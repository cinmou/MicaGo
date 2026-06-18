package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"

	"micagoserver/internal/imessage"
)

type editMessageRequest struct {
	Text      string `json:"text"`
	PartIndex int    `json:"partIndex"`
}

type messageActionRequest struct {
	PartIndex int `json:"partIndex"`
}

func (h *Handlers) GetMessageActionCapabilities(w http.ResponseWriter, r *http.Request) {
	if h.actions == nil {
		writeJSON(w, http.StatusOK, imessage.Capabilities{
			Available:        false,
			RequiresMessages: true,
			Reason:           "MicaGo IMCore helper is not configured",
		})
		return
	}
	writeJSON(w, http.StatusOK, h.actions.Capabilities(r.Context()))
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
