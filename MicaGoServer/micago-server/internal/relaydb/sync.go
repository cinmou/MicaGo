package relaydb

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"time"

	"micagoserver/internal/store"
)

type syncSource interface {
	ListSyncChats(ctx context.Context) ([]store.SyncChatRow, error)
	ListSyncRecentMessages(ctx context.Context, limit int) ([]store.SyncMessageRow, error)
	ListSyncRecentMessagesSince(ctx context.Context, afterRowID int64, limit int) ([]store.SyncMessageRow, error)
	ListSyncAttachmentsForMessages(ctx context.Context, messageGUIDs []string) ([]store.SyncAttachmentRow, error)
}

func SyncOnce(ctx context.Context, source syncSource, relay *DB, limit int) (SyncResult, error) {
	lastRowIDValue, hasLastRowID, err := relay.GetSyncState("last_message_rowid")
	if err != nil {
		return SyncResult{}, fmt.Errorf("get last_message_rowid: %w", err)
	}

	var previousLastRowID int64
	if hasLastRowID {
		previousLastRowID, err = strconv.ParseInt(lastRowIDValue, 10, 64)
		if err != nil {
			return SyncResult{}, fmt.Errorf("parse last_message_rowid: %w", err)
		}
	}

	chats, err := source.ListSyncChats(ctx)
	if err != nil {
		return SyncResult{}, fmt.Errorf("list sync chats: %w", err)
	}

	mode := "incremental"
	var messages []store.SyncMessageRow
	if !hasLastRowID {
		mode = "initial"
		messages, err = source.ListSyncRecentMessages(ctx, limit)
		if err != nil {
			return SyncResult{}, fmt.Errorf("list initial sync messages: %w", err)
		}
	} else {
		messages, err = source.ListSyncRecentMessagesSince(ctx, previousLastRowID, limit)
		if err != nil {
			return SyncResult{}, fmt.Errorf("list incremental sync messages: %w", err)
		}
	}

	messageGUIDs := make([]string, 0, len(messages))
	for _, message := range messages {
		messageGUIDs = append(messageGUIDs, message.GUID)
	}

	attachments, err := source.ListSyncAttachmentsForMessages(ctx, messageGUIDs)
	if err != nil {
		return SyncResult{}, fmt.Errorf("list sync attachments: %w", err)
	}

	tx, err := relay.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return SyncResult{}, err
	}
	defer tx.Rollback()

	now := time.Now().UnixMilli()
	if err := upsertChatsTx(tx, chats, now); err != nil {
		return SyncResult{}, err
	}
	insertedGUIDs, err := upsertMessagesTx(tx, messages, now)
	if err != nil {
		return SyncResult{}, err
	}
	if err := upsertAttachmentsTx(tx, attachments, now); err != nil {
		return SyncResult{}, err
	}

	result := SyncResult{
		Mode:                     mode,
		PreviousLastMessageRowID: previousLastRowID,
		NewLastMessageRowID:      previousLastRowID,
		ChatsSynced:              len(chats),
		MessagesSynced:           len(messages),
		AttachmentsSynced:        len(attachments),
	}
	for _, message := range messages {
		if message.SourceRowID > result.NewLastMessageRowID {
			result.NewLastMessageRowID = message.SourceRowID
			result.LastMessageGUID = message.GUID
			if message.DateCreated != nil {
				result.LastMessageDateCreated = *message.DateCreated
			} else {
				result.LastMessageDateCreated = 0
			}
		}
	}

	if err := setSyncStateTx(tx, "last_sync_at", strconv.FormatInt(now, 10)); err != nil {
		return SyncResult{}, err
	}
	if result.NewLastMessageRowID > previousLastRowID {
		if err := setSyncStateTx(tx, "last_message_rowid", strconv.FormatInt(result.NewLastMessageRowID, 10)); err != nil {
			return SyncResult{}, err
		}
	}
	if result.LastMessageGUID != "" {
		if err := setSyncStateTx(tx, "last_message_guid", result.LastMessageGUID); err != nil {
			return SyncResult{}, err
		}
		if err := setSyncStateTx(tx, "last_message_date_created", strconv.FormatInt(result.LastMessageDateCreated, 10)); err != nil {
			return SyncResult{}, err
		}
	}

	if err := tx.Commit(); err != nil {
		return SyncResult{}, err
	}

	if len(insertedGUIDs) > 0 {
		result.NewMessages, err = relay.GetMessagesByGUIDs(ctx, insertedGUIDs)
		if err != nil {
			return SyncResult{}, err
		}
		result.NotificationEvents = buildNotificationEvents(result.NewMessages, messages, chats)
	}

	return result, nil
}

