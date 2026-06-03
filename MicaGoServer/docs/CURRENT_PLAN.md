# MicaGoServer Current Plan

Short, living summary of where the project is headed. Pairs with the per-version
table in [`PROJECT_STATUS.md`](PROJECT_STATUS.md). Read
[`README.md`](README.md) first.

## Where we are

- **v0.11 connection endpoints are implemented** (local + LAN always-on, optional
  public URL via `GET /api/server/urls`, `POST /api/server/public-url`, `…/check`);
  the **v0.10** macOS SwiftUI companion exists and builds. Both are **In
  validation** (build + unit tests pass locally; not yet fully live-verified
  end-to-end).
- **v0.11.x — server reliability is implemented** (schema probing + capabilities,
  bounded lookback update pass with `message:update`/`message:unsend`, send-error
  fast-fail via `message.error`, Messages.app-running precondition, and companion
  runtime UX). It is **In validation** pending a live Mac run with Full Disk
  Access. Group/system `chat:event` is **deferred**. See
  [`spec-v0.11.x-server-reliability.md`](spec-v0.11.x-server-reliability.md) and
  [`v0.11.x-reliability-crosscheck.md`](v0.11.x-reliability-crosscheck.md).
- **v0.10.1 companion redesign Slice 1** landed (NavigationSplitView shell,
  Dashboard, Connections, status chip, runtime card, capabilities display).
- **Next milestone is v0.11.2 — Companion Runtime & Deployment**, then the
  productization roadmap below. Firebase (v0.12) moved **after** the local
  runtime, sync-control, and contacts foundations.

## Roadmap (next phases, in order)

Each phase has a dedicated spec; build strictly in this order:

1. **v0.11.2 — Companion Runtime & Deployment** —
   [`spec-v0.11.2-companion-runtime-deployment.md`](spec-v0.11.2-companion-runtime-deployment.md).
   Bundle the Go backend in the app; companion-owned lifecycle (start/stop/restart,
   crash detection + exit reason, auto-restart with backoff), launch-at-login,
   auto-start, silent/hidden launch, **menu-bar status item**, and a clear **Full
   Disk Access** failure banner (not raw "operation not permitted").
2. **v0.11.3 — Sync Control / Privacy Rules** —
   [`spec-v0.11.3-sync-control-and-privacy-rules.md`](spec-v0.11.3-sync-control-and-privacy-rules.md).
   Per-chat / per-handle **sync allow/block** and **push enable/mute** rules
   (whitelist/blacklist + default policy), a Sync Control page with a
   management-only Recent Messages view. **First version: stop future sync only —
   no deletion of existing `relay.db` data.** New `sync_rules` table + rule
   endpoints; rules gate sync + dispatch.
3. **v0.11.4 — Contacts Enrichment** —
   [`spec-v0.11.4-contacts-enrichment.md`](spec-v0.11.4-contacts-enrichment.md).
   Read-only, **local-only** macOS Contacts to map handle addresses → names for
   recognizing chats and creating rules. Optional; never uploaded; core server
   never depends on it.
4. **v0.12 — Firebase Self-host Push** —
   [`spec-v0.12.0-firebase-self-host.md`](spec-v0.12.0-firebase-self-host.md).
   Implement the `fcm` provider (service-account OAuth2 + FCM HTTP v1 multicast,
   TTL, token pruning, `previewMode`); **optional Firestore public-URL-only sync**.
   Push is gated by the v0.11.3 rules. **Never** store message content/contacts/
   phone numbers/bearer tokens/public push tokens/attachments/chat history.
5. **v0.13 — Scheduled Sending (deferred)** —
   [`spec-v0.13.0-scheduled-sending.md`](spec-v0.13.0-scheduled-sending.md).
   Scheduled text sends with persistence, restart/sleep reconciliation,
   Messages.app/Automation preconditions, conservative retry, anti-misfire
   confirmation. Sequenced last (depends on runtime + rules + contacts + push).

## Design principle: connection endpoints, not modes

This is the core mental model and must not regress into a "mode switch":

- **Local/loopback** endpoints (e.g. `http://127.0.0.1:<port>`) always exist
  while the server runs.
- **LAN** endpoints (e.g. `http://192.168.x.x:<port>`) are **always available
  when the server is running and bound appropriately** (wildcard `0.0.0.0` or a
  specific LAN address). LAN is **not** a switchable mode.
- A **public URL** (e.g. `https://mica.example.com`) is an **optional additional
  endpoint**, never a replacement for local/LAN.
- Config is provider-neutral (`network.public_base_url`, `verify_tls`,
  `preferred_pairing_endpoint`). There is **no** `remote: { mode: local | custom }`.
- The pairing QR encodes a **selected** endpoint (local for this Mac, LAN for
  same-network, public for remote) — a per-pairing choice, not a server mode.

