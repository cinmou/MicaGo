# BlueBubbles Server Full Architecture Audit

Scope: reference-only audit of `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server` for MicaGoServer planning. This document cites exact BlueBubbles file paths and function/class names. If something was not confirmed in source, it is marked `not found`.

## 1. Startup And Lifecycle

Purpose: initialize Electron, config DB, iMessage DB, services, permissions, listeners, and restart flows.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/index.ts`
- Key classes/functions:
  - `BlueBubblesServer`
  - `Server(args, win)`
  - `BlueBubblesServer.initServer()`
  - `BlueBubblesServer.initDatabase()`
  - `BlueBubblesServer.initServices()`
  - `BlueBubblesServer.startServices()`
  - `BlueBubblesServer.start()`
  - `BlueBubblesServer.preChecks()`
  - `BlueBubblesServer.postChecks()`
  - `BlueBubblesServer.startChatListeners()`
- One short explanation:
  - BlueBubbles is a singleton Electron app with a long-lived server object that wires config changes, database initialization, permission checks, service startup, and chat listeners into one lifecycle.
- Runtime dependencies:
  - `electron`, `electron-log`, `events`
- Data dependencies:
  - config DB via `ServerRepository.initialize()`
  - iMessage DB via `MessageRepository.initialize()`
- API/socket surface:
  - indirect; startup brings up `HttpService`, Socket.IO, proxy services, FCM, private API, listeners.
- macOS permissions involved:
  - Full Disk Access via `hasDiskAccess`
  - Accessibility via `hasAccessibilityAccess`
  - Contacts permission warning in `postChecks()`
- Classification:
  - core
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - ongoing foundation, already partly copied by v0.x app bootstrap

## 2. Config System

Purpose: persist runtime settings and allow config-driven service behavior.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/constants.ts`
- Key classes/functions:
  - `ServerRepository`
  - `ServerRepository.initialize()`
  - `ServerRepository.loadConfig()`
  - `ServerRepository.getConfig()`
  - `ServerRepository.setConfig()`
  - `DEFAULT_DB_ITEMS`
- One short explanation:
  - Config is stored in BlueBubbles’ own SQLite DB and can trigger live service changes through the repository’s `"config-update"` event.
- Runtime dependencies:
  - `typeorm`, `better-sqlite3`
- Data dependencies:
  - `Config` rows in config DB
- API/socket surface:
  - exposed by HTTP/server settings routes and Electron IPC.
- macOS permissions involved:
  - none directly
- Classification:
  - core
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - v0.x to v1.0 as small file/env/SQLite config

## 3. Server SQLite / Config DB

Purpose: store server-only state separate from `chat.db`.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/Config.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/Device.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/Queue.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/Webhook.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/Contact.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/ContactAddress.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/ScheduledMessage.ts`
- Key classes/functions:
  - `ServerRepository.devices()`
  - `ServerRepository.queue()`
  - `ServerRepository.webhooks()`
  - `ServerRepository.contacts()`
  - `ServerRepository.scheduledMessages()`
- One short explanation:
  - This DB is a general-purpose control plane for devices, alerts, queue items, contacts, webhooks, and scheduled messages.
- Runtime dependencies:
  - `typeorm`, `better-sqlite3`
- Data dependencies:
  - config DB at `app.getPath("userData")/.../config.db`
- API/socket surface:
  - many HTTP, socket, IPC, and service modules depend on it.
- macOS permissions involved:
  - none directly
- Classification:
  - core for BlueBubbles, heavy for Mica if copied wholesale
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - relay/config state only; do not copy devices/webhooks/contacts tables unless needed

## 4. HTTP API Routes

Purpose: broad product API for chats, messages, settings, attachments, FCM, server admin, macOS actions, contacts, Find My, FaceTime, and backups.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/api/v1/httpRoutes.ts`
- Key classes/functions:
  - `HttpService`
  - `HttpService.configureKoa()`
  - `HttpService.start()`
  - `HttpRoutes.api`
