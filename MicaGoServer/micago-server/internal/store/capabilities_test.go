package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

// newSchemaDB creates a writable temp SQLite DB and runs the provided DDL.
func newSchemaDB(t *testing.T, ddl ...string) *sql.DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "chat.db")
	db, err := sql.Open("sqlite3", "file:"+path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	for _, stmt := range ddl {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("exec %q: %v", stmt, err)
		}
	}
	return db
}

func TestProbeCapabilitiesModernSchema(t *testing.T) {
	db := newSchemaDB(t,
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY,
			text TEXT, attributedBody BLOB,
			date INTEGER, date_read INTEGER, date_delivered INTEGER,
			date_edited INTEGER, date_retracted INTEGER,
			is_sent INTEGER, error INTEGER,
			item_type INTEGER, group_action_type INTEGER
		)`,
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT)`,
		`CREATE TABLE attachment (
			ROWID INTEGER PRIMARY KEY,
			guid TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER
		)`,
	)

	caps, err := ProbeCapabilities(context.Background(), db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	want := SchemaCapabilities{
		EditedMessages:     true,
		UnsentMessages:     true,
		ReadStatus:         true,
		DeliveredStatus:    true,
		SendError:          true,
		GroupActions:       true,
		AttachmentMetadata: true,
	}
	if caps != want {
		t.Fatalf("modern schema caps = %+v, want %+v", caps, want)
	}
}

func TestProbeCapabilitiesOldSchema(t *testing.T) {
	// Pre-edit/retract era: no date_edited/date_retracted/error/item_type,
	// and the attachment table lacks mime_type.
	db := newSchemaDB(t,
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY,
			text TEXT, attributedBody BLOB,
			date INTEGER, date_read INTEGER, date_delivered INTEGER
		)`,
		`CREATE TABLE attachment (
			ROWID INTEGER PRIMARY KEY,
			guid TEXT, transfer_name TEXT, total_bytes INTEGER
		)`,
	)

	caps, err := ProbeCapabilities(context.Background(), db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	want := SchemaCapabilities{
		EditedMessages:     false,
		UnsentMessages:     false,
		ReadStatus:         true,
		DeliveredStatus:    true,
		SendError:          false,
		GroupActions:       false,
		AttachmentMetadata: false, // mime_type missing
	}
	if caps != want {
		t.Fatalf("old schema caps = %+v, want %+v", caps, want)
	}
}

func TestProbeCapabilitiesPartialGroupActions(t *testing.T) {
	// item_type present but group_action_type missing -> GroupActions false.
	db := newSchemaDB(t,
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, date INTEGER, item_type INTEGER
		)`,
	)
	caps, err := ProbeCapabilities(context.Background(), db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if caps.GroupActions {
		t.Fatalf("expected GroupActions false when group_action_type missing")
	}
}

func TestProbeCapabilitiesMissingTablesDoNotCrash(t *testing.T) {
	// Empty database: no message/attachment tables at all.
	db := newSchemaDB(t)

	caps, err := ProbeCapabilities(context.Background(), db)
	if err != nil {
		t.Fatalf("probe on empty db should not error, got: %v", err)
	}
	if (caps != SchemaCapabilities{}) {
		t.Fatalf("expected all-false caps for empty db, got %+v", caps)
	}
}

func TestTableColumnsRejectsNonAllowlistedTable(t *testing.T) {
	db := newSchemaDB(t)
	if _, err := tableColumns(context.Background(), db, "sqlite_master; DROP"); err == nil {
		t.Fatalf("expected error for non-allowlisted table name")
	}
}
