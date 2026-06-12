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
