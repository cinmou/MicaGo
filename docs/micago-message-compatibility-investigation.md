# MicaGo Message Compatibility Investigation

Date: 2026-06-08

Scope: read-only investigation of current MicaGoServer and MicaGoFlutterClient message compatibility. Per latest instruction, reference code under `Ref/` was not inspected for this report; BlueBubbles-specific comparison is therefore marked as deferred.

## Executive Summary

MicaGo currently supports the core iMessage relay path: it reads macOS `chat.db`, syncs iMessage chats/messages/attachments into `relay.db`, exposes a normal JSON API, streams attachment bytes, emits WebSocket events, and the Flutter client parses/render text, attachments, reactions, replies, effects, retractions, local send states, contact names, and local avatar thumbnails.

The main compatibility risks are not basic transport. They are row classification, unsupported/empty iMessage database rows, TIFF/image decoding, send-state reconciliation after a timeout or fast-fail, background receive reliability on Android, and stale comments/docs in the Flutter model that understate current server fields.

## Part A - Current Architecture Map

| Area | Current files | Notes |
| --- | --- | --- |
| Open/read macOS Messages DB | `MicaGoServer/micago-server/internal/app/app.go`, `MicaGoServer/micago-server/internal/store/db.go` | App opens configured `chat.db` read-only, probes schema capabilities, and creates `store.Queries`. |
| Query `chat.db` messages/chats | `MicaGoServer/micago-server/internal/store/queries.go` | Reads `message`, `chat`, `chat_message_join`, `handle`, `attachment`, `message_attachment_join`. Extracts `attributedBody`, dates, handle, delivery, semantic fields, and attachment metadata. |
| Text extraction | `MicaGoServer/micago-server/internal/store/text.go` | Resolves `message.text` plus `attributedBody`; filters renderable content. |
| Row classification/debug | `MicaGoServer/micago-server/internal/store/debug.go`, `MicaGoServer/micago-server/internal/store/classify.go` | Debug-only inspector query keeps empty/semantic rows and annotates text/image/audio/file/reaction/reply/service/unsupported candidates. |
| Sync into relay DB | `MicaGoServer/micago-server/internal/relaydb/sync.go`, `MicaGoServer/micago-server/internal/relaydb/migrations.go` | Syncs iMessage chats/messages/attachments into `relay.db`; stores semantic columns such as `associated_message_type`, `thread_originator_guid`, `balloon_bundle_id`, and `payload_data_present`. |
| Mutable update pass | `MicaGoServer/micago-server/internal/relaydb/updatepass.go` | Bounded lookback detects read/delivered/edited/retracted/error changes for already synced messages and emits update/unsend events. |
| Normal API JSON | `MicaGoServer/micago-server/internal/store/models.go`, `MicaGoServer/micago-server/internal/relaydb/query.go`, `MicaGoServer/micago-server/internal/httpapi/handlers.go` | `MessageJSON` includes core fields, attachments, `chatGuid`, tapback/reply/effect/service metadata, `error`, `dateEdited`, `dateRetracted`, `isEdited`, `isRetracted`. |
| API routes | `MicaGoServer/micago-server/internal/httpapi/router.go` | Key routes: `GET /api/chats`, `GET /api/chats/{guid}/messages`, `POST /api/chats/{guid}/send`, `GET /api/attachments/{guid}`, `GET /api/debug/recent-messages`, `/ws`. |
| WebSocket events | `MicaGoServer/micago-server/internal/app/app.go`, `MicaGoServer/micago-server/internal/httpapi/handlers.go`, `MicaGoServer/micago-server/internal/realtime/hub.go` | Emits `message:new`, `message:update`, `message:unsend`, `send:pending`, `send:match`, `send:error`, plus `sync:error`. |
| Send path | `MicaGoServer/micago-server/internal/httpapi/handlers.go`, `MicaGoServer/micago-server/internal/send/*` | POST validates iMessage chat, creates pending send, AppleScript sends text, syncs, polls for matching outgoing row, emits pending/match/error. |
| Attachment streaming | `MicaGoServer/micago-server/internal/httpapi/handlers.go`, `MicaGoServer/micago-server/internal/store/attachmentkind.go` | Streams local attachment bytes under attachment root, sets inferred content type, exposes metadata in message JSON. |
| Android/Flutter REST parsing | `MicaGoFlutterClient/lib/core/network/api_client.dart`, `MicaGoFlutterClient/lib/features/chats/models/message_model.dart` | Parses chat/message JSON, attachments, semantic fields, local send state. |
| Flutter classify/render | `MicaGoFlutterClient/lib/features/chats/message_render.dart`, `MicaGoFlutterClient/lib/features/chats/message_display.dart`, `MicaGoFlutterClient/lib/features/chats/message_thread_screen.dart` | Classifies normal/attachment/service/reaction/retracted/unknown, merges tapbacks, reply previews, delivery labels, effect hints, debug info. |
| Attachments UI | `MicaGoFlutterClient/lib/features/chats/attachment_views.dart`, `MicaGoFlutterClient/lib/features/chats/media_viewer.dart` | Image bytes via `Image.memory`, audio via `just_audio`, fallback file row. |
| Contacts/avatars | `MicaGoFlutterClient/lib/features/contacts/*`, `MicaGoFlutterClient/lib/features/chats/avatar.dart`, `MicaGoServer/micago-mac-companion/MicaGoCompanion/Services/ContactsService.swift` | Flutter does local opt-in contacts matching and lazy local thumbnails. Companion has local contacts support for display/rule UX. Server API does not store contact names. |
| Message Inspector/debug endpoint | `MicaGoServer/micago-server/internal/httpapi/debug.go`, `MicaGoFlutterClient/lib/features/chats/message_debug_sheet.dart`, `MicaGoFlutterClient/lib/features/chats/message_render.dart` | Server exposes `/api/debug/recent-messages`; Flutter has per-message redacted debug JSON from normal API messages. |

