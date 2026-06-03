# BlueBubbles Source Audit v2

Source-level read of `MicaGoServer/bluebubbles server/` (reference only, gitignored)
compared against the current MicaGoServer Go server. This is a **planning/audit
pass — no code was changed.** It supersedes the higher-level
[`bluebubbles-full-audit.md`](bluebubbles-full-audit.md) by going into the
specific files/functions that reveal *server concerns we may be missing*.

> Boundary: we read BlueBubbles to find **missing server concerns**, not to copy
> its API, Socket.IO protocol, Electron/WebUI admin surface, private-API helpers,
> Firebase chat storage, or client-compatibility layer. MicaGoServer stays
> Mica-native: Go owns the relay API; the SwiftUI companion owns local
> setup/control; local + LAN endpoints are always derived; public URL is
> optional; Firebase (if used) is self-host FCM push + optional public-URL sync
> only.

Key files inspected (paths under `bluebubbles server/packages/server/src/`):
`server/index.ts`, `main.ts`, `server/fileSystem/index.ts`,
`server/api/interfaces/messageInterface.ts`,
`server/managers/outgoingMessageManager/{index,messagePromise}.ts`,
`server/databases/imessage/{index.ts,pollers/*,listeners/*}`,
`server/services/fcmService/index.ts`,
`server/services/proxyServices/{cloudflareService,ngrokService}/*`,
`server/api/http/api/v1/middleware/authMiddleware.ts`,
`server/services/caffeinateService/index.ts`,
`server/databases/server/{index.ts,migrations/*}`.

## Executive summary

MicaGoServer already covers the **core relay**: read-only `chat.db` → `relay.db`
sync, clean iMessage view, `attributedBody` text extraction, AppleScript send
with DB-confirmation matching (and the same 10-second offset + text/sentAt match
BlueBubbles uses), plain WebSocket events, safe attachment streaming, bearer
auth, device registry, a notification-provider abstraction, server-status
diagnostics, and aggregated connection endpoints.

The most material gaps are **not** in the request/response surface — they are in
**sync fidelity and runtime reliability**:

1. MicaGoServer's incremental sync advances by `message.ROWID` and only **inserts
   new rows**. It does not re-read already-synced rows, so **edits, unsends,
   read/delivered transitions, and send errors are never propagated** after the
   initial insert. BlueBubbles solves this with a **time-windowed poller** (1-week
   lookback on the indexed `date` column) plus an event-state cache and an
   `unsentIds` watch-list.
2. AppleScript send requires **Messages.app to be running**, and a 24/7 relay
   needs the **Mac to stay awake**. BlueBubbles actively ensures both
   (`startMessages` keep-alive every 2.5 min; `caffeinate` child process).
   MicaGoServer assumes both.
3. Outgoing **send failures** are detected only via AppleScript error + a 120 s
   timeout; BlueBubbles also reads `message.error` to report failures quickly.

BlueBubbles' **FCM/Firestore design validates the v0.12 plan**: it stores **only
the server URL** in Firestore and sends notification content via transient FCM
data pushes — never message history in Firebase.

## What MicaGoServer already handles

- **Read pipeline / clean view** — `relay.db` sync of a clean iMessage subset,
  `service` filtering, `includeEmpty`, Apple-epoch conversion. (BlueBubbles'
  `MessageRepository.getMessages` is the analog; ours is intentionally narrower.)
- **`attributedBody` extraction** — equivalent to BlueBubbles' `universalText()`;
  we already recover text when `message.text` is NULL.
