# MicaGoServer Project Status

Dynamic status across versions/areas. **Update this whenever a milestone changes
state.** Read [`README.md`](README.md) first, then this, then
[`CURRENT_PLAN.md`](CURRENT_PLAN.md).

Status legend:
- **Done** — implemented and unit-tested (and where applicable smoke/live tested).
- **In validation** — implemented and builds/tests pass locally, but not yet
  fully live-verified end-to-end (and, in this checkout, not yet committed).
- **Planned** — designed/queued, not implemented.
- **Deferred** — intentionally postponed.

> Snapshot note: the Go server (v0.1–v0.9, v0.11) and the SwiftUI companion
> (v0.10, v0.11 UI) currently exist in the working tree. Per this project's
> workflow, changes are committed only when the user asks, so most of this is
> **untracked locally** rather than pushed. `git status` will show
> `MicaGoServer/` untracked.

## Server + companion milestones

| Version / Area | Status | Scope | Key files | Tests / verification | Source of truth | Next action |
| --- | --- | --- | --- | --- | --- | --- |
| **v0.1 — initial server** | Done | Read-only `chat.db` HTTP API; chats + recent messages; Apple-epoch conversion. | `cmd/micago/`, `internal/app/`, `internal/config/`, `internal/store/{db,queries,models,text}.go`, `internal/timeutil/` | `go test ./...` (config, store, timeutil) | [`spec-v0.1.md`](spec-v0.1.md) | None. |
| **v0.1.1 — live test** | Done | iMessage-default view; `service` + `includeEmpty` filters; live epoch fix. | `internal/store/queries.go`, `internal/httpapi/handlers.go` | unit tests; `scripts/smoke-v0.1.1.sh`; **live-tested** | [`spec-v0.1.1.md`](spec-v0.1.1.md), report: [`v0.1.1-live-test-report.md`](v0.1.1-live-test-report.md) | None. |
| **v0.2.0 — relaydb** | Done | `relay.db` bootstrap, schema, one-way sync skeleton (clean iMessage subset). | `internal/relaydb/{db,migrations,sync,models}.go` | `relaydb` unit tests | [`spec-v0.2.0-relaydb.md`](spec-v0.2.0-relaydb.md) | None. |
| **v0.2.1 — incremental sync** | Done | Incremental import via `source_rowid`; idempotent `--sync-once`. | `internal/relaydb/sync.go`, `migrations.go` | unit tests; `scripts/smoke-v0.2.1-incremental-sync.sh` | [`spec-v0.2.1-incremental-sync.md`](spec-v0.2.1-incremental-sync.md) | None. |
| **v0.2.2 / v0.2.3 — relay API + periodic sync** | Done | API reads default to `relay.db`; periodic sync loop; `--api-store relaydb\|chatdb`. | `internal/app/app.go`, `internal/relaydb/query.go` | unit tests; `scripts/smoke-v0.2.2-v0.2.3.sh` | [`spec-v0.2.2-v0.2.3-relay-api-sync.md`](spec-v0.2.2-v0.2.3-relay-api-sync.md) | None. |
| **v0.3.0 — send** | Done | Plain-text send to an existing iMessage chat via AppleScript + DB confirmation. | `internal/send/{applescript,manager,pending,normalize,sender}.go`, `handlers.go` (`SendText`) | `send` unit tests; `scripts/smoke-v0.3.0-send.sh` | [`spec-v0.3.0-send.md`](spec-v0.3.0-send.md) | Live-verify send on a real Mac when convenient. |
| **v0.3.1 — text extraction** | Done | Recover text from `attributedBody` when `text` is NULL (send-confirmation + reads). | `internal/store/text.go`, `internal/relaydb/sync.go` | `store/text_test.go`; `scripts/inspect-v0.3.0-send-text.sh` | [`spec-v0.3.1-text-extraction-fix.md`](spec-v0.3.1-text-extraction-fix.md) | None. |
| **v0.4 — WebSocket** | Done | Plain `GET /ws`; events `message:new`, `send:match`, `send:error`, `sync:error`. No Socket.IO. | `internal/realtime/{hub,event}.go`, `router.go` | `realtime` unit tests; `scripts/smoke-v0.4.0-websocket.sh` | [`spec-v0.4.0-websocket.md`](spec-v0.4.0-websocket.md) | None. |
| **v0.5 — attachments** | Done | Attachment metadata in `relay.db`; safe path-checked download stream. | `internal/relaydb/` (attachments), `handlers.go` (`GetAttachment`) | unit tests; `scripts/smoke-v0.5.0-attachments.sh` | [`spec-v0.5.0-attachments.md`](spec-v0.5.0-attachments.md) | None. |
| **v0.6 — security** | Done | Bearer-token auth for all `/api` (except health) + `/ws`; localhost-only `--disable-auth`. | `internal/httpapi/auth.go`, `internal/config/config.go` | `auth_test.go`; `scripts/smoke-v0.6-security.sh` | [`spec-v0.6.0-security.md`](spec-v0.6.0-security.md) | None. |
| **v0.7 — device registry** | Done | Register/list/patch/heartbeat/delete devices; token never returned (`pushTokenSet`). | `internal/relaydb/devices.go`, `handlers.go`, `store/models.go` | `handlers_test.go`, `relaydb` tests; `scripts/smoke-v0.7-devices.sh` | [`spec-v0.7.0-device-registry.md`](spec-v0.7.0-device-registry.md) | None. |
| **v0.8 — notification provider** | Done (webhook); stubs Deferred | Provider abstraction; `none`+`webhook` deliver; `fcm`/`hms`/`harmony_push`/`ntfy` are stubs (`501`). | `internal/notify/*` | `notify/dispatcher_test.go`; `scripts/smoke-v0.8-notify.sh` | [`spec-v0.8.0-notification-provider.md`](spec-v0.8.0-notification-provider.md) | Real FCM/HMS delivery tracked in v0.12. |
| **v0.9 — client API / server status** | Done | Canonical client API contract; `GET /api/server/status` (version, sync, notifications, devices, permission diagnostics); version → `0.11.0`. | `spec`; `handlers.go` (`GetServerStatus`), `store/models.go` (`ServerStatusResponse`) | `handlers_test.go` (`TestGetServerStatus*`) | [`spec-v0.9.0-client-api-contract.md`](spec-v0.9.0-client-api-contract.md); gap: [`v0.9.0-gap-analysis.md`](v0.9.0-gap-analysis.md) | None. |
| **v0.10 — SwiftUI macOS companion** | In validation | Native controller: start/stop/restart server, status, endpoints, token + QR, devices, provider status, permission diagnostics, Launch-at-Login. No chat UI, no WebUI. | `micago-mac-companion/` (Xcode project + `MicaGoCompanion/*`) | `xcodebuild … build` succeeds | [`spec-v0.10.0-mac-companion.md`](spec-v0.10.0-mac-companion.md) | Manual test in Xcode per spec; verify Launch-at-Login from a built app. |
| **v0.10.1 — companion redesign (sidebar)** | In progress | Slice 1 done: `NavigationSplitView` shell (Dashboard, Connections, Devices, Notifications, Permissions, Server, Logs, Advanced), persistent status chip, runtime card, capabilities display. Later slices flesh out remaining pages. | companion `ContentView.swift`, `MicaGoCompanionApp.swift`, `Services/RuntimeStatus.swift`, `Models/StatusModels.swift` | `xcodebuild … build` succeeds | [`spec-v0.10.1-swiftui-companion-redesign.md`](spec-v0.10.1-swiftui-companion-redesign.md) | Continue redesign after v0.11.2 runtime work, or interleave. |
| **v0.11 — connection endpoints / public URL** | In validation | Aggregated endpoints (local + LAN always-on; optional public); `GET /api/server/urls`, `POST /api/server/public-url`, `…/check`; `network.*` config; companion "Connection Endpoints" + QR endpoint picker. | `internal/config/config.go` (network), `internal/httpapi/urls.go`, companion `Models/ConnectionModels.swift` + UI | `urls_test.go` (9 tests); `go test ./...` green; `xcodebuild` green | [`spec-v0.11.0-connection-endpoints.md`](spec-v0.11.0-connection-endpoints.md) | Live-verify `/api/server/urls` and a real public URL (e.g. Cloudflare Tunnel) end-to-end; then commit. |
| **v0.11.x — server reliability** | In validation | Schema probing + `capabilities`; bounded lookback update pass + event-state cache (`message:update`/`message:unsend`); send-error fast-fail via `message.error`; Messages.app-running precondition; companion runtime UX (Messages status, Keep-Awake, FDA/Automation summary). Group/system `chat:event` **deferred**. | `internal/store/{capabilities,fingerprint,queries}.go`, `internal/relaydb/updatepass.go`, `internal/send/messages.go`, `internal/httpapi/handlers.go`; companion `Services/RuntimeStatus.swift` + `ContentView.swift` | unit tests (capabilities, update pass, fast-fail, messages-precondition); `go test ./...` green; `xcodebuild` green | [`spec-v0.11.x-server-reliability.md`](spec-v0.11.x-server-reliability.md), cross-check [`v0.11.x-reliability-crosscheck.md`](v0.11.x-reliability-crosscheck.md) | Live-verify on a Mac with FDA; then close and start v0.12. Commits: `38205fc`, `f8d2185`, `9cee7ed`, + this runtime pass. |
| **v0.11.2 — companion runtime & deployment** | Done (manual tests passed) | Bundled Go backend (Run Script build phase → `Contents/Resources/micago`); companion-owned process manager (`BackendController`) with start/stop/restart, state machine + exit classification, auto-restart w/ backoff; launch-at-login, auto-start, silent launch; **menu-bar item** (`MenuBarExtra`); clear **Full Disk Access** banner; external/unmanaged detection; log token-redaction. No Go changes. | companion `Services/BackendController.swift`, `MenuBarContent.swift`, `MicaGoCompanionApp.swift` (AppDelegate), `ContentView.swift`; `project.pbxproj` (build phase + script sandboxing off) | `xcodebuild … build` succeeds; bundled binary verified; manual tests 1–10 passed | [`spec-v0.11.2-companion-runtime-deployment.md`](spec-v0.11.2-companion-runtime-deployment.md) | Commit when ready; then do v0.11.2.1 polish. |
| **v0.11.2.1 — hide Dock icon / menu-bar-only** | Planned (next, small) | A `hideDockIcon` setting toggling `.accessory`/`.regular` activation policy: hide the Dock icon while menu-bar-only, keep the menu-bar item, always restore the Dashboard on demand, return to accessory on window close. Must not break silent launch / login / auto-start / auto-restart / Keep Awake / external detection / Dashboard. | companion `MicaGoCompanionApp.swift` (AppDelegate policy helper), `BackendController` settings, Advanced page toggle | TBD | [`spec-v0.11.2-companion-runtime-deployment.md`](spec-v0.11.2-companion-runtime-deployment.md) → "v0.11.2.1 Polish follow-up" | Do before v0.11.3. |
| **v0.11.3 — sync control / privacy rules** | Planned | Per-chat / per-handle **sync allow/block** + **push enable/mute** rules (whitelist/blacklist + default policy); Sync Control + management-only Recent Messages view. **Future-sync-only first; no historical `relay.db` deletion.** | (new) `relay.db` `sync_rules` table + rule store/evaluator; `internal/relaydb` sync/dispatch gating; `/api/sync/rules`/`policy`; companion Sync Control pages | TBD | [`spec-v0.11.3-sync-control-and-privacy-rules.md`](spec-v0.11.3-sync-control-and-privacy-rules.md) | After v0.11.2.1. |
| **v0.11.4 — contacts enrichment** | Planned | Read-only, **local-only** macOS Contacts (`Contacts.framework`) to map handle addresses → names for rule editing; optional; never uploaded; core server independent of it. | companion-only: `Contacts.framework`, normalization, local cache | TBD | [`spec-v0.11.4-contacts-enrichment.md`](spec-v0.11.4-contacts-enrichment.md) | After v0.11.3. |
| **v0.12 — Firebase self-host push + URL sync** | Planned (after v0.11.4) | Implement `fcm` provider (service-account OAuth2 + FCM HTTP v1 multicast, TTL, token pruning, `previewMode`); optional Firestore **public-URL-only** sync; push gated by v0.11.3 rules. Strict privacy (no content/contacts/numbers/tokens-in-public-docs/attachments/history). | (new) `internal/notify/fcm`, optional Firestore URL writer, `POST /api/server/notifications`; companion Notifications setup | TBD | [`spec-v0.12.0-firebase-self-host.md`](spec-v0.12.0-firebase-self-host.md) | After v0.11.4. |
| **v0.13 — scheduled sending** | Deferred | Scheduled text sends; `relay.db` `scheduled_messages` table; restart/sleep reconciliation; Messages.app/Automation preconditions; conservative retry; anti-misfire confirmation. | (new) `relay.db` `scheduled_messages`, scheduler service, `/api/scheduled` CRUD; companion Scheduled page | TBD | [`spec-v0.13.0-scheduled-sending.md`](spec-v0.13.0-scheduled-sending.md) | Sequenced last (after v0.12). |

