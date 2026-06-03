# Mica v0.1 Technical Spec

Scope: first implementation milestone for a lightweight Mac-based iMessage relay in Go.

Constraints:
- Read-only access to `~/Library/Messages/chat.db`
- No Firebase
- No push notifications
- No sending messages
- No WebSocket
- No attachment download
- No Private API
- No OAuth
- No UI

## Goal

Mica v0.1 is a local HTTP service that opens the macOS Messages database in read-only mode, converts Apple timestamps correctly, and exposes stable JSON read endpoints for chats and messages.

## Endpoints

- `GET /api/health`
- `GET /api/messages/recent`
- `GET /api/chats`
- `GET /api/chats/{guid}/messages`

## Package Structure

```text
mica/
  cmd/mica/
    main.go
  internal/app/
    app.go
  internal/config/
    config.go
  internal/httpapi/
    router.go
    handlers.go
    errors.go
    response.go
  internal/store/
    db.go
    queries.go
    models.go
  internal/timeutil/
    apple_time.go
```

## Responsibilities

- `cmd/mica/main.go`
  Starts the process, loads config, opens the DB, builds the router, and starts HTTP.
- `internal/config/config.go`
  Resolves the default `chat.db` path from `$HOME`.
- `internal/store/db.go`
  Opens SQLite in read-only mode.
- `internal/store/queries.go`
  Runs the confirmed `chat.db` read queries.
- `internal/store/models.go`
  Defines DB-facing and API-facing structs.
- `internal/timeutil/apple_time.go`
  Converts Apple epoch timestamps to Unix time.
- `internal/httpapi/handlers.go`
  Implements the four HTTP handlers.

## Database Path

Default path:

```text
~/Library/Messages/chat.db
```

Resolved path:

```go
filepath.Join(os.Getenv("HOME"), "Library", "Messages", "chat.db")
```

## Database Open Rules

- Open SQLite in read-only mode.
- Do not create, migrate, or modify schema.
- Do not write PRAGMAs that mutate the DB.
- Fail startup if the DB cannot be opened.

Recommended DSN shape:

```text
file:/Users/<user>/Library/Messages/chat.db?mode=ro
```

If the driver supports it, also prefer:

- busy timeout
- immutable mode only if confirmed safe in local testing

## HTTP API

### `GET /api/health`

Purpose:
- Confirms the process is running and the DB handle is available.

Response:

```json
{
  "ok": true
}
```

### `GET /api/messages/recent`

Query params:
- `limit` optional, default `100`, max `500`
- `offset` optional, default `0`

Response shape:

```json
{
  "data": [
    {
      "guid": "string",
      "text": "string or null",
      "subject": "string or null",
      "service": "string or null",
      "dateCreated": 1712345678901,
      "dateRead": 1712345679999,
      "dateDelivered": 1712345679555,
      "isFromMe": true,
      "isRead": true,
      "isDelivered": true,
      "handle": {
        "id": "string",
        "service": "string or null"
      },
      "cacheHasAttachments": false
    }
  ],
  "meta": {
    "limit": 100,
    "offset": 0
  }
}
```

### `GET /api/chats`

Query params:
- `limit` optional, default `100`, max `500`
- `offset` optional, default `0`
- `withArchived` optional, default `false`

Response shape:

```json
{
  "data": [
    {
      "guid": "string",
      "chatIdentifier": "string or null",
      "serviceName": "iMessage",
      "displayName": "string or null",
      "isArchived": false
    }
  ],
  "meta": {
    "limit": 100,
    "offset": 0
  }
}
```

### `GET /api/chats/{guid}/messages`

Query params:
- `limit` optional, default `100`, max `500`
- `offset` optional, default `0`

Behavior:
- Return `404` if the chat GUID does not exist.

Response shape:
- Same message JSON model as `GET /api/messages/recent`

## Go Structs

### Config

```go
type Config struct {
    DBPath   string
    HTTPAddr string
}
```

### API models

