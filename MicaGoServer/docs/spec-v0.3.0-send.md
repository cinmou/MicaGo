# Mica v0.3.0 Plain-Text Send Spec

## Goal

Add a minimal plain-text send flow to an existing iMessage chat using AppleScript plus post-send confirmation through the existing sync and storage architecture.

## API

Endpoint:

```text
POST /api/chats/{guid}/send
```

Request JSON:

```json
{
  "tempGuid": "client-generated-id",
  "message": "plain text"
}
```

## Request / Response

Success response:

- returns the matched `MessageJSON` for the outgoing message

Failure responses:

- `400 bad_request` for invalid JSON or validation failures
- `404 not_found` if the chat does not exist
- `409 conflict` if the same `tempGuid` is already pending
- `500 send_failed` if AppleScript send fails
- `504 send_timeout` if no matching outgoing message is confirmed before timeout

## Validation

Rules:

1. chat GUID path param is required
2. chat must exist
3. chat must be `iMessage`
4. `tempGuid` is required and non-empty
5. `message` is required and non-empty after trimming
6. duplicate pending `tempGuid` returns `409`
7. invalid JSON returns `400`

## AppleScript Behavior

Send transport:

```applescript
tell application "Messages"
  send "<escaped message>" to chat id "<escaped chatGuid>"
end tell
```

Safety:

- backslashes are escaped
- double quotes are escaped
- `osascript` is invoked directly without shell-concatenating the request text

## Pending Confirmation Flow

On request:

1. create a pending send entry with:
   - `tempGuid`
   - `chatGuid`
   - original message
   - normalized message
   - `sentAt = now - 10 seconds`
   - `timeout = 120 seconds`
2. store it in an in-memory pending manager
3. run AppleScript send
4. trigger one sync immediately after AppleScript returns
5. poll for a match every `500ms`
6. on match, return the matched message
7. on failure or timeout, remove the pending entry and return a stable error

## Matching Rules

When matching an outgoing message:

- same `chat_guid`
- `is_from_me = 1`
- normalized relay/chatdb text equals normalized request message
- `date_created >= sentAt`

When `api-store=relaydb`, matching is performed against relay.db rows.
When `api-store=chatdb`, matching is performed against direct chat.db reads.

## Manual Test Steps

1. Start the server:

```bash
go run ./cmd/micago
```

2. Find a real iMessage chat GUID:

```bash
curl -s 'http://127.0.0.1:3000/api/chats?limit=10'
```

3. Send a test message:

```bash
CHAT_GUID='<real-guid>' MESSAGE='test from MicaGoServer' ./scripts/smoke-v0.3.0-send.sh
```

4. Confirm:

- HTTP status is `200`
- the returned message GUID is present
- the outgoing message appears in Messages

## Limitations

- existing chat GUID only
- iMessage chats only
- no SMS / RCS send
- no new chat creation by phone number or email
- no attachments
- no Private API
- no reactions, edit, or unsend