## Cross-cutting guardrails (always apply)

Never add (per [`micago-feature-decision-matrix.md`](micago-feature-decision-matrix.md)
and repeated user direction): BlueBubbles client/server compatibility, Socket.IO,
a WebUI/admin page, Electron, React/Vue, private-API helpers, a Mica-operated
cloud relay, or Firebase storage of message content/contacts/phone
numbers/bearer tokens/attachments/chat history. Do not embed Tailscale; do not
bundle/manage `cloudflared`/`ngrok`.

## Docs & process notes (suggested fixes, not yet applied)

1. **Stale agent instructions.** [`CLAUDE.md`](CLAUDE.md) and
   [`AGENTS.md`](AGENTS.md) describe a gVisor/web container with a mandatory
   "checkpoint + commit + push after every step" workflow. This project is a
   **local macOS** checkout where work is committed **only when the user asks**.
   *Suggested fix:* rewrite both to describe the real env (local macOS, repo-local
   `GOCACHE`, `xcodebuild`, commit-on-request) or clearly mark them
   `Codex web only` / `Claude web only`. Not done here to avoid overstepping the
   "docs consolidation, no behavior change" scope.
2. **Stale CHANGELOG.** `micago-server/CHANGELOG.md` only covers v0.1.1.
   *Suggested fix:* either maintain it through v0.11 or replace it with a pointer
   to this file. (This table is the authoritative status; the CHANGELOG is not.)
3. **Old absolute paths.** Some historical reports/audits reference
   `…/GitHub/MicaGoServer/…` (an earlier path); the repo now lives at
   `…/GitHub/MicaGo/MicaGoServer/…`. Harmless, historical — leave as-is.
4. **Folder reorg.** The `docs/specs|audits|reports|agents/` layout proposed in
   [`README.md`](README.md) is not applied; do it as a link-checked pass.