```go
type HealthResponse struct {
    OK bool `json:"ok"`
}

type HandleJSON struct {
    ID      string  `json:"id"`
    Service *string `json:"service"`
}

type ChatJSON struct {
    GUID           string  `json:"guid"`
    ChatIdentifier *string `json:"chatIdentifier"`
    ServiceName    *string `json:"serviceName"`
    DisplayName    *string `json:"displayName"`
    IsArchived     bool    `json:"isArchived"`
}

type MessageJSON struct {
    GUID                string      `json:"guid"`
    Text                *string     `json:"text"`
    Subject             *string     `json:"subject"`
    Service             *string     `json:"service"`
    DateCreated         *int64      `json:"dateCreated"`
    DateRead            *int64      `json:"dateRead"`
    DateDelivered       *int64      `json:"dateDelivered"`
    IsFromMe            bool        `json:"isFromMe"`
    IsRead              bool        `json:"isRead"`
    IsDelivered         bool        `json:"isDelivered"`
    Handle              *HandleJSON `json:"handle"`
    CacheHasAttachments bool        `json:"cacheHasAttachments"`
}

type ListMeta struct {
    Limit  int `json:"limit"`
    Offset int `json:"offset"`
}

type ChatListResponse struct {
    Data []ChatJSON `json:"data"`
    Meta ListMeta   `json:"meta"`
}

type MessageListResponse struct {
    Data []MessageJSON `json:"data"`
    Meta ListMeta      `json:"meta"`
}
```

### DB row structs

```go
type ChatRow struct {
    GUID           string
    ChatIdentifier *string
    ServiceName    *string
    DisplayName    *string
    IsArchived     bool
}

type MessageRow struct {
    GUID                string
    Text                *string
    Subject             *string
    Service             *string
    DateRaw             int64
    DateReadRaw         *int64
    DateDeliveredRaw    *int64
    IsFromMe            bool
    IsRead              bool
    IsDelivered         bool
    HandleValue         *string
    HandleService       *string
    CacheHasAttachments bool
}
```

## SQL Queries

### Health check query

Used only if needed for deeper DB verification:

```sql
SELECT 1;
```

### Recent messages

```sql
SELECT
  m.guid,
  m.text,
  m.subject,
  m.service,
  m.date,
  m.date_read,
  m.date_delivered,
  m.is_from_me,
  m.is_read,
  m.is_delivered,
  m.cache_has_attachments,
  h.id AS handle_id_value,
  h.service AS handle_service
FROM message AS m
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
ORDER BY m.date DESC
LIMIT ? OFFSET ?;
```

### Chat list

When `withArchived=false`:

```sql
SELECT
  c.guid,
  c.chat_identifier,
  c.service_name,
  c.display_name,
  c.is_archived
FROM chat AS c
WHERE c.is_archived = 0
ORDER BY c.ROWID DESC
LIMIT ? OFFSET ?;
```

When `withArchived=true`:

```sql
SELECT
  c.guid,
  c.chat_identifier,
  c.service_name,
  c.display_name,
  c.is_archived
FROM chat AS c
ORDER BY c.ROWID DESC
LIMIT ? OFFSET ?;
```

### Chat existence check

```sql
SELECT 1
FROM chat
WHERE guid = ?
LIMIT 1;
```

### Messages in one chat

```sql
SELECT
  m.guid,
  m.text,
  m.subject,
  m.service,
  m.date,
  m.date_read,
  m.date_delivered,
  m.is_from_me,
  m.is_read,
  m.is_delivered,
  m.cache_has_attachments,
  h.id AS handle_id_value,
  h.service AS handle_service
FROM message AS m
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
WHERE c.guid = ?
ORDER BY m.date DESC
LIMIT ? OFFSET ?;
```

## Timestamp Conversion Helper

Apple Messages timestamps are relative to `2001-01-01 00:00:00 UTC`.

For modern `chat.db` files, BlueBubbles treats stored values as microseconds since Apple epoch.

