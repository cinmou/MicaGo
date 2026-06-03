# Architecture Map

Scope: only the modules most relevant to a lightweight Go iMessage relay rewrite.

## 1. Main entry point

| File path | Function/class | One-sentence purpose | Relevant to lightweight Go rewrite |
| --- | --- | --- | --- |
| `packages/server/src/main.ts` | `Server(parsedArgs, null)`, `app.whenReady().then(() => { Server().start(); })` | Electron bootstrap that loads YAML/CLI config, creates the singleton server, and starts it when the app is ready. | Partial |
| `packages/server/src/server/index.ts` | `Server`, `BlueBubblesServer`, `BlueBubblesServer.start`, `initServer`, `initDatabase`, `initServices`, `startServices` | Central application coordinator that wires repositories, HTTP/socket service, private API helpers, OAuth, proxy services, and lifecycle events. | Yes |

## 2. HTTP/API route registration

| File path | Function/class | One-sentence purpose | Relevant to lightweight Go rewrite |
| --- | --- | --- | --- |
| `packages/server/src/server/api/http/index.ts` | `HttpService.initialize`, `HttpService.configureKoa`, `HttpService.start` | Builds the Koa server, attaches middleware, registers HTTP routes, creates Socket.IO on the same server, and starts listening on the configured port. | Yes |
| `packages/server/src/server/api/http/api/v1/httpRoutes.ts` | `HttpRoutes.createRoutes` | Registers the versioned HTTP API surface and applies shared middleware such as auth, logging, metrics, and private API gating. | Yes |

## 3. Socket/WebSocket registration

| File path | Function/class | One-sentence purpose | Relevant to lightweight Go rewrite |
| --- | --- | --- | --- |
| `packages/server/src/server/api/http/index.ts` | `HttpService.start` | Registers the top-level Socket.IO `connection` handler, performs handshake password checks, installs per-socket error middleware, and delegates event binding. | Yes |
| `packages/server/src/server/api/http/api/v1/socketRoutes.ts` | `SocketRoutes.createRoutes` | Registers socket event handlers for metadata, config, logs, chats, messages, attachments, and other client-driven operations. | Maybe |

## 4. Database access modules

| File path | Function/class | One-sentence purpose | Relevant to lightweight Go rewrite |
| --- | --- | --- | --- |
| `packages/server/src/server/databases/server/index.ts` | `ServerRepository`, `initialize`, `getConfig`, `setConfig` | TypeORM repository for the app’s own SQLite config/state database, including config cache, devices, queue, webhooks, contacts, and scheduled messages. | Yes |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository`, `initialize`, `getChats`, `getMessage`, `getMessages`, `getAttachment` | TypeORM repository over Apple’s `chat.db` that provides the read/query layer for chats, messages, handles, and attachments. | Yes |
| `packages/server/src/server/databases/findmy/index.ts` | `FindMyRepository`, `initialize`, `getLatestCacheReference` | Optional SQLite repository for Find My cache data. | No |

## 5. Message sending modules

| File path | Function/class | One-sentence purpose | Relevant to lightweight Go rewrite |
| --- | --- | --- | --- |
| `packages/server/src/server/api/http/api/v1/routers/messageRouter.ts` | `MessageRouter.sendText`, `MessageRouter.sendAttachment`, `MessageRouter.sendMultipartMessage` | HTTP handlers that accept outbound send requests, add temp GUIDs to send cache, call the message interface, and serialize the sent result. | Yes |
| `packages/server/src/server/api/interfaces/messageInterface.ts` | `MessageInterface.sendMessageSync`, `sendAttachmentSync`, `sendMessagePrivateApi`, `sendAttachmentPrivateApi` | Main outbound messaging orchestration layer that chooses AppleScript vs private API delivery, waits for DB confirmation, and normalizes send behavior. | Yes |
| `packages/server/src/server/api/apple/actions.ts` | `ActionHandler.sendMessage` | macOS-specific AppleScript send backend with retry and fallback behavior for text and attachment sends. | Partial |
| `packages/server/src/server/api/privateApi/apis/PrivateApiMessage.ts` | `PrivateApiMessage.send`, `sendMultipart`, `react`, `edit`, `unsend` | Private API transport wrapper that sends structured message commands to the helper process. | Partial |
| `packages/server/src/server/managers/outgoingMessageManager/index.ts` | `OutgoingMessageManager` | Tracks in-flight send promises and resolves or rejects them when matching outbound messages appear in the database. | Yes |
| `packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise` | Defines the matching, timeout, and completion logic used to correlate a send request with the eventual database-written message. | Yes |

## 6. Attachment modules

| File path | Function/class | One-sentence purpose | Relevant to lightweight Go rewrite |
| --- | --- | --- | --- |
| `packages/server/src/server/api/http/api/v1/routers/attachmentRouter.ts` | `AttachmentRouter.download`, `uploadAttachment`, `forceDownload`, `blurhash` | HTTP handlers for attachment lookup, upload staging, download/transform streaming, and forced private API retrieval. | Yes |
| `packages/server/src/server/api/interfaces/attachmentInterface.ts` | `AttachmentInterface.upload`, `forceDownload`, `getLivePhotoPath`, `getBlurhash` | Attachment service layer for staging uploaded files, computing image metadata, and waiting for purged attachments to be restored. | Yes |
| `packages/server/src/server/api/privateApi/apis/PrivateApiAttachment.ts` | `PrivateApiAttachment.send`, `downloadPurged` | Private API transport wrapper for sending attachments and requesting download of purged attachments. | Partial |

## 7. Config/auth modules

| File path | Function/class | One-sentence purpose | Relevant to lightweight Go rewrite |
| --- | --- | --- | --- |
| `packages/server/src/server/databases/server/index.ts` | `ServerRepository.getConfig`, `setConfig`, `loadConfig`, `setupDefaults` | Persistent configuration store and cache for server settings such as socket port, password, private API flags, and proxy options. | Yes |
| `packages/server/src/server/api/http/api/v1/middleware/authMiddleware.ts` | `AuthMiddleware` | Simple HTTP query-parameter password check against the stored server password. | Yes |
| `packages/server/src/server/api/http/index.ts` | `HttpService.start` | Performs equivalent socket handshake authentication by comparing the provided password or guid query value with the configured password. | Yes |
| `packages/server/src/server/services/oauthService/index.ts` | `OauthService`, `initialize`, `configureKoa` | Local OAuth callback server and Google setup/contact-sync workflow used for Firebase and Google Contacts setup. | No |
