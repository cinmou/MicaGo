# C18 — Backend/tunnel startup decoupling + Companion cleanup

## The bug

Backend startup was coupled to Remote Tunnel startup in three ways:

1. **Blocking tunnel discovery at app launch.** `TunnelController` is a
   `@StateObject` singleton created during App init, and its `init()` ran
   discovery **synchronously on the main actor**: a login-shell
   `/bin/zsh -lc "command -v cloudflared"` and a `pgrep -f`, each with
   `waitUntilExit()`. A slow login shell (common with heavy dotfiles) delayed
   the entire bootstrap — including `backend.autoStartIfNeeded` — so tunnel
   discovery effectively gated backend launch.
2. **Per-poll tunnel side effects.** Every health poll called
   `TunnelController.serverHealthChanged(...)` with level-triggered logic, so
   steady polls could repeatedly retry a failed tunnel, and the very first
   poll after app launch (backend simply not started yet) could stop a tunnel
   the user had running.
3. **The Companion control API preferred the public URL.** `ConfigReader.baseURL`
   returned `network.public_base_url` / `server.public_url` before the local
   server address. When the Cloudflare Tunnel was down, the Companion's own
   health/auth/status calls went through the public tunnel and failed, making
   backend startup look dependent on Cloudflare.

## New ownership model

- **The backend owns its own lifecycle.** `BackendController` contains zero
  tunnel references (enforced by review; verified by grep in validation).
  Start/stop/restart and the C17 freshness/version checks never touch, wait
  on, or consult the tunnel.
- **The Companion control API is always local.** `ConfigReader.baseURL(for:)`
  now ignores public/tunnel URLs and builds a local control URL from
  `server.addr`. Any-address binds such as `0.0.0.0:3000` and `[::]:3000`
  map to `127.0.0.1:3000` for local control.
- **The tunnel optionally FOLLOWS backend health.** The coupling is one
  pure function, `TunnelAutopilot.decide(...)`
  (`MicaGoCompanion/Services/TunnelAutopilot.swift`): given the previous and
  current health plus the user's "start/stop tunnel with server" opt-ins, it
  returns start/stop/none. Decisions fire **only on health transitions**, so:
  - steady polls never re-fire a failed tunnel start,
  - the first poll after launch never stops an existing tunnel,
  - a backend restart without the opt-in never touches the tunnel.
- **Discovery is async.** `refreshDiscovery()` runs all probes (binary lookup,
  config read, pgrep) in a detached utility task; only the published-state
  update hops to the main actor. App bootstrap and backend auto-start no
  longer wait on anything tunnel-related.
- **AppDelegate owns the optional follow link.** `AppModel.refresh()` only polls
  backend state now. `AppDelegate` observes `AppModel.reachable` changes and
  notifies `TunnelController` after backend health changes. This keeps sync,
  config, and status polling free of tunnel side effects.

Focused tests:

- `scripts/test-startup-ownership.sh` verifies that Companion control ignores
  public URLs, maps any-address binds to loopback, preserves specific bind
  addresses, and that `BackendController.swift` contains no tunnel/cloudflared
  references.
- `scripts/test-tunnel-autopilot.sh` compiles the pure autopilot with 7
  assertions covering the tunnel follow scenarios.

## Removed legacy logic

Companion:
- `ServerRuntimeCard` — duplicated the Dashboard Status card and the toolbar
  start/stop control (status dot, version, start/stop/restart, exit info).
- `RecentOutputView` — orphan (nothing referenced it).
- `PermissionsPage` — orphan page not reachable from the sidebar.
- `SummaryRow`, `StatusValueRow` — became orphans once the Dashboard
  Permissions card moved (DiagnosticsSection covers the same data).
- `BackendController.lastExitReason` — write-only published property.
- Synchronous tunnel discovery in `TunnelController.init`.
- Public/tunnel URL as the Companion's own control endpoint.
- `AppModel.refresh()` directly starting/stopping tunnel work from status poll.

Server:
- `apiQueryService` interface + indirection in `internal/app/app.go` — dead
  abstraction since C12 (exactly one implementation; `httpapi.NewHandlers`
  already declares its own interface). `relay` is now passed directly.

## UI changes (reorganize only, no redesign)

