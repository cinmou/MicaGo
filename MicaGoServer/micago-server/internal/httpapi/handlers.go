package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"mime"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"micagoserver/internal/config"
	"micagoserver/internal/notify"
	"micagoserver/internal/realtime"
	"micagoserver/internal/relaydb"
	micasend "micagoserver/internal/send"
	"micagoserver/internal/store"
	"micagoserver/internal/version"
)

const (
	defaultLimit    = 100
	maxLimit        = 500
	defaultOffset   = 0
	defaultService  = "all"
	serviceAll      = "all"
	serviceIMessage = "iMessage"
	serviceSMS      = "SMS"
	serviceRCS      = "RCS"
	serviceUnknown  = "unknown"
)

type queryService interface {
	ListRecentMessages(ctx context.Context, limit, offset int, service string, includeEmpty bool) ([]store.MessageJSON, error)
	ListChats(ctx context.Context, limit, offset int, withArchived bool, service string, includeDebug bool) ([]store.ChatJSON, error)
	ChatExists(ctx context.Context, guid string) (bool, error)
	GetChatInfo(ctx context.Context, guid string) (*store.ChatInfo, error)
	ListChatMessages(ctx context.Context, guid string, limit, offset int, includeEmpty bool) ([]store.MessageJSON, error)
	FindOutgoingMessageMatch(ctx context.Context, guid string, normalizedText string, sentAtUnixMilli int64, excludedGUIDs map[string]struct{}) (*store.MessageJSON, error)
}

type pendingSendManager interface {
	Add(micasend.PendingSend) error
	Remove(string)
	Has(string) bool
	Resolve(tempGUID, matchedGUID string, matchedROWID int64) bool
	Reject(tempGUID, reason string)
	MarkSentUnconfirmed(tempGUID, reason string, recoverFor time.Duration)
	ClaimedSnapshot() map[string]struct{}
}

type SendDependencies struct {
	Pending pendingSendManager
	Sender  micasend.Sender
	SyncNow func(context.Context) error
	Events  eventBroadcaster
	// ErrorFinder reads message.error from chat.db so a failed send can be
	// reported before the timeout (v0.11.x). Only consulted when the
	// SendError schema capability is present. May be nil.
	ErrorFinder outgoingErrorFinder
	// MessagesRunning is a fast, macOS-local precondition checked before an
	// AppleScript send (Messages.app must be open). Nil skips the check; a probe
	// error is logged and the send proceeds rather than being wrongly blocked.
	MessagesRunning func(ctx context.Context) (bool, error)
}

type outgoingErrorFinder interface {
	FindOutgoingMessageError(ctx context.Context, guid string, normalizedText string, sentAtUnixMilli int64) (int64, bool, error)
}

type attachmentService interface {
	GetAttachmentByGUID(ctx context.Context, guid string) (*store.AttachmentMeta, error)
}

type deviceService interface {
	UpsertDevice(ctx context.Context, device store.DeviceRecord) (*store.DeviceRecord, error)
	GetDeviceByID(ctx context.Context, id string) (*store.DeviceRecord, error)
	ListDevices(ctx context.Context) ([]store.DeviceRecord, error)
	UpdateDeviceHeartbeat(ctx context.Context, id string, at int64) (*store.DeviceRecord, error)
	DeleteDevice(ctx context.Context, id string) error
}

type eventBroadcaster interface {
	Broadcast(context.Context, realtime.Event) error
}

type notificationDispatcher interface {
	SendTest(ctx context.Context, device store.DeviceRecord) error
	ProviderNames() []string
	ImplementedProviders() []string
	Enabled() bool
	PreviewMode() string
	DefaultProvider() string
}

// notificationConfigurator lets the notifications-config endpoint apply changes
// to the live dispatcher without a restart (implemented by *notify.Dispatcher).
type notificationConfigurator interface {
	Reload(cfg config.Config)
	FirestoreSyncEnabled() bool
}

type syncSettingsService interface {
	GetSyncSettings(ctx context.Context) (relaydb.SyncSettings, error)
	SetSyncSettings(ctx context.Context, settings relaydb.SyncSettings) (relaydb.SyncSettings, error)
}

type sendRequest struct {
	TempGUID string `json:"tempGuid"`
	Message  string `json:"message"`
}

type deviceRegisterRequest struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Platform     string `json:"platform"`
	ClientType   string `json:"clientType"`
	PushProvider string `json:"pushProvider"`
	PushToken    string `json:"pushToken"`
	PushEnabled  bool   `json:"pushEnabled"`
}

type devicePatchRequest struct {
	Name         *string `json:"name"`
	PushProvider *string `json:"pushProvider"`
	PushToken    *string `json:"pushToken"`
	PushEnabled  *bool   `json:"pushEnabled"`
}

// StatusDeps carries the runtime values reported by GET /api/server/status that
// are not already available from the static server config. All fields are
// optional; nil function fields are treated as "unavailable".
type StatusDeps struct {
	APIStore    string
	ClientCount func() int
	SyncState   func(key string) (string, bool, error)
	// Network owns the optional public connection endpoint (v0.11). Nil disables
	// the public-url endpoints; local/LAN aggregation still works.
	Network *NetworkController
	// Capabilities reports detected chat.db schema support (v0.11.x). Zero value
	// (all false) is a safe default when the schema was not probed.
	Capabilities    store.SchemaCapabilities
	SyncDiagnostics func() store.ServerSyncDiagnostics
	// Backend identifies the exact running binary (C17): executable path,
	// version/commit/buildTime, config + DB paths, and the chat.db open options
	// (so the absence of immutable=1 is verifiable). Nil omits the block.
	Backend *store.ServerBackendStatus
	// SyncSettings returns the live relay sync settings (backfill mode, service
	// scope) for the status echo. Nil omits them.
	SyncSettings func(ctx context.Context) *store.ServerSyncSettings
}

