# C23 — Companion UI cleanup + unified client connection flow

Focused cleanup of the macOS Companion plus a single unified connection flow
across server / client. Keeps the WebSocket + delta-cursor model; FCM unchanged.

## 1. Build / displayVersion
`displayVersion(_:)` lives in `Services/VersionFormat.swift` and is the **single**
version formatter — it trims, collapses any run of leading `v`/`V` to exactly one
`v`, and maps empty → `v?`. The Companion project uses a synchronized folder
group, so the file is compiled and visible to `ContentView` (the "not visible"
concern was stale). Covered by a standalone `swiftc` test
(`scripts/tests/main.swift`): `v0.15.0` / `0.15.0` / `vv0.15.0` / `  V0.15.0 `
all → `v0.15.0`.

## 2–4. Dashboard cleanup + declutter (Companion)
- **Merged Status + Remote Tunnel** into one `ServerRemoteCard` ("Server & Remote
  Access"): lean server state (status dot, label, version·uptime, failure/restart
  notes) + the tunnel chip/controls/toggles. The read-only Store / Sync / WebSocket-
  clients rows were removed from the Dashboard.
- The **live sync monitor** (a diagnostic) moved off the Dashboard into **Advanced**.
- **One canonical pairing card** — `CreateConnectionCard` ("Create Connection"):
  a QR code, a **Copy connection JSON** button, and a small status line
  (`LAN` / `Public` / `Token` capability flags). No mode picker, no long
  explanations; per-endpoint rows are in an opt-in "Connection detail" disclosure.
  The old bloated `ClientSetupSection` (mode picker + LAN dropdown + Base/WS/Public
  rows) was deleted. It was the only pairing card — there were no sidebar/Collection
  duplicates to remove.
- Dashboard is now just: FDA banner (when needed) → Server & Remote Access →
  Create Connection → Paired Devices.

## 3 / 5. Log split from Debug (Companion)
Sidebar is now **Dashboard · Connections · Sync Control · Debug · Log ·
Notifications · Tutorials · Advanced**. **Debug** holds debugging tools (Message
Inspector); **Log** holds the server log only (`LogsPage` moved out of Debug). No
duplicate logs.

## 5–7. Unified connection flow (server + client)

### One payload (v3), no manual mode
The Companion now emits a single unified payload (`AppModel.pairingPayloadV3`):
```json
{ "version": 3, "token": "…", "serverName": "Mac mini",
  "configRevision": "abc123def456",
  "candidates": [
    {"kind":"lan","baseUrl":"http://192.168.1.23:3000","wsUrl":"ws://…","priority":1},
    {"kind":"public","baseUrl":"https://…","wsUrl":"wss://…","priority":2}
  ] }
```
It always includes **all** candidates (every LAN endpoint + Public when
configured) — there is no LAN-only vs LAN+Public mode. The client decides:
**LAN first, Public fallback**, automatically.

### Client: scan or paste, auto-select
- `parsePairingPayload` gained a `_parseV3` branch (v1/v2 still parse for
  back-compat). Because it parses any JSON string, **pasting** the connection JSON
  goes through the exact same path as scanning — the QR pairing screen now offers
  a **"Paste connection JSON"** action (clipboard-prefilled dialog) and the stale
  hint points at Dashboard → Create Connection.
- `offeredModes` returns empty for v3, so the **LAN-only vs LAN+Public picker is
  never shown**. The onboarding tests candidates in order (LAN→Public) and
  activates the first reachable one — the existing auto-select path.
- The profile stores the full candidate list + `configRevision`
  (`ConnectionProfile.configRevision`, round-tripped through JSON).

### Connection-config sync after pairing (revision)
- Server: `GET /api/server/urls` now returns `connectionRevision` — a short,
  **stateless** sha256 hash of the LAN/Public endpoints. Same settings → same
  revision; any LAN/Public change → new revision.
- On a change via `POST /api/server/public-url`, the server broadcasts a
  `connection:updated` WS event carrying the new revision.
- Client: `_persistEndpointCandidates` already refreshed candidates from
  `/api/server/urls` on every connect; it now also stores the revision and
  **skips the rebuild when the revision is unchanged**. `AppController` subscribes
  to `connection:updated` and refreshes immediately. Net effect: **changing the
  server's LAN/Public settings updates connected clients without rescanning**, as
  long as one existing candidate is still reachable. Scope is connection
  candidates only — not general settings sync. Delta sync/cursor untouched.

