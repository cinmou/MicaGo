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
| **v0.11 — connection endpoints / public URL** | In validation | Aggregated endpoints (local + LAN always-on; optional public); `GET /api/server/urls`, `POST /api/server/public-url`, `…/check`; `network.*` config; companion "Connection Endpoints" + QR endpoint picker. | `internal/config/config.go` (network), `internal/httpapi/urls.go`, companion `Models/ConnectionModels.swift` + UI | `urls_test.go` (9 tests); `go test ./...` green; `xcodebuild` green | [`spec-v0.11.0-connection-endpoints.md`](spec-v0.11.0-connection-endpoints.md) | Live-verify `/api/server/urls` and a real public URL (e.g. Cloudflare Tunnel) end-to-end; then commit. |
| **v0.12 — Firebase self-host push + URL sync** | Planned | Self-hosted Firebase: real FCM push delivery; optional Firestore sync of the **public URL only**. Strict privacy (no content/contacts/numbers/tokens/attachments/history). | (new) `internal/notify/fcm_*`, optional `internal/notify`/config for Firestore URL sync | TBD | [`CURRENT_PLAN.md`](CURRENT_PLAN.md) (spec to be written: `spec-v0.12.0-firebase-self-host.md`) | Write the v0.12 spec, then implement FCM delivery first. |

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
