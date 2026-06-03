package notify

import (
	"context"

	"micagoserver/internal/store"
)

type NoneProvider struct{}

func (NoneProvider) Name() string { return "none" }

func (NoneProvider) Send(context.Context, store.DeviceRecord, Notification) error { return nil }