| Before | After |
| --- | --- |
| Sidebar: Dashboard, Connections, Sync Control, Message Inspector, Notifications, Server, Logs, Tutorials, Advanced | Dashboard, Connections, **Sync Control**, **Debug**, Notifications, Tutorials, Advanced |
| Sync Control + Message Inspector mixed into Debug | **Sync Control** is its own page; **Debug** contains only Message Inspector and Logs |
| Dashboard: Status, Tunnel, Pairing, Devices, Permissions, Capabilities | Dashboard: Status, Tunnel, Pairing, Devices, **Live Sync Monitor** |
| Server page: Server Runtime card, FDA banner, Live Sync Monitor, Bind address | **Page removed** — monitor → Dashboard, bind address → Connections, binary path/identity → Advanced |
| Permissions/Capabilities on Dashboard | **Advanced**: FDA banner, Permission Diagnostics, Runtime (Messages.app / Keep Awake), Capabilities, Configuration (+ binary path), Backend Build |

## Validation

- `scripts/test-tunnel-autopilot.sh` — 7/7 pass: backend start without opt-in
  never starts tunnel; opt-in follows; steady health never re-fires; initial
  unhealthy poll never stops; opt-in stop on observed down-transition; restart
  without opt-in doesn't touch tunnel; unusable tunnel never started.
- `scripts/test-startup-ownership.sh` — pass: local control URL ignores public
  URL; `0.0.0.0` / `[::]` map to loopback; specific bind preserved;
  BackendController has no tunnel references.
- Backend start/stop/restart paths contain no tunnel references (grep clean).
- Tunnel can be started/stopped independently at any time from the Dashboard
  card (unchanged behavior).
- C17 freshness/version reporting untouched (Backend Build card, --version,
  status backend block).
- `go build ./...` + `go test ./...` — pass.
- `xcodebuild` Debug — BUILD SUCCEEDED.

## C18 Follow-up: Debug vs Sync Control

The first cleanup pass over-compressed the sidebar by placing Sync Control above
Message Inspector inside Debug. That was reverted. The current ownership is:

- Sync Control: sync policy, service scope, backfill controls, rule editing,
  sync status, and sync diagnostics only.
- Debug: Message Inspector and server logs only.
- Connection, pairing, backend runtime, tunnel, and startup controls remain on
  their existing Dashboard/Connections/Advanced pages.

This keeps Message Inspector's message list under Message Inspector while
avoiding duplicated standalone debug/log cards.

## C18 Follow-up: ClientSetupSection crash fix

Regression: the Companion crashed in `ClientSetupSection`
(`Fatal error: Unexpectedly found nil while unwrapping an Optional value`)
and the console showed malformed health URLs like `:3000/api/health`.

Two independent defects:

1. **Stale-binding force unwrap.** The LAN-address Picker's binding getter used
   `lanTargets.first!`. SwiftUI evaluates binding getters lazily — when the
   pairing target list emptied between renders (status poll while the backend
   stopped), the live Picker's getter ran against an empty list and crashed.
   Fixed with `selectedLan?.baseUrl ?? lanTargets.first?.baseUrl ?? ""`; the
   empty string is a safe no-match tag. This was the only force unwrap in the
   Client Setup / pairing / QR path (grep-verified 0 remaining).
2. **Host-less control URL.** `ConfigReader.controlAddress` didn't handle Go's
   host-less listen syntax `":3000"` (and other any-address forms), so the
   control URL became `http://:3000` → requests to `:3000/api/health`.
   `controlHostPort(_:)` now parses host/port properly (bracketed IPv6, bare
   IPv6, missing host, missing/invalid port) and guarantees a non-empty host
   (loopback) and valid port (default 3000); `baseURL` builds the URL with
   `URLComponents`, never string concatenation.

Degraded-state rendering (no crash, no dead ends): backend stopped → empty
target list shows the "No LAN endpoint" hint; LAN missing but Public configured
→ the v2 payload falls back to a public-only endpoint (QR still works); Public
missing → LAN-only setup unaffected; token missing → token row shows "—" with
copy/reveal disabled and the QR area hidden.

Regression coverage: `scripts/test-startup-ownership.sh` gained 15 new
assertions — `:3000`/empty/`::`/bracketed-IPv6/missing-port/out-of-range-port
mappings, plus "baseURL always has a host" across seven hostile addr inputs.

## C18 Follow-up: Service Sendability

The client had one remaining split source of truth: chat rows displayed as
iMessage, but thread sendability could still be affected by older per-message
service logic. That path was deleted. The thread badge and composer now both use
`ChatSummary.service`, which is derived only from server-provided
`serviceCategory` / `serviceName` via `chatServiceFromServer`.

Rules:

- iMessage from the server means the composer is enabled, including phone-number
  chats and `any;-;` chat GUIDs.
- SMS and Unknown remain read-only.
- Handle shape, display name, chat GUID shape, and old cached flags are never
  used for sendability.
