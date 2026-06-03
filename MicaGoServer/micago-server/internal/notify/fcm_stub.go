package notify

import (
	"context"

	"micagoserver/internal/store"
)

type FCMStubProvider struct{}

func (FCMStubProvider) Name() string { return "fcm" }

func (FCMStubProvider) Send(context.Context, store.DeviceRecord, Notification) error {
	return ErrNotImplemented
}
