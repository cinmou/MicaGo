package store

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	"micagoserver/internal/send"
	"micagoserver/internal/timeutil"
)

const recentMessagesBaseSQL = `
SELECT DISTINCT
  m.guid,
  m.text,
  m.attributedBody,
  m.subject,
  m.service,
  m.date,
  m.date_read,
  m.date_delivered,
  m.is_from_me,
  m.is_read,
  m.is_delivered,
  m.cache_has_attachments,
  h.id AS handle_id_value,
  h.service AS handle_service
FROM message AS m
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
`

const chatsBaseSQL = `
SELECT
  c.guid,
  c.chat_identifier,
  c.service_name,
  c.display_name,
  c.is_archived
FROM chat AS c
`

const syncChatsSQL = `
SELECT
  c.guid,
  c.chat_identifier,
  c.service_name,
  c.display_name,
  c.is_archived
FROM chat AS c
WHERE c.service_name = 'iMessage'
ORDER BY c.ROWID DESC;
`

const chatExistsSQL = `
SELECT 1
FROM chat
WHERE guid = ?
LIMIT 1;
`

const chatInfoSQL = `
SELECT guid, service_name
FROM chat
WHERE guid = ?
LIMIT 1;
`

const chatMessagesBaseSQL = `
SELECT
  m.guid,
  m.text,
  m.attributedBody,
  m.subject,
  m.service,
  m.date,
  m.date_read,
  m.date_delivered,
  m.is_from_me,
  m.is_read,
  m.is_delivered,
  m.cache_has_attachments,
  h.id AS handle_id_value,
  h.service AS handle_service
FROM message AS m
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
WHERE c.guid = ?
`

// syncMessagesBaseCols are the always-present columns for the new-message sync
// queries, in scan order. Semantic columns (capability-gated) are appended.
var syncMessagesBaseCols = []string{
	"c.guid AS chat_guid",
	"m.ROWID AS source_rowid",
	"m.guid",
	"m.text",
	"m.attributedBody",
	"m.subject",
	"m.service",
	"m.date",
	"m.date_read",
	"m.date_delivered",
	"m.is_from_me",
	"m.is_read",
	"m.is_delivered",
	"m.cache_has_attachments",
	"h.id AS handle_id_value",
	"h.service AS handle_service",
}

const syncMessagesFromWhere = `
FROM message AS m
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
WHERE c.service_name = 'iMessage'
  AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)
`

// buildSyncMessagesSQL assembles a new-message sync query with capability-gated
// semantic columns appended, plus the caller's extra WHERE and ORDER/LIMIT tail.
func buildSyncMessagesSQL(present []string, extraWhere, tail string) string {
	return "SELECT DISTINCT\n  " + strings.Join(syncMessagesBaseCols, ",\n  ") +
		semanticSelectFragment(present) + syncMessagesFromWhere + extraWhere + tail
}

// scanSyncRowSemantic scans the base sync columns plus the present semantic
// columns into a MessageRow and semanticValues.
func scanSyncRowSemantic(rows *sql.Rows, present []string) (MessageRow, semanticValues, error) {
	var row MessageRow
	var isFromMe, isRead, isDelivered, hasAttachments int64
	base := []any{
		&row.ChatGUID, &row.SourceRowID, &row.GUID, &row.Text, &row.AttributedBody,
		&row.Subject, &row.Service, &row.DateRaw, &row.DateReadRaw, &row.DateDeliveredRaw,
		&isFromMe, &isRead, &isDelivered, &hasAttachments, &row.HandleValue, &row.HandleService,
	}
	semTargets, finalize := semanticScanTargets(present)
	if err := rows.Scan(append(base, semTargets...)...); err != nil {
		return MessageRow{}, semanticValues{}, fmt.Errorf("scan sync message row: %w", err)
	}
	row.IsFromMe = isFromMe != 0
	row.IsRead = isRead != 0
	row.IsDelivered = isDelivered != 0
	row.CacheHasAttachments = hasAttachments != 0
	return row, finalize(), nil
}

