# C27 — Companion UI cleanup, version consistency, helper install

Companion-focused cleanup pass. Builds on the C28 helper refresh chain.

## 1 — Version consistency

- **Companion app version** bumped `MARKETING_VERSION` 0.10.0 → **0.26.0** to
  match the backend `internal/version.Version` (`v0.26.0`). `/api/server/status`
  and `micago --version` already derive from that single constant.
- **Stale cached backend can no longer be launched.** `BackendController
  .resolveBinary()` previously chose the **newest-by-mtime** of the bundled
  binary and the cached `~/.micago/bin/micago` dev build — so an old cached
  binary with a recent mtime could silently run, showing an out-of-date version.
  It now **always prefers the bundled binary** (the exact build the app ships
  with); the cache is only a fallback when no bundled binary exists. Local
  backend development still uses the explicit `MICAGO_BACKEND_BIN` env override or
  the binary-path override, which are unaffected.

Net: Companion, bundled backend, the running server (`/api/server/status`), and
`micago --version` all report the same current version.

## 2 — IMCore helper install

The install flow (C26c/C28) is wired end-to-end and the prior Swift errors are
gone (the Companion builds clean). This pass finishes the **state display**:

- The Message Actions card shows all five clear states:
  **installing** (spinner + "Installing…") · **missing** · **not_runnable**
  (installed but won't run) · **unsupported_selectors** (runs, wrong macOS) ·
  **ready**. Driven by `status.messageActions.state` (+ `helperInstalling`).
- Install → force backend rescan (`POST /api/messages/actions/refresh`) → reload
  status, with a restart fallback for older backends (C28). A **Re-scan** button
  re-probes without re-installing.

**Honest limitation:** no IMCore helper *binary* ships in the app bundle yet
(the repo has only reference material in `Ref/imsg`, which we must not require).
So Install currently lands on the "this build doesn't include the helper
component" result rather than enabling edit/unsend/delete — by design, never a
fake success. Everything downstream (rescan, state reporting, capability gating)
is wired so it works the moment a real helper binary is bundled.

## 3 — Dashboard Status: all VISIBLE LAN addresses

The Status → Server card showed only `urls.lan.first`. It now lists **every**
LAN address (the first interface isn't necessarily the right route, and a Mac can
be reachable on several) — **excluding the endpoints the user hid** in
Connections.

- A new `AppModel.visibleLANEndpoints` filters `urls.lan` by `hiddenLANBaseURLs`.
  The Dashboard uses it; the full list (with hide/unhide/reset) stays only in
  Connections → Connection Endpoints.
- The QR/JSON pairing payload already excluded hidden endpoints (it is built from
  `pairingTargets`, which filters `hiddenLANBaseURLs`), so paired clients receive
  only visible candidates — hidden endpoints never become the preferred/default
  route. Hiding remains a Companion-side pairing/display filter; it doesn't alter
  the server's networking.
- **Reset hidden LAN endpoints** (Connections) clears the set, so the address
  reappears on the Dashboard and in the QR immediately.

## 4 + 5 — Removed duplicate/conflicting UI; one Public-URL source of truth

- **Removed** the Dashboard "Connection detail (token hidden)" disclosure from
  Create Connection (the QR + Copy JSON already cover it).
- **Public URL has one source of truth: Connections → Public.** The Dashboard
  Status "Remote" section kept only the tunnel (cloudflared) status + Start/Stop/
  Restart controls; its duplicate **Validate** button and validation message were
  removed.
- Within the Connections Public editor, the two competing status displays
  (a static "Public status" reachability line **and** the validation-result
  label) are merged into **one** `publicStatusLine` — it shows the detailed last
  validation result when present, else the server's cached reachability.
- **Advanced** no longer duplicates the backend-binary detail: the stale-binary
  warning and the binary source/path rows in "Files & Paths" lived twice — they
  now appear once, in the **Backend Build** card (which owns version/freshness).
  "Files & Paths" keeps the config path + the editable binary-override picker.

## 6 — Simplicity

No new panels were added; this pass only deletes duplicated UI and consolidates
status into single sources. Backend/helper details remain only where they help
(Backend Build for freshness, Message Actions for the helper, Connections for
Public URL).

## Validation

| Check | Result |
| --- | --- |
| Companion `xcodebuild` (Debug) | ✅ BUILD SUCCEEDED (no Swift errors) |
| Install Helper button wired (install → rescan → state) | ✅ |
| Helper status refreshes after install | ✅ (C28 chain) |
| All LAN addresses in Dashboard Status | ✅ |
| Public URL status not duplicated | ✅ (single `publicStatusLine`; dashboard dup removed) |
| Version display consistent | ✅ (MARKETING_VERSION = backend; bundled preferred) |
| Go build + tests | ✅ except pre-existing env-only `TestSendAttachmentSMSGate` |
