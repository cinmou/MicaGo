package relaydb

import "fmt"

func (db *DB) Migrate() error {
	statements := []string{
		`CREATE TABLE IF NOT EXISTS chats (
			guid TEXT PRIMARY KEY,
			chat_identifier TEXT,
			service_name TEXT,
			display_name TEXT,
			is_archived INTEGER,
			updated_at INTEGER
		);`,
		`CREATE TABLE IF NOT EXISTS messages (
			guid TEXT PRIMARY KEY,
			chat_guid TEXT,
			source_rowid INTEGER,
			text TEXT,
			subject TEXT,
			service TEXT,
			date_created INTEGER,
			date_read INTEGER,
			date_delivered INTEGER,
			is_from_me INTEGER,
			is_read INTEGER,
			is_delivered INTEGER,
			handle_id TEXT,
			handle_service TEXT,
			cache_has_attachments INTEGER,
			created_at INTEGER
		);`,
		`CREATE TABLE IF NOT EXISTS sync_state (
			key TEXT PRIMARY KEY,
			value TEXT
		);`,
		`CREATE TABLE IF NOT EXISTS attachments (
			guid TEXT PRIMARY KEY,
			message_guid TEXT,
			filename TEXT,
			mime_type TEXT,
			transfer_name TEXT,
			total_bytes INTEGER,
			local_path TEXT,
			is_outgoing INTEGER,
			hide_attachment INTEGER,
			created_at INTEGER
		);`,
		`CREATE TABLE IF NOT EXISTS devices (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			platform TEXT NOT NULL,
			client_type TEXT NOT NULL,
			push_provider TEXT NOT NULL,
			push_token TEXT,
			push_enabled INTEGER NOT NULL DEFAULT 0,
			last_seen_at INTEGER,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		);`,
		// v0.11.3: per-target sync/push rules (whitelist/blacklist overrides).
		`CREATE TABLE IF NOT EXISTS sync_rules (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			target_kind TEXT NOT NULL,
			target_value TEXT NOT NULL,
			sync_mode TEXT NOT NULL,
			push_mode TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			UNIQUE(target_kind, target_value)
		);`,
		// v0.11.x: persisted event-state cache for the lookback update pass.
		`CREATE TABLE IF NOT EXISTS message_state (
			guid TEXT PRIMARY KEY,
			is_read INTEGER,
			date_read INTEGER,
			is_delivered INTEGER,
			date_delivered INTEGER,
			date_edited INTEGER,
			date_retracted INTEGER,
			error INTEGER,
			fingerprint TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		);`,
	}

	for _, statement := range statements {
		if _, err := db.sqlDB.Exec(statement); err != nil {
			return err
		}
	}

	if err := db.ensureColumn("messages", "source_rowid", "INTEGER"); err != nil {
		return err
	}

	// v0.11.5: attachment fidelity — Apple UTI + sticker flag (additive).
	if err := db.ensureColumn("attachments", "uti", "TEXT"); err != nil {
		return err
	}
	if err := db.ensureColumn("attachments", "is_sticker", "INTEGER"); err != nil {
		return err
	}

	return nil
}

func (db *DB) ensureColumn(table, column, columnType string) error {
	rows, err := db.sqlDB.Query(fmt.Sprintf("PRAGMA table_info(%s);", table))
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var cid int
		var name, typ string
		var notNull, pk int
		var dflt any
		if err := rows.Scan(&cid, &name, &typ, &notNull, &dflt, &pk); err != nil {
			return err
		}
		if name == column {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}

	_, err = db.sqlDB.Exec(fmt.Sprintf("ALTER TABLE %s ADD COLUMN %s %s;", table, column, columnType))
	return err
}
