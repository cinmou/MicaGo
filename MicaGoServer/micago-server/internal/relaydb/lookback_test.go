package relaydb

import (
	"context"
	"testing"
	"time"

	"micagoserver/internal/store"
)

// lookbackSource simulates chat.db: a ROWID query that (buggily) misses a row,
// and a date-window query that includes it — proving the C11 lookback recovers
// rows skipped by the ROWID watermark.
type lookbackSource struct {
	chats     []store.SyncChatRow
	sinceRows []store.SyncMessageRow // returned by the ROWID query
	dateRows  []store.SyncMessageRow // returned by the date-window query
	dateCalls int
}

func (s *lookbackSource) ListSyncChats(context.Context) ([]store.SyncChatRow, error) {
	return s.chats, nil
}
func (s *lookbackSource) ListSyncRecentMessages(context.Context, int) ([]store.SyncMessageRow, error) {
	return s.sinceRows, nil
}
func (s *lookbackSource) ListSyncRecentMessagesSince(context.Context, int64, int) ([]store.SyncMessageRow, error) {
	return s.sinceRows, nil
}
func (s *lookbackSource) ListSyncRecentMessagesByDate(context.Context, int64, int) ([]store.SyncMessageRow, error) {
	s.dateCalls++
	return s.dateRows, nil
}
func (s *lookbackSource) ListSyncAttachmentsForMessages(context.Context, []string) ([]store.SyncAttachmentRow, error) {
	return nil, nil
}

func TestDateLookbackRecoversRowMissedByRowid(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	// Seed a watermark so SyncOnce runs in incremental mode.
	if err := db.SetSyncState("last_message_rowid", "100"); err != nil {
		t.Fatalf("seed watermark: %v", err)
	}

	src := &lookbackSource{
		chats: []store.SyncChatRow{{GUID: "c", ServiceName: strp("iMessage")}},
		// ROWID query returns nothing new (the bug: row was skipped).
		sinceRows: nil,
		// Date window includes the missed row.
		dateRows: []store.SyncMessageRow{
			{ChatGUID: "c", SourceRowID: 90, GUID: "missed", Text: strp("recovered"), DateCreated: intp(1700)},
		},
	}

	res, err := SyncOnce(ctx, src, db, 200, 7*24*time.Hour)
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	if src.dateCalls != 1 {
		t.Fatalf("expected date-lookback to run once, got %d", src.dateCalls)
	}
	// The missed row is now inserted + broadcast as new.
	if len(res.NewMessages) != 1 || res.NewMessages[0].GUID != "missed" {
		t.Fatalf("expected recovered row in NewMessages, got %+v", res.NewMessages)
	}
	msgs, err := db.ListChatMessages(ctx, "c", 50, 0, false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(msgs) != 1 || msgs[0].GUID != "missed" {
		t.Fatalf("missed row not persisted: %+v", msgs)
	}
}

func TestDateLookbackIsIdempotent(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	_ = db.SetSyncState("last_message_rowid", "100")

	row := store.SyncMessageRow{ChatGUID: "c", SourceRowID: 90, GUID: "dup", Text: strp("hi"), DateCreated: intp(1700)}
	src := &lookbackSource{
		chats:    []store.SyncChatRow{{GUID: "c", ServiceName: strp("iMessage")}},
		dateRows: []store.SyncMessageRow{row},
	}

	first, _ := SyncOnce(ctx, src, db, 200, time.Hour)
	if len(first.NewMessages) != 1 {
		t.Fatalf("first sync should insert 1, got %d", len(first.NewMessages))
	}
	second, _ := SyncOnce(ctx, src, db, 200, time.Hour)
	if len(second.NewMessages) != 0 {
		t.Fatalf("second sync should re-broadcast nothing, got %d", len(second.NewMessages))
	}
}
