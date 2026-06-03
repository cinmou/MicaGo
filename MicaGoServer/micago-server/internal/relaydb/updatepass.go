package relaydb

import (
	"context"
	"database/sql"
	"time"

	"micagoserver/internal/store"
)

// updateWindowLimit bounds how many lookback rows a single update pass scans.
const updateWindowLimit = 5000

type updateSource interface {
	ListMessageUpdatesSince(ctx context.Context, afterUnixMilli int64, limit int, caps store.SchemaCapabilities) ([]store.MessageUpdateRow, error)
}

// UpdatePass runs the bounded lookback update pass (v0.11.x). It detects mutable
// state changes (read/delivered/edited/unsent/send-error) on messages already
// tracked in relay.db and returns the events to broadcast. It is additive to,
// and independent of, the rowid-only new-message sync in SyncOnce.
//
// First sight of a message seeds its state WITHOUT emitting, so a fresh relay.db
// (or a brand-new message) never triggers a rebroadcast storm. Only messages
// already present in relay.messages are tracked, so system/non-renderable rows
// are ignored. A lookback of 0 disables the pass.
//
// Missing schema capabilities are skipped: the source query only selects columns
// that exist, and DiffMessageState only compares enabled fields.
func UpdatePass(ctx context.Context, source updateSource, relay *DB, caps store.SchemaCapabilities, lookback time.Duration) (UpdatePassResult, error) {
	var result UpdatePassResult
	if lookback <= 0 {
		return result, nil
	}

	after := time.Now().Add(-lookback).UnixMilli()
	rows, err := source.ListMessageUpdatesSince(ctx, after, updateWindowLimit, caps)
	if err != nil {
		return result, err
	}

	// v0.11.3: skip updates for blocked chats/handles (no insert/update/emit).
	snapshot, err := relay.LoadRuleSnapshot(ctx)
	if err != nil {
		return result, err
	}

	tx, err := relay.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()

	now := time.Now().UnixMilli()

	// Collected during the tx; MessageJSON is fetched after commit so it reflects
	// the updated row.
	type pendingUpdate struct {
		guid    string
		changed []string
	}
	var pendingUpdates []pendingUpdate

	for _, row := range rows {
		exists, err := messageExistsTx(tx, row.GUID)
		if err != nil {
			return result, err
		}
		if !exists {
			continue // not a message we track; new-message sync owns insertion
		}
		if !snapshot.SyncAllowed(row.ChatGUID, row.HandleID) {
			continue // blocked target: no further updates/emits
		}
		result.Scanned++

		current := row.State()
		old, had, err := getMessageStateTx(tx, row.GUID)
		if err != nil {
			return result, err
		}
		fingerprint := current.Fingerprint(caps)

		if !had {
			// Seed without emitting.
			if err := upsertMessageStateTx(tx, row.GUID, current, fingerprint, now); err != nil {
				return result, err
			}
			result.Seeded++
			continue
		}
		if old.Fingerprint(caps) == fingerprint {
			continue // unchanged
		}

		changed, retracted := store.DiffMessageState(old, current, caps)

		// Reflect the new mutable state into the relay row.
		if err := updateMessageMutableTx(tx, row); err != nil {
			return result, err
		}
		if err := upsertMessageStateTx(tx, row.GUID, current, fingerprint, now); err != nil {
			return result, err
		}

		if retracted {
			result.Unsent = append(result.Unsent, UnsentEvent{
				GUID:          row.GUID,
				ChatGUID:      row.ChatGUID,
				DateRetracted: row.DateRetracted,
			})
		} else if len(changed) > 0 {
			pendingUpdates = append(pendingUpdates, pendingUpdate{guid: row.GUID, changed: changed})
		}
	}

	if err := tx.Commit(); err != nil {
		return result, err
	}

	// Build message:update payloads from the now-committed relay rows.
	for _, p := range pendingUpdates {
		messages, err := relay.GetMessagesByGUIDs(ctx, []string{p.guid})
		if err != nil {
			return result, err
		}
		if len(messages) == 0 {
			continue
		}
		result.Updates = append(result.Updates, MessageUpdate{
			Message: messages[0],
			Changed: p.changed,
		})
	}

	return result, nil
}

func messageExistsTx(tx *sql.Tx, guid string) (bool, error) {
	var one int
	err := tx.QueryRow(`SELECT 1 FROM messages WHERE guid = ? LIMIT 1`, guid).Scan(&one)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func getMessageStateTx(tx *sql.Tx, guid string) (store.MessageState, bool, error) {
	var (
		isRead        sql.NullInt64
		dateRead      sql.NullInt64
		isDelivered   sql.NullInt64
		dateDelivered sql.NullInt64
		dateEdited    sql.NullInt64
		dateRetracted sql.NullInt64
		errorCode     sql.NullInt64
		fingerprint   string
		updatedAt     int64
	)
	err := tx.QueryRow(`
SELECT is_read, date_read, is_delivered, date_delivered, date_edited, date_retracted, error, fingerprint, updated_at
FROM message_state WHERE guid = ?`, guid).Scan(
		&isRead, &dateRead, &isDelivered, &dateDelivered, &dateEdited, &dateRetracted, &errorCode, &fingerprint, &updatedAt,
	)
	if err == sql.ErrNoRows {
		return store.MessageState{}, false, nil
	}
	if err != nil {
		return store.MessageState{}, false, err
	}
	return store.MessageState{
		IsRead:        isRead.Valid && isRead.Int64 != 0,
		DateRead:      nullToPtr(dateRead),
		IsDelivered:   isDelivered.Valid && isDelivered.Int64 != 0,
		DateDelivered: nullToPtr(dateDelivered),
		DateEdited:    nullToPtr(dateEdited),
		DateRetracted: nullToPtr(dateRetracted),
		ErrorCode:     errorCode.Int64,
	}, true, nil
}

func upsertMessageStateTx(tx *sql.Tx, guid string, state store.MessageState, fingerprint string, now int64) error {
	_, err := tx.Exec(`
INSERT INTO message_state (
	guid, is_read, date_read, is_delivered, date_delivered, date_edited, date_retracted, error, fingerprint, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
	is_read = excluded.is_read,
	date_read = excluded.date_read,
	is_delivered = excluded.is_delivered,
	date_delivered = excluded.date_delivered,
	date_edited = excluded.date_edited,
	date_retracted = excluded.date_retracted,
	error = excluded.error,
	fingerprint = excluded.fingerprint,
	updated_at = excluded.updated_at;
`,
		guid,
		boolToInt(state.IsRead),
		state.DateRead,
		boolToInt(state.IsDelivered),
		state.DateDelivered,
		state.DateEdited,
		state.DateRetracted,
		state.ErrorCode,
		fingerprint,
		now,
	)
	return err
}

func updateMessageMutableTx(tx *sql.Tx, row store.MessageUpdateRow) error {
	_, err := tx.Exec(`
UPDATE messages SET
	text = ?,
	subject = ?,
	date_read = ?,
	date_delivered = ?,
	is_read = ?,
	is_delivered = ?
WHERE guid = ?;
`,
		row.Text,
		row.Subject,
		row.DateRead,
		row.DateDelivered,
		boolToInt(row.IsRead),
		boolToInt(row.IsDelivered),
		row.GUID,
	)
	return err
}

func nullToPtr(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	out := v.Int64
	return &out
}
