# MicaGoServer Documentation Index

This folder is the documentation home for **MicaGoServer**, a lightweight,
Mica-native, Go iMessage relay server plus a native macOS SwiftUI companion app.

If you are a future Claude/Codex session, **start here**, then read
[`PROJECT_STATUS.md`](PROJECT_STATUS.md) and [`CURRENT_PLAN.md`](CURRENT_PLAN.md)
before touching code.

> ⚠️ **Workspace-instruction conflict (read this first).**
> [`CLAUDE.md`](CLAUDE.md) and [`AGENTS.md`](AGENTS.md) in this folder are
> generic "Workspace" templates describing a **gVisor/Ubuntu web container** with
> a *"create checkpoint.md, commit, and push after every step"* workflow and
> internet-via-proxy notes. **That does not match how this project is actually
> being worked on**, which is a **local macOS** checkout where:
> - changes are reviewed locally and **committed only when the user asks**
>   (nothing here is auto-committed/pushed);
> - the Go tests run with a repo-local `GOCACHE` (`.gocache/`), and the SwiftUI
>   app is built with the **real local Xcode** (`xcodebuild`);
> - there is no gVisor container, proxy, or DoH requirement.
>
> Treat `CLAUDE.md`/`AGENTS.md` as **stale/non-authoritative** for environment
> and git workflow. Follow the user's actual instructions and this index
> instead. See [`PROJECT_STATUS.md`](PROJECT_STATUS.md) → "Docs & process notes"
> for the suggested fix.

## Recommended reading order (for a new agent)

1. **[`README.md`](README.md)** (this file) — what each doc is and where things live.
2. **[`PROJECT_STATUS.md`](PROJECT_STATUS.md)** — the dynamic per-version status table: what's Done / In validation / Planned / Deferred.
3. **[`CURRENT_PLAN.md`](CURRENT_PLAN.md)** — the current direction and the next implementation phase.
4. **[`../README.md`](../README.md)** — the server's top-level README (how to run, config, auth, smoke scripts).
5. **[`spec-v0.9.0-client-api-contract.md`](spec-v0.9.0-client-api-contract.md)** — the **canonical client-facing API contract** (the single best reference for request/response shapes).
6. The specific **`spec-v0.*`** doc(s) for the area you are about to change.
7. **[`micago-feature-decision-matrix.md`](micago-feature-decision-matrix.md)** — the guardrails: what MicaGoServer deliberately keeps vs. skips vs. defers.

## What each document is for

### Entry points / living docs (current source of truth)

| Document | Purpose |
| --- | --- |
| [`README.md`](README.md) | This documentation index. |
| [`PROJECT_STATUS.md`](PROJECT_STATUS.md) | Dynamic status table across all versions/areas. Update it whenever a milestone changes state. |
| [`CURRENT_PLAN.md`](CURRENT_PLAN.md) | Current direction + next phase (today: validate v0.11, then v0.12 Firebase self-host). |
| [`../README.md`](../README.md) | Server top-level README: run/config/auth/smoke. |
| [`../micago-mac-companion/README.md`](../micago-mac-companion/README.md) | Companion app README: open/build in Xcode. |

### Server specs (current source of truth, per area)

These describe the design and wire format and are authoritative for their area.
The **client API contract (v0.9)** is the canonical reference for HTTP/WS shapes;
individual feature specs add detail and rationale.

