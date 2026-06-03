# MicaGoServer v0.11.0 — Connection Endpoints

## Goal

Expose **all** the ways a client can reach a running MicaGoServer as an
**aggregated set of connection endpoints**, not as mutually-exclusive modes.

The previous "LAN mode vs remote mode" framing was wrong. Corrected model:

> Once the Go server is running and bound appropriately, **local and LAN access
> always exist**. A **public** endpoint is an *additional* endpoint configured
> by the user — it never replaces or disables local/LAN.

```
MicaGoServer always exposes:
  1. loopback / local   http://127.0.0.1:<port>
  2. LAN                http://192.168.x.x:<port>      (when bound appropriately)
  3. public (optional)  https://mica.example.com       (user-configured EXTRA)
```

## Configuration

Provider-neutral. There is **no** `remote: { mode: local | custom }`. Instead:

```yaml
network:
  public_base_url: ""                 # optional EXTRA public endpoint (http/https origin)
  verify_tls: true                    # verify TLS when checking the public URL
  preferred_pairing_endpoint: "auto"  # auto | local | lan | public (a default, not a mode)
```

- `public_base_url` is a bare origin (scheme + host[:port], no path/query). Empty
  means "no public endpoint" — local/LAN are unaffected either way.
- `verify_tls` only affects the server's outbound reachability **check** of the
  public URL (set `false` for self-signed certs behind a reverse proxy).
- `preferred_pairing_endpoint` is a hint for which endpoint the pairing QR
  defaults to. It is a per-pairing default, **not** a server-wide mode.

Backward compatibility: the legacy `server.public_url` (and `--public-url`) are
honored as a fallback when `network.public_base_url` is empty.

Changes to the public URL are persisted by rewriting only the `network` section
of `~/.micago/config.yaml` (0600), preserving all other settings.

## Endpoint model

| Group | Source | Reachability |
| --- | --- | --- |
| `local` | loopback (or the specific bound address) derived from `server.addr` | `true` (the server is answering) |
| `lan` | non-loopback IPv4 interface addresses when bound to a wildcard, or the specific LAN bind address | `"unknown"` (not server-verifiable) |
| `public` | `network.public_base_url` | `true`/`false` after a check, else `"unknown"` |

LAN endpoints are only present when the bind makes the server LAN-reachable:

- bind `127.0.0.1:<port>` → local only, **no** LAN endpoints.
- bind `0.0.0.0:<port>` (or `:<port>`) → local loopback **plus** every
  non-loopback IPv4 interface as a LAN endpoint.
- bind `192.168.x.y:<port>` → that address as both the local and LAN endpoint.

`reachable` is encoded as JSON `true`, `false`, or the string `"unknown"`.

## API

All endpoints require the bearer token. None of them ever return the token.

### `GET /api/server/urls`

```json
{
  "local": [
    {
      "kind": "loopback",
      "label": "This Mac",
      "baseUrl": "http://127.0.0.1:12345",
      "wsUrl": "ws://127.0.0.1:12345/ws",
      "reachable": true
    }
  ],
  "lan": [
    {
      "kind": "lan",
      "label": "LAN",
      "baseUrl": "http://192.168.1.23:12345",
      "wsUrl": "ws://192.168.1.23:12345/ws",
      "reachable": "unknown"
    }
  ],
  "public": {
    "enabled": true,
    "kind": "custom",
    "baseUrl": "https://mica.example.com",
    "wsUrl": "wss://mica.example.com/ws",
    "reachable": true,
    "providerHint": "cloudflare_tunnel",
    "verifyTls": true,
    "lastCheckedAt": 1717372805000
  },
  "preferredPairingEndpoint": "auto"
}
```

When no public URL is configured: `"public": { "enabled": false, "baseUrl": "", "wsUrl": "", "reachable": "unknown", "verifyTls": true, "lastCheckedAt": null }`.

`providerHint` is a best-effort guess from the host (`cloudflare_tunnel`,
`ngrok`, `tailscale`, or `custom`). It is informational only.

### `POST /api/server/public-url`

Sets (or clears) the optional public endpoint. Body:

