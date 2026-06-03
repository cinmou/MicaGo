# Server Gap After BlueBubbles Source Review

Prioritized actions derived from [`bluebubbles-source-audit-v2.md`](bluebubbles-source-audit-v2.md).
Audit/planning only — **no code changed**. Recommendations stay Mica-native:

- Go server owns the relay API; the SwiftUI companion owns local setup/control.
- Local + LAN endpoints are always derived; public URL is optional.
- Firebase, if used, is **self-host FCM push + optional public-URL sync only** —
  never message content, contacts, phone numbers, bearer tokens, attachments, or
  chat history.

## P0 — must fix before broader testing

- **P0-1 Live-validate the running server with Full Disk Access.** Current
  shells lack FDA, so the full binary can't open `chat.db` and exits at startup.
  Grant FDA to the launching app/terminal (or a built companion) and confirm a
  real end-to-end run: sync, `GET /api/server/urls`, send. *Owner: companion +
  manual.* Blocks all live testing.
- **P0-2 Ensure Messages.app is running before AppleScript send.** Today send
  assumes Messages is open; if it isn't, the AppleScript fails opaquely and we
  only learn via the 120 s timeout. At minimum, **detect and return a clear
  error**; ideally have the companion ensure Messages is launched.
  (BlueBubbles: `FileSystem.startMessages()` keep-alive.)

> Note: there is no P0 in the request/response surface — the API contract is
> sound. P0 here is "what blocks *reliable live testing*."

## P1 — important for reliable self-hosting

- **P1-1 Detect message updates after insert (edits / unsends / read /
  delivered).** Add a bounded **lookback pass** to the sync loop (BlueBubbles
  uses ~1 week on the indexed `date` column, then filters in memory) plus a small
  **event-state cache** keyed by GUID + `dateEdited`/`dateRetracted`. Emit new
  realtime event types (e.g. `message:update`) and update the corresponding
  `relay.db` rows. Read `date_delivered`, `date_read`, `date_edited`,
  `date_retracted`, retracted-parts/`is_empty`. *Owner: Go server (`relaydb` +
  `realtime`).* Needs a short spec (e.g. `spec-v0.x-sync-fidelity.md`).
- **P1-2 Surface outgoing send errors from `message.error`.** For our own sent
  rows, read `message.error != 0` and emit `send:error` immediately instead of
  waiting for the timeout. Track outgoing rows until sent/errored (BlueBubbles'
  `unsentIds`). *Owner: Go server (`send` + sync).*
- **P1-3 Keep the relay host awake (companion-owned).** A sleeping Mac stalls
  sync/send/tunnel. Add a conservative "keep awake while serving" option in the
  SwiftUI companion (e.g. an `NSProcessInfo` activity / `caffeinate`-style
  assertion), **not** in the Go server. *Owner: companion.*
- **P1-4 macOS-version / schema guards for `chat.db`.** Probe column existence
  (or detect macOS version) before selecting version-specific columns
  (`date_edited`, thread fields, `attributedBody`) so queries don't fail on
  older/newer `chat.db`. *Owner: Go server (`store`/`relaydb`).*

## P2 — useful later

- **P2-1 Group / system events** — decode `item_type` + `group_action_type`
  (participant add/remove/left, name-change, icon) as read-only events.
- **P2-2 Reactions / tapbacks & threads** — read-only decode of
  `associated_message_guid`/`associated_message_type` and thread originator for
  display. **Never** the private-API send path.
- **P2-3 Attachment conversions / thumbnails** — optional `sips` HEIC→JPG,
  `afconvert` audio, and thumbnails for clients that can't render Apple formats;
  raw-byte streaming stays the default.
- **P2-4 Richer permission diagnostics (companion)** — query native TCC status
  for FDA/Accessibility and guide the user through the one-time Automation
  prompt; the Go server's read-probe stays as the API-level signal.
- **P2-5 Auth-failure logging** — log client IP on `401` (without echoing the
  token), matching BlueBubbles' visibility. Keep header-bearer + constant-time.

## Deferred / do not implement

- Socket.IO RPC; BlueBubbles `/api/v1` shapes/envelopes; Electron/React WebUI
  admin surface.
- Private API / dylib injection (typing-send, reaction-send, edit/unsend-send,
  FaceTime, `MacForgeMode`).
- Query-param password auth (our header bearer + constant-time is stronger).
- Bundling/managing `cloudflared`/`ngrok`/`zrok`; embedding Tailscale.
- Firebase storage of message content/contacts/phone numbers/bearer tokens/
  attachments/chat history (Firestore holds **server URL only**).
- BlueBubbles' heavy server config DB (contacts, queue, scheduled messages,
  alerts) and attachment **send** queue.

## Recommended next milestone

**Insert a short reliability/fidelity pass _before_ v0.12 Firebase**, then
proceed to Firebase:

1. **v0.11.x — Sync fidelity + send reliability** (Go server): P1-1 (update
   detection via lookback + event cache), P1-2 (`message.error` send failures),
   P1-4 (schema/version guards). Add `spec-v0.11.x-sync-fidelity.md` and tests.
2. **Companion reliability** (SwiftUI): P0-2 (ensure Messages running) and P1-3
   (keep-awake while serving). Update `spec-v0.10.0-mac-companion.md`.
3. **v0.12 — Firebase self-host** (as already planned): FCM push for real (token
   pruning + TTL, `previewMode`-gated payload) and **optional** Firestore sync of
   the **public URL only**. Write `spec-v0.12.0-firebase-self-host.md` first.

Rationale: v0.12 push is far more useful once the relay reliably reflects edits/
unsends/read-receipts/send-failures and stays running — otherwise clients get
push for a state the relay won't keep current. Doing P1 first de-risks v0.12.
