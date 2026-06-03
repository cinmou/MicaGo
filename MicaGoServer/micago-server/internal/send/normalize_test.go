package send

import "testing"

func TestNormalizeText(t *testing.T) {
	got := NormalizeText("  HeLLo \n 世界  ")
	if got != "hello世界" {
		t.Fatalf("expected normalized text hello世界, got %q", got)
	}
}
