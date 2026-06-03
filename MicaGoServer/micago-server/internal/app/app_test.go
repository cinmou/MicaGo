package app

import (
	"testing"

	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
)

func TestSelectAPIStoreInvalid(t *testing.T) {
	_, err := selectAPIStore("nope", &store.Queries{}, &relaydb.DB{})
	if err == nil {
		t.Fatal("expected invalid api-store error")
	}
}
