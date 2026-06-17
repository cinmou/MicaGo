# C20 — Refresh/realtime reliability + SMS sendability setting

Improves chat freshness and makes SMS sending a server-authoritative setting.
BlueBubbles was referenced only for the refresh *model*, not UI.

## 1. Refresh / realtime model

Three-tier strategy (BlueBubbles-like): **realtime first → targeted refresh
second → catch-up/poll fallback**.

- **Realtime (unchanged, in the controllers).** `ThreadController` and
  `ChatListController` each subscribe to the WS event stream and *patch in
  place* — `message:new`/`update`/`unsend` upsert/patch the affected row by
  GUID; a missing-chatGuid event falls back to a short debounced reload
  (400 ms thread / 150 ms list). No full reload when a patch suffices.
- **Active-thread targeting.** A `message:*` event only mutates the open thread
  when `msg.chatGuid == chatGuid`; otherwise the chat-list controller updates
  the summary. Send reconciliation replaces the optimistic row by `send:match`
  (text) and dedupes by GUID, so no duplicate bubble appears after a refresh.
- **Fallback tier (C20, new) — `RefreshCoordinator`.** One object
  (`lib/core/network/refresh_coordinator.dart`, owned by `AppController`) owns
  *all* reconnect scheduling and the conservative poll:
  - On WS `disconnected` **or** `failed` (the old code only reacted to `failed`,
    and only in lanFirst/auto) it schedules a reconnect with capped backoff
    (1→2→5→10→15 s) and starts a `catchUp` poll (20 s) so missed messages still
    arrive while the socket is down.
  - On WS `connected` it cancels the reconnect, stops the poll, resets backoff,
    and `AppController` runs a catch-up sync (`_handleWebSocketReconnect`).
  - `onResume()` (app foreground) reconnects if needed and does a light
    catch-up — one entry point, replacing the home-shell's ad-hoc
    connect+catchUp.
  - Reconnect routes through `selectReachableCandidate`, which health-checks and
    re-selects the endpoint, so LAN↔Public fallback is handled by the same path.
- **After send.** Text/attachment send already triggers a server sync; the new
  row arrives via the same realtime/catch-up path (attachments deliberately do
  not add an optimistic bubble — see C19 — so they can't duplicate).

Deleted/consolidated: the failed-only inline reconnect in
`AppController._onWebSocketStatusChanged`, and the home-shell's manual
`connectWebSocket()+catchUp()` on resume. There is now one fallback-refresh
owner.

## 2. Server event audit

The existing events are sufficient — no new protocol. Each carries enough to
route a targeted refresh:

| Event | Payload | Routing key |
| --- | --- | --- |
| `message:new` | full `MessageJSON` | `chatGuid`, `guid` |
| `message:update` | `{message, changed}` | `message.chatGuid`, `message.guid` |
| `message:unsend` | `{guid, chatGuid, dateRetracted}` | `chatGuid`, `guid` |
| `send:match` / `send:pending` / `send:error` | `{tempGuid, chatGuid, …}` | `tempGuid` |
| `sync:error` | `{message}` | — |

`chatGuid` + message `guid` are present, so the client patches the right
thread/summary and dedupes by GUID. No rowid/revision field was added — it
wasn't needed for targeted refresh, and the task said not to invent a large
protocol.

## 3. Refresh coordinator

`RefreshCoordinator` is the single source of truth for: when to reconnect,
when to fall back to polling, when to stop polling, and resume handling. Pure
`reconnectBackoff(attempt)` is unit-tested; the timer behavior is tested with
`fake_async`.

## 4. SMS sendability setting (server-authoritative)

Audit: SMS was gated **both** client- and server-side (the send handlers
hard-required `iMessage`). Now there is one server-owned flag.

- **Server**: `relaydb.SyncSettings.AllowSMSSend` (default **off**), persisted,
  normalized, echoed in `/api/server/status` `sync.settings` and
  `GET/PUT /api/sync/settings`. `SyncSettings.ServiceSendable(service)` decides:
  iMessage always, SMS only when `AllowSMSSend`, everything else never — from
  the **service name only**, never the GUID/handle. `SendText` and
  `SendAttachment` enforce it via `Handlers.chatSendable`.
- **Client**: `AppController` fetches the settings on connect and exposes
  `allowSmsSend`; `ChatService.canSendWith({allowSmsSend})` drives the composer
  (and the "· Read only" badge). A "Allow SMS sending through Mac" switch in
  Settings → Messaging reads/writes the server setting (PUT), so the client
  **displays server state**, never guesses. Unknown/RCS stay read-only;
  iMessage stays send-enabled; phone-number/`any;-;` chats follow the service,
  not the shape.

## 5. Status feedback

Reuses the C19 connection-notice host (sticky banner for offline / public
fallback, transient snackbar for recovery — de-duped, transition-only). The
coordinator drives the WS transitions that feed it (reconnecting/disconnected/
recovered). No per-event spam.

## Tests

- `refresh_coordinator_test.dart` — backoff curve; fallback poll starts only
  when WS is down and stops on reconnect; reconnect fires after backoff;
  reconnect suppressed if recovered first; resume reconnects+catches up.
- `sms_sendability_test.dart` — SMS composer off by default, on when enabled,
  Unknown/RCS read-only, iMessage always send-enabled, phone-shaped SMS gated by
  the setting not the shape.
- Server: `relaydb.TestServiceSendable`, `httpapi.TestSendAttachmentSMSGate`.
- Existing (still passing): `message:new dedupes by guid (no duplicate bubble)`,
  optimistic-send reconciliation, WS routing helpers.

## Validation

| Check | Result |
| --- | --- |
| New incoming iMessage appears w/o manual refresh | ✅ realtime patch (unchanged) |
| Active thread / chat-list update quickly | ✅ targeted patch by GUID |
| Send text + attachment reconcile w/o duplicates | ✅ GUID dedup + attachment no-bubble |
| Kill/restart network → reconnect + catch-up | ✅ coordinator backoff + catchUp |
| Background/foreground refresh | ✅ `onResume` |
| Fallback poll only when WS unavailable | ✅ coordinator test |
| SMS read-only by default | ✅ server off + client gate |
| Enable SMS sending → SMS sendable | ✅ setting on → server allows + composer enabled |
| Disable SMS sending → read-only | ✅ |
| Unknown read-only / iMessage send-enabled | ✅ |
| C19 behavior intact | ✅ attachment/device/version tests pass |
| `go build`/`go test`, `flutter analyze`/`test`, APK | ✅ |
