# C10 — Onboarding & connection model

## Supported pairing modes
Only two user-facing modes (Part A):
- **LAN only** — connects on the local network; **never** uses Public.
- **LAN + Public fallback** — tries the selected LAN endpoint(s) first, then the
  Public endpoint if LAN is unreachable.

Local/loopback remains internal (Mac/server health checks) and is **never**
surfaced as a pairing option. "Public only" is not a user-facing default.

## QR payload schema (v2)
The companion encodes a v2 payload (loopback excluded):
```json
{
  "version": 2,
  "mode": "lan_first",          // or "lan_only"
  "token": "...",
  "serverName": "Mac mini",
  "endpoints": [
    { "kind": "lan",    "baseUrl": "http://192.168.1.23:3000", "wsUrl": "ws://192.168.1.23:3000/ws", "priority": 1 },
    { "kind": "public", "baseUrl": "https://micago.example.com", "priority": 2 }
  ]
}
```
- LAN-only payloads contain only LAN endpoint(s).
- The client parser (`pairing_payload.dart`) accepts v2 **and** legacy v1
  (`{baseUrl, websocketUrl?, token}`); v1 maps to a single LAN endpoint.
- `local`/loopback endpoints are dropped by the parser even if present.

## Companion pairing UI (Part B)
`ClientSetupSection` (ContentView.swift) now shows:
- a **mode** segmented control (LAN only / LAN + Public fallback),
- a **preferred LAN IP** picker over detected LAN endpoints (loopback hidden;
  noisy LAN endpoints already hideable), persisted via `selectedPairingBaseURL`,
- the public fallback URL when mode = LAN + Public,
- a v2 QR + "Copy setup JSON" (`AppModel.pairingPayloadV2`). `pairingMode` is
  persisted in `UserDefaults`.

## Android onboarding flow (Part C)
Scan → preview (with mode chooser when the payload offers both) → test → sync →
home. The state machine is `OnboardingController` (pure, injected prober +
sync runner; fully unit-tested):

1. `endpointTryOrder(mode, endpoints)` produces the attempt order
   (LAN by priority, then Public; LAN-only excludes Public).
2. For each endpoint: status **Testing LAN…** / **trying Public…**, then
   `health()` + `authCheck()`.
3. First success → active endpoint; status **LAN connected** / **Public
   connected**. None → **failed** (LAN-only shows retry/Wi-Fi guidance).
4. Build the `ConnectionProfile` (active endpoint as primary + LAN/Public
   candidates + mode), then run the initial per-chat backfill (status
   **Syncing chats…** → **Sync complete**), then persist + enter the app.

Status strings surface through `PairingController.message` during
`PairingStage.testing`. Manual sync is **not** required after pairing.

## Endpoint persistence
The saved `ConnectionProfile` carries `lanBaseUrl`/`lanWsUrl`,
`publicBaseUrl`/`publicWsUrl`, and `mode`; `effectiveBaseUrl`/`effectiveWsUrl`
resolve the runtime endpoint (LAN-only never resolves to Public). The active
endpoint becomes the primary `baseUrl`.

## Tests
- `test/pairing_v2_test.dart` — v1 back-compat, v2 parse, LAN-only drops public,
  loopback dropped, try-order rules, offered modes.
- `test/onboarding_controller_test.dart` — LAN connects first, LAN→Public
  fallback, LAN-only never probes Public + fails cleanly, runs initial sync,
  sync failure non-fatal.

## Remaining gaps
- No standalone "Welcome/explainer" screen yet (the flow starts at scan); the
  status states are surfaced inline during testing/sync.
- WebSocket reachability is not a separate onboarding check (health+auth only);
  WS connects post-activation.
