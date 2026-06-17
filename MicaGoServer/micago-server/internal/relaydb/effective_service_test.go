package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

// C21: the effective service prefers iMessage and is message-aware, so a
// phone-number chat is never wrongly treated as SMS (or vice-versa) for the
// badge/gate. Never inferred from GUID/handle shape.
func TestResolveEffectiveService(t *testing.T) {
	cases := []struct {
		name        string
		chat, msg   *string
		hasIMessage bool
		want        string
	}{
		{"both iMessage", sp("iMessage"), sp("iMessage"), true, "imessage"},
		{"chat SMS but latest msg iMessage → prefer iMessage", sp("SMS"), sp("iMessage"), true, "imessage"},
		{"chat iMessage but latest msg SMS → prefer iMessage", sp("iMessage"), sp("SMS"), true, "imessage"},
		// C21c capability: latest msg is SMS but the chat HAS iMessage history.
		{"SMS chat + SMS latest BUT iMessage history → prefer iMessage", sp("SMS"), sp("SMS"), true, "imessage"},
		{"both SMS, no iMessage history → sms", sp("SMS"), sp("SMS"), false, "sms"},
		{"chat unknown, msg SMS, no history → sms", nil, sp("SMS"), false, "sms"},
		{"iMessageLite normalizes to imessage", sp("iMessageLite"), nil, false, "imessage"},
		{"nothing → unknown", nil, nil, false, "unknown"},
		{"RCS chat, no msg → rcs", sp("RCS"), nil, false, "rcs"},
	}
	for _, c := range cases {
		if got := ResolveEffectiveService(c.chat, c.msg, c.hasIMessage); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestCategorySendable(t *testing.T) {
	off := DefaultSyncSettings()
	on := DefaultSyncSettings()
	on.AllowSMSSend = true
	if !off.CategorySendable("imessage") || !on.CategorySendable("imessage") {
		t.Fatal("imessage must always be sendable")
	}
	if off.CategorySendable("sms") {
		t.Fatal("sms must be read-only by default")
	}
	if !on.CategorySendable("sms") {
		t.Fatal("sms must be sendable when enabled")
	}
	for _, cat := range []string{"rcs", "unknown", ""} {
		if on.CategorySendable(cat) {
			t.Fatalf("%q must never be sendable", cat)
		}
	}
}

// End-to-end: a chat row stored as SMS whose latest message is iMessage must
// surface effectiveService=imessage on both ListChats and GetChatInfo.
func TestEffectiveServiceMessageAwareRoundTrip(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{
			{GUID: "phone", ServiceName: sp("SMS")}, // chat row says SMS
		},
		messages: []store.SyncMessageRow{
			{ChatGUID: "phone", SourceRowID: 1, GUID: "m1", Text: sp("hi"), DateCreated: intp(1000), Service: sp("iMessage")},
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	info, err := db.GetChatInfo(ctx, "phone")
	if err != nil || info == nil {
		t.Fatalf("GetChatInfo: %v / %v", info, err)
	}
	if info.EffectiveService != "imessage" {
		t.Fatalf("GetChatInfo effective = %q, want imessage (message-aware)", info.EffectiveService)
	}

	chats, err := db.ListChats(ctx, 50, 0, true, "all", false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	var found *store.ChatJSON
	for i := range chats {
		if chats[i].GUID == "phone" {
			found = &chats[i]
		}
	}
	if found == nil || found.EffectiveService != "imessage" {
		t.Fatalf("ListChats effective = %v, want imessage", found)
	}
}

func TestSendCapabilities(t *testing.T) {
	off := DefaultSyncSettings()
	on := DefaultSyncSettings()
	on.AllowSMSSend = true

	if tx, at := off.SendCapabilities("imessage"); !tx || !at {
		t.Fatal("imessage must allow text + attachments")
	}
	if tx, at := off.SendCapabilities("sms"); tx || at {
		t.Fatal("sms read-only by default")
	}
	if tx, at := on.SendCapabilities("sms"); !tx || !at {
		t.Fatal("sms sendable when enabled")
	}
	if tx, at := on.SendCapabilities("unknown"); tx || at {
		t.Fatal("unknown always read-only")
	}
}

// C21c: a chat stored as SMS whose LATEST message is also SMS but which has an
// older iMessage message is iMessage-capable → effective iMessage (prefer
// iMessage), with canSend* true, on both ListChats and GetChatInfo.
func TestEffectiveServicePrefersIMessageFromHistory(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{{GUID: "phone", ServiceName: strp("SMS")}},
		messages: []store.SyncMessageRow{
			{ChatGUID: "phone", SourceRowID: 1, GUID: "old", Text: strp("hi via iMessage"), DateCreated: intp(1000), Service: strp("iMessage")},
			{ChatGUID: "phone", SourceRowID: 2, GUID: "new", Text: strp("fell back to SMS"), DateCreated: intp(2000), Service: strp("SMS")},
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	info, err := db.GetChatInfo(ctx, "phone")
	if err != nil || info == nil {
		t.Fatalf("GetChatInfo: %v / %v", info, err)
	}
	if info.EffectiveService != "imessage" {
		t.Fatalf("effective = %q, want imessage (iMessage history prefers iMessage)", info.EffectiveService)
	}

	chats, err := db.ListChats(ctx, 50, 0, true, "all", false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	for i := range chats {
		if chats[i].GUID == "phone" {
			if chats[i].EffectiveService != "imessage" || !chats[i].CanSendText || !chats[i].CanSendAttachments {
				t.Fatalf("chat caps wrong: %+v", chats[i])
			}
			return
		}
	}
	t.Fatal("chat not found")
}