## Part B - BlueBubbles Reference Scan

Deferred. The original request asked to inspect BlueBubbles reference code, but the latest instruction explicitly says the app has a `Ref` folder with reference code and that it should not be read. This report therefore does not claim BlueBubbles file-level evidence.

Current MicaGo mapping against known field concepts:

| Concept | MicaGo current field | Normal API? | Debug API? | Flutter uses it? | Gap / next action |
| --- | --- | --- | --- | --- | --- |
| Tapbacks/reactions | `associatedMessageType`, `associatedMessageGuid` | Yes via relay when schema has columns | Yes | Yes, can merge chips | Need real samples to verify codes/prefixes. |
| Replies | `threadOriginatorGuid` | Yes | Yes | Yes, reply preview if target loaded | Need samples for thread part/originator edge cases. |
| Unsent/retracted | `dateRetracted`, `isRetracted` | Yes via update pass/message_state | Yes | Yes | Verify update pass sees real retractions promptly. |
| Edited | `dateEdited`, `isEdited` | Yes via update pass/message_state | Yes | Parsed; rendering polish unclear | Add explicit edited badge if not already visible enough. |
| Delivered/read | `dateDelivered`, `dateRead`, `isDelivered`, `isRead` | Yes | Yes | Yes | Reconciliation after local failure needs testing. |
| Send failed/error | `error` | Yes through message_state and send fast-fail | Yes | Yes as failed delivery | Later success/update must clear local failed state. |
| Effects | `expressiveSendStyleId` | Yes | Yes | Yes, label map | Need real effects samples. |
| Stickers/apps | `associatedMessageType=1000`, `balloonBundleId`, `payloadDataPresent`, attachment `isSticker` | Partly | Yes | Partly | No rich iMessage app payload rendering. |
| Attachments/media | `attachments[]` with MIME/UTI/kind/voice/download URL | Yes | Yes redacted | Yes | TIFF/HEIC support depends on Flutter decoder/device. |
| Contact avatars | Local contact thumbnail | Client-only | N/A | Yes | Server does not provide avatars; privacy-friendly. |

## Part C - Noisy / Empty iMessage Database Rows

