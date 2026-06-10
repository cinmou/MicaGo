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

// byDateSource is an optional capability: a sync source that can scan a bounded
// date window (C11). The live chat.db source implements it; lightweight test
// fakes need not.
type byDateSource interface {
	ListSyncRecentMessagesByDate(ctx context.Context, afterUnixMilli int64, limit int) ([]store.SyncMessageRow, error)
}

// unionByGUID appends rows from b not already present (by GUID) in a.
func unionByGUID(a, b []store.SyncMessageRow) []store.SyncMessageRow {
	if len(b) == 0 {
		return a
	}
	seen := make(map[string]struct{}, len(a))
	for _, m := range a {
		seen[m.GUID] = struct{}{}
	}
	out := a
	for _, m := range b {
		if _, ok := seen[m.GUID]; ok {
			continue
		}
		seen[m.GUID] = struct{}{}
		out = append(out, m)
	}
	return out
}

func SyncOnce(ctx context.Context, source syncSource, relay *DB, limit int, lookback time.Duration) (SyncResult, error) {
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
		// C11: also scan a bounded date window (BlueBubbles-style) so rows the
		// ROWID watermark skipped under WAL/rowid races are recovered. Idempotent
		// — the relay upsert dedupes by guid and only truly-new rows broadcast.
		if lookback > 0 {
			if bd, ok := source.(byDateSource); ok {
				afterMs := time.Now().Add(-lookback).UnixMilli()
				dated, derr := bd.ListSyncRecentMessagesByDate(ctx, afterMs, limit)
				if derr != nil {
					return SyncResult{}, fmt.Errorf("list date-lookback messages: %w", derr)
				}
				messages = unionByGUID(messages, dated)
			}
		}
	}

	// v0.11.3: evaluate sync rules. Blocked messages are NOT inserted/broadcast/
	// pushed, but the rowid watermark below still advances over the FULL set so
	// blocked messages are not re-scanned forever.
	snapshot, err := relay.LoadRuleSnapshot(ctx)
	if err != nil {
		return SyncResult{}, fmt.Errorf("load sync rules: %w", err)
	}
	syncedMessages := make([]store.SyncMessageRow, 0, len(messages))
	for _, message := range messages {
		if snapshot.SyncAllowed(message.ChatGUID, message.HandleID) {
			syncedMessages = append(syncedMessages, message)
		}
	}

	messageGUIDs := make([]string, 0, len(syncedMessages))
	for _, message := range syncedMessages {
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
	insertedGUIDs, err := upsertMessagesTx(tx, syncedMessages, now)
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
		result.NotificationEvents = buildNotificationEvents(result.NewMessages, syncedMessages, chats, snapshot)
	}

	return result, nil
}

func buildNotificationEvents(messages []store.MessageJSON, rows []store.SyncMessageRow, chats []store.SyncChatRow, snapshot RuleSnapshot) []NotificationEvent {
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
		// v0.11.3: muted (but synced) messages are excluded from push dispatch.
		if !snapshot.PushEnabled(row.ChatGUID, row.HandleID) {
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
	is_from_me, is_read, is_delivered, handle_id, handle_service, cache_has_attachments, created_at,
	has_attributed_body, associated_message_type, associated_message_guid, thread_originator_guid, item_type,
	group_action_type, group_title, balloon_bundle_id, expressive_send_style_id, payload_data_present,
	is_debug_only, is_reaction
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
	cache_has_attachments = excluded.cache_has_attachments,
	has_attributed_body = excluded.has_attributed_body,
	associated_message_type = excluded.associated_message_type,
	associated_message_guid = excluded.associated_message_guid,
	thread_originator_guid = excluded.thread_originator_guid,
	item_type = excluded.item_type,
	group_action_type = excluded.group_action_type,
	group_title = excluded.group_title,
	balloon_bundle_id = excluded.balloon_bundle_id,
	expressive_send_style_id = excluded.expressive_send_style_id,
	payload_data_present = excluded.payload_data_present,
	is_debug_only = excluded.is_debug_only,
	is_reaction = excluded.is_reaction;
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
			boolToInt(message.HasAttributedBody),
			message.AssociatedMessageType,
			message.AssociatedMessageGUID,
			message.ThreadOriginatorGUID,
			message.ItemType,
			message.GroupActionType,
			message.GroupTitle,
			message.BalloonBundleID,
			message.ExpressiveSendStyleID,
			boolToInt(message.PayloadDataPresent),
			boolToInt(store.DebugOnlyForSyncRow(message)),
			boolToInt(store.IsReactionForSyncRow(message)),
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
	guid, message_guid, filename, mime_type, transfer_name, total_bytes, local_path, is_outgoing, hide_attachment, created_at, uti, is_sticker
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
	message_guid = excluded.message_guid,
	filename = excluded.filename,
	mime_type = excluded.mime_type,
	transfer_name = excluded.transfer_name,
	total_bytes = excluded.total_bytes,
	local_path = excluded.local_path,
	is_outgoing = excluded.is_outgoing,
	hide_attachment = excluded.hide_attachment,
	created_at = excluded.created_at,
	uti = excluded.uti,
	is_sticker = excluded.is_sticker;
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
			attachment.Uti,
			boolToInt(attachment.IsSticker),
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
