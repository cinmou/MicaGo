# MicaGoServer — Agent Instructions (Codex / general)

You are working on **MicaGoServer**: a lightweight, **Mica-native** Go iMessage
relay server plus a native macOS SwiftUI companion app. This file describes how
to work in this repository. It supersedes the old generic "gVisor/web workspace"
template (that template's checkpoint + commit + push workflow does **not** apply
here).

## Environment & workflow

- **Local macOS development.** Normal local checkout on a Mac, not a gVisor/web
  container. No proxy/DoH requirement and no mandatory checkpoint file.
- **Do not commit or push unless the user explicitly asks.** Review changes
  locally; the user decides when to commit. Most of the tree may be untracked —
  that is expected.
- **Keep the project Mica-native and conservative.** Never add: BlueBubbles
  client/server compatibility, Socket.IO, a WebUI/admin page, Electron,
  React/Vue, private-API helpers, a Mica-operated cloud relay, embedded
  Tailscale, or bundled tunnel binaries (`cloudflared`/`ngrok`). See
  [`micago-feature-decision-matrix.md`](micago-feature-decision-matrix.md).

## Repository layout

```
MicaGoServer/
  micago-server/         # the Go relay server (module: micagoserver)
  micago-mac-companion/  # native macOS SwiftUI controller (Xcode project)
  docs/                  # specs, status, plan, audits, analysis
```

## First reading order (every session)

1. [`docs/README.md`](README.md) — documentation index + workspace-conflict notes.
2. [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md) — per-version status (Done / In validation / Planned / Deferred).
3. [`docs/CURRENT_PLAN.md`](CURRENT_PLAN.md) — current direction and next phase.
4. The specific `docs/spec-v*.md` for the area you are changing
   (the canonical API reference is `spec-v0.9.0-client-api-contract.md`).

Docs-first: plan in `docs/` (and update `PROJECT_STATUS.md`) before/with code.

## Verification

**Go server** — from `micago-server/`:

```bash
gofmt -w .
GOCACHE="$PWD/.gocache" go test ./...
```

(Use a repo-local `GOCACHE` so the build cache stays inside the project and is
git-ignored.)

**SwiftUI companion** — when any Swift files change, from
`micago-mac-companion/`:

```bash
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The server binary the companion launches is built to `~/.micago/bin/micago`:

```bash
cd micago-server && go build -o ~/.micago/bin/micago ./cmd/micago
```

## Conventions

- Update [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md) when a milestone changes
  state.
- Smoke scripts live in `micago-server/scripts/` (kept in git; not build output).
- Local runtime/config/db (`~/.micago/`, `relay.db`, `.gocache/`, Xcode
  DerivedData) must never be committed — see the repo `.gitignore`.
