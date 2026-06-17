# C21 — BlueBubbles sync / Firebase audit (Part B, output only)

Audit before any sync rewrite or Firebase work. **No implementation in this
pass.** Files read are cited; comparison and a minimal plan follow.

## 1. How BlueBubbles sync works

Server (`Ref/bluebubbles server/packages/server`):
- `lib/MultiFileWatcher.ts` — `fs.watch` on `chat.db`, `chat.db-wal`, `chat.db-shm`;
  emits a `change` event.
- `databases/imessage/listeners/IMessageListener.ts` — on `change`, a
  **500 ms debounce** (`@DebounceSubsequentWithWait`) then `handleChangeEvent`
  polls messages **with a 30 s lookback** (`afterTime = lastCheck - 30000`,
  capped at 24 h), advances `lastCheck`, and trims caches. An initial seed poll
  runs at startup.
- `databases/imessage/pollers/MessagePoller.ts` + `eventCache/` — results sorted
  ascending; **dedup via an EventCache** (`cache.events.find(id)` → skip; else
  `add`). Each new row is emitted as a socket event (`new-message`, etc.).
- Socket.IO pushes events to connected apps; HTTP endpoints serve history /
  incremental fetches.

App (`Ref/bluebubbles-app-master/lib`):
- `services/network/socket_service.dart` — Socket.IO client; on connect/reconnect
  (5 s retry timer + connectivity listener) runs `NetworkTasks.onConnect`.
- `helpers/network/network_tasks.dart onConnect` → `sync.startIncrementalSync()`
  (gated on lifecycle: only when resumed / was-paused/hidden).
- `services/backend/sync/incremental_sync_manager.dart` — tracks
  `lastSyncedRowId` + `lastSyncedTimestamp`, fetches messages **after** that
  marker, saves new markers. Dedup by ROWID/GUID in the local DB.
- `services/backend/lifecycle/lifecycle_service.dart` — tracks
  paused/hidden/resumed to decide when to incremental-sync.

So: **realtime socket first → incremental fetch on (re)connect by rowid/timestamp
marker → DB/EventCache dedup → 30 s watcher lookback for missed rows.**

## 2. How BlueBubbles Firebase/FCM fits into sync

- Server `services/fcmService/index.ts` — `FCMService.sendNotification(...)`
  (firebase-admin multicast). FCM is used to (a) **wake a backgrounded/killed
  app** with a new-message data push so it reconnects and incremental-syncs, and
  (b) broadcast a **server-URL change** (`emitMessage(NEW_SERVER, ...)` +
  `fcm.setServerUrl`) so apps follow the Mac's changing address.
- App `services/network/firebase/cloud_messaging_service.dart` — `registerDevice`
  registers the FCM token; the push is a thin "something changed, fetch" signal —
  **the actual message data still comes over socket/HTTP**, not in the push.

FCM is a **wake/awareness channel layered on top of socket sync**, not a separate
data path.

## 3. What MicaGo already has

- **Watcher + sync**: `runDBMtimeSyncLoop` (WAL/SHM/chat.db mtime poll, 750 ms) +
  coalescing `app.SyncEngine` + **bounded date-lookback union** (C11) — the
  direct analogue of BB's watcher + 30 s lookback.
- **Realtime**: WS `message:new/update/unsend` from `broadcastSyncResult`;
  **relay dedup by `ON CONFLICT(guid)`** (analogue of EventCache); renderable-only
  broadcast (C12).
- **Reconnect/catch-up/fallback**: `RefreshCoordinator` (C20) — reconnect backoff,
  fallback poll when WS down, catch-up on reconnect, `onResume()` lightweight
  refresh; `AppController.catchUp` triggers a server `syncNow`. Client tracks
  `lastAppliedEventCursor` diagnostics.
- **Send reconciliation**: optimistic text row reconciled by `send:match`
  (text+time), GUID dedup; attachments deliberately bubble-free (no duplicates).
- **Device registration** (C19) with `pushProvider/pushToken/pushEnabled` fields.
- **Server FCM is largely BUILT (C12)**: `internal/notify` has a real
  `FCMProvider` (HTTP v1 + service-account OAuth), `dispatchNotifications` already
  fires `DispatchNewMessages` on each sync's `NotificationEvents`, token storage,
  dead-token pruning. The Companion has notification config UI.

## 4. What MicaGo is missing (vs BlueBubbles)

1. **Client-side FCM is absent.** The Flutter app has no `firebase_messaging`,
   never registers an FCM token (devices register with `pushProvider: none`), and
   has **no background/killed wake handler**. So the server's push dispatch has no
   client to wake.
2. **No persistent client sync marker / delta fetch.** MicaGo's catch-up triggers
   a server-side `syncNow` (re-syncs the relay) rather than the client fetching
   "messages after lastSeenRowId/timestamp." If a `message:new` WS event was
   missed but the relay already has the row (so no new broadcast), the open
   thread may not patch until a manual reload. BB's marker-based incremental fetch
   is more precise.
3. **Background behavior.** Flutter WS closes when backgrounded; new messages
   reach the relay but the phone isn't notified until the next foreground/resume
   catch-up. No push = a killed app gets nothing until reopened.

