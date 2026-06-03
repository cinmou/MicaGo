# MicaGoServer v0.7.0 Device Registry

## Goal

Add a lightweight server-side device registry so future Windows, Android, iOS, HarmonyOS, and web clients can register themselves and later receive push or realtime policy decisions.

## Storage

Current implementation stores devices in `relay.db` to avoid adding a second server database.

Table:

```sql
devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  client_type TEXT NOT NULL,
  push_provider TEXT NOT NULL,
  push_token TEXT,
  push_enabled INTEGER NOT NULL DEFAULT 0,
  last_seen_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
```

## Supported Values

`platform`:

- `windows`
- `android`
- `ios`
- `harmonyos`
- `web`
- `unknown`

`clientType`:

- `tauri`
- `flutter`
- `web`
- `native`
- `unknown`

`pushProvider`:

- `none`
- `webhook`
- `fcm`
- `hms`
- `harmony_push`
- `ntfy`

## Validation

- `name` is required.
- `platform` is required and must be one of the supported values.
- `clientType` is required and must be one of the supported values.
- `pushProvider` is required and must be one of the supported values.
- If `pushEnabled=true` and `pushProvider != none`, `pushToken` is required except for `webhook` when a global `webhook.url` is configured.

## Endpoints

All routes below are authenticated.

### `POST /api/devices/register`

Request:

```json
{
  "id": "optional-client-generated-id",
  "name": "Cinmou Android",
  "platform": "android",
  "clientType": "flutter",
  "pushProvider": "fcm",
  "pushToken": "token",
  "pushEnabled": true
}
```

Behavior:

- If `id` is missing, the server generates one.
- Upserts by `id`.
- Updates `push_token`, `updated_at`, and `last_seen_at`.
- Preserves `created_at` for existing devices.

Response shape:

- Returns the stored device under `data`.
- Does not return the raw `pushToken`.
- Returns `pushTokenSet: true|false`.

### `GET /api/devices`

Returns all devices as a list under `data`.

### `PATCH /api/devices/{id}`

Allows updating:

- `name`
- `pushProvider`
- `pushToken`
- `pushEnabled`

### `POST /api/devices/{id}/heartbeat`

Updates `last_seen_at` and `updated_at`.

### `DELETE /api/devices/{id}`

Deletes the device.

## Windows / Android / Huawei Notes

- Windows is expected to use WebSocket plus local tray notifications later.
- Flutter Android is expected to use `fcm` on Google Android once a real provider implementation is added.
- Huawei / HarmonyOS devices are expected to use `hms` or `harmony_push` through the same abstraction layer.

## Manual Test Plan

1. Start the server and read the token from `~/.micago/config.yaml`.
2. Register a device with `pushProvider=none`.
3. List devices and confirm the device appears.
4. Confirm the response hides the raw `pushToken`.
5. Send a heartbeat and confirm `lastSeenAt` changes.
6. Patch the device name and confirm it updates.
7. Delete the device and confirm it disappears from `GET /api/devices`.

## Known Limitations

- Device auth is still server-token based, not per-device scoped.
- WebSocket sessions are not yet linked to registered device IDs.
- The registry is sufficient for future client support, but not yet a full pairing system.
