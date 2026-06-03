# MicaGoServer Feature Decision Matrix

Source: `/Users/Cinmou/Documents/GitHub/MicaGoServer/bluebubbles server` audit. Each row references exact BlueBubbles files and the intended MicaGoServer decision.

| Area | BlueBubbles source | Purpose | Weight | Mica decision | Suggested version | Notes |
|---|---|---|---|---|---|---|
| Startup and lifecycle | `packages/server/src/server/index.ts` `BlueBubblesServer.start()` | Boot app, DBs, services, listeners | Core | Simplify | ongoing | Keep CLI/server lifecycle, skip Electron-centric restart UX |
| Config system | `packages/server/src/server/databases/server/index.ts` `ServerRepository.getConfig()` | Persist settings and trigger service changes | Core | Simplify | v0.x-v1.0 | Small config store is enough |
| Server config DB | `packages/server/src/server/databases/server/entity/*` | Store devices, alerts, queue, contacts, webhooks, scheduled messages | Heavy | Simplify | later selective | Do not copy whole DB model |
| HTTP API breadth | `packages/server/src/server/api/http/api/v1/httpRoutes.ts` `HttpRoutes.api` | Full product API | Heavy | Simplify | ongoing | Keep narrow Mica API |
| Socket.IO RPC layer | `packages/server/src/server/api/http/api/v1/socketRoutes.ts` `SocketRoutes.createRoutes()` | Command transport plus events | Heavy | Skip | none | Mica should use plain WebSocket events only |
| iMessage repository | `packages/server/src/server/databases/imessage/index.ts` `MessageRepository.getMessages()` | Read `chat.db` safely and consistently | Core | Copy | ongoing | Already aligned with Mica architecture |
| Realtime file watcher stack | `packages/server/src/server/databases/imessage/listeners/IMessageListener.ts` `IMessageListener.start()` | Detect chat DB changes via watchers + pollers | Heavy | Simplify | post-v0.6 if needed | Prefer relay sync loop first |
| Message serialization | `packages/server/src/server/api/serializers/MessageSerializer.ts` | Build client payloads | Core | Simplify | ongoing | Keep Mica JSON smaller |
| `universalText` / attributedBody | `packages/server/src/server/databases/imessage/entity/Message.ts` `universalText()` | Recover user-visible text | Core | Copy | already needed | This is required for correct send/read behavior |
| Plain-text send | `packages/server/src/server/api/interfaces/messageInterface.ts` `sendMessageSync()` | Send via AppleScript and confirm in DB | Core | Simplify | v0.3+ | Existing-chat send only is enough |
| Attachment send | `packages/server/src/server/services/queueService/index.ts` `QueueService.process()` | File staging and queued send | Heavy | Defer | later | Not needed for current scope |
| Attachment download/media | `packages/server/src/server/api/http/api/v1/routers/attachmentRouter.ts` | Download, convert, blurhash, live photo | Optional-heavy | Simplify | v0.5+ | Read-only metadata + safe streaming only |
| Private API helper | `packages/server/src/server/api/privateApi/PrivateApiService.ts` | Advanced features beyond AppleScript | Heavy | Skip | none | Too much operational complexity |
| Pending send confirmation | `packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | Match outgoing DB rows to pending sends | Core | Copy | v0.3+ | Essential for reliable local send |
| Contacts and avatars | `packages/server/src/server/api/interfaces/contactInterface.ts` | Enrich identities and avatars | Optional | Defer | later | Only if users need names/avatars locally |
| Firebase notifications | `packages/server/src/server/services/fcmService/index.ts` | Push to remote clients | Heavy | Skip | none | Explicitly outside Mica scope |
| Webhooks | `packages/server/src/server/services/webhookService/index.ts` | Outbound automation hooks | Optional | Defer | later | Useful, but not core |
| Local notifications | `packages/server/src/server/services/updateService/index.ts` `checkForUpdate()` | Update UX on macOS | Optional | Skip | none | Not part of server core |
| Proxy / remote access | `packages/server/src/server/services/proxyServices/*` | Public exposure and tunnel lifecycle | Heavy | Skip | none | Conflicts with local-first design |
| OAuth / cloud setup | `packages/server/src/server/services/oauthService/index.ts` | Google/Firebase/bootstrap/contact sync | Heavy | Skip | none | No product need today |
| Auth/password/device setup | `packages/server/src/server/api/http/api/v1/middleware/authMiddleware.ts` | Protect remote API and register devices | Optional-heavy | Skip | none for local mode | Revisit only if remote mode appears |
| Permissions UX | `packages/server/src/server/services/ipcService/index.ts` | Prompt/inspect FDA, accessibility, contacts | Core operational | Simplify | ongoing | Keep logs and docs, not Electron setup UI |
| Error/retry framework | `packages/server/src/server/api/apple/actions.ts` `ActionHandler.sendMessage()` | Recover from flaky automation and services | Core-heavy | Simplify | ongoing | Stable errors + minimal retries |
| Setup/admin UI | `packages/server/src/server/services/ipcService/index.ts` | Full Electron control plane | Unnecessary | Skip | none | Mica should stay inspectable and headless |
| Client compatibility layer | `packages/server/src/server/events.ts`, `socketRoutes.ts`, serializers | Preserve BlueBubbles client contracts | Unnecessary | Skip | none | Do not become a compatibility clone |
| Legacy/deprecated support | `packages/server/src/server/api/http/api/v1/socketRoutes.ts` `get-chat-messages` | Backward compatibility | Unnecessary | Skip | none | Avoid inheriting legacy debt |

## Recommended MicaGoServer Roadmap After v0.6

### Must Have

- Relay-first correctness: reliable incremental sync, extracted text, attachment metadata linkage, and durable sync cursors.
- Stable local send pipeline: AppleScript send, pending manager, confirmation polling against relay/chat DB, and predictable timeout/error codes.
- Lightweight realtime: plain WebSocket with a tiny event envelope and no RPC sprawl.
- Operational clarity: good logs for permissions, sync failures, and send failures.

### Should Have

- Limited message update events for delivery/read changes if they can be sourced cleanly from sync.
- Optional local webhooks for automation.
- Better diagnostics around relay lag and sync health.

### Nice To Have

- Read-only contacts enrichment.
- Better attachment previews and metadata polish.
- Optional manual/admin helpers for permissions and environment checks.

### Avoid

- Socket.IO transport compatibility.
- Remote proxy/tunnel management in the core server.
- Broad product-style admin routes and UI.
- Feature pressure to mirror BlueBubbles field-for-field.

### Never

- Firebase/mobile push stack in the local-first server.
- Private API helper injection unless Mica changes product direction.
- BlueBubbles client compatibility as a success criterion.
