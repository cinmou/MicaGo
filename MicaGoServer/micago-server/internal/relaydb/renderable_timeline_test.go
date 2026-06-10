package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

// C12: the relay is the single canonical timeline path and filters debug-only
// noise rows in SQL. These tests prove an empty/noise row cannot enter the
// normal thread or the normal recent list, while the raw (debug) read still
// reveals it for the Message Inspector.
func TestRenderableThreadAndRecentExcludeNoise(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{{GUID: "chat-1", ServiceName: strp("iMessage")}},
		messages: []store.SyncMessageRow{
			// Renderable text row.
			{ChatGUID: "chat-1", SourceRowID: 1, GUID: "real", Text: strp("hello"), DateCreated: intp(1000), Service: strp("iMessage")},
			// Empty/noise row: no text, no attributedBody, no attachments → debug-only.
			{ChatGUID: "chat-1", SourceRowID: 2, GUID: "noise", DateCreated: intp(2000), Service: strp("iMessage")},
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	// Normal thread: noise excluded.
	thread, err := db.ListChatMessages(ctx, "chat-1", 50, 0, false)
	if err != nil {
		t.Fatalf("thread: %v", err)
	}
	if len(thread) != 1 || thread[0].GUID != "real" {
		t.Fatalf("normal thread = %v, want only [real]", guidsOf(thread))
	}

	// Raw thread (debug): noise revealed.
	rawThread, err := db.ListChatMessages(ctx, "chat-1", 50, 0, true)
	if err != nil {
		t.Fatalf("raw thread: %v", err)
	}
	if len(rawThread) != 2 {
		t.Fatalf("raw thread should reveal noise, got %d rows", len(rawThread))
	}

	// Normal recent list: noise excluded.
	recent, err := db.ListRecentMessages(ctx, 50, 0, "all", false)
	if err != nil {
		t.Fatalf("recent: %v", err)
	}
	if len(recent) != 1 || recent[0].GUID != "real" {
		t.Fatalf("normal recent = %v, want only [real]", guidsOf(recent))
	}

	rawRecent, err := db.ListRecentMessages(ctx, 50, 0, "all", true)
	if err != nil {
		t.Fatalf("raw recent: %v", err)
	}
	if len(rawRecent) != 2 {
		t.Fatalf("raw recent should reveal noise, got %d rows", len(rawRecent))
	}
}

// C12 (IMSG-derived): a reaction that arrives after a real text message must not
// reorder its chat above a chat whose newest renderable message is older — the
// reaction is excluded from the ordering aggregate entirely.
func TestReactionDoesNotReorderChats(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	reaction := func(guid, chat string, at int64) store.SyncMessageRow {
		return store.SyncMessageRow{
			ChatGUID: chat, SourceRowID: at, GUID: guid,
			Text:                  strp("Loved a message"),
			DateCreated:           intp(at),
			Service:               strp("iMessage"),
			AssociatedMessageType: intp(2000),
			AssociatedMessageGUID: strp("p:0/target"),
		}
	}

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{
			{GUID: "older", ServiceName: strp("iMessage")},
			{GUID: "newer", ServiceName: strp("iMessage")},
		},
		messages: []store.SyncMessageRow{
			// "newer" has the most recent *text* at t=2000.
			{ChatGUID: "newer", SourceRowID: 1, GUID: "n1", Text: strp("newest text"), DateCreated: intp(2000), Service: strp("iMessage")},
			// "older" has older text at t=1000 ...
			{ChatGUID: "older", SourceRowID: 2, GUID: "o1", Text: strp("older text"), DateCreated: intp(1000), Service: strp("iMessage")},
			// ... plus a reaction at t=3000 (newer than everything). It must NOT
			// pull "older" to the top.
			reaction("o-react", "older", 3000),
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	chats, err := db.ListChats(ctx, 50, 0, true, "all", false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(chats) != 2 {
		t.Fatalf("want 2 visible chats, got %v", guids(chats))
	}
	// Ordering is by latest renderable (non-reaction) message: "newer" (t=2000)
	// must outrank "older" (t=1000) despite older's t=3000 reaction.
	if chats[0].GUID != "newer" {
		t.Fatalf("ordering = %v, want [newer, older] — reaction must not reorder", guids(chats))
	}
	// And "older"'s preview is its text, not the reaction.
	var older store.ChatJSON
	for _, c := range chats {
		if c.GUID == "older" {
			older = c
		}
	}
	if older.LatestRenderablePreview == nil || *older.LatestRenderablePreview != "older text" {
		t.Fatalf("older preview = %v, want 'older text'", older.LatestRenderablePreview)
	}
}

func guidsOf(msgs []store.MessageJSON) []string {
	out := make([]string, 0, len(msgs))
	for _, m := range msgs {
		out = append(out, m.GUID)
	}
	return out
}
