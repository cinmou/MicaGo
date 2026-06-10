# C6 BlueBubbles Sync Audit

Date: 2026-06-08

Scope: foreground sync, send confirmation, realtime message/update routing, attachments, links, replies, edited/unsent state. Push/FCM was inspected only as architecture context and was not ported.

## BlueBubbles Files Inspected

Server:

- `Ref/bluebubbles server/packages/server/src/server/databases/imessage/listeners/IMessageListener.ts`
- `Ref/bluebubbles server/packages/server/src/server/databases/imessage/pollers/MessagePoller.ts`
- `Ref/bluebubbles server/packages/server/src/server/databases/imessage/pollers/ChatChangePoller.ts`
- `Ref/bluebubbles server/packages/server/src/server/databases/imessage/pollers/index.ts`
- `Ref/bluebubbles server/packages/server/src/server/databases/imessage/index.ts`
- `Ref/bluebubbles server/packages/server/src/server/databases/imessage/entity/Message.ts`
- `Ref/bluebubbles server/packages/server/src/server/databases/imessage/entity/Attachment.ts`
- `Ref/bluebubbles server/packages/server/src/server/databases/imessage/entity/decoders/MessageDecoder.ts`
- `Ref/bluebubbles server/packages/server/src/server/databases/imessage/helpers/utils.ts`
- `Ref/bluebubbles server/packages/server/src/server/api/serializers/MessageSerializer.ts`
- `Ref/bluebubbles server/packages/server/src/server/api/serializers/AttachmentSerializer.ts`
- `Ref/bluebubbles server/packages/server/src/server/api/interfaces/messageInterface.ts`
- `Ref/bluebubbles server/packages/server/src/server/api/interfaces/attachmentInterface.ts`
- `Ref/bluebubbles server/packages/server/src/server/api/http/api/v1/socketRoutes.ts`
- `Ref/bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/index.ts`
- `Ref/bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts`

Client:

- `Ref/bluebubbles-app-master/lib/services/network/socket_service.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/action_handler.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/queue/queue_impl.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/sync/chat_sync_manager.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/sync/incremental_sync_manager.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/sync/full_sync_manager.dart`
- `Ref/bluebubbles-app-master/lib/services/ui/chat/chats_service.dart`
- `Ref/bluebubbles-app-master/lib/services/ui/chat/chat_manager.dart`
- `Ref/bluebubbles-app-master/lib/services/ui/message/messages_service.dart`
- `Ref/bluebubbles-app-master/lib/services/ui/message/message_widget_controller.dart`
- `Ref/bluebubbles-app-master/lib/services/ui/attachments_service.dart`
- `Ref/bluebubbles-app-master/lib/database/io/message.dart`
- `Ref/bluebubbles-app-master/lib/database/io/attachment.dart`
- `Ref/bluebubbles-app-master/lib/database/io/chat.dart`
- `Ref/bluebubbles-app-master/lib/database/global/chat_messages.dart`
- `Ref/bluebubbles-app-master/lib/helpers/types/helpers/message_helper.dart`
- `Ref/bluebubbles-app-master/lib/helpers/ui/message_widget_helpers.dart`
- `Ref/bluebubbles-app-master/lib/app/layouts/conversation_view/widgets/message/message_holder.dart`
- `Ref/bluebubbles-app-master/lib/app/layouts/conversation_view/widgets/message/interactive/url_preview.dart`

## What BlueBubbles Does

Detection:

- Watches `chat.db` and related WAL files via `IMessageListener`, debounced by about 500 ms.
- On start, seeds cache with an initial poll based on the earliest DB modified time minus one minute.
- On file change, polls from `lastCheck - 30 seconds`; if the listener was asleep for more than 24 hours, it bounds the window to 24 hours.
- Uses a semaphore to prevent overlapping DB processing.

Message scanning:

- `MessagePoller` queries messages by `dateCreated` with a one-week lookback for index-friendly fetches, then filters in memory for the real after-time.
- Updates are not rowid-only. It considers `dateDelivered`, `isDelivered`, `dateRead`, `dateEdited`, `dateRetracted`, `hasUnsentParts`, and `didNotifyRecipient`.
- `IMessageCache` stores per-guid mutable state and emits `new-entry` or `updated-entry` only when state changes.
- Unsent outgoing rows are tracked in `unsentIds`; later polls re-fetch them to detect sent or errored transitions.

Outgoing confirmation:

- Sends are registered as `MessagePromise` records containing `tempGuid`, chat guid, normalized text/subject, sent timestamp, and attachment filename when relevant.
- Text sends time out after about two minutes; attachments after about twenty minutes.
- When `MessagePoller` sees an outgoing matching row, it calls `messageManager.resolve(entry)`.
- Matching checks chat guid variants, normalized text or attributed body, optional subject, and `sentAt <= dateCreated`.
- If a matching row has a non-zero error, the manager rejects it and emits a send error.

Socket/client flow:

- Server emits events such as `new-message`, `updated-message`, group events, and read-status changes.
- Client `SocketService` reconnects automatically and calls `NetworkTasks.onConnect()`.
- `ActionHandler` parses events into `IncomingItem`s, queues them, writes/replaces local ObjectBox records, and updates current chat services from the local DB layer.
- `tempGuid` is used to replace optimistic local messages with server-confirmed rows. If an outgoing real row arrives before the `tempGuid` match event, BlueBubbles briefly delays and de-dupes out-of-order events.

Chat list and thread freshness:

- `ChatsService` watches the local chat database and updates/sorts the list when chats or latest messages change.
- `MessagesService` watches local message count for the active chat and only handles new rows for that chat.
- Updated messages are merged by guid; attachments are replaced by guid; stale temp rows are removed.

Attachments, links, replies, edits:

- Server-side `convertImage` converts HEIC/HEIF/TIFF to JPEG when conversion is requested.
- Client-side `AttachmentsService.loadAndGetProperties` converts HEIC and TIFF to PNG on mobile before previewing when possible.
- Link data comes from `payloadData`/URL metadata and is rendered by URL preview widgets; BlueBubbles does not rely only on raw text scraping when Apple payload data exists.
- Reply threading uses `threadOriginatorGuid` and `threadOriginatorPart`; the client caches originator messages and renders reply/thread affordances.
- Edits and partial unsends are modeled through `messageSummaryInfo` edited/retracted parts. `MessageWidgetController` rebuilds parts, removes retracted parts, and inserts unsent placeholders.

## Concepts To Port Into MicaGo

- Do not rely on `ROWID` alone for realtime correctness. Use a bounded lookback/update pass for mutable state and a DB-change or catch-up trigger to reduce delay.
- Keep send records alive after initial timeout when AppleScript succeeded. Treat this as unconfirmed, then late-match real outgoing rows.
- Run sync after send and after reconnect/resume, with throttling and no overlap.
- Include `chatGuid` and complete message payloads in events so the client can update the active thread and chat list without global reload.
- Keep TIFF placeholder now, but design `GET /api/attachments/{guid}/preview` to match BlueBubbles' conversion concept later.
- Preserve `payloadData`, `messageSummaryInfo`, and reply fields for future link/reply/edit fidelity.

