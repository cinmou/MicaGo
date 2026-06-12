# C14 Client Refresh Reference

This note documents how `Ref/imsgweb-main` and `Ref/imsg` handle live refresh,
history paging, reactions, replies, attachments, and send status. It is a
planning document only; no client implementation changes are made here.

## Reference Files Read

| Area | File / function |
| --- | --- |
| imsgweb API routes | `Ref/imsgweb-main/server/index.ts` |
| imsgweb SSE client | `Ref/imsgweb-main/web/events.ts`, `connectEvents` |
| imsgweb frontend store | `Ref/imsgweb-main/web/store.svelte.ts`, `Store.start`, `handleEvent`, `trackSendStatus` |
| imsgweb merge model | `Ref/imsgweb-main/web/model.ts`, `upsertMessage`, `applyReactionEvent`, `bumpChat` |
| imsgweb payload shaping | `Ref/imsgweb-main/server/payloads.ts`, `toApiMessage`, `toApiChat` |
| imsgweb RPC bridge | `Ref/imsgweb-main/server/rpc/index.ts`, `RpcClient.watch` |
| imsgweb RPC types | `Ref/imsgweb-main/server/rpc/types.ts`, `WatchSubscribeParams`, `MessagePayload` |
| imsg watcher | `Ref/imsg/Sources/IMsgCore/MessageWatcher.swift`, `MessageWatcher.stream`, `WatchState.poll` |
| imsg event tailer | `Ref/imsg/Sources/IMsgCore/IMsgEventTailer.swift`, `events`, `drainAvailable` |
| imsg RPC watch handler | `Ref/imsg/Sources/imsg/RPCServer+Handlers.swift`, `handleWatchSubscribe`, `buildMessagePayload` |
| imsg watch CLI | `Ref/imsg/Sources/imsg/Commands/WatchCommand.swift`, `WatchCommand.run` |
| imsg message queries | `Ref/imsg/Sources/IMsgCore/MessageStore+Messages.swift`, `messagesAfterBatch` |
| imsg query SQL builders | `Ref/imsg/Sources/IMsgCore/MessageStore+Queries.swift`, `MessagesAfterQuery`, `ChatMessagesQuery` |
| imsg watch docs | `Ref/imsg/docs/watch.md` |

## Reference Refresh Model

`imsgweb-main` uses a push-first model, not a repeated full refresh:

1. The browser opens `GET /api/events` with `EventSource`.
2. The server maps `Last-Event-ID` or `?since=` to `imsg`'s `since_rowid`.
3. The server calls `rpc.watch({ since_rowid, attachments: true, convert_attachments: true, include_reactions: true })`.
4. Each pushed message is emitted as an SSE `event: message` with `id = message.id`.
5. Browser reconnection is delegated to `EventSource`; resume state is stateless because the SSE event id is the message rowid.
6. The frontend applies the event locally with `upsertMessage`, `applyReactionEvent`, or `bumpChat`.

The key point is that the server sends a complete enough event payload for the
client to patch local state immediately. The client does not need to reload the
whole thread for every normal incoming message.

## imsg Watch Mechanics

`MessageWatcher` in `Ref/imsg/Sources/IMsgCore/MessageWatcher.swift` watches:

- `~/Library/Messages/chat.db`
- `~/Library/Messages/chat.db-wal`
- `~/Library/Messages/chat.db-shm`
- the containing directory

The directory watch exists so WAL/SHM creation, deletion, and replacement can
be noticed. File events schedule a debounced poll; the default CLI debounce is
250 ms and the RPC default is documented as 500 ms.

`MessageWatcher` also runs a fallback poll every 5 seconds. This is important:
filesystem events can be dropped or coalesced after sleep/wake, heavy I/O, or
SQLite WAL rotation. The fallback poll refreshes file sources and scans by
`ROWID > cursor`.

The row query is `MessagesAfterQuery`:

```sql
SELECT ...
FROM message m
LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
LEFT JOIN handle h ON m.handle_id = h.ROWID
WHERE m.ROWID > ?
ORDER BY m.ROWID ASC
LIMIT ?
```

When `include_reactions` is false, tapback rows are filtered out. When it is
true, tapback add/remove rows are streamed as reaction events.

## Client Merge Rules From imsgweb

`Ref/imsgweb-main/web/model.ts` defines the important frontend invariants:

- `upsertMessage`: insert or replace by `id`, then keep the list sorted oldest
  to newest by `id`.
- Do not append blindly. `history` and `watch` can re-emit the same rowid.
- `applyReactionEvent`: reaction rows are not inserted as standalone chat
  bubbles. They update the target message's aggregated `reactions`.
- Reaction identity is not just `sender`; imsg notes that own and peer reactions
  can share a sender value, so matching uses `sender + is_from_me + type`.
- `bumpChat`: update chat preview and sort the chat list only if the incoming
  message is at least as new as the current preview. Older replayed events
  should not move a chat backwards.
- Unknown chat on an event means refetch the chat list; this covers a new 1:1
  thread created by sending to a fresh handle.

## Replies, Reactions, Polls, Attachments

`toApiMessage` in `Ref/imsgweb-main/server/payloads.ts` applies display shaping:

- Attachment metadata is included in history and watch when requested.
- Browser-playable files use the original attachment; unsupported media can use
  converted metadata.
