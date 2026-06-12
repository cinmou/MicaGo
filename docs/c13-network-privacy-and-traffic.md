# C13 Network Privacy and Traffic

Client does not upload:

- contacts
- avatars
- message history
- attachment files during bootstrap

Client sends:

- bearer token/auth checks
- health/server URL checks
- send requests
- sync/catch-up commands
- local display/settings requests needed to read server-owned scope

Bootstrap traffic:

1. Android asks the server to sync/catch up.
2. Android fetches the chat list.
3. Android fetches recent renderable messages per chat.
4. Android writes chats/messages/attachment metadata to `micago_client_cache.db`.
5. Attachment bytes are fetched only through preview/download URLs when visible or requested.

Diagnostics:

- Android local DB diagnostics expose DB path, schema version, chat count, message count, attachment metadata count, pending send count, last bootstrap/catch-up/write counts, and last error.
- Server diagnostics expose rows scanned and attachment metadata counts, not attachment byte download counts yet.

Remaining gap: exact REST-call counting for the last bootstrap and preview/full attachment download counters are not persisted yet.
