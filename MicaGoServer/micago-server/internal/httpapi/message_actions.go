package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"micagoserver/internal/imessage"
	"micagoserver/internal/realtime"
	"micagoserver/internal/store"
)

type editMessageRequest struct {
	Text      string `json:"text"`
	PartIndex int    `json:"partIndex"`
}

type messageActionRequest struct {
	PartIndex int `json:"partIndex"`
}

func (h *Handlers) GetMessageActionCapabilities(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.messageActionCapabilities(r.Context()))
}

// capabilityRefresher is the optional cache-invalidation hook a Performer can
// expose so a freshly-installed helper is detected immediately (no TTL wait).
type capabilityRefresher interface{ InvalidateCapabilities() }

// RefreshMessageActionCapabilities drops any cached helper probe, re-scans, and
// returns the fresh capabilities. The Companion calls this right after a helper
// install so /api/server/status + the dedicated capability endpoint report the
// new state without a backend restart. It also broadcasts connection:updated so
// connected clients re-check their gating.
func (h *Handlers) RefreshMessageActionCapabilities(w http.ResponseWriter, r *http.Request) {
	if rf, ok := h.actions.(capabilityRefresher); ok {
		rf.InvalidateCapabilities()
	}
	caps := h.messageActionCapabilities(r.Context())
	if h.send != nil && h.send.Events != nil {
		_ = h.send.Events.Broadcast(r.Context(), realtime.Event{
			Type: "capabilities:updated",
			Data: map[string]any{"messageActions": caps.State},
		})
	}
	writeJSON(w, http.StatusOK, caps)
}

// messageActionCapabilities is the single source of truth for IMCore-helper
// capability detection, shared by the dedicated endpoint (which the Flutter
// client uses to gate Edit/Unsend/Delete) and the server status payload (which
// the companion shows). A missing/unconfigured helper reports unavailable with a
// reason — never a fake "supported".
func (h *Handlers) messageActionCapabilities(ctx context.Context) imessage.Capabilities {
	if h.actions == nil {
		return imessage.Capabilities{
			Available:        false,
			State:            imessage.HelperStateMissing,
			RequiresMessages: true,
			Reason:           "MicaGo IMCore helper is not configured",
		}
	}
	return h.actions.Capabilities(ctx)
}

// messageActionsStatus maps the helper capabilities into the status payload
// shape (the store layer is decoupled from the imessage package).
func (h *Handlers) messageActionsStatus(ctx context.Context) store.ServerMessageActionsStatus {
	c := h.messageActionCapabilities(ctx)
	return store.ServerMessageActionsStatus{
		Available:        c.Available,
		State:            c.State,
		Edit:             c.Edit,
		Retract:          c.Retract,
		Delete:           c.Delete,
		Helper:           c.Helper,
		Reason:           c.Reason,
		RequiresMessages: c.RequiresMessages,
	}
}

func (h *Handlers) EditMessage(w http.ResponseWriter, r *http.Request) {
	chatGUID, messageGUID, ok := h.messageActionPath(w, r)
	if !ok {
		return
	}
	var req editMessageRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	if strings.TrimSpace(req.Text) == "" {
		writeBadRequest(w, "text is required")
		return
	}
	if err := h.requireMessageActions().Edit(r.Context(), imessage.Request{
		Action:      imessage.ActionEdit,
		ChatGUID:    chatGUID,
		MessageGUID: messageGUID,
		Text:        req.Text,
		PartIndex:   req.PartIndex,
	}); err != nil {
		h.writeMessageActionError(w, err)
		return
	}
	h.syncAfterMessageAction(r)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (h *Handlers) RetractMessage(w http.ResponseWriter, r *http.Request) {
	chatGUID, messageGUID, ok := h.messageActionPath(w, r)
	if !ok {
		return
	}
	req := decodeMessageActionRequest(r)
	if err := h.requireMessageActions().Retract(r.Context(), imessage.Request{
		Action:      imessage.ActionRetract,
		ChatGUID:    chatGUID,
		MessageGUID: messageGUID,
		PartIndex:   req.PartIndex,
	}); err != nil {
		h.writeMessageActionError(w, err)
		return
	}
	h.syncAfterMessageAction(r)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (h *Handlers) DeleteMessage(w http.ResponseWriter, r *http.Request) {
	chatGUID, messageGUID, ok := h.messageActionPath(w, r)
	if !ok {
		return
	}
	if err := h.requireMessageActions().Delete(r.Context(), imessage.Request{
		Action:      imessage.ActionDelete,
		ChatGUID:    chatGUID,
		MessageGUID: messageGUID,
	}); err != nil {
		h.writeMessageActionError(w, err)
		return
	}
	h.syncAfterMessageAction(r)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (h *Handlers) messageActionPath(w http.ResponseWriter, r *http.Request) (chatGUID, messageGUID string, ok bool) {
	if h.actions == nil {
		writeAPIError(w, http.StatusNotImplemented, "unsupported", "message actions are not supported by this backend build")
		return "", "", false
	}
	chatGUID = strings.TrimSpace(r.PathValue("guid"))
	messageGUID = strings.TrimSpace(r.PathValue("messageGuid"))
	if chatGUID == "" || messageGUID == "" {
		writeBadRequest(w, "chatGuid and messageGuid are required")
		return "", "", false
	}
	return chatGUID, messageGUID, true
}

func (h *Handlers) requireMessageActions() imessage.Performer { return h.actions }

func (h *Handlers) writeMessageActionError(w http.ResponseWriter, err error) {
	status := imessage.ErrorStatus(err)
	code := imessage.ErrorCode(err)
	writeAPIError(w, status, code, err.Error())
}

func (h *Handlers) syncAfterMessageAction(r *http.Request) {
	if h.syncNow == nil {
		return
	}
	if _, err := h.syncNow(r.Context()); err != nil {
		h.logInternal("message action sync", err)
	}
}

func decodeMessageActionRequest(r *http.Request) messageActionRequest {
	var req messageActionRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	return req
}
