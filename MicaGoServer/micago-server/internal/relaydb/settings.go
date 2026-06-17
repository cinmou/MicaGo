package relaydb

import (
	"context"
	"encoding/json"
	"strings"
)

const syncSettingsKey = "sync_settings_v1"

type SyncSettings struct {
	BackfillMode          string `json:"backfillMode"`
	RecentMessagesPerChat int    `json:"recentMessagesPerChat"`
	IncludeIMessage       bool   `json:"includeIMessage"`
	IncludeSMS            bool   `json:"includeSMS"`
	IncludeRCS            bool   `json:"includeRCS"`
	IncludeUnknown        bool   `json:"includeUnknown"`
	IncludeDebugInNormal  bool   `json:"includeDebugInNormal"`
	// AllowSMSSend gates sending to SMS chats through Messages (C20). Default
	// off: SMS chats are readable but the composer is disabled until the user
	// turns this on. iMessage is always sendable; unknown is never sendable.
	AllowSMSSend bool `json:"allowSmsSend"`
}

func DefaultSyncSettings() SyncSettings {
	return SyncSettings{
		BackfillMode:          "hybrid",
		RecentMessagesPerChat: 100,
		IncludeIMessage:       true,
		IncludeSMS:            true,
		IncludeRCS:            true,
		IncludeUnknown:        false,
		IncludeDebugInNormal:  false,
		AllowSMSSend:          false,
	}
}

// ResolveEffectiveService computes the single, server-authoritative service for
// a chat (C21). It is message-aware and prefers iMessage: a phone-number chat
// whose row says SMS but whose latest message is iMessage is treated as
// iMessage (and vice-versa). This one value drives the client's badge/composer
// AND the server send gate, so they can never disagree. Never inferred from the
// GUID/handle shape — only the service strings decide.
//
// chatService is the chat row's service_name; latestMsgService is the newest
// renderable message's service (may be nil); hasIMessage is true when ANY
// renderable message in the chat was sent over iMessage (capability signal).
// Returns a category: "imessage" | "sms" | "rcs" | "unknown".
//
// Prefer-iMessage rule (C21c): if the chat OR any message shows iMessage
// capability, the effective service is iMessage — a phone-number contact that
// is iMessage-capable is never downgraded to SMS just because the latest
// message happened to fall back to SMS.
func ResolveEffectiveService(chatService, latestMsgService *string, hasIMessage bool) string {
	chat := ServiceCategory(chatService)
	msg := ServiceCategory(latestMsgService)
	if chat == "imessage" || msg == "imessage" || hasIMessage {
		return "imessage"
	}
	// Otherwise the message is the more current signal; fall back to the chat.
	if msg != "unknown" {
		return msg
	}
	return chat
}

// ServiceSendable reports whether a chat with the given chat.db service name can
// be SENT to under these settings (C20). Server-authoritative: iMessage always;
// SMS only when AllowSMSSend; everything else (RCS, unknown, nil) never. Never
// inferred from the GUID/handle shape — only the service string decides.
func (s SyncSettings) ServiceSendable(serviceName string) bool {
	return s.CategorySendable(ServiceCategory(&serviceName))
}

// SendCapabilities returns the explicit (canSendText, canSendAttachments) the
// client consumes directly (C21c) — no client-side inference. Currently text
// and attachments share the same gate (both go through the same Messages send
// path), but they are separate fields so a future capability split is a server
// change, not a Flutter one.
func (s SyncSettings) SendCapabilities(effectiveCategory string) (canText, canAttachments bool) {
	sendable := s.CategorySendable(effectiveCategory)
	return sendable, sendable
}

// CategorySendable is the gate over a normalized effective-service category
// (C21): iMessage always; SMS only when AllowSMSSend; RCS/unknown never. The
// effective category comes from ResolveEffectiveService so the client badge and
// this gate use the identical decision.
func (s SyncSettings) CategorySendable(category string) bool {
	switch category {
	case "imessage":
		return true
	case "sms":
		return s.AllowSMSSend
	default:
		return false
	}
}

func NormalizeSyncSettings(s SyncSettings) SyncSettings {
	if s.BackfillMode != "global_recent" && s.BackfillMode != "per_chat_recent" && s.BackfillMode != "hybrid" {
		s.BackfillMode = "hybrid"
	}
	switch s.RecentMessagesPerChat {
	case 50, 100, 200, 500:
	default:
		s.RecentMessagesPerChat = 100
	}
	if !s.IncludeIMessage && !s.IncludeSMS && !s.IncludeRCS && !s.IncludeUnknown {
		s.IncludeIMessage = true
	}
	return s
}

func (db *DB) GetSyncSettings(ctx context.Context) (SyncSettings, error) {
	raw, ok, err := db.GetSyncState(syncSettingsKey)
	if err != nil {
		return SyncSettings{}, err
	}
	if !ok || strings.TrimSpace(raw) == "" {
		return DefaultSyncSettings(), nil
	}
	var s SyncSettings
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		return DefaultSyncSettings(), nil
	}
	return NormalizeSyncSettings(s), nil
}

func (db *DB) SetSyncSettings(ctx context.Context, s SyncSettings) (SyncSettings, error) {
	s = NormalizeSyncSettings(s)
	b, err := json.Marshal(s)
	if err != nil {
		return SyncSettings{}, err
	}
	if err := db.SetSyncState(syncSettingsKey, string(b)); err != nil {
		return SyncSettings{}, err
	}
	return s, nil
}

func ServiceCategory(service *string) string {
	if service == nil {
		return "unknown"
	}
	switch strings.ToLower(strings.TrimSpace(*service)) {
	case "imessage", "imessagelite":
		return "imessage"
	case "sms", "text", "plain":
		return "sms"
	case "rcs":
		return "rcs"
	default:
		return "unknown"
	}
}

func (s SyncSettings) IncludesCategory(category string) bool {
	switch category {
	case "imessage":
		return s.IncludeIMessage
	case "sms":
		return s.IncludeSMS
	case "rcs":
		return s.IncludeRCS
	default:
		return s.IncludeUnknown
	}
}
