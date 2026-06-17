package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

// C21: the delta endpoint is the catch-up correctness path. It returns
// renderable messages newer than the cursor, the affected chats, and an
// advancing cursor so nothing is missed and quiet periods don't re-scan.
func TestListMessagesSinceDelta(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{
			{GUID: "chatA", ServiceName: strp("iMessage")},
			{GUID: "chatB", ServiceName: strp("iMessage")},
		},
		messages: []store.SyncMessageRow{
			{ChatGUID: "chatA", SourceRowID: 10, GUID: "a1", Text: strp("hi"), DateCreated: intp(1000), Service: strp("iMessage")},
			{ChatGUID: "chatB", SourceRowID: 20, GUID: "b1", Text: strp("yo"), DateCreated: intp(2000), Service: strp("iMessage")},
			// noise row: must be excluded from the delta (debug-only) but still
			// counts toward the max rowid ceiling.
			{ChatGUID: "chatA", SourceRowID: 30, GUID: "noise", DateCreated: intp(3000), Service: strp("iMessage")},
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	// since < 0 → seed: no messages, cursor at the current max (30).
	seed, err := db.ListMessagesSince(ctx, -1, 200)
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	if len(seed.Messages) != 0 || seed.Cursor != 30 {
		t.Fatalf("seed should be empty with cursor=30, got %d msgs cursor=%d", len(seed.Messages), seed.Cursor)
	}

	// since=0 → both renderable messages (noise excluded), oldest-first, cursor
	// advanced to the ceiling (30) since nothing remains.
	all, err := db.ListMessagesSince(ctx, 0, 200)
	if err != nil {
		t.Fatalf("delta: %v", err)
	}
	if len(all.Messages) != 2 {
		t.Fatalf("expected 2 renderable msgs, got %d", len(all.Messages))
	}
	if all.Messages[0].GUID != "a1" || all.Messages[1].GUID != "b1" {
		t.Fatalf("delta must be oldest-first: %v", []string{all.Messages[0].GUID, all.Messages[1].GUID})
	}
	if all.Cursor != 30 {
		t.Fatalf("cursor should advance to ceiling 30, got %d", all.Cursor)
	}
	if len(all.ChatGUIDs) != 2 {
		t.Fatalf("expected 2 affected chats, got %v", all.ChatGUIDs)
	}

	// since=10 → only b1 (rowid 20) is newer.
	after10, err := db.ListMessagesSince(ctx, 10, 200)
	if err != nil {
		t.Fatalf("delta after 10: %v", err)
	}
	if len(after10.Messages) != 1 || after10.Messages[0].GUID != "b1" {
		t.Fatalf("since=10 should return only b1, got %d", len(after10.Messages))
	}

	// paging: limit 1 → first page returns a1, hasMore true, cursor=10.
	page, err := db.ListMessagesSince(ctx, 0, 1)
	if err != nil {
		t.Fatalf("page: %v", err)
	}
	if len(page.Messages) != 1 || page.Messages[0].GUID != "a1" || !page.HasMore || page.Cursor != 10 {
		t.Fatalf("paging wrong: n=%d hasMore=%v cursor=%d", len(page.Messages), page.HasMore, page.Cursor)
	}
}