- One short explanation:
  - BlueBubbles’ HTTP layer is a large Koa surface, not a narrow message API.
- Runtime dependencies:
  - `koa`, `koa-router`, `koa-body`, `koa-json`, `koa-cors`
- Data dependencies:
  - config DB, iMessage DB, contacts, filesystem, private API, update service
- API/socket surface:
  - HTTP groups visible in `HttpRoutes.api`: `General`, `macOS`, `iCloud`, `Server`, `FCM`, `Attachment`, `Message`, `Chat`, `Handle`, `Settings`, `Contacts`, `Themes`, `Scheduled Messages`, `Webhooks`, `FaceTime`
- macOS permissions involved:
  - depends on route; some routes require Automation / Full Disk Access / Contacts
- Classification:
  - core
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - keep small REST surface; skip admin sprawl

## 5. Socket.IO Routes And Events

Purpose: realtime RPC-ish client transport plus event delivery for BlueBubbles clients.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/api/v1/socketRoutes.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/events.ts`
- Key classes/functions:
  - `SocketRoutes.createRoutes(socket)`
  - `HttpService.start()`
- One short explanation:
  - BlueBubbles uses Socket.IO as both a command channel and an event stream, with a very wide event surface.
- Runtime dependencies:
  - `socket.io`
- Data dependencies:
  - same backends as HTTP plus message manager, listeners, FCM, queue service
- API/socket surface:
  - command events include `get-chats`, `get-chat`, `get-chat-messages`, `get-messages`, `get-attachment`, `send-message`, `start-chat`, `rename-group`, `send-reaction`, `restart-messages-app`
  - outbound events in `events.ts` include `new-message`, `updated-message`, `message-send-error`, `chat-read-status-changed`, `typing-indicator`, `server-update`
- macOS permissions involved:
  - indirect, depending on invoked actions
- Classification:
  - core for BlueBubbles, heavy for Mica
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - v0.4+ style lightweight WS only, not Socket.IO RPC

## 6. iMessage `chat.db` Repository

Purpose: typed access layer over Apple Messages database.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/imessage/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/imessage/entity/Message.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/imessage/entity/Attachment.ts`
- Key classes/functions:
  - `MessageRepository`
  - `MessageRepository.initialize()`
  - `MessageRepository.getChats()`
  - `MessageRepository.getMessages()`
  - `MessageRepository.getMessagesRaw()`
  - `MessageRepository.getUpdatedMessages()`
  - `MessageRepository.getAttachment()`
  - `MessageRepository.getMessageCount()`
- One short explanation:
  - BlueBubbles centralizes all `chat.db` access behind a repository that knows chats, messages, handles, attachments, counts, and update scans.
- Runtime dependencies:
  - `typeorm`, `better-sqlite3`
- Data dependencies:
  - `~/Library/Messages/chat.db`
  - `~/Library/Messages/chat.db-wal`
- API/socket surface:
  - feeds HTTP, sockets, listeners, stats, attachments, send confirmation
- macOS permissions involved:
  - Full Disk Access
- Classification:
  - core
- MicaGoServer recommendation:
  - copy
- Suggested Mica version:
  - ongoing, already partly copied

## 7. Realtime Listener / Pollers / File Watchers

Purpose: detect new and updated records in `chat.db` and emit deduplicated events.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/imessage/listeners/IMessageListener.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/imessage/pollers/MessagePoller.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/imessage/pollers/ChatChangePoller.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/lib/MultiFileWatcher.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/index.ts`
- Key classes/functions:
  - `IMessageListener.start()`
  - `IMessageListener.handleChangeEvent()`
  - `MessagePoller.poll(after)`
  - `ChatUpdatePoller.poll(after)`
  - `IMessagePoller.getMessageEvent()`
  - `BlueBubblesServer.startChatListeners()`
- One short explanation:
  - BlueBubbles combines `fs.watch` on `chat.db` and `chat.db-wal` with debounced pollers and caches to turn low-level DB churn into stable message/chat events.
- Runtime dependencies:
  - `fs.watch`, `async-sema`, debounce decorator infrastructure
- Data dependencies:
  - iMessage DB, in-memory event/message/chat caches
- API/socket surface:
  - emits `new-message`, `updated-message`, `chat-read-status-changed`, participant and group events via `emitMessage()`
- macOS permissions involved:
  - Full Disk Access
- Classification:
  - core but heavy
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - keep periodic relay sync as primary; maybe revisit file watching later

## 8. Message Serialization

Purpose: convert database entities into BlueBubbles API payloads.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/serializers/MessageSerializer.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/serializers/AttachmentSerializer.ts`
- Key classes/functions:
  - `MessageSerializer.serialize()`
  - `MessageSerializer.serializeList()`
  - `MessageSerializer.convert()`
  - `AttachmentSerializer.serializeList()`
  - `AttachmentSerializer.convert()`
