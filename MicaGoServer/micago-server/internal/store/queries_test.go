package store

import (
	"strings"
	"testing"
)

func TestBuildRecentMessagesQueryAllDoesNotFilterService(t *testing.T) {
	sqlText, args := buildRecentMessagesQuery(10, 0, "all", false)

	if strings.Contains(sqlText, "c.service_name = ?") {
		t.Fatal("did not expect service filter for service=all")
	}
	if strings.Contains(sqlText, "JOIN chat AS c") {
		t.Fatal("did not expect chat join for service=all")
	}
	if !strings.Contains(sqlText, "(m.text IS NOT NULL OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)") {
		t.Fatal("expected non-empty filter when includeEmpty=false")
	}
	if len(args) != 2 {
		t.Fatalf("expected only limit and offset args, got %d", len(args))
	}
}

func TestBuildRecentMessagesQueryIMessageFiltersByChatService(t *testing.T) {
	sqlText, args := buildRecentMessagesQuery(10, 5, "iMessage", false)

	if !strings.Contains(sqlText, "JOIN chat_message_join AS cmj") {
		t.Fatal("expected chat_message_join for service filtering")
	}
	if !strings.Contains(sqlText, "JOIN chat AS c") {
		t.Fatal("expected chat join for service filtering")
	}
	if !strings.Contains(sqlText, "c.service_name = ?") {
		t.Fatal("expected chat.service_name filter")
	}
	if !strings.Contains(sqlText, "(m.text IS NOT NULL OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)") {
		t.Fatal("expected non-empty filter when includeEmpty=false")
	}
	if len(args) != 3 {
		t.Fatalf("expected service, limit, and offset args, got %d", len(args))
	}
	if args[0] != "iMessage" {
		t.Fatalf("expected first arg to be service, got %#v", args[0])
	}
}

func TestBuildRecentMessagesQueryIncludeEmptySkipsNonEmptyFilter(t *testing.T) {
	sqlText, _ := buildRecentMessagesQuery(10, 0, "iMessage", true)

	if strings.Contains(sqlText, "(m.text IS NOT NULL OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)") {
		t.Fatal("did not expect non-empty filter when includeEmpty=true")
	}
	if !strings.Contains(sqlText, "c.service_name = ?") {
		t.Fatal("expected chat.service_name filter to remain")
	}
}