- **Send + confirmation** — `POST /api/chats/{guid}/send` mirrors
  `sendMessageSync`: 10 s send-time offset, await a DB match on normalized
  text + `sentAt <= dateCreated`, duplicate `tempGuid` rejected (409, like
  BlueBubbles' `sendCache`), 120 s timeout, `send:match` / `send:error` events.
- **Realtime** — plain `GET /ws` with `message:new` / `send:match` /
  `send:error` / `sync:error`. We correctly **avoid Socket.IO**.
- **Attachments** — metadata in `relay.db`; download streams raw bytes with
  **path-traversal protection** (`EvalSymlinks` + root-prefix check),
  `Content-Type` from stored MIME, `hideAttachment` respected. Our safe-path
  handling is solid (BlueBubbles serves from its own resolved paths too).
- **Security** — bearer token in the `Authorization` header, **constant-time**
  comparison, localhost-only `--disable-auth`, WS token via header or query.
  **Stronger than BlueBubbles** (see "things not to copy").
- **Device registry** — register/list/patch/heartbeat/delete; raw push token
  **never returned** (`pushTokenSet`).
- **Notification abstraction** — `none`/`webhook` deliver; `fcm`/`hms`/
  `harmony_push`/`ntfy` are honest `501` stubs; `previewMode`
  (`none`/`sender`/`sender_and_text`) already controls how much content a push
  carries.
- **Diagnostics** — `GET /api/server/status` reports a Full-Disk-Access probe,
  attachments-readable probe, and Automation `unknown`.
- **Connection endpoints** — `GET /api/server/urls` (local + LAN always derived,
  optional public), `POST /api/server/public-url` + `…/check`.

## Important gaps we should address soon

1. **Message-update detection (edits / unsends / read / delivered / errors).**
   Rowid-only incremental sync misses post-insert changes. Adopt a **bounded
   lookback poll** (BlueBubbles uses 1 week on the indexed `date` column, then
   filters in memory) plus a small **event-state cache** keyed by GUID +
   `dateEdited`/`dateRetracted` to emit "updated" events. Read `message.error`,
   `date_delivered`, `date_read`, `date_edited`, `date_retracted`,
   `is_sent`/retracted-parts.
2. **Outgoing send-error reporting.** Detect `message.error != 0` for our own
   sent rows and surface it as `send:error` immediately (don't wait for the
   timeout).
3. **Send preconditions.** Ensure **Messages.app is running** before AppleScript
   send; surface a clear error if it isn't. (BlueBubbles: `FileSystem.startMessages()`.)
4. **Stay-awake for a relay host.** A sleeping Mac stalls sync/send/tunnel.
   BlueBubbles spawns `caffeinate -i -m -s -w <pid>`. In Mica this is best owned
   by the **SwiftUI companion** (it already owns local control), not the Go server.

## Useful ideas for later

- **Group / system events** — `message.item_type` (1/2/3) + `group_action_type`
  map to participant-added/removed/left, name-change, icon-change. Surface as
  read-only events if/when clients want group fidelity.
- **Reactions / tapbacks & threads** — `associated_message_guid` +
  `associated_message_type`, and thread originator columns. Read-only decode for
  display; **never** the private-API *send* path.
- **macOS-version schema guards** — BlueBubbles branches on
  `isMinSierra/Mojave/HighSierra/Monterey/Ventura` because columns like
  `date_edited`, `attributedBody`, thread fields, and `is_from_me` semantics
  differ. We should **probe column existence** (or detect macOS version) before
  selecting these, to avoid query failures on older/newer `chat.db`.
- **Attachment conversions/thumbnails** — `sips` HEIC→JPG, `afconvert` CAF↔MP3,
  thumbnails/blurhash for clients that can't render Apple formats. Optional;
  raw-byte streaming remains the default.
- **Native permission status** — BlueBubbles uses `node-mac-permissions`
  `getAuthStatus("full-disk-access")` and `isTrustedAccessibilityClient`. The
  Go server's read-probe is fine; the **companion** could query richer TCC
  status and guide the user (Automation can only be confirmed by attempting an
  AppleScript and catching the TCC error).
- **Token hygiene on push** — BlueBubbles prunes `registration-token-not-registered`
  and handles `payload-size-limit-exceeded`; apply the same when v0.12 FCM lands.

## Things we should not copy

- **Socket.IO RPC layer** (`socketRoutes.ts`) — keep plain WebSocket events.
- **BlueBubbles `/api/v1/*` shapes & response envelopes** — keep our Mica-native
  contract ([`spec-v0.9.0-client-api-contract.md`](spec-v0.9.0-client-api-contract.md)).
- **Electron app / React `packages/ui` admin surface** — the SwiftUI companion is
  our only control surface; no WebUI.
- **Private API / dylib injection** (`api/privateApi/*`, `MacForgeMode`,
  `dylibPlugins`) — no typing-send, reactions-send, edit/unsend-send, FaceTime.
- **Query-param password auth** (`authMiddleware.ts` reads `?guid/?password/?token`
  and does a plaintext `safeTrim` compare). Our header bearer + constant-time
  compare is **better** — do not regress to query-param secrets on REST.
- **Managing tunnel binaries** — BlueBubbles spawns/refreshes `cloudflared`,
  `ngrok`, `zrok`. We only **store/validate** a user-produced public URL.
- **Firebase chat storage** — only the server URL belongs in Firestore (which is
  exactly what BlueBubbles does); never content/contacts/numbers/tokens/
  attachments/history.
- **Heavy server config DB** — BlueBubbles' TypeORM entities (contacts, queue,
  scheduled messages, alerts, webhooks) are far broader than we need.

## Detailed notes by area

### Lifecycle
- `BlueBubblesServer` runs **pre-start** and **post-start** checks
  (`server/index.ts`): region/timezone, proxy fixups, permission logging,
  `startMessages`, a 2.5-min Messages keep-alive (`ScheduledService`), and a
  **post-start password warning** if empty. Config lives in a TypeORM SQLite DB
  with **migrations** (`databases/server/migrations/*`, `migrationsRun` /
  `synchronize`).