// implementedNotificationProviders are providers that actually deliver today;
// all others advertised by the dispatcher are stubs. Keep in sync with
// internal/notify.
var implementedNotificationProviders = []string{"none", "webhook"}

type Handlers struct {
	queries         queryService
	logger          *log.Logger
	send            *SendDependencies
	attachments     attachmentService
	attachmentsRoot string
	devices         deviceService
	notify          notificationDispatcher
	serverInfo      store.ServerInfoResponse
	cfg             config.Config
	status          StatusDeps
	startedAt       int64
	rules           ruleService
	notifyConfig    notificationConfigurator
	debug           debugQueryService
	debugColumns    map[string]bool
	syncNow         func(context.Context) (store.ServerSyncDiagnostics, error)
	syncSettings    syncSettingsService
}

// SetRuleService wires the v0.11.3 sync-rule store after construction (kept off
// the constructor to avoid churning every NewHandlers call site). Nil means the
// rule endpoints are unavailable.
func (h *Handlers) SetRuleService(rs ruleService) { h.rules = rs }

// SetNotificationConfigurator wires the v0.12 live dispatcher reload used by the
// notifications-config write endpoint. Nil means that endpoint is unavailable.
func (h *Handlers) SetNotificationConfigurator(c notificationConfigurator) { h.notifyConfig = c }

func (h *Handlers) SetSyncNow(fn func(context.Context) (store.ServerSyncDiagnostics, error)) {
	h.syncNow = fn
}

func (h *Handlers) SetSyncSettingsService(svc syncSettingsService) {
	h.syncSettings = svc
}

func NewHandlers(
	queries queryService,
	logger *log.Logger,
	sendDeps *SendDependencies,
	attachments attachmentService,
	attachmentsRoot string,
	devices deviceService,
	notifier notificationDispatcher,
	serverCfg config.Config,
	status StatusDeps,
) *Handlers {
	notificationProviders := []string{"none", "webhook", "fcm", "hms", "harmony_push", "ntfy"}
	if notifier != nil {
		notificationProviders = notifier.ProviderNames()
	}
	return &Handlers{
		queries:         queries,
		logger:          logger,
		send:            sendDeps,
		attachments:     attachments,
		attachmentsRoot: attachmentsRoot,
		devices:         devices,
		notify:          notifier,
		cfg:             serverCfg,
		status:          status,
		startedAt:       time.Now().UnixMilli(),
		serverInfo: store.ServerInfoResponse{
			Name:         "MicaGoServer",
			Version:      version.Version,
			BaseURL:      config.DeriveBaseURL(serverCfg),
			WebSocketURL: config.DeriveWebSocketURL(serverCfg),
			Features: store.ServerFeatures{
				Chats:         true,
				Messages:      true,
				SendText:      true,
				Attachments:   true,
				WebSocket:     true,
				Devices:       true,
				Notifications: true,
			},
			NotificationProviders: notificationProviders,
		},
	}
}

func (h *Handlers) GetHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, store.HealthResponse{OK: true})
}

func (h *Handlers) GetServerInfo(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, h.serverInfo)
}

func (h *Handlers) CheckAuth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, store.HealthResponse{OK: true})
}

// GetServerStatus reports runtime status for the native macOS companion app.
// It is read-only and never returns the bearer token or any push token.
func (h *Handlers) GetServerStatus(w http.ResponseWriter, r *http.Request) {
	now := time.Now().UnixMilli()
	status := store.ServerStatusResponse{
		OK:            true,
		Version:       h.serverInfo.Version,
		StartedAt:     h.startedAt,
		UptimeSeconds: (now - h.startedAt) / 1000,
		Address: store.ServerAddressStatus{
			Listen:       h.cfg.HTTPAddr,
			BaseURL:      h.serverInfo.BaseURL,
			WebSocketURL: h.serverInfo.WebSocketURL,
			LAN:          lanAddresses(h.cfg.HTTPAddr),
		},
		Store: h.status.APIStore,
		Auth:  store.ServerAuthStatus{Enabled: !h.cfg.AuthDisabled},
		Sync: store.ServerSyncStatus{
			LoopEnabled:     !h.cfg.DisableSyncLoop,
			IntervalSeconds: int64(h.cfg.SyncInterval / time.Second),
		},
		Notifications: h.notificationStatus(),
		Devices:       store.ServerDevicesStatus{Count: h.deviceCount(r.Context())},
		WebSocket:     store.ServerWebSocketStatus{Clients: h.clientCount()},
		Permissions:   h.permissionStatus(),
		Capabilities:  store.ServerCapabilities{Schema: h.status.Capabilities},
	}

	if h.status.SyncState != nil {
		status.Sync.LastSyncAt = readSyncStateInt(h.status.SyncState, "last_sync_at")
		status.Sync.LastMessageRowID = readSyncStateInt(h.status.SyncState, "last_message_rowid")
	}
	if h.status.SyncDiagnostics != nil {
		diagnostics := h.status.SyncDiagnostics()
		status.Sync.Diagnostics = &diagnostics
	}
	// C17: identify the exact running binary + the live sync settings so the
	// companion can prove the launched backend is the intended build.
	status.Backend = h.status.Backend
	if h.status.SyncSettings != nil {
		status.Sync.Settings = h.status.SyncSettings(r.Context())
	}

	writeJSON(w, http.StatusOK, status)
}

func (h *Handlers) SyncNow(w http.ResponseWriter, r *http.Request) {
	if h.syncNow == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "sync_unavailable", "sync is not available")
		return
	}
	diagnostics, err := h.syncNow(r.Context())
	if err != nil {
		h.logInternal("sync now", err)
		writeInternalError(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"diagnostics": diagnostics,
	})
}