| Document | Area |
| --- | --- |
| [`spec-v0.1.md`](spec-v0.1.md) | Initial read-only chat.db HTTP API. |
| [`spec-v0.1.1.md`](spec-v0.1.1.md) | Clean iMessage-default view; `service` / `includeEmpty` filters. |
| [`spec-v0.2.0-relaydb.md`](spec-v0.2.0-relaydb.md) | `relay.db` bootstrap + one-way sync skeleton. |
| [`spec-v0.2.1-incremental-sync.md`](spec-v0.2.1-incremental-sync.md) | Incremental sync via `source_rowid`. |
| [`spec-v0.2.2-v0.2.3-relay-api-sync.md`](spec-v0.2.2-v0.2.3-relay-api-sync.md) | API reads move to `relay.db`; periodic sync loop. |
| [`spec-v0.3.0-send.md`](spec-v0.3.0-send.md) | Plain-text send via AppleScript + confirmation. |
| [`spec-v0.3.1-text-extraction-fix.md`](spec-v0.3.1-text-extraction-fix.md) | `attributedBody` text extraction fix. |
| [`spec-v0.4.0-websocket.md`](spec-v0.4.0-websocket.md) | Plain WebSocket realtime events. |
| [`spec-v0.5.0-attachments.md`](spec-v0.5.0-attachments.md) | Attachment metadata + safe download. |
| [`spec-v0.6.0-security.md`](spec-v0.6.0-security.md) | Bearer auth + localhost binding rules. |
| [`spec-v0.7.0-device-registry.md`](spec-v0.7.0-device-registry.md) | Device registry endpoints. |
| [`spec-v0.8.0-notification-provider.md`](spec-v0.8.0-notification-provider.md) | Notification provider abstraction (webhook real; FCM/HMS/ntfy stubs). |
| [`spec-v0.9.0-client-api-contract.md`](spec-v0.9.0-client-api-contract.md) | **Canonical** stable client API contract (REST + WS + models). |
| [`spec-v0.11.0-connection-endpoints.md`](spec-v0.11.0-connection-endpoints.md) | Aggregated connection endpoints (local/LAN/optional public) + `/api/server/urls`. |
| [`spec-v0.11.x-server-reliability.md`](spec-v0.11.x-server-reliability.md) | **Planned next milestone:** sync fidelity (update detection), send-error fast-fail, `chat.db` schema/version safety, runtime preconditions. |
| [`spec-v0.11.5-message-fidelity.md`](spec-v0.11.5-message-fidelity.md) | **Implemented:** attachment kind/voice/UTI + MIME inference; typedstream `+!`/`+$` text-extraction fix. Additive `Attachment` fields. |
| [`spec-v0.12.0-reliable-send-pipeline.md`](spec-v0.12.0-reliable-send-pipeline.md) | **Implemented:** hardened plain-text send — richer pending-send manager (status/resolve/reject/claim), 15s confirmation, `send:pending` event, structured `send_confirmation_timeout`. (Note: `v0.12.0` also used by the Firebase spec.) |
| [`c26-imessage-advanced-semantics-actions.md`](c26-imessage-advanced-semantics-actions.md) | **Implemented:** sticker display semantics, capability-driven edit/undo-send/delete API surface, LAN endpoint startup refresh, and C26 limitations. |

### Companion app spec (current source of truth)

| Document | Area |
| --- | --- |
| [`spec-v0.10.0-mac-companion.md`](spec-v0.10.0-mac-companion.md) | Native macOS SwiftUI companion + `GET /api/server/status`. Uses "Connection Endpoints" terminology (v0.11). |
| [`spec-v0.10.1-swiftui-companion-redesign.md`](spec-v0.10.1-swiftui-companion-redesign.md) | **Planning:** sidebar-based companion redesign (Dashboard/Connections/Devices/Notifications/Permissions/Server/Logs/Advanced), informed by a BlueBubbles UI surface audit. |

### Roadmap specs (planned / deferred phases)

Productization roadmap after v0.11.x. Build order:
v0.11.2 → v0.11.3 → v0.11.4 → v0.12 → v0.13. See
[`CURRENT_PLAN.md`](CURRENT_PLAN.md).

| Document | Phase |
| --- | --- |
| [`spec-v0.11.2-companion-runtime-deployment.md`](spec-v0.11.2-companion-runtime-deployment.md) | **Planned:** bundle the Go backend in the app; companion-owned lifecycle (start/stop/restart, crash + backoff auto-restart), launch-at-login/auto-start/silent launch, menu-bar item, clear Full Disk Access failure surfacing. |
| [`spec-v0.11.3-sync-control-and-privacy-rules.md`](spec-v0.11.3-sync-control-and-privacy-rules.md) | **Planned:** per-chat/per-handle sync + push rules (whitelist/blacklist), Sync Control + Recent Messages management view; future-sync-only first (no historical deletion). |
| [`spec-v0.11.4-contacts-enrichment.md`](spec-v0.11.4-contacts-enrichment.md) | **Planned:** read-only, local-only macOS Contacts to map handles → names for rule editing; never uploaded. |
| [`spec-v0.12.0-firebase-self-host.md`](spec-v0.12.0-firebase-self-host.md) | Self-host FCM push + optional Firestore **public-URL-only** sync; strict no-content/no-token privacy. **Implemented (in validation).** User setup guide: [`setup/firebase/`](setup/firebase/README.md). |
| [`spec-v0.13.0-scheduled-sending.md`](spec-v0.13.0-scheduled-sending.md) | **Deferred:** scheduled text sends; persistence, restart/sleep behavior, anti-misfire — sequenced last. |

