# C7 — Client architecture rewrite + renderable timeline

## References inspected
- BlueBubbles client: `lib/database/global/chat_messages.dart` (in-memory keyed
  store), `lib/services/ui/message/messages_service.dart`,
  `lib/services/backend/action_handler.dart` (new/updated reconciliation,
  `replaceMessage(tempGuid, …)`), `lib/services/network/socket_service.dart`.
- Mategram: `mategram/domain/.../ChatList*.kt`, `MessageSourceChatList.kt`
  (delta-updated chat list) + Compose lazy list patterns.
- Full audit: `docs/c7-client-store-architecture-audit.md`.

## New client store architecture
- **`store/message_collection.dart`** — pure, per-chat source of truth. Server
  messages keyed by `guid`; optimistic sends keyed by `tempId`. Patched by REST
  pages (`replaceServerPage`/`mergeOlder`) and WS events
  (`upsertServer`/`applyUpdate`/`applyUnsend`) — never a full rebuild. Dedupe by
  guid; optimistic rows reconcile by guid/tempId/(text+time) via
  `shouldReconcileLocalWithServer`. `ordered` is a lazily-rebuilt sorted view.
- **`ThreadController`** now holds a `MessageCollection` and only translates
  REST/WS into store mutations + `notifyListeners()`. The **PendingSendStore** is
  the collection's `_pending` map (optimistic rows live there until reconciled).
- **`ChatStore`**: chat summaries come from `ChatListController` over
  `GET /api/chats`; rows carry server-computed renderable summary fields, so the
  list is store-driven and reload-on-event stays debounced + silent.

## Renderable vs raw timeline policy (server)
- Each message is classified once (`store.ClassifyMessageJSON`) into a
  `semanticKind` + `renderRecommendation` + `isDebugOnly`.
- `GET /api/chats/{guid}/messages` returns the **renderable** timeline by default
  (drops `isDebugOnly` rows); `?debug=true` returns the raw timeline.
- `GET /api/chats` hides chats with no renderable content by default and exposes
  `hasRenderableMessages`, `latestRenderableAt`, `latestRenderablePreview`,
  `unsupportedOnly`, `hiddenReason`; `?debug=true` reveals hidden chats. The
  Message Inspector / `GET /api/debug/recent-messages` still expose everything.
- `is_debug_only` is persisted on relay messages at sync time, so the chat-list
  aggregate is a cheap SQL `COUNT(... is_debug_only=0)`.

## Event flow
`WebSocket → ThreadController._onWsEvent → MessageCollection`:
- `message:new` / `message:update` (matching `chatGuid`) → `upsertServer` (patch
  by guid; reconcile a matching optimistic row). Mismatched/legacy events →
  debounced silent reload.
- `message:unsend` → `applyUnsend(guid)` (clears text/attachments, marks
  retracted). Unknown guid → reload.
- `send:match` → `confirmPending(tempId, server)`. `send:error` → `sentUnconfirmed`
  (recoverable) or `failed`.

## Send reconciliation flow
Local states: `sending → sentUnconfirmed → confirmed` (+ derived
`delivered`/`read` from server dates) or `→ failed`.
- AppleScript ok + DB confirmation timeout (`send_confirmation_timeout`) ⇒
  **sentUnconfirmed**, not failed.
- A later outgoing server row matching chat/text/time (or tempGuid) **replaces**
  the optimistic row — never both a pending and a confirmed bubble.
- `delivered`/`read` updates patch the same guid; `deliveryStateFor` derives the
  label. Real failures stay `failed` and are retryable (`removePending` returns
  the text). Tested in `test/message_collection_test.dart`.

## Chat filtering rules
- Default: server returns only chats with renderable content.
- Setting **"Show debug-only chats"** (`MessageDisplayPrefs.showDebugChats`)
  sends `?debug=true` and reveals noise-only chats.
- Search filters the loaded summaries in memory (title/contact/identifier/
  service/preview). Timestamp/preview come from real server data
  (`latestRenderableAt`/`latestRenderablePreview`); no fabricated unread.

## Performance notes (thread)
- **`store/thread_presentation.dart`** precomputes the whole `ThreadViewItem`
  list once per change: classification, sender label (contact lookup), reply
  preview, reaction merge, effect label, delivery visibility, date separators,
  body text. The `ListView.builder` itemBuilder only renders a precomputed item
  — no classification, contact lookup, JSON, or attachment-kind detection in the
  hot path.
- Stable `ValueKey(item.key)` from guid/tempId; media bubbles wrapped in
  `RepaintBoundary`. Inline images are bounded (`maxHeight 260`, `cacheWidth`)
  so a large photo never decodes full-size while scrolling; TIFF keeps its
  placeholder (no `Image.memory`); full-size load is deferred to the media
  viewer. Tested in `test/thread_presentation_test.dart`.

## Auto-sync
Catch-up (`AppController.catchUp`, throttled 4s) fires on: launch (WS connect),
WS reconnect, app resume, entering a thread, and chat-list open. The server runs
an initial sync at startup + periodic sync; `POST /api/sync/now` remains as the
manual/backup action. Pending sends reconcile against later sync rows.

## Remaining gaps
- Chat summaries still come from a (debounced, silent) reload on events rather
  than an incremental delta patch — acceptable because the renderable preview/
  ordering are server-computed; a future delta API could remove the reload.
- `previewUrl` model field is reserved; the server preview/thumbnail endpoint
  (e.g. TIFF/HEIC → JPEG) is documented but not implemented.
- chatGuid-less legacy WS events still fall back to a debounced reload.
- No persistent local DB (in-memory over REST+WS), so cold start re-fetches.
