package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

type fakePerChatSource struct {
	fakeSyncSource
	perChat map[string][]store.SyncMessageRow
}

func (f *fakePerChatSource) ListSyncRecentMessagesForChat(_ context.Context, chatGUID string, _ int) ([]store.SyncMessageRow, error) {
	return f.perChat[chatGUID], nil
}

func TestServiceScopeSMSCanBeIncludedAndExcluded(t *testing.T) {
	ctx := context.Background()
	db := openTestDB(t)
	src := &fakeSyncSource{
		chats: []store.SyncChatRow{
			{GUID: "im", ServiceName: strp("iMessage")},
			{GUID: "sms", ServiceName: strp("SMS")},
		},
		initialMessages: []store.SyncMessageRow{
			{ChatGUID: "im", SourceRowID: 1, GUID: "m-im", Text: strp("blue"), DateCreated: intp(10)},
			{ChatGUID: "sms", SourceRowID: 2, GUID: "m-sms", Text: strp("green"), DateCreated: intp(20)},
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatal(err)
	}

	chats, err := db.ListChats(ctx, 10, 0, true, "all", false)
	if err != nil {
		t.Fatal(err)
	}
	if got := guids(chats); len(got) != 2 {
		t.Fatalf("default service scope = %v, want iMessage+SMS", got)
	}

	if _, err := db.SetSyncSettings(ctx, SyncSettings{
		BackfillMode:          "hybrid",
		RecentMessagesPerChat: 100,
		IncludeIMessage:       true,
		IncludeSMS:            false,
		IncludeRCS:            true,
	}); err != nil {
		t.Fatal(err)
	}
	chats, err = db.ListChats(ctx, 10, 0, true, "all", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(chats) != 1 || chats[0].GUID != "im" {
		t.Fatalf("SMS excluded list = %v, want [im]", guids(chats))
	}
	debug, err := db.ListChats(ctx, 10, 0, true, "all", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(debug) != 2 {
		t.Fatalf("debug list should still expose excluded service rows, got %v", guids(debug))
	}
}

func TestUnknownServiceHiddenByDefaultUnlessDebug(t *testing.T) {
	ctx := context.Background()
	db := openTestDB(t)
	src := &fakeSyncSource{
		chats:           []store.SyncChatRow{{GUID: "u", ServiceName: strp("CarrierX")}},
		initialMessages: []store.SyncMessageRow{{ChatGUID: "u", SourceRowID: 1, GUID: "m-u", Text: strp("real"), DateCreated: intp(10)}},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatal(err)
	}
	normal, err := db.ListChats(ctx, 10, 0, true, "all", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(normal) != 0 {
		t.Fatalf("unknown service should be hidden by default, got %v", guids(normal))
	}
	debug, err := db.ListChats(ctx, 10, 0, true, "all", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(debug) != 1 || debug[0].ServiceCategory != "unknown" {
		t.Fatalf("debug unknown = %+v", debug)
	}
}

func TestHybridPerChatBackfillRecoversLowActivityChat(t *testing.T) {
	ctx := context.Background()
	db := openTestDB(t)
	if _, err := db.SetSyncSettings(ctx, SyncSettings{
		BackfillMode:          "hybrid",
		RecentMessagesPerChat: 100,
		IncludeIMessage:       true,
		IncludeSMS:            true,
		IncludeRCS:            true,
	}); err != nil {
		t.Fatal(err)
	}
	src := &fakePerChatSource{
		fakeSyncSource: fakeSyncSource{
			chats: []store.SyncChatRow{
				{GUID: "busy", ServiceName: strp("iMessage")},
				{GUID: "quiet", ServiceName: strp("iMessage")},
			},
			initialMessages: []store.SyncMessageRow{
				{ChatGUID: "busy", SourceRowID: 100, GUID: "busy-new", Text: strp("latest"), DateCreated: intp(1000)},
			},
		},
		perChat: map[string][]store.SyncMessageRow{
			"busy":  {{ChatGUID: "busy", SourceRowID: 100, GUID: "busy-new", Text: strp("latest"), DateCreated: intp(1000)}},
			"quiet": {{ChatGUID: "quiet", SourceRowID: 10, GUID: "quiet-old", Text: strp("still here"), DateCreated: intp(100)}},
		},
	}
	res, err := SyncOnce(ctx, src, db, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if res.Mode != "hybrid" || res.PerChatLimit != 100 {
		t.Fatalf("mode/limit = %q/%d", res.Mode, res.PerChatLimit)
	}
	msgs, err := db.ListChatMessages(ctx, "quiet", 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].GUID != "quiet-old" {
		t.Fatalf("quiet messages = %+v", msgs)
	}
}

func TestAttachmentMetadataStoredWithoutBytes(t *testing.T) {
	ctx := context.Background()
	db := openTestDB(t)
	src := &fakeSyncSource{
		chats:           []store.SyncChatRow{{GUID: "chat", ServiceName: strp("iMessage")}},
		initialMessages: []store.SyncMessageRow{{ChatGUID: "chat", SourceRowID: 1, GUID: "m", Text: strp("￼"), CacheHasAttachments: true, DateCreated: intp(10)}},
		attachments: map[string][]store.SyncAttachmentRow{
			"m": {{GUID: "a", MessageGUID: "m", Filename: strp("~/Library/Messages/Attachments/a.jpg"), MimeType: strp("image/jpeg"), TransferName: strp("a.jpg"), TotalBytes: 123}},
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatal(err)
	}
	meta, err := db.GetAttachmentByGUID(ctx, "a")
	if err != nil {
		t.Fatal(err)
	}
	if meta == nil || meta.TotalBytes != 123 || meta.Filename == nil {
		t.Fatalf("attachment metadata not stored: %+v", meta)
	}
}