## Tests
- Swift: `displayVersion` normalization (standalone `swiftc` harness).
- Go: `TestConnectionRevisionChangesWithSettings` (stable vs changed LAN/Public),
  `TestBuildServerURLsIncludesRevision`.
- Flutter (`pairing_v3_test.dart`): v3 parses LAN+Public with no mode; LAN-only
  works; pasted JSON imports like a scan; `toProfile` stores all candidates +
  revision (JSON round-trip); auto-selects LAN then Public. Existing v1/v2 pairing
  tests still pass.

## Validation
| Check | Result |
| --- | --- |
| Companion builds | ✅ BUILD SUCCEEDED |
| Go tests pass | ✅ |
| Flutter tests pass | ✅ 247 |
| APK builds | ✅ |
| QR scan still works | ✅ (v3 parse; v1/v2 back-compat) |
| Paste connection JSON works | ✅ same parser path |
| No LAN-only vs LAN+Public manual prompt | ✅ `offeredModes` empty for v3 |
| Server LAN/Public change updates clients without rescan | ✅ revision + `connection:updated` + urls refresh |
| Dashboard cleaner; Status + Remote Tunnel merged | ✅ `ServerRemoteCard` |
| Log separate from Debug | ✅ new Log sidebar item |
| One canonical Create Connection card | ✅ `CreateConnectionCard` |

---

## C23 regression fix — LAN is independent; Public is optional

A follow-up that fully separates LAN and Public so Public can never block LAN.

### Core rule
- **LAN / local is the primary, always-available path.** A missing Public URL
  never blocks backend start, LAN status, the LAN QR / pairing payload, the
  Connections page, client setup, connection-JSON copy, QR generation, or paired
  operation over LAN.
- **Public / Remote is an optional add-on.** When configured it's included as an
  extra candidate and used as a fallback; it never replaces or gates LAN.

### What changed
- **Dashboard "Status" card** (was "Server & Remote Access"): now two clearly
  separated sections.
  - **Server** — running/stopped, LAN address (when bound to LAN), version·uptime,
    failure/restart notes. Always shown, never gated on Public.
  - **Remote** — tunnel/public status, Public URL (when configured), tunnel
    Start/Stop/Restart + Validate, and auto-start toggles. When there's no public
    endpoint and no tunnel it shows **"Not configured"** with a one-line note that
    LAN pairing still works. Concise; the long explanatory paragraphs were removed.
- **Unified payload is candidate-generic and LAN-independent.** Extracted a pure
  `unifiedConnectionPayload(lan:publicCandidate:…)` (`Services/ConnectionPayload.swift`)
  that produces a valid payload for **LAN-only**, **LAN+Public**, **Public-only**,
  and an empty `{}` for none (the Create Connection card shows an empty state in
  that case rather than copying `{}`). Candidates are tagged `kind: "lan" |
  "public"`; the client decides selection. There is no LAN-only vs LAN+Public mode.
- **Create Connection** already required only `LAN or Public` (not Public) — QR and
  Copy JSON work LAN-only; verified + covered by tests.
