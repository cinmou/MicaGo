# MicaGoServer v0.4.0 WebSocket

## Goal

Add a lightweight realtime websocket layer on top of the existing architecture:

`chat.db -> sync loop -> relay.db -> REST API / WebSocket`

## Architecture

- `GET /ws` upgrades to a plain websocket connection
- sync loop remains the only source of new-message realtime events
- no Socket.IO compatibility
- no auth
- no file watching over `chat.db` or `chat.db-wal`

## Event envelope

All websocket messages use:

```json
{
  "type": "message:new",
  "data": {}
}
```

## Event types

### `message:new`

Payload:

- existing `MessageJSON`

Emitted when:

- a sync run inserts a previously unseen message into `relay.db`

### `send:pending`

Payload:

```json
{
  "tempGuid": "client-generated-id",
  "chatGuid": "any;-;example@icloud.com"
}
```

Emitted when:

- a send request is accepted and its pending record is created (v0.12.0).
  Always followed by a terminal `send:match` / `send:error`.

### `send:match`

Payload:

```json
{
  "tempGuid": "client-generated-id",
  "message": {}
}
```

Emitted when:

- a pending send is confirmed against the database

### `send:error`

Payload:

```json
{
  "tempGuid": "client-generated-id",
  "chatGuid": "any;-;example@icloud.com",
  "code": "send_confirmation_timeout",
  "message": "AppleScript completed but no matching outgoing message appeared in chat.db before the confirmation timeout",
  "text": "hello world"
}
```

`code` is one of `send_failed`, `send_error`, `messages_app_not_running`,
`send_confirmation_timeout`. The timeout case adds `text` (v0.12.0; previously
`send_timeout`).

Emitted when:

- AppleScript send fails
- send confirmation times out

### `sync:error`

Payload:

```json
{
  "message": "periodic sync failed"
}
```

Emitted when:

- a non-startup periodic sync run fails

## Endpoint

### `GET /ws`

- accepts websocket upgrade
- supports multiple concurrent clients
- server shutdown closes open websocket clients

## Test plan

1. Start the server.
2. Connect with `websocat ws://127.0.0.1:3000/ws` or `wscat -c ws://127.0.0.1:3000/ws`.
3. Wait for the next sync-discovered incoming or outgoing iMessage.
4. Confirm `message:new` arrives once per newly inserted relay row.
5. Send a message through `POST /api/chats/{guid}/send`.
6. Confirm `send:match` arrives on success.
7. Force a send failure or timeout and confirm `send:error`.

## Limitations

- no replay/backfill endpoint over websocket
- no auth
- no typing indicators
- no read receipts
- no edit/reaction/unsend-specific events
- no file watching; realtime latency follows sync interval
