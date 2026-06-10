# C9 Sync, Storage, And Endpoint Strategy

Date: 2026-06-09

## Implemented

Server sync:

- Existing periodic sync remains.
- Added chat.db/WAL mtime trigger loop with no overlapping syncs; it calls the same sync wrapper as manual/periodic/send-triggered sync.
- Update pass now runs after DB mtime-triggered sync, so delivered/read/edited/retracted changes are checked sooner.
- Diagnostics now include last trigger reason, chat.db mtime, WAL mtime, last sync error, counts, pending sends, late matches, and last emitted event.

Send reconciliation:

- Actual AppleScript/send command failure remains failed.
- AppleScript success + DB confirmation timeout returns HTTP 202 and must be treated as `sentUnconfirmed`.
- Client now handles HTTP 202 in `sendText`, not in chat loading.
- Pending/sentUnconfirmed rows are persisted locally and can be replaced by later `send:match` or matching `message:new/update`.

Local storage:

- Added Flutter `sqflite` cache.
- Tables:
  - `chats`
  - `messages`
  - `metadata`
- Cached chats/messages show immediately on cold start/offline launch.
- REST fetches write through to cache.
- WS `message:new/update/unsend` and `send:match/send:error` patch cache.
- Pending outgoing rows persist across restart.

Attachment previews:

- Added `previewUrl` to attachment JSON when conversion is needed.
- Added `GET /api/attachments/{guid}/preview`.
- TIFF/HEIC/HEIF previews use macOS `sips` to PNG and cache in the temp directory.
- Original attachment download remains unchanged.
- Flutter inline and gallery image rendering prefer preview bytes when available.

Filtering:

- Default chat list hides chats with no renderable messages.
- `GET /api/chats?debug=true` still reveals unsupported/noise-only chats.
- `GET /api/debug/recent-messages` remains raw/debug-safe and is not filtered.
- Flutter local cache supports local hidden and always-visible flags.

Endpoint strategy:

- `ConnectionProfile` now stores:
  - mode: `auto`, `lan_only`, `public_only`, `lan_first`
  - LAN base/ws URL
  - Public base/ws URL
- `AppController` builds the REST client from the effective endpoint.
- `GET /api/server/urls` candidates are persisted after discovery.
- QR pairing remains backward-compatible.

## Manual Acceptance Notes

- A cold-start should show cached chats immediately before catch-up finishes.
- If server is unreachable, cached data remains visible.
- TIFF screenshot behavior should be either converted preview or stable placeholder; it should not attempt broken Android TIFF decode.
- Empty/noise chats are hidden by default but visible through debug mode/Message Inspector.
- LAN-first fallback model is present, but user-facing preferred LAN IP selection still needs UI work.

## Remaining Gaps

- Complete per-chat initial backfill is still design-only; selected thread fetch already requests that thread directly.
- DB mtime watcher is polling-based rather than native fsnotify; this avoids a dependency but is less elegant than BlueBubbles' watcher.
- Local DB is not yet the only source of truth for every UI surface; controllers bridge cache plus network.
- Contact hide/always-visible settings are implemented at cache API level but need full settings UI.
- Full link preview, partial edit history, and reply target fetch parity remain future work.