## v0.11 — aggregated connection endpoints (implemented; finish validating)

Focus: local + LAN + optional public, exposed via `GET /api/server/urls`, with
`POST /api/server/public-url` and `…/check`. See
[`spec-v0.11.0-connection-endpoints.md`](spec-v0.11.0-connection-endpoints.md).

Remaining to close out v0.11:
- Live-verify `GET /api/server/urls` on a running server (loopback-only vs
  `0.0.0.0` bind → LAN entries appear).
- Configure a real public URL via a tunnel/proxy and confirm
  `POST /api/server/public-url/check` reports `reachable: true, authOk: true`.
- Exercise the companion's "Connection Endpoints" section and QR endpoint picker.

### Public URL providers (ways to produce a URL — not bundled)

Cloudflare Tunnel, Ngrok, DDNS + port forwarding, and Caddy/Nginx reverse proxy
are simply ways for the user to obtain a `public_base_url` that forwards to the
local server. **Tailscale** is an **advanced** option only.

Hard constraints:
- **Do not embed Tailscale.**
- **Do not bundle, download, launch, or manage `cloudflared`/`ngrok`** (yet).
- MicaGoServer only stores/validates the resulting URL; the user runs the tool.

## v0.11.x — server reliability (implemented; validating)

Made the relay faithfully reflect live `chat.db` state and run dependably,
**before** Firebase. Full spec:
[`spec-v0.11.x-server-reliability.md`](spec-v0.11.x-server-reliability.md).

- **Sync fidelity — done.** Bounded **lookback update pass** (default 7 days,
  `sync.update_lookback`, `0` disables) on top of the rowid-only insert; detects
  edited/unsent/read/delivered/send-error changes; **event-state cache**
  (fingerprint per message) prevents rebroadcast; first sight seeds silently.
  Emits Mica-native `message:update` and `message:unsend` (no Socket.IO/BlueBubbles
  shapes).
- **Send reliability — done.** Kept AppleScript text-send, pending matching, and
  the duplicate-`tempGuid` 409; added **`message.error` fast-fail**
  (`send_error`, gated by the `sendError` capability).
- **Schema / macOS compatibility — done.** Probes `chat.db` columns; missing
  columns degrade gracefully; `capabilities` reported in `GET /api/server/status`.
- **Runtime reliability — done.** The Go relay returns a fast, clear
  `messages_app_not_running` (`409`) when Messages.app isn't running for a send.
  **Keep-awake/caffeinate lives in the SwiftUI companion** (a conservative
  `caffeinate -i -s -w <pid>` toggle), which also shows Messages.app-running,
  Full Disk Access, and Automation status.
- **Deferred:** group/system `chat:event` (behind the `groupActions` capability).

Remaining to close: a live run on a Mac with Full Disk Access (the dev shells
lack FDA, so the full binary can't open `chat.db`).

## v0.12 — Firebase self-host (now sequenced 4th)

Full detail in [`spec-v0.12.0-firebase-self-host.md`](spec-v0.12.0-firebase-self-host.md).
Scoped tightly: implement the `fcm` provider (service-account OAuth2 + FCM HTTP
v1 multicast, TTL, token pruning, `previewMode`) and an **optional** Firestore
**public-URL-only** sync. Push is gated by the v0.11.3 sync/mute rules.

**Privacy (non-negotiable).** Firebase must **never** store: message content,
contacts, phone numbers, bearer tokens, public push tokens, attachments, or chat
history. Only the public URL (optional) is written to Firestore; push tokens go
only to Google FCM as delivery addresses.

> Sequencing note: v0.12 was previously "next"; it now comes **after** v0.11.2
> (runtime), v0.11.3 (sync control), and v0.11.4 (contacts), per the Roadmap
> above — push is most useful once the relay runs reliably and respects sync/mute
> rules.

## Out of scope (do not add)

WebUI/admin page, Electron, React/Vue, Socket.IO, BlueBubbles client/server
compatibility, private-API helpers (typing/reactions/edits/unsend/read-receipt
writes), a Mica-operated cloud relay, embedded Tailscale, or bundled tunnel
binaries. Keep the project Mica-native and conservative
([`micago-feature-decision-matrix.md`](micago-feature-decision-matrix.md)).

## Process reminders

- This is a **local macOS** workflow: review locally, **commit only when the user
  asks**. The `CLAUDE.md`/`AGENTS.md` "commit + push after every step" instruction
  is stale here (see [`PROJECT_STATUS.md`](PROJECT_STATUS.md) → "Docs & process
  notes").
- Verification commands: from `micago-server/`, run `gofmt -w .` and
  `GOCACHE=$PWD/.gocache go test ./...`; for the companion, `xcodebuild … build`.
