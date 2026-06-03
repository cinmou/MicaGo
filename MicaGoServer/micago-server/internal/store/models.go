package store

type HealthResponse struct {
	OK bool `json:"ok"`
}

type HandleJSON struct {
	ID      string  `json:"id"`
	Service *string `json:"service"`
}

type AttachmentJSON struct {
	GUID         string  `json:"guid"`
	Filename     *string `json:"filename"`
	MimeType     *string `json:"mimeType"`
	TransferName *string `json:"transferName"`
	TotalBytes   int64   `json:"totalBytes"`
	DownloadURL  string  `json:"downloadUrl"`
}

type ChatJSON struct {
	GUID           string  `json:"guid"`
	ChatIdentifier *string `json:"chatIdentifier"`
	ServiceName    *string `json:"serviceName"`
	DisplayName    *string `json:"displayName"`
	IsArchived     bool    `json:"isArchived"`
}

type MessageJSON struct {
	GUID                string           `json:"guid"`
	Text                *string          `json:"text"`
	Subject             *string          `json:"subject"`
	Service             *string          `json:"service"`
	DateCreated         *int64           `json:"dateCreated"`
	DateRead            *int64           `json:"dateRead"`
	DateDelivered       *int64           `json:"dateDelivered"`
	IsFromMe            bool             `json:"isFromMe"`
	IsRead              bool             `json:"isRead"`
	IsDelivered         bool             `json:"isDelivered"`
	Handle              *HandleJSON      `json:"handle"`
	CacheHasAttachments bool             `json:"cacheHasAttachments"`
	Attachments         []AttachmentJSON `json:"attachments"`
}

type ListMeta struct {
	Limit  int `json:"limit"`
	Offset int `json:"offset"`
}

type ChatListResponse struct {
	Data []ChatJSON `json:"data"`
	Meta ListMeta   `json:"meta"`
}

type MessageListResponse struct {
	Data []MessageJSON `json:"data"`
	Meta ListMeta      `json:"meta"`
}

type ChatRow struct {
	GUID           string
	ChatIdentifier *string
	ServiceName    *string
	DisplayName    *string
	IsArchived     bool
}

type MessageRow struct {
	ChatGUID            *string
	SourceRowID         *int64
	GUID                string
	Text                *string
	AttributedBody      []byte
	Subject             *string
	Service             *string
	DateRaw             int64
	DateReadRaw         *int64
	DateDeliveredRaw    *int64
	IsFromMe            bool
	IsRead              bool
	IsDelivered         bool
	HandleValue         *string
	HandleService       *string
	CacheHasAttachments bool
}

type SyncChatRow struct {
	GUID           string
	ChatIdentifier *string
	ServiceName    *string
	DisplayName    *string
	IsArchived     bool
}

type SyncMessageRow struct {
	ChatGUID            string
	SourceRowID         int64
	GUID                string
	Text                *string
	Subject             *string
	Service             *string
	DateCreated         *int64
	DateRead            *int64
	DateDelivered       *int64
	IsFromMe            bool
	IsRead              bool
	IsDelivered         bool
	HandleID            *string
	HandleService       *string
	CacheHasAttachments bool
}

// MessageUpdateRow is a chat.db row fetched by the v0.11.x lookback update pass.
// Mutable-state fields are populated only when the corresponding capability is
// available; otherwise they remain nil/zero and are ignored. Dates are Unix ms.
type MessageUpdateRow struct {
	GUID                string
	ChatGUID            string
	Text                *string
	Subject             *string
	Service             *string
	DateCreated         *int64
	DateRead            *int64
	DateDelivered       *int64
	DateEdited          *int64
	DateRetracted       *int64
	ErrorCode           int64
	IsFromMe            bool
	IsRead              bool
	IsDelivered         bool
	HandleID            *string
	HandleService       *string
	CacheHasAttachments bool
}

// State extracts the mutable MessageState used for fingerprinting/diffing.
func (r MessageUpdateRow) State() MessageState {
	return MessageState{
		IsRead:        r.IsRead,
		DateRead:      r.DateRead,
		IsDelivered:   r.IsDelivered,
		DateDelivered: r.DateDelivered,
		DateEdited:    r.DateEdited,
		DateRetracted: r.DateRetracted,
		ErrorCode:     r.ErrorCode,
	}
}

type SyncAttachmentRow struct {
	GUID           string
	MessageGUID    string
	Filename       *string
	MimeType       *string
	TransferName   *string
	TotalBytes     int64
	LocalPath      *string
	IsOutgoing     bool
	HideAttachment bool
	CreatedAt      *int64
}