- Missing attachments are represented as stable metadata with `missing: true`;
  clients should not cache a missing byte response permanently.
- `reply_to_guid` is not enough to show an inline reply. imsgweb only preserves
  reply metadata when `thread_originator_guid` exists. Otherwise it deletes
  `reply_to_guid`, `reply_to_text`, and `reply_to_sender` because ordinary
  consecutive messages can have Apple-internal linkage that is not a real reply.
- Attachment-only quoted parents are displayed as `"Attachment"` after stripping
  placeholder text.
- Poll creation/vote rows are normal message payloads with a `poll` object.
- Tapbacks are event rows when streamed with `include_reactions`; history returns
  aggregated reactions on target messages.

## Send Status

`imsgweb-main` does not optimistically add the sent bubble in the selected
thread. `Store.send` waits for the SSE echo to insert the message. It separately
polls `GET /api/messages/:guid/status` using `trackSendStatus`:

- Initial state is `pending`.
- It polls quickly for the first few attempts, then more slowly.
- `date_read` upgrades the state to `read`.
- `failed` stops polling.

This separates "message row exists and should render" from "delivery/read state
changed later".

## Important Limitation: New Rows vs Existing Row Mutation

The `imsg` watcher scans `ROWID > cursor`. This is excellent for new incoming
or outgoing rows, reaction rows, and poll rows. It does not by itself detect
changes to an existing row whose `ROWID` does not change, such as:

- edit markers / edited text fields,
- retraction / unsend fields,
- delivered/read status changes,
- late attachment metadata updates on an already-seen message.

`imsgweb-main` handles send delivery/read status with a point poll by GUID.
For general edit/retract/read-state convergence, MicaGo should keep the server
side update/lookback pass as the source of truth and broadcast `message:update`
or `message:unsend` events with complete payloads.

## Current MicaGo Client Observations

Files read:

- `MicaGoFlutterClient/lib/core/network/websocket_client.dart`
- `MicaGoFlutterClient/lib/features/chats/chat_list_controller.dart`
- `MicaGoFlutterClient/lib/features/chats/thread_controller.dart`
- `MicaGoFlutterClient/lib/core/network/api_client.dart`
- `MicaGoFlutterClient/lib/core/storage/local_cache_store.dart`

Current client behavior:

- The Flutter client already has a WebSocket event stream.
- `ThreadController` consumes `message:new`, `message:update`, `message:unsend`,
  and `send:*` events.
- If a `message:new` or `message:update` event contains a full message with
  `chatGuid`, the thread upserts it into `MessageCollection` and writes it to
  local cache.
- If the event is incomplete, the thread schedules a 400 ms silent reload.
- `ChatListController` reloads the whole chat list after `message:new`,
  `message:update`, or `message:unsend`, debounced by 150 ms.
- Startup calls `app.catchUp(...)` from chat list and thread controllers.

Likely gap:

The client can feel stale if realtime events are incomplete, delayed, missed, or
not replayed after reconnect. In those cases the UI waits for explicit reloads
or catch-up, even though the server may already have the message in relaydb.

## Migration Direction For MicaGo

Recommended target, following imsgweb's logic:

1. Keep normal message data relay-backed.
2. Make server realtime events complete enough for direct local patching:
   `message:new` should include full normal message JSON, chat identifiers,
   attachment metadata, reply fields, reaction fields if relevant, and service
   category.
3. Add a durable realtime cursor on the client, based on server sequence or
   source rowid, equivalent to SSE `Last-Event-ID`.
4. On reconnect, request events or a catch-up delta after the last applied
   cursor before declaring the UI live.
5. Keep WebSocket if desired, but copy EventSource semantics: reconnect,
   resume cursor, heartbeat, and replay.
6. Apply `message:new` directly with upsert-by-stable-id. Do not reload the
   thread when payload is complete.
7. Apply reaction events to the target message, not as standalone bubbles.
8. Apply `message:update` by replacing the existing message by GUID/source id.
9. Apply `message:unsend` by replacing the old content with the server's
   retracted representation.
10. Only reload the chat list when the chat is unknown or the event payload is
    not enough to bump preview.
11. Poll send status by GUID after local sends, separately from message arrival.
12. Preserve attachment metadata during realtime updates; download bytes only
    when the UI needs a preview or full attachment.

## Diagnostics To Add Later

For the refresh problem, the most useful client diagnostics would be:

- realtime transport status,
- last event time,
- last applied event cursor,
- last requested catch-up cursor,
- last catch-up result count,
- number of events patched directly,
- number of events that forced thread reload,
- number of chat-list reloads caused by events,
- number of dropped events due to missing `chatGuid` or malformed payload,
- local DB write count after realtime events,
- reconnect count and last reconnect reason.

These diagnostics would quickly show whether the delay is caused by the server
not broadcasting, client not receiving, event payload incompleteness, local DB
write lag, or UI state not being notified.

## Concrete Hypothesis

Given the current Flutter controller code, the most likely client-side cause of
"server already has the reply but UI does not feel live" is that the app lacks a
robust resume/catch-up cursor tied to realtime delivery. If the WebSocket drops,
connects late, receives an incomplete event, or misses a frame, the UI falls
back to debounced REST reloads or controller-level catch-up. imsgweb avoids this
by making the live stream cursor explicit (`Last-Event-ID` = rowid), replaying
from that cursor, and treating complete message events as authoritative local
patches.

