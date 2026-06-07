# Getting Started with MicaGo

This guide walks you through your first MicaGo setup and the recommended order
to test each connection.

## What MicaGo does (at this stage)

MicaGo runs a small server on your Mac that exposes your Messages data to your
**own** devices over a private, token‑protected connection. A companion app on
the Mac starts/stops the server and shows you how to connect.

You can reach the Mac in three ways:

1. **This Mac (local)** — from the Mac itself.
2. **LAN (same Wi‑Fi)** — from another device on the same network.
3. **Public (remote)** — from anywhere, using your own domain and a tunnel you
   set up yourself (see
   [Remote Access with Cloudflare Tunnel](remote-access-cloudflare.md)).

There is no MicaGo cloud. Your data stays between your Mac and your devices.

## What you need

- A **Mac signed in to Messages** (iMessage working in the Messages app).
- The **MicaGo Mac app** (companion/server) installed and running.
- Required **macOS permissions** for the Mac app. If a permission is missing,
  the Mac app will tell you and link to the right Settings panel. In general the
  app needs permission to read the Messages database (Full Disk Access) and to
  control Messages for sending. Grant what the app asks for, then start the
  server again.
- An **Android device** for testing the mobile client (optional but recommended).

## What to get from the Mac app

Open the MicaGo Mac app and find the connection details. You will need:

- **Server base URL** — for example `http://127.0.0.1:<PORT>` on the Mac itself,
  or `http://<Mac-LAN-IP>:<PORT>` from another device on your Wi‑Fi. The default
  port is `3000`, but always use the value shown in the app.
- **Bearer token** — the secret that authorizes your devices. Copy it from the
  Mac app.
- **Public URL** (optional) — only if you set up remote access, e.g.
  `https://go.example.com`.

> ⚠️ **Keep your token private.** The bearer token is effectively a password.
> Do not paste it into screenshots, public logs, bug reports, or chats. If it
> ever leaks, create a new token in the Mac app and reconnect your devices.

## First connection options

- **This Mac / local** — `http://127.0.0.1:<PORT>`. Fastest way to confirm the
  server is alive. Note: `127.0.0.1` only works **on the Mac itself**, not from
  your phone.
- **LAN / same Wi‑Fi** — `http://<Mac-LAN-IP>:<PORT>`. Use this from a phone or
  laptop on the same network. Find `<Mac-LAN-IP>` in the Mac app's connection
  list, or in macOS System Settings → Network.
- **Public / remote domain** — `https://go.example.com`. Use this from mobile
  data or any outside network after you complete the Cloudflare guide.

## Recommended path

Test connections in this order — each step builds on the previous one:

1. **Test the local server.** On the Mac, confirm the server is running and
   reachable at `http://127.0.0.1:<PORT>`.
2. **Test LAN.** From another device on the same Wi‑Fi, reach
   `http://<Mac-LAN-IP>:<PORT>` and confirm the token is accepted.
3. **Set up a remote URL** (optional). Follow
   [Remote Access with Cloudflare Tunnel](remote-access-cloudflare.md) to get
   `https://go.example.com`, then enter it in the Mac app and validate it.
4. **Connect the Android client.** Enter the server URL and token in the app and
   tap **Test connection**. See
   [Android Client Connection](android-client-connection.md).
5. **Verify the WebSocket.** In the Android app, confirm the realtime connection
   shows **Connected** and that the debug panel lists incoming events.

For an exact, copy‑paste checklist of all of the above, see the
[Manual Test Flow](manual-test-flow.md).

## What success looks like

- The server's health check responds without a token.
- Your token is accepted by the auth check.
- The Android app shows **Connected** for the WebSocket and logs events in the
  debug panel.

If something does not work, each guide has a Troubleshooting section, and the
[Manual Test Flow](manual-test-flow.md) helps you find which step failed.
