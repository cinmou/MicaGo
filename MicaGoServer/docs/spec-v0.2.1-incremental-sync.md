# Mica v0.2.1 Incremental Sync Spec

## Goal

Mica v0.2.1 extends relay sync so that repeated `--sync-once` runs can import only new clean iMessage messages using source `chat.db` `message.ROWID`.

## Schema Change

`relay.db` `messages` adds:

- `source_rowid INTEGER`

This stores the source `chat.db` `message.ROWID`.

Migration behavior:

- new databases create the column immediately
- existing databases attempt an `ALTER TABLE` to add the column if missing

During early development it is still acceptable to delete `~/.micago/relay.db` and resync from scratch.

## Initial Sync Behavior

If `sync_state.last_message_rowid` does not exist:

- sync is treated as `initial`
- the latest 1000 clean iMessage messages are loaded
- clean rules remain:
  - `chat.service_name = 'iMessage'`
  - `message.text IS NOT NULL OR message.cache_has_attachments = 1`
- rows are upserted into `relay.db`
- `last_message_rowid` is set to the maximum `source_rowid` processed in that initial batch

## Incremental Sync Behavior

If `sync_state.last_message_rowid` exists:

- sync is treated as `incremental`
- only messages with `m.ROWID > last_message_rowid` are read
- clean iMessage rules are preserved
- rows are upserted into `relay.db`
- after a successful batch, `last_message_rowid` advances to the maximum processed `source_rowid`
- if there are no new messages, `last_message_rowid` does not change

## Manual Test Commands

From `micago-server/`:

```bash
rm -f ~/.micago/relay.db
go run ./cmd/micago --sync-once
sqlite3 ~/.micago/relay.db 'SELECT COUNT(*) FROM messages;'
sqlite3 ~/.micago/relay.db "SELECT value FROM sync_state WHERE key = 'last_message_rowid';"
go run ./cmd/micago --sync-once
sqlite3 ~/.micago/relay.db 'SELECT COUNT(*) FROM messages;'
sqlite3 ~/.micago/relay.db "SELECT value FROM sync_state WHERE key = 'last_message_rowid';"
```

Then send or receive a new iMessage manually and run:

```bash
go run ./cmd/micago --sync-once
sqlite3 ~/.micago/relay.db 'SELECT COUNT(*) FROM messages;'
sqlite3 ~/.micago/relay.db "SELECT value FROM sync_state WHERE key = 'last_message_rowid';"
sqlite3 ~/.micago/relay.db 'SELECT guid, source_rowid, date_created FROM messages ORDER BY source_rowid DESC LIMIT 10;'
```

Optional helper:

```bash
./scripts/smoke-v0.2.1-incremental-sync.sh
```

## Completion Criteria

- `messages.source_rowid` exists in `relay.db`
- initial sync stores the max processed `source_rowid` in `sync_state.last_message_rowid`
- repeated `--sync-once` runs do not duplicate already-synced messages
- incremental sync imports only rows with larger source `ROWID`
- clean iMessage filtering rules are preserved
- logs show:
  - sync mode
  - previous `last_message_rowid`
  - number of messages synced
  - new `last_message_rowid`

## Known Limitations

- no background loop yet; sync runs only when `--sync-once` is invoked
- no delete propagation yet; relay rows are only inserted or updated
- initial sync still uses a latest-1000 window rather than a full historical import
- incremental behavior assumes `message.ROWID` is a useful increasing cursor for new messages on this local database