```json
{ "publicBaseUrl": "https://mica.example.com", "verifyTls": true, "preferredPairingEndpoint": "auto" }
```

- `publicBaseUrl` empty string clears the public endpoint.
- `verifyTls` / `preferredPairingEndpoint` optional (keep current if omitted).
- Validates the URL is a bare http(s) origin; invalid → `400 bad_request`.
- Persists to config and returns the updated `GET /api/server/urls` body.

### `POST /api/server/public-url/check`

Actively verifies the configured public URL reaches **this** server and that
bearer auth works. The server makes an outbound `POST <publicBaseUrl>/api/auth/check`
with its own token (honoring `verify_tls`), with a short timeout.

```json
{
  "ok": true,
  "reachable": true,
  "authOk": true,
  "status": 200,
  "baseUrl": "https://mica.example.com",
  "message": "public URL reaches this server and bearer auth works"
}
```

- `reachable` = an HTTP response was received.
- `authOk` = `200` (the token was accepted → it is this server).
- The response **never** contains the bearer token. The result is cached and
  surfaces as `public.reachable` in `GET /api/server/urls`.

## Pairing QR

The pairing QR encodes the **selected endpoint** (a per-pairing choice):

```json
{ "baseUrl": "...", "websocketUrl": "...", "token": "..." }
```

- **Local/loopback** → pairing a client on this Mac.
- **LAN** → pairing a same-network client.
- **Public** → pairing a remote client.

Selecting a different endpoint does not change any server mode; all endpoints
remain active. `preferred_pairing_endpoint` only sets the default selection.

## Companion app (SwiftUI)

The section is **"Connection Endpoints"** (not "Remote Mode"). It shows:

- **Local** URL(s) with copy buttons.
- **LAN** URL(s) with copy buttons (or a note when loopback-only).
- **Public URL**: editable field + "Verify TLS" toggle + **Save** +
  **Validate Public URL**, with the live reachability dot and provider hint.
- **Pairing QR**: an endpoint picker (Local / LAN / Public) that regenerates the
  QR for the chosen endpoint.

See [`spec-v0.10.0-mac-companion.md`](spec-v0.10.0-mac-companion.md).

## Producing a public URL (provider guidance)

MicaGoServer does **not** bundle, download, launch, or manage any of these. They
are simply ways for the user to obtain a `public_base_url` that forwards to the
local server; once they have one, they paste it into the companion.

| Approach | Notes |
| --- | --- |
| **Cloudflare Tunnel** | `cloudflared` tunnel to `http://127.0.0.1:<port>`; gives an `https://…trycloudflare.com` or custom-domain URL. No port-forwarding. |
| **Ngrok** | `ngrok http <port>`; quick `https://….ngrok-free.app` URL for testing. |
| **DDNS + port forwarding** | Dynamic DNS hostname + router port-forward to the Mac; pair with HTTPS via a reverse proxy. |
| **Reverse proxy (Caddy / Nginx)** | Terminates TLS for your own domain and proxies to the local server; set `verify_tls: true`. |
| **Tailscale** | **Advanced option only.** A tailnet `https://…ts.net` (or Funnel) URL. MicaGoServer does **not** embed Tailscale; documented for advanced users who already run it. |

Set `verify_tls: false` only for self-signed/intermediate setups you control.

## Firebase — deferred to a later phase

Not implemented here. When added, Firebase is limited to:

- **FCM push** delivery.
- **Optional** Firestore sync of the **public URL only** (so clients can
  rediscover a changed tunnel URL).

Firebase must **never** store message content, contacts, phone numbers, bearer
tokens, attachments, or chat history.

## Non-goals

No WebUI/admin page, Electron, React/Vue, Socket.IO, BlueBubbles compatibility,
private-API helpers, a Mica-operated cloud relay, or bundled tunnel/VPN tools.
Local and LAN are always-on derived endpoints; public is an optional extra.

## Tests

`internal/httpapi/urls_test.go` covers endpoint derivation (loopback-only vs
specific/wildcard bind), the `/api/server/urls` shape (public enabled/disabled),
provider-hint inference, public-URL persistence + validation, the reachability
check (success + wrong-token), and that the token never leaks into responses.
