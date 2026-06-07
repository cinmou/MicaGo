# Android Client Connection

This guide covers the current **Android app**, which is an early **C0
foundation** build. It focuses on connecting to your Mac server and confirming
the connection works.

## What the Android client can do today

- **Save your server URL.**
- **Save your bearer token securely** (stored in Android's encrypted storage;
  the token is never shown in logs).
- **Test the REST connection** — checks that the server is alive and that your
  token is accepted.
- **Connect the realtime WebSocket** and show its status
  (connecting / connected / failed).
- **Display debug events** — a panel that lists the names of realtime events as
  they arrive.

## What it cannot do yet

This build is foundation only. It does **not** yet:

- show a **chat list**,
- open a **message thread**,
- **send messages**,
- handle **attachments**,
- receive **push notifications**.

These come in later phases.

## Step 1 — Install the app

If you have a debug build (APK):

1. Copy the APK to your Android device (or build and run it from a computer with
   Flutter installed).
2. On the device, allow installing from your file manager / browser if prompted
   ("Install unknown apps").
3. Open the APK and install it, then launch **MicaGo**.

> A debug build is for testing only. Treat it like any pre‑release app.

## Step 2 — Choose how you'll connect

Pick the address that matches where your phone is:

- **Same Wi‑Fi as the Mac (LAN):**

  ```
  http://<Mac-LAN-IP>:<PORT>
  ```

  Find `<Mac-LAN-IP>` in the Mac app's connection list (or macOS System
  Settings → Network). The default `<PORT>` is `3000` — use whatever the Mac app
  shows.

- **Anywhere (public domain), after the Cloudflare setup:**

  ```
  https://go.example.com
  ```

> ⚠️ **Do not use `http://127.0.0.1` on the phone.** On Android, `127.0.0.1`
> means *the phone itself*, not your Mac. Use the Mac's LAN IP or your public
> domain.

## Step 3 — Enter your details

In the app's connection screen:

1. **Server URL** — the address from Step 2.
2. **Bearer token** — paste the token from the Mac app.
3. **WebSocket URL (optional)** — leave this blank. The app derives it
   automatically (see below). Only fill it in if your setup uses a different
   host for realtime.

> ⚠️ Keep your token private. Don't share screenshots of this screen with the
> token visible.

## Step 4 — Test the connection

Tap **Test connection**. The app will:

1. Check the server is alive (a no‑auth health check).
2. Check your token is accepted (an auth check).

A success message means both passed. Then tap **Save & continue** to go to the
home screen, where the app opens the WebSocket automatically.

## How the WebSocket URL is derived

If you leave the WebSocket field blank, the app builds it from your server URL:

- `http://…`  →  `ws://…`
- `https://…` →  `wss://…`
- it appends the `/ws` path.

Examples:

- `http://<Mac-LAN-IP>:<PORT>`  →  `ws://<Mac-LAN-IP>:<PORT>/ws`
- `https://go.example.com`      →  `wss://go.example.com/ws`

## Expected successful result

- **Health check passes** (server reachable).
- **Auth check passes** (token accepted).
- **WebSocket connected** — the status chip shows **Connected**.
- The **debug log shows received events** as activity happens on the Mac
  (for example when new Messages arrive).

## Common errors

| What you see | Likely cause | Fix |
| --- | --- | --- |
| **401 / token rejected** | Wrong or stale bearer token | Re‑copy the exact token from the Mac app and try again. |
| **Cannot reach host** | Wrong URL, server not running, or wrong network | Confirm the server is running, the URL/port match the Mac app, and the phone can reach that address. |
| **WebSocket connection failed** | Token query rejected, tunnel/proxy not passing WebSockets, or wrong scheme | Confirm REST works first; ensure `wss://` is used for HTTPS servers and the tunnel is running. |
| **LAN address times out** | Phone isn't on the same Wi‑Fi | Put the phone on the same network as the Mac, or use the public URL. |
| **Nothing loads with `127.0.0.1`** | Used loopback on the phone | Use the Mac's LAN IP or your public domain instead. |

If REST works but the WebSocket doesn't, the
[Remote Access guide](remote-access-cloudflare.md) and
[Manual Test Flow](manual-test-flow.md) have more checks.
