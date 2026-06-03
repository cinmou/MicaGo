# BlueBubbles Realtime Sync And Socket Flow

Scope:

- Reference only: `bluebubbles server`
- No code changes to BlueBubbles or MicaGoServer
- Goal: understand BlueBubbles' realtime message detection and socket broadcast design before a lightweight MicaGoServer v0.4 websocket layer

## 1. How BlueBubbles detects new messages in `chat.db`

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/index.ts` | `startChatListeners` | Starts the realtime pipeline by watching both `chat.db` and `chat.db-wal`, then attaches message and chat pollers. | Yes, conceptually |
| `bluebubbles server/packages/server/src/server/databases/imessage/index.ts` | `MessageRepository` constructor | Defines the watched files as `~/Library/Messages/chat.db` and `~/Library/Messages/chat.db-wal`. | Yes |
| `bluebubbles server/packages/server/src/server/databases/imessage/listeners/IMessageListener.ts` | `start` | Seeds caches with an initial poll, then starts a filesystem watcher over the DB files. | Maybe |
| `bluebubbles server/packages/server/src/server/lib/MultiFileWatcher.ts` | `watchFile` | Uses `fs.watch(...)` on each file and emits a change event whenever file stats change. | Maybe |
| `bluebubbles server/packages/server/src/server/databases/imessage/listeners/IMessageListener.ts` | `handleChangeEvent` | Debounces change bursts, serializes processing with a semaphore, computes a lookback time, and triggers pollers. | Yes, conceptually |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/MessagePoller.ts` | `poll` | Queries recent messages after a lookback window, then decides which are new, updated, unsent, or errored. | Yes |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/ChatChangePoller.ts` | `poll` | Separately queries chats whose read timestamp changed and emits a chat-level update event. | Maybe |

### Summary

BlueBubbles does not rely on private API events for ordinary message realtime updates. Its main path is:

1. watch `chat.db` and `chat.db-wal`
2. on change, debounce and poll the database
3. compare rows against in-memory state caches
4. emit semantic events

## 2. Polling vs file watching vs timers vs private API

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/lib/MultiFileWatcher.ts` | `fs.watch` usage | Realtime trigger is file watching, not a fixed polling loop. | Maybe |
| `bluebubbles server/packages/server/src/server/databases/imessage/listeners/IMessageListener.ts` | `@DebounceSubsequentWithWait(..., 500)` | Changes are debounced for 500ms to avoid repeated bursts from WAL writes. | Yes, conceptually |
| `bluebubbles server/packages/server/src/server/databases/imessage/listeners/IMessageListener.ts` | `poll` | Actual database change detection still happens by querying the DB after a computed `after` timestamp. | Yes |
| `bluebubbles server/packages/server/src/server/api/http/index.ts` | `socketOpts.transports` | Socket.IO accepts both websocket and long-polling transports for client compatibility. | No |
| `bluebubbles server/packages/server/src/server/api/privateApi/eventHandlers/*` | private API event handlers | Private API is used for other features like typing, FaceTime, Find My, but not as the primary new-message detector. | No |
| `bluebubbles server/packages/server/src/server/lib/ScheduledService.ts` | `setInterval` usage | Timers exist elsewhere in the app, but not as the primary iMessage realtime trigger. | No |

### Summary

BlueBubbles is best described as:

- filesystem-triggered
- database-polled
- cache-diffed

It is not a pure timer loop, and it is not primarily driven by private API events for message creation.