- One short explanation:
  - Serialization is where raw entity data becomes client-facing message JSON, including universal text, parsed payloads, attachments, and platform-specific extras.
- Runtime dependencies:
  - serializer helpers, attachment/media helpers
- Data dependencies:
  - message entities, attachment entities, parsed attributed bodies
- API/socket surface:
  - shared payload layer used by both HTTP and Socket.IO
- macOS permissions involved:
  - none directly
- Classification:
  - core
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - keep Mica JSON small and stable

## 9. Text Extraction / `attributedBody` / `universalText`

Purpose: recover displayable text when `message.text` is empty, especially for newer outgoing messages and rich content.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/imessage/entity/Message.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/utils/AttributedBodyUtils.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/imessage/helpers/utils.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/serializers/MessageSerializer.ts`
- Key classes/functions:
  - `Message.universalText(sanitize = false)`
  - `AttributedBodyUtils.extractText(attributedBody)`
  - `convertAttributedBody()`
  - `MessageSerializer.convert()`
- One short explanation:
  - BlueBubbles normalizes user-visible text through `universalText(true)`, which falls back from `message.text` to decoded `attributedBody`.
- Runtime dependencies:
  - `node-typedstream`
- Data dependencies:
  - `message.text`, `message.attributedBody`
- API/socket surface:
  - serializer `text` field
  - outgoing send matching
- macOS permissions involved:
  - Full Disk Access
- Classification:
  - core
- MicaGoServer recommendation:
  - copy
- Suggested Mica version:
  - already needed and already partly copied

## 10. Plain-Text Sending

Purpose: send text to an existing chat and confirm it when it lands in `chat.db`.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/interfaces/messageInterface.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/apple/actions.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/apple/scripts.ts`
- Key classes/functions:
  - `MessageInterface.sendMessageSync()`
  - `ActionHandler.sendMessage()`
  - `sendMessage(chatGuid, message, attachment)`
  - `sendMessageFallback(chatGuid, message, attachment)`
  - `restartMessages()`
- One short explanation:
  - BlueBubbles’ default text send path is AppleScript against existing Messages chat IDs, with retry-after-restart and a fallback script for direct chats.
- Runtime dependencies:
  - `osascript` execution through filesystem helpers
- Data dependencies:
  - chat GUIDs, pending manager, later chat.db confirmation
- API/socket surface:
  - HTTP and Socket.IO send routes
- macOS permissions involved:
  - Automation / Apple Events to Messages
- Classification:
  - core
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - v0.3-like minimal send path

## 11. Attachment Sending

