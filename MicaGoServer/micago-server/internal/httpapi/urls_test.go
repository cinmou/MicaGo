package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"micagoserver/internal/config"
)

func newURLHandlers(httpAddr string, network *NetworkController) *Handlers {
	return NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: httpAddr, PreferredPairingEndpoint: "auto", VerifyTLS: true},
		StatusDeps{APIStore: "relaydb", Network: network},
	)
}

func TestLocalEndpointsLoopbackOnly(t *testing.T) {
	local := localEndpoints("127.0.0.1:12345")
	if len(local) != 1 {
		t.Fatalf("expected 1 local endpoint, got %d", len(local))
	}
	if local[0].Kind != "loopback" || local[0].BaseURL != "http://127.0.0.1:12345" {
		t.Fatalf("unexpected local endpoint: %+v", local[0])
	}
	if local[0].WSURL != "ws://127.0.0.1:12345/ws" {
		t.Fatalf("unexpected ws url: %q", local[0].WSURL)
	}

	lan := lanEndpoints("127.0.0.1:12345")
	if len(lan) != 0 {
		t.Fatalf("loopback bind must not expose LAN endpoints, got %d", len(lan))
	}
}

func TestLanEndpointsSpecificBind(t *testing.T) {
	lan := lanEndpoints("192.168.1.23:12345")
	if len(lan) != 1 {
		t.Fatalf("expected 1 lan endpoint, got %d", len(lan))
	}
	if lan[0].Kind != "lan" || lan[0].BaseURL != "http://192.168.1.23:12345" {
		t.Fatalf("unexpected lan endpoint: %+v", lan[0])
	}
	// Reachability for LAN is not server-verifiable -> "unknown".
	if data, _ := json.Marshal(lan[0].Reachable); string(data) != `"unknown"` {
		t.Fatalf("expected lan reachable unknown, got %s", data)
	}
}