## 3. How it decides that a message is new or updated

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/index.ts` | `IMessagePoller.getMessageEvent` | A message is `new-entry` if its GUID was never seen; otherwise it is `updated-entry` if delivery, read, edit, retract, notify, or unsent-part state advanced. | Yes |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/index.ts` | `MessageState` | Stores previous values for `dateCreated`, `isDelivered`, `dateDelivered`, `dateRead`, `dateEdited`, `dateRetracted`, `didNotifyRecipient`, and `hasUnsentParts`. | Maybe |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/index.ts` | `processMessageEvent` | Adds unseen GUIDs to the event cache and updates the message state snapshot after classification. | Yes |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/MessagePoller.ts` | `poll` | Filters queried messages to those whose created/delivered/read/edited/retracted/notify state falls after the lookback threshold. | Yes |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/index.ts` | `getChatEvent` / `processChatEvent` | Chat-level change detection is much narrower: it tracks `lastReadMessageTimestamp` and emits `chat-read-status-changed`. | Maybe |

### Summary

BlueBubbles distinguishes:

- new message: unseen GUID
- updated message: same GUID, but a tracked status/timestamp changed
- chat update: read timestamp changed

It does not appear to use ROWID as its primary realtime identity. It relies on message GUID plus cached state.

## 4. How it avoids duplicate events

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/index.ts` | `IMessageCache.events` | Keeps a time-trimmed event cache so already-seen GUIDs do not emit as new repeatedly. | Yes |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/index.ts` | `trimCaches` | Periodically trims cached event and state entries so memory does not grow forever. | Maybe |
| `bluebubbles server/packages/server/src/server/databases/imessage/listeners/IMessageListener.ts` | `processLock: Sema` | Serializes overlapping file-change processing so concurrent DB polls do not duplicate work. | Maybe |
| `bluebubbles server/packages/server/src/server/databases/imessage/listeners/IMessageListener.ts` | `handleChangeEvent` | Applies a 30-second lookback but depends on the caches to prevent duplicates from that intentional overlap. | Yes, conceptually |
| `bluebubbles server/packages/server/src/server/api/http/index.ts` | `sendCache` | Separately deduplicates outbound sends by `tempGuid` before they enter the outgoing-message manager. | Yes, for send path |

### Summary

BlueBubbles intentionally over-reads recent history, then uses caches to suppress duplicates. The two important duplicate guards are:

- message/chat event cache for incoming realtime events
- `tempGuid` send cache for outgoing sends

## 5. How outgoing pending messages are resolved during sync

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/index.ts` | `OutgoingMessageManager.add` / `resolve` / `reject` | Stores pending outbound match promises and resolves or rejects them when a polled DB message matches. | Yes |
| `bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise.isSame` | Match logic compares chat GUID, normalized text via `message.universalText(true)`, optional subject, and `sentAt`. | Yes |
| `bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `emitMessageMatch` | On successful match, removes the temp GUID from send cache and emits a socket event for the matched message. | Yes |
| `bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `emitMessageError` | On send failure with a DB-backed message, removes temp GUID and emits a send-error event. | Yes |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/MessagePoller.ts` | `poll` | For outgoing messages from yourself, each detected message attempts `Server().messageManager.resolve(entry)` before the normal event result is emitted. | Yes |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/MessagePoller.ts` | `handlePreviouslyUnsent` | Tracks previously unsent rows, resolves them later if they become sent, or rejects them if an error code appears. | Maybe |

### Summary

BlueBubbles does not confirm sends directly from AppleScript return values. Confirmation happens later, during realtime DB sync:

1. add pending matcher
2. AppleScript returns
3. poller notices a matching outgoing DB row
4. pending promise resolves or rejects
5. socket event is emitted

## 6. How it broadcasts new messages to clients

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/index.ts` | `emitMessage` | Central fan-out method that emits to Socket.IO, then optionally FCM and webhooks. | Yes, simplified |
| `bluebubbles server/packages/server/src/server/index.ts` | `handleNewMessage` | Serializes full message data for sockets and emits `new-message` directly to connected clients. | Yes |
| `bluebubbles server/packages/server/src/server/index.ts` | `handleUpdatedMessage` | Serializes and emits `updated-message` for read, delivered, edited, unsent, and similar changes. | Maybe |
| `bluebubbles server/packages/server/src/server/index.ts` | group-change listeners | Emits specialized group and participant events with richer serialized payloads. | No |
| `bluebubbles server/packages/server/src/server/api/serializers/MessageSerializer.ts` | `serialize` / `serializeList` | Builds the socket payload, including `text: message.universalText(true)`, attachments, and optional chat info. | Yes, conceptually |

### Summary

For websocket clients, BlueBubbles usually emits already-serialized message/chat payloads, not raw DB entities.

## 7. Socket events BlueBubbles emits

### Message creation

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/events.ts` | `NEW_MESSAGE = "new-message"` | Canonical realtime event for a newly seen message. | Yes, conceptually |
| `bluebubbles server/packages/server/src/server/index.ts` | `handleNewMessage` | Emits `new-message` to sockets with serialized message payload including chats. | Yes |
| `bluebubbles server/packages/server/src/server/index.ts` | `emitMessageMatch` | Also emits the send-confirmed outgoing message as `new-message`, but with `tempGuid` attached. | Yes |