## 5. Why occasional desync can still happen

- **Backgrounded/killed app, no push:** the relay keeps syncing chat.db, but the
  phone's WS is dead and there's no FCM wake → messages only appear on next
  manual foreground. This is the most likely "occasional miss."
- **Missed WS event without a thread reload:** if a `message:new` is dropped
  (transient socket hiccup) and the relay already stored the row, the next
  `catchUp` re-syncs the relay (no-op, already there) and emits no new event, so
  the active thread isn't patched until a reload. A client cursor/delta fetch
  would close this.
- **Watcher window edge cases:** mtime granularity / WAL-checkpoint timing can
  delay detection to the next date-lookback union — bounded, but a brief gap.
- **Relay-cache staleness for the open chat:** the thread trusts pushed rows +
  periodic catch-up; without a delta-by-cursor, a narrow race can leave the
  visible thread behind the relay until refresh.

## 6. Minimal plan to improve MicaGo sync (no Firebase)

(Smallest changes; in priority order. **Not implemented here.**)
1. **Client cursor delta fetch on reconnect/resume.** Persist a per-chat (or
   global) `lastSeenRowId`/`lastSeenAt`; on catch-up, fetch `GET /api/chats/
   {guid}/messages?since=…` (add a `since` param server-side) and patch the
   thread, instead of relying only on `syncNow` + WS. Closes the "missed event +
   already-synced relay" gap.
2. **Active-thread reconcile on reconnect.** When the WS reconnects while a thread
   is open, force one targeted `loadDelta` for that chat (not a full reload).
3. **Slightly widen / verify the date-lookback** to match BB's 30 s explicit
   lookback on each change tick (MicaGo's union is bounded but tune the window).
4. **Surface a "last synced" marker** in the thread so staleness is visible
   (reuses C20 status feedback).

## 7. Minimal plan to add Firebase later (server already mostly done)

Server is built; the work is **client-side + wiring**:
1. Flutter: add `firebase_messaging` + `firebase_core`; on connect, get the FCM
   token and register it via the existing `/api/devices/register`
   (`pushProvider: fcm`, `pushToken: …`) — the registration plumbing already
   exists (C19).
2. Flutter: a background/terminated message handler that, on a new-message data
   push, triggers `RefreshCoordinator`/`catchUp` (and a local notification).
3. Server: confirm `dispatchNotifications` sends a **data** push (not just
   notification) carrying enough to route (chatGuid) so the app can targeted-fetch.
4. Provide the Firebase project config (the server already supports a service
   account; the client needs `google-services.json` / `GoogleService-Info.plist`).
5. Gate it behind the existing notifications settings; keep WS as the primary
   path (FCM is wake-only, exactly like BB).

## 8. Files that would need changes

Sync improvement (no Firebase):
- `MicaGoServer/.../internal/httpapi/handlers.go` + `router.go` — add a `since`
  param to `GetChatMessages` (delta).
- `MicaGoServer/.../internal/relaydb/query.go` — `ListChatMessages` since-filter.
- `MicaGoFlutterClient/lib/core/app_controller.dart` +
  `core/network/refresh_coordinator.dart` — cursor persistence + delta fetch on
  reconnect/resume.
- `MicaGoFlutterClient/lib/features/chats/thread_controller.dart` — apply delta;
  cursor advance.

Firebase (later):
- `MicaGoFlutterClient/pubspec.yaml` — `firebase_core`, `firebase_messaging`.
- new `MicaGoFlutterClient/lib/core/push/` — token registration + background
  handler.
- `MicaGoFlutterClient/android/app` + `ios/Runner` — Firebase config files,
  background message entry.
- `MicaGoServer/.../internal/notify/fcm.go` — confirm data-payload shape; minor.

## 9. Risks and validation tests

Risks:
- **Battery/abuse**: background fetch on every push — debounce (RefreshCoordinator
  already coalesces).
- **Dedup**: a push-triggered fetch + a later WS event must not double-insert —
  relay `ON CONFLICT(guid)` + client GUID dedup already cover this; verify.
- **Firebase dependency weight + config**: another native dep + per-platform
  config; keep WS primary so the app fully works without FCM.
- **Delta correctness**: a `since` filter must be inclusive/exclusive-correct to
  avoid missing the boundary row.

Validation tests (when implemented):
- Server `since` filter returns exactly rows after the cursor (boundary cases).
- Client delta fetch patches the open thread with no duplicate bubbles.
- Reconnect while a thread is open pulls the missed message.
- (Firebase) token registers with `pushProvider: fcm`; a data push triggers a
  single catch-up; backgrounded app shows the message on next push; killed app
  wakes and fetches.
- No regression in existing WS realtime / reconcile / dedup tests.

## Recommendation

MicaGo's sync core already mirrors BlueBubbles (watcher + lookback + WS + dedup +
reconnect/catch-up). The remaining gaps are **(a) a client cursor/delta fetch**
(small, no new deps — do this first; it removes most "occasional miss" cases) and
**(b) client-side FCM wake** for backgrounded/killed apps (the server half is
already built). Do the cursor delta first; add Firebase only if background
delivery is still required after that.
