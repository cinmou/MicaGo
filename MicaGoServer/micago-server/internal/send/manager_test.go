package send

import (
	"testing"
	"time"
)

func TestPendingManagerAddStampsDefaults(t *testing.T) {
	m := NewPendingSendManager()
	if err := m.Add(PendingSend{TempGUID: "t1", Timeout: 15 * time.Second}); err != nil {
		t.Fatal(err)
	}
	p, ok := m.Get("t1")
	if !ok {
		t.Fatal("expected pending send present")
	}
	if p.Status != StatusPending {
		t.Fatalf("expected status pending, got %q", p.Status)
	}
	if p.CreatedAt.IsZero() {
		t.Fatal("expected CreatedAt stamped")
	}
	if p.Deadline.IsZero() || !p.Deadline.After(p.CreatedAt) {
		t.Fatal("expected Deadline = CreatedAt + Timeout")
	}
}

func TestPendingManagerResolveConfirmsAndClaims(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "t1"})

	if ok := m.Resolve("t1", "msg-1", 42); !ok {
		t.Fatal("expected Resolve to succeed")
	}
	p, _ := m.Get("t1")
	if p.Status != StatusConfirmed || p.MatchedGUID != "msg-1" || p.MatchedROWID != 42 {
		t.Fatalf("unexpected resolved record: %+v", p)
	}
	if _, claimed := m.ClaimedSnapshot()["msg-1"]; !claimed {
		t.Fatal("expected msg-1 to be claimed")
	}
}

func TestPendingManagerResolveRejectsRowClaimedByAnother(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "first"})
	_ = m.Add(PendingSend{TempGUID: "second"})

	if ok := m.Resolve("first", "msg-1", 0); !ok {
		t.Fatal("first claim should succeed")
	}
	if ok := m.Resolve("second", "msg-1", 0); ok {
		t.Fatal("second claim of the same row must fail")
	}
}

func TestPendingManagerRemoveReleasesClaim(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "t1"})
	m.Resolve("t1", "msg-1", 0)
	m.Remove("t1")
	if _, claimed := m.ClaimedSnapshot()["msg-1"]; claimed {
		t.Fatal("expected claim released on Remove")
	}
}

func TestPendingManagerReject(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "t1"})
	m.Reject("t1", "send_failed")
	p, _ := m.Get("t1")
	if p.Status != StatusFailed || p.FailReason != "send_failed" {
		t.Fatalf("unexpected rejected record: %+v", p)
	}
}

func TestPendingManagerExpireTimedOut(t *testing.T) {
	m := NewPendingSendManager()
	past := time.Now().Add(-time.Minute)
	_ = m.Add(PendingSend{TempGUID: "old", CreatedAt: past, Deadline: past.Add(time.Second), Status: StatusPending})
	_ = m.Add(PendingSend{TempGUID: "fresh", Timeout: time.Hour})

	expired := m.ExpireTimedOut(time.Now())
	if len(expired) != 1 || expired[0].TempGUID != "old" {
		t.Fatalf("expected only 'old' to expire, got %+v", expired)
	}
	if p, _ := m.Get("old"); p.Status != StatusFailed {
		t.Fatal("expected expired send marked failed")
	}
	if p, _ := m.Get("fresh"); p.Status != StatusPending {
		t.Fatal("expected fresh send still pending")
	}
}

func TestPendingManagerList(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "a"})
	_ = m.Add(PendingSend{TempGUID: "b"})
	if got := len(m.List()); got != 2 {
		t.Fatalf("expected 2 pending, got %d", got)
	}
}

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
