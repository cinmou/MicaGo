# C25 — Connection model: LAN is primary, Public is optional, loopback is gone

A model refactor (no backward compatibility kept) that makes LAN the normal,
default path and removes loopback/"This Mac only" from the connection flow.

## Final model
- **LAN is primary.** A fresh install binds the server LAN-capable, so Android
  devices on the same Wi‑Fi can connect out of the box (the bearer token still
  gates access).
- **Public/Remote is optional.** It is only an extra fallback endpoint. A missing
  Public never blocks LAN pairing, QR generation, Copy JSON, the Connections
  page, the Dashboard, or local server operation.
- **Loopback (127.0.0.1) is not part of pairing.** Android can't reach it, so it
  is removed from `/api/server/urls`, the QR/JSON payload, and all connection UI.
  The QR/JSON contains only client-usable candidates: LAN, plus Public when
  configured.

## Why the old flow broke
The server defaulted to `127.0.0.1:3000` (loopback only), and the bind change to
"Local network" only takes effect after **Save & Restart**. So a fresh or
un‑restarted server advertised **no LAN endpoint** — and with Public unset, the
Create Connection payload had **zero candidates**, leaving Android nothing to
connect to. The UI also showed the raw bind (`0.0.0.0`, not a usable address) and
could contradict itself ("Local network selected" vs "LAN unavailable").

## What changed

### Server (Go)
- **Default bind → `0.0.0.0:3000`** (`config.go`) so fresh installs are
  LAN-reachable.
- `GET /api/server/urls` **drops the `local` list**; `ServerURLsResponse` now has
  only `lan`, `public`, `preferredPairingEndpoint`, `connectionRevision`.
  `localEndpoints()` was deleted. `lanEndpoints()` already resolves the Mac's real
  non-loopback IPv4 interface addresses on a wildcard bind (e.g.
  `http://192.168.1.23:3000`) — those are the Android-usable endpoints.
- Tests updated: `TestLoopbackBindHasNoLanEndpoints`,
  `TestGetServerURLsPublicDisabled` (asserts no LAN endpoints, no loopback list).

### Companion (Swift)
- **Server Bind Address**: "This Mac only" removed; options are now **Local
  network** (default) and **Custom**. Any existing loopback/wildcard bind loads as
  "Local network". The card shows the **real Android-usable LAN address**
  ("Android devices connect to: http://192.168.x.x:3000"), or a clear orange
  warning when listening but no LAN address was found — never the raw `0.0.0.0`.
- **Connection Endpoints**: the "Local / loopback" section is removed. LAN shows
  the real address(es) or a clear reason none exists; Public is labelled an
  optional fallback. The dead `EndpointRow` view and the obsolete pairing-mode
  state were removed; the menu-bar quick link shows **LAN** (not Local).
- Create Connection shows a **"No Android-usable endpoint"** empty state only when
  there is neither LAN nor Public.

### Flutter client
- `ServerUrls` drops `local`; the connection-status view no longer lists loopback.
- Candidate persistence already rebuilds the profile explicitly from
  `/api/server/urls` each revision, so **removing Public clears the stored public
  candidate** (no stale fallback). LAN-only and Public-only payloads both parse
  and connect; loopback `kind` is still defensively filtered out of any payload.

## Validation
| Check | Result |
| --- | --- |
| Fresh install defaults to LAN-capable bind (`0.0.0.0:3000`) | ✅ |
| Dashboard / Connections show LAN as the normal path | ✅ |
| Public is visibly optional; missing Public never blocks LAN | ✅ |
| QR works without Public; Copy JSON works without Public | ✅ (LAN-only payload) |
| Android can connect with a LAN-only payload | ✅ (real `192.168.x.x` endpoint) |
| Public can be added later as a fallback | ✅ (revision sync, no rescan) |
| Removing Public leaves no stale client candidate | ✅ (explicit profile rebuild) |
| Companion build · Go tests · Flutter tests (264) · debug APK | ✅ |

Still device-confirmable on your side: with the server **Save & Restart**ed on
"Local network", the Connections card should show a concrete `192.168.x.x:3000`,
and scanning that LAN-only QR should connect the Android app with no Public set.
