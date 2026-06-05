package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"

	"micagoserver/internal/config"
	"micagoserver/internal/notify"
	"micagoserver/internal/store"
)

type notificationsConfigRequest struct {
	Enabled            bool   `json:"enabled"`
	Provider           string `json:"provider"`
	Preview            string `json:"preview"`
	FCMEnabled         bool   `json:"fcmEnabled"`
	FCMProjectID       string `json:"fcmProjectId"`
	ServiceAccountPath string `json:"serviceAccountPath"`
	PublicURLSync      bool   `json:"publicUrlSync"`
}

// notificationsConfigResponse echoes the resulting status. It never returns the
// service-account contents or any token — only flags/paths/levels.
type notificationsConfigResponse struct {
	store.ServerNotificationStatus
	ServiceAccountPathSet bool `json:"serviceAccountPathSet"`
	FirestoreSyncEnabled  bool `json:"firestoreSyncEnabled"`
}

// PutNotificationsConfig handles POST /api/server/notifications (v0.12): persist
// notification/FCM/Firebase settings and apply them to the live dispatcher.
func (h *Handlers) PutNotificationsConfig(w http.ResponseWriter, r *http.Request) {
	if h.notifyConfig == nil {
		writeInternalError(w)
		return
	}

	var req notificationsConfigRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	req.Provider = strings.TrimSpace(req.Provider)
	req.Preview = strings.TrimSpace(req.Preview)
	req.ServiceAccountPath = strings.TrimSpace(req.ServiceAccountPath)

	if req.Preview != "none" && req.Preview != "sender" && req.Preview != "sender_and_text" {
		writeBadRequest(w, "preview must be one of: none, sender, sender_and_text")
		return
	}
	switch req.Provider {
	case "none", "webhook", "fcm", "hms", "harmony_push", "ntfy":
	default:
		writeBadRequest(w, "provider must be one of: none, webhook, fcm, hms, harmony_push, ntfy")
		return
	}

	// Validate the service account up front so the user gets a clear error.
	if req.FCMEnabled {
		if req.ServiceAccountPath == "" {
			writeBadRequest(w, "serviceAccountPath is required when fcmEnabled is true")
			return
		}
		if _, err := notify.LoadServiceAccount(req.ServiceAccountPath); err != nil {
			writeBadRequest(w, "invalid service account: "+err.Error())
			return
		}
	}

	if err := config.UpdateNotificationsConfig(h.cfg.ConfigPath, config.NotificationsUpdate{
		Enabled:            req.Enabled,
		Provider:           req.Provider,
		Preview:            req.Preview,
		FCMEnabled:         req.FCMEnabled,
		FCMProjectID:       req.FCMProjectID,
		ServiceAccountPath: req.ServiceAccountPath,
		PublicURLSync:      req.PublicURLSync,
	}); err != nil {
		writeBadRequest(w, err.Error())
		return
	}

	// Reload from the freshly-written config so the dispatcher (and status)
	// reflect the change without a restart.
	fresh, err := config.Load(config.Options{})
	if err != nil {
		h.logInternal("reload config after notifications update", err)
		writeInternalError(w)
		return
	}
	h.notifyConfig.Reload(fresh)

	writeJSON(w, http.StatusOK, notificationsConfigResponse{
		ServerNotificationStatus: h.notificationStatus(),
		ServiceAccountPathSet:    req.ServiceAccountPath != "",
		FirestoreSyncEnabled:     h.notifyConfig.FirestoreSyncEnabled(),
	})
}