func (h *Handlers) GetSyncSettings(w http.ResponseWriter, r *http.Request) {
	if h.syncSettings == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "sync_settings_unavailable", "sync settings are not available")
		return
	}
	settings, err := h.syncSettings.GetSyncSettings(r.Context())
	if err != nil {
		h.logInternal("get sync settings", err)
		writeInternalError(w)
		return
	}
	writeJSON(w, http.StatusOK, settings)
}

func (h *Handlers) PutSyncSettings(w http.ResponseWriter, r *http.Request) {
	if h.syncSettings == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "sync_settings_unavailable", "sync settings are not available")
		return
	}
	var req relaydb.SyncSettings
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	settings, err := h.syncSettings.SetSyncSettings(r.Context(), req)
	if err != nil {
		h.logInternal("put sync settings", err)
		writeInternalError(w)
		return
	}
	var diagnostics *store.ServerSyncDiagnostics
	if h.syncNow != nil {
		if d, err := h.syncNow(r.Context()); err == nil {
			diagnostics = &d
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"settings": settings, "diagnostics": diagnostics})
}

func (h *Handlers) clientCount() int {
	if h.status.ClientCount == nil {
		return 0
	}
	return h.status.ClientCount()
}

func (h *Handlers) deviceCount(ctx context.Context) int {
	if h.devices == nil {
		return 0
	}
	devices, err := h.devices.ListDevices(ctx)
	if err != nil {
		h.logInternal("status device count", err)
		return 0
	}
	return len(devices)
}

func (h *Handlers) notificationStatus() store.ServerNotificationStatus {
	providers := h.serverInfo.NotificationProviders

	// Prefer the live dispatcher (reflects runtime config reloads); fall back to
	// static config when no dispatcher is wired (e.g. in tests).
	enabled := h.cfg.NotificationsEnabled
	provider := h.cfg.NotificationProvider
	preview := h.cfg.NotificationPreview
	implementedSet := implementedNotificationProviders
	if h.notify != nil {
		enabled = h.notify.Enabled()
		provider = h.notify.DefaultProvider()
		preview = h.notify.PreviewMode()
		implementedSet = h.notify.ImplementedProviders()
	}

	implemented := make([]string, 0, len(providers))
	stub := make([]string, 0, len(providers))
	for _, p := range providers {
		if slices.Contains(implementedSet, p) {
			implemented = append(implemented, p)
		} else {
			stub = append(stub, p)
		}
	}
	return store.ServerNotificationStatus{
		Enabled:     enabled,
		Provider:    provider,
		Preview:     preview,
		Providers:   providers,
		Implemented: implemented,
		Stub:        stub,
	}
}

func (h *Handlers) permissionStatus() store.ServerPermissionStatus {
	return store.ServerPermissionStatus{
		FullDiskAccess: probeReadable(h.cfg.DBPath,
			"reads ~/Library/Messages/chat.db; grant Full Disk Access to the server (or its launcher) in System Settings > Privacy & Security"),
		Attachments: probeReadable(h.attachmentsRoot,
			"reads ~/Library/Messages/Attachments for attachment downloads"),
		Automation: store.PermissionCheck{
			Status: "unknown",
			Detail: "Automation (AppleScript control of Messages) cannot be probed without sending; verify in System Settings > Privacy & Security > Automation",
		},
	}
}

// probeReadable opens the given path read-only to determine whether the server
// process currently has access. A permission error reports "denied"; a missing
// path or other error reports "unknown".
func probeReadable(path, detail string) store.PermissionCheck {
	if strings.TrimSpace(path) == "" {
		return store.PermissionCheck{Status: "unknown", Detail: detail}
	}
	f, err := os.Open(path)
	if err == nil {
		_ = f.Close()
		return store.PermissionCheck{Status: "ok", Detail: detail}
	}
	if errors.Is(err, os.ErrPermission) {
		return store.PermissionCheck{Status: "denied", Detail: detail}
	}
	return store.PermissionCheck{Status: "unknown", Detail: detail}
}

func readSyncStateInt(get func(string) (string, bool, error), key string) *int64 {
	raw, ok, err := get(key)
	if err != nil || !ok {
		return nil
	}
	v, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil {
		return nil
	}
	return &v
}

// lanAddresses returns non-loopback IPv4 host:port endpoints the server is
// reachable on, derived from the configured listen address' port. It is a
// best-effort helper for the companion app's "LAN address" display.
func lanAddresses(listenAddr string) []string {
	_, port, err := net.SplitHostPort(listenAddr)
	if err != nil || port == "" {
		port = "3000"
	}
	ifaces, err := net.Interfaces()
	if err != nil {
		return []string{}
	}
	out := make([]string, 0)
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
				continue
			}
			out = append(out, net.JoinHostPort(ip4.String(), port))
		}
	}
	return out
}

func (h *Handlers) GetRecentMessages(w http.ResponseWriter, r *http.Request) {
	limit, offset, ok := parseListParams(w, r)
	if !ok {
		return
	}

	service, err := parseService(r)
	if err != nil {
		writeBadRequest(w, err.Error())
		return
	}

	// The raw/debug timeline is requested with ?debug=true (canonical) or the
	// legacy ?include_empty=true alias. Both bypass the renderable filter.
	raw, err := parseRawTimeline(r)
	if err != nil {
		writeBadRequest(w, err.Error())
		return
	}

	data, err := h.queries.ListRecentMessages(r.Context(), limit, offset, service, raw)
	if err != nil {
		h.logInternal("list recent messages", err)
		writeInternalError(w)
		return
	}

	writeJSON(w, http.StatusOK, store.MessageListResponse{
		Data: data,
		Meta: store.ListMeta{Limit: limit, Offset: offset},
	})
}

