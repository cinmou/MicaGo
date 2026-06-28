<div align="center">

# MicaGo

**English** · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

**Your iMessage, your Mac, your phone — nothing in between.**
*A self‑hosted iMessage bridge. No MicaGo cloud, no account, no relay.*

[Documentation](docs/index.md) · [Getting started](docs/getting-started.md) · [Security model](#-security-model) · [Remote access](docs/remote-access-cloudflare.md) · [CHANGELOG](MicaGoServer/docs/CHANGELOG.md)

</div>

---

## Overview

MicaGo lets your **own** Android phone read and send your iMessages through your
**own** Mac. A small Go server on the Mac reads its local Messages database and
exposes a private, token‑protected API; a macOS menu‑bar **Companion** runs and
manages it; and a **Flutter Android app** pairs with it over your Wi‑Fi (or an
optional public URL you control). Your data only ever travels between **your** Mac
and **your** devices.

> ⚠️ **Project status:** functional and self‑hostable, but young. It reads macOS
> Messages internals and needs Full Disk Access. Read the
> [security model](#-security-model) and [limitations](#-limitations) before
> relying on it. Not affiliated with Apple.

---

## ✨ What you get

- 🔐 **Self‑hosted.** No MicaGo account or hosted relay. Optional push and remote
  access use services **you** own and configure.
- 💬 **Chats & messages.** Conversation list, threads, reactions/tapbacks, replies,
  send effects, stickers, **location / handwriting / Digital Touch**, and inline
  image/video media with a full‑screen viewer.
- 📤 **Send.** Text + attachments over iMessage, **voice messages**, and SMS when
  you turn it on (off by default, gated by a server setting).
- ⚡ **Realtime + catch‑up.** WebSocket events for live updates, plus a cursor
  **delta** sync that fills gaps after the app was closed — nothing is lost.
- 🌐 **LAN‑first connectivity.** Multiple LAN routes are advertised; the client
  auto‑selects a reachable one and lets you pin it. An optional public URL (your
  own tunnel) works from anywhere.
- 👤 **Contacts matching.** On‑device name resolution, opt‑in — the address book
  is never uploaded.
- 🔔 **Notifications (optional).** Native Android MessagingStyle pushes via **your
  own** Firebase, or a keep‑alive local path with no Firebase at all.

---

## 🧩 How it works

```
            ┌──────────────────────── your Mac ────────────────────────┐
            │                                                            │
 Messages   │   chat.db ──► sync loop ──► relay.db ──► REST + WebSocket  │
 (iMessage) │      ▲                                        │           │
            │      │ AppleScript / optional IMCore helper    │           │
            │   ┌──┴───────────────┐                         │           │
            │   │  Mac Companion   │  runs & manages the server          │
            │   │  (menu‑bar app)  │                         │           │
            │   └──────────────────┘                         │           │
            └────────────────────────────────────────────────┼──────────┘
                                                              │
                         LAN (same Wi‑Fi)  ──or──  optional public URL (your tunnel)
                                                              │
                                                   ┌──────────▼──────────┐
                                                   │   Android client    │
                                                   │  (Flutter app)      │
                                                   └─────────────────────┘
```

- **Read path** — the server syncs `chat.db` one‑directionally into its own
  `relay.db`, then serves a small, stable REST + WebSocket API. The client pulls a
  cursor‑based **delta** for catch‑up and gets realtime events over the socket.
- **Send path** — text via AppleScript through Messages; attachments via multipart
  upload. Edit / Unsend / Delete use an optional bundled
  [IMCore helper](#-optional-features).
- **Pairing** — the Companion shows a QR code / connection JSON with the LAN/public
  candidates + a bearer token; the client scans or pastes it.

---

## 🔐 Security model

MicaGo is **local‑first** and built so your data stays yours.

| Concern | How MicaGo handles it |
| --- | --- |
| **Auth** | Every API call needs a server‑generated **bearer token** (`~/.micago/config.yaml`). Anyone with your URL **and** token can reach your Mac — treat it like a password. |
| **Network** | Default bind is your **LAN**. Public exposure is opt‑in and your responsibility; prefer HTTPS for anything leaving your network. |
| **Your data** | **No MicaGo cloud relay.** Contacts are matched on‑device and never uploaded. |
| **Push** | If you enable FCM, payloads carry only a small wake/preview — never your message history or tokens. |
| **Private APIs** | The optional IMCore helper (edit/unsend/delete) is gated behind capability checks; it never fakes success. |

> **What MicaGo does** — bridge *your* iMessage to *your* devices over a connection
> *you* control.
> **What MicaGo does _not_ do** — run a cloud, hold an account, store your messages
> anywhere but your own Mac, or upload your contacts.

---

## 🚀 Quick start

The easiest path is the **Companion**, which builds + launches the bundled server:

1. Open `MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj` in Xcode and
   run it (or build a release and launch it).
2. Grant **Full Disk Access** when prompted, then **Start** the server. It binds
   `0.0.0.0:3000` (LAN‑reachable) by default.
3. On the Companion's **Create Connection** card, show the QR code (or copy the
   connection JSON).
4. In the Android app, **Scan QR** or **Paste connection JSON** to pair — it
   connects over LAN automatically.

Prefer the command line? See [building each component](#-building-each-component).

---

## 🛠 Building each component

**Server** (`MicaGoServer/micago-server`)

```sh
cd MicaGoServer/micago-server
go build ./cmd/micago        # produces ./micago
./micago --version
go test ./...
go run ./cmd/micago          # generates ~/.micago/config.yaml + a token on first run
```

**Companion** (`MicaGoServer/micago-mac-companion`)

```sh
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

> The Xcode build phase compiles the bundled `micago` backend **and** the
> `micago-imcore-helper` into the app's `Resources/`.

**Client** (`MicaGoFlutterClient`)

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # or: flutter run
```

---

## 🧰 Optional features

All optional and **off by default** — MicaGo works fully without any of them.

- 🔔 **Firebase / FCM push.** Background push using **your own** Firebase project
  (no `google-services.json` baked in). A thin *wake* signal; message data arrives
  over WebSocket / delta. See [`docs/setup/firebase/`](docs/setup/firebase/README.md).
- 🔋 **Keep‑alive service (Android).** A foreground service that holds the
  connection open with a minimal notification — alerts with **no** push setup.
  Default off; OEM battery managers can still throttle it.
- ✍️ **Edit / Unsend / Delete (IMCore helper).** A small bundled helper that calls
  private macOS IMCore APIs.
  - *What it's for* — edit/unsend/delete a sent iMessage from the phone.
  - *What it does **not** do* — fake success. If your Mac doesn't grant IMCore
    access, it reports *unsupported* and the actions stay hidden.
- 🌍 **Remote access.** Put your own reverse proxy / tunnel (e.g. Cloudflare Tunnel)
  in front of the server and set the **Public URL** in the Companion. MicaGo does
  not provide or manage a tunnel. See
  [`docs/remote-access-cloudflare.md`](docs/remote-access-cloudflare.md).

---

## 🗂 Repository layout

```
MicaGo/
├── MicaGoServer/
│   ├── micago-server/          # the Go relay server (the `micago` binary)
│   ├── micago-mac-companion/   # macOS SwiftUI menu‑bar Companion
│   └── docs/                   # software/design docs + CHANGELOG
├── MicaGoFlutterClient/        # the Flutter Android client
├── docs/                       # user guides (getting started, remote access, …)
└── README.md
```

> `Ref/` (if present locally) holds third‑party reference projects used during
> development. It is **not** part of MicaGo and is git‑ignored.

---

## 🌐 Localization

The Android client ships **English / 简体中文 / 繁體中文** (chosen in Settings, or
follow the system language). The Companion menu/sidebar and these docs are
localized too; this README has [简体中文](README.zh-Hans.md) and
[繁體中文](README.zh-Hant.md) editions.

---

## ⚠️ Limitations

- **macOS‑bound.** The server must run on a Mac signed in to iMessage, with Full
  Disk Access. It reads the live Messages database.
- **Edit/Unsend/Delete** depend on your Mac granting private‑API (IMCore) access;
  where unavailable, those actions are hidden.
- **Reliable killed‑app push** on Android effectively needs your own
  `google-services.json` and/or keep‑alive; otherwise push is best‑effort while the
  socket + delta sync cover the rest.
- **Android only** for the client today (the API is client‑agnostic by design).
- Not affiliated with, or endorsed by, Apple. Use at your own risk.

---

## 🤝 Contributing

Issues and pull requests are welcome. Before opening a PR:

- **Server:** `go build ./... && go vet ./... && go test ./...`
- **Client:** `flutter analyze && flutter test`
- **Companion:** build the `MicaGoCompanion` scheme in Xcode.

Keep changes lightweight and dependency‑free where possible; never log or commit
bearer tokens or push tokens.

---

<div align="center">

**[MIT](LICENSE)** · Built for people who'd rather host it themselves.

[Get started →](docs/getting-started.md)

</div>
