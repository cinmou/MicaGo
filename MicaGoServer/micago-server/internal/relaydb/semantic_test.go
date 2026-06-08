package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

// fakeSemanticSource feeds one chat + one reaction message carrying the
// BlueBubbles-compatible semantic fields through SyncOnce.
type fakeSemanticSource struct {
	chats    []store.SyncChatRow
	messages []store.SyncMessageRow
}

func (f fakeSemanticSource) ListSyncChats(context.Context) ([]store.SyncChatRow, error) {
	return f.chats, nil
}
func (f fakeSemanticSource) ListSyncRecentMessages(context.Context, int) ([]store.SyncMessageRow, error) {
	return f.messages, nil
}
func (f fakeSemanticSource) ListSyncRecentMessagesSince(context.Context, int64, int) ([]store.SyncMessageRow, error) {
	return f.messages, nil
}
func (f fakeSemanticSource) ListSyncAttachmentsForMessages(context.Context, []string) ([]store.SyncAttachmentRow, error) {
	return nil, nil
}

func strp(s string) *string { return &s }
func intp(n int64) *int64   { return &n }

func TestSemanticFieldsRoundTripThroughRelay(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{
			{GUID: "chatA", ServiceName: strp("iMessage")},
		},
		messages: []store.SyncMessageRow{
			{
				ChatGUID:              "chatA",
				SourceRowID:           10,
				GUID:                  "m-react",
				Text:                  strp("loved"),
				DateCreated:           intp(1000),
				AssociatedMessageType: intp(2000),
				AssociatedMessageGUID: strp("p:0/m-target"),
				PayloadDataPresent:    true,
			},
			{
				ChatGUID:             "chatA",
				SourceRowID:          11,
				GUID:                 "m-reply",
				Text:                 strp("sure"),
				DateCreated:          intp(2000),
				ThreadOriginatorGUID: strp("m-target"),
			},
		},
	}

	if _, err := SyncOnce(ctx, src, db, 100); err != nil {
		t.Fatalf("sync: %v", err)
	}

	msgs, err := db.ListChatMessages(ctx, "chatA", 50, 0, false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(msgs))
	}

	byGUID := map[string]store.MessageJSON{}
	for _, m := range msgs {
		byGUID[m.GUID] = m
	}

	react := byGUID["m-react"]
	if react.ChatGUID == nil || *react.ChatGUID != "chatA" {
		t.Fatalf("chatGuid not exposed: %+v", react.ChatGUID)
	}
	if react.AssociatedMessageType == nil || *react.AssociatedMessageType != 2000 {
		t.Fatalf("associatedMessageType = %v, want 2000", react.AssociatedMessageType)
	}
	if react.AssociatedMessageGUID == nil || *react.AssociatedMessageGUID != "p:0/m-target" {
		t.Fatalf("associatedMessageGuid = %v", react.AssociatedMessageGUID)
	}
	if !react.PayloadDataPresent {
		t.Fatalf("payloadDataPresent should be true")
	}

	reply := byGUID["m-reply"]
	if reply.ThreadOriginatorGUID == nil || *reply.ThreadOriginatorGUID != "m-target" {
		t.Fatalf("threadOriginatorGuid = %v, want m-target", reply.ThreadOriginatorGUID)
	}
}

func TestRetractedStateFromMessageState(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats:    []store.SyncChatRow{{GUID: "chatB", ServiceName: strp("iMessage")}},
		messages: []store.SyncMessageRow{{ChatGUID: "chatB", SourceRowID: 1, GUID: "m-unsent", Text: strp("oops"), DateCreated: intp(500)}},
	}
	if _, err := SyncOnce(ctx, src, db, 100); err != nil {
		t.Fatalf("sync: %v", err)
	}

	// Simulate the lookback update pass recording a retraction in message_state.
	if _, err := db.sqlDB.ExecContext(ctx, `
INSERT INTO message_state (guid, date_retracted, fingerprint, updated_at)
VALUES ('m-unsent', 1234, 'fp', 1)
ON CONFLICT(guid) DO UPDATE SET date_retracted = excluded.date_retracted;`); err != nil {
		t.Fatalf("seed message_state: %v", err)
	}

	msgs, err := db.ListChatMessages(ctx, "chatB", 50, 0, false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	m := msgs[0]
	if !m.IsRetracted || m.DateRetracted == nil || *m.DateRetracted != 1234 {
		t.Fatalf("retracted state not surfaced: isRetracted=%v dateRetracted=%v", m.IsRetracted, m.DateRetracted)
	}
}
