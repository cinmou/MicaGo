package store

import (
	"encoding/json"
	"strings"
	"testing"
)

func ip(n int64) *int64 { return &n }

func TestIsControlLikeText(t *testing.T) {
	cases := map[string]bool{
		"+!":       true,
		"+$":       true,
		"":         true,
		"￼":        true,
		"   ":      true,
		"Hello":    false,
		"+1":       false,
		"你好":       false,
		"see ya 👋": false,
	}
	for in, want := range cases {
		if got := IsControlLikeText(in); got != want {
			t.Errorf("IsControlLikeText(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestClassifyDebugMessage(t *testing.T) {
	tests := []struct {
		name     string
		msg      DebugMessageJSON
		wantKind string
		wantCand string // a candidate that must be present ("" = none required)
	}{
		{"plain text", DebugMessageJSON{Text: sp("Hello")}, KindText, ""},
		{"control text", DebugMessageJSON{Text: sp("+!")}, KindUnsupported, candidateControl},
		{"empty", DebugMessageJSON{}, KindUnsupported, candidateNoConten},
		{
			"reaction",
			DebugMessageJSON{AssociatedMessageType: ip(2000), AssociatedMessageGUID: sp("p:0/abc")},
			KindReaction, KindReaction,
		},
		{
			"reply candidate",
			DebugMessageJSON{ThreadOriginatorGUID: sp("m-target"), Text: sp("ok")},
			KindReply, KindReply,
		},
		{
			"service event",
			DebugMessageJSON{ItemType: ip(2), GroupActionType: ip(1)},
			KindService, KindService,
		},
		{
			"image attachment",
			DebugMessageJSON{Attachments: []DebugAttachmentJSON{{AttachmentKind: AttachmentKindImage}}},
			KindImage, "",
		},
		{
			"voice attachment",
			DebugMessageJSON{Attachments: []DebugAttachmentJSON{{AttachmentKind: AttachmentKindAudio, IsVoiceMessage: true}}},
			KindVoice, "",
		},
		{
			"file attachment",
			DebugMessageJSON{Attachments: []DebugAttachmentJSON{{AttachmentKind: AttachmentKindFile}}},
			KindFile, "",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			kind, cand := ClassifyDebugMessage(tc.msg)
			if kind != tc.wantKind {
				t.Errorf("kind = %q, want %q", kind, tc.wantKind)
			}
			if tc.wantCand != "" && !contains(cand, tc.wantCand) {
				t.Errorf("candidates %v missing %q", cand, tc.wantCand)
			}
		})
	}
}

func TestClassifyFlagsMissingAttachmentRows(t *testing.T) {
	m := DebugMessageJSON{Text: sp("hi"), CacheHasAttachments: true}
	_, cand := ClassifyDebugMessage(m)
	if !contains(cand, "missing_attachment_rows") {
		t.Fatalf("expected missing_attachment_rows candidate, got %v", cand)
	}
}

func annotate(in []DebugMessageJSON) []DebugMessageJSON {
	for i := range in {
		AnnotateDebugMessage(&in[i])
	}
	return in
}

func sampleMessages() []DebugMessageJSON {
	return annotate([]DebugMessageJSON{
		{GUID: "1", Text: sp("Hello world"), HandleID: sp("+15550001"), ChatGUID: sp("cA"), ChatDisplayName: sp("Alice"), DateCreated: ip(100)},
		{GUID: "2", Text: sp("+!"), HandleID: sp("+15550001"), ChatGUID: sp("cA"), ChatDisplayName: sp("Alice"), DateCreated: ip(200)},
		{GUID: "3", IsFromMe: true, Text: sp("from me"), ChatGUID: sp("cA"), ChatDisplayName: sp("Alice"), DateCreated: ip(300)},
		{GUID: "4", HandleID: sp("+15550002"), ChatGUID: sp("cB"), ChatDisplayName: sp("Bob"),
			Attachments: []DebugAttachmentJSON{{GUID: "att1", AttachmentKind: AttachmentKindImage, Filename: sp("photo.jpg")}}, DateCreated: ip(400)},
		{GUID: "5", HandleID: sp("+15550002"), ChatGUID: sp("cB"), DateCreated: ip(500)}, // empty -> unsupported
	})
}

func TestFilterByQuery(t *testing.T) {
	msgs := sampleMessages()
	// matches chat display name "Alice"
	got := FilterDebugMessages(msgs, DebugFilter{Query: "alice"})
	if len(got) != 3 {
		t.Fatalf("query alice = %d rows, want 3 (chat cA)", len(got))
	}
	// matches attachment filename
	got = FilterDebugMessages(msgs, DebugFilter{Query: "photo.jpg"})
	if len(got) != 1 || got[0].GUID != "4" {
		t.Fatalf("query photo.jpg = %+v, want only guid 4", got)
	}
}

func TestFilterByType(t *testing.T) {
	msgs := sampleMessages()
	if got := FilterDebugMessages(msgs, DebugFilter{Type: "text"}); len(got) != 2 {
		t.Fatalf("type text = %d, want 2", len(got))
	}
	if got := FilterDebugMessages(msgs, DebugFilter{Type: "image"}); len(got) != 1 {
		t.Fatalf("type image = %d, want 1", len(got))
	}
	if got := FilterDebugMessages(msgs, DebugFilter{Type: "unsupported"}); len(got) != 2 {
		t.Fatalf("type unsupported = %d, want 2 (control + empty)", len(got))
	}
}

func TestFilterByAttachments(t *testing.T) {
	msgs := sampleMessages()
	if got := FilterDebugMessages(msgs, DebugFilter{HasAttachments: "has"}); len(got) != 1 {
		t.Fatalf("has = %d, want 1", len(got))
	}
	if got := FilterDebugMessages(msgs, DebugFilter{HasAttachments: "none"}); len(got) != 4 {
		t.Fatalf("none = %d, want 4", len(got))
	}
	if got := FilterDebugMessages(msgs, DebugFilter{HasAttachments: "image"}); len(got) != 1 {
		t.Fatalf("image = %d, want 1", len(got))
	}
}

func TestGroupBySender(t *testing.T) {
	groups := GroupDebugMessages(sampleMessages(), "sender")
	byKey := map[string]DebugGroup{}
	for _, g := range groups {
		byKey[g.Key] = g
	}
	if byKey["+15550001"].Count != 2 {
		t.Fatalf("+15550001 count = %d, want 2", byKey["+15550001"].Count)
	}
	if byKey["+15550001"].UnsupportedCount != 1 {
		t.Fatalf("+15550001 unsupported = %d, want 1", byKey["+15550001"].UnsupportedCount)
	}
	if byKey["me"].Label != "You" {
		t.Fatalf("me label = %q, want You", byKey["me"].Label)
	}
	bob := byKey["+15550002"]
	if bob.AttachmentCount != 1 {
		t.Fatalf("bob attachment count = %d, want 1", bob.AttachmentCount)
	}
	if bob.LatestTimestamp == nil || *bob.LatestTimestamp != 500 {
		t.Fatalf("bob latest = %v, want 500", bob.LatestTimestamp)
	}
}

func TestGroupByUnsupportedReason(t *testing.T) {
	groups := GroupDebugMessages(sampleMessages(), "unsupported")
	byKey := map[string]int{}
	for _, g := range groups {
		byKey[g.Key] = g.Count
	}
	if byKey[candidateControl] != 1 {
		t.Fatalf("control group = %d, want 1", byKey[candidateControl])
	}
	if byKey[candidateNoConten] != 1 {
		t.Fatalf("no-content group = %d, want 1", byKey[candidateNoConten])
	}
}

func TestGroupFlatReturnsNil(t *testing.T) {
	if g := GroupDebugMessages(sampleMessages(), "flat"); g != nil {
		t.Fatalf("flat groupBy should return nil, got %v", g)
	}
}

// TestDebugPayloadRedactionByConstruction asserts the debug JSON never carries
// a local file path or a tokenized download URL — only a boolean presence flag.
func TestDebugPayloadRedactionByConstruction(t *testing.T) {
	msg := DebugMessageJSON{
		GUID:     "g1",
		HandleID: sp("+15550001"),
		Text:     sp("hello"),
		Attachments: []DebugAttachmentJSON{{
			GUID:           "att1",
			Filename:       sp("/Users/cinmou/Library/Messages/Attachments/secret.jpg"),
			AttachmentKind: AttachmentKindImage,
			HasDownloadURL: true,
		}},
	}
	AnnotateDebugMessage(&msg)
	raw, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(raw)
	if strings.Contains(s, "localPath") || strings.Contains(s, "downloadUrl\"") {
		t.Fatalf("debug JSON leaked a path/url field: %s", s)
	}
	if !strings.Contains(s, "\"hasDownloadUrl\":true") {
		t.Fatalf("expected hasDownloadUrl flag, got %s", s)
	}
	if strings.Contains(strings.ToLower(s), "bearer ") || strings.Contains(s, "\"token\"") {
		t.Fatalf("debug JSON leaked a token: %s", s)
	}
}
