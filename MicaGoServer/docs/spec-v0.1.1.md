# Mica v0.1.1 Technical Spec

Scope: refine the v0.1 read-only API so the default view is a clean iMessage-only view.

## Behavioral Changes From v0.1

- `GET /api/chats` now defaults to `service=iMessage`
- `GET /api/messages/recent` now defaults to `service=iMessage`
- `GET /api/messages/recent` and `GET /api/chats/{guid}/messages` now hide empty messages by default
- Empty messages can still be requested with `includeEmpty=true`

Accepted `service` values:

- `iMessage`
- `SMS`
- `RCS`
- `all`

Default `service` value:

- `iMessage`

## Endpoints

### `GET /api/chats`

Query params:

- `limit` optional, default `100`, max `500`
- `offset` optional, default `0`
- `withArchived` optional, default `false`
- `service` optional, default `iMessage`

Behavior:

- if `service != all`, filter by `chat.service_name = service`
- if `withArchived = false`, still exclude archived chats

Example:

```bash
curl -s 'http://127.0.0.1:3000/api/chats?limit=5&offset=0'
curl -s 'http://127.0.0.1:3000/api/chats?service=SMS&withArchived=true'
curl -s 'http://127.0.0.1:3000/api/chats?service=all'
```

### `GET /api/messages/recent`

Query params:

- `limit` optional, default `100`, max `500`
- `offset` optional, default `0`
- `service` optional, default `iMessage`
- `includeEmpty` optional, default `false`

Behavior:

- if `service != all`, join `chat_message_join` and `chat`, then filter by `chat.service_name = service`
- by default, only return messages where `message.text IS NOT NULL OR message.cache_has_attachments = 1`
- if `includeEmpty = true`, disable the empty-message filter

Example:

```bash
curl -s 'http://127.0.0.1:3000/api/messages/recent?limit=5&offset=0'
curl -s 'http://127.0.0.1:3000/api/messages/recent?service=SMS'
curl -s 'http://127.0.0.1:3000/api/messages/recent?service=all&includeEmpty=true'
```

### `GET /api/chats/{guid}/messages`

Query params:

- `limit` optional, default `100`, max `500`
- `offset` optional, default `0`
- `includeEmpty` optional, default `false`

Behavior:

- return `404` if the chat GUID does not exist
- by default, only return messages where `message.text IS NOT NULL OR message.cache_has_attachments = 1`
- if `includeEmpty = true`, disable the empty-message filter

Example:

```bash
curl -s 'http://127.0.0.1:3000/api/chats/<guid>/messages?limit=10&offset=0'
curl -s 'http://127.0.0.1:3000/api/chats/<guid>/messages?includeEmpty=true'
```

## Validation

- invalid `limit` or `offset` returns `400`
- invalid `service` returns `400`
- invalid `withArchived` returns `400`
- invalid `includeEmpty` returns `400`