func (h *Handlers) GetChats(w http.ResponseWriter, r *http.Request) {
	limit, offset, ok := parseListParams(w, r)
	if !ok {
		return
	}

	withArchived, err := parseWithArchived(r)
	if err != nil {
		writeBadRequest(w, err.Error())
		return
	}

	service, err := parseService(r)
	if err != nil {
		writeBadRequest(w, err.Error())
		return
	}

	debug, err := parseDebug(r)
	if err != nil {
		writeBadRequest(w, err.Error())
		return
	}

	data, err := h.queries.ListChats(r.Context(), limit, offset, withArchived, service, debug)
	if err != nil {
		h.logInternal("list chats", err)
		writeInternalError(w)
		return
	}

	writeJSON(w, http.StatusOK, store.ChatListResponse{
		Data: data,
		Meta: store.ListMeta{Limit: limit, Offset: offset},
	})
}

func (h *Handlers) GetChatMessages(w http.ResponseWriter, r *http.Request) {
	limit, offset, ok := parseListParams(w, r)
	if !ok {
		return
	}

	guid := r.PathValue("guid")
	exists, err := h.queries.ChatExists(r.Context(), guid)
	if err != nil {
		h.logInternal("check chat exists", err)
		writeInternalError(w)
		return
	}
	if !exists {
		writeNotFound(w, "chat not found")
		return
	}

	// One canonical thread path: the relay filters debug-only/noise rows in SQL
	// (before pagination) for the normal renderable timeline. ?debug=true (or the
	// legacy ?include_empty=true alias) returns the raw thread for the Inspector.
	raw, err := parseRawTimeline(r)
	if err != nil {
		writeBadRequest(w, err.Error())
		return
	}

	data, err := h.queries.ListChatMessages(r.Context(), guid, limit, offset, raw)
	if err != nil {
		h.logInternal("list chat messages", err)
		writeInternalError(w)
		return
	}

	writeJSON(w, http.StatusOK, store.MessageListResponse{
		Data: data,
		Meta: store.ListMeta{Limit: limit, Offset: offset},
	})
}

func (h *Handlers) SendText(w http.ResponseWriter, r *http.Request) {
	if h.send == nil || h.send.Pending == nil || h.send.Sender == nil {
		writeInternalError(w)
		return
	}

	guid := r.PathValue("guid")
	chatInfo, err := h.queries.GetChatInfo(r.Context(), guid)
	if err != nil {
		h.logInternal("get chat info", err)
		writeInternalError(w)
		return
	}
	if chatInfo == nil {
		writeNotFound(w, "chat not found")
		return
	}
	if chatInfo.ServiceName == nil || *chatInfo.ServiceName != serviceIMessage {
		writeBadRequest(w, "chat must be an iMessage chat")
		return
	}

	var req sendRequest
	decoder := json.NewDecoder(r.Body)
	if err := decoder.Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}

	req.TempGUID = strings.TrimSpace(req.TempGUID)
	req.Message = strings.TrimSpace(req.Message)
	if req.TempGUID == "" {
		writeBadRequest(w, "tempGuid is required")
		return
	}
	if req.Message == "" {
		writeBadRequest(w, "message is required")
		return
	}

	const confirmationTimeout = 20 * time.Second
	const lateReconciliationWindow = 2 * time.Minute

	now := time.Now()
	pending := micasend.PendingSend{
		TempGUID:          req.TempGUID,
		ChatGUID:          guid,
		OriginalMessage:   req.Message,
		NormalizedMessage: micasend.NormalizeText(req.Message),
		// Backdate slightly so clock skew / rounding never excludes the row.
		SentAtUnixMilli: now.Add(-10 * time.Second).UnixMilli(),
		CreatedAt:       now,
		Timeout:         confirmationTimeout,
	}

	h.logSend(req.TempGUID, "request received", fmt.Sprintf("chat=%s len=%d", guid, len(req.Message)))

	if err := h.send.Pending.Add(pending); err != nil {
		if errors.Is(err, micasend.ErrDuplicateTempGUID) {
			writeConflict(w, "tempGuid is already pending")
			return
		}
		h.logInternal("add pending send", err)
		writeInternalError(w)
		return
	}
	removePendingOnReturn := true
	defer func() {
		if removePendingOnReturn {
			h.send.Pending.Remove(req.TempGUID)
		}
	}()
	h.logSend(req.TempGUID, "pending created", "")
	h.broadcastSendPending(r.Context(), req.TempGUID, guid)

	// Fast precondition: AppleScript send needs Messages.app running. Detect and
	// return a clear error instead of waiting out the send timeout.
	if h.send.MessagesRunning != nil {
		running, err := h.send.MessagesRunning(r.Context())
		if err != nil {
			h.logInternal("messages running check", err) // probe failed; proceed
		} else if !running {
			const msg = "Messages.app is not running; open Messages and retry"
			h.send.Pending.Reject(req.TempGUID, "messages_app_not_running")
			h.broadcastSendError(r.Context(), req.TempGUID, guid, "messages_app_not_running", msg)
			writeAPIError(w, http.StatusConflict, "messages_app_not_running", msg)
			return
		}
	}

	// Single AppleScript attempt (conservative: no automatic Messages restart).
	// osascript success only means "send requested", not "delivered".
	h.logSend(req.TempGUID, "applescript started", "")
	if err := h.send.Sender.SendText(r.Context(), guid, req.Message); err != nil {
		h.logSend(req.TempGUID, "applescript failed", err.Error())
		h.send.Pending.Reject(req.TempGUID, "send_failed")
		h.broadcastSendError(r.Context(), req.TempGUID, guid, "send_failed", "failed to send message")
		writeAPIError(w, http.StatusInternalServerError, "send_failed", "failed to send message")
		return
	}
	h.logSend(req.TempGUID, "applescript ok", "")

	if h.send.SyncNow != nil {
		if err := h.send.SyncNow(r.Context()); err != nil {
			h.logInternal("sync after send", err)
		}
	}

	// Confirmation: poll chat.db until the matching outgoing row appears or we
	// time out. Exclude rows already claimed by other in-flight sends so two
	// concurrent identical sends never confirm against the same message.
	h.logSend(req.TempGUID, "confirmation poll started", fmt.Sprintf("timeout=%s", confirmationTimeout))
	excluded := h.send.Pending.ClaimedSnapshot()
	deadline := now.Add(pending.Timeout)
	for time.Now().Before(deadline) {
		if h.send.SyncNow != nil {
			if err := h.send.SyncNow(r.Context()); err != nil {
				h.logInternal("sync during send confirmation", err)
			}
		}
		match, err := h.queries.FindOutgoingMessageMatch(r.Context(), guid, pending.NormalizedMessage, pending.SentAtUnixMilli, excluded)
		if err != nil {
			h.logInternal("find outgoing message match", err)
			writeInternalError(w)
			return
		}
		if match != nil {
			h.logSend(req.TempGUID, "candidate found", fmt.Sprintf("guid=%s", match.GUID))
			if h.send.Pending.Resolve(req.TempGUID, match.GUID, 0) {
				h.logSend(req.TempGUID, "confirmed", fmt.Sprintf("guid=%s", match.GUID))
				h.broadcastSendMatch(r.Context(), req.TempGUID, *match)
				writeJSON(w, http.StatusOK, match)
				return
			}
			// Row already claimed by another send: skip it and keep looking.
			excluded[match.GUID] = struct{}{}
			continue
		}

		// Fast-fail: if the message landed in chat.db with a non-zero error,
		// report it immediately instead of waiting out the timeout. Gated by the
		// SendError schema capability so we never touch m.error when absent.
		if h.status.Capabilities.SendError && h.send.ErrorFinder != nil {
			code, found, err := h.send.ErrorFinder.FindOutgoingMessageError(r.Context(), guid, pending.NormalizedMessage, pending.SentAtUnixMilli)
			if err != nil {
				h.logInternal("find outgoing message error", err)
			} else if found {
				message := fmt.Sprintf("message failed to send (error %d)", code)
				h.logSend(req.TempGUID, "applescript failed", fmt.Sprintf("chat.db error=%d", code))
				h.send.Pending.Reject(req.TempGUID, "send_error")
				h.broadcastSendError(r.Context(), req.TempGUID, guid, "send_error", message)
				writeAPIError(w, http.StatusBadGateway, "send_error", message)
				return
			}
		}

		select {
		case <-r.Context().Done():
			h.send.Pending.Reject(req.TempGUID, "canceled")
			h.broadcastSendError(r.Context(), req.TempGUID, guid, "send_failed", "request canceled")
			writeAPIError(w, http.StatusInternalServerError, "send_failed", "request canceled")
			return
		case <-time.After(500 * time.Millisecond):
		}
	}

	// AppleScript completed but no matching outgoing row appeared in time.
	const timeoutMsg = "AppleScript completed but no matching outgoing message appeared in chat.db before the confirmation timeout"
	h.logSend(req.TempGUID, "timed out", fmt.Sprintf("chat=%s", guid))
	h.send.Pending.MarkSentUnconfirmed(req.TempGUID, "send_confirmation_timeout", lateReconciliationWindow)
	removePendingOnReturn = false
	details := map[string]any{
		"tempGuid":             req.TempGUID,
		"chatGuid":             guid,
		"text":                 req.Message,
		"recoverable":          true,
		"appleScriptSucceeded": true,
		"state":                string(micasend.StatusSentUnconfirmed),
	}
	h.broadcastSendErrorDetails(r.Context(), req.TempGUID, guid, "send_confirmation_timeout", timeoutMsg, details)
	writeJSON(w, http.StatusAccepted, map[string]any{
		"tempGuid":    req.TempGUID,
		"chatGuid":    guid,
		"text":        req.Message,
		"state":       string(micasend.StatusSentUnconfirmed),
		"recoverable": true,
		"message":     timeoutMsg,
	})
}

