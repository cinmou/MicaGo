package notify

import (
	"context"
	"errors"

	"micagoserver/internal/store"
)

var (
	ErrNotImplemented    = errors.New("notification provider not implemented")
	ErrPushNotConfigured = errors.New("push not configured")
)

type Provider interface {
	Name() string
	Send(ctx context.Context, device store.DeviceRecord, notification Notification) error
}
