# C26c — Multi-endpoint selection + IMCore helper install + action-chain verify

Follow-up to [C26b](c26b-reliability-and-cleanup.md). Adds proper multi-LAN
endpoint selection, an IMCore-helper install flow controlled by MicaGo, and an
end-to-end verification (not just code-exists) of the edit/unsend/delete chain.
Parts 3 (endpoint refresh / Public persistence) and 6 (attachment-unavailable)
were already fixed in C26b and are re-verified here.

## 1 + 2 — Multi-LAN: track, show, and switch the active route

Previously a profile stored a **single** LAN URL (`lanBaseUrl`), and refresh
picked `urls.lan.first` — so the app assumed the first discovered interface was
the right route and the Dashboard/Settings showed that, not the one actually in
use.

- **Model.** `ConnectionProfile` now holds `lanRoutes: List<EndpointRef>` (every
  advertised LAN candidate) plus `selectedBaseUrl` (the user's pinned route,
  persisted). `lanBaseUrl`/`lanWsUrl` became getters that resolve to the pinned
  route, else the first. `EndpointRef` is a tiny `{baseUrl, wsUrl}` pair.
- **Candidates.** `connectionCandidatesForProfile` emits **all** LAN routes (+
  Public), and moves the pinned candidate to the front so connect/reconnect try
  it first while keeping the others as fallbacks.
- **Pairing.** `PairingPayload.toProfile()` keeps every LAN candidate from the v3
  payload (the Companion already emits all of them). Onboarding retains the full
  list when building the active profile.
- **Refresh never clobbers the selection.** `_persistEndpointCandidates` stores
  the full LAN list, keeps the active candidate when it still exists, and keeps
  the pin only if its URL is still advertised (otherwise it drops to auto).
- **Switcher UI.** Settings → Connection shows a simple "Server route" picker
  (Automatic + one row per candidate, with the connected one marked). Selecting a
  route calls `AppController.selectRoute(baseUrl)` which persists the pin and
  reconnects through it. Hidden when there's only one candidate.
- **Active endpoint shown.** Settings now shows the **active** server/WebSocket
  URL (`activeCandidate`), not `profile.baseUrl`.

QR/JSON already includes all usable candidates (Companion `pairingPayloadV3`
maps every LAN target + Public) — verified, unchanged.

## 3 — Endpoint refresh + Public persistence (re-verified)

Unchanged from C26b: the loopback-bind migration (`config.Load` upgrades a
pre-C25 `127.0.0.1` bind to `0.0.0.0:3000` and persists it) means LAN appears on
startup without Save; the Companion decoupled `refresh()` + Public-field mirror
keep the saved Public URL across restarts. Covered by the existing Go tests.

## 4 — IMCore helper install flow (MicaGo-controlled)

The helper that performs edit/unsend/delete is detected on startup via the
server capability probe (C26b) and surfaced in the Companion's **Message
Actions** card. C26c adds the install flow:

- **Stable install location.** The backend's `helperPath()` now also scans
  `~/.micago/bin/` (exposed as `imessage.HelperInstallDir`), so a helper MicaGo
  installs is picked up without re-bundling the backend.
- **Install action.** `IMCoreHelperInstaller.install()` copies a bundled helper
  into `~/.micago/bin`, marks it executable, and the card refreshes. The
  **Install helper** button appears in the card whenever the helper is
  unavailable; a spinner + result line report the outcome.
- **Honest when absent.** If a build ships no helper component, install reports
  that plainly instead of faking success — the capability stays `available:false`
  and Flutter keeps Edit/Unsend/Delete hidden. Users never install
  imsg/imsgbridge by hand.

## 5 — Edit / Unsend / Delete chain (verified end-to-end)

Each link was traced, not just confirmed to exist:

| Link | Status |
| --- | --- |
| Helper detection (Companion/startup) | capability probe + status block + Install button |
| Backend capability endpoint + status | `GET /api/messages/actions/capabilities` + `status.messageActions` (shared source) |
| Backend action endpoints | `POST …/edit`, `POST …/retract`, `DELETE …/{messageGuid}` (router-wired) |
| Flutter long-press menu | items gated on `caps.edit/retract/delete` (absent when unavailable) |
| Action request | `ApiClient.editMessage/retractMessage/deleteMessage` hit the matching paths |
| Success / error handling | `_runMessageAction` → success snackbar / `ApiException.friendly` |
| State refresh after action | client `onChanged` reloads the thread; server `syncAfterMessageAction` → sync → WS event |

A missing helper makes the action endpoints return `501 unsupported` and the
menu items never render — no fake success anywhere. No broken links found.

## 6 — Attachment-unavailable (re-verified)

Unchanged from C26b: `missing_attachment_rows` / `empty_edited_residue` render as
an unsent/retracted system row ("You unsent a message" / "{Sender} unsent a
message"), never a broken file card; raw reason kept for Message Info.

## Tests

- Go: `TestHelperPathFindsInstalledBinary`, `TestHelperInstallDir` (install loop);
  plus the C26b `TestLoopbackBindMigratesToLAN`, `TestPublicURLSurvivesRestart`,
  message-action capability tests.
- Flutter: multi-LAN model tests (all LAN routes become candidates; pin ordering;
  stale-pin fallback) in `models_test`; existing pairing/connection-notice/
  attachment tests still green.

## Validation

| Check | Result |
| --- | --- |
| Go `build` + targeted tests | ✅ (pre-existing `TestSendAttachmentSMSGate` still fails — writes to TCC-protected `~/Library/Messages/Attachments`, environmental) |
| Companion `xcodebuild` (Debug) | ✅ BUILD SUCCEEDED |
| `flutter analyze lib test` | ✅ No issues |
| `flutter test` | ✅ |
| debug APK | ✅ |
| Multiple LAN endpoints discovered + selectable + persisted | ✅ |
| Reconnect uses the selected route | ✅ (pinned candidate first) |
| Dashboard/Settings shows the active endpoint | ✅ |
| Helper missing detected on startup + Install button shown | ✅ |
| Edit/Unsend/Delete only when helper available | ✅ |
| Full action chain verified | ✅ |
