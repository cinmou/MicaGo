# CLAUDE.md — working guide

Live notes for Claude when working in this repo. Keep it short; update it as part of any pass.

## What MicaGo is

Three components:

- **Go relay server** — `MicaGoServer/micago-server`. Reads the Mac's Messages DB, exposes a local control + chat API, syncs into `relay.db`, serves chats/messages/delta + WebSocket. Tests: `go test ./...`, `go vet ./...`.
- **macOS Companion** (SwiftUI) — `MicaGoServer/micago-mac-companion`. Menu-bar + dashboard that launches/monitors the server, manages pairing/URLs, sync rules, devices, notifications. Build: `xcodebuild`.
- **Flutter Android client** — `MicaGoFlutterClient`. Pairs over LAN/public URL, syncs, sends, optional FCM push. Checks: `flutter analyze`, `flutter test`, `flutter build apk --debug`.

## Important rules

- **Never commit unless explicitly asked.** Branch first if on `main`.
- **Never log, commit, or expose** bearer tokens, push tokens, or service-account paths. The Companion redacts tokens in captured server stdout (`BackendController.redact`).
- Keep it **lightweight** — no new dependencies without a clear need.
- **Firebase, keep-alive, and IMCore message actions are all optional and off by default.** Don't word docs/UI as if they're required or guaranteed.
- Keep final logs clean (debug-guarded only).
- Companion menu-bar icon must use **template rendering** (no hard-coded colors) so it adapts to light/dark menu bars.
- **Before debugging sync, check the running backend binary's version against source** — a stale binary is a common false lead. Rebuild via `scripts/build-backend.sh`.

## Known UI/state notes

- `serverDisplayState(process:reachable:)` (`BackendController.swift`) is the single source of truth for combined process+reachability state; both the menu-bar icon and the dashboard pill derive from it.
- Sync Control loads four endpoints (`sync/rules`, `sync/settings`, `chats`, `messages/recent`). A failure in any one is what users see as a page error.
- Contacts permission on macOS can only be prompted by the app once (`.notDetermined`); after that it's System-Settings-only. The UI must not offer a dead "Allow" button.

## Changed in this pass (Companion UI/state, C30)

1. **Menu-bar icon** (`MicaGoCompanionApp.swift`): `mica.error` for hard-failure states (not installed, crashed/unreachable); normal `mica` dimmed for inactive/transitional (stopped/starting/stopping); full-strength active for running/external. Template-rendered, no hard-coded colors.
2. **Menu-bar dropdown** (`MenuBarContent.swift`): removed the `LAN:`, `Public:`, and `Messages.app is running` rows. Kept Open Dashboard / Start / Stop (correct enabled state) / Keep Awake / Quit.
3. **Contacts permission** (`SyncControlView.swift`, `ContactsService.swift`): replaced the misleading disabled "Allow Contacts access" button with **Open System Settings** (`ContactsStore.openSystemSettings()`) + guidance that names/photos need permission while raw handles still work.
4. **Sync Control HTTP 500** path: investigated — all four handlers are correct and wired in source (`internal/httpapi`); a live 500 is environmental (commonly a stale binary; rebuild). Made the client resilient: per-endpoint loading (`AppModel.loadSyncControl`) so one failure doesn't blank the page and the error names which call failed; the client now surfaces the server's `{error:{code,message}}` body (`APIClient.validate(_:body:)`) instead of a bare status; and a proper **error card with Retry + Copy diagnostics** (`SyncControlErrorCard`) replaces the small inline line.
