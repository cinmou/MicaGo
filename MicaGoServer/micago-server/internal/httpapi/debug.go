package httpapi

import (
	"context"
	"net/http"
	"strings"

	"micagoserver/internal/store"
)

// debugQueryService is the rich chat.db source backing the message inspector.
// It is the live chat.db (*store.Queries), independent of the api-store mode, so
// the inspector can see iMessage fields the synced relay does not keep.
type debugQueryService interface {
	ListDebugRecentMessages(ctx context.Context, opts store.DebugListOptions, cols map[string]bool) ([]store.DebugMessageJSON, error)
}

// SetDebugService wires the debug message inspector source (live chat.db) plus
// the set of available `message` columns used for capability-gated selection.
// Nil disables GET /api/debug/recent-messages.
func (h *Handlers) SetDebugService(svc debugQueryService, messageColumns map[string]bool) {
	h.debug = svc
	h.debugColumns = messageColumns
}

// DebugRecentMessagesResponse is the inspector payload. `groups` is present only
// when a groupBy mode was requested. All fields are redaction-safe by
// construction (no token, local paths, or tokenized URLs).
type DebugRecentMessagesResponse struct {
	Data   []store.DebugMessageJSON `json:"data"`
	Groups []store.DebugGroup       `json:"groups,omitempty"`
	Meta   DebugMeta                `json:"meta"`
}

type DebugMeta struct {
	Limit   int    `json:"limit"`
	Offset  int    `json:"offset"`
	GroupBy string `json:"groupBy"`
	Total   int    `json:"total"` // rows after filtering
}

var allowedDebugTypes = map[string]bool{
	"": true, "all": true, "text": true, "attachment": true,
	"image": true, "video": true, "audio": true, "voice": true,
	"file": true, "reaction": true, "reply": true, "service": true,
	"unknown": true, "unsupported": true,
}

var allowedDebugAttachmentFilters = map[string]bool{
	"": true, "all": true, "has": true, "none": true,
	"image": true, "audio": true, "unsupported": true,
}

var allowedDebugGroupBy = map[string]bool{
	"": true, "flat": true, "none": true,
	"sender": true, "chat": true, "type": true, "unsupported": true,
}

var allowedDebugDirection = map[string]bool{
	"": true, "all": true, "incoming": true, "outgoing": true,
}

// GetDebugRecentMessages serves the companion Message Inspector. Bearer auth is
// enforced by the router wrapper. Structural filters (chat/sender/direction,
// limit/offset) run in SQL; query/type/attachment refinement and grouping run
// in Go on the fetched page.
func (h *Handlers) GetDebugRecentMessages(w http.ResponseWriter, r *http.Request) {
	if h.debug == nil {
		writeNotFound(w, "debug inspector is not available")
		return
	}

	limit, offset, ok := parseListParams(w, r)
	if !ok {
		return
	}

	q := r.URL.Query()
	direction := strings.TrimSpace(q.Get("direction"))
	if !allowedDebugDirection[direction] {
		writeBadRequest(w, "direction must be one of all, incoming, outgoing")
		return
	}
	if direction == "all" {
		direction = ""
	}

	typeFilter := strings.TrimSpace(q.Get("type"))
	if !allowedDebugTypes[typeFilter] {
		writeBadRequest(w, "invalid type filter")
		return
	}

	attFilter := strings.TrimSpace(q.Get("hasAttachments"))
	if !allowedDebugAttachmentFilters[attFilter] {
		writeBadRequest(w, "invalid hasAttachments filter")
		return
	}

	groupBy := strings.TrimSpace(q.Get("groupBy"))
	if !allowedDebugGroupBy[groupBy] {
		writeBadRequest(w, "invalid groupBy")
		return
	}

	opts := store.DebugListOptions{
		ChatGUID:  strings.TrimSpace(q.Get("chatGuid")),
		Sender:    strings.TrimSpace(q.Get("sender")),
		Direction: direction,
		Limit:     limit,
		Offset:    offset,
	}

	rows, err := h.debug.ListDebugRecentMessages(r.Context(), opts, h.debugColumns)
	if err != nil {
		h.logInternal("list debug recent messages", err)
		writeInternalError(w)
		return
	}

	for i := range rows {
		store.AnnotateDebugMessage(&rows[i])
	}

	filtered := store.FilterDebugMessages(rows, store.DebugFilter{
		Query:          q.Get("q"),
		Type:           typeFilter,
		HasAttachments: attFilter,
	})

	resp := DebugRecentMessagesResponse{
		Data: filtered,
		Meta: DebugMeta{Limit: limit, Offset: offset, GroupBy: groupBy, Total: len(filtered)},
	}
	if groups := store.GroupDebugMessages(filtered, groupBy); groups != nil {
		resp.Groups = groups
	}
	if resp.Data == nil {
		resp.Data = []store.DebugMessageJSON{}
	}

	writeJSON(w, http.StatusOK, resp)
}
