package httpapi

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"micagoserver/internal/config"
)

func TestHealthIsUnauthenticated(t *testing.T) {
	router := NewRouter(
		NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{}),
		nil,
		AuthConfig{Enabled: true, Token: "secret"},
	)

	req := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestAuthMissingWrongAndCorrect(t *testing.T) {
	router := NewRouter(
		NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{}),
		nil,
		AuthConfig{Enabled: true, Token: "secret"},
	)

	for _, tc := range []struct {
		name   string
		header string
		want   int
	}{
		{name: "missing", header: "", want: http.StatusUnauthorized},
		{name: "wrong", header: "Bearer nope", want: http.StatusUnauthorized},
		{name: "correct", header: "Bearer secret", want: http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/api/chats", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)
			if rec.Code != tc.want {
				t.Fatalf("expected %d, got %d", tc.want, rec.Code)
			}
		})
	}
}

func TestServerInfoDoesNotExposeToken(t *testing.T) {
	router := NewRouter(
		NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{
			HTTPAddr:  "127.0.0.1:3000",
			PublicURL: "https://example.com",
		}, StatusDeps{}),
		nil,
		AuthConfig{Enabled: true, Token: "secret"},
	)

	req := httptest.NewRequest(http.MethodGet, "/api/server/info", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "secret") {
		t.Fatalf("response leaked token: %s", rec.Body.String())
	}
}