### Message updates

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/events.ts` | `MESSAGE_UPDATED = "updated-message"` | Canonical realtime event for message status/content updates. | Maybe |
| `bluebubbles server/packages/server/src/server/index.ts` | `handleUpdatedMessage` | Emits updated-message when delivery/read/edit/retract/notify state changed. | Maybe |

### Chat updates

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/events.ts` | `CHAT_READ_STATUS_CHANGED = "chat-read-status-changed"` | Canonical event for chat read-state changes. | Maybe |
| `bluebubbles server/packages/server/src/server/index.ts` | `iMessageListener.on(CHAT_READ_STATUS_CHANGED, ...)` | Emits `{ chatGuid, read: true }` when a chat read timestamp advances. | Maybe |

### Attachment update

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/api/http/api/v1/socketRoutes.ts` | `get-attachment-chunk` | Socket.IO is used for attachment download chunks, but there is no separate generic realtime `attachment-updated` event in the core iMessage listener flow. | No |
| `bluebubbles server/packages/server/src/server/api/serializers/MessageSerializer.ts` | `AttachmentSerializer` integration | Attachments are included inside message payloads rather than emitted as a standalone realtime attachment-change event. | No |

### Send match / send error

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/index.ts` | `emitMessageMatch` | Emits the matched outgoing message as `new-message` with `tempGuid`. | Yes |
| `bluebubbles server/packages/server/src/server/index.ts` | `emitMessageError` | Emits `message-send-error` with serialized message data and optional `tempGuid`. | Yes |
| `bluebubbles server/packages/server/src/server/events.ts` | `MESSAGE_SEND_ERROR = "message-send-error"` | Canonical send-failure event. | Yes |
| `bluebubbles server/packages/server/src/server/api/http/api/v1/socketRoutes.ts` | `send-message` callback response | The request-response callback may also return `message-sent` or `message-send-error`, but that is separate from the async broadcast path. | Maybe |

### Sync state or errors

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/api/http/index.ts` | socket middleware `exception` emit | Per-request socket exceptions are emitted as `exception`. | Maybe |
| `bluebubbles server/packages/server/src/server/index.ts` | `iMessageListener.on("error", ...)` | Listener errors are logged, but there is no dedicated public realtime `sync-error` or `sync-state` event for iMessage DB polling. | No |
| `bluebubbles server/packages/server/src/server/events.ts` | `HELLO_WORLD = "hello-world"` | On server startup, connected clients receive a basic hello-world event. | No |

## 8. How socket clients authenticate and connect

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/api/http/index.ts` | `HttpService.start` socket connection handler | Socket.IO clients connect over websocket or polling and authenticate by sending the configured password in the handshake query. | No |
| `bluebubbles server/packages/server/src/server/api/http/index.ts` | `socket.use(...)` | Socket event middleware catches per-event errors and emits `exception` responses. | Maybe |

### Summary

BlueBubbles' socket auth is intentionally simple in this layer: handshake password query plus disconnect on mismatch. This is enough to understand the architecture, but not something MicaGoServer needs to copy yet if auth is explicitly deferred.

