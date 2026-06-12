# C13 Sync Scope and Backfill

Normal API remains relay-backed:

`chat.db -> store.Queries sync reader -> relay.db -> normal REST/WebSocket`

Direct `chat.db` reads are used only for sync input and Message Inspector/debug. The deleted duplicate normal chatdb serving path was not reintroduced.

Server-owned settings live in relaydb `sync_state` key `sync_settings_v1` and are exposed by:

- `GET /api/sync/settings`
- `PUT /api/sync/settings`
- `POST /api/sync/now`

Defaults:

- Backfill mode: `hybrid`
- Recent messages per chat: `100`
- iMessage: on
- SMS/plain: on
- RCS: on when service is exactly `RCS`
- unknown service: off for normal API, visible in debug
- debug/noise in normal client: off

Backfill behavior:

1. Fetch all chats from `chat`.
2. Global mode fetches latest rows globally.
3. Per-chat mode fetches latest N rows per chat via `chat_message_join`.
4. Hybrid does both and de-duplicates by GUID.
5. Rows are classified and upserted into relaydb.
6. Normal API filters by service scope and `is_debug_only`.
7. Debug APIs still show excluded/raw rows.
8. Attachments are metadata-only during sync; bytes are served only by attachment endpoints.

Diagnostics now include mode, per-chat limit, rows scanned, renderable rows, hidden/debug rows, duration, errors, WAL/SHM mtimes, and trigger counts.
