# C6 Sync/Realtimes Changes

Date: 2026-06-08

Source of truth: `docs/c6-bluebubbles-sync-audit.md`.

## Current MicaGo Gaps Found

- Startup sync existed, but it ran before serving HTTP. Normal operation still depended too much on the periodic loop or manual refresh when a client connected later.
- Periodic sync existed with a default 5 second interval and a mutex, so overlap was avoided.
- New-message sync advanced `relaydb.last_message_rowid`, which is fine for newly inserted high-rowid messages but cannot see old-row mutable changes by itself.
- C5 update pass covered delivered/read/edited/retracted/send-error fields for tracked relay rows, but it only runs with sync and depends on the configured lookback.
- Send path ran one sync after AppleScript, then polled for only 15 seconds. A confirmation timeout became a hard failure and removed the pending record.
- Later real outgoing rows could reconcile against local failed rows on the client, but the server no longer had the pending send to emit a late `send:match`.
- Flutter listened to WS events and routed by `chatGuid`, but it did not ask the server for catch-up on WS reconnect, app resume, or entering a stale thread.
- Chat list refresh was event-driven with a small debounce, but reconnect/resume without events could leave it stale.

## Implemented Changes

Automatic sync triggers:

- Added authenticated `POST /api/sync/now`.
- `AppController` calls catch-up sync after pairing/profile activation, WS connected/reconnected, app resume, chat list start, and thread start.
- Catch-up is throttled and ignores overlapping calls.
- Existing manual sync behavior remains available.

Send reconciliation v2:

- Server pending sends now support `sent_unconfirmed`.
- Confirmation wait is 20 seconds and runs repeated short sync attempts during the wait.
- If AppleScript succeeds but no DB match appears, server returns HTTP 202 with `state: sent_unconfirmed`, emits recoverable `send:error`, and keeps the pending record for late reconciliation.
- Periodic/manual/send-triggered sync now late-matches newly synced outgoing rows against pending/unconfirmed sends and emits `send:match` with `late: true`.
- Actual AppleScript failure and explicit DB send error still mark failed.
- Flutter adds `LocalSendState.sending` and `LocalSendState.sentUnconfirmed`.
- Flutter maps HTTP 202 / recoverable `send:error` to `sentUnconfirmed`, not failed.
- Later `send:match`, `message:new`, or `message:update` still replaces the local row and removes duplicates.

Foreground realtime:

- Existing `message:new`, `message:update`, and `message:unsend` routing by `chatGuid` remains.
- Client catch-up on WS connection and resume reduces reliance on manual sync.
- Thread entry runs a throttled catch-up before/alongside loading.
- Chat list entry runs a throttled catch-up and still refreshes on `message:new/update/unsend`.

Debug diagnostics:

- `GET /api/server/status` now includes `sync.diagnostics`.
- Diagnostics include last sync start/completion time, duration, inserted/synced counts, update-pass counts, unsent count, scanned rowid, pending sends, late matched sends, and last emitted event type/chat guid.
- Flutter `WebSocketClient` tracks `lastEventAt`; `AppController` tracks `lastCatchUpSyncAt`.

Attachments/link/reply findings:

- BlueBubbles converts TIFF/HEIC server-side when conversion is requested and also converts TIFF/HEIC to PNG client-side for mobile previews.
- MicaGo keeps the C5 safe TIFF placeholder for now: TIFF is not passed to Android `Image.memory`; users see “TIFF image” / “Preview not available yet” with file info.
- Recommended future endpoint remains `GET /api/attachments/{guid}/preview`, returning a converted PNG/JPEG preview while preserving original download.
- BlueBubbles uses Apple `payloadData`/URL metadata for link previews and `threadOriginatorGuid` / `threadOriginatorPart` for replies. MicaGo currently exposes several fields but does not render full link/reply UI yet.
- BlueBubbles uses `messageSummaryInfo` edited/retracted parts for partial edits/unsends. MicaGo currently renders whole-message edited/retracted state and should preserve richer fields for future partial rendering.

## Remaining Gaps

- No DB file watcher/WAL mtime trigger has been added yet; MicaGo still uses periodic sync plus explicit catch-up calls.
- Startup sync still runs before HTTP starts serving; a future refinement can move or repeat it after listener readiness.
- Late reconciliation is in-memory, so pending send history is lost on server restart.
- No heavy TIFF preview conversion endpoint was implemented in C6.
- No push/Firebase work was implemented.
- No Mategram/UI rewrite was performed.
- Cloudflare/tunnel logic was not changed.

## Manual Test Flow

1. Start server and do not press manual sync.
2. Open Android; verify chat list loads and `POST /api/sync/now` catch-up runs.
3. Send from Android; message appears as sending, then confirmed or sent_unconfirmed.
4. If confirmation is delayed, wait for periodic sync; late real outgoing row should emit `send:match` and replace the local row.
5. Send from iPhone/Mac; Android foreground should receive within sync interval or next catch-up.
6. Edit a message; update pass should emit `message:update`.
7. Unsend a message; update pass should emit `message:unsend` and hide old content.
8. Switch chats; chat list refreshes on message events.
9. Kill/reopen Android; app resume/WS connect should catch up.
10. Reconnect WS; catch-up should run once within throttle.

