# C10 — Local database as the client pipeline

The Android client uses a local sqflite DB (`LocalCacheStore`) as the source of
truth. REST fetches and WebSocket events write to the DB; the UI reads cached
data immediately, then patches arrive. The in-memory `MessageCollection`
(per-thread) is a working cache layered on top.

## Tables (`micago_client_cache.db`)
- **chats** — `guid` PK, `json` (full `ChatSummary`), `latest_renderable_at`
  (sort key), `hidden` / `always_visible` (per-chat display rules), `updated_at`.
- **messages** — `key` PK (`guid:<g>` or `temp:<t>`), `guid`, `temp_id`,
  `chat_guid`, `json`, `local_state` (sending/sentUnconfirmed/confirmed/failed),
  `date_created`, `updated_at`; indexed by (chat,date), guid, temp_id.
- **metadata** — key/value for sync bookmarks + misc.
- Connection profile + token live in `SecureStore` (token is Keystore-backed);
  endpoint candidates + mode live on the persisted `ConnectionProfile`.

## Pipeline behavior
1. **Cold start** — `ChatListController` reads `cache.listChats()` and shows
   cached chats *before* the network returns; a background `getChats()` then
   `cache.upsertChats()` patches the list. Threads read `cache.listMessages()`
   first, then `getMessages()` → `cache.replaceServerPage()`.
2. **Sending** — an optimistic message is written immediately
   (`cache.addPending`), then `setPendingState`
   (sending→sentUnconfirmed/failed), then `confirmPending` swaps the temp row
   for the server row. State survives restart (persisted `local_state`).
3. **Incoming** — `message:new` → `cache.upsertMessage`; the open thread's
   `MessageCollection` patches and the UI updates.
4. **Updates** — `message:update` patches the row by guid (delivered/read/edit).
5. **Unsend** — `message:unsend` → `cache.applyUnsend` clears text/attachments
   and marks the row retracted.

## Initial per-chat backfill (Part F)
`AppController.backfill(profile, perChat, onProgress)`:
- `syncNow()` (catch-up) → `getChats()` → `cache.upsertChats`,
- for each visible chat: `getMessages(guid, limit: perChat)` →
  `cache.replaceServerPage`, accumulating `BackfillDiagnostics`
  (chatsScanned / messagesFetched / renderableRows / hiddenOrDebugRows /
  failedChats). `perChat` is the **Recent messages per chat** setting
  (50/100/200, default 100). Never blocks on huge history; reports progress.

## Send reconciliation (Part G)
States: `sending → sentUnconfirmed → confirmed` (+ derived delivered/read) or
`failed`. AppleScript success + DB confirmation timeout
(`send_confirmation_timeout`) ⇒ `sentUnconfirmed`, not failed. A later matching
outgoing server row reconciles the pending row (guid/tempId/text+time);
delivered/read patch the same guid; no duplicate bubbles; failed rows stay
retryable. Logic + every case are unit-tested in
`test/message_collection_test.dart`.

## Tests
- `test/message_collection_test.dart` (event + reconciliation cases).
- `test/local_cache_store_test.dart` (if present) / cold-start + persistence
  behavior is exercised via the controller paths.

## Remaining gaps
- The DB is a cache (no migrations beyond v1); a schema bump would clear it.
- Pending sends persist but auto-retry on reconnect is manual (tap-to-retry).