- Mica analog: `app.Run` opens `chat.db` + `relay.db`, runs a startup sync, then
  a periodic sync loop. Config is a flat YAML (`~/.micago/config.yaml`); relay
  migrations are additive `ALTER TABLE` in `relaydb/migrations.go`. **Adequate.**
  Missing: Messages-running guarantee and stay-awake (see gaps).

### macOS permissions
- FDA: `getAuthStatus("full-disk-access")` (native TCC) **plus** a DB-init probe
  (`hasDiskAccess`). Accessibility: `isTrustedAccessibilityClient`.
  `checkPermissions()` returns name/pass/solution rows for the UI.
- Mica: server does a **read probe** of `chat.db`/attachments and reports
  Automation as `unknown` (can't be probed without sending). This is reasonable;
  the **companion** is the right place to add richer guidance and (optionally) a
  one-time Automation prompt by attempting a benign AppleScript.

### chat.db
- `MessageRepository.getMessages` joins chat/handle/attachment, supports
  `withChats`, ordering, and where-clauses. The **poller**
  (`pollers/MessagePoller.ts`) is the important part: a **1-week lookback** on
  the indexed `date` column, then in-memory filtering for new/changed rows by
  `dateCreated`, `dateDelivered` (if `isFromMe`), `dateRead` (if `isFromMe` and
  not group), `dateEdited`, `dateRetracted`, `hasUnsentParts`,
  `didNotifyRecipient`. Group/system rows handled via `itemType` +
  `groupActionType`. An `IMessageCache` event-state cache dedupes and detects
  `updated-entry` when `dateEdited`/`dateRetracted` advance. An `unsentIds` list
  re-checks outgoing rows until they become sent or errored.
- Mica: rowid-only incremental insert → **misses all of the above updates.**
  This is the single biggest fidelity gap.

### Send pipeline
- `sendMessageSync` adds a `MessagePromise` (match on chatGuid + text +
  `sentAt <= dateCreated`), sends via `ActionHandler.sendMessage` (AppleScript),
  awaits the DB match; `sendCache` dedupes by `tempGuid`; timeouts are **2 min
  (text) / 20 min (attachment)**; errors detected via `message.error` →
  `message-send-error`. Attachment send copies to a Convert/staging dir and
  ensures Messages is open.
- Mica: equivalent matching + dedup + 120 s timeout + `send:match`/`send:error`.
  Missing: `message.error` fast-fail and the Messages-open precondition;
  attachment **send** is intentionally out of scope.

### Sync pipeline
- Two mechanisms: **file-change listeners** (watch `chat.db`/`-wal`) and
  **pollers** (interval). Both feed an `IMessageCache` for missed-event recovery
  and restart de-dup; the lookback window covers gaps after downtime.
- Mica: single periodic relay sync loop persisting `last_message_rowid` +
  `last_sync_at` (restart-safe for *new* rows). Add a lookback/update pass for
  parity (see gaps). Polling is already our model — no Socket.IO needed.

### Attachments
- `fileSystem/index.ts` resolves Attachment paths, converts media (`sips`
  HEIC→JPG, `afconvert` CAF↔MP3), and stages copies; `attachmentInterface`
  handles double-extension converted files.
- Mica: raw-byte streaming with strong path safety; no conversion/thumbnails.
  Conversions are a later nicety, not a correctness gap.

### Remote access
- Proxy services (`cloudflareService`, `ngrokService`, `zrokService`) **spawn and
  manage** the tunnel, listen for `new-url` → `applyAddress` → `setServerUrl`
  (push to Firebase), and handle `needs-restart`/refresh timers.
- Mica: deliberately does **not** manage tunnels. We store/validate a
  user-produced public URL (`/api/server/public-url` + `…/check`). The reusable
  idea is **"when the public URL changes, sync it outward"** — which becomes the
  optional Firestore URL sync in v0.12.

### Firebase / push
- `fcmService/index.ts`: self-host Firebase via the user's `clientConfig`/
  `serverConfig`; sets Firestore security rules; **stores only `serverUrl`** in
  Firestore (`collection("server").doc("config").set({ serverUrl })`) and/or
  Realtime DB; an `addressUpdateService` keeps that URL fresh; `sendNotification`
  does an FCM **multicast** `data` payload with 24 h TTL, prunes unregistered
  tokens, and handles payload-size errors. Restart coordination via a
  `nextRestart` field.
- Mica v0.12: follow this exactly — **Firestore = server URL only**, FCM data
  push for content (gated by `previewMode`), token pruning, TTL. **No** message
  content/contacts/numbers/tokens/attachments/history in Firebase.

### Security
- Single shared `password`, accepted as `?guid`/`?password`/`?token` query
  params, compared with a non-constant-time `safeTrim` equality; logs client IP
  on failures. No per-device tokens; "pairing" = sharing the password + URL.
- Mica: header bearer + constant-time compare (stronger). Keep it. Minor idea
  worth adopting: **log auth failures with client IP** (without echoing the
  token). Per-device revocable tokens remain out of scope for now.