func (h *Handlers) GetAttachment(w http.ResponseWriter, r *http.Request) {
	if h.attachments == nil {
		writeInternalError(w)
		return
	}

	meta, err := h.attachments.GetAttachmentByGUID(r.Context(), r.PathValue("guid"))
	if err != nil {
		h.logInternal("get attachment", err)
		writeInternalError(w)
		return
	}
	if meta == nil || meta.HideAttachment {
		writeNotFound(w, "attachment not found")
		return
	}

	resolvedPath, ok := resolveAttachmentPath(h.attachmentsRoot, meta.LocalPath)
	if !ok {
		writeNotFound(w, "attachment not found")
		return
	}

	file, err := os.Open(resolvedPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeNotFound(w, "attachment not found")
			return
		}
		h.logInternal("open attachment", err)
		writeInternalError(w)
		return
	}
	defer file.Close()

	stat, err := file.Stat()
	if err != nil {
		h.logInternal("stat attachment", err)
		writeInternalError(w)
		return
	}

	contentType := "application/octet-stream"
	if inferred := store.InferMimeType(meta.MimeType, meta.Uti, meta.TransferName, meta.Filename); inferred != nil {
		if v := strings.TrimSpace(*inferred); v != "" {
			contentType = v
		}
	}
	w.Header().Set("Content-Type", contentType)

	filename := attachmentFilename(meta)
	if filename != "" {
		w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": filename}))
	}

	http.ServeContent(w, r, filename, stat.ModTime(), file)
}

