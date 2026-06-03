# MicaGoServer v0.5.0 Attachments

## Goal

Add read-only attachment metadata and safe file download without changing the existing sync architecture.

## Architecture

- attachment metadata is synced from `chat.db` into `relay.db`
- raw attachment file bytes are never copied into `relay.db`
- REST responses include attachment metadata on each message
- downloads are served by looking up attachment GUIDs in `relay.db`

## Relay schema

New table:

- `attachments`

Columns:

- `guid`
- `message_guid`
- `filename`
- `mime_type`
- `transfer_name`
- `total_bytes`
- `local_path`
- `is_outgoing`
- `hide_attachment`
- `created_at`

## Message JSON

`MessageJSON` now includes:

```json
"attachments": [
  {
    "guid": "at_123",
    "filename": "IMG_0001.HEIC",
    "mimeType": "image/heic",
    "transferName": "IMG_0001.HEIC",
    "totalBytes": 4626339,
    "downloadUrl": "/api/attachments/at_123"
  }
]
```

## Endpoint

### `GET /api/attachments/{guid}`

Behavior:

- looks up attachment metadata by GUID in `relay.db`
- resolves the stored local path
- only serves files under `~/Library/Messages/Attachments/`
- rejects hidden attachments
- rejects missing files
- rejects paths outside the allowed attachment root
- streams the file with `Content-Type` and `Content-Disposition`

## Test plan

1. Run a sync so recent message attachments are present in `relay.db`.
2. Call `GET /api/messages/recent?limit=10`.
3. Confirm message payloads include `attachments`.
4. Pick one attachment GUID and call `GET /api/attachments/{guid}`.
5. Confirm headers are present and the response streams bytes.
6. Try a missing GUID and confirm `404`.
7. Try an attachment that resolves outside the allowed root and confirm `404`.

## Limitations

- metadata only; no attachment send
- no thumbnail generation
- no attachment websocket event type
- no raw file caching in `relay.db`