func buildNotificationEvents(messages []store.MessageJSON, rows []store.SyncMessageRow, chats []store.SyncChatRow) []NotificationEvent {
	if len(messages) == 0 {
		return nil
	}
	messageRows := make(map[string]store.SyncMessageRow, len(rows))
	for _, row := range rows {
		messageRows[row.GUID] = row
	}
	chatRows := make(map[string]store.SyncChatRow, len(chats))
	for _, chat := range chats {
		chatRows[chat.GUID] = chat
	}

	events := make([]NotificationEvent, 0, len(messages))
	for _, message := range messages {
		row, ok := messageRows[message.GUID]
		if !ok {
			continue
		}
		chat := chatRows[row.ChatGUID]
		events = append(events, NotificationEvent{
			ChatGUID:       row.ChatGUID,
			ChatIdentifier: chat.ChatIdentifier,
			ChatDisplay:    chat.DisplayName,
			Message:        message,
		})
	}
	return events
}

func upsertChatsTx(tx *sql.Tx, chats []store.SyncChatRow, updatedAt int64) error {
	stmt, err := tx.Prepare(`
INSERT INTO chats (
	guid, chat_identifier, service_name, display_name, is_archived, updated_at
) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
	chat_identifier = excluded.chat_identifier,
	service_name = excluded.service_name,
	display_name = excluded.display_name,
	is_archived = excluded.is_archived,
	updated_at = excluded.updated_at;
`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, chat := range chats {
		if _, err := stmt.Exec(
			chat.GUID,
			chat.ChatIdentifier,
			chat.ServiceName,
			chat.DisplayName,
			boolToInt(chat.IsArchived),
			updatedAt,
		); err != nil {
			return err
		}
	}

	return nil
}

func upsertMessagesTx(tx *sql.Tx, messages []store.SyncMessageRow, createdAt int64) ([]string, error) {
	stmt, err := tx.Prepare(`
INSERT INTO messages (
	guid, chat_guid, source_rowid, text, subject, service, date_created, date_read, date_delivered,
	is_from_me, is_read, is_delivered, handle_id, handle_service, cache_has_attachments, created_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
	chat_guid = excluded.chat_guid,
	source_rowid = excluded.source_rowid,
	text = excluded.text,
	subject = excluded.subject,
	service = excluded.service,
	date_created = excluded.date_created,
	date_read = excluded.date_read,
	date_delivered = excluded.date_delivered,
	is_from_me = excluded.is_from_me,
	is_read = excluded.is_read,
	is_delivered = excluded.is_delivered,
	handle_id = excluded.handle_id,
	handle_service = excluded.handle_service,
	cache_has_attachments = excluded.cache_has_attachments;
`)
	if err != nil {
		return nil, err
	}
	defer stmt.Close()

	insertedGUIDs := make([]string, 0, len(messages))
	for _, message := range messages {
		var exists int
		err := tx.QueryRow(`SELECT 1 FROM messages WHERE guid = ? LIMIT 1`, message.GUID).Scan(&exists)
		isNew := err == sql.ErrNoRows
		if err != nil && err != sql.ErrNoRows {
			return nil, err
		}
		if _, err := stmt.Exec(
			message.GUID,
			message.ChatGUID,
			message.SourceRowID,
			message.Text,
			message.Subject,
			message.Service,
			message.DateCreated,
			message.DateRead,
			message.DateDelivered,
			boolToInt(message.IsFromMe),
			boolToInt(message.IsRead),
			boolToInt(message.IsDelivered),
			message.HandleID,
			message.HandleService,
			boolToInt(message.CacheHasAttachments),
			createdAt,
		); err != nil {
			return nil, err
		}
		if isNew {
			insertedGUIDs = append(insertedGUIDs, message.GUID)
		}
	}

	return insertedGUIDs, nil
}

func upsertAttachmentsTx(tx *sql.Tx, attachments []store.SyncAttachmentRow, createdAt int64) error {
	stmt, err := tx.Prepare(`
INSERT INTO attachments (
	guid, message_guid, filename, mime_type, transfer_name, total_bytes, local_path, is_outgoing, hide_attachment, created_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
	message_guid = excluded.message_guid,
	filename = excluded.filename,
	mime_type = excluded.mime_type,
	transfer_name = excluded.transfer_name,
	total_bytes = excluded.total_bytes,
	local_path = excluded.local_path,
	is_outgoing = excluded.is_outgoing,
	hide_attachment = excluded.hide_attachment,
	created_at = excluded.created_at;
`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, attachment := range attachments {
		created := createdAt
		if attachment.CreatedAt != nil {
			created = *attachment.CreatedAt
		}
		if _, err := stmt.Exec(
			attachment.GUID,
			attachment.MessageGUID,
			attachment.Filename,
			attachment.MimeType,
			attachment.TransferName,
			attachment.TotalBytes,
			attachment.LocalPath,
			boolToInt(attachment.IsOutgoing),
			boolToInt(attachment.HideAttachment),
			created,
		); err != nil {
			return err
		}
	}

	return nil
}

func setSyncStateTx(tx *sql.Tx, key, value string) error {
	_, err := tx.Exec(`
INSERT INTO sync_state (key, value)
VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
`, key, value)
	return err
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