Purpose: stage files, send attachments, optionally send follow-up text, and reconcile completion.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/interfaces/messageInterface.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/interfaces/attachmentInterface.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/queueService/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/privateApi/apis/PrivateApiAttachment.ts`
- Key classes/functions:
  - `MessageInterface.sendAttachmentSync()`
  - `AttachmentInterface.upload()`
  - `QueueService.process()`
  - `PrivateApiAttachment.send()`
- One short explanation:
  - Attachment send is significantly heavier than text send because it involves file staging, queueing, cleanup, and longer async confirmation windows.
- Runtime dependencies:
  - filesystem copy/conversion, AppleScript or private API
- Data dependencies:
  - local files, attachment caches, pending queue
- API/socket surface:
  - upload/download/send attachment routes and socket chunk upload
- macOS permissions involved:
  - filesystem access, Automation, possibly private API helper
- Classification:
  - heavy
- MicaGoServer recommendation:
  - defer
- Suggested Mica version:
  - after stable text send and read-only attachments

## 12. Attachment Download And Media Handling

Purpose: stream attachments, convert media, compute blurhash, handle live photos, and optionally force-download purged files.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/api/v1/routers/attachmentRouter.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/interfaces/attachmentInterface.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/serializers/AttachmentSerializer.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/fileSystem/index.ts`
- Key classes/functions:
  - `AttachmentRouter.download()`
  - `AttachmentRouter.forceDownload()`
  - `AttachmentRouter.downloadLive()`
  - `AttachmentRouter.blurhash()`
  - `AttachmentInterface.forceDownload()`
  - `AttachmentSerializer.convert()`
- One short explanation:
  - BlueBubbles goes far beyond raw file download by supporting conversion, caching, blurhash, live photo handling, and purged-attachment retrieval.
- Runtime dependencies:
  - `electron.nativeImage`, `mime-types`, blurhash utilities, filesystem helpers
- Data dependencies:
  - iMessage attachment rows, on-disk attachment files, cache directories
- API/socket surface:
  - attachment download, live-photo, blurhash, chunk APIs
- macOS permissions involved:
  - Full Disk Access
- Classification:
  - optional to heavy
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - read-only metadata and safe download first

## 13. Private API Helper Process

Purpose: use an injected helper process for features AppleScript cannot do reliably or at all.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/privateApi/PrivateApiService.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/privateApi/apis/PrivateApiMessage.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/privateApi/apis/PrivateApiAttachment.ts`
- Key classes/functions:
  - `PrivateApiService.start()`
  - `PrivateApiService.startPerMode()`
  - `PrivateApiService.configureServer()`
  - `PrivateApiService.onEvent()`
  - `PrivateApiMessage.send()`
  - `PrivateApiMessage.edit()`
  - `PrivateApiMessage.unsend()`
  - `PrivateApiAttachment.send()`
  - `PrivateApiAttachment.downloadPurged()`
- One short explanation:
  - BlueBubbles’ private API is a separate helper channel over local TCP with transaction promises and restart logic, enabling advanced features like edit, unsend, reaction, purged attachment download, and richer sends.
- Runtime dependencies:
  - custom helper bundle, TCP sockets, transaction manager, plugin/injection mode
- Data dependencies:
  - helper process state, transaction registry
- API/socket surface:
  - backs many higher-level APIs when `enable_private_api` is on
- macOS permissions involved:
  - additional helper/install requirements beyond standard FDA/Automation
- Classification:
  - heavy
- MicaGoServer recommendation:
  - skip
- Suggested Mica version:
  - none unless product direction changes dramatically

## 14. Outgoing Message Manager / Pending Send Confirmation

Purpose: track pending sends and reconcile them with later database-visible messages.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/imessage/pollers/MessagePoller.ts`
- Key classes/functions:
  - `OutgoingMessageManager.add()`
  - `OutgoingMessageManager.resolve()`
  - `OutgoingMessageManager.reject()`
  - `MessagePromise.isSame()`
  - `MessagePromise.emitMessageMatch()`
  - `MessagePromise.emitMessageError()`
  - `MessagePoller.poll()`
- One short explanation:
  - Pending send confirmation is a first-class subsystem; sends are not complete when AppleScript returns, only when a matching outgoing DB row is observed.
- Runtime dependencies:
  - in-memory promise registry, message poller
- Data dependencies:
  - chat GUID, normalized `message.universalText(true)`, subject, sent timestamp
- API/socket surface:
  - emits `message-send-error` and match-style callbacks through socket/server emitters
- macOS permissions involved:
  - indirect
- Classification:
  - core
- MicaGoServer recommendation:
  - copy
- Suggested Mica version:
  - immediate if Mica keeps local send

