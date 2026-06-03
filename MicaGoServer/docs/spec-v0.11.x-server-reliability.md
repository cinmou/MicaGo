# MicaGoServer v0.11.x — Server Reliability

Status: **Planned** (spec only; no code in this pass). Derived from
[`bluebubbles-source-audit-v2.md`](bluebubbles-source-audit-v2.md) and
[`server-gap-after-bluebubbles-source-review.md`](server-gap-after-bluebubbles-source-review.md).

## Goal

Make the relay faithfully reflect the live `chat.db` state and run dependably as
a long-lived local service, **before** adding Firebase push (v0.12). Push is only
useful once edits/unsends/receipts/send-failures stay current and the host keeps
running.

This is a **server-reliability** milestone, not a feature-surface change. It
adds update detection, faster send-failure reporting, schema/version safety, and
runtime preconditions — while staying Mica-native.

## Non-goals

- **No Firebase** in this pass (that is v0.12).
- No WebUI / Electron / React.
- No Socket.IO (keep our plain WebSocket envelope).
- Do not copy BlueBubbles API shapes or event names.
- No private-API helpers (typing/reaction/edit/unsend **send**, FaceTime, dylib).
- No attachment **sending** (no send queue) in this pass.
- Do not store messages, tokens, or any chat data in any cloud service.

---

## 1. Sync fidelity

### Problem

The current sync is **rowid-only incremental**: it advances `last_message_rowid`
and inserts newly-seen rows. Rows already in `relay.db` are never re-read, so
post-insert changes are missed:

- edited messages (`message.date_edited`),
- unsent/retracted messages (`message.date_retracted`, retracted parts / empty),
- read-status changes (`message.date_read`, for our outgoing messages),
- delivered-status changes (`message.date_delivered`, for our outgoing messages),
- send errors (`message.error`),
- group/system events (`message.item_type` + `group_action_type`).

### Design: bounded lookback pass + event-state cache

Keep the existing incremental insert pass for **new** rows. **Add** an
independent **update pass** that runs on the same sync tick:

1. **Lookback window.** Query `chat.db` for rows with
   `message.date >= (now - lookback)`, default **7 days**, ordered by the indexed
   `date` column, then filter in memory (the index keeps this cheap; following
   BlueBubbles' approach). The window is configurable
   (`sync.update_lookback`, default `168h`); `0` disables the update pass.
   The incremental rowid pass still catches anything outside the window.
2. **Change selection.** Within the window, consider a row "changed" if any of:
   `date_edited`, `date_retracted`, `date_read` (outgoing only),
   `date_delivered` (outgoing only), `error`, send/retracted-part state, or a
   group/system `item_type` transition differs from what we last stored.
3. **Event-state cache.** Maintain a per-message fingerprint so unchanged rows
   **do not rebroadcast**. Fingerprint = a hash/tuple of the mutable fields:
   `(date_edited, date_retracted, date_read, date_delivered, is_sent, error,
   has_unsent_parts)`. Persist the relevant values in `relay.db` (the message
   row already stores some) and/or a small `message_state` side table so the
   cache survives restarts; on startup, seed from `relay.db` to avoid a
   rebroadcast storm. An in-memory LRU may front the persistent state for speed.
4. **Apply + emit.** Update the corresponding `relay.db` row, then emit a
   WebSocket update event (below). Process oldest-first within a tick.

This pass is **read-only** against `chat.db` and idempotent: re-running it
produces no events unless a fingerprint actually changed.

### WebSocket update events (Mica-native; not BlueBubbles shapes)

Keep the existing envelope `{ "type": ..., "data": ... }` and existing events
(`message:new`, `send:match`, `send:error`, `sync:error`). Add:

- **`message:update`** — a message's mutable state changed. `data` is the full
  Mica `Message` object (same model as `message:new`) plus a `changed` array of
  field names, e.g.:

  ```json
  {
    "type": "message:update",
    "data": {
      "message": { /* Mica Message */ },
      "changed": ["dateRead", "isRead"]
    }
  }
  ```

  Used for read/delivered transitions and edited-text updates (the edited text
  is reflected in the `Message.text`/`subject` fields).

- **`message:unsend`** — a message was retracted/unsent. `data`:

  ```json
  { "type": "message:unsend", "data": { "guid": "…", "chatGuid": "…", "dateRetracted": 1717372800000 } }
  ```

- **`chat:event`** (optional, gated by capability — see §3) — a group/system
  event. `data`:

  ```json
  {
    "type": "chat:event",
    "data": { "chatGuid": "…", "event": "name-change", "guid": "…", "dateCreated": 1717372800000 }
  }
  ```

  `event` ∈ `participant-added | participant-removed | participant-left |
  name-change | group-icon-changed | group-icon-removed`. Group events are
  **best-effort**: emitted only when the columns are present and decodable;
  otherwise silently skipped.

Notes:
- Event **names and payloads are Mica-native**; we do not adopt BlueBubbles'
  `updated-message` / Socket.IO event shapes.
- Clients must treat unknown `type` values as ignorable (forward-compatible),
  per the v0.9 contract.
- These additions are documented as an addendum to
  [`spec-v0.4.0-websocket.md`](spec-v0.4.0-websocket.md) /
  [`spec-v0.9.0-client-api-contract.md`](spec-v0.9.0-client-api-contract.md) when
  implemented.

### Message model additions (additive, optional fields)

Extend the Mica `Message` model with nullable, additive fields so update events
carry full state without breaking existing clients:

- `dateEdited` (int ms, nullable)
- `dateRetracted` (int ms, nullable)
- `isEdited` (bool), `isUnsent` (bool)

All optional and ignorable by older clients (forward-compatible per v0.9).

---

## 2. Send reliability

Keep the current AppleScript text-send path, pending-match manager
(normalized text + `sentAt <= dateCreated`), 120 s timeout, `send:match` /
`send:error` events, and **duplicate `tempGuid` → 409** protection. Changes:

- **`message.error` fast-fail.** Track our own outgoing rows (by chat + matching
  window) until they become `is_sent` with `error == 0`, or `error != 0`. On a
  non-zero `error`, emit `send:error` **immediately** (don't wait for the
  timeout). Map common Apple error codes to a short, stable reason string in the
  `send:error.code`/`message` fields (timeout remains `send_timeout`; AppleScript
  failure remains `send_failed`; new `send_error` for DB-reported failures with
  the numeric code in the message).
- **Outgoing watch-list.** Maintain a small in-memory set of pending outgoing
  rowids (BlueBubbles' `unsentIds` analog) so the update pass can resolve them to
  sent/errored and clear the pending entry.
- **Unchanged:** no private-API send, no attachment-send queue (out of scope).

---

## 3. Schema / macOS compatibility

`chat.db` columns differ across macOS versions (e.g. `date_edited`,
`date_retracted`, `thread_originator_guid`, `attributedBody`, group/`item_type`
semantics). Today a query referencing a missing column would fail.

Design:

- **Schema probe at startup** (and cache the result): inspect
  `PRAGMA table_info(message)` / `table_info(chat)` to record which
  version-sensitive columns exist. Optionally also read the macOS product
  version for logging.
- **Capability-gated SQL.** Build the SELECT column list from detected
  capabilities; never reference a column that isn't present. Missing columns
  **degrade gracefully** (the corresponding feature is simply not emitted — e.g.
  no `message:unsend` if `date_retracted` is absent), rather than crashing.
- **Report capabilities in diagnostics.** Add a `capabilities` object to
  `GET /api/server/status` (or a sibling field), e.g.:

  ```json
  "capabilities": {
    "macosVersion": "14.5",
    "schema": {
      "dateEdited": true,
      "dateRetracted": true,
      "threadOriginator": true,
      "groupActions": true,
      "attributedBody": true
    },
    "syncUpdatePass": { "enabled": true, "lookbackHours": 168 }
  }
  ```

  This makes it obvious to the companion (and to a future agent) what the running
  server can actually detect on this Mac.

---

## 4. Runtime reliability

Split clearly between the **Go relay** (minimal, correctness-focused) and the
**SwiftUI companion** (local control/UX).

### Go server

- **Messages.app precondition for send.** AppleScript send requires Messages.app
  to be running. The server should **detect** whether Messages is running and
  **return a clear, fast error** when a send is attempted while it is not
  (a dedicated `send:error` code such as `messages_not_running` / HTTP `409`
  `messages_app_not_running`), instead of failing opaquely and waiting for the
  120 s timeout. The server **may** attempt a single benign launch via
  AppleScript, but **must not** run an aggressive keep-alive loop — that belongs
  in the companion.
- **No deep keep-awake logic in the relay core.** The Go server stays a clean
  relay; it does not spawn `caffeinate` or manage power assertions.

### SwiftUI companion (owns runtime UX; spec'd here, built later)

The companion should eventually show and manage:

- **Messages.app running status** — and a one-click "Open Messages".
- **Full Disk Access status** — already surfaced via `/api/server/status`
  permission diagnostics; keep guidance.
- **Automation status** — guide the user through the one-time Automation prompt
  (can only be confirmed by attempting an AppleScript and catching the TCC
  error).
- **Keep Awake status** — a conservative, opt-in "keep this Mac awake while the
  relay is running" toggle (e.g. an `NSProcessInfo` activity assertion or a
  managed `caffeinate`), owned entirely by the companion.

These companion items are tracked as an update to
[`spec-v0.10.0-mac-companion.md`](spec-v0.10.0-mac-companion.md) when built.

---

## Suggested implementation order (when approved)

1. **Schema probing + capabilities** (§3) — foundational; everything else gates
   on it. Add `capabilities` to `/api/server/status`. Tests: probe parsing,
   capability-gated SQL on synthetic schemas.
2. **Update pass + event-state cache + `message:update`/`message:unsend`** (§1).
   Tests: fingerprint stability (no rebroadcast), edit/unsend/read/delivered
   detection against fixture DBs.
3. **Send-error fast-fail via `message.error`** (§2). Tests: errored outgoing row
   → prompt `send:error`; duplicate `tempGuid` still 409.
4. **Messages-not-running detection** (§4, server side). Tests: send while
   "not running" → fast clear error.
5. **Group/system events** (§1, `chat:event`) — last, behind the
   `groupActions` capability.
6. **Companion runtime UX** (§4) — Messages status, Keep Awake toggle, richer
   permission guidance.

Each step is independently shippable and testable with
`gofmt -w . && GOCACHE=$PWD/.gocache go test ./...`.

## Tests / verification (planned)

- Unit tests over synthetic/fixture `chat.db` snapshots for: schema probing,
  update detection per field, fingerprint de-duplication, and `message.error`
  reporting.
- `GET /api/server/status` includes `capabilities`; no bearer/token leakage.
- WebSocket: new events emitted once per real change; unchanged rows produce no
  events.