### Status / gap reports

| Document | Purpose |
| --- | --- |
| [`v0.9.0-gap-analysis.md`](v0.9.0-gap-analysis.md) | Contract-vs-implementation gap analysis (now mostly resolved; see notes inside). |
| [`bluebubbles-source-audit-v2.md`](bluebubbles-source-audit-v2.md) | Source-level audit of BlueBubbles vs MicaGoServer across 10 server areas (informs v0.11.x). |
| [`server-gap-after-bluebubbles-source-review.md`](server-gap-after-bluebubbles-source-review.md) | Prioritized (P0/P1/P2) gap list and recommended next milestone from the source audit. |
| [`v0.1.1-live-test-report.md`](v0.1.1-live-test-report.md) | Historical live-test run on the author's Mac (v0.1.1). |

### Background / historical (reference, not source of truth)

These informed the original design by auditing BlueBubbles. They are **not**
specs and should not be treated as requirements. MicaGoServer is intentionally
**not** a BlueBubbles clone.

| Document | Purpose |
| --- | --- |
| [`micago-feature-decision-matrix.md`](micago-feature-decision-matrix.md) | The keep/simplify/skip/defer guardrails vs. BlueBubbles. **Read for guardrails.** |
| [`bluebubbles-full-audit.md`](bluebubbles-full-audit.md) | Reference-only architecture audit of BlueBubbles. |
| [`analysis/01-map.md`](analysis/01-map.md) | BlueBubbles module map. |
| [`analysis/02-chatdb.md`](analysis/02-chatdb.md) | `chat.db` schema/query analysis. |
| [`analysis/03-send-flow.md`](analysis/03-send-flow.md) | BlueBubbles send flow analysis. |
| [`analysis/04-message-text-extraction.md`](analysis/04-message-text-extraction.md) | `attributedBody` text extraction analysis. |
| [`analysis/05-realtime-sync-socket.md`](analysis/05-realtime-sync-socket.md) | Realtime/sync/socket analysis. |

### Agent instructions (see conflict note above)

| Document | Purpose |
| --- | --- |
| [`CLAUDE.md`](CLAUDE.md) | Generic Claude "Workspace" template. **Stale for this project's env/workflow.** |
| [`AGENTS.md`](AGENTS.md) | Generic Codex "Workspace" template. **Stale for this project's env/workflow.** |

## Where things live (repository map)

```
MicaGoServer/
  README.md                  # server: run / config / auth / smoke
  micago-server/             # the Go relay server
    cmd/micago/              # main entry
    internal/                # app, config, httpapi, store, relaydb, send, realtime, notify, timeutil
    scripts/                 # smoke + inspect scripts (kept; not build output)
    CHANGELOG.md             # currently only tracks v0.1.1 (stale; see PROJECT_STATUS)
  micago-mac-companion/      # native macOS SwiftUI controller (Xcode project)
  docs/                      # you are here
    README.md  PROJECT_STATUS.md  CURRENT_PLAN.md
    spec-v*.md               # server + companion specs
    v0.9.0-gap-analysis.md  v0.1.1-live-test-report.md
    micago-feature-decision-matrix.md  bluebubbles-full-audit.md
    analysis/                # BlueBubbles reference analysis
```

## Proposed future folder organization (NOT yet applied)

To reduce clutter, a future pass could reorganize `docs/` as below. **This has
not been done** because moving files safely requires updating every cross-link
(this index, the specs that reference each other, both READMEs, and the
gap-analysis). Do it as a dedicated, link-checked pass — see
[`PROJECT_STATUS.md`](PROJECT_STATUS.md) → "Docs & process notes".

```
docs/
  README.md
  PROJECT_STATUS.md
  CURRENT_PLAN.md
  specs/      # spec-v*.md (server + companion)
  audits/     # bluebubbles-full-audit.md, micago-feature-decision-matrix.md
  reports/    # v0.9.0-gap-analysis.md, v0.1.1-live-test-report.md
  agents/     # CLAUDE.md, AGENTS.md (after de-staling)
  analysis/   # already exists
```
