package notify

import (
	"context"

	"micagoserver/internal/store"
)

type HMSStubProvider struct {
	name string
}

func NewHMSStubProvider(name string) HMSStubProvider {
	return HMSStubProvider{name: name}
}

func (p HMSStubProvider) Name() string {
	if p.name != "" {
		return p.name
	}
	return "hms"
}

func (p HMSStubProvider) Send(context.Context, store.DeviceRecord, Notification) error {
	return ErrNotImplemented
}