type AttachmentMeta struct {
	GUID           string
	MessageGUID    string
	Filename       *string
	MimeType       *string
	TransferName   *string
	TotalBytes     int64
	LocalPath      *string
	IsOutgoing     bool
	HideAttachment bool
	CreatedAt      *int64
}

type ChatInfo struct {
	GUID        string
	ServiceName *string
}

type DeviceRecord struct {
	ID           string
	Name         string
	Platform     string
	ClientType   string
	PushProvider string
	PushToken    *string
	PushEnabled  bool
	LastSeenAt   *int64
	CreatedAt    int64
	UpdatedAt    int64
}

type DeviceJSON struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Platform     string `json:"platform"`
	ClientType   string `json:"clientType"`
	PushProvider string `json:"pushProvider"`
	PushEnabled  bool   `json:"pushEnabled"`
	PushTokenSet bool   `json:"pushTokenSet"`
	LastSeenAt   *int64 `json:"lastSeenAt"`
	CreatedAt    int64  `json:"createdAt"`
	UpdatedAt    int64  `json:"updatedAt"`
}

type DeviceResponse struct {
	Data DeviceJSON `json:"data"`
}

type DeviceListResponse struct {
	Data []DeviceJSON `json:"data"`
}

type ServerInfoResponse struct {
	Name                  string         `json:"name"`
	Version               string         `json:"version"`
	BaseURL               string         `json:"baseUrl"`
	WebSocketURL          string         `json:"websocketUrl"`
	Features              ServerFeatures `json:"features"`
	NotificationProviders []string       `json:"notificationProviders"`
}

type ServerFeatures struct {
	Chats         bool `json:"chats"`
	Messages      bool `json:"messages"`
	SendText      bool `json:"sendText"`
	Attachments   bool `json:"attachments"`
	WebSocket     bool `json:"websocket"`
	Devices       bool `json:"devices"`
	Notifications bool `json:"notifications"`
}

// ServerStatusResponse is the runtime control/status payload consumed by the
// native macOS companion app (see docs/spec-v0.10.0-mac-companion.md). It is
// intentionally read-only and local-control oriented; it never returns the
// bearer token or any push token.
type ServerStatusResponse struct {
	OK            bool                     `json:"ok"`
	Version       string                   `json:"version"`
	StartedAt     int64                    `json:"startedAt"`
	UptimeSeconds int64                    `json:"uptimeSeconds"`
	Address       ServerAddressStatus      `json:"address"`
	Store         string                   `json:"store"`
	Auth          ServerAuthStatus         `json:"auth"`
	Sync          ServerSyncStatus         `json:"sync"`
	Notifications ServerNotificationStatus `json:"notifications"`
	Devices       ServerDevicesStatus      `json:"devices"`
	WebSocket     ServerWebSocketStatus    `json:"websocket"`
	Permissions   ServerPermissionStatus   `json:"permissions"`
	Capabilities  ServerCapabilities       `json:"capabilities"`
}

// ServerCapabilities reports what the running chat.db schema supports, so
// clients/companion can know which update signals this Mac can actually produce.
// See docs/spec-v0.11.x-server-reliability.md.
type ServerCapabilities struct {
	Schema SchemaCapabilities `json:"schema"`
}

type ServerAddressStatus struct {
	Listen       string   `json:"listen"`
	BaseURL      string   `json:"baseUrl"`
	WebSocketURL string   `json:"websocketUrl"`
	LAN          []string `json:"lan"`
}

type ServerAuthStatus struct {
	Enabled bool `json:"enabled"`
}

type ServerSyncStatus struct {
	LoopEnabled      bool   `json:"loopEnabled"`
	IntervalSeconds  int64  `json:"intervalSeconds"`
	LastSyncAt       *int64 `json:"lastSyncAt"`
	LastMessageRowID *int64 `json:"lastMessageRowId"`
}

type ServerNotificationStatus struct {
	Enabled     bool     `json:"enabled"`
	Provider    string   `json:"provider"`
	Preview     string   `json:"preview"`
	Providers   []string `json:"providers"`
	Implemented []string `json:"implemented"`
	Stub        []string `json:"stub"`
}

type ServerDevicesStatus struct {
	Count int `json:"count"`
}

type ServerWebSocketStatus struct {
	Clients int `json:"clients"`
}

type ServerPermissionStatus struct {
	FullDiskAccess PermissionCheck `json:"fullDiskAccess"`
	Attachments    PermissionCheck `json:"attachments"`
	Automation     PermissionCheck `json:"automation"`
}

// PermissionCheck reports a single permission probe. Status is one of
// "ok", "denied", or "unknown".
type PermissionCheck struct {
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}
