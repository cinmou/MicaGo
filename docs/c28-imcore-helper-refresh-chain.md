# C28 — IMCore helper install + refresh chain

## Problem

After installing the IMCore helper, the Companion/backend kept reporting it as
**unavailable**. Same shape as the old stale-endpoint bug: the state changed on
disk, but the running Go backend served a **cached** capability snapshot.

Root cause: `HelperPerformer.Capabilities` has a 30s TTL cache (added in C26b to
avoid spawning the helper subprocess on every 3s status poll). After an install
the cache held the pre-install "missing" result for up to 30s, so
`/api/server/status` and the capability endpoint reported "unavailable" even
though the helper was now on disk at the path the backend scans.

## Fix — the whole chain

**Backend**
- `HelperPerformer.InvalidateCapabilities()` drops the cached probe so the next
  call re-scans disk + re-runs the helper.
- New `POST /api/messages/actions/refresh` invalidates the cache, re-probes, and
  returns the fresh capabilities. It also broadcasts a `capabilities:updated`
  WS event so connected clients re-check. No backend restart needed — helper
  detection is per-probe (path resolve + subprocess), so a freshly-installed
  binary is picked up the instant the cache is cleared.
- Clear lifecycle **states** on `Capabilities` / `status.messageActions.state`:
  - `missing` — no helper binary found.
  - `not_runnable` — found, but it failed to execute.
  - `unsupported_selectors` — ran, but reports none of edit/unsend/delete.
  - `ready` — usable.
  Both the dedicated endpoint and `/api/server/status` carry it (single source
  of truth, `messageActionCapabilities`).

**Companion**
- `APIClient.refreshMessageActions()` → the new endpoint.
- `installIMCoreHelper()` now: install → **call refresh (force rescan)** →
  reload status → show a state-specific result line. The card flips to "ready"
  with no manual Save/restart.
- **Restart fallback:** if the refresh call fails (an older backend without the
  endpoint), the Companion explicitly restarts the backend (`BackendController
  .shared.restart()`) and reloads status.
- A **Re-scan** button forces a fresh probe without re-installing.
- The card shows the four clear states (icon + headline + reason), not just a
  binary available/unavailable.
- Install path (`~/.micago/bin/micago-imcore-helper`) is exactly the path the
  backend scans (`helperPath()` + `imessage.HelperInstallDir`) — verified
  aligned.

**Flutter**
- Already correct: the long-press menu fetches
  `GET /api/messages/actions/capabilities` **live every time it opens** (no
  client cache), so Edit/Unsend/Delete appear only when the freshly-probed caps
  say so. After reconnect / install / `capabilities:updated`, the next menu open
  reflects the new state immediately. A fetch error defaults to all-false
  (actions hidden, safe). Nothing caches "unavailable" forever. The new `state`
  field is ignored gracefully by the existing parser.

## Stale backend binaries

Detection is per-probe against the install path, so the running backend does not
need to be the one that was running at install time — but if a genuinely stale
binary is launched it won't have the refresh endpoint, which is exactly the
restart-fallback path above. The C17/C26 freshness tooling
(`MICAGO_BACKEND_BIN`, `scripts/debug-backend.sh`,
`restartWithLatestBackend`) remains the way to guarantee the newest binary.

## Tests

- `TestCapabilitiesRescanAfterInstall` — cache holds "missing" after install;
  `InvalidateCapabilities()` makes the next probe report `ready` + all selectors.
- `TestCapabilitiesUnsupportedSelectors` — ran-but-no-selectors → `unsupported`.
- `TestRefreshMessageActionCapabilities` — the endpoint invalidates the cache
  and returns the fresh `ready` state.

## Validation

| Check | Result |
| --- | --- |
| Go build + `internal/imessage` + `internal/httpapi` action tests | ✅ |
| Full Go suite | ✅ except pre-existing env-only `TestSendAttachmentSMSGate` (writes to TCC-protected `~/Library/Messages/Attachments`) |
| Companion `xcodebuild` (Debug) | ✅ BUILD SUCCEEDED |
| Flutter | unchanged this cycle (live-fetch already correct) |

Manual chain: start with no helper → Dashboard shows **missing** + Install →
click Install → helper lands in `~/.micago/bin` → backend rescans → card flips to
**ready** without a Save/restart → `/api/server/status` shows `state: ready` →
the Flutter action menu shows Edit/Unsend/Delete on its next open → restart
Companion/backend → status stays **ready**.