func (h *Handlers) GetAttachmentPreview(w http.ResponseWriter, r *http.Request) {
	if h.attachments == nil {
		writeInternalError(w)
		return
	}

	guid := r.PathValue("guid")
	meta, err := h.attachments.GetAttachmentByGUID(r.Context(), guid)
	if err != nil {
		h.logInternal("get attachment preview", err)
		writeInternalError(w)
		return
	}
	if meta == nil || meta.HideAttachment {
		writeNotFound(w, "attachment not found")
		return
	}
	source, ok := resolveAttachmentPath(h.attachmentsRoot, meta.LocalPath)
	if !ok {
		writeNotFound(w, "attachment not found")
		return
	}
	if !attachmentNeedsPreviewConversion(meta) {
		http.ServeFile(w, r, source)
		return
	}

	previewPath := filepath.Join(os.TempDir(), "micago-attachment-previews", safePreviewName(guid)+".png")
	if _, err := os.Stat(previewPath); err != nil {
		if err := os.MkdirAll(filepath.Dir(previewPath), 0o700); err != nil {
			h.logInternal("create attachment preview dir", err)
			writeInternalError(w)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		if err := exec.CommandContext(ctx, "sips", "-s", "format", "png", source, "--out", previewPath).Run(); err != nil {
			h.logInternal("convert attachment preview", err)
			writeAPIError(w, http.StatusNotImplemented, "preview_unavailable", "preview conversion is not available for this attachment")
			return
		}
	}
	w.Header().Set("Content-Type", "image/png")
	http.ServeFile(w, r, previewPath)
}

func (h *Handlers) RegisterDevice(w http.ResponseWriter, r *http.Request) {
	if h.devices == nil {
		writeInternalError(w)
		return
	}

	var req deviceRegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}

	device, err := h.buildDeviceRecord(req)
	if err != nil {
		writeBadRequest(w, err.Error())
		return
	}

	saved, err := h.devices.UpsertDevice(r.Context(), device)
	if err != nil {
		h.logInternal("register device", err)
		writeInternalError(w)
		return
	}

	writeJSON(w, http.StatusOK, store.DeviceResponse{Data: deviceToJSON(*saved)})
}

func (h *Handlers) ListDevices(w http.ResponseWriter, r *http.Request) {
	if h.devices == nil {
		writeInternalError(w)
		return
	}

	devices, err := h.devices.ListDevices(r.Context())
	if err != nil {
		h.logInternal("list devices", err)
		writeInternalError(w)
		return
	}
	items := make([]store.DeviceJSON, 0, len(devices))
	for _, device := range devices {
		items = append(items, deviceToJSON(device))
	}
	writeJSON(w, http.StatusOK, store.DeviceListResponse{Data: items})
}

func (h *Handlers) PatchDevice(w http.ResponseWriter, r *http.Request) {
	if h.devices == nil {
		writeInternalError(w)
		return
	}

	id := strings.TrimSpace(r.PathValue("id"))
	if id == "" {
		writeBadRequest(w, "device id is required")
		return
	}

	current, err := h.devices.GetDeviceByID(r.Context(), id)
	if err != nil {
		h.logInternal("get device", err)
		writeInternalError(w)
		return
	}
	if current == nil {
		writeNotFound(w, "device not found")
		return
	}

	var req devicePatchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}

	if req.Name != nil {
		current.Name = strings.TrimSpace(*req.Name)
	}
	if req.PushProvider != nil {
		current.PushProvider = strings.TrimSpace(*req.PushProvider)
	}
	if req.PushToken != nil {
		token := strings.TrimSpace(*req.PushToken)
		current.PushToken = &token
	}
	if req.PushEnabled != nil {
		current.PushEnabled = *req.PushEnabled
	}
	current.UpdatedAt = time.Now().UnixMilli()

	if err := validateDeviceRecord(*current, h.serverInfo.NotificationProviders, strings.TrimSpace(h.cfg.WebhookURL) != ""); err != nil {
		writeBadRequest(w, err.Error())
		return
	}

	saved, err := h.devices.UpsertDevice(r.Context(), *current)
	if err != nil {
		h.logInternal("patch device", err)
		writeInternalError(w)
		return
	}
	writeJSON(w, http.StatusOK, store.DeviceResponse{Data: deviceToJSON(*saved)})
}

func (h *Handlers) DeviceHeartbeat(w http.ResponseWriter, r *http.Request) {
	if h.devices == nil {
		writeInternalError(w)
		return
	}

	id := strings.TrimSpace(r.PathValue("id"))
	if id == "" {
		writeBadRequest(w, "device id is required")
		return
	}
	device, err := h.devices.UpdateDeviceHeartbeat(r.Context(), id, time.Now().UnixMilli())
	if err != nil {
		h.logInternal("device heartbeat", err)
		writeInternalError(w)
		return
	}
	if device == nil {
		writeNotFound(w, "device not found")
		return
	}
	writeJSON(w, http.StatusOK, store.DeviceResponse{Data: deviceToJSON(*device)})
}

func (h *Handlers) DeleteDevice(w http.ResponseWriter, r *http.Request) {
	if h.devices == nil {
		writeInternalError(w)
		return
	}

	id := strings.TrimSpace(r.PathValue("id"))
	if id == "" {
		writeBadRequest(w, "device id is required")
		return
	}
	device, err := h.devices.GetDeviceByID(r.Context(), id)
	if err != nil {
		h.logInternal("get device", err)
		writeInternalError(w)
		return
	}
	if device == nil {
		writeNotFound(w, "device not found")
		return
	}
	if err := h.devices.DeleteDevice(r.Context(), id); err != nil {
		h.logInternal("delete device", err)
		writeInternalError(w)
		return
	}
	writeJSON(w, http.StatusOK, store.HealthResponse{OK: true})
}

func (h *Handlers) TestPush(w http.ResponseWriter, r *http.Request) {
	if h.devices == nil || h.notify == nil {
		writeInternalError(w)
		return
	}

	id := strings.TrimSpace(r.PathValue("id"))
	if id == "" {
		writeBadRequest(w, "device id is required")
		return
	}
	device, err := h.devices.GetDeviceByID(r.Context(), id)
	if err != nil {
		h.logInternal("get device", err)
		writeInternalError(w)
		return
	}
	if device == nil {
		writeNotFound(w, "device not found")
		return
	}

	err = h.notify.SendTest(r.Context(), *device)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, store.HealthResponse{OK: true})
	case errors.Is(err, notify.ErrPushNotConfigured):
		writeAPIError(w, http.StatusBadRequest, "push_not_configured", "push is not configured for this device")
	case errors.Is(err, notify.ErrNotImplemented):
		writeAPIError(w, http.StatusNotImplemented, "not_implemented", "notification provider is not implemented")
	default:
		h.logInternal("test push", err)
		writeInternalError(w)
	}
}

