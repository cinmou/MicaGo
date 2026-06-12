# MicaGo User Documentation

Welcome to MicaGo. These guides help you set up the Mac app, connect from your
phone, and (optionally) reach your Mac from anywhere.

MicaGo lets your **own** devices talk to **your own** Mac. There is no MicaGo
cloud service: your messages stay between your Mac and the devices you connect.

## Guides

- **[Getting Started](getting-started.md)** — first‑time setup: what you need,
  where to find your server URL and token, and the recommended order to test
  each connection.
- **[Remote Access with Cloudflare Tunnel](remote-access-cloudflare.md)** — how
  to reach your Mac from outside your home using your own domain. Cloudflare
  Tunnel is **external and optional**; MicaGo does not bundle or manage it.
- **[Android Client Connection](android-client-connection.md)** — how to use the
  current Android app (an early "C0" build) and what it can and cannot do yet.
- **[C18 Client Connection Fallback](c18-client-connection-fallback.md)** —
  implementation notes for LAN/Public candidate storage, fallback, and
  diagnostics.
- **[Manual Test Flow](manual-test-flow.md)** — a step‑by‑step checklist you can
  run from zero to confirm local, LAN, public, and client connectivity.

## Security notes

- Your **bearer token** is like a password for your server. Anyone who has your
  public URL **and** your token can reach your Mac. Keep it private.
- Never paste your token into screenshots, public logs, bug reports, chat
  messages, or issue trackers.
- Prefer **HTTPS** for any connection that leaves your home network (the
  Cloudflare guide gives you HTTPS automatically).
- If you think your token has leaked, generate a new one in the Mac app and
  reconnect your devices.

## Current limitations (early stage)

MicaGo is still early. At this stage:

- The **Mac app** runs the server and shows your local, LAN, and (optional)
  public connection details. You set up remote access yourself.
- The **Android app** is a **C0 foundation build**. It can save your server URL
  and token, test the REST connection, and open the realtime WebSocket. It does
  **not** yet show chats, open message threads, send messages, handle
  attachments, or receive push notifications.
- **Remote access** uses your own domain + Cloudflare Tunnel (or another
  reverse proxy/tunnel you choose). MicaGo does not provide a tunnel for you.

See each guide for the details, and the
[Manual Test Flow](manual-test-flow.md) for how to verify everything works.
