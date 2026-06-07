# Manual Test Flow

A from‑zero checklist to confirm MicaGo works at each layer: local, LAN, public,
and the Android client. Run the sections in order — each builds on the previous.

**Placeholders used throughout:**

- `<TOKEN>` — your bearer token (from the Mac app). Keep it private.
- `<PORT>` — the server port (default `3000`; use what the Mac app shows).
- `<Mac-LAN-IP>` — your Mac's address on your Wi‑Fi (e.g. `192.168.1.23`).
- `go.example.com` / `https://go.example.com` — your own public domain.

> ⚠️ The `curl` commands below include your token. Don't paste real output that
> contains the token into screenshots, issues, or chats.

---

## A. Mac server check (local)

1. Start the **MicaGo Mac app** (companion/server).
2. Confirm the status shows **Running**.
3. Copy the **local URL** and the **bearer token** from the app.
4. From a Terminal **on the Mac**, test the no‑auth health check:

   ```bash
   curl http://127.0.0.1:<PORT>/api/health
   ```

   Expected: `{"ok":true}`.

5. Test that your token is accepted:

   ```bash
   curl -X POST \
     -H "Authorization: Bearer <TOKEN>" \
     http://127.0.0.1:<PORT>/api/auth/check
   ```

   Expected: HTTP `200` with `{"ok":true}`. A `401` means the token is wrong.

---

## B. LAN check (same Wi‑Fi)

1. Find your **Mac LAN IP** (`<Mac-LAN-IP>`) in the Mac app's connection list, or
   in macOS System Settings → Network.
2. From **another device on the same Wi‑Fi**, test health:

   ```bash
   curl http://<Mac-LAN-IP>:<PORT>/api/health
   ```

   Expected: `{"ok":true}`.

3. Test the token over LAN:

   ```bash
   curl -X POST \
     -H "Authorization: Bearer <TOKEN>" \
     http://<Mac-LAN-IP>:<PORT>/api/auth/check
   ```

   Expected: HTTP `200`.

   If health works but you get connection errors from another device, confirm
   the server is exposed on the LAN (not only loopback) in the Mac app, and that
   no firewall is blocking the port.

---

## C. Public URL check (Cloudflare Tunnel)

Complete the [Remote Access guide](remote-access-cloudflare.md) first.

1. Make sure the tunnel is running on the Mac:

   ```bash
   cloudflared tunnel run micago-server
   ```

2. From an **outside** network (or mobile data), confirm the domain reaches your
   server and the token works:

   ```bash
   curl -H "Authorization: Bearer <TOKEN>" \
     https://go.example.com/api/server/urls
   ```

   Expected: HTTP `200` and a JSON body listing your endpoints, for example:

   ```json
   {
     "local": [ { "kind": "loopback", "label": "This Mac",
                  "baseUrl": "http://127.0.0.1:<PORT>",
                  "wsUrl": "ws://127.0.0.1:<PORT>/ws", "reachable": true } ],
     "lan":   [ { "kind": "lan", "label": "LAN",
                  "baseUrl": "http://<Mac-LAN-IP>:<PORT>",
                  "wsUrl": "ws://<Mac-LAN-IP>:<PORT>/ws", "reachable": "unknown" } ],
     "public": { "enabled": true, "baseUrl": "https://go.example.com",
                 "wsUrl": "wss://go.example.com/ws", "reachable": true,
                 "providerHint": "cloudflare_tunnel" },
     "preferredPairingEndpoint": "auto"
   }
   ```

3. In the **Mac app**, set the **Public URL** to the bare origin
   `https://go.example.com` and run **Validate Public URL**.

   Expected result: the app reports the public URL is **reachable** and **auth
   passes**. (Behind the scenes this confirms the public URL loops back to this
   same Mac and that the token is accepted; the response never contains your
   token.)

---

## D. Android client check

See [Android Client Connection](android-client-connection.md) for details.

1. **Install** the Android app (debug APK).
2. Enter the **Server URL**:
   - LAN: `http://<Mac-LAN-IP>:<PORT>`
   - Public: `https://go.example.com`
   - (Not `127.0.0.1` — that's the phone itself.)
3. Enter the **token** (`<TOKEN>`).
4. Tap **Test connection**.
5. Confirm **REST success** (health + auth check pass).
6. Open the home screen and confirm **WebSocket success** — status shows
   **Connected** and the debug panel lists events as activity happens on the Mac.

---

## E. Send‑pipeline remote smoke test (API / manual)

> The current Android client **cannot send messages yet**, so this section is a
> **manual API test** (curl) and a **future‑client** check. Sending requires the
> **Messages app to be running** on the Mac and an **iMessage** chat.

1. List your chats to get a chat identifier (GUID):

   ```bash
   curl -H "Authorization: Bearer <TOKEN>" \
     "http://127.0.0.1:<PORT>/api/chats"
   ```

   Pick a `guid` from the response (an iMessage chat).

2. Send a simple text. `tempGuid` is any unique correlation string you choose:

   ```bash
   curl -X POST \
     -H "Authorization: Bearer <TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"tempGuid":"test-001","message":"Hello from MicaGo"}' \
     "http://127.0.0.1:<PORT>/api/chats/<CHAT_GUID>/send"
   ```

   The call is synchronous: the server triggers the send and waits until it can
   confirm the message in the Messages database (up to ~15 seconds).

3. **Watch the realtime events.** If you keep a WebSocket open (the Android app,
   or a WebSocket tool pointed at `…/ws?token=<TOKEN>`), you should see, for the
   same `tempGuid`:
   - `send:pending` — the request was accepted,
   - then `send:match` — the message was confirmed in the database (success).

4. **Confirm in Messages.** The sent text appears in the Messages app on the Mac.

5. **Confirm error/timeout behavior.** If the message can't be confirmed in time,
   the request returns HTTP `504` with code `send_confirmation_timeout` (and a
   `send:error` event). Other failures return clear codes (for example a `404`
   for an unknown chat, `409` for a duplicate `tempGuid`, or a `409`/error if the
   Messages app isn't running).

---

## F. Pass / fail table

Record your results:

| # | Check | Command / action | Expected | Pass? |
| --- | --- | --- | --- | --- |
| A1 | Server running | Mac app status | "Running" | ☐ |
| A2 | Local health | `curl …/api/health` | `{"ok":true}` | ☐ |
| A3 | Local auth | `POST …/api/auth/check` with token | `200` | ☐ |
| B1 | LAN health | `curl http://<Mac-LAN-IP>:<PORT>/api/health` | `{"ok":true}` | ☐ |
| B2 | LAN auth | `POST` auth check over LAN | `200` | ☐ |
| C1 | Tunnel running | `cloudflared tunnel run …` | connects | ☐ |
| C2 | Public reachable + auth | `curl …https://go.example.com/api/server/urls` | `200` + JSON | ☐ |
| C3 | Validate Public URL | Mac app "Validate" | reachable + auth OK | ☐ |
| D1 | Android REST | App → Test connection | success | ☐ |
| D2 | Android WebSocket | App home screen | "Connected" + events | ☐ |
| E1 | Send via API | `POST …/send` | `200` + message | ☐ |
| E2 | Realtime confirm | WebSocket events | `send:pending` → `send:match` | ☐ |
| E3 | Appears in Messages | Messages app | message visible | ☐ |
| E4 | Timeout/error path | force no‑match | `504 send_confirmation_timeout` | ☐ |

If a row fails, jump to the Troubleshooting section of the relevant guide:
[Getting Started](getting-started.md),
[Remote Access](remote-access-cloudflare.md), or
[Android Client Connection](android-client-connection.md).
