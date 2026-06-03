package notify

import (
	"context"

	"micagoserver/internal/store"
)

type NtfyStubProvider struct{}

func (NtfyStubProvider) Name() string { return "ntfy" }

func (NtfyStubProvider) Send(context.Context, store.DeviceRecord, Notification) error {
	return ErrNotImplemented
}
