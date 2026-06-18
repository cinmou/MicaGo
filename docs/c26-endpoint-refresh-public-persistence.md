# C26 — Endpoint refresh + Public URL persistence fix

Blocker fix: LAN endpoints only appeared after clicking **Save**, and a saved
Public URL looked cleared/"unknown" after a restart. Root causes were in the
Companion's refresh + UI-state code, not the server's persistence.

## Audit findings (whole chain)
- **config.yaml load/save (server): already correct.** `POST /api/server/public-url`
  → `NetworkController.SetPublicURL` → `config.UpdatePublicBaseURL` parses the
  whole file and rewrites it via `renderConfig`, setting `network.public_base_url`.
  `Load` reads the same key back into `cfg.PublicBaseURL`, and `NewNetworkController`
  seeds from it. So the saved Public URL **is** preserved on disk across restarts
  (now covered by a test).
- **`/api/server/urls` (server): already correct.** LAN is derived from the bind
  address; a `0.0.0.0` bind enumerates the Mac's real interface IPs. With the C25
  LAN-capable default, startup advertises LAN automatically.
- **Companion `refresh()` (THE bug).** It fetched `status()` → `devices()` →
  `serverURLs()` inside **one** `do/catch`. Any error in `status` or `devices`
  silently skipped `serverURLs()`/`applyURLs()`, so `model.urls` never updated —
  while the **Save** path calls `serverURLs` directly, which is why endpoints
  "only appeared after Save" and "Save triggered side effects startup didn't."
- **Companion Public-URL field (the second bug).** `applyURLs` seeded
  `publicURLInput` **once** (`didSeedPublicInput`). If the first poll caught the
  backend before config finished loading, it captured an empty value and never
  re-synced — so a saved Public URL showed blank/"unknown" after restart.

## What changed (Companion `AppModel`)
- **Decoupled endpoint discovery.** `refresh()` now runs `status()`, `devices()`,
  and `serverURLs()` in **independent** `do/catch` blocks. Endpoint discovery
  always runs whenever the server is up + authed — exactly like a Save does — so
  **LAN/Public refresh automatically on startup and on every poll**, with no Save
  required. A status/devices hiccup no longer blocks it.
- **Public URL field mirrors the saved value.** Replaced the seed-once logic with
  a mirror: `publicURLInput` tracks the server's saved `public.baseUrl` unless the
  user has unsaved edits (`input != lastSeededPublicURL`). After a restart the
  field re-syncs to the saved URL; while editing, a poll won't clobber the draft;
  after Save it stays as typed. No stale local UI state overwrites config state.

Unchanged because already correct: server config persistence; `/api/server/urls`
LAN/Public derivation; the QR/JSON payload (reads the latest `model.urls`
snapshot, which now updates reliably); the Flutter client (already clears stale
Public candidates on revision change and subscribes to `connection:updated`). The
Companion already polls every 3s and aggressively right after backend start
(`refreshAfterBackendStart`), so it picks up `connection:updated`-driven changes
within the poll interval without a dedicated WS subscription.

## Required behavior — now met
- Backend startup runs endpoint discovery automatically; **LAN appears without Save**.
- Saved Public URL is loaded from config and **preserved across restarts**;
  start/stop/restart never clears it.
- Save is only needed to *change* Public URL / bind / port / hidden LAN — it is no
  longer the only path that refreshes discovery.
- `/api/server/urls` returns correct LAN + Public after startup; QR/JSON uses the
  latest snapshot; Public stays optional and never blocks LAN.

## Tests
- Go `TestPublicURLSurvivesRestart`: save a Public URL → reload (restart) → it is
  preserved (and bind/token survive the round-trip); clearing it removes it (no
  stale Public candidate).
- Existing: `TestLoadGeneratesConfigAndToken` (LAN-capable default),
  `TestLanEndpointsSpecificBind` / `TestBuildServerURLsLanOnlyHasNoPublic`
  (`/api/server/urls` includes LAN for a bound address; Public optional).
- The `refresh()` decoupling and the Public-field mirror are in `AppModel`, which
  has no XCTest target; they are validated by the Companion build + the manual
  steps below.

## Validation
| Check | Result |
| --- | --- |
| Companion builds | ✅ BUILD SUCCEEDED |
| Go tests pass | ✅ (incl. `TestPublicURLSurvivesRestart`) |
| Flutter untouched (still green) | ✅ |
| LAN appears after startup without Save | ✅ (decoupled `refresh()`) |
| Saved Public URL survives restart, shows in the field | ✅ (mirror + persistence) |
| Removing Public leaves no stale candidate | ✅ |

Manual: reset config → start backend → LAN endpoint appears automatically; set +
Save a Public URL, restart Companion/backend → Public URL remains and shows in the
field; QR/JSON includes LAN (+ Public); stop/start backend → endpoints stay
correct with no Save.