// applySemantic copies parsed semantic values onto a SyncMessageRow.
func applySemantic(m *SyncMessageRow, s semanticValues) {
	m.AssociatedMessageType = s.AssociatedType
	m.AssociatedMessageGUID = s.AssociatedGUID
	m.ThreadOriginatorGUID = s.ThreadOriginatorGUID
	m.ItemType = s.ItemType
	m.GroupActionType = s.GroupActionType
	m.GroupTitle = s.GroupTitle
	m.BalloonBundleID = s.BalloonBundleID
	m.ExpressiveSendStyleID = s.ExpressiveSendStyleID
	m.PayloadDataPresent = s.PayloadDataPresent
}

type Queries struct {
	db *sql.DB
	// messageColumns is the set of available chat.db `message` columns, used to
	// capability-gate the BlueBubbles-compatible semantic columns (associated_*,
	// item_type, …). nil = base behavior (no optional columns selected).
	messageColumns map[string]bool
}

// SetMessageColumns wires the probed chat.db `message` column set so reads can
// select version-sensitive semantic columns only when present. Safe to call
// with nil (degrades to base columns).
func (q *Queries) SetMessageColumns(cols map[string]bool) { q.messageColumns = cols }

// semanticMessageColumns are the BlueBubbles-compatible chat.db columns carried
// into MessageJSON when present, in a fixed append order.
var semanticMessageColumns = []string{
	"associated_message_type",
	"associated_message_guid",
	"thread_originator_guid",
	"item_type",
	"group_action_type",
	"group_title",
	"balloon_bundle_id",
	"expressive_send_style_id",
	"payload_data",
}

// semanticValues holds the parsed optional semantic columns for one row.
type semanticValues struct {
	AssociatedType        *int64
	AssociatedGUID        *string
	ThreadOriginatorGUID  *string
	ItemType              *int64
	GroupActionType       *int64
	GroupTitle            *string
	BalloonBundleID       *string
	ExpressiveSendStyleID *string
	PayloadDataPresent    bool
}

func presentSemanticColumns(cols map[string]bool) []string {
	out := make([]string, 0, len(semanticMessageColumns))
	for _, c := range semanticMessageColumns {
		if cols[c] {
			out = append(out, c)
		}
	}
	return out
}

// semanticSelectFragment returns the ",\n  m.col" SQL fragment for present cols.
func semanticSelectFragment(present []string) string {
	if len(present) == 0 {
		return ""
	}
	parts := make([]string, len(present))
	for i, c := range present {
		parts[i] = "m." + c
	}
	return ",\n  " + strings.Join(parts, ",\n  ")
}

// semanticScanTargets builds scan holders for the present columns and returns a
// finalizer that materializes them into semanticValues after Scan.
func semanticScanTargets(present []string) (targets []any, finalize func() semanticValues) {
	intH := map[string]*sql.NullInt64{}
	strH := map[string]*sql.NullString{}
	var payload []byte
	for _, name := range present {
		switch name {
		case "associated_message_guid", "thread_originator_guid", "group_title",
			"balloon_bundle_id", "expressive_send_style_id":
			h := &sql.NullString{}
			strH[name] = h
			targets = append(targets, h)
		case "payload_data":
			targets = append(targets, &payload)
		default: // associated_message_type, item_type, group_action_type
			h := &sql.NullInt64{}
			intH[name] = h
			targets = append(targets, h)
		}
	}
	finalize = func() semanticValues {
		return semanticValues{
			AssociatedType:        nullInt(intH["associated_message_type"]),
			ItemType:              nullInt(intH["item_type"]),
			GroupActionType:       nullInt(intH["group_action_type"]),
			AssociatedGUID:        nullStr(strH["associated_message_guid"]),
			ThreadOriginatorGUID:  nullStr(strH["thread_originator_guid"]),
			GroupTitle:            nullStr(strH["group_title"]),
			BalloonBundleID:       nullStr(strH["balloon_bundle_id"]),
			ExpressiveSendStyleID: nullStr(strH["expressive_send_style_id"]),
			PayloadDataPresent:    len(payload) > 0,
		}
	}
	return targets, finalize
}

const attachmentBaseSelect = `
SELECT
  a.guid,
  m.guid AS message_guid,
  a.filename,
  a.mime_type,
  a.transfer_name,
  a.total_bytes,
  a.filename AS local_path,
  a.is_outgoing,
  a.hide_attachment,
  a.created_date,
  a.uti,
  a.is_sticker
FROM attachment AS a
JOIN message_attachment_join AS maj
  ON maj.attachment_id = a.ROWID
JOIN message AS m
  ON m.ROWID = maj.message_id
`