func TestGetServerURLsPublicDisabled(t *testing.T) {
	h := newURLHandlers("127.0.0.1:12345", NewNetworkController(config.Config{VerifyTLS: true, PreferredPairingEndpoint: "auto"}))
	req := httptest.NewRequest(http.MethodGet, "/api/server/urls", nil)
	rec := httptest.NewRecorder()
	h.GetServerURLs(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var resp ServerURLsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Public.Enabled {
		t.Fatalf("expected public disabled")
	}
	if len(resp.Local) != 1 {
		t.Fatalf("expected loopback local endpoint")
	}
	if resp.PreferredPairingEndpoint != "auto" {
		t.Fatalf("expected preferred auto, got %q", resp.PreferredPairingEndpoint)
	}
}

func TestGetServerURLsPublicEnabled(t *testing.T) {
	controller := NewNetworkController(config.Config{
		PublicBaseURL:            "https://abc123.trycloudflare.com",
		VerifyTLS:                true,
		PreferredPairingEndpoint: "public",
	})
	h := newURLHandlers("0.0.0.0:12345", controller)
	resp := h.buildServerURLs()

	if !resp.Public.Enabled {
		t.Fatalf("expected public enabled")
	}
	if resp.Public.Kind != "custom" {
		t.Fatalf("expected kind custom, got %q", resp.Public.Kind)
	}
	if resp.Public.BaseURL != "https://abc123.trycloudflare.com" {
		t.Fatalf("unexpected base: %q", resp.Public.BaseURL)
	}
	if resp.Public.WSURL != "wss://abc123.trycloudflare.com/ws" {
		t.Fatalf("unexpected ws: %q", resp.Public.WSURL)
	}
	if resp.Public.ProviderHint != "cloudflare_tunnel" {
		t.Fatalf("expected cloudflare_tunnel hint, got %q", resp.Public.ProviderHint)
	}
	// Not checked yet -> reachable unknown.
	if data, _ := json.Marshal(resp.Public.Reachable); string(data) != `"unknown"` {
		t.Fatalf("expected reachable unknown, got %s", data)
	}
	if resp.PreferredPairingEndpoint != "public" {
		t.Fatalf("expected preferred public, got %q", resp.PreferredPairingEndpoint)
	}
}

func TestProviderHintInference(t *testing.T) {
	cases := map[string]string{
		"https://x.trycloudflare.com": "cloudflare_tunnel",
		"https://x.ngrok-free.app":    "ngrok",
		"https://mac.tail1234.ts.net": "tailscale",
		"https://mica.example.com":    "custom",
	}
	for url, want := range cases {
		if got := inferProviderHint(url); got != want {
			t.Fatalf("inferProviderHint(%q) = %q, want %q", url, got, want)
		}
	}
}

func TestSetPublicURLPersistsAndValidates(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(cfgPath, []byte("auth:\n  token: \"abc\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	controller := NewNetworkController(config.Config{ConfigPath: cfgPath, VerifyTLS: true, PreferredPairingEndpoint: "auto"})

	// Invalid URL is rejected and not persisted.
	if err := controller.SetPublicURL("not-a-url", true, "auto"); err == nil {
		t.Fatalf("expected error for invalid url")
	}

	// Valid URL persists to the config file.
	if err := controller.SetPublicURL("https://mica.example.com", false, "public"); err != nil {
		t.Fatalf("set public url: %v", err)
	}
	body, _ := os.ReadFile(cfgPath)
	if !strings.Contains(string(body), "public_base_url: \"https://mica.example.com\"") {
		t.Fatalf("config not persisted: %s", body)
	}
	if !strings.Contains(string(body), "verify_tls: false") {
		t.Fatalf("verify_tls not persisted: %s", body)
	}
	snap := controller.snapshot()
	if snap.publicBaseURL != "https://mica.example.com" || snap.verifyTLS || snap.preferred != "public" {
		t.Fatalf("snapshot not updated: %+v", snap)
	}
}

func TestCheckPublicURLReachableAndAuth(t *testing.T) {
	const token = "secret-check-token"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/api/auth/check" &&
			r.Header.Get("Authorization") == "Bearer "+token {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()

	controller := NewNetworkController(config.Config{
		PublicBaseURL: server.URL,
		VerifyTLS:     true,
		AuthToken:     token,
	})

	result := controller.Check(context.Background())
	if !result.Reachable || !result.AuthOK || !result.OK || result.Status != 200 {
		t.Fatalf("expected reachable+authOK, got %+v", result)
	}

	// The cached reachability should now feed /api/server/urls.
	h := newURLHandlers("0.0.0.0:12345", controller)
	resp := h.buildServerURLs()
	if data, _ := json.Marshal(resp.Public.Reachable); string(data) != "true" {
		t.Fatalf("expected public reachable true, got %s", data)
	}

	// The token must never appear in the check result or the urls payload.
	checkJSON, _ := json.Marshal(result)
	urlsJSON, _ := json.Marshal(resp)
	if strings.Contains(string(checkJSON), token) || strings.Contains(string(urlsJSON), token) {
		t.Fatalf("token leaked in response")
	}
}

func TestCheckPublicURLWrongToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()

	controller := NewNetworkController(config.Config{PublicBaseURL: server.URL, VerifyTLS: true, AuthToken: "wrong"})
	result := controller.Check(context.Background())
	if !result.Reachable {
		t.Fatalf("expected reachable true (server responded)")
	}
	if result.AuthOK || result.OK {
		t.Fatalf("expected auth failure, got %+v", result)
	}
}

func TestSetPublicURLHandlerRejectsInvalid(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	_ = os.WriteFile(cfgPath, []byte("auth:\n  token: \"abc\"\n"), 0o600)
	controller := NewNetworkController(config.Config{ConfigPath: cfgPath, VerifyTLS: true, PreferredPairingEndpoint: "auto"})
	h := newURLHandlers("127.0.0.1:12345", controller)

	req := httptest.NewRequest(http.MethodPost, "/api/server/public-url",
		strings.NewReader(`{"publicBaseUrl":"ftp://nope"}`))
	rec := httptest.NewRecorder()
	h.SetPublicURL(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}