| Category | chat.db indicators | MicaGo detects now? | Normal timeline? | Inspector? | Merge/action |
| --- | --- | --- | --- | --- | --- |
| Text only | `text` or extractable `attributedBody`; no control artifact | Yes | Yes | Yes | Keep. |
| Real text in `attributedBody` | `text` null, `attributedBody` present | Yes via `ExtractMessageText` | Yes if extracted/renderable | Yes, `hasAttributedBody` | Keep; collect samples when extraction fails. |
| Emoji-only text | Non-ASCII emoji in text/attributed body | Client/server control filter intentionally preserves non-ASCII | Yes | Yes | Keep; test because emoji-only must not be treated as punctuation noise. |
| Tapback/reaction row | `associated_message_type` 2000-2005 or 3000-3005 + `associated_message_guid` | Yes when column exists | Yes, but Flutter may merge/hide standalone | Yes | Prefer merge into target when target loaded; inspect standalone fallback. |
| Sticker tapback/app row | `associated_message_type=1000`, `is_sticker`, `balloon_bundle_id`, `payload_data` | Partly | Partly as sticker/file/service depending attachment | Yes | Needs real samples and display policy. |
| Reply metadata | `thread_originator_guid` present | Yes | Yes | Yes | Should render as message with reply preview, not hidden. |
| Group/service event | `item_type`, `group_action_type`, `group_title` | Yes | Yes as service row | Yes | Keep subtle system row; avoid chat grouping by display name. |
| Edited row/state | `date_edited` | Yes through update pass for tracked messages | Yes fields, rendering partial | Yes | Add/verify edited label. |
| Retracted/unsent | `date_retracted` | Yes through update pass | Yes as retracted system row | Yes | Keep, do not show old content once retracted. |
| Effect row/message | `expressive_send_style_id` | Yes | Yes | Yes effect hint | Collect samples to validate labels. |
| Attachment-only | `cache_has_attachments=1`, joined attachment rows | Yes | Yes | Yes | Keep. |
| Missing attachment rows | `cache_has_attachments=1`, no `message_attachment_join`/attachment rows | Debug classifies `missing_attachment_rows`; normal may appear unsupported | Yes if synced because cache flag is renderable | Yes | Should usually be inspector-only or subtle system row until explained. |
| iCloud/sync artifact | no text, no attachments, no semantic fields, odd handle/date | Debug `unsupported_candidate`; normal sync filters most no-content rows | Usually no | Yes | Keep out of normal timeline unless user enables debug. |
| Deleted/old/unknown handles | handle join null or stale `handle.id` | Partly | Yes if content row | Yes | Display fallback `Unknown`; identity should remain handle/chat GUID based. |

## Part D - Deleted/Unknown Users and Sender Grouping

Current mapping:

| Source | Use |
| --- | --- |
| `message.handle_id` | Foreign key-like integer into `handle.ROWID`; absent/null for some system/self/sync rows. |
| `handle.ROWID` | Stable row identity inside `chat.db`, not exposed by normal API. |
| `handle.id` | Exposed as `MessageJSON.handle.id` / Flutter `handleId`; used for sender display and contacts matching. |
| `chat.guid` | Primary thread identity and API route key. |
| `chat.chat_identifier` | 1:1 visible address/identifier; group chats can be opaque. |
| `chat_message_join` | Authoritative message-to-thread relation. |
| contact display name | Presentation-only in Flutter/companion contacts matching. |

Reasons messages may appear under surprising names:

- One person can have multiple handles: phone, email, Apple ID, normalized variants.
- Apple ID identity can change over time while old messages keep old handles.
- Group chats rely on `chat_message_join` for thread and `handle_id` for sender; display name alone is not identity.
- Deleted contacts only remove local presentation data; old `handle.id` rows remain in `chat.db`.
- iCloud sync can restore old handles or sparse rows.
- Some messages have null handle; Flutter falls back to `Unknown`.
- Grouping by display/contact name can merge unrelated handles if two contacts share a name or one contact has several addresses.

Recommended strategy:

1. Use `chat.guid` as the thread key everywhere.
2. Use `handle.ROWID` plus `handle.id` as sender identity when deeper debug/identity work is needed.
3. Keep contact display name and avatar as presentation only.
4. In debug/grouping UI, show both display label and raw handle/chat key.
5. Do not derive primary identity from `displayName`, contact name, or avatar initials.

## Part E - TIFF / Unsupported Image Attachments

Current handling:

| Item | Current state |
| --- | --- |
| Attachment read | Server selects `filename`, `mime_type`, `transfer_name`, `total_bytes`, `filename AS local_path`, `is_outgoing`, `hide_attachment`, `created_date`, `uti`, `is_sticker`. |
| Metadata exposed | Normal API exposes filename, MIME, UTI, transfer name, total bytes, sticker flag, kind, voice flag, download URL. Debug API exposes same minus local path/full URL. |
| MIME/UTI inference | `store/attachmentkind.go` maps `public.tiff`, `.tif`, `.tiff` to `image/tiff` and classifies as `image`. |
| Flutter classification | `AttachmentModel.isImage` returns true for `attachmentKind == image` or `mimeType startsWith image/`. |
| Flutter rendering | Fetches bytes and calls `Image.memory`; on error falls back to file attachment. |
| TIFF risk | Server labels TIFF as image, so Flutter attempts decode. Flutter engine/platform may not decode TIFF consistently on Android. |

Recommended fix options, not implemented here:

1. Preferred: server-side preview/thumbnail endpoint that converts TIFF/HEIC/problem formats to PNG/JPEG for display while preserving original download.
2. Short-term: client-side TIFF placeholder/file row when `mimeType == image/tiff`, `uti == public.tiff`, or extension `.tif/.tiff`.
3. Medium-term: expose `previewUrl`/`thumbnailUrl` per attachment and let Flutter use preview for display, original for download/open.

## Part F - Send State Mismatch

Trace:

1. Flutter `ThreadController.send()` adds a local optimistic message with `LocalSendState.pending`.
2. `ApiClient.sendText()` POSTs `/api/chats/{guid}/send` with `tempGuid`.
3. Server `SendText` validates iMessage chat and creates a pending send.
4. Server emits `send:pending`.
5. Server runs AppleScript via `send.AppleScriptSender`.
6. Server runs `SyncNow`, then polls `FindOutgoingMessageMatch` for up to 15 seconds.
7. If matched, server emits `send:match` with confirmed message and HTTP 200.
8. If AppleScript fails, Messages.app is not running, `message.error` appears, request is cancelled, or no match appears before timeout, server emits `send:error` and returns non-200.
9. Flutter marks the local optimistic message failed on HTTP error or `send:error`.
10. Later `message:new` / `message:update` reloads the thread, but failed local messages are only removed if their real GUID is known; a timeout failure has no GUID.

Likely mismatch causes:

- The 15 second confirmation window is too short for slow `chat.db` insert/sync.
- `SyncNow` runs before the outgoing row appears; later periodic sync adds the real row after Flutter already marked the temp row failed.
- A later `send:match` cannot arrive after the handler returns timeout because the pending entry is removed by defer.
- A real delivered row may appear as a separate server message while the failed local temp row remains.
- `dateDelivered`/`dateRead` updates arrive through `message:update`, but local failed state is not reconciled by text/time matching.
- `send:error` does not carry enough eventual-match info; timeout details include text/chat/tempGuid but no future row ID.

Evidence needed:

- Server send logs for `tempGuid`: request, AppleScript ok/fail, sync, poll, timeout/match.
- `/api/debug/recent-messages` rows around send time with `chatGuid`, `guid`, text, `isFromMe`, `error`, `dateDelivered`.
- Flutter WS event log around the same send.
- Whether a later real message row matches same normalized text and send time.

## Part G - Incoming Message Delay

Trace:

1. Server periodically runs sync loop in `app.runSyncLoop`.
2. Default interval is 5 seconds unless configured.
3. `SyncOnce` reads rows with `ROWID > last_message_rowid`, upserts relay rows, then returns inserted messages.
4. `broadcastSyncResult` emits `message:new` with full `MessageJSON`.
5. Flutter `WebSocketClient` parses event.
6. `ThreadController` reloads open thread on `message:new`, `message:update`, or `message:unsend` after 400 ms debounce.
7. Background/killed Android state has no WebSocket guarantee. Push is server-side capable but client integration is not evident in current Flutter code.

Current observations:

- Normal foreground delay should be roughly sync interval plus query/reload time; default expected delay is around 0-5+ seconds.
- `message:new` data now includes `chatGuid` through `MessageJSON`, despite stale Flutter comments saying otherwise.
- `ThreadController` still reloads on every message event instead of routing by `chatGuid` and inserting/updating in memory.
- Chat list controller does not appear to subscribe to WebSocket events; chat list may require manual refresh to reflect new rows.
- Android background receive needs push or a foreground service. A plain WebSocket is not reliable in background or killed state.