func NewQueries(db *sql.DB) *Queries {
	return &Queries{db: db}
}

func (q *Queries) ListRecentMessages(ctx context.Context, limit, offset int, service string, includeEmpty bool) ([]MessageJSON, error) {
	sqlText, args := buildRecentMessagesQuery(limit, offset, service, includeEmpty)

	rows, err := q.db.QueryContext(ctx, sqlText, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	messages, err := scanMessages(rows, includeEmpty)
	if err != nil {
		return nil, err
	}

	return q.attachMessageAttachments(ctx, messages)
}

// ListChats (chat.db direct mode). includeDebug is accepted for interface
// parity; the live chat.db path does not compute the renderable aggregate, so
// it never hides chats (HasRenderableMessages defaults true to avoid hiding).
func (q *Queries) ListChats(ctx context.Context, limit, offset int, withArchived bool, service string, includeDebug bool) ([]ChatJSON, error) {
	_ = includeDebug
	sqlText, args := buildChatsQuery(limit, offset, withArchived, service)

	rows, err := q.db.QueryContext(ctx, sqlText, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var chats []ChatJSON
	for rows.Next() {
		var row ChatRow
		if err := rows.Scan(
			&row.GUID,
			&row.ChatIdentifier,
			&row.ServiceName,
			&row.DisplayName,
			&row.IsArchived,
		); err != nil {
			return nil, err
		}

		chats = append(chats, ChatJSON{
			GUID:                  row.GUID,
			ChatIdentifier:        row.ChatIdentifier,
			ServiceName:           row.ServiceName,
			DisplayName:           row.DisplayName,
			IsArchived:            row.IsArchived,
			HasRenderableMessages: true,
		})
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return chats, nil
}

func (q *Queries) ChatExists(ctx context.Context, guid string) (bool, error) {
	var one int
	err := q.db.QueryRowContext(ctx, chatExistsSQL, guid).Scan(&one)
	if err == nil {
		return true, nil
	}
	if err == sql.ErrNoRows {
		return false, nil
	}
	return false, err
}

func (q *Queries) GetChatInfo(ctx context.Context, guid string) (*ChatInfo, error) {
	var info ChatInfo
	err := q.db.QueryRowContext(ctx, chatInfoSQL, guid).Scan(&info.GUID, &info.ServiceName)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &info, nil
}

func (q *Queries) ListChatMessages(ctx context.Context, guid string, limit, offset int, includeEmpty bool) ([]MessageJSON, error) {
	sqlText, args := buildChatMessagesQuery(guid, limit, offset, includeEmpty)

	rows, err := q.db.QueryContext(ctx, sqlText, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	messages, err := scanMessages(rows, includeEmpty)
	if err != nil {
		return nil, err
	}

	return q.attachMessageAttachments(ctx, messages)
}

func (q *Queries) FindOutgoingMessageMatch(ctx context.Context, guid string, normalizedText string, sentAtUnixMilli int64, excludedGUIDs map[string]struct{}) (*MessageJSON, error) {
	rows, err := q.db.QueryContext(ctx, `
SELECT
  m.guid,
  m.text,
  m.attributedBody,
  m.subject,
  m.service,
  m.date,
  m.date_read,
  m.date_delivered,
  m.is_from_me,
  m.is_read,
  m.is_delivered,
  m.cache_has_attachments,
  h.id AS handle_id_value,
  h.service AS handle_service
FROM message AS m
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
WHERE c.guid = ?
  AND m.is_from_me = 1
ORDER BY m.date DESC
LIMIT 100;
`, guid)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		row, err := scanMessageRow(rows)
		if err != nil {
			return nil, err
		}
		json := rowToMessageJSON(row)
		if json.DateCreated == nil || *json.DateCreated < sentAtUnixMilli {
			continue
		}
		if _, skip := excludedGUIDs[json.GUID]; skip {
			continue
		}
		if send.NormalizeText(stringValue(json.Text)) == normalizedText {
			AnnotateMessageJSON(&json)
			return &json, nil
		}
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return nil, nil
}

// FindOutgoingMessageError looks for an outgoing message in the chat that
// matches the just-sent text/time AND carries a non-zero message.error, so the
// send path can fail fast instead of waiting out the timeout (v0.11.x §2). It
// references the m.error column, so callers MUST only invoke it when
// SchemaCapabilities.SendError is true. Returns (errorCode, found, err).
func (q *Queries) FindOutgoingMessageError(ctx context.Context, guid string, normalizedText string, sentAtUnixMilli int64) (int64, bool, error) {
	rows, err := q.db.QueryContext(ctx, `
SELECT
  m.text,
  m.attributedBody,
  m.date,
  m.error
FROM message AS m
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
WHERE c.guid = ?
  AND m.is_from_me = 1
  AND m.error != 0
ORDER BY m.date DESC
LIMIT 100;
`, guid)
	if err != nil {
		return 0, false, err
	}
	defer rows.Close()

	for rows.Next() {
		var (
			text           *string
			attributedBody []byte
			dateRaw        int64
			errorCode      int64
		)
		if err := rows.Scan(&text, &attributedBody, &dateRaw, &errorCode); err != nil {
			return 0, false, err
		}
		created := timeutil.AppleMicrosToUnixMilli(dateRaw)
		if created == nil || *created < sentAtUnixMilli {
			continue
		}
		resolved := ExtractMessageText(text, attributedBody)
		if send.NormalizeText(stringValue(resolved)) == normalizedText {
			return errorCode, true, nil
		}
	}
	if err := rows.Err(); err != nil {
		return 0, false, err
	}
	return 0, false, nil
}

func (q *Queries) ListSyncChats(ctx context.Context) ([]SyncChatRow, error) {
	rows, err := q.db.QueryContext(ctx, syncChatsSQL)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var chats []SyncChatRow
	for rows.Next() {
		var row SyncChatRow
		if err := rows.Scan(
			&row.GUID,
			&row.ChatIdentifier,
			&row.ServiceName,
			&row.DisplayName,
			&row.IsArchived,
		); err != nil {
			return nil, err
		}
		chats = append(chats, row)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return chats, nil
}

func (q *Queries) ListSyncRecentMessages(ctx context.Context, limit int) ([]SyncMessageRow, error) {
	present := presentSemanticColumns(q.messageColumns)
	sqlText := buildSyncMessagesSQL(present, "", "ORDER BY m.date DESC\nLIMIT ?;\n")
	rows, err := q.db.QueryContext(ctx, sqlText, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []SyncMessageRow
	for rows.Next() {
		row, sem, err := scanSyncRowSemantic(rows, present)
		if err != nil {
			return nil, err
		}
		if row.ChatGUID == nil {
			continue
		}
		text := ExtractMessageText(row.Text, row.AttributedBody)
		if !MessageHasRenderableContent(text, row.CacheHasAttachments) {
			continue
		}

		msg := SyncMessageRow{
			ChatGUID:            *row.ChatGUID,
			SourceRowID:         derefInt64(row.SourceRowID),
			GUID:                row.GUID,
			Text:                text,
			Subject:             row.Subject,
			Service:             row.Service,
			DateCreated:         timeutil.AppleMicrosToUnixMilli(row.DateRaw),
			DateRead:            timeutil.AppleMicrosToUnixMilliPtr(row.DateReadRaw),
			DateDelivered:       timeutil.AppleMicrosToUnixMilliPtr(row.DateDeliveredRaw),
			IsFromMe:            row.IsFromMe,
			IsRead:              row.IsRead,
			IsDelivered:         row.IsDelivered,
			HandleID:            row.HandleValue,
			HandleService:       row.HandleService,
			CacheHasAttachments: row.CacheHasAttachments,
			HasAttributedBody:   len(row.AttributedBody) > 0,
		}
		applySemantic(&msg, sem)
		messages = append(messages, msg)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return messages, nil
}

// ListSyncRecentMessagesByDate returns renderable messages created on/after
// [afterUnixMilli], newest first, up to [limit] (C11 bounded date lookback).
// Unlike the ROWID query, this is resilient to WAL/rowid races: it re-scans a
// recent window every sync so a row the rowid watermark skipped is recovered.
// `message.date` is indexed, so the scan is cheap.
func (q *Queries) ListSyncRecentMessagesByDate(ctx context.Context, afterUnixMilli int64, limit int) ([]SyncMessageRow, error) {
	present := presentSemanticColumns(q.messageColumns)
	sqlText := buildSyncMessagesSQL(present, "  AND m.date >= ?\n", "ORDER BY m.date DESC\nLIMIT ?;\n")
	afterApple := timeutil.UnixMilliToAppleNanos(afterUnixMilli)
	rows, err := q.db.QueryContext(ctx, sqlText, afterApple, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []SyncMessageRow
	for rows.Next() {
		row, sem, err := scanSyncRowSemantic(rows, present)
		if err != nil {
			return nil, err
		}
		if row.ChatGUID == nil || row.SourceRowID == nil {
			continue
		}
		text := ExtractMessageText(row.Text, row.AttributedBody)
		if !MessageHasRenderableContent(text, row.CacheHasAttachments) {
			continue
		}
		msg := SyncMessageRow{
			ChatGUID:            *row.ChatGUID,
			SourceRowID:         *row.SourceRowID,
			GUID:                row.GUID,
			Text:                text,
			Subject:             row.Subject,
			Service:             row.Service,
			DateCreated:         timeutil.AppleMicrosToUnixMilli(row.DateRaw),
			DateRead:            timeutil.AppleMicrosToUnixMilliPtr(row.DateReadRaw),
			DateDelivered:       timeutil.AppleMicrosToUnixMilliPtr(row.DateDeliveredRaw),
			IsFromMe:            row.IsFromMe,
			IsRead:              row.IsRead,
			IsDelivered:         row.IsDelivered,
			HandleID:            row.HandleValue,
			HandleService:       row.HandleService,
			CacheHasAttachments: row.CacheHasAttachments,
			HasAttributedBody:   len(row.AttributedBody) > 0,
		}
		applySemantic(&msg, sem)
		messages = append(messages, msg)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return messages, nil
}

func (q *Queries) ListSyncRecentMessagesSince(ctx context.Context, afterRowID int64, limit int) ([]SyncMessageRow, error) {
	present := presentSemanticColumns(q.messageColumns)
	sqlText := buildSyncMessagesSQL(present, "  AND m.ROWID > ?\n", "ORDER BY m.ROWID ASC\nLIMIT ?;\n")
	rows, err := q.db.QueryContext(ctx, sqlText, afterRowID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []SyncMessageRow
	for rows.Next() {
		row, sem, err := scanSyncRowSemantic(rows, present)
		if err != nil {
			return nil, err
		}
		if row.ChatGUID == nil || row.SourceRowID == nil {
			continue
		}
		text := ExtractMessageText(row.Text, row.AttributedBody)
		if !MessageHasRenderableContent(text, row.CacheHasAttachments) {
			continue
		}

		msg := SyncMessageRow{
			ChatGUID:            *row.ChatGUID,
			SourceRowID:         *row.SourceRowID,
			GUID:                row.GUID,
			Text:                text,
			Subject:             row.Subject,
			Service:             row.Service,
			DateCreated:         timeutil.AppleMicrosToUnixMilli(row.DateRaw),
			DateRead:            timeutil.AppleMicrosToUnixMilliPtr(row.DateReadRaw),
			DateDelivered:       timeutil.AppleMicrosToUnixMilliPtr(row.DateDeliveredRaw),
			IsFromMe:            row.IsFromMe,
			IsRead:              row.IsRead,
			IsDelivered:         row.IsDelivered,
			HandleID:            row.HandleValue,
			HandleService:       row.HandleService,
			CacheHasAttachments: row.CacheHasAttachments,
			HasAttributedBody:   len(row.AttributedBody) > 0,
		}
		applySemantic(&msg, sem)
		messages = append(messages, msg)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return messages, nil
}

// ListMessageUpdatesSince returns iMessage rows whose creation date falls within
// the lookback window (afterUnixMilli, using the indexed message.date column), so
// the v0.11.x update pass can detect mutable-state changes. Version-sensitive
// columns (date_edited, date_retracted, error) are selected ONLY when caps allow,
// so missing columns never cause a query error. Unlike the new-message queries,
// this does NOT apply a renderable-content filter, so retracted/edited (possibly
// empty) rows are still returned.
func (q *Queries) ListMessageUpdatesSince(ctx context.Context, afterUnixMilli int64, limit int, caps SchemaCapabilities) ([]MessageUpdateRow, error) {
	cols := []string{
		"c.guid AS chat_guid",
		"m.guid",
		"m.text",
		"m.attributedBody",
		"m.subject",
		"m.service",
		"m.date",
		"m.date_read",
		"m.date_delivered",
		"m.is_from_me",
		"m.is_read",
		"m.is_delivered",
		"m.cache_has_attachments",
		"h.id AS handle_id_value",
		"h.service AS handle_service",
	}
	// Optional, capability-gated columns appended in a fixed order.
	if caps.EditedMessages {
		cols = append(cols, "m.date_edited")
	}
	if caps.UnsentMessages {
		cols = append(cols, "m.date_retracted")
	}
	if caps.SendError {
		cols = append(cols, "m.error")
	}

	sqlText := "SELECT DISTINCT\n  " + strings.Join(cols, ",\n  ") + `
FROM message AS m
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
WHERE c.service_name = 'iMessage'
  AND m.date >= ?
ORDER BY m.date ASC
LIMIT ?;`

	afterApple := timeutil.UnixMilliToAppleNanos(afterUnixMilli)
	rows, err := q.db.QueryContext(ctx, sqlText, afterApple, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var updates []MessageUpdateRow
	for rows.Next() {
		// Base scan targets.
		var (
			chatGUID                        *string
			guid                            string
			text                            *string
			attributedBody                  []byte
			subject, service                *string
			dateRaw                         int64
			dateReadRaw, dateDeliveredRaw   *int64
			isFromMe, isRead, isDelivered   int64
			hasAttachments                  int64
			handleValue, handleService      *string
			dateEditedRaw, dateRetractedRaw *int64
			errorCode                       sql.NullInt64
		)
		targets := []any{
			&chatGUID, &guid, &text, &attributedBody, &subject, &service, &dateRaw,
			&dateReadRaw, &dateDeliveredRaw, &isFromMe, &isRead, &isDelivered,
			&hasAttachments, &handleValue, &handleService,
		}
		if caps.EditedMessages {
			targets = append(targets, &dateEditedRaw)
		}
		if caps.UnsentMessages {
			targets = append(targets, &dateRetractedRaw)
		}
		if caps.SendError {
			targets = append(targets, &errorCode)
		}
		if err := rows.Scan(targets...); err != nil {
			return nil, fmt.Errorf("scan message update row: %w", err)
		}
		if chatGUID == nil {
			continue
		}

		updates = append(updates, MessageUpdateRow{
			GUID:                guid,
			ChatGUID:            *chatGUID,
			Text:                ExtractMessageText(text, attributedBody),
			Subject:             subject,
			Service:             service,
			DateCreated:         timeutil.AppleMicrosToUnixMilli(dateRaw),
			DateRead:            timeutil.AppleMicrosToUnixMilliPtr(dateReadRaw),
			DateDelivered:       timeutil.AppleMicrosToUnixMilliPtr(dateDeliveredRaw),
			DateEdited:          timeutil.AppleMicrosToUnixMilliPtr(dateEditedRaw),
			DateRetracted:       timeutil.AppleMicrosToUnixMilliPtr(dateRetractedRaw),
			ErrorCode:           errorCode.Int64,
			IsFromMe:            isFromMe != 0,
			IsRead:              isRead != 0,
			IsDelivered:         isDelivered != 0,
			HandleID:            handleValue,
			HandleService:       handleService,
			CacheHasAttachments: hasAttachments != 0,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return updates, nil
}

func (q *Queries) ListSyncAttachmentsForMessages(ctx context.Context, messageGUIDs []string) ([]SyncAttachmentRow, error) {
	if len(messageGUIDs) == 0 {
		return nil, nil
	}

	sqlText, args := buildMessageAttachmentsQuery(messageGUIDs)
	rows, err := q.db.QueryContext(ctx, sqlText, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var attachments []SyncAttachmentRow
	for rows.Next() {
		row, err := scanAttachmentRow(rows)
		if err != nil {
			return nil, err
		}
		attachments = append(attachments, SyncAttachmentRow{
			GUID:           row.GUID,
			MessageGUID:    row.MessageGUID,
			Filename:       row.Filename,
			MimeType:       row.MimeType,
			TransferName:   row.TransferName,
			TotalBytes:     row.TotalBytes,
			LocalPath:      row.LocalPath,
			IsOutgoing:     row.IsOutgoing,
			HideAttachment: row.HideAttachment,
			CreatedAt:      timeutil.AppleMicrosToUnixMilliPtr(row.CreatedRaw),
			Uti:            row.Uti,
			IsSticker:      row.IsSticker,
		})
	}

	return attachments, rows.Err()
}

func scanMessages(rows *sql.Rows, includeEmpty bool) ([]MessageJSON, error) {
	var messages []MessageJSON
	for rows.Next() {
		row, err := scanMessageRow(rows)
		if err != nil {
			return nil, err
		}
		message := rowToMessageJSON(row)
		if !includeEmpty && !MessageHasRenderableContent(message.Text, message.CacheHasAttachments) {
			continue
		}
		messages = append(messages, message)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return messages, nil
}

func scanMessageRow(rows *sql.Rows) (MessageRow, error) {
	var row MessageRow
	var isFromMe, isRead, isDelivered, hasAttachments int64

	err := rows.Scan(
		&row.GUID,
		&row.Text,
		&row.AttributedBody,
		&row.Subject,
		&row.Service,
		&row.DateRaw,
		&row.DateReadRaw,
		&row.DateDeliveredRaw,
		&isFromMe,
		&isRead,
		&isDelivered,
		&hasAttachments,
		&row.HandleValue,
		&row.HandleService,
	)
	if err != nil {
		return MessageRow{}, fmt.Errorf("scan message row: %w", err)
	}

	row.IsFromMe = isFromMe != 0
	row.IsRead = isRead != 0
	row.IsDelivered = isDelivered != 0
	row.CacheHasAttachments = hasAttachments != 0
	return row, nil
}

func derefInt64(v *int64) int64 {
	if v == nil {
		return 0
	}
	return *v
}

func rowToMessageJSON(row MessageRow) MessageJSON {
	var handle *HandleJSON
	if row.HandleValue != nil {
		handle = &HandleJSON{
			ID:      *row.HandleValue,
			Service: row.HandleService,
		}
	}

	return MessageJSON{
		GUID:                row.GUID,
		Text:                ExtractMessageText(row.Text, row.AttributedBody),
		Subject:             row.Subject,
		Service:             row.Service,
		DateCreated:         timeutil.AppleMicrosToUnixMilli(row.DateRaw),
		DateRead:            timeutil.AppleMicrosToUnixMilliPtr(row.DateReadRaw),
		DateDelivered:       timeutil.AppleMicrosToUnixMilliPtr(row.DateDeliveredRaw),
		IsFromMe:            row.IsFromMe,
		IsRead:              row.IsRead,
		IsDelivered:         row.IsDelivered,
		Handle:              handle,
		CacheHasAttachments: row.CacheHasAttachments,
		HasAttributedBody:   len(row.AttributedBody) > 0,
	}
}

func buildRecentMessagesQuery(limit, offset int, service string, includeEmpty bool) (string, []any) {
	sqlText := recentMessagesBaseSQL
	args := make([]any, 0, 3)

	clauses := make([]string, 0, 2)
	if !includeEmpty {
		clauses = append(clauses, "(m.text IS NOT NULL OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)")
	}

	if service != "all" {
		sqlText += `
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
`
		clauses = append(clauses, "c.service_name = ?")
		args = append(args, service)
	}

	if len(clauses) > 0 {
		sqlText += "WHERE " + joinClauses(clauses) + "\n"
	}

	sqlText += "ORDER BY m.date DESC\nLIMIT ? OFFSET ?;\n"
	args = append(args, limit, offset)
	return sqlText, args
}

func buildChatsQuery(limit, offset int, withArchived bool, service string) (string, []any) {
	sqlText := chatsBaseSQL
	args := make([]any, 0, 3)
	clauses := make([]string, 0, 2)

	if !withArchived {
		clauses = append(clauses, "c.is_archived = 0")
	}
	if service != "all" {
		clauses = append(clauses, "c.service_name = ?")
		args = append(args, service)
	}

	if len(clauses) > 0 {
		sqlText += "WHERE " + joinClauses(clauses) + "\n"
	}

	sqlText += "ORDER BY c.ROWID DESC\nLIMIT ? OFFSET ?;\n"
	args = append(args, limit, offset)
	return sqlText, args
}

func buildChatMessagesQuery(guid string, limit, offset int, includeEmpty bool) (string, []any) {
	sqlText := chatMessagesBaseSQL
	args := []any{guid}

	if !includeEmpty {
		sqlText += "AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)\n"
	}

	sqlText += "ORDER BY m.date DESC\nLIMIT ? OFFSET ?;\n"
	args = append(args, limit, offset)
	return sqlText, args
}

func joinClauses(clauses []string) string {
	result := clauses[0]
	for i := 1; i < len(clauses); i++ {
		result += " AND " + clauses[i]
	}
	return result
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

type attachmentRow struct {
	GUID           string
	MessageGUID    string
	Filename       *string
	MimeType       *string
	TransferName   *string
	TotalBytes     int64
	LocalPath      *string
	IsOutgoing     bool
	HideAttachment bool
	CreatedRaw     *int64
	Uti            *string
	IsSticker      bool
}

func scanAttachmentRow(rows *sql.Rows) (attachmentRow, error) {
	var row attachmentRow
	var isOutgoing, hideAttachment int64
	var isSticker sql.NullInt64
	err := rows.Scan(
		&row.GUID,
		&row.MessageGUID,
		&row.Filename,
		&row.MimeType,
		&row.TransferName,
		&row.TotalBytes,
		&row.LocalPath,
		&isOutgoing,
		&hideAttachment,
		&row.CreatedRaw,
		&row.Uti,
		&isSticker,
	)
	if err != nil {
		return attachmentRow{}, fmt.Errorf("scan attachment row: %w", err)
	}
	row.IsOutgoing = isOutgoing != 0
	row.HideAttachment = hideAttachment != 0
	row.IsSticker = isSticker.Valid && isSticker.Int64 != 0
	return row, nil
}

func (q *Queries) attachMessageAttachments(ctx context.Context, messages []MessageJSON) ([]MessageJSON, error) {
	if len(messages) == 0 {
		return messages, nil
	}

	guids := make([]string, 0, len(messages))
	for _, message := range messages {
		guids = append(guids, message.GUID)
	}

	attachments, err := q.ListSyncAttachmentsForMessages(ctx, guids)
	if err != nil {
		return nil, err
	}

	grouped := make(map[string][]AttachmentJSON, len(messages))
	for _, attachment := range attachments {
		item := AttachmentJSON{
			GUID:         attachment.GUID,
			Filename:     attachment.Filename,
			MimeType:     attachment.MimeType,
			TransferName: attachment.TransferName,
			TotalBytes:   attachment.TotalBytes,
			DownloadURL:  "/api/attachments/" + attachment.GUID,
			Uti:          attachment.Uti,
			IsSticker:    attachment.IsSticker,
		}
		DecorateAttachmentJSON(&item)
		if item.NeedsPreviewConversion {
			item.PreviewURL = "/api/attachments/" + item.GUID + "/preview"
		}
		grouped[attachment.MessageGUID] = append(grouped[attachment.MessageGUID], item)
	}

	for i := range messages {
		messages[i].Attachments = grouped[messages[i].GUID]
		if messages[i].Attachments == nil {
			messages[i].Attachments = []AttachmentJSON{}
		}
		AnnotateMessageJSON(&messages[i])
	}

	return messages, nil
}

func buildMessageAttachmentsQuery(messageGUIDs []string) (string, []any) {
	placeholders := make([]string, len(messageGUIDs))
	args := make([]any, len(messageGUIDs))
	for i, guid := range messageGUIDs {
		placeholders[i] = "?"
		args[i] = guid
	}

	return attachmentBaseSelect +
		"WHERE m.guid IN (" + strings.Join(placeholders, ", ") + ")\n" +
		"ORDER BY a.created_date ASC, a.ROWID ASC;\n", args
}
