package relaydb

import (
	"context"
	"database/sql"
	"strings"

	"micagoserver/internal/send"
	"micagoserver/internal/store"
)

func (db *DB) ListChats(ctx context.Context, limit, offset int, withArchived bool, service string) ([]store.ChatJSON, error) {
	query := `
SELECT guid, chat_identifier, service_name, display_name, is_archived
FROM chats
WHERE (? = 1 OR is_archived = 0)
  AND (? = 'all' OR service_name = ?)
ORDER BY updated_at DESC
LIMIT ? OFFSET ?;
`
	rows, err := db.sqlDB.QueryContext(ctx, query, boolToInt(withArchived), service, service, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var chats []store.ChatJSON
	for rows.Next() {
		var chat store.ChatJSON
		if err := rows.Scan(
			&chat.GUID,
			&chat.ChatIdentifier,
			&chat.ServiceName,
			&chat.DisplayName,
			&chat.IsArchived,
		); err != nil {
			return nil, err
		}
		chats = append(chats, chat)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return chats, nil
}

// relayMessageSelect is the shared SELECT for relay message reads. It exposes
// the BlueBubbles-compatible semantic columns and LEFT JOINs message_state so
// retracted/edited/error (maintained by the lookback update pass) are surfaced.
const relayMessageSelect = `
SELECT m.guid, m.text, m.subject, m.service, m.date_created, m.date_read, m.date_delivered,
       m.is_from_me, m.is_read, m.is_delivered, m.handle_id, m.handle_service, m.cache_has_attachments,
       m.chat_guid,
       m.associated_message_type, m.associated_message_guid, m.thread_originator_guid,
       m.item_type, m.group_action_type, m.group_title, m.balloon_bundle_id,
       m.expressive_send_style_id, m.payload_data_present,
       ms.date_edited, ms.date_retracted, ms.error
FROM messages AS m
LEFT JOIN message_state AS ms ON ms.guid = m.guid
`

func (db *DB) ListRecentMessages(ctx context.Context, limit, offset int, service string, _ bool) ([]store.MessageJSON, error) {
	query := relayMessageSelect + `
WHERE (? = 'all' OR m.service = ?)
ORDER BY m.source_rowid DESC, m.date_created DESC
LIMIT ? OFFSET ?;
`
	rows, err := db.sqlDB.QueryContext(ctx, query, service, service, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return db.scanRelayMessagesWithAttachments(ctx, rows)
}

func (db *DB) ChatExists(ctx context.Context, guid string) (bool, error) {
	var one int
	err := db.sqlDB.QueryRowContext(ctx, `SELECT 1 FROM chats WHERE guid = ? LIMIT 1`, guid).Scan(&one)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func (db *DB) GetChatInfo(ctx context.Context, guid string) (*store.ChatInfo, error) {
	var info store.ChatInfo
	err := db.sqlDB.QueryRowContext(ctx, `SELECT guid, service_name FROM chats WHERE guid = ? LIMIT 1`, guid).Scan(&info.GUID, &info.ServiceName)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &info, nil
}

func (db *DB) ListChatMessages(ctx context.Context, guid string, limit, offset int, _ bool) ([]store.MessageJSON, error) {
	query := relayMessageSelect + `
WHERE m.chat_guid = ?
ORDER BY m.source_rowid DESC, m.date_created DESC
LIMIT ? OFFSET ?;
`
	rows, err := db.sqlDB.QueryContext(ctx, query, guid, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return db.scanRelayMessagesWithAttachments(ctx, rows)
}

func (db *DB) FindOutgoingMessageMatch(ctx context.Context, guid string, normalizedText string, sentAtUnixMilli int64, excludedGUIDs map[string]struct{}) (*store.MessageJSON, error) {
	rows, err := db.sqlDB.QueryContext(ctx, relayMessageSelect+`
WHERE m.chat_guid = ?
  AND m.is_from_me = 1
  AND m.date_created >= ?
ORDER BY m.source_rowid DESC, m.date_created DESC
LIMIT 100;
`, guid, sentAtUnixMilli)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	messages, err := db.scanRelayMessagesWithAttachments(ctx, rows)
	if err != nil {
		return nil, err
	}

	for _, message := range messages {
		if _, skip := excludedGUIDs[message.GUID]; skip {
			continue
		}
		if send.NormalizeText(stringValue(message.Text)) == normalizedText {
			return &message, nil
		}
	}

	return nil, nil
}

func (db *DB) GetMessagesByGUIDs(ctx context.Context, guids []string) ([]store.MessageJSON, error) {
	if len(guids) == 0 {
		return nil, nil
	}

	placeholders := make([]string, len(guids))
	args := make([]any, len(guids))
	for i, guid := range guids {
		placeholders[i] = "?"
		args[i] = guid
	}

	rows, err := db.sqlDB.QueryContext(ctx, relayMessageSelect+`
WHERE m.guid IN (`+strings.Join(placeholders, ", ")+`)
ORDER BY m.source_rowid ASC, m.date_created ASC;
`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return db.scanRelayMessagesWithAttachments(ctx, rows)
}

func (db *DB) GetAttachmentByGUID(ctx context.Context, guid string) (*store.AttachmentMeta, error) {
	var meta store.AttachmentMeta
	var filename, mimeType, transferName, localPath, uti *string
	var isOutgoing, hideAttachment int64
	var isSticker sql.NullInt64
	err := db.sqlDB.QueryRowContext(ctx, `
SELECT guid, message_guid, filename, mime_type, transfer_name, total_bytes, local_path, is_outgoing, hide_attachment, created_at, uti, is_sticker
FROM attachments
WHERE guid = ?
LIMIT 1;
`, guid).Scan(
		&meta.GUID,
		&meta.MessageGUID,
		&filename,
		&mimeType,
		&transferName,
		&meta.TotalBytes,
		&localPath,
		&isOutgoing,
		&hideAttachment,
		&meta.CreatedAt,
		&uti,
		&isSticker,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	meta.Filename = filename
	meta.MimeType = mimeType
	meta.TransferName = transferName
	meta.LocalPath = localPath
	meta.IsOutgoing = isOutgoing != 0
	meta.HideAttachment = hideAttachment != 0
	meta.Uti = uti
	meta.IsSticker = isSticker.Valid && isSticker.Int64 != 0
	return &meta, nil
}

func scanRelayMessages(rows *sql.Rows) ([]store.MessageJSON, error) {
	var messages []store.MessageJSON
	for rows.Next() {
		var message store.MessageJSON
		var handleID, handleService *string
		var isFromMe, isRead, isDelivered, hasAttachments int64
		var payloadPresent sql.NullInt64
		if err := rows.Scan(
			&message.GUID,
			&message.Text,
			&message.Subject,
			&message.Service,
			&message.DateCreated,
			&message.DateRead,
			&message.DateDelivered,
			&isFromMe,
			&isRead,
			&isDelivered,
			&handleID,
			&handleService,
			&hasAttachments,
			&message.ChatGUID,
			&message.AssociatedMessageType,
			&message.AssociatedMessageGUID,
			&message.ThreadOriginatorGUID,
			&message.ItemType,
			&message.GroupActionType,
			&message.GroupTitle,
			&message.BalloonBundleID,
			&message.ExpressiveSendStyleID,
			&payloadPresent,
			&message.DateEdited,
			&message.DateRetracted,
			&message.Error,
		); err != nil {
			return nil, err
		}

		message.IsFromMe = isFromMe != 0
		message.IsRead = isRead != 0
		message.IsDelivered = isDelivered != 0
		message.CacheHasAttachments = hasAttachments != 0
		message.PayloadDataPresent = payloadPresent.Valid && payloadPresent.Int64 != 0
		message.IsRetracted = message.DateRetracted != nil
		message.IsEdited = message.DateEdited != nil
		if handleID != nil {
			message.Handle = &store.HandleJSON{
				ID:      *handleID,
				Service: handleService,
			}
		}

		messages = append(messages, message)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return messages, nil
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func (db *DB) scanRelayMessagesWithAttachments(ctx context.Context, rows *sql.Rows) ([]store.MessageJSON, error) {
	messages, err := scanRelayMessages(rows)
	if err != nil {
		return nil, err
	}
	return db.attachMessageAttachments(ctx, messages)
}

func (db *DB) attachMessageAttachments(ctx context.Context, messages []store.MessageJSON) ([]store.MessageJSON, error) {
	if len(messages) == 0 {
		return messages, nil
	}

	guids := make([]string, 0, len(messages))
	for _, message := range messages {
		guids = append(guids, message.GUID)
	}

	grouped, err := db.loadAttachmentsByMessageGUID(ctx, guids)
	if err != nil {
		return nil, err
	}

	for i := range messages {
		messages[i].Attachments = grouped[messages[i].GUID]
		if messages[i].Attachments == nil {
			messages[i].Attachments = []store.AttachmentJSON{}
		}
	}
	return messages, nil
}

func (db *DB) loadAttachmentsByMessageGUID(ctx context.Context, guids []string) (map[string][]store.AttachmentJSON, error) {
	placeholders := make([]string, len(guids))
	args := make([]any, len(guids))
	for i, guid := range guids {
		placeholders[i] = "?"
		args[i] = guid
	}

	rows, err := db.sqlDB.QueryContext(ctx, `
SELECT guid, message_guid, filename, mime_type, transfer_name, total_bytes, uti, is_sticker
FROM attachments
WHERE message_guid IN (`+strings.Join(placeholders, ", ")+`)
ORDER BY created_at ASC, guid ASC;
`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	grouped := make(map[string][]store.AttachmentJSON, len(guids))
	for rows.Next() {
		var attachment store.AttachmentJSON
		var messageGUID string
		var isSticker sql.NullInt64
		if err := rows.Scan(
			&attachment.GUID,
			&messageGUID,
			&attachment.Filename,
			&attachment.MimeType,
			&attachment.TransferName,
			&attachment.TotalBytes,
			&attachment.Uti,
			&isSticker,
		); err != nil {
			return nil, err
		}
		attachment.IsSticker = isSticker.Valid && isSticker.Int64 != 0
		attachment.DownloadURL = "/api/attachments/" + attachment.GUID
		store.DecorateAttachmentJSON(&attachment)
		grouped[messageGUID] = append(grouped[messageGUID], attachment)
	}

	return grouped, rows.Err()
}
