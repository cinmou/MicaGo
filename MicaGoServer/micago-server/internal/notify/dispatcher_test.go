package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
)

func TestNoneProviderNoOp(t *testing.T) {
	if err := (NoneProvider{}).Send(context.Background(), store.DeviceRecord{}, Notification{}); err != nil {
		t.Fatalf("expected none provider to no-op, got %v", err)
	}
}

func TestDispatcherSendTestUsesWebhookProvider(t *testing.T) {
	var got map[string]any
	dispatcher := NewDispatcher(config.Config{
		NotificationsEnabled: true,
		NotificationPreview:  "sender",
		WebhookURL:           "https://example.test/webhook",
	})
	dispatcher.providers["webhook"] = WebhookProvider{
		URL: "https://example.test/webhook",
		Client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			defer req.Body.Close()
			if err := json.NewDecoder(req.Body).Decode(&got); err != nil {
				t.Fatal(err)
			}
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(bytes.NewReader(nil)),
				Header:     make(http.Header),
			}, nil
		})},
	}
	device := store.DeviceRecord{
		ID:           "dev-1",
		Name:         "Device",
		Platform:     "android",
		ClientType:   "flutter",
		PushProvider: "webhook",
		PushEnabled:  true,
	}
	if err := dispatcher.SendTest(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	if got["notification"] == nil {
		t.Fatalf("expected webhook payload, got %#v", got)
	}
}

func TestDispatcherBuildsNotificationPreview(t *testing.T) {
	dispatcher := NewDispatcher(config.Config{
		NotificationsEnabled: true,
		NotificationPreview:  "sender_and_text",
	})
	text := "hello"
	event := relaydb.NotificationEvent{
		ChatGUID:       "chat-1",
		ChatIdentifier: ptr("chat@example.com"),
		Message: store.MessageJSON{
			GUID: "msg-1",
			Text: &text,
		},
	}
	notification := dispatcher.buildNotification(event)
	if notification.Title != "chat@example.com" {
		t.Fatalf("expected sender title, got %q", notification.Title)
	}
	if notification.Body != "hello" {
		t.Fatalf("expected text body, got %q", notification.Body)
	}
}

func ptr[T any](v T) *T { return &v }

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}
