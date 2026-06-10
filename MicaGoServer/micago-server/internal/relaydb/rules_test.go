package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

func sp(v string) *string { return &v }

func TestNormalizeHandle(t *testing.T) {
	cases := map[string]string{
		"+1 (555) 123-4567": "+15551234567",
		"555-123-4567":      "5551234567",
		"User@iCloud.com":   "user@icloud.com",
		"  bob@EX.com ":     "bob@ex.com",
	}
	for in, want := range cases {
		if got := NormalizeHandle(in); got != want {
			t.Fatalf("NormalizeHandle(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDefaultPolicyPersistenceAndDefaults(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	s, p, err := db.DefaultPolicies(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if s != PolicyAllowAll || p != PolicyEnabled {
		t.Fatalf("expected default allow_all/enabled, got %q/%q", s, p)
	}

	if err := db.SetDefaultPolicies(ctx, PolicyBlockAll, PolicyMuted); err != nil {
		t.Fatal(err)
	}
	s, p, _ = db.DefaultPolicies(ctx)
	if s != PolicyBlockAll || p != PolicyMuted {
		t.Fatalf("expected block_all/muted, got %q/%q", s, p)
	}
}

func TestSnapshotPrecedence(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	// chat allow overrides handle block; handle block applies elsewhere.
	must(t, db.UpsertSyncRule(ctx, store.SyncRuleJSON{TargetKind: TargetChat, TargetValue: "chatA", SyncMode: SyncAllow, PushMode: PushInherit}))
	must(t, db.UpsertSyncRule(ctx, store.SyncRuleJSON{TargetKind: TargetHandle, TargetValue: "+1 555 000", SyncMode: SyncBlock, PushMode: PushInherit}))
	// chat muted (sync allowed, push muted)
	must(t, db.UpsertSyncRule(ctx, store.SyncRuleJSON{TargetKind: TargetChat, TargetValue: "chatM", SyncMode: SyncAllow, PushMode: PushMuted}))

	snap, err := db.LoadRuleSnapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}

	// The rule target "+1 555 000" normalizes to "+1555000"; a message handle
	// must normalize identically to match.
	handleMatch := sp("+1 (555) 000") // -> "+1555000" (matches the block rule)
	handleOther := sp("+1 555 999")   // -> "+1555999" (no rule → default allow)

	if !snap.SyncAllowed("chatA", handleMatch) {
		t.Fatalf("chat allow must override handle block")
	}
	if snap.SyncAllowed("chatB", handleMatch) {
		t.Fatalf("handle block must apply where no chat rule exists")
	}
	if !snap.SyncAllowed("chatB", handleOther) {
		t.Fatalf("unmatched handle should fall through to default allow_all")
	}
	// Default allow for an unknown chat/handle.
	if !snap.SyncAllowed("chatUnknown", nil) {
		t.Fatalf("default policy allow_all should allow unknown targets")
	}
	// Muted chat: synced but not pushed.
	if !snap.SyncAllowed("chatM", nil) {
		t.Fatalf("chatM should be synced")
	}
	if snap.PushEnabled("chatM", nil) {
		t.Fatalf("chatM push should be muted")
	}
	// Push gated by sync: blocked target never pushes.
	if snap.PushEnabled("chatB", handleMatch) {
		t.Fatalf("blocked target must not push")
	}
}

func TestWhitelistMode(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	must(t, db.SetDefaultPolicies(ctx, PolicyBlockAll, PolicyEnabled))
	must(t, db.UpsertSyncRule(ctx, store.SyncRuleJSON{TargetKind: TargetChat, TargetValue: "allowed", SyncMode: SyncAllow, PushMode: PushInherit}))

	snap, err := db.LoadRuleSnapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !snap.SyncAllowed("allowed", nil) {
		t.Fatalf("allowlisted chat should sync")
	}
	if snap.SyncAllowed("other", nil) {
		t.Fatalf("block_all default should block non-allowlisted chats")
	}
}

func TestUpsertListDeleteRules(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	must(t, db.UpsertSyncRule(ctx, store.SyncRuleJSON{TargetKind: TargetHandle, TargetValue: "+1 (555) 111", SyncMode: SyncBlock, PushMode: PushInherit}))
	rules, err := db.ListSyncRules(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(rules) != 1 || rules[0].TargetValue != "+1555111" {
		t.Fatalf("expected one normalized handle rule, got %#v", rules)
	}
	// Upsert same target updates in place.
	must(t, db.UpsertSyncRule(ctx, store.SyncRuleJSON{TargetKind: TargetHandle, TargetValue: "+1555111", SyncMode: SyncAllow, PushMode: PushMuted}))
	rules, _ = db.ListSyncRules(ctx)
	if len(rules) != 1 || rules[0].SyncMode != SyncAllow || rules[0].PushMode != PushMuted {
		t.Fatalf("expected updated rule, got %#v", rules)
	}
	// Delete reverts.
	must(t, db.DeleteSyncRule(ctx, TargetHandle, "+1 555 111"))
	rules, _ = db.ListSyncRules(ctx)
	if len(rules) != 0 {
		t.Fatalf("expected no rules after delete, got %#v", rules)
	}
}

func TestSyncOnceBlocksMessagesButAdvancesWatermark(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	// Block chat-B before syncing.
	must(t, db.UpsertSyncRule(ctx, store.SyncRuleJSON{TargetKind: TargetChat, TargetValue: "chat-B", SyncMode: SyncBlock, PushMode: PushInherit}))

	source := &fakeSyncSource{
		chats: []store.SyncChatRow{{GUID: "chat-A"}, {GUID: "chat-B"}},
		initialMessages: []store.SyncMessageRow{
			{GUID: "a1", ChatGUID: "chat-A", SourceRowID: 10},
			{GUID: "b1", ChatGUID: "chat-B", SourceRowID: 11},
		},
	}
	res, err := SyncOnce(ctx, source, db, 1000, 0)
	if err != nil {
		t.Fatal(err)
	}
	// Watermark advances over the FULL set (including blocked b1).
	if res.NewLastMessageRowID != 11 {
		t.Fatalf("expected watermark 11 (advances past blocked), got %d", res.NewLastMessageRowID)
	}
	// Only chat-A message was inserted / broadcast.
	if len(res.NewMessages) != 1 || res.NewMessages[0].GUID != "a1" {
		t.Fatalf("expected only a1 synced, got %#v", res.NewMessages)
	}
	var count int
	if err := db.sqlDB.QueryRow(`SELECT COUNT(*) FROM messages WHERE guid='b1'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("blocked message b1 must not be in relay.db")
	}
	// chats are still synced so the user can target them.
	if err := db.sqlDB.QueryRow(`SELECT COUNT(*) FROM chats WHERE guid='chat-B'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("chat rows should still sync (count=%d)", count)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
