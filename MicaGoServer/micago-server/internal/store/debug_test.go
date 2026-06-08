package store

import (
	"context"
	"testing"
)

// modernChatDB builds a writable chat.db-like schema with the optional iMessage
// columns the inspector gates on, plus a couple of rows + one attachment.
func modernChatDB(t *testing.T) *Queries {
	t.Helper()
	db := newSchemaDB(t,
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY,
			guid TEXT, text TEXT, attributedBody BLOB, subject TEXT, service TEXT,
			date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER,
			cache_has_attachments INTEGER, handle_id INTEGER,
			associated_message_type INTEGER, associated_message_guid TEXT,
			item_type INTEGER, group_action_type INTEGER, group_title TEXT,
			balloon_bundle_id TEXT, expressive_send_style_id TEXT,
			payload_data BLOB, error INTEGER, account TEXT
		)`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)`,
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, service_name TEXT, display_name TEXT, is_archived INTEGER)`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)`,
		`CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER, is_outgoing INTEGER, hide_attachment INTEGER, created_date INTEGER, uti TEXT, is_sticker INTEGER)`,
		`CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER)`,

		`INSERT INTO handle (ROWID, id, service) VALUES (1, '+15550001', 'iMessage')`,
		`INSERT INTO chat (ROWID, guid, chat_identifier, service_name, display_name, is_archived) VALUES (1, 'cA', '+15550001', 'iMessage', 'Alice', 0)`,

		// Plain text incoming.
		`INSERT INTO message (ROWID, guid, text, date, is_from_me, handle_id, item_type, group_action_type, associated_message_type)
		   VALUES (10, 'm-text', 'Hello', 100, 0, 1, 0, 0, 0)`,
		// Reaction (associated type set).
		`INSERT INTO message (ROWID, guid, text, date, is_from_me, handle_id, associated_message_type, associated_message_guid)
		   VALUES (11, 'm-react', NULL, 200, 0, 1, 2000, 'p:0/m-text')`,
		// Attachment-only.
		`INSERT INTO message (ROWID, guid, text, date, is_from_me, handle_id, cache_has_attachments)
		   VALUES (12, 'm-img', NULL, 300, 0, 1, 1)`,

		`INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 10), (1, 11), (1, 12)`,
		`INSERT INTO attachment (ROWID, guid, filename, mime_type, transfer_name, total_bytes, is_outgoing, hide_attachment, uti, is_sticker)
		   VALUES (1, 'att-1', '/Users/me/img.png', 'image/png', 'img.png', 1234, 0, 0, 'public.png', 0)`,
		`INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (12, 1)`,
	)
	return NewQueries(db)
}

func columnsOf(t *testing.T, q *Queries) map[string]bool {
	t.Helper()
	cols, err := ProbeMessageColumns(context.Background(), q.db)
	if err != nil {
		t.Fatalf("probe columns: %v", err)
	}
	return cols
}

func TestListDebugRecentMessagesModern(t *testing.T) {
	q := modernChatDB(t)
	cols := columnsOf(t, q)

	rows, err := q.ListDebugRecentMessages(context.Background(), DebugListOptions{}, cols)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("expected 3 rows, got %d", len(rows))
	}
	// Newest first by date.
	if rows[0].GUID != "m-img" || rows[2].GUID != "m-text" {
		t.Fatalf("unexpected order: %s..%s", rows[0].GUID, rows[2].GUID)
	}

	// Optional columns scanned: reaction row carries the associated type.
	var react DebugMessageJSON
	for _, r := range rows {
		if r.GUID == "m-react" {
			react = r
		}
	}
	if react.AssociatedMessageType == nil || *react.AssociatedMessageType != 2000 {
		t.Fatalf("expected associatedMessageType 2000, got %v", react.AssociatedMessageType)
	}

	// Attachment attached, decorated, and path-free.
	var img DebugMessageJSON
	for _, r := range rows {
		if r.GUID == "m-img" {
			img = r
		}
	}
	if len(img.Attachments) != 1 {
		t.Fatalf("expected 1 attachment, got %d", len(img.Attachments))
	}
	a := img.Attachments[0]
	if a.AttachmentKind != AttachmentKindImage {
		t.Fatalf("attachment kind = %q, want image", a.AttachmentKind)
	}
	if !a.HasDownloadURL {
		t.Fatalf("expected hasDownloadUrl true")
	}
}

func TestListDebugRecentMessagesFiltersDirectionAndSender(t *testing.T) {
	q := modernChatDB(t)
	cols := columnsOf(t, q)

	rows, err := q.ListDebugRecentMessages(context.Background(),
		DebugListOptions{Sender: "+15550001", Direction: "incoming"}, cols)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("expected 3 incoming from sender, got %d", len(rows))
	}

	none, err := q.ListDebugRecentMessages(context.Background(),
		DebugListOptions{Direction: "outgoing"}, cols)
	if err != nil {
		t.Fatalf("list outgoing: %v", err)
	}
	if len(none) != 0 {
		t.Fatalf("expected 0 outgoing rows, got %d", len(none))
	}
}

func TestListDebugRecentMessagesLimitClamp(t *testing.T) {
	q := modernChatDB(t)
	cols := columnsOf(t, q)

	// Over-large and zero limits are clamped, not errors.
	if rows, err := q.ListDebugRecentMessages(context.Background(), DebugListOptions{Limit: 100000}, cols); err != nil {
		t.Fatalf("huge limit errored: %v", err)
	} else if len(rows) != 3 {
		t.Fatalf("huge limit returned %d rows, want 3", len(rows))
	}
	if rows, err := q.ListDebugRecentMessages(context.Background(), DebugListOptions{Limit: 1}, cols); err != nil {
		t.Fatalf("limit 1 errored: %v", err)
	} else if len(rows) != 1 {
		t.Fatalf("limit 1 returned %d rows, want 1", len(rows))
	}
}

// TestListDebugRecentMessagesOldSchema ensures the query degrades gracefully when
// the optional iMessage columns are absent (older macOS chat.db).
func TestListDebugRecentMessagesOldSchema(t *testing.T) {
	db := newSchemaDB(t,
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER,
			cache_has_attachments INTEGER, handle_id INTEGER
		)`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)`,
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, service_name TEXT, display_name TEXT, is_archived INTEGER)`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)`,
		`CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER, is_outgoing INTEGER, hide_attachment INTEGER, created_date INTEGER, uti TEXT, is_sticker INTEGER)`,
		`CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER)`,
		`INSERT INTO handle (ROWID, id) VALUES (1, '+15550009')`,
		`INSERT INTO chat (ROWID, guid, service_name) VALUES (1, 'cZ', 'iMessage')`,
		`INSERT INTO message (ROWID, guid, text, date, is_from_me, handle_id) VALUES (1, 'mZ', 'hi', 100, 0, 1)`,
		`INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1)`,
	)
	q := NewQueries(db)
	cols, err := ProbeMessageColumns(context.Background(), db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	rows, err := q.ListDebugRecentMessages(context.Background(), DebugListOptions{}, cols)
	if err != nil {
		t.Fatalf("old-schema list errored: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0].AssociatedMessageType != nil || rows[0].ItemType != nil {
		t.Fatalf("optional fields should be nil on old schema")
	}
}
