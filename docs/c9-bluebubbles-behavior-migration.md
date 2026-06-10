# C9 BlueBubbles Behavior Migration

Date: 2026-06-09

Reference path note: the requested `MicaGoFlutterClient/Ref/` directory does not exist in this checkout. The actual reference folder is `/Users/Cinmou/Documents/GitHub/MicaGo/Ref/`, containing `bluebubbles server` and `bluebubbles-app-master`.

## Files Inspected

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
- `Ref/bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/index.ts`
- `Ref/bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts`

Client:

- `Ref/bluebubbles-app-master/lib/services/network/socket_service.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/action_handler.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/queue/queue_impl.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/sync/chat_sync_manager.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/sync/full_sync_manager.dart`
- `Ref/bluebubbles-app-master/lib/services/backend/sync/incremental_sync_manager.dart`
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

## Behavior Summary And Migration

Database sync:

- BlueBubbles watches `chat.db`/WAL files, debounces change handling by about 500 ms, serializes processing with a semaphore, and polls from `lastCheck - 30s`.
- It queries with a one-week `dateCreated` lookback for index performance, then filters in memory for delivered/read/edited/retracted/error changes.
- MicaGo equivalent before C9 was periodic sync + explicit catch-up + update pass.
- C9 adds a `chat.db`/WAL mtime trigger loop that runs through the same sync mutex and records diagnostics.

Message updates:

- BlueBubbles caches per-guid state and emits `updated-entry` when delivered, read, edited, retracted, notify, or unsent-part state changes.
- MicaGo already has update pass; C9 makes it run promptly after mtime-triggered sync.

Outgoing sends:

- BlueBubbles stores `MessagePromise` records for sends, with tempGuid, normalized text/subject, chat guid, sent time, and longer timeout. Poller resolution replaces temp rows.
- MicaGo C6 introduced pending late match. C9 fixes client-side HTTP 202 handling so AppleScript success + DB timeout becomes `sentUnconfirmed`, not failed.

Client local storage:

- BlueBubbles writes socket/REST data to ObjectBox and UI watches local DB/collections.
- MicaGo now has a `sqflite` local cache for chats/messages/pending sends/metadata. Chat and thread controllers show cached rows first, then patch from REST/WS.

Attachments:

- BlueBubbles converts HEIC/HEIF/TIFF to JPEG server-side when serializer conversion is requested, and converts TIFF/HEIC to PNG client-side for mobile previews.
- MicaGo C9 adds `GET /api/attachments/{guid}/preview`, using `sips` to convert TIFF/HEIC/HEIF to PNG and cache it. Payloads expose `previewUrl` for attachments needing conversion.

Replies, tapbacks, effects, edited/unsent:

- BlueBubbles models replies via `threadOriginatorGuid/threadOriginatorPart`, tapbacks via associated message fields, effects via expressive style, and partial edits/unsends via `messageSummaryInfo`.
- MicaGo currently exposes many of these fields and renders whole-message edited/retracted state. Full partial edit/reply/link preview parity remains a future migration.

Filtering and sorting:

- BlueBubbles chat list is backed by local DB latest message and excludes deleted/archived rows by query.
- MicaGo already stores renderable summaries in relaydb; C9 continues hiding unsupported-only chats by default and preserving Message Inspector raw access.

Connection strategy:

- BlueBubbles can update/fetch server URL and reconnect.
- MicaGo C9 adds persisted connection mode metadata: auto, LAN only, Public only, LAN first. QR pairing remains compatible; after server URL discovery, LAN/Public candidates are saved for future mode selection.

## Remaining Gaps

- MicaGo local cache is a pragmatic `sqflite` cache, not a full ObjectBox-style reactive source for every widget.
- LAN endpoint selection UI is not complete; the model and persistence are in place, but preferred-IP chooser needs Companion/settings UI follow-up.
- Full BlueBubbles partial edit rendering, rich link previews, and complete reply-thread UI are not fully ported.
- Push/Firebase was deliberately not implemented.
- Cloudflare/tunnel management was not changed.

