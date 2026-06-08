package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"micagoserver/internal/store"
)

type fakeDebugService struct {
	rows     []store.DebugMessageJSON
	lastOpts store.DebugListOptions
}

func (f *fakeDebugService) ListDebugRecentMessages(_ context.Context, opts store.DebugListOptions, _ map[string]bool) ([]store.DebugMessageJSON, error) {
	f.lastOpts = opts
	return f.rows, nil
}

func sp(s string) *string { return &s }
func i64(n int64) *int64  { return &n }

func debugSample() []store.DebugMessageJSON {
	return []store.DebugMessageJSON{
		{GUID: "1", Text: sp("Hello"), HandleID: sp("+15550001"), ChatGUID: sp("cA"), ChatDisplayName: sp("Alice"), DateCreated: i64(100)},
		{GUID: "2", Text: sp("+!"), HandleID: sp("+15550001"), ChatGUID: sp("cA"), ChatDisplayName: sp("Alice"), DateCreated: i64(200)},
		{GUID: "3", HandleID: sp("+15550002"), ChatGUID: sp("cB"),
			Attachments: []store.DebugAttachmentJSON{{GUID: "att1", AttachmentKind: store.AttachmentKindImage, Filename: sp("p.jpg")}},
			DateCreated: i64(300)},
	}
}

func newDebugHandlers(rows []store.DebugMessageJSON) (*Handlers, *fakeDebugService) {
	h := newTestHandlers(&stubQueries{})
	svc := &fakeDebugService{rows: rows}
	h.SetDebugService(svc, map[string]bool{"item_type": true})
	return h, svc
}

func TestDebugRecentMessagesUnavailable(t *testing.T) {
	h := newTestHandlers(&stubQueries{}) // no SetDebugService
	req := httptest.NewRequest(http.MethodGet, "/api/debug/recent-messages", nil)
	rec := httptest.NewRecorder()
	h.GetDebugRecentMessages(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 when debug disabled, got %d", rec.Code)
	}
}

func TestDebugRecentMessagesAnnotatesAndReturnsAll(t *testing.T) {
	h, _ := newDebugHandlers(debugSample())
	req := httptest.NewRequest(http.MethodGet, "/api/debug/recent-messages", nil)
	rec := httptest.NewRecorder()
	h.GetDebugRecentMessages(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var resp DebugRecentMessagesResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(resp.Data) != 3 {
		t.Fatalf("expected 3 rows, got %d", len(resp.Data))
	}
	// Classification was applied server-side.
	kinds := map[string]string{}
	for _, m := range resp.Data {
		kinds[m.GUID] = m.Kind
	}
	if kinds["1"] != store.KindText || kinds["2"] != store.KindUnsupported || kinds["3"] != store.KindImage {
		t.Fatalf("unexpected kinds: %+v", kinds)
	}
}

func TestDebugRecentMessagesTypeFilter(t *testing.T) {
	h, _ := newDebugHandlers(debugSample())
	req := httptest.NewRequest(http.MethodGet, "/api/debug/recent-messages?type=unsupported", nil)
	rec := httptest.NewRecorder()
	h.GetDebugRecentMessages(rec, req)

	var resp DebugRecentMessagesResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if len(resp.Data) != 1 || resp.Data[0].GUID != "2" {
		t.Fatalf("type=unsupported should return only guid 2, got %+v", resp.Data)
	}
	if resp.Meta.Total != 1 {
		t.Fatalf("meta total = %d, want 1", resp.Meta.Total)
	}
}

func TestDebugRecentMessagesGroupBySender(t *testing.T) {
	h, _ := newDebugHandlers(debugSample())
	req := httptest.NewRequest(http.MethodGet, "/api/debug/recent-messages?groupBy=sender", nil)
	rec := httptest.NewRecorder()
	h.GetDebugRecentMessages(rec, req)

	var resp DebugRecentMessagesResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if len(resp.Groups) != 2 {
		t.Fatalf("expected 2 sender groups, got %d", len(resp.Groups))
	}
	// +15550001 has 2 messages (one unsupported) and sorts first by count.
	if resp.Groups[0].Key != "+15550001" || resp.Groups[0].Count != 2 {
		t.Fatalf("unexpected first group: %+v", resp.Groups[0])
	}
	if resp.Groups[0].UnsupportedCount != 1 {
		t.Fatalf("expected 1 unsupported in first group, got %d", resp.Groups[0].UnsupportedCount)
	}
}

func TestDebugRecentMessagesPassesStructuralFilters(t *testing.T) {
	h, svc := newDebugHandlers(debugSample())
	req := httptest.NewRequest(http.MethodGet,
		"/api/debug/recent-messages?chatGuid=cA&sender=%2B15550001&direction=incoming&limit=25&offset=5", nil)
	rec := httptest.NewRecorder()
	h.GetDebugRecentMessages(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if svc.lastOpts.ChatGUID != "cA" || svc.lastOpts.Sender != "+15550001" ||
		svc.lastOpts.Direction != "incoming" || svc.lastOpts.Limit != 25 || svc.lastOpts.Offset != 5 {
		t.Fatalf("structural filters not forwarded: %+v", svc.lastOpts)
	}
}

func TestDebugRecentMessagesRejectsBadParams(t *testing.T) {
	h, _ := newDebugHandlers(debugSample())
	for _, q := range []string{"?direction=sideways", "?type=banana", "?groupBy=color", "?hasAttachments=maybe", "?limit=9999"} {
		req := httptest.NewRequest(http.MethodGet, "/api/debug/recent-messages"+q, nil)
		rec := httptest.NewRecorder()
		h.GetDebugRecentMessages(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("expected 400 for %q, got %d", q, rec.Code)
		}
	}
}
