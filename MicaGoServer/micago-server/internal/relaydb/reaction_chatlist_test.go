package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

// C12 (IMSG-derived): a tapback must not become a chat's preview or bump its
// ordering; a chat whose only content is reactions is hidden by default.
func TestReactionsExcludedFromChatListAggregate(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	reaction := func(guid, chat string, at int64) store.SyncMessageRow {
		return store.SyncMessageRow{
			ChatGUID: chat, SourceRowID: at, GUID: guid,
			Text:                  strp("Loved a message"),
			DateCreated:           intp(at),
			AssociatedMessageType: intp(2000),
			AssociatedMessageGUID: strp("p:0/target"),
		}
	}

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{
			{GUID: "withText", ServiceName: strp("iMessage")},
			{GUID: "reactionOnly", ServiceName: strp("iMessage")},
		},
		messages: []store.SyncMessageRow{
			{ChatGUID: "withText", SourceRowID: 1, GUID: "t1", Text: strp("real message"), DateCreated: intp(1000)},
			// A later reaction in the same chat must NOT become the preview.
			reaction("r1", "withText", 2000),
			// A chat with only reactions must be hidden by default.
			reaction("r2", "reactionOnly", 1500),
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	visible, err := db.ListChats(ctx, 50, 0, true, "all", false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(visible) != 1 || visible[0].GUID != "withText" {
		t.Fatalf("default list = %v, want only [withText]", guids(visible))
	}
	// Preview is the real text, not the reaction.
	if visible[0].LatestRenderablePreview == nil || *visible[0].LatestRenderablePreview != "real message" {
		t.Fatalf("preview = %v, want 'real message'", visible[0].LatestRenderablePreview)
	}

	// Debug reveals the reaction-only chat, flagged unsupportedOnly.
	all, err := db.ListChats(ctx, 50, 0, true, "all", true)
	if err != nil {
		t.Fatalf("list debug: %v", err)
	}
	var reactionOnly *store.ChatJSON
	for i := range all {
		if all[i].GUID == "reactionOnly" {
			reactionOnly = &all[i]
		}
	}
	if reactionOnly == nil || reactionOnly.HasRenderableMessages || !reactionOnly.UnsupportedOnly {
		t.Fatalf("reaction-only chat flags wrong: %+v", reactionOnly)
	}
}

func TestIsReactionForSyncRow(t *testing.T) {
	yes := store.SyncMessageRow{AssociatedMessageType: intp(2000), AssociatedMessageGUID: strp("p:0/x")}
	if !store.IsReactionForSyncRow(yes) {
		t.Fatal("2000 + target should be a reaction")
	}
	noTarget := store.SyncMessageRow{AssociatedMessageType: intp(2000)}
	if store.IsReactionForSyncRow(noTarget) {
		t.Fatal("no target → not a reaction")
	}
	plain := store.SyncMessageRow{Text: strp("hi")}
	if store.IsReactionForSyncRow(plain) {
		t.Fatal("plain text is not a reaction")
	}
	sticker := store.SyncMessageRow{AssociatedMessageType: intp(1000), AssociatedMessageGUID: strp("p:0/x")}
	if store.IsReactionForSyncRow(sticker) {
		t.Fatal("sticker (1000) is below the reaction range")
	}
}