func (h *Handlers) logInternal(action string, err error) {
	if h.logger != nil {
		h.logger.Printf("%s: %v", action, err)
	}
}

func (h *Handlers) broadcastSendMatch(ctx context.Context, tempGUID string, message store.MessageJSON) {
	if h.send == nil || h.send.Events == nil {
		return
	}
	_ = h.send.Events.Broadcast(ctx, realtime.Event{
		Type: "send:match",
		Data: map[string]any{
			"tempGuid": tempGUID,
			"message":  message,
		},
	})
}

func (h *Handlers) broadcastSendError(ctx context.Context, tempGUID, chatGUID, code, message string) {
	h.broadcastSendErrorDetails(ctx, tempGUID, chatGUID, code, message, nil)
}

// broadcastSendErrorDetails emits a send:error event, merging optional extra
// fields (e.g. the original text for a confirmation timeout) into the payload.
func (h *Handlers) broadcastSendErrorDetails(ctx context.Context, tempGUID, chatGUID, code, message string, details map[string]any) {
	if h.send == nil || h.send.Events == nil {
		return
	}
	data := map[string]any{
		"tempGuid": tempGUID,
		"chatGuid": chatGUID,
		"code":     code,
		"message":  message,
	}
	for k, v := range details {
		if _, reserved := data[k]; !reserved {
			data[k] = v
		}
	}
	_ = h.send.Events.Broadcast(ctx, realtime.Event{Type: "send:error", Data: data})
}

// broadcastSendPending emits a send:pending event so async WebSocket clients can
// show an optimistic "sending" state before the confirmed/failed event.
func (h *Handlers) broadcastSendPending(ctx context.Context, tempGUID, chatGUID string) {
	if h.send == nil || h.send.Events == nil {
		return
	}
	_ = h.send.Events.Broadcast(ctx, realtime.Event{
		Type: "send:pending",
		Data: map[string]any{
			"tempGuid": tempGUID,
			"chatGuid": chatGUID,
		},
	})
}

// logSend writes a concise, single-line stage log for a send. `detail` may be
// empty. Callers build `detail` with constant format strings to keep vet happy.
func (h *Handlers) logSend(tempGUID, stage, detail string) {
	if h.logger == nil {
		return
	}
	if detail != "" {
		detail = " " + detail
	}
	h.logger.Printf("send[%s] %s%s", tempGUID, stage, detail)
}

func resolveAttachmentPath(root string, localPath *string) (string, bool) {
	if localPath == nil || strings.TrimSpace(*localPath) == "" {
		return "", false
	}
	if root == "" {
		return "", false
	}

	root = filepath.Clean(root)
	if resolvedRoot, err := filepath.EvalSymlinks(root); err == nil {
		root = resolvedRoot
	}
	target := *localPath
	if strings.HasPrefix(target, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", false
		}
		target = filepath.Join(home, strings.TrimPrefix(target, "~/"))
	}
	target = filepath.Clean(target)

	resolvedPath, err := filepath.EvalSymlinks(target)
	if err != nil {
		return "", false
	}

	if resolvedPath != root && !strings.HasPrefix(resolvedPath, root+string(os.PathSeparator)) {
		return "", false
	}

	return resolvedPath, true
}

func attachmentFilename(meta *store.AttachmentMeta) string {
	if meta == nil {
		return ""
	}
	for _, candidate := range []*string{meta.TransferName, meta.Filename} {
		if candidate == nil || strings.TrimSpace(*candidate) == "" {
			continue
		}
		name := filepath.Base(*candidate)
		if name != "." && name != string(os.PathSeparator) {
			return name
		}
	}
	return meta.GUID
}

func attachmentNeedsPreviewConversion(meta *store.AttachmentMeta) bool {
	if meta == nil {
		return false
	}
	mimeType := strings.ToLower(strings.TrimSpace(ptrString(meta.MimeType)))
	uti := strings.ToLower(strings.TrimSpace(ptrString(meta.Uti)))
	name := strings.ToLower(strings.TrimSpace(attachmentFilename(meta)))
	return strings.Contains(mimeType, "image/tif") ||
		strings.Contains(mimeType, "image/heic") ||
		strings.Contains(mimeType, "image/heif") ||
		uti == "public.tiff" ||
		uti == "public.heic" ||
		uti == "public.heif" ||
		strings.HasSuffix(name, ".tif") ||
		strings.HasSuffix(name, ".tiff") ||
		strings.HasSuffix(name, ".heic") ||
		strings.HasSuffix(name, ".heif")
}

func ptrString(v *string) string {
	if v == nil {
		return ""
	}
	return *v
}

func safePreviewName(guid string) string {
	var b strings.Builder
	for _, r := range guid {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			b.WriteRune(r)
		}
	}
	if b.Len() == 0 {
		return "attachment"
	}
	return b.String()
}

func (h *Handlers) buildDeviceRecord(req deviceRegisterRequest) (store.DeviceRecord, error) {
	id := strings.TrimSpace(req.ID)
	if id == "" {
		var err error
		id, err = generateDeviceID()
		if err != nil {
			return store.DeviceRecord{}, err
		}
	}

	now := time.Now().UnixMilli()
	device := store.DeviceRecord{
		ID:           id,
		Name:         strings.TrimSpace(req.Name),
		Platform:     strings.TrimSpace(req.Platform),
		ClientType:   strings.TrimSpace(req.ClientType),
		PushProvider: strings.TrimSpace(req.PushProvider),
		PushEnabled:  req.PushEnabled,
		LastSeenAt:   &now,
		CreatedAt:    now,
		UpdatedAt:    now,
	}
	if strings.TrimSpace(req.PushToken) != "" {
		token := strings.TrimSpace(req.PushToken)
		device.PushToken = &token
	}

	existing, err := h.devices.GetDeviceByID(context.Background(), id)
	if err == nil && existing != nil {
		device.CreatedAt = existing.CreatedAt
	}

	if err := validateDeviceRecord(device, h.serverInfo.NotificationProviders, strings.TrimSpace(h.cfg.WebhookURL) != ""); err != nil {
		return store.DeviceRecord{}, err
	}
	return device, nil
}