- **Connections page** lists Local / LAN / Public independently; LAN controls are
  never disabled when Public is missing (Public is labelled "Optional and
  external"). No guard removed was needed — confirmed by audit.
- **Client (Flutter)** treats the candidate list generically: one candidate → use
  it; LAN+Public → LAN first, Public fallback; Public missing → no fallback but
  still valid; paste/scan never require a Public candidate.

### Tests
- Swift (`scripts/tests/main.swift`, run via `swiftc`): `unifiedConnectionPayload`
  for LAN-only (one `lan`, carries token), LAN+Public (`lan` then `public`),
  Public-only (one `public`), none (`{}`), and redaction.
- Go: `TestBuildServerURLsLanOnlyHasNoPublic` (LAN endpoints + revision present,
  Public disabled), plus the existing revision tests.
- Flutter (`pairing_v3_test.dart`): LAN-only profile → single LAN candidate;
  Public-only payload parses + selects Public; LAN+Public still works; paste works
  without Public.

### Validation
| Check | Result |
| --- | --- |
| No Public configured → Status shows Server working + Remote "Not configured" | ✅ |
| Create Connection shows QR + Copy JSON from the LAN candidate alone | ✅ |
| Android connects via LAN-only QR/paste | ✅ (parser + candidate tests) |
| Connections page usable without Public | ✅ (independent sections) |
| Add Public later → payload includes it; revision sync updates clients | ✅ |
| Remove Public again → LAN keeps working | ✅ (LAN candidate tried first) |
| Companion build · Go tests · Flutter tests · APK | ✅ |

---

## C23 follow-up cleanup — sidebar, Advanced, Dashboard, obsolete UI

A focused tidy-up (no new features).

### Sidebar order
Debug and Log are technical tools, so they now sit **below** Advanced:
**Dashboard · Connections · Sync Control · Notifications · Tutorials · Advanced ·
Debug · Log**.

### Advanced page
- **General Settings** — the old "Startup & Lifecycle" and "Launch at Login"
  sections were merged into one section (startup/lifecycle + login-at-launch).
  `LaunchAtLoginSection` became a content-only `LaunchAtLoginControls` so it lives
  inside the merged card; no duplicate headings.
- The ambiguous **"Configuration"** card was renamed **"Files & Paths"** and the
  connection-related rows (Preferred pairing, Verify TLS) were **removed** — those
  belong on the Connections page. Advanced no longer displays or edits connection
  fields. It now shows only backend/file paths.
- The **Live Sync Monitor** moved off Advanced.

### Dashboard (now three concise cards)
1. **Status** — Server (LAN, primary) + Remote (public/tunnel, optional;
   "Not configured" when absent). LAN works without Public.
2. **Live Sync Monitor** — sync health/activity (moved back from Advanced).
3. **Create Connection** — QR + Copy connection JSON; LAN-only works, Public is an
   optional fallback.

### Obsolete UI / state removed
- Companion `AppModel`: deleted the unused `pairingMode` (lanOnly/lanFirst),
  `selectedPairingBaseURL`, `selectedPairingTarget`, `ensureValidPairingSelection`,
  `defaultPairingBaseURL`, and `tokenRevealed` — all dead after the v3 unified
  payload (which includes every candidate, no manual mode/selection).
- Flutter: removed the **LAN-only vs LAN+Public mode picker** from the pairing
  preview and the now-dead `selectedMode` / `availableModes` / `chooseMode`
  plumbing in `PairingController` and the `connectionModeLabel` helper. v1/v2
  payloads still parse for back-compat; they just use their default (LAN-first).
- The Companion device-card `modeLabel` ("LAN" / "LAN + Public") is **not** this
  obsolete state — it reports how a *paired device* connected, and is kept.

### Naming
Status (main card) · Server (backend/local) · Remote (tunnel/public) ·
Connections (config page) · Create Connection (QR/JSON) · General Settings
(lifecycle/login) · Debug (Message Inspector) · Log (server logs). No more
"Server & Remote Access" / ambiguous "Configuration" labels.

### LAN/Public rule preserved
LAN remains independent and primary; Public/Remote stays optional and never
blocks LAN pairing, QR/JSON generation, the Connections page, Dashboard status, or
client operation over LAN. Covered by the existing Swift `unifiedConnectionPayload`
tests (LAN-only / both / public-only / empty), the Go LAN-only URLs test, and the
Flutter v3 parse tests (LAN-only and public-only).

---

## C23 implementation pass — paste-first manual setup + reconnect grace

Final connection model:

- **LAN is independent.** LAN/local controls, Sync Control/Collections, QR
  generation, and copied connection JSON do not depend on a Public URL.
- **Public is optional.** It is an extra remote endpoint used only when configured;
  empty Public is displayed as "Not configured" and never presented as a LAN
  prerequisite.
- **Normal Android setup is QR or pasted connection JSON.** Both paths use the
  same v3 unified payload parser and produce the same candidate model.
- **Low-level manual URL entry is advanced only.** The advanced editor asks for a
  Public origin, optional LAN origin, and token, then derives HTTP/WebSocket
  candidates automatically. Normal users no longer type a WebSocket URL.
- **Cold start/resume reconnect is quiet first.** The Android client suppresses
  sticky disconnect/server-unavailable banners during the initial reconnect grace
  window, then shows the normal warning only after the first attempt fails. Active
  in-use disconnects still show warnings.
