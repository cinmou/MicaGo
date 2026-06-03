package store

import (
	"context"
	"testing"
)

// chatDBCommonDDL returns the join/chat/handle tables shared by both schemas.
func chatDBCommonDDL() []string {
	return []string{
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, service_name TEXT)`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)`,
		`CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER)`,
		`INSERT INTO chat (ROWID, guid, service_name) VALUES (1, 'chat-1', 'iMessage')`,
		`INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1)`,
	}
}

func TestListMessageUpdatesSinceModernSchema(t *testing.T) {
	ddl := append([]string{
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER, cache_has_attachments INTEGER,
			handle_id INTEGER, date_edited INTEGER, date_retracted INTEGER, error INTEGER
		)`,
		// date ~ 7e17 ns since Apple epoch (a modern timestamp).
		`INSERT INTO message (ROWID, guid, text, date, date_read, is_from_me, is_read, is_delivered, cache_has_attachments, date_edited, error)
		 VALUES (1, 'm1', 'edited body', 700000000000000000, 0, 1, 0, 1, 0, 700000000000000001, 0)`,
	}, chatDBCommonDDL()...)
	db := newSchemaDB(t, ddl...)

	caps, err := ProbeCapabilities(context.Background(), db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if !caps.EditedMessages || !caps.UnsentMessages || !caps.SendError {
		t.Fatalf("expected edit/unsent/error caps true, got %+v", caps)
	}

	q := NewQueries(db)
	updates, err := q.ListMessageUpdatesSince(context.Background(), 0, 100, caps)
	if err != nil {
		t.Fatalf("ListMessageUpdatesSince: %v", err)
	}
	if len(updates) != 1 {
		t.Fatalf("expected 1 update row, got %d", len(updates))
	}
	if updates[0].GUID != "m1" || updates[0].ChatGUID != "chat-1" {
		t.Fatalf("unexpected row: %+v", updates[0])
	}
	if updates[0].DateEdited == nil {
		t.Fatalf("expected DateEdited populated on modern schema")
	}
}

func TestListMessageUpdatesSinceOldSchemaDoesNotCrash(t *testing.T) {
	// No date_edited / date_retracted / error columns at all.
	ddl := append([]string{
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER, cache_has_attachments INTEGER,
			handle_id INTEGER
		)`,
		`INSERT INTO message (ROWID, guid, text, date, is_from_me, is_read, is_delivered, cache_has_attachments)
		 VALUES (1, 'm1', 'hi', 700000000000000000, 1, 1, 1, 0)`,
	}, chatDBCommonDDL()...)
	db := newSchemaDB(t, ddl...)

	caps, err := ProbeCapabilities(context.Background(), db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if caps.EditedMessages || caps.UnsentMessages || caps.SendError {
		t.Fatalf("expected edit/unsent/error caps false on old schema, got %+v", caps)
	}

	q := NewQueries(db)
	// Must not reference missing columns -> must not error.
	updates, err := q.ListMessageUpdatesSince(context.Background(), 0, 100, caps)
	if err != nil {
		t.Fatalf("old-schema query should not crash, got: %v", err)
	}
	if len(updates) != 1 {
		t.Fatalf("expected 1 row, got %d", len(updates))
	}
	if updates[0].DateEdited != nil || updates[0].DateRetracted != nil {
		t.Fatalf("expected no edited/retracted data on old schema")
	}
	if !updates[0].IsRead {
		t.Fatalf("expected IsRead true from row")
	}
}

// guard: ensure the query handles an empty result set cleanly.
func TestListMessageUpdatesSinceNoRows(t *testing.T) {
	ddl := append([]string{
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER, cache_has_attachments INTEGER, handle_id INTEGER
		)`,
	}, chatDBCommonDDL()...)
	db := newSchemaDB(t, ddl...)
	caps, _ := ProbeCapabilities(context.Background(), db)
	q := NewQueries(db)
	updates, err := q.ListMessageUpdatesSince(context.Background(), 0, 100, caps)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(updates) != 0 {
		t.Fatalf("expected 0 rows, got %d", len(updates))
	}
}
