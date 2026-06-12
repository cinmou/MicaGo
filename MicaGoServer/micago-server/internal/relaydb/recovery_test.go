package relaydb

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// C15: relay.db is a MicaGo-owned, rebuildable cache. A corrupt one must be
// moved aside and rebuilt so the server still starts — never repaired in place,
// and this path is NEVER applied to Apple chat.db.
func TestOpenRecoversFromCorruptRelayDB(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.db")

	// Write a file that is not a valid SQLite database.
	if err := os.WriteFile(path, []byte("this is not a sqlite database, it is garbage"), 0o644); err != nil {
		t.Fatalf("seed corrupt file: %v", err)
	}

	db, err := Open(path)
	if err != nil {
		t.Fatalf("Open should recover a corrupt relay.db, got: %v", err)
	}
	defer db.Close()

	// The rebuilt DB must be usable (schema present).
	if err := db.SetSyncState("k", "v"); err != nil {
		t.Fatalf("rebuilt relay.db not usable: %v", err)
	}
	if v, ok, _ := db.GetSyncState("k"); !ok || v != "v" {
		t.Fatalf("rebuilt relay.db lost data: ok=%v v=%q", ok, v)
	}

	// The corrupt original must have been quarantined, not deleted.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	var foundQuarantine bool
	for _, e := range entries {
		if filepath.Ext(e.Name()) != "" && len(e.Name()) > len("relay.db") &&
			e.Name()[:len("relay.db.corrupt")] == "relay.db.corrupt" {
			foundQuarantine = true
		}
	}
	if !foundQuarantine {
		t.Fatal("expected a relay.db.corrupt-* quarantine file")
	}
}

func TestIsCorruptionError(t *testing.T) {
	corrupt := []string{
		"database disk image is malformed",
		"file is not a database",
		"file is encrypted or is not a database",
	}
	for _, m := range corrupt {
		if !isCorruptionError(errors.New(m)) {
			t.Fatalf("%q should be classified as corruption", m)
		}
	}
	// Busy/locked/permission are NOT corruption — must not trigger move-aside.
	notCorrupt := []string{
		"database is locked",
		"database table is locked",
		"unable to open database file",
		"permission denied",
	}
	for _, m := range notCorrupt {
		if isCorruptionError(errors.New(m)) {
			t.Fatalf("%q must NOT be classified as corruption", m)
		}
	}
	if isCorruptionError(nil) {
		t.Fatal("nil is not corruption")
	}
}
