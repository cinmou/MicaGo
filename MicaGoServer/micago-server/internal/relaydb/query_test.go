package relaydb

import (
	"context"
	"testing"
)

func TestListChats(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	chats, err := db.ListChats(context.Background(), 10, 0, false, "iMessage", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(chats) != 1 {
		t.Fatalf("expected 1 non-archived iMessage chat, got %d", len(chats))
	}
	if chats[0].GUID != "chat-1" {
		t.Fatalf("expected chat-1, got %q", chats[0].GUID)
	}

	// debug=true reveals all chats including the message-less one.
	allChats, err := db.ListChats(context.Background(), 10, 0, true, "all", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(allChats) != 3 {
		t.Fatalf("expected 3 chats, got %d", len(allChats))
	}
}

func TestListRecentMessages(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	messages, err := db.ListRecentMessages(context.Background(), 10, 0, "iMessage", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("expected 2 iMessage messages, got %d", len(messages))
	}
	if messages[0].GUID != "msg-2" {
		t.Fatalf("expected newest iMessage msg-2, got %q", messages[0].GUID)
	}
	if len(messages[0].Attachments) != 1 {
		t.Fatalf("expected 1 attachment for msg-2, got %d", len(messages[0].Attachments))
	}

	smsMessages, err := db.ListRecentMessages(context.Background(), 10, 0, "SMS", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(smsMessages) != 1 {
		t.Fatalf("expected 1 SMS relay message, got %d", len(smsMessages))
	}
}

func TestGetAttachmentByGUID(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	meta, err := db.GetAttachmentByGUID(context.Background(), "att-1")
	if err != nil {
		t.Fatal(err)
	}
	if meta == nil {
		t.Fatal("expected attachment metadata")
	}
	if meta.MessageGUID != "msg-2" {
		t.Fatalf("expected msg-2, got %q", meta.MessageGUID)
	}
}

func TestListChatMessagesAndExists(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	exists, err := db.ChatExists(context.Background(), "chat-1")
	if err != nil {
		t.Fatal(err)
	}
	if !exists {
		t.Fatal("expected chat-1 to exist")
	}

	messages, err := db.ListChatMessages(context.Background(), "chat-1", 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("expected 2 messages for chat-1, got %d", len(messages))
	}
	if messages[0].GUID != "msg-2" {
		t.Fatalf("expected newest msg-2, got %q", messages[0].GUID)
	}
}

func TestFindOutgoingMessageMatch(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	match, err := db.FindOutgoingMessageMatch(context.Background(), "chat-1", "world", 1500, nil)
	if err != nil {
		t.Fatal(err)
	}
	if match == nil {
		t.Fatal("expected outgoing match")
	}
	if match.GUID != "msg-2" {
		t.Fatalf("expected msg-2, got %q", match.GUID)
	}
}

func TestFindOutgoingMessageMatchExcludesClaimedRow(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	// Excluding the only matching row must yield no match (so a second
	// concurrent identical send won't re-confirm an already-claimed message).
	excluded := map[string]struct{}{"msg-2": {}}
	match, err := db.FindOutgoingMessageMatch(context.Background(), "chat-1", "world", 1500, excluded)
	if err != nil {
		t.Fatal(err)
	}
	if match != nil {
		t.Fatalf("expected no match when row is excluded, got %q", match.GUID)
	}
}

func seedRelayData(t *testing.T, db *DB) {
	t.Helper()
	tx, err := db.sqlDB.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()

	_, err = tx.Exec(`
INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, updated_at) VALUES
('chat-1', 'c1', 'iMessage', 'Chat 1', 0, 100),
('chat-2', 'c2', 'iMessage', 'Chat 2', 1, 90),
('chat-3', 'c3', 'SMS', 'Chat 3', 0, 80);
`)
	if err != nil {
		t.Fatal(err)
	}

	_, err = tx.Exec(`
INSERT INTO messages (
	guid, chat_guid, source_rowid, text, subject, service, date_created, date_read, date_delivered,
	is_from_me, is_read, is_delivered, handle_id, handle_service, cache_has_attachments, created_at
) VALUES
('msg-1', 'chat-1', 10, 'hello', NULL, 'iMessage', 1000, NULL, NULL, 0, 1, 1, 'h1', 'iMessage', 0, 100),
('msg-2', 'chat-1', 11, 'world', NULL, 'iMessage', 2000, NULL, NULL, 1, 1, 1, 'h1', 'iMessage', 1, 100),
('msg-3', 'chat-3', 12, 'sms', NULL, 'SMS', 1500, NULL, NULL, 0, 1, 1, 'h2', 'SMS', 0, 100);
`)
	if err != nil {
		t.Fatal(err)
	}

	_, err = tx.Exec(`
INSERT INTO attachments (
	guid, message_guid, filename, mime_type, transfer_name, total_bytes, local_path, is_outgoing, hide_attachment, created_at
) VALUES
('att-1', 'msg-2', 'photo.jpg', 'image/jpeg', 'photo.jpg', 1234, '/tmp/photo.jpg', 1, 0, 100);
`)
	if err != nil {
		t.Fatal(err)
	}

	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}
