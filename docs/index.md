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
- **[Android Client Connection](android-client-connection.md)** — pairing the
  Android app over LAN or a public URL, and what it supports.
- **[Manual Test Flow](manual-test-flow.md)** — a step‑by‑step checklist you can
  run from zero to confirm local, LAN, public, and client connectivity.

For the full development history (per-cycle change notes), see the
[CHANGELOG](../CHANGELOG.md). For the overall project overview and build
instructions, see the [root README](../README.md).

## Security notes

- Your **bearer token** is like a password for your server. Anyone who has your
  public URL **and** your token can reach your Mac. Keep it private.
- Never paste your token into screenshots, public logs, bug reports, chat
  messages, or issue trackers.
- Prefer **HTTPS** for any connection that leaves your home network (the
  Cloudflare guide gives you HTTPS automatically).
- If you think your token has leaked, generate a new one in the Mac app and
  reconnect your devices.

## Current state

- The **Mac Companion** runs the server and shows your LAN and optional public
  connection details, paired devices, and diagnostics. You set up remote access
  yourself.
- The **Android app** pairs over LAN (same Wi‑Fi) or an optional public URL, syncs
  chats and messages, sends text + attachments (iMessage; SMS when you enable it
  on the Mac), renders reactions/replies/effects/media, and optionally receives
  push notifications.
- **Remote access** uses your own domain + Cloudflare Tunnel (or another
  reverse proxy/tunnel you choose). MicaGo does not provide a tunnel for you.

See each guide for details, the [Manual Test Flow](manual-test-flow.md) to verify
everything works, and the [root README](../README.md) for build instructions and
the full feature list.
