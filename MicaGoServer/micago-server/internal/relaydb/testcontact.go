package relaydb

import (
	"context"
	"fmt"
	"time"

	"micagoserver/internal/store"
	"micagoserver/internal/testcontact"
)

// testContactStateKey persists the on/off flag in the existing sync_state table.
const testContactStateKey = "test_contact_enabled"

// TestContactEnabled reports whether the synthetic test contact is currently on.
func (db *DB) TestContactEnabled(_ context.Context) (bool, error) {
	value, ok, err := db.GetSyncState(testContactStateKey)
	if err != nil {
		return false, err
	}
	return ok && value == "1", nil
}

// SetTestContactEnabled flips the test contact on or off: enabling seeds the
// synthetic chat + greeting, disabling removes all of its rows. The persisted
// flag is written last so a mid-way failure never leaves the flag lying about
// the data.
func (db *DB) SetTestContactEnabled(ctx context.Context, enabled bool) error {
	if enabled {
		if err := db.ensureTestContact(ctx); err != nil {
			return err
		}
	} else if err := db.removeTestContact(ctx); err != nil {
		return err
	}
	value := "0"
	if enabled {
		value = "1"
	}
	return db.SetSyncState(testContactStateKey, value)
}

// TestContactWelcome returns the seeded inbound greeting (nil if absent), used to
// broadcast a message:new when the contact is enabled.
func (db *DB) TestContactWelcome(ctx context.Context) (*store.MessageJSON, error) {
	return db.messageByGUID(ctx, testcontact.WelcomeGUID)
}

// AppendTestOutgoingMessage records a client-sent message into the test chat as
// a delivered outgoing row — the loopback that replaces a real iMessage send.
func (db *DB) AppendTestOutgoingMessage(ctx context.Context, text string) (*store.MessageJSON, error) {
	return db.appendTestMessage(ctx, text, true, "out")
}

// AppendTestInboundMessage records a message *from* the test contact (typed in
// the Companion's Debug card) as an incoming row, so it pushes to the client
// exactly like a received iMessage.
func (db *DB) AppendTestInboundMessage(ctx context.Context, text string) (*store.MessageJSON, error) {
	return db.appendTestMessage(ctx, text, false, "in")
}

// appendTestMessage inserts one synthetic message and returns the stored row.
//
// source_rowid is deliberately left NULL: the delta cursor is the global
// MAX(source_rowid), so a synthetic rowid would corrupt real incremental sync.
// NULL keeps these rows out of the delta watermark entirely; the client still
// sees them on chat open (ListChatMessages falls back to date_created) and live
// over the WebSocket.
func (db *DB) appendTestMessage(ctx context.Context, text string, fromMe bool, tag string) (*store.MessageJSON, error) {
	now := time.Now()
	ms := now.UnixMilli()
	guid := fmt.Sprintf("micago-test-%s-%d", tag, now.UnixNano())
	if _, err := db.sqlDB.ExecContext(ctx, `
INSERT INTO messages (guid, chat_guid, text, service, date_created, date_read, date_delivered,
	is_from_me, is_read, is_delivered, handle_id, handle_service, cache_has_attachments, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 0, ?);`,
		guid, testcontact.ChatGUID, text, testcontact.Service, ms, ms, ms,
		boolToInt(fromMe), boolToInt(fromMe), // inbound stays unread (is_read=0)
		testcontact.Handle, testcontact.Service, ms); err != nil {
		return nil, err
	}
	return db.messageByGUID(ctx, guid)
}

// ResetTestContactMessages wipes the test conversation back to just the greeting
// — called on startup so each session begins with a clean scratchpad.
func (db *DB) ResetTestContactMessages(ctx context.Context) error {
	if _, err := db.sqlDB.ExecContext(ctx,
		`DELETE FROM messages WHERE chat_guid = ? AND guid != ?`,
		testcontact.ChatGUID, testcontact.WelcomeGUID); err != nil {
		return err
	}
	// Re-seed the greeting in case it was missing.
	return db.ensureTestContact(ctx)
}

func (db *DB) ensureTestContact(ctx context.Context) error {
	now := time.Now().UnixMilli()
	tx, err := db.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit

	if _, err := tx.ExecContext(ctx, `
INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, updated_at)
VALUES (?, ?, ?, ?, 0, ?)
ON CONFLICT(guid) DO UPDATE SET
	chat_identifier = excluded.chat_identifier,
	service_name = excluded.service_name,
	display_name = excluded.display_name,
	updated_at = excluded.updated_at;`,
		testcontact.ChatGUID, testcontact.Handle, testcontact.Service, testcontact.DisplayName, now); err != nil {
		return err
	}

	// ON CONFLICT DO NOTHING: re-enabling keeps the original greeting timestamp,
	// so it stays at the top of the thread instead of jumping below later sends.
	if _, err := tx.ExecContext(ctx, `
INSERT INTO messages (guid, chat_guid, text, service, date_created, date_read, date_delivered,
	is_from_me, is_read, is_delivered, handle_id, handle_service, cache_has_attachments, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, 0, 1, 1, ?, ?, 0, ?)
ON CONFLICT(guid) DO NOTHING;`,
		testcontact.WelcomeGUID, testcontact.ChatGUID, testcontact.WelcomeText, testcontact.Service,
		now, now, now, testcontact.Handle, testcontact.Service, now); err != nil {
		return err
	}

	return tx.Commit()
}

func (db *DB) removeTestContact(ctx context.Context) error {
	tx, err := db.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit

	const inChat = `(SELECT guid FROM messages WHERE chat_guid = ?)`
	for _, stmt := range []string{
		`DELETE FROM attachments WHERE message_guid IN ` + inChat,
		`DELETE FROM message_state WHERE guid IN ` + inChat,
		`DELETE FROM messages WHERE chat_guid = ?`,
		`DELETE FROM chats WHERE guid = ?`,
	} {
		if _, err := tx.ExecContext(ctx, stmt, testcontact.ChatGUID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// messageByGUID returns the single stored message, or (nil, nil) if absent.
func (db *DB) messageByGUID(ctx context.Context, guid string) (*store.MessageJSON, error) {
	messages, err := db.GetMessagesByGUIDs(ctx, []string{guid})
	if err != nil {
		return nil, err
	}
	if len(messages) == 0 {
		return nil, nil
	}
	return &messages[0], nil
}
