# Mica v0.2.0 Relay DB Spec

## Goal

Mica v0.2.0 adds a lightweight local relay database that stores a clean iMessage-only subset of macOS Messages data copied from `~/Library/Messages/chat.db`.

This milestone is intentionally limited to:

- bootstrap `relay.db`
- create the minimal schema
- run a one-way sync skeleton
- copy a clean iMessage view only

This milestone does not implement sending, WebSocket, auth, frontend, Firebase, push notifications, Private API, or attachment download.

## Relay DB Path

Default path:

```text
~/.micago/relay.db
```

Resolved path:

```text
filepath.Join(os.Getenv("HOME"), ".micago", "relay.db")
```

## Schema

### chats

- `guid TEXT PRIMARY KEY`
- `chat_identifier TEXT`
- `service_name TEXT`
- `display_name TEXT`
- `is_archived INTEGER`
- `updated_at INTEGER`

### messages

- `guid TEXT PRIMARY KEY`
- `chat_guid TEXT`
- `text TEXT`
- `subject TEXT`
- `service TEXT`
- `date_created INTEGER`
- `date_read INTEGER`
- `date_delivered INTEGER`
- `is_from_me INTEGER`
- `is_read INTEGER`
- `is_delivered INTEGER`
- `handle_id TEXT`
- `handle_service TEXT`
- `cache_has_attachments INTEGER`
- `created_at INTEGER`

### sync_state

- `key TEXT PRIMARY KEY`
- `value TEXT`

## Sync Behavior

The initial sync is a one-way copy:

- source: `~/Library/Messages/chat.db`
- destination: `~/.micago/relay.db`

Rules:

- chats are copied with `service_name = 'iMessage'`
- messages are copied with:
  - chat-level `service=iMessage` via joined `chat.service_name = 'iMessage'`
  - `includeEmpty = false`
  - `(message.text IS NOT NULL OR message.cache_has_attachments = 1)`
- initial sync copies the latest `1000` messages by default
- sync uses upserts
- sync does not delete old relay rows yet

## What Data Is Copied

Copied chat fields:

- `guid`
- `chat_identifier`
- `service_name`
- `display_name`
- `is_archived`

Copied message fields:

- `guid`
- `chat_guid`
- `text`
- `subject`
- `service`
- `date_created`
- `date_read`
- `date_delivered`
- `is_from_me`
- `is_read`
- `is_delivered`
- `handle_id`
- `handle_service`
- `cache_has_attachments`

Copied sync metadata:

- last sync timestamp
- last synced message guid
- last synced message timestamp

## What Is Deliberately Not Copied

- non-iMessage chats by default
- empty non-attachment messages
- attachment binary data
- attachment tables or download state
- reactions
- edits / unsends
- reply metadata
- rich attributed body structures
- BlueBubbles private API state
- relay-side deletes or tombstones

## Manual Test Steps

From `micago-server/`:

```bash
go test ./...
go run ./cmd/micago --sync-once
sqlite3 ~/.micago/relay.db '.tables'
sqlite3 ~/.micago/relay.db 'SELECT COUNT(*) FROM chats;'
sqlite3 ~/.micago/relay.db 'SELECT COUNT(*) FROM messages;'
sqlite3 ~/.micago/relay.db 'SELECT key, value FROM sync_state ORDER BY key;'
sqlite3 ~/.micago/relay.db 'SELECT guid, service_name, is_archived FROM chats ORDER BY updated_at DESC LIMIT 10;'
sqlite3 ~/.micago/relay.db 'SELECT guid, chat_guid, text, date_created FROM messages ORDER BY date_created DESC LIMIT 10;'
```

Expected checks:

- `relay.db` is created under `~/.micago/`
- `chats`, `messages`, and `sync_state` tables exist
- chats are iMessage-only
- messages are iMessage-only and exclude empty non-attachment messages
- repeated `--sync-once` runs do not duplicate rows

## Completion Criteria

- `~/.micago/relay.db` is created automatically if missing
- migrations create the expected tables
- `go run ./cmd/micago --sync-once` performs a one-way sync and exits
- initial sync upserts iMessage chats and the latest 1000 clean iMessage messages
- sync writes sync metadata to `sync_state`
- logs show relay.db path, synced chat count, synced message count, and the last synced message guid or date
- `go test ./...` passes
