package relaydb

import (
	"context"
	"testing"

	_ "github.com/mattn/go-sqlite3"

	"micagoserver/internal/testcontact"
)

func TestTestContactLifecycle(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	// Off by default.
	if on, err := db.TestContactEnabled(ctx); err != nil || on {
		t.Fatalf("expected disabled by default, got on=%v err=%v", on, err)
	}

	// Enable: a renderable, sendable chat with a seeded greeting appears.
	if err := db.SetTestContactEnabled(ctx, true); err != nil {
		t.Fatalf("enable: %v", err)
	}
	if on, _ := db.TestContactEnabled(ctx); !on {
		t.Fatal("expected enabled after SetTestContactEnabled(true)")
	}
	chats, err := db.ListChats(ctx, 100, 0, false, "all", false)
	if err != nil {
		t.Fatalf("list chats: %v", err)
	}
	var found bool
	for _, c := range chats {
		if c.GUID == testcontact.ChatGUID {
			found = true
			if !c.HasRenderableMessages {
				t.Error("test chat should have a renderable greeting")
			}
			if !c.CanSendText {
				t.Error("test chat should be sendable text")
			}
		}
	}
	if !found {
		t.Fatal("test chat not in the chat list after enable")
	}
	welcome, err := db.TestContactWelcome(ctx)
	if err != nil || welcome == nil {
		t.Fatalf("welcome message missing: %v", err)
	}

	// Send: the outgoing row is recorded and visible in the thread.
	msg, err := db.AppendTestOutgoingMessage(ctx, "hello loopback")
	if err != nil || msg == nil {
		t.Fatalf("append outgoing: %v", err)
	}
	if !msg.IsFromMe {
		t.Error("outgoing message should be isFromMe")
	}
	thread, err := db.ListChatMessages(ctx, testcontact.ChatGUID, 100, 0, false)
	if err != nil {
		t.Fatalf("list chat messages: %v", err)
	}
	if len(thread) != 2 {
		t.Fatalf("expected greeting + 1 outgoing = 2 messages, got %d", len(thread))
	}

	// Synthetic rows must stay out of the delta watermark (NULL source_rowid),
	// or they would corrupt real incremental sync.
	if max, err := db.maxMessageRowID(ctx); err != nil || max != 0 {
		t.Fatalf("test rows must not raise the delta cursor, got max=%d err=%v", max, err)
	}
	delta, err := db.ListMessagesSince(ctx, 0, 100)
	if err != nil {
		t.Fatalf("delta: %v", err)
	}
	if len(delta.Messages) != 0 {
		t.Fatalf("test rows must not appear in delta, got %d", len(delta.Messages))
	}

	// Inbound (from the Debug card) lands as an incoming row.
	inbound, err := db.AppendTestInboundMessage(ctx, "from the mac")
	if err != nil || inbound == nil {
		t.Fatalf("append inbound: %v", err)
	}
	if inbound.IsFromMe {
		t.Error("inbound message should not be isFromMe")
	}

	// Reset wipes the conversation back to just the greeting.
	if err := db.ResetTestContactMessages(ctx); err != nil {
		t.Fatalf("reset: %v", err)
	}
	afterReset, err := db.ListChatMessages(ctx, testcontact.ChatGUID, 100, 0, false)
	if err != nil {
		t.Fatalf("list after reset: %v", err)
	}
	if len(afterReset) != 1 {
		t.Fatalf("reset should leave only the greeting, got %d", len(afterReset))
	}

	// Disable: every trace is removed.
	if err := db.SetTestContactEnabled(ctx, false); err != nil {
		t.Fatalf("disable: %v", err)
	}
	chats, _ = db.ListChats(ctx, 100, 0, false, "all", false)
	for _, c := range chats {
		if testcontact.IsTestChatGUID(c.GUID) {
			t.Fatal("test chat should be gone after disable")
		}
	}
	if left, _ := db.ListChatMessages(ctx, testcontact.ChatGUID, 100, 0, true); len(left) != 0 {
		t.Fatalf("test messages should be deleted, got %d", len(left))
	}
}