## 15. Contacts And Avatars

Purpose: enrich handles with local contacts, imported contacts, avatars, and VCF workflows.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/interfaces/contactInterface.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/Contact.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/ContactAddress.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/oauthService/index.ts`
- Key classes/functions:
  - `ContactInterface.getApiContacts()`
  - `ContactInterface.getDbContacts()`
  - `ContactInterface.getAllContacts()`
  - `ContactInterface.findContact()`
  - `ContactInterface.createContact()`
- One short explanation:
  - BlueBubbles merges macOS Contacts, local DB contacts, Google-imported contacts, and avatars into a unified enrichment layer.
- Runtime dependencies:
  - `node-mac-contacts`, `vcf`, `byte-base64`, Google APIs through OAuth service
- Data dependencies:
  - macOS contacts, config DB contact tables, imported avatar blobs
- API/socket surface:
  - HTTP, socket, and IPC contact CRUD/read endpoints
- macOS permissions involved:
  - Contacts permission
- Classification:
  - optional
- MicaGoServer recommendation:
  - defer
- Suggested Mica version:
  - only if user-facing contact enrichment becomes important

## 16. Notifications

Purpose: deliver server events to remote/mobile clients and optionally notify local users of updates.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/fcmService/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/webhookService/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/updateService/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/index.ts`
- Key classes/functions:
  - `FCMService.start()`
  - `FCMService.setRealtimeRules()`
  - `FCMService.setServerUrl()`
  - `WebhookService.dispatch()`
  - `UpdateService.checkForUpdate()`
  - `BlueBubblesServer.emitMessage()`
- One short explanation:
  - BlueBubbles fans events out to Socket.IO, Firebase, and webhooks, while also using local macOS notifications for update UX.
- Runtime dependencies:
  - `firebase-admin`, `googleapis`, `axios`, `electron.Notification`
- Data dependencies:
  - device registrations, Firebase configs, webhook rows
- API/socket surface:
  - event fanout and FCM registration endpoints
- macOS permissions involved:
  - local notifications if OS prompts; not central to message pipeline
- Classification:
  - FCM heavy, webhooks optional, local notifications optional
- MicaGoServer recommendation:
  - skip FCM, defer webhooks, skip local notifications
- Suggested Mica version:
  - webhooks maybe later; FCM none

## 17. Proxy / Remote Access / Cloud Setup

Purpose: expose the server beyond localhost via ngrok, Cloudflare, zrok, or similar mechanisms.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/proxyServices/proxy.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/proxyServices/ngrokService/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/proxyServices/cloudflareService/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/proxyServices/zrokService/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/oauthService/index.ts`
- Key classes/functions:
  - `Proxy.restart()`
  - `NgrokService.connect()`
  - `NgrokService.checkForError()`
  - `CloudflareService.connect()`
  - `ZrokService.connect()`
  - `OauthService.handleProjectCreation()`
- One short explanation:
  - BlueBubbles invests heavily in remote-access setup, token management, tunnel lifecycle, and cloud configuration because it targets remote mobile clients.
- Runtime dependencies:
  - `ngrok`, Cloudflare manager, zrok manager, `googleapis`
- Data dependencies:
  - config DB tunnel settings, OAuth tokens, URL state
- API/socket surface:
  - server settings, proxy switch routes, Electron UI setup
- macOS permissions involved:
  - none special beyond app networking
- Classification:
  - heavy
- MicaGoServer recommendation:
  - skip
- Suggested Mica version:
  - none for current local-first direction

## 18. Authentication / Password / Device Setup

Purpose: protect HTTP/socket access and register remote devices.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/api/v1/middleware/authMiddleware.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/databases/server/entity/Device.ts`
- Key classes/functions:
  - `AuthMiddleware`
  - `HttpService.start()` socket handshake auth
- One short explanation:
  - BlueBubbles uses a shared password-style token for both HTTP and Socket.IO, plus device registration for FCM.
- Runtime dependencies:
  - Koa middleware, Socket.IO handshake