## Part H - Edited / Deleted Messages

| Layer | Edited support | Retracted support | Notes |
| --- | --- | --- | --- |
| chat.db probe | `SchemaCapabilities.EditedMessages` checks `date_edited` | `SchemaCapabilities.UnsentMessages` checks `date_retracted` | Capability-gated. |
| sync insert | New-message sync does not store edit/retract dates directly | Same | Mutable state is update-pass responsibility. |
| update pass | Reads `date_edited`, updates message_state, emits `message:update` | Reads `date_retracted`, emits `message:unsend` | Only for messages already in relay DB and inside lookback window. |
| normal API | `dateEdited`, `isEdited` via relay `message_state` join | `dateRetracted`, `isRetracted` via relay `message_state` join | Present for relay-backed API. |
| debug API | Directly shows date/flags when columns exist | Directly shows date/flags | Best source for manual evidence. |
| Flutter model | Parses fields | Parses fields | Good. |
| Flutter rendering | Effects/delivery/retracted are explicit; edited label needs verification | Renders retracted row | Add UI polish/tests for edited marker. |

Remaining gaps:

- Confirm update lookback is long enough for edits/retractions that happen later.
- Ensure `message:unsend` updates/removes current in-memory rows without full reload.
- Add visible edited indicator if absent in thread bubble.

## Part I - Background Receiving / Push Strategy

| Option | Foreground reliability | Background reliability | Killed reliability | Battery | Privacy | Complexity | Fit |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Foreground WebSocket only | Good while connected | Poor | None | Low | Good, direct only | Low | Current baseline only. |
| Android foreground service + persistent notification | Good | Medium-high if service remains | Low-medium depending OEM | Medium-high | Good | Medium | Useful for power users, noisy UX. |
| FCM/Firebase push | Good | High | High | Low | Sends token and selected preview metadata to Google | Medium-high | Best mainstream Android path; server already has self-host FCM provider. |
| UnifiedPush/vendor push | Medium | Medium-high | Medium-high | Low | Better provider choice | Medium-high | Good future privacy option; provider fragmentation. |
| Local network polling | Medium | Low-medium | None | Medium-high | Good | Low-medium | Fallback only. |
| Manual refresh only | User-driven | None | None | Lowest | Best | Lowest | Not enough for messaging. |

Current server push state:

- Notification dispatcher supports `none`, `webhook`, and conditionally active `fcm`; other providers are stubs.
- FCM payload is data-only with `type`, `messageGuid`, `chatGuid`, title/body preview based on preview mode, and created time.
- Push dispatch skips outgoing messages and respects sync/push rules.

Current Flutter gap:

- No FCM/notification registration path is visible in the current Flutter client code inspected. Devices can be registered by API shape, but Android push token collection/notification handling is not present in the read files.

## Part J - Supported Feature Matrix

