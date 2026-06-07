# MicaGo Android client (Flutter)

Android-first Flutter client for a **MicaGo** relay server. This is the **Phase
C0 foundation**: connect to a server, test REST connectivity, open the realtime
WebSocket, and show connection/debug status. Chat list, message threads,
sending, attachments, push, and settings come in later phases.

## What works in C0

- **App shell** — Material 3, light/dark (system), MicaGo branding, go_router routes.
- **Connection setup** — server URL, bearer token, optional WebSocket URL
  (auto-derived from the base URL when blank). Saved locally; token in
  `flutter_secure_storage` (Android Keystore-backed). **Test connection** runs
  `GET /api/health` → `POST /api/auth/check`.
- **REST client** — bearer auth, `GET /api/server/urls`, structured error
  envelope (`{"error":{"code","message"}}`) parsing.
- **WebSocket client** — derives `ws://`/`wss://` + `/ws`, connects with
  `?token=`, shows connecting/connected/failed, logs received event `type`s in a
  debug panel.
- **Home** — connection status card, server endpoint summary, placeholder
  sections (Chats / Messages / Contacts / Settings), and the debug panel.

## Architecture

```
lib/
  main.dart
  app/        mica_go_app.dart · router.dart · theme.dart
  core/
    app_controller.dart            # app-wide state (profile, clients, urls)
    network/  api_client.dart · websocket_client.dart · endpoint_utils.dart
    storage/  secure_store.dart
    models/   connection_profile.dart · server_urls.dart
  features/
    connection/  connection_screen.dart · connection_controller.dart
    home/        home_screen.dart
    debug/       debug_log_panel.dart
```

State: `ChangeNotifier` + `provider`. Routing: `go_router` (guards force the
connection screen until a complete profile exists).

## Server compatibility

Targets the documented MicaGo API (see `MicaGoServer/docs/`):
`spec-v0.9.0-client-api-contract.md` (auth, error envelope, `/ws`),
`spec-v0.11.0-connection-endpoints.md` (`/api/server/urls`). Auth is a shared
bearer token (`Authorization: Bearer …`; the WebSocket also accepts `?token=`).

## Run

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # or: flutter run -d <android-device>
```

## Notes / TODO

- `android:usesCleartextTraffic="true"` is enabled so the client can reach
  `http://` local/LAN servers; public access should use `https` via the tunnel.
- The bearer token is stored securely and never written to logs or `toString()`.
- Not yet implemented (by design): chats, threads, sending, attachments, push /
  Firebase, QR scanner, BlueBubbles compatibility mode, full settings.
