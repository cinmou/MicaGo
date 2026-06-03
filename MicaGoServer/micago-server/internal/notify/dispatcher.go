package notify

import (
	"context"
	"errors"
	"strings"
	"time"

	"micagoserver/internal/config"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
)

type Dispatcher struct {
	enabled     bool
	previewMode string
	providers   map[string]Provider
}

func NewDispatcher(cfg config.Config) *Dispatcher {
	providers := map[string]Provider{
		"none":         NoneProvider{},
		"webhook":      WebhookProvider{URL: cfg.WebhookURL},
		"fcm":          FCMStubProvider{},
		"hms":          NewHMSStubProvider("hms"),
		"harmony_push": NewHMSStubProvider("harmony_push"),
		"ntfy":         NtfyStubProvider{},
	}
	return &Dispatcher{
		enabled:     cfg.NotificationsEnabled,
		previewMode: cfg.NotificationPreview,
		providers:   providers,
	}
}

func (d *Dispatcher) ProviderNames() []string {
	return []string{"none", "webhook", "fcm", "hms", "harmony_push", "ntfy"}
}

func (d *Dispatcher) DispatchNewMessages(ctx context.Context, devices []store.DeviceRecord, events []relaydb.NotificationEvent) error {
	if !d.enabled {
		return nil
	}
	for _, event := range events {
		if event.Message.IsFromMe {
			continue
		}
		notification := d.buildNotification(event)
		for _, device := range devices {
			if !device.PushEnabled {
				continue
			}
			if device.PushProvider == "none" {
				continue
			}
			provider, ok := d.providers[device.PushProvider]
			if !ok {
				continue
			}
			if err := provider.Send(ctx, device, notification); err != nil && !errors.Is(err, ErrPushNotConfigured) {
				return err
			}
		}
	}
	return nil
}

func (d *Dispatcher) SendTest(ctx context.Context, device store.DeviceRecord) error {
	if !d.enabled {
		return ErrPushNotConfigured
	}
	if !device.PushEnabled || device.PushProvider == "none" {
		return ErrPushNotConfigured
	}
	provider, ok := d.providers[device.PushProvider]
	if !ok {
		return ErrNotImplemented
	}
	return provider.Send(ctx, device, Notification{
		Type:        "test",
		Title:       "MicaGoServer test notification",
		Body:        "Notifications are configured for this device",
		PreviewMode: d.previewMode,
		CreatedAt:   time.Now().UnixMilli(),
	})
}

func (d *Dispatcher) buildNotification(event relaydb.NotificationEvent) Notification {
	title := "New iMessage"
	body := ""
	sender := event.ChatLabel()

	switch d.previewMode {
	case "sender":
		body = sender
	case "sender_and_text":
		if sender != "" {
			title = sender
		}
		body = strings.TrimSpace(stringValue(event.Message.Text))
	case "none":
	default:
		body = sender
	}

	return Notification{
		Type:        "message:new",
		MessageGUID: event.Message.GUID,
		ChatGUID:    event.ChatGUID,
		Title:       title,
		Body:        body,
		PreviewMode: d.previewMode,
		CreatedAt:   time.Now().UnixMilli(),
	}
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