## 9. What is too heavy for MicaGoServer

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.4 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/api/http/index.ts` | `SocketServer` with polling fallback, encryption, FCM integration | The full transport/auth/notification stack is much broader than MicaGoServer needs. | No |
| `bluebubbles server/packages/server/src/server/index.ts` | `emitMessage` fan-out to socket + FCM + webhooks | Mica can keep websocket broadcast only. | No |
| `bluebubbles server/packages/server/src/server/databases/imessage/listeners/IMessageListener.ts` | file watcher + semaphore + debounce stack | Useful, but heavier than necessary when Mica already has a periodic relay sync loop. | Maybe |
| `bluebubbles server/packages/server/src/server/databases/imessage/pollers/MessagePoller.ts` | deep update classification including edit/retract/didNotifyRecipient/unsent parts | Mica does not need the full status matrix initially. | Maybe |
| `bluebubbles server/packages/server/src/server/index.ts` | group-change event family | Participant/group-photo/name-change events add significant complexity and can be deferred. | No |
| `bluebubbles server/packages/server/src/server/api/serializers/MessageSerializer.ts` | very rich payload serialization | Mica can keep payloads much smaller by reusing its existing API JSON shape. | Yes, simplified |

## 10. Minimal MicaGoServer v0.4 recommendation

### Detection model

Use periodic polling, not file watching, for the first MicaGoServer websocket layer.

Reason:

- MicaGoServer already has a working `chat.db -> sync -> relay.db` loop.
- Relay sync already tracks incremental progress by `message.ROWID`.
- Reusing that loop is much smaller and easier to reason about than adding `fs.watch`, debounce logic, overlap locks, and a second DB-diff pipeline.

Recommended flow:

1. periodic sync reads new `chat.db` rows into `relay.db`
2. sync function returns the rows that were newly inserted or materially updated
3. websocket broadcaster emits events from those relay sync results
4. pending sends resolve by polling `relay.db`, exactly as the current send path already does

### Event names

Prefer a very small event surface:

- `message:new`
- `message:update`
- `chat:update`
- `send:match`
- `send:error`
- optional later: `sync:error`

If you want to stay closer to BlueBubbles naming, `new-message` and `updated-message` are also reasonable, but Mica should avoid copying BlueBubbles' large event family.

### Payload shape

Reuse existing API JSON shapes where possible.

Recommended payloads:

- `message:new`: existing `MessageJSON`, plus optional `chatGuid`
- `message:update`: existing `MessageJSON`, plus a narrow `change` hint if useful later
- `chat:update`: existing `ChatJSON` or a tiny `{ guid, isArchived, lastMessage? }`
- `send:match`: existing `MessageJSON`, plus `tempGuid`
- `send:error`: `{ tempGuid, code, message, chatGuid }`

Avoid realtime-only custom schemas unless they materially reduce client complexity.

### Duplicate prevention strategy

Keep it simpler than BlueBubbles:

- use `relay.db.messages.guid` as the stable dedupe key
- on each sync cycle, emit `message:new` only for rows newly inserted into `relay.db`
- if later you support status transitions like read/delivered, emit `message:update` only when tracked fields actually changed
- keep `tempGuid` pending dedupe separate, as it already is

In other words, let `relay.db` be the durable dedupe boundary instead of maintaining a large in-memory GUID cache like BlueBubbles.

### Integration with existing `relay.db` sync

Recommended integration:

- extend sync result to include newly inserted message GUIDs and maybe touched chat GUIDs
- after each successful sync cycle, fetch those relay rows and broadcast them
- startup sync should not replay the last 1000 imported messages to fresh websocket clients unless explicitly desired
- keep websocket emission downstream of relay sync so the relay database remains the single source of truth

This preserves the current Mica architecture:

`chat.db -> sync -> relay.db -> API / websocket`

### What to explicitly defer

Defer these from MicaGoServer v0.4:

- Socket.IO compatibility and long-polling fallback
- handshake auth
- FCM / push / webhooks
- file watching on `chat.db` / `chat.db-wal`
- participant/group-name/group-photo events
- attachment chunk streaming
- edit / unsend / reaction-specific events
- broad sync-state lifecycle events beyond maybe a simple logged sync error

The smallest useful v0.4 is:

- websocket connections
- periodic relay-based `message:new`
- optional `send:match` and `send:error`
- maybe `message:update` later if delivered/read transitions become important
