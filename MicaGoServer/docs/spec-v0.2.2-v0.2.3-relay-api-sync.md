# Mica v0.2.2-v0.2.3 Relay API + Periodic Sync Spec

## Goal

Move Mica toward the architecture:

```text
chat.db -> sync scanner -> relay.db -> API
```

This milestone keeps the system read-only and local while shifting the default API reads onto `relay.db` and adding a periodic sync loop.

## Architecture

- source of truth input: `~/Library/Messages/chat.db`
- sync target: `~/.micago/relay.db`
- default HTTP API store: `relaydb`
- debug HTTP API store: `chatdb`

Clean-view rules remain:

- `service=iMessage`
- `includeEmpty=false`
- `(message.text IS NOT NULL OR message.cache_has_attachments = 1)`

## New Flags

- `--sync-once`
  Runs one relay sync and exits.
- `--api-store=relaydb|chatdb`
  Selects whether HTTP reads come from relay.db or direct chat.db reads.
- `--sync-interval=5s`
  Periodic sync interval.
- `--disable-sync-loop`
  Disables the periodic sync loop after startup.

Default behavior:

- `api-store=relaydb`
- `sync-interval=5s`
- sync once at startup
- continue periodic sync unless disabled

## Relay DB-Backed API Behavior

When `--api-store=relaydb`:

- `GET /api/chats` reads from relay.db
- `GET /api/messages/recent` reads from relay.db
- `GET /api/chats/{guid}/messages` reads from relay.db

Behavior notes:

- `service=iMessage` works over relay contents
- `service=all` works over relay contents
- `service=SMS` or `service=RCS` returns empty if those services are not stored in relay.db
- `includeEmpty` is accepted but relay.db is normally already pre-filtered to a clean view
- `withArchived` still filters relay chat rows

When `--api-store=chatdb`:

- existing direct chat.db reads are preserved for debugging

## Periodic Sync Behavior

On startup:

1. open `chat.db`
2. open or migrate `relay.db`
3. run one sync immediately
4. start HTTP API
5. continue periodic sync unless disabled

Sync mode:

- initial sync if `sync_state.last_message_rowid` is missing
- incremental sync otherwise

Incremental cursor:

- `sync_state.last_message_rowid`

Failure policy:

- startup open/sync failures can fail process startup
- later periodic sync failures are logged and do not crash HTTP API

Graceful shutdown:

- sync loop stops on `SIGINT` / `SIGTERM`
- HTTP server shuts down on `SIGINT` / `SIGTERM`

## Manual Test Plan

```bash
rm -f ~/.micago/relay.db
go run ./cmd/micago --sync-once
sqlite3 ~/.micago/relay.db '.tables'
sqlite3 ~/.micago/relay.db 'SELECT COUNT(*) FROM chats;'
sqlite3 ~/.micago/relay.db 'SELECT COUNT(*) FROM messages;'
sqlite3 ~/.micago/relay.db "SELECT key, value FROM sync_state ORDER BY key;"
go run ./cmd/micago --api-store=relaydb
curl -s 'http://127.0.0.1:3000/api/health'
curl -s 'http://127.0.0.1:3000/api/chats?limit=5'
curl -s 'http://127.0.0.1:3000/api/messages/recent?limit=5'
curl -s 'http://127.0.0.1:3000/api/chats/<guid>/messages?limit=5'
go run ./cmd/micago --api-store=chatdb --disable-sync-loop
```

Optional helper:

```bash
./scripts/smoke-v0.2.2-v0.2.3.sh --reset
```

Then:

1. leave server running with relaydb API store
2. send or receive a new iMessage manually
3. wait at least one sync interval
4. call `/api/messages/recent`
5. confirm the new message appears

## Completion Criteria

- v0.2.1 incremental sync exists and is preserved
- relay.db exposes API read queries for chats and messages
- default API store is relaydb
- `--api-store=chatdb` preserves direct read debugging
- startup runs one sync
- periodic sync runs every configured interval unless disabled
- sync loop stops on shutdown
- periodic sync errors are logged and non-fatal
- `gofmt` passes
- `go test ./...` passes

## Known Limitations

- no sending
- no WebSocket
- no auth
- no frontend
- no Private API
- no delete propagation from chat.db to relay.db
- relay.db still stores only the clean iMessage subset
- no background daemon management beyond the in-process ticker loop
