package timeutil

import "testing"

func TestAppleMicrosToUnixMilliWithMicroseconds(t *testing.T) {
	got := AppleMicrosToUnixMilli(1_000_000)
	if got == nil {
		t.Fatal("expected a timestamp")
	}
	if *got != 978307201000 {
		t.Fatalf("expected 978307201000, got %d", *got)
	}
}

func TestAppleMicrosToUnixMilliWithNanoseconds(t *testing.T) {
	got := AppleMicrosToUnixMilli(800_297_737_003_547_392)
	if got == nil {
		t.Fatal("expected a timestamp")
	}
	if *got != 1_778_604_937_003 {
		t.Fatalf("expected 1778604937003, got %d", *got)
	}
}