| Feature | Server reads chat.db | Normal API | Debug API | Flutter parses | Flutter renders | Current status | Next action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Normal text | Yes | Yes | Yes | Yes | Yes | Supported | Keep tests. |
| `attributedBody` text | Yes | Yes as text | Yes with flag | Yes | Yes | Supported but sample-dependent | Collect failures. |
| Emoji-only text | Yes | Yes | Yes | Yes | Yes, should survive control filter | Likely supported | Manual sample. |
| Images | Yes | Yes | Yes | Yes | Yes | Supported | Improve thumbnails/cache. |
| TIFF images | Yes as image/tiff | Yes | Yes | Yes | Attempts image decode | Risky | Add preview/placeholder strategy. |
| HEIC/Live Photo | HEIC likely image; Live Photo not modeled | Partly | Partly | Partly | Depends decoder; no Live Photo pairing | Partial | Samples + preview. |
| Videos | Yes classified by MIME/UTI | Yes | Yes | Yes | File row/icon currently, not video player | Partial | Add video player/thumbnail. |
| Audio/voice | Yes | Yes voice flag | Yes | Yes | Audio player | Supported | More format tests. |
| Files | Yes | Yes | Yes | Yes | File row | Supported | Add open/download action. |
| Tapbacks | Yes semantic fields | Yes | Yes | Yes | Chips/rows | Partial/supported | Verify real samples. |
| Replies | Yes | Yes | Yes | Yes | Preview when target loaded | Partial | Improve target loading. |
| Message effects | Yes | Yes | Yes | Yes | Label hint | Partial | Verify IDs. |
| Edited messages | Yes via update pass | Yes | Yes | Yes | Needs visible polish | Partial | Add edited badge. |
| Unsent messages | Yes via update pass | Yes | Yes | Yes | Yes | Supported but timing-dependent | Verify lookback/event. |
| Delivered/read | Yes | Yes | Yes | Yes | Yes | Supported | Reconcile failed locals. |
| Failed sends | Yes `error`, send errors | Yes | Yes | Yes | Yes | Partial | Fix false failed after delivered. |
| Unread badges | Chat model parses optional only | Server chat API lacks unread count | Debug not relevant | Yes optional | Yes optional | Not supported end-to-end | Add server unread counts. |
| Contact names | Client local contacts | Not server | N/A | Yes | Yes | Supported client-side | Keep presentation-only. |
| Contact avatars | Client local thumbnail | Not server | N/A | Yes | Yes | Supported client-side | Cache carefully. |
| Group events | Yes | Yes | Yes | Yes | Generic event | Partial | Better labels. |
| Stickers/iMessage apps | Partly | Partly | Yes | Partly | Sticker/file/service fallback | Partial | Sample-driven rendering. |
| System/noise rows | Debug detects; normal filters many | Some may pass if attachment flag/semantic | Yes | Yes | Unknown/service rows | Partial | Server classification policy. |
| Hidden/merged display prefs | N/A | N/A | N/A | Yes | Yes | Supported client-side | Ensure defaults match UX. |
| Foreground realtime receive | Yes WS | Yes event | N/A | Yes | Reloads thread | Partial | Route by `chatGuid`. |
| Background receive | Server push possible | Device/push API exists | N/A | Not evident | Not evident | Gap | Implement push or service. |
| Push notifications | Server FCM/webhook | Device endpoints | N/A | Not evident | Not evident | Server partial/client gap | Next push phase. |

## Part K - Evidence Needed From Message Inspector

Use `GET /api/debug/recent-messages` or the companion Message Inspector. Redact phone numbers, emails, names, message text, attachment filenames if sensitive, bearer tokens, local paths, and full download URLs.

| Sample | Suggested filters | Fields to check | Copy/redact |
| --- | --- | --- | --- |
| Empty/noise row | `type=unsupported` or `hasAttachments=none` | `text`, `hasAttributedBody`, `cacheHasAttachments`, semantic fields, dates, handle | Copy full debug JSON; redact handles/text/chat names. |
| Tapback row | `type=reaction` | `associatedMessageType`, `associatedMessageGuid`, sender handle, target GUID | Redact handles; keep numeric code and GUID shape if possible. |
| Reply row | `type=reply` | `threadOriginatorGuid`, text, target availability | Redact text/handles. |
| TIFF screenshot | `hasAttachments=image`, search `.tif`/`.tiff` | attachment `mimeType`, `uti`, `transferName`, `filename`, `totalBytes` | Redact filename if personal. |
| Edited message | search known edited text/time | `dateEdited`, `isEdited`, normal text after edit | Redact message text. |
| Unsent message | search around unsend time | `dateRetracted`, `isRetracted`, remaining text | Redact content; preserve flags. |
| Android failed but iMessage delivered | search outgoing text/time | `error`, `dateDelivered`, `isDelivered`, `guid`, `dateCreated` | Redact text; keep timing deltas and tempGuid logs separately. |
| Delayed incoming | filter incoming chat/time | `dateCreated`, server sync logs, WS event time | Redact handle/text. |
| Unknown/deleted sender | `sender` blank or unexpected handle | `handleId`, `chatGuid`, `chatIdentifier`, `chatDisplayName` | Redact handles but preserve null/non-null shape. |
| Emoji-only | search emoji/time | `textLength`, `text`, classification | Redact if needed; keep whether non-ASCII survived. |
| iMessage effect | search effect message/time | `expressiveSendStyleId`, `balloonBundleId`, `payloadDataPresent` | Redact content. |

## Part L - Recommended Next Implementation Order