```go
package timeutil

import "time"

var appleEpoch = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)

func AppleMicrosToTime(raw int64) *time.Time {
    if raw == 0 {
        return nil
    }

    t := appleEpoch.Add(time.Duration(raw) * time.Microsecond)
    return &t
}

func AppleMicrosToUnixMilli(raw int64) *int64 {
    t := AppleMicrosToTime(raw)
    if t == nil {
        return nil
    }

    ms := t.UnixMilli()
    return &ms
}
```

Notes:
- Return `nil` for `0` timestamps.
- Keep the helper isolated so older macOS formats can be added later without touching handlers.

## Handler Rules

- Responses must be JSON.
- `Content-Type` must be `application/json`.
- All list endpoints must accept `limit` and `offset`.
- Invalid `limit` or `offset` returns `400`.
- Unknown chat GUID returns `404`.
- DB read failures return `500`.
- Do not expose raw SQL errors to clients.

## Error Handling Rules

Error envelope:

```json
{
  "error": {
    "code": "bad_request",
    "message": "limit must be between 1 and 500"
  }
}
```

Codes:
- `bad_request`
- `not_found`
- `internal_error`

Rules:
- Parse and validate query params before touching the DB.
- Clamp nothing silently; reject invalid values.
- Log full internal errors server-side.
- Return short, stable client-facing messages.

## Suggested Defaults

- HTTP listen address: `127.0.0.1:3000`
- `limit` default: `100`
- `limit` max: `500`
- `offset` default: `0`

## Manual Test Commands

### Verify the DB exists

```bash
ls -l ~/Library/Messages/chat.db
```

### Check raw chat count with sqlite3

```bash
sqlite3 ~/Library/Messages/chat.db 'SELECT COUNT(*) FROM chat;'
```

### Check raw message count with sqlite3

```bash
sqlite3 ~/Library/Messages/chat.db 'SELECT COUNT(*) FROM message;'
```

### Inspect a few chats with sqlite3

```bash
sqlite3 ~/Library/Messages/chat.db 'SELECT guid, chat_identifier, service_name, is_archived FROM chat ORDER BY ROWID DESC LIMIT 5;'
```

### Inspect a few messages with sqlite3

```bash
sqlite3 ~/Library/Messages/chat.db 'SELECT guid, text, service, date, is_from_me FROM message ORDER BY date DESC LIMIT 5;'
```

### Health endpoint

```bash
curl -s http://127.0.0.1:3000/api/health
```

### Recent messages endpoint

```bash
curl -s 'http://127.0.0.1:3000/api/messages/recent?limit=5&offset=0'
```

### Chats endpoint

```bash
curl -s 'http://127.0.0.1:3000/api/chats?limit=5&offset=0'
```

### Chats endpoint including archived

```bash
curl -s 'http://127.0.0.1:3000/api/chats?limit=5&offset=0&withArchived=true'
```

### Messages for one chat

Replace `<guid>` with a real chat GUID from sqlite output.

```bash
curl -s "http://127.0.0.1:3000/api/chats/<guid>/messages?limit=10&offset=0"
```

### Invalid limit

```bash
curl -i 'http://127.0.0.1:3000/api/messages/recent?limit=0'
```

### Unknown chat

```bash
curl -i 'http://127.0.0.1:3000/api/chats/not-a-real-guid/messages'
```

## Completion Criteria

- Mica starts successfully on macOS with local `chat.db` present.
- Mica opens `~/Library/Messages/chat.db` in read-only mode.
- `GET /api/health` returns `200` with `{ "ok": true }`.
- `GET /api/messages/recent` returns recent messages ordered by descending `message.date`.
- `GET /api/chats` returns chats ordered by descending `chat.ROWID`.
- `GET /api/chats/{guid}/messages` returns messages for exactly that chat GUID.
- Apple timestamps are converted to Unix milliseconds correctly in JSON responses.
- `isFromMe`, `isRead`, `isDelivered`, `service`, and `cacheHasAttachments` are populated from `chat.db`.
- Invalid parameters return `400`.
- Missing chat GUID returns `404`.
- DB failures return `500`.
- No writes are made to the Messages database.
