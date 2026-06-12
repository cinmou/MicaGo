package version

import (
	"strings"
	"testing"
)

// C17: the --version line is the freshness contract between the companion and
// the backend — it must always carry every identity field, with no empties.
func TestStringCarriesAllIdentityFields(t *testing.T) {
	s := String()
	for _, want := range []string{"MicaGoServer", Version, "commit=", "buildTime=", "go=go", "/"} {
		if !strings.Contains(s, want) {
			t.Fatalf("version string missing %q: %s", want, s)
		}
	}
	if strings.Contains(s, "commit= ") || strings.HasSuffix(s, "commit=") {
		t.Fatalf("commit must never be empty (fallback to vcs stamp or 'unknown'): %s", s)
	}
}

func TestResolvedNeverEmpty(t *testing.T) {
	if ResolvedCommit() == "" {
		t.Fatal("ResolvedCommit must not be empty")
	}
	if ResolvedBuildTime() == "" {
		t.Fatal("ResolvedBuildTime must not be empty")
	}
}

// ldflags-injected values must win over the VCS fallback.
func TestLdflagsValuesWin(t *testing.T) {
	oldC, oldB := Commit, BuildTime
	t.Cleanup(func() { Commit, BuildTime = oldC, oldB })
	Commit, BuildTime = "abc1234", "2026-06-12T00:00:00Z"
	if ResolvedCommit() != "abc1234" || ResolvedBuildTime() != "2026-06-12T00:00:00Z" {
		t.Fatalf("ldflags values must win: %s %s", ResolvedCommit(), ResolvedBuildTime())
	}
	if !strings.Contains(String(), "commit=abc1234") {
		t.Fatalf("String() must use injected commit: %s", String())
	}
}
