# C18 Client Connection Fallback

## Scope

Restore Flutter client support for LAN plus Public fallback without changing the Go server. Normal message APIs, relay-backed timeline behavior, iMessage/SMS/RCS service scope, and tunnel management are unchanged.

## Pairing payload audit

The Companion already emits both connection candidates when LAN plus Public fallback is selected:

| Behavior | File/function | Notes |
| --- | --- | --- |
| Build pairable endpoint list | `MicaGoServer/micago-mac-companion/MicaGoCompanion/AppModel.swift` `pairingTargets` | Includes local, LAN, and configured Public targets. |
| Build QR/setup JSON | `MicaGoServer/micago-mac-companion/MicaGoCompanion/AppModel.swift` `pairingPayloadV2(redacted:)` | Adds selected LAN first, then Public when `pairingMode == "lanFirst"`. Includes `baseUrl`, `wsUrl`, and `priority`. Loopback/local is not included in QR. |
| Public endpoint response | `MicaGoServer/micago-server/internal/httpapi/urls.go` `buildPublicEndpoint` | Public response includes `baseUrl` and `wsUrl`. |
| Public WS derivation | `MicaGoServer/micago-server/internal/config/config.go` `WebSocketURLFromBase` | `https://micago.cinmou.uk` becomes `wss://micago.cinmou.uk/ws`; `http` becomes `ws`. |

No server-side payload change was needed for this pass.

## Flutter connection model

The client now treats the saved profile as a list of connection candidates rather than a single active URL.

| Mode | Candidate order |
| --- | --- |
| `lanOnly` | LAN only |
| `publicOnly` | Public only |
| `lanFirst` | LAN, then Public |
| `auto` | LAN, then Public |

Each candidate stores:

- HTTP base URL.
- WebSocket URL.
- Candidate kind: LAN or Public.

Public is not overwritten when LAN is active. LAN and Public base/ws URLs survive `ConnectionProfile` JSON storage round-trips.

## Fallback behavior

On profile activation and manual reconnect, the client probes candidates in mode order:

1. Run REST health check.
2. Run auth check with the saved token.
3. Select the first healthy/authenticated candidate.
4. Rebuild REST client for that candidate.
5. Connect WebSocket using that candidate's WS URL.
6. Run catch-up sync after selection.

If the active WebSocket fails in `lanFirst` or `auto`, the client tries the other candidate. LAN-only mode never probes Public. Public-only mode never falls back to localhost.

## WebSocket auth and URL rules

WebSocket URL derivation stays centralized:

- `http://host` -> `ws://host/ws`
- `https://host` -> `wss://host/ws`
- Explicit `wsUrl` from setup payload is preserved.

The Flutter WebSocket client attaches auth as `?token=`. This works for both LAN and Public and avoids relying on custom WebSocket headers on Android.

## Diagnostics

The Android connection/debug screen now shows:

- Pairing mode.
- Active candidate.
- Active HTTP base URL.
- Active WebSocket URL.
- LAN and Public candidate URLs.
- Recent connection selection log.

Temporary debug log lines are also emitted with the prefix:

```text
[MicaGo connection]
```

The log includes selected mode, candidate list, per-candidate status/auth checks, fallback decisions, and WebSocket error text.

## Tests

Focused tests cover:

- LAN plus Public setup payload becomes two runtime candidates.
- Public HTTPS derives `wss://.../ws`.
- LAN failure falls back to Public in fallback mode.
- LAN-only mode never tries Public.
- Candidate list survives profile JSON round-trip.
- Token survives profile JSON round-trip and is reused by runtime clients.

## Manual validation

1. Pair in LAN plus Public fallback mode.
2. On LAN, confirm the debug screen shows active `LAN` and connects to `http://192.168.0.106:3000`.
3. Disable LAN or move the phone off LAN.
4. Tap reconnect or wait for WebSocket failure.
5. Confirm active candidate changes to `Public`, REST uses `https://micago.cinmou.uk`, and WS uses `wss://micago.cinmou.uk/ws`.
6. Return to LAN and manually reconnect to confirm LAN is preferred again.
