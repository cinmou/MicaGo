package send

import "testing"

func TestPendingManagerRejectsDuplicateTempGUID(t *testing.T) {
	manager := NewPendingSendManager()
	pending := PendingSend{TempGUID: "dup"}

	if err := manager.Add(pending); err != nil {
		t.Fatal(err)
	}
	if err := manager.Add(pending); err != ErrDuplicateTempGUID {
		t.Fatalf("expected ErrDuplicateTempGUID, got %v", err)
	}
}

func TestPendingManagerRemoveCleansUp(t *testing.T) {
	manager := NewPendingSendManager()
	if err := manager.Add(PendingSend{TempGUID: "one"}); err != nil {
		t.Fatal(err)
	}
	manager.Remove("one")
	if manager.Has("one") {
		t.Fatal("expected pending send to be removed")
	}
}
