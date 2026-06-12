package relaydb

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type DB struct {
	sqlDB *sql.DB
	path  string
}

func Open(path string) (*DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}

	db, err := openOnce(path)
	if err == nil {
		return db, nil
	}

	// relay.db is a MicaGo-OWNED, fully rebuildable cache (re-synced from
	// chat.db). Unlike Apple's chat.db — which we never repair, vacuum, or delete
	// — a corrupt relay.db can be safely moved aside and rebuilt so the server
	// stays up instead of refusing to start. We never run this on chat.db. See
	// docs/c15-imsg-db-open-and-error-handling.md.
	if !isCorruptionError(err) {
		return nil, err
	}
	quarantined, mvErr := quarantineCorruptDB(path)
	if mvErr != nil {
		return nil, fmt.Errorf("relay.db is corrupt (%v) and could not be moved aside: %w", err, mvErr)
	}
	log.Printf("relay.db was corrupt (%v); moved aside to %s and rebuilding a fresh cache", err, quarantined)
	return openOnce(path)
}

func openOnce(path string) (*DB, error) {
	sqlDB, err := sql.Open("sqlite3", fmt.Sprintf("file:%s?_busy_timeout=5000", path))
	if err != nil {
		return nil, err
	}

	if err := sqlDB.Ping(); err != nil {
		_ = sqlDB.Close()
		return nil, err
	}

	db := &DB{sqlDB: sqlDB, path: path}
	if err := db.Migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}

	return db, nil
}

// isCorruptionError reports whether err is a SQLite "the database file itself is
// damaged" condition — the only class for which moving relay.db aside is the
// correct recovery. Busy/locked/permission errors are deliberately excluded.
func isCorruptionError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "database disk image is malformed") ||
		strings.Contains(msg, "file is not a database") ||
		strings.Contains(msg, "file is encrypted or is not a database") ||
		strings.Contains(msg, "database corruption") ||
		strings.Contains(msg, "malformed database schema")
}

// quarantineCorruptDB renames a corrupt relay.db (and its -wal/-shm sidecars)
// aside so a fresh one can be created in its place. Returns the new main-file
// path. Best-effort on the sidecars.
func quarantineCorruptDB(path string) (string, error) {
	suffix := fmt.Sprintf(".corrupt-%d", time.Now().Unix())
	quarantined := path + suffix
	if err := os.Rename(path, quarantined); err != nil {
		return "", err
	}
	for _, sidecar := range []string{path + "-wal", path + "-shm"} {
		if _, err := os.Stat(sidecar); err == nil {
			_ = os.Rename(sidecar, sidecar+suffix)
		}
	}
	return quarantined, nil
}

func (db *DB) Close() error {
	return db.sqlDB.Close()
}

func (db *DB) SetSyncState(key, value string) error {
	_, err := db.sqlDB.Exec(`
INSERT INTO sync_state (key, value)
VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
`, key, value)
	return err
}

func (db *DB) GetSyncState(key string) (string, bool, error) {
	var value string
	err := db.sqlDB.QueryRow(`SELECT value FROM sync_state WHERE key = ?`, key).Scan(&value)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return value, true, nil
}
