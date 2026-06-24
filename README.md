# MicaGo

**Use your own iMessage from your own Android phone — through your own Mac. No cloud, no account, no third‑party relay.**

MicaGo is a self‑hosted iMessage bridge. A small Go server runs on your Mac and
reads its local Messages database; a macOS menu‑bar **Companion** manages that
server; and a **Flutter Android app** pairs with it over your Wi‑Fi (or an
optional public URL you control) to read and send messages. Your data only ever
travels between **your** Mac and **your** devices.

> ⚠️ **Project status:** functional and self‑hostable, but young. It talks to
> macOS Messages internals and requires Full Disk Access. Read the
> [security model](#security-model) and [limitations](#limitations) before
> relying on it. Not affiliated with Apple.

---

## Contents

- [How it works](#how-it-works)
- [Features](#features)
- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Building each component](#building-each-component)
- [Optional features](#optional-features)
- [Security model](#security-model)
- [Limitations](#limitations)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## How it works

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

- **Read path:** the server syncs `chat.db` one‑directionally into its own
  `relay.db`, then serves a small, stable REST + WebSocket API. The client pulls a
  cursor‑based **delta** for catch‑up and gets realtime events over the socket.
- **Send path:** text is sent via AppleScript through Messages; attachments via a
  multipart upload. Edit / Unsend / Delete use an optional bundled
  [IMCore helper](#edit--unsend--delete-imcore-helper).
- **Pairing:** the Companion shows a QR code / connection JSON containing the
  LAN/public candidates + a bearer token; the client scans or pastes it.

## Features

- **Self‑hosted, no cloud.** No MicaGo account or server; nothing is relayed
  through a third party.
- **Chats & messages.** Conversation list, threads, reactions/tapbacks, replies,
  send effects, stickers, and inline image/video media with a full‑screen viewer.
- **Send.** Text and attachments over iMessage; SMS sending is **off by default**
  and gated by a server setting.
- **Realtime + catch‑up.** WebSocket events for live updates, cursor delta sync to
  fill gaps after the app was closed.
- **LAN‑first connectivity.** Multiple LAN interface addresses are advertised; the
  client auto‑selects a reachable route and lets you pin one. An optional public
  URL (your own tunnel) works from anywhere.
- **Contacts matching.** Local, on‑device contact names (opt‑in; the address book
  is never uploaded).
- **Paired devices.** The Companion lists connected devices with push/background
  status and a test‑push action.
- **Optional extras** (all off by default): Firebase/FCM push, a keep‑alive
  background service, and the Edit/Unsend/Delete IMCore helper.

## Repository layout

| Path | What it is |
| --- | --- |
| `MicaGoServer/micago-server/` | The Go relay server (the `micago` binary). |
| `MicaGoServer/micago-mac-companion/` | The macOS SwiftUI menu‑bar Companion (runs/manages the server, pairing UI). |
| `MicaGoFlutterClient/` | The Flutter Android client. |
| `docs/` | User guides (getting started, remote access, manual test flow). |
| `CHANGELOG.md` | Consolidated development/version history. |

> `Ref/` (if present locally) holds third‑party reference projects used during
> development. It is **not** part of MicaGo and is git‑ignored.

## Requirements

- **macOS** with the Messages app signed in to iMessage, and **Full Disk Access**
  granted to the Companion / terminal (so it can read `chat.db`).
- **Go 1.24+** to build the server.
- **Xcode** (recent) to build the Companion.
- **Flutter** (stable, with the Android toolchain) to build the client.
- An Android device on the same Wi‑Fi as the Mac (LAN), or your own public
  URL/tunnel for remote access.

## Quick start

The easiest path is to run the **Companion**, which builds + launches the bundled
server for you:

1. Open `MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj` in Xcode and
   run the app (or build a release and launch it).
2. Grant **Full Disk Access** to the Companion when prompted, then **Start** the
   server. It binds `0.0.0.0:3000` (LAN‑reachable) by default.
3. On the Companion's **Create Connection** card, show the QR code (or copy the
   connection JSON).
4. In the Android app, **Scan QR** or **Paste connection JSON** to pair. It will
   connect over LAN automatically.

Prefer the command line? See [Building each component](#building-each-component)
to run the server directly with `go run`/`go build`.

## Building each component

### Server (`MicaGoServer/micago-server`)

```sh
cd MicaGoServer/micago-server
go build ./cmd/micago        # produces ./micago
./micago --version
go test ./...
```

Run it directly (it generates `~/.micago/config.yaml` with a bearer token on
first run):

```sh
go run ./cmd/micago
```

### Companion (`MicaGoServer/micago-mac-companion`)

Open the Xcode project and build the `MicaGoCompanion` scheme. The build phase
compiles the bundled `micago` backend **and** the `micago-imcore-helper` into the
app's `Resources/`. Command‑line build:

```sh
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

### Client (`MicaGoFlutterClient`)

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # or: flutter run
```

## Optional features

All optional and **off by default** — MicaGo works fully without any of them.

### Firebase / FCM push

Background push uses **your own** Firebase project (no `google-services.json` is
baked into the app). Point the server at your `google-services.json` and it serves
the client config at `GET /api/fcm/client`; the app initializes Firebase at
runtime and registers a token. Push is a thin **wake** signal — message content
always arrives over the socket / delta sync. With nothing configured, the app runs
on WebSocket + delta sync. See `docs/setup/firebase/`.

### Keep‑alive background service (Android)

An advanced, opt‑in toggle ("Keep MicaGo running in background") starts a native
foreground service with a minimal persistent notification, keeping the connection
alive in the background without Firebase. Default off; OEM battery managers may
still throttle it.

### Edit / Unsend / Delete (IMCore helper)

These use a small bundled helper (`micago-imcore-helper`) that calls private
macOS IMCore APIs. The Companion's **Install helper** button copies it to
`~/.micago/bin`; the backend detects it and the client only shows the actions when
the helper reports them usable. If your Mac doesn't grant IMCore access, it
reports *unsupported* — never a fake success.

### Remote access

For access outside your Wi‑Fi, put your own reverse proxy / tunnel (e.g.
Cloudflare Tunnel) in front of the server and set the **Public URL** in the
Companion. MicaGo does not provide or manage a tunnel. See
[`docs/remote-access-cloudflare.md`](docs/remote-access-cloudflare.md).

## Security model

- **Bearer token.** Every API call requires a server‑generated bearer token
  (in `~/.micago/config.yaml`). Anyone with your URL **and** token can reach your
  Mac — treat the token like a password; never paste it into screenshots, logs, or
  issues. Regenerate it (and re‑pair) if it leaks.
- **Local‑first.** The default bind is your LAN. Public exposure is opt‑in and
  your responsibility; prefer HTTPS for anything leaving your network.
- **Your data stays yours.** No cloud relay. Contacts are matched on‑device and
  never uploaded. Push payloads (if you enable FCM) carry only a small wake
  preview, never your message history or tokens.
- **Private APIs.** The optional IMCore helper uses Apple private frameworks for
  edit/unsend/delete and is gated behind capability checks.

## Limitations

- **macOS‑bound.** The server must run on a Mac signed in to iMessage with Full
  Disk Access. It reads the live Messages database.
- **Edit/Unsend/Delete** depend on your Mac granting private‑API (IMCore) access;
  where it isn't available, those actions are hidden.
- **Reliable killed‑app push** on Android effectively needs your own
  `google-services.json` and/or the keep‑alive service; without them, push covers
  foreground/backgrounded apps best‑effort while the socket + delta sync cover the
  rest.
- **Android only** for the client today (the API is client‑agnostic by design).
- Not affiliated with, or endorsed by, Apple. Use at your own risk.

## Documentation

- [Getting started](docs/getting-started.md)
- [Android client connection](docs/android-client-connection.md)
- [Remote access with Cloudflare Tunnel](docs/remote-access-cloudflare.md)
- [Manual test flow](docs/manual-test-flow.md)
- [CHANGELOG](CHANGELOG.md) — full development/version history
- Component READMEs: [`server`](MicaGoServer/README.md),
  [`Companion`](MicaGoServer/micago-mac-companion/README.md),
  [`client`](MicaGoFlutterClient/README.md)

## Contributing

Issues and pull requests are welcome. Before opening a PR:

- **Server:** `go build ./... && go vet ./... && go test ./...`
- **Client:** `flutter analyze && flutter test`
- **Companion:** build the `MicaGoCompanion` scheme in Xcode.

Keep changes lightweight and dependency‑free where possible; never log or commit
bearer tokens or push tokens.

## License

[MIT](LICENSE).