- Data dependencies:
  - config DB `password`, device rows
- API/socket surface:
  - protected API routes; FCM device registration
- macOS permissions involved:
  - none
- Classification:
  - core for remote product, unnecessary for current local Mica scope
- MicaGoServer recommendation:
  - skip
- Suggested Mica version:
  - reconsider only if remote multi-client use becomes real

## 19. macOS Permissions / Automation / Full Disk Access

Purpose: ensure the app can read `chat.db`, automate Messages, and access contacts.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/ipcService/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/apple/scripts.ts`
- Key classes/functions:
  - `BlueBubblesServer.hasDiskAccess`
  - `BlueBubblesServer.hasAccessibilityAccess`
  - `BlueBubblesServer.initDatabase()`
  - `IPCService.startIpcListeners()`
  - `prompt_accessibility`
  - `prompt_disk_access`
- One short explanation:
  - Permissions are treated as first-class runtime dependencies, with prompts, checks, and setup UI because the product would otherwise silently fail.
- Runtime dependencies:
  - `node-mac-permissions`, Electron `systemPreferences`
- Data dependencies:
  - none
- API/socket surface:
  - mostly Electron IPC and startup dialogs, not public API
- macOS permissions involved:
  - Full Disk Access, Accessibility, Contacts, Automation
- Classification:
  - core operational concern
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - keep CLI/log-based checks, avoid heavy GUI flows

## 20. Error Handling / Recovery / Retry Behavior

Purpose: keep the app usable despite flaky macOS automation, helper crashes, network failures, or tunnel instability.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/proxyServices/proxy.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/privateApi/PrivateApiService.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/apple/actions.ts`
- Key classes/functions:
  - `ActionHandler.sendMessage()` retry and fallback path
  - `MessagePromise` timeouts
  - `PrivateApiService` restart counters
  - `Proxy.restartHandler()`
- One short explanation:
  - BlueBubbles favors robustness over simplicity, with many retries, restarts, and fallback code paths.
- Runtime dependencies:
  - timers, scheduled services, socket/process restarts
- Data dependencies:
  - config-driven restart behavior, pending queues
- API/socket surface:
  - failures become socket events, logs, UI alerts, and sometimes dialogs
- macOS permissions involved:
  - indirect
- Classification:
  - core but heavy
- MicaGoServer recommendation:
  - simplify
- Suggested Mica version:
  - add only narrow retries and stable error codes

## 21. Setup / Admin UI

Purpose: provide an Electron management interface for settings, permissions, logs, contacts, updates, tunnels, and diagnostics.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/services/ipcService/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/api/v1/routers/uiRouter.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/api/v1/routers/settingsRouter.ts`
- Key classes/functions:
  - `IPCService.startIpcListeners()`
  - `UiRouter.index()`
- One short explanation:
  - A large amount of BlueBubbles complexity exists only because it ships as an end-user Electron desktop product with a settings UI.
- Runtime dependencies:
  - `electron`, `ipcMain`
- Data dependencies:
  - almost every service and DB
- API/socket surface:
  - Electron IPC, landing page, settings backup endpoints
- macOS permissions involved:
  - many setup-related flows
- Classification:
  - optional for BlueBubbles, unnecessary for current Mica
- MicaGoServer recommendation:
  - skip
- Suggested Mica version:
  - none

## 22. Client Compatibility Layer

Purpose: keep BlueBubbles mobile/desktop clients working against a stable transport and payload contract.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/api/v1/socketRoutes.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/serializers/MessageSerializer.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/serializers/AttachmentSerializer.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/events.ts`
- Key classes/functions:
  - `SocketRoutes.createRoutes()`
  - `MessageSerializer.serialize()`
  - `AttachmentSerializer.serializeList()`
- One short explanation:
  - BlueBubbles’ route names, event names, payload fields, and serializer behavior form a compatibility layer for its own clients.
- Runtime dependencies:
  - Socket.IO, Koa serializers
- Data dependencies:
  - all domain entities
- API/socket surface:
  - broad, client-shaped contracts