func validateDeviceRecord(device store.DeviceRecord, supportedProviders []string, webhookConfigured bool) error {
	if strings.TrimSpace(device.Name) == "" {
		return errors.New("name is required")
	}
	if strings.TrimSpace(device.Platform) == "" {
		return errors.New("platform is required")
	}
	if strings.TrimSpace(device.ClientType) == "" {
		return errors.New("clientType is required")
	}
	if strings.TrimSpace(device.PushProvider) == "" {
		return errors.New("pushProvider is required")
	}
	if !slices.Contains([]string{"windows", "android", "ios", "harmonyos", "web", "unknown"}, device.Platform) {
		return errors.New("platform must be one of: windows, android, ios, harmonyos, web, unknown")
	}
	if !slices.Contains([]string{"tauri", "flutter", "web", "native", "unknown"}, device.ClientType) {
		return errors.New("clientType must be one of: tauri, flutter, web, native, unknown")
	}
	if !slices.Contains([]string{"none", "webhook", "fcm", "hms", "harmony_push", "ntfy"}, device.PushProvider) {
		return errors.New("pushProvider must be one of: none, webhook, fcm, hms, harmony_push, ntfy")
	}
	if len(supportedProviders) > 0 && !slices.Contains(supportedProviders, device.PushProvider) && device.PushProvider != "harmony_push" {
		return errors.New("pushProvider is not supported by this server")
	}
	if device.PushEnabled && device.PushProvider != "none" {
		tokenMissing := device.PushToken == nil || strings.TrimSpace(*device.PushToken) == ""
		if device.PushProvider == "webhook" && webhookConfigured {
			tokenMissing = false
		}
		if tokenMissing {
			return errors.New("pushToken is required when pushEnabled is true")
		}
	}
	return nil
}

func deviceToJSON(device store.DeviceRecord) store.DeviceJSON {
	return store.DeviceJSON{
		ID:           device.ID,
		Name:         device.Name,
		Platform:     device.Platform,
		ClientType:   device.ClientType,
		PushProvider: device.PushProvider,
		PushEnabled:  device.PushEnabled,
		PushTokenSet: device.PushToken != nil && strings.TrimSpace(*device.PushToken) != "",
		LastSeenAt:   device.LastSeenAt,
		CreatedAt:    device.CreatedAt,
		UpdatedAt:    device.UpdatedAt,
	}
}

func generateDeviceID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func parseListParams(w http.ResponseWriter, r *http.Request) (int, int, bool) {
	limit, err := parseLimit(r.URL.Query().Get("limit"))
	if err != nil {
		writeBadRequest(w, err.Error())
		return 0, 0, false
	}

	offset, err := parseOffset(r.URL.Query().Get("offset"))
	if err != nil {
		writeBadRequest(w, err.Error())
		return 0, 0, false
	}

	return limit, offset, true
}

func parseLimit(raw string) (int, error) {
	if raw == "" {
		return defaultLimit, nil
	}

	v, err := strconv.Atoi(raw)
	if err != nil || v < 1 || v > maxLimit {
		return 0, errors.New("limit must be between 1 and 500")
	}
	return v, nil
}

func parseOffset(raw string) (int, error) {
	if raw == "" {
		return defaultOffset, nil
	}

	v, err := strconv.Atoi(raw)
	if err != nil || v < 0 {
		return 0, errors.New("offset must be greater than or equal to 0")
	}
	return v, nil
}

func parseWithArchived(r *http.Request) (bool, error) {
	raw := r.URL.Query().Get("withArchived")
	if raw == "" {
		return false, nil
	}

	v, err := strconv.ParseBool(raw)
	if err != nil {
		return false, errors.New("withArchived must be a boolean")
	}
	return v, nil
}

func parseService(r *http.Request) (string, error) {
	raw := r.URL.Query().Get("service")
	if raw == "" {
		return defaultService, nil
	}

	switch raw {
	case serviceIMessage, serviceSMS, serviceRCS, serviceUnknown, serviceAll:
		return raw, nil
	default:
		return "", errors.New("service must be one of iMessage, SMS, RCS, unknown, all")
	}
}

// parseRawTimeline reports whether the caller wants the raw (unfiltered) message
// timeline rather than the default renderable one. The canonical flag is
// ?debug=true; ?includeEmpty=true is kept as a backward-compatible alias. Either
// being true makes the relay return debug-only/noise rows for the Inspector.
func parseRawTimeline(r *http.Request) (bool, error) {
	debug, err := parseDebug(r)
	if err != nil {
		return false, err
	}
	rawEmpty := r.URL.Query().Get("includeEmpty")
	if rawEmpty == "" {
		return debug, nil
	}
	v, err := strconv.ParseBool(rawEmpty)
	if err != nil {
		return false, errors.New("includeEmpty must be a boolean")
	}
	return debug || v, nil
}

// parseDebug reads the optional ?debug=true flag used by the renderable-timeline
// APIs to include debug-only/noise rows and otherwise-hidden chats.
func parseDebug(r *http.Request) (bool, error) {
	raw := r.URL.Query().Get("debug")
	if raw == "" {
		return false, nil
	}
	v, err := strconv.ParseBool(raw)
	if err != nil {
		return false, errors.New("debug must be a boolean")
	}
	return v, nil
}
