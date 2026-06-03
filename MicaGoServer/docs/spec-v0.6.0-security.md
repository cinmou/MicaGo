# MicaGoServer v0.6.0 Security Baseline

## Goal

Add a small production-ready baseline for authentication and server metadata without changing the core sync/send architecture.

## Config

Config file path:

- `~/.micago/config.yaml`

Current structure:

```yaml
server:
  addr: "127.0.0.1:3000"
  public_url: ""

auth:
  token: "<generated-token>"

sync:
  interval: "5s"

notifications:
  enabled: false
  provider: "none"
  preview: "sender"

webhook:
  url: ""

fcm:
  enabled: false
  project_id: ""
  service_account_path: ""

hms:
  enabled: false
  app_id: ""
  app_secret: ""
  token_cache_path: "~/.micago/hms-token.json"
```

Behavior:

- On first run, MicaGoServer creates `~/.micago/config.yaml` if missing.
- It generates a random auth token using at least 32 random bytes.
- The full token is only printed on first-run setup.
- CLI flags override config file values.

## Flags

- `--addr`
- `--token`
- `--disable-auth`
- `--public-url`
- `--sync-interval`
- `--disable-sync-loop`
- `--sync-once`
- `--api-store`

## Security Behavior

HTTP auth:

- `GET /api/health` is unauthenticated.
- All other `/api` routes require `Authorization: Bearer <token>` unless `--disable-auth` is active.
- Missing token returns `401`.
- Wrong token returns `401`.
- Token comparison uses constant-time comparison.

WebSocket auth:

- `GET /ws` requires a valid token.
- Token sources:
  - `Authorization: Bearer <token>`
  - `?token=<token>`
- Missing or invalid token rejects the connection.

`--disable-auth` rules:

- Allowed only for localhost binds such as `127.0.0.1`, `localhost`, or `::1`.
- If used with `0.0.0.0` or another non-local address, startup fails.

Bind warnings:

- If the server binds to a non-local address, it logs a warning.
- If the server binds to a wildcard address such as `0.0.0.0`, it logs an extra warning.

## Endpoints

### `GET /api/health`

Unauthenticated.

Response:

```json
{"ok":true}
```

### `GET /api/server/info`

Authenticated.

Response fields:

- `name`
- `version`
- `baseUrl`
- `websocketUrl`
- `features`
- `notificationProviders`

`baseUrl` and `websocketUrl` behavior:

- If `server.public_url` is set, derive both URLs from it.
- Otherwise, derive them from the local listen address where possible.
- Secret config values are never exposed.

### `POST /api/auth/check`

Authenticated.

Response:

```json
{"ok":true}
```

## Manual Test Plan

1. Delete `~/.micago/config.yaml` and start the server once.
2. Confirm the config file is generated and a token is printed once.
3. Call `GET /api/health` without a token and confirm `200`.
4. Call `GET /api/chats` without a token and confirm `401`.
5. Call `GET /api/chats` with `Authorization: Bearer <token>` and confirm success.
6. Call `GET /api/server/info` with the token and confirm the token is not present in the response.
7. Try `--disable-auth --addr 0.0.0.0:3000` and confirm startup refuses.

## Known Limitations

- Auth is a single shared bearer token, not per-device auth yet.
- There is no refresh-token or pairing-code flow yet.
- WebSocket auth does not yet associate a device identity with a connection.
