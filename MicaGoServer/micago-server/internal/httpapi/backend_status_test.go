package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/store"
)

// C17: /api/server/status must identify the exact running binary (path,
// version, commit, build time, DB paths, chat.db open options) and echo the
// live sync settings, so a stale launched backend is externally detectable.
func TestGetServerStatusReportsBackendIdentityAndSettings(t *testing.T) {
	backend := &store.ServerBackendStatus{
		Version:           "v0.15.0",
		Commit:            "abc1234",
		BuildTime:         "2026-06-12T00:00:00Z",
		GoVersion:         "go1.22.1",
		OSArch:            "darwin/arm64",
		ExecutablePath:    "/Users/dev/.micago/bin/micago",
		ConfigPath:        "/Users/dev/.micago/config.yaml",
		RelayDBPath:       "/Users/dev/.micago/relay.db",
		ChatDBPath:        "/Users/dev/Library/Messages/chat.db",
		ChatDBOpenOptions: store.ChatDBOpenOptions(),
		ChatDBImmutable:   false,
	}
	settings := &store.ServerSyncSettings{
		BackfillMode:          "hybrid",
		RecentMessagesPerChat: 100,
		IncludeIMessage:       true,
		IncludeSMS:            true,
	}

	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"},
		StatusDeps{
			APIStore: "relaydb",
			Backend:  backend,
			SyncSettings: func(context.Context) *store.ServerSyncSettings {
				return settings
			},
		},
	)

	req := httptest.NewRequest(http.MethodGet, "/api/server/status", nil)
	rec := httptest.NewRecorder()
	handlers.GetServerStatus(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var status store.ServerStatusResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode: %v", err)
	}

	b := status.Backend
	if b == nil {
		t.Fatal("status.backend missing")
	}
	if b.ExecutablePath != backend.ExecutablePath || b.Commit != "abc1234" || b.Version != "v0.15.0" {
		t.Fatalf("backend identity wrong: %+v", b)
	}
	// The C15 fix contract: chat.db is opened WITHOUT immutable.
	if b.ChatDBImmutable {
		t.Fatal("chatDbImmutable must be false")
	}
	if b.ChatDBOpenOptions == "" {
		t.Fatal("chatDbOpenOptions must be reported")
	}

	s := status.Sync.Settings
	if s == nil {
		t.Fatal("sync.settings missing")
	}
	if s.BackfillMode != "hybrid" || s.RecentMessagesPerChat != 100 {
		t.Fatalf("settings echo wrong: %+v", s)
	}
}

// store.ChatDBOpenOptions is the verifiable C15 contract — it must include the
// read-only + busy-timeout options and must never contain immutable.
func TestChatDBOpenOptionsContract(t *testing.T) {
	opts := store.ChatDBOpenOptions()
	for _, want := range []string{"mode=ro", "_busy_timeout=5000"} {
		if !strings.Contains(opts, want) {
			t.Fatalf("options missing %q: %s", want, opts)
		}
	}
	if strings.Contains(opts, "immutable") {
		t.Fatalf("options must not contain immutable: %s", opts)
	}
}
