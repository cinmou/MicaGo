# C17 — Backend launch & CLI test plan

Manual commands to verify the *running* backend is the intended build and that
the C12–C15 sync fixes are actually active. Run from the repo root unless
noted. `TOKEN` is `auth.token` from `~/.micago/config.yaml`.

```sh
TOKEN=$(grep 'token:' ~/.micago/config.yaml | sed 's/.*"\(.*\)"/\1/')
BASE=http://127.0.0.1:3000
```

## 1. Build the backend from source (with version stamp)

```sh
MicaGoServer/micago-server/scripts/build-backend.sh
# installs to ~/.micago/bin/micago and prints the --version line
```

A plain `go build ./cmd/micago` works but loses the commit/buildTime stamp;
always use the script for the dev binary the companion launches.

## 2. Print the version

```sh
~/.micago/bin/micago --version
# MicaGoServer v0.15.0 commit=843ca25 buildTime=2026-06-12T11:26:17Z go=go1.26.4 darwin/arm64
```

A **stale pre-v0.15 binary fails this** with `flag provided but not defined:
-version` — that failure is itself the staleness signal (and the unknown flag
makes it exit; it never starts the server).

## 3. Start the backend from the command line

```sh
~/.micago/bin/micago            # uses ~/.micago/config.yaml
# or explicit bind:
~/.micago/bin/micago --addr 0.0.0.0:3000
```

Startup must log the identity first:

```
MicaGoServer v0.15.0 commit=… buildTime=… go=… darwin/arm64
executable: /Users/you/.micago/bin/micago
```

## 4. Query status (backend identity + settings)

```sh
curl -s -H "Authorization: Bearer $TOKEN" $BASE/api/server/status | python3 -m json.tool
```

Check `.backend`: `executablePath`, `version`, `commit`, `buildTime`,
`configPath`, `relayDbPath`, `chatDbPath`, `chatDbOpenOptions`,
`chatDbImmutable`. Check `.sync.settings`: `backfillMode`,
`recentMessagesPerChat`, service includes.

## 5. Run a sync/backfill now

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $BASE/api/sync/now | python3 -m json.tool
```

Inspect the returned diagnostics (`lastBackfillMode`, `lastRowsScanned`,
`lastRenderableRows`, `lastSyncError`).

## 6. Confirm immutable=1 is absent

```sh
curl -s -H "Authorization: Bearer $TOKEN" $BASE/api/server/status \
  | python3 -c "import json,sys; b=json.load(sys.stdin)['backend']; print(b['chatDbOpenOptions'], '| immutable:', b['chatDbImmutable'])"
# expected: mode=ro&_busy_timeout=5000 | immutable: False
```

If `backend` is missing entirely, the running server predates v0.15 → stale.

## 7. Confirm backfill mode / settings

```sh
curl -s -H "Authorization: Bearer $TOKEN" $BASE/api/sync/settings | python3 -m json.tool
# and the echo in /api/server/status .sync.settings (must match)
```

## 8. Confirm the latest message appears

Send yourself an iMessage from another device, then:

```sh
# normal renderable timeline (should contain it within a few seconds)
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/messages/recent?limit=5" | python3 -m json.tool
# raw/debug view (always shows everything, including hidden rows)
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/debug/recent-messages?limit=5" | python3 -m json.tool
```

## Companion launch policy (what to expect)

- Resolution: explicit override → **newest** (file mtime) of
  `~/.micago/bin/micago` vs the bundled binary. A stale cached binary is never
  silently preferred anymore.
- Every start probes `--version`; the result (or the probe failure = stale
  warning) appears in the backend log panel and in Settings → Advanced →
  **Backend Build**, alongside the running server's reported identity.
- **Restart with Latest Backend** (Advanced → Backend Build) stops the child,
  re-resolves (newest wins), starts, and the next status poll shows the new
  version/path.
- The Xcode "Bundle Go Backend" phase builds the bundled binary from the
  current checkout **with** the version stamp on every app build.

## Config auto-creation (Part E state)

`BackendController.ensureConfigFile()` creates `~/.micago/config.yaml` on
first launch when missing: generates a 32-byte hex token, 0600 permissions,
binds `0.0.0.0:3000` (C17 — LAN pairing out of the box; bearer token still
required; restrict via Settings → bind address). chat.db and relay.db paths
are server-side defaults (`~/Library/Messages/chat.db`, `~/.micago/relay.db` —
the directory is created by the server). Known gap: the UI edits bind address,
sync settings, and notifications, but not every config.yaml field (e.g.
webhook URL) — acceptable for now.
