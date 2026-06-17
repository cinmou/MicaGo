package relaydb

import (
	"context"
	"database/sql"
	"strings"

	"micagoserver/internal/send"
	"micagoserver/internal/store"
)

func serviceNamesForSettings(settings SyncSettings) []string {
	var out []string
	if settings.IncludeIMessage {
		out = append(out, "iMessage", "iMessageLite")
	}
	if settings.IncludeSMS {
		out = append(out, "SMS", "Text", "Plain")
	}
	if settings.IncludeRCS {
		out = append(out, "RCS")
	}
	if len(out) == 0 {
		return []string{"iMessage"}
	}
	return out
}

func servicePlaceholders(settings SyncSettings) string {
	names := serviceNamesForSettings(settings)
	return strings.TrimRight(strings.Repeat("?,", len(names)), ",")
}

func serviceArgs(settings SyncSettings) []any {
	names := serviceNamesForSettings(settings)
	args := make([]any, len(names))
	for i, name := range names {
		args[i] = name
	}
	return args
}

func (db *DB) ListChats(ctx context.Context, limit, offset int, withArchived bool, service string, includeDebug bool) ([]store.ChatJSON, error) {
	settings, err := db.GetSyncSettings(ctx)
	if err != nil {
		return nil, err
	}
	effectiveDebug := includeDebug || settings.IncludeDebugInNormal
	// Per-chat renderable summary via correlated subqueries over the persisted
	// is_debug_only flag. Chats whose only content is debug-only/noise are
	// flagged and (by default) hidden from the normal client list.
	query := `
SELECT c.guid, c.chat_identifier, c.service_name, c.display_name, c.is_archived,
  (SELECT COUNT(*) FROM messages m WHERE m.chat_guid = c.guid) AS total,
  (SELECT COUNT(*) FROM messages m WHERE m.chat_guid = c.guid AND COALESCE(m.is_debug_only, 0) = 0 AND COALESCE(m.is_reaction, 0) = 0) AS renderable,
  (SELECT m.date_created FROM messages m WHERE m.chat_guid = c.guid AND COALESCE(m.is_debug_only, 0) = 0 AND COALESCE(m.is_reaction, 0) = 0 ORDER BY m.date_created DESC, m.source_rowid DESC LIMIT 1) AS latest_at,
  (SELECT m.text FROM messages m WHERE m.chat_guid = c.guid AND COALESCE(m.is_debug_only, 0) = 0 AND COALESCE(m.is_reaction, 0) = 0 ORDER BY m.date_created DESC, m.source_rowid DESC LIMIT 1) AS latest_text,
  (SELECT m.service FROM messages m WHERE m.chat_guid = c.guid AND COALESCE(m.is_debug_only, 0) = 0 AND COALESCE(m.is_reaction, 0) = 0 ORDER BY m.date_created DESC, m.source_rowid DESC LIMIT 1) AS latest_service,
  (SELECT COUNT(*) FROM messages m WHERE m.chat_guid = c.guid AND m.service IN ('iMessage','iMessageLite')) AS imessage_count
FROM chats c
WHERE (? = 1 OR c.is_archived = 0)
  AND (? = 'all' OR c.service_name = ?)
ORDER BY COALESCE(latest_at, 0) DESC, c.updated_at DESC;
`
	var rows *sql.Rows
	if service == "unknown" {
		query = strings.Replace(query, "AND (? = 'all' OR c.service_name = ?)", "AND c.service_name NOT IN ('iMessage','iMessageLite','SMS','Text','Plain','RCS')", 1)
		rows, err = db.sqlDB.QueryContext(ctx, query, boolToInt(withArchived))
	} else {
		rows, err = db.sqlDB.QueryContext(ctx, query, boolToInt(withArchived), service, service)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var all []store.ChatJSON
	for rows.Next() {
		var chat store.ChatJSON
		var total, renderable int64
		var latestAt *int64
		var latestText *string
		var latestService *string
		var imessageCount int64
		if err := rows.Scan(
			&chat.GUID,
			&chat.ChatIdentifier,
			&chat.ServiceName,
			&chat.DisplayName,
			&chat.IsArchived,
			&total,
			&renderable,
			&latestAt,
			&latestText,
			&latestService,
			&imessageCount,
		); err != nil {
			return nil, err
		}
		chat.HasRenderableMessages = renderable > 0
		chat.ServiceCategory = ServiceCategory(chat.ServiceName)
		// C21: the single server-authoritative service (message-aware, prefers
		// iMessage when the chat is iMessage-capable) — drives the client badge,
		// the explicit send capabilities, and the server send gate.
		chat.EffectiveService = ResolveEffectiveService(chat.ServiceName, latestService, imessageCount > 0)
		chat.CanSendText, chat.CanSendAttachments = settings.SendCapabilities(chat.EffectiveService)
		chat.LatestRenderableAt = latestAt
		if latestText != nil {
			if t := strings.TrimSpace(*latestText); t != "" {
				chat.LatestRenderablePreview = &t
			}
		}
		chat.UnsupportedOnly = total > 0 && renderable == 0
		if total == 0 {
			chat.HiddenReason = "empty"
		} else if renderable == 0 {
			chat.HiddenReason = "debug_only"
		}
		all = append(all, chat)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Hide noise unless the caller asked for debug. Filtering happens here (not
	// in SQL) so limit/offset apply to the visible set.
	filtered := all
	if !includeDebug {
		filtered = filtered[:0]
		for _, c := range all {
			if !settings.IncludesCategory(c.ServiceCategory) {
				continue
			}
			if effectiveDebug || c.HasRenderableMessages {
				filtered = append(filtered, c)
			}
		}
	}

	// Apply offset/limit to the visible set.
	if offset >= len(filtered) {
		return []store.ChatJSON{}, nil
	}
	end := offset + limit
	if end > len(filtered) {
		end = len(filtered)
	}
	return filtered[offset:end], nil
}

// relayMessageSelect is the shared SELECT for relay message reads. It exposes
// the BlueBubbles-compatible semantic columns and LEFT JOINs message_state so
// retracted/edited/error (maintained by the lookback update pass) are surfaced.
const relayMessageSelect = `
SELECT m.guid, m.text, m.subject, m.service, m.account, m.date_created, m.date_read, m.date_delivered,
       m.is_from_me, m.is_read, m.is_delivered, m.handle_id, m.handle_service, m.cache_has_attachments,
       m.chat_guid, COALESCE(m.has_attributed_body, 0),
       m.associated_message_type, m.associated_message_guid, m.thread_originator_guid,
       m.item_type, m.group_action_type, m.group_title, m.balloon_bundle_id,
       m.expressive_send_style_id, m.payload_data_present,
       ms.date_edited, ms.date_retracted, ms.error, m.source_rowid
FROM messages AS m
LEFT JOIN message_state AS ms ON ms.guid = m.guid
`

// ListRecentMessages returns the renderable timeline by default: debug-only /
// noise rows are excluded in SQL (before LIMIT/OFFSET, so pagination is stable).
// includeDebug=true returns the raw timeline for the Message Inspector.
func (db *DB) ListRecentMessages(ctx context.Context, limit, offset int, service string, includeDebug bool) ([]store.MessageJSON, error) {
	settings, err := db.GetSyncSettings(ctx)
	if err != nil {
		return nil, err
	}
	effectiveDebug := includeDebug || settings.IncludeDebugInNormal
	query := relayMessageSelect + `
WHERE (? = 'all' OR m.service = ?)
  AND (? = 1 OR m.service IN (` + servicePlaceholders(settings) + `))
  AND (? = 1 OR COALESCE(m.is_debug_only, 0) = 0)
ORDER BY m.source_rowid DESC, m.date_created DESC
LIMIT ? OFFSET ?;
`
	args := []any{service, service, boolToInt(includeDebug)}
	args = append(args, serviceArgs(settings)...)
	args = append(args, boolToInt(effectiveDebug), limit, offset)
	if service == "unknown" {
		query = strings.Replace(query, "(? = 'all' OR m.service = ?)", "m.service NOT IN ('iMessage','iMessageLite','SMS','Text','Plain','RCS')", 1)
		args = []any{boolToInt(includeDebug)}
		args = append(args, serviceArgs(settings)...)
		args = append(args, boolToInt(effectiveDebug), limit, offset)
	}
	rows, err := db.sqlDB.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return db.scanRelayMessagesWithAttachments(ctx, rows)
}

// DeltaResult is the response to a cursor delta fetch (C21): renderable messages
// changed since the cursor, the affected chat GUIDs, the new cursor, and whether
// more remain (so the client can page until caught up).
type DeltaResult struct {
	Messages  []store.MessageJSON `json:"messages"`
	ChatGUIDs []string            `json:"chatGuids"`
	Cursor    int64               `json:"cursor"`
	HasMore   bool                `json:"hasMore"`
}

// ListMessagesSince returns renderable messages whose source_rowid is greater
// than [since], oldest-first, capped at [limit]. The cursor advances to the last
// returned row, or — when nothing is newer — to the current max so it never
// regresses. This is the correctness path: realtime WS is the fast path, this
// catch-up guarantees nothing missed while disconnected/backgrounded.
//
// A negative [since] means "uninitialized": return no messages, just the current
// max cursor, so a fresh client seeds its cursor to "now" without backfilling.
func (db *DB) ListMessagesSince(ctx context.Context, since int64, limit int) (DeltaResult, error) {
	maxRowID, err := db.maxMessageRowID(ctx)
	if err != nil {
		return DeltaResult{}, err
	}
	if since < 0 {
		return DeltaResult{Messages: []store.MessageJSON{}, ChatGUIDs: []string{}, Cursor: maxRowID}, nil
	}
	if limit <= 0 || limit > 500 {
		limit = 200
	}

	query := relayMessageSelect + `
WHERE COALESCE(m.is_debug_only, 0) = 0
  AND m.source_rowid > ?
ORDER BY m.source_rowid ASC
LIMIT ?;
`
	// Fetch one extra to detect hasMore.
	rows, err := db.sqlDB.QueryContext(ctx, query, since, limit+1)
	if err != nil {
		return DeltaResult{}, err
	}
	defer rows.Close()
	messages, err := db.scanRelayMessagesWithAttachments(ctx, rows)
	if err != nil {
		return DeltaResult{}, err
	}

	hasMore := len(messages) > limit
	if hasMore {
		messages = messages[:limit]
	}

	cursor := since
	chatSet := map[string]struct{}{}
	chatGUIDs := []string{}
	for _, m := range messages {
		if m.SourceRowID != nil && *m.SourceRowID > cursor {
			cursor = *m.SourceRowID
		}
		if m.ChatGUID != nil {
			if _, seen := chatSet[*m.ChatGUID]; !seen {
				chatSet[*m.ChatGUID] = struct{}{}
				chatGUIDs = append(chatGUIDs, *m.ChatGUID)
			}
		}
	}
	// No newer rows → advance to the current ceiling so quiet periods don't
	// re-scan the same window forever.
	if !hasMore && cursor < maxRowID {
		cursor = maxRowID
	}

	return DeltaResult{Messages: messages, ChatGUIDs: chatGUIDs, Cursor: cursor, HasMore: hasMore}, nil
}

func (db *DB) maxMessageRowID(ctx context.Context) (int64, error) {
	var maxRowID sql.NullInt64
	if err := db.sqlDB.QueryRowContext(ctx, `SELECT MAX(source_rowid) FROM messages`).Scan(&maxRowID); err != nil {
		return 0, err
	}
	if maxRowID.Valid {
		return maxRowID.Int64, nil
	}
	return 0, nil
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
	// C21: resolve the same message-aware effective service the chat list and
	// client use, so the send gate can never disagree with the displayed badge.
	var latestService *string
	err = db.sqlDB.QueryRowContext(ctx, `
SELECT m.service FROM messages m
WHERE m.chat_guid = ? AND COALESCE(m.is_debug_only, 0) = 0 AND COALESCE(m.is_reaction, 0) = 0
ORDER BY m.date_created DESC, m.source_rowid DESC LIMIT 1`, guid).Scan(&latestService)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	// C21c: capability signal — does the chat have ANY iMessage message?
	var imessageCount int64
	if err := db.sqlDB.QueryRowContext(ctx, `
SELECT COUNT(*) FROM messages m WHERE m.chat_guid = ? AND m.service IN ('iMessage','iMessageLite')`, guid).Scan(&imessageCount); err != nil {
		return nil, err
	}
	info.EffectiveService = ResolveEffectiveService(info.ServiceName, latestService, imessageCount > 0)
	return &info, nil
}

// ListChatMessages returns one chat's renderable thread by default: debug-only /
// noise rows are excluded in SQL (before LIMIT/OFFSET, so a page is never
// silently shrunk by post-filtering). Reaction rows are kept — they carry
// renderRecommendation=merge so the client folds tapbacks onto their target.
// includeDebug=true returns the raw thread for the Message Inspector.
func (db *DB) ListChatMessages(ctx context.Context, guid string, limit, offset int, includeDebug bool) ([]store.MessageJSON, error) {
	settings, err := db.GetSyncSettings(ctx)
	if err != nil {
		return nil, err
	}
	effectiveDebug := includeDebug || settings.IncludeDebugInNormal
	query := relayMessageSelect + `
WHERE m.chat_guid = ?
  AND (? = 1 OR m.service IN (` + servicePlaceholders(settings) + `))
  AND (? = 1 OR COALESCE(m.is_debug_only, 0) = 0)
ORDER BY m.source_rowid DESC, m.date_created DESC
LIMIT ? OFFSET ?;
`
	args := []any{guid, boolToInt(includeDebug)}
	args = append(args, serviceArgs(settings)...)
	args = append(args, boolToInt(effectiveDebug), limit, offset)
	rows, err := db.sqlDB.QueryContext(ctx, query, args...)
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
		var isFromMe, isRead, isDelivered, hasAttachments, hasAttributedBody int64
		var payloadPresent sql.NullInt64
		if err := rows.Scan(
			&message.GUID,
			&message.Text,
			&message.Subject,
			&message.Service,
			&message.Account,
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
			&hasAttributedBody,
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
			&message.SourceRowID,
		); err != nil {
			return nil, err
		}

		message.IsFromMe = isFromMe != 0
		message.IsRead = isRead != 0
		message.IsDelivered = isDelivered != 0
		message.CacheHasAttachments = hasAttachments != 0
		message.ServiceCategory = ServiceCategory(message.Service)
		message.HasAttributedBody = hasAttributedBody != 0
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
		store.AnnotateMessageJSON(&messages[i])
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
		if attachment.NeedsPreviewConversion {
			attachment.PreviewURL = "/api/attachments/" + attachment.GUID + "/preview"
		}
		grouped[messageGUID] = append(grouped[messageGUID], attachment)
	}

	return grouped, rows.Err()
}