1. Server row classification/noise policy: decide which semantic/no-content rows belong in normal API vs inspector-only, and add explicit classification to normal JSON if helpful.
2. TIFF/preview handling: add server preview/thumbnail endpoint or client TIFF placeholder before more UI polish.
3. Send-state reconciliation: after timeout/failed local state, reconcile later matching outgoing rows by chat/text/time and clear duplicate failed temp rows.
4. Incoming update latency: use `chatGuid` in `message:new/update/unsend` to update only the relevant thread and refresh chat list.
5. Edited/retracted rendering polish: visible edited badge, stronger unsend update handling, tests with real samples.
6. Push/background strategy: implement Android FCM registration/handling first, then consider foreground service for direct mode.
7. UI performance and Mategram-style rewrite: only after data fidelity issues stop producing misleading UI.
8. Final UI polish: grouped media, video player, file open/download, richer service event labels.

## Biggest Findings

1. `message:new` payloads now carry `chatGuid` via `MessageJSON`, but Flutter still treats message events as unroutable and reloads the open thread globally.
2. Server-side semantic support is stronger than some stale Flutter comments suggest.
3. TIFF is currently classified as image, so Flutter attempts direct decode and may fail on Android.
4. A `send:error` timeout can leave a failed local optimistic row even if the real sent/delivered row appears later.
5. Background receive is not solved by the current Flutter client; server FCM support exists but client push handling is the missing half.
6. Debug Inspector is the right evidence collection path because it shows rows normal API may filter or merge.

## Files Inspected

Server:

- `MicaGoServer/micago-server/internal/app/app.go`
- `MicaGoServer/micago-server/internal/store/models.go`
- `MicaGoServer/micago-server/internal/store/queries.go`
- `MicaGoServer/micago-server/internal/store/debug.go`
- `MicaGoServer/micago-server/internal/store/classify.go`
- `MicaGoServer/micago-server/internal/store/attachmentkind.go`
- `MicaGoServer/micago-server/internal/store/capabilities.go`
- `MicaGoServer/micago-server/internal/relaydb/migrations.go`
- `MicaGoServer/micago-server/internal/relaydb/sync.go`
- `MicaGoServer/micago-server/internal/relaydb/query.go`
- `MicaGoServer/micago-server/internal/relaydb/updatepass.go`
- `MicaGoServer/micago-server/internal/httpapi/handlers.go`
- `MicaGoServer/micago-server/internal/httpapi/debug.go`
- `MicaGoServer/micago-server/internal/httpapi/router.go`
- `MicaGoServer/micago-server/internal/realtime/event.go`
- `MicaGoServer/micago-server/internal/realtime/hub.go`
- `MicaGoServer/micago-server/internal/send/*`
- `MicaGoServer/micago-server/internal/notify/payload.go`
- `MicaGoServer/micago-server/internal/notify/dispatcher.go`
- `MicaGoServer/micago-server/internal/notify/fcm.go`

Flutter:

- `MicaGoFlutterClient/lib/core/network/api_client.dart`
- `MicaGoFlutterClient/lib/core/network/websocket_client.dart`
- `MicaGoFlutterClient/lib/features/chats/models/message_model.dart`
- `MicaGoFlutterClient/lib/features/chats/models/chat_summary.dart`
- `MicaGoFlutterClient/lib/features/chats/message_render.dart`
- `MicaGoFlutterClient/lib/features/chats/message_display.dart`
- `MicaGoFlutterClient/lib/features/chats/message_thread_screen.dart`
- `MicaGoFlutterClient/lib/features/chats/attachment_views.dart`
- `MicaGoFlutterClient/lib/features/chats/media_viewer.dart`
- `MicaGoFlutterClient/lib/features/chats/chat_list_controller.dart`
- `MicaGoFlutterClient/lib/features/chats/chat_list_screen.dart`
- `MicaGoFlutterClient/lib/features/chats/avatar.dart`
- `MicaGoFlutterClient/lib/features/contacts/contact_identity.dart`
- `MicaGoFlutterClient/lib/features/contacts/contacts_service.dart`

Reference code:

- `Ref/` was intentionally not inspected after the latest instruction.

## Validation

Only read-only commands were used before creating this documentation file. No source code, migrations, formatting, or tests were run. `git status --short` was clean before adding this document.