- macOS permissions involved:
  - none directly
- Classification:
  - core for BlueBubbles, unnecessary for Mica
- MicaGoServer recommendation:
  - skip
- Suggested Mica version:
  - none

## 23. Unsupported Or Deprecated Features

Purpose: identify parts already marked as legacy or tied to OS/version caveats.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/http/api/v1/socketRoutes.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/index.ts`
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/src/server/api/apple/scripts.ts`
- Key classes/functions:
  - `SocketRoutes.createRoutes()` contains `TODO: DEPRECATE!` above `get-chat-messages`
  - `BlueBubblesServer.postChecks()` warns about Monterey/Big Sur group chat limitations
  - `buildServiceScript()` in `scripts.ts` carries old macOS branching
- One short explanation:
  - BlueBubbles carries compatibility baggage for older macOS behavior and some legacy routes.
- Runtime dependencies:
  - version checks via `macos-version`
- Data dependencies:
  - none
- API/socket surface:
  - deprecated route name and version-specific behavior
- macOS permissions involved:
  - none specific
- Classification:
  - mixed legacy baggage
- MicaGoServer recommendation:
  - skip
- Suggested Mica version:
  - none

## 24. Heavy Dependencies And Why They Exist

Purpose: explain which dependencies drive most of the architectural weight.

- Key file paths:
  - `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server/packages/server/package.json`
- Key classes/functions:
  - not applicable; dependency-level audit
- One short explanation:
  - BlueBubbles is heavy because it is an Electron desktop product, a remote-access server, a push-notification backend, a contact/media processor, and a macOS automation app all at once.
- Runtime dependencies:
  - `electron`: desktop shell and admin UI
  - `koa`, `socket.io`: HTTP + realtime API
  - `typeorm`, `better-sqlite3`: multiple SQLite-backed stores
  - `firebase-admin`, `googleapis`: push + cloud bootstrap
  - `node-mac-permissions`, `node-mac-contacts`: macOS integration
  - `node-typedstream`: decode `attributedBody`
  - `ngrok`: remote tunnels
  - `axios`: updates, webhooks, cloud calls
- Data dependencies:
  - config DB, `chat.db`, attachment files, cloud project config
- API/socket surface:
  - broad and multi-client
- macOS permissions involved:
  - Full Disk Access, Accessibility, Contacts, Automation
- Classification:
  - heavy
- MicaGoServer recommendation:
  - selectively copy small ideas, not dependency set
- Suggested Mica version:
  - n/a

## Recommended MicaGoServer Roadmap After v0.6

### Must Have

- Stable relay-first read path with incremental sync and explicit reconciliation state.
- Small WebSocket event model driven by relay inserts and send confirmation, not Socket.IO RPC.
- Robust plain-text send confirmation using extracted display text and pending temp GUID tracking.
- Safe read-only attachment metadata plus bounded download path checks.
- Clear startup diagnostics for Full Disk Access and Automation failures.

### Should Have

- Better send retry ergonomics around transient AppleScript timeouts, but without BlueBubbles’ full fallback complexity unless needed.
- Webhook fanout for local automation use cases.
- Better chat/message update events beyond `message:new`, such as limited `message:update` when delivery/read status materially changes.
- Minimal config persistence for sync interval, API store, and operational flags.

### Nice To Have

- Contact enrichment from local macOS Contacts, read-only first.
- Local stats/diagnostics endpoints for sync lag, relay counts, and last processed row IDs.
- Smarter attachment preview metadata or image dimensions.

### Avoid

- Socket.IO compatibility layer and BlueBubbles-style RPC event surface.
- Full Electron admin UI and IPC control plane.
- Tunnel/proxy/cloud bootstrap inside the core server.
- Feature growth that forces Mica to mirror BlueBubbles payload shapes.

### Never

- Private API helper injection architecture unless Mica’s product goals fundamentally change.
- Firebase/mobile push stack inside the core local server.
- BlueBubbles client compatibility as a product requirement.
- Large legacy OS compatibility branches unless a real Mica user need appears.
