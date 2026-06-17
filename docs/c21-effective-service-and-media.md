# C21 — Server-authoritative effective service + media alignment

Corrective pass: make iMessage/SMS sendability one server-authoritative
decision used identically for display and send, and confirm media/sticker/emoji
follow proven BlueBubbles patterns. Audit-first; full audit in the task thread
and summarized below.

## Audit findings

1. **Client disagreed with server** on the *same* chat: the badge normalized the
   chat-row `service_name` via `ServiceCategory()` (iMessage + iMessageLite →
   iMessage) while the send gate started with a strict `== "iMessage"`. No
   single server-computed effective service existed; neither side was
   message-aware; and the client could read a **stale cached** chat row.
2. **Text vs attachment gates** were already unified on each side (C20) — both
   use `_canSendNow` (client) / `chatSendable` (server). The real split was
   client-derived service vs server-derived service.
3. **BlueBubbles**: the client sends to `chat.guid` and the **server routes**
   iMessage vs SMS (its `isIMessage`/`isTextForwarding` read a server-set GUID
   prefix — server-authoritative; "method" is private-api/apple-script, the
   mechanism, not the service). Attachment send is multipart to `chatGuid`
   (we already match). MIME via `mimeType ?? mime(name)`, `mimeStart` →
   image/video/audio (we already do this); stickers/tapbacks/emoji handled by
   attachment kind + `associatedMessageType` + larger emoji text (we already
   have these).

## What changed

### Server — one source of truth
- `relaydb.ResolveEffectiveService(chatService, latestMsgService)`: normalizes
  both and **prefers iMessage** (a phone-number chat whose row says SMS but
  whose latest message is iMessage resolves to iMessage, and vice-versa).
  Message-aware; never the GUID/handle shape.
- Exposed as `effectiveService` on `ChatJSON` (ListChats adds a `latest_service`
  subquery) and on `ChatInfo` (GetChatInfo queries the latest message service).
- `chatSendable` now gates on that **same** effective service via
  `SyncSettings.CategorySendable(category)` (iMessage always; SMS iff
  `AllowSMSSend`; RCS/unknown never). Display and gate can no longer disagree —
  they read the identical value.

### Client — consume only
- `ChatSummary.effectiveService` (from the server); `ChatSummary.service` uses
  it first, with `serviceCategory`/`serviceName` only as a fallback for older
  servers. `chatServiceFromServer` is the single string→enum mapper and is
  called from exactly one place (`ChatSummary.service`).
- One sendability path: `chat.service.canSendWith(allowSmsSend)` drives the
  badge, composer-enabled state, text send, attachment send, and retry — all via
  `_canSendNow` in the thread screen. No GUID/handle/stale-cache decision; the
  server is the final authority and returns a clear error if the client's view
  is momentarily stale.

### Media / sticker / emoji (#2)
No new abstractions — the existing flow already matches BlueBubbles: attachment
send is multipart to the chat GUID (`/api/chats/{guid}/send-attachment`, C19),
gated by the **same** `_canSendNow`; type detection is mime/`mimeStart`-based
(server `attachmentKind` + client `isImage/isVideo/isAudio`); stickers, tapbacks
and emoji-only rendering are unchanged. So image/video/file send work for
phone-number iMessage chats (and for SMS when the setting is on and the server
allows), with the failure/retry state from C19.

## Tests
- Server: `relaydb.TestResolveEffectiveService` (prefer-iMessage, message-aware,
  iMessageLite, RCS/unknown), `TestCategorySendable`,
  `TestEffectiveServiceMessageAwareRoundTrip` (chat row SMS + latest msg iMessage
  → effective iMessage on ListChats + GetChatInfo). Existing send/SMS-gate tests
  pass via the effective path.
- Client: `effective_service_test.dart` — effectiveService overrides a stale
  SMS row → iMessage + sendable; downgrade to SMS → read-only unless enabled;
  unknown stays read-only; older-server fallback; cache round-trip. Existing
  `service_authority_test.dart`, `sms_sendability_test.dart`,
  `attachment_send_test.dart`, `message_render_test.dart` all still pass (no
  media/sticker/emoji/tapback regression).

## C21 continuation — aggressive cleanup + BlueBubbles media UX

### Service (Part A)
- `ResolveEffectiveService(chatService, latestMsgService, hasIMessage)` is now
  **capability-aware**: a phone-number chat with **any** iMessage message in its
  history resolves to iMessage even if the latest message fell back to SMS —
  "prefer iMessage if iMessage capability exists." (ListChats/GetChatInfo add an
  `imessage_count` query.)
- The server exposes explicit `canSendText` + `canSendAttachments` on `ChatJSON`
  (`SyncSettings.SendCapabilities`). The client consumes these booleans directly
  via `ChatSummary.canSendText/canSendAttachments` — **zero client inference**;
  text send, image send, file send, and the badge all read the same server
  values (older-server fallback derives from `service` + the SMS setting).

### BlueBubbles-style media UX (Parts B–D)
- Adapted `text_field_attachment_picker.dart`: the **+** toggles an in-composer
  `AttachmentPanel`. **C21 finalization** brings it close to BlueBubbles with
  `photo_manager`: the panel shows a horizontal **grid of recent gallery media**
  (images + videos, thumbnails) preceded by Camera / Video / Files action tiles.
  Tapping a thumbnail **toggles** it into the selection with a check overlay
  (BB-style multi-select); video tiles show a play badge. Picked items **stage**
  into a `StagedAttachmentStrip` (thumbnails + per-item remove); Send dispatches
  the batch. Permission states are handled — granted/limited show the grid (with
  a "More photos" tile on iOS limited), denied/restricted show a prompt with
  "Open Settings"; the Files picker is always available as a fallback.
  `StagedAttachment.sourceId` carries the gallery asset id so the grid can
  toggle a selection off. Replaces the earlier system-picker-first panel.
- Multi-send: `ThreadController.sendAttachments` posts each staged file to the
  chat GUID sequentially (the server routes the service), then one catch-up. No
  optimistic bubble → **no duplicate media bubbles** after refresh. Failures stop
  the batch and surface a retry/error snackbar.
- `image_picker` added (multi-photo/video + camera) alongside `file_picker`
  (generic files); iOS `NSPhotoLibrary/Camera/Microphone` usage strings added;
  permission denial handled gracefully via the panel's `onError`.
- Display unchanged/no regression: images inline, audio playable, files as cards,
  stickers inline as images, video as a file card (movie icon), tapbacks/emoji
  intact.

### Cleanup (deleted)
- The immediate-native-picker `_pickAndSendAttachment` flow (replaced by the
  staged panel).
- Client-side sendability inference in the thread screen (`_canSendNow` →
  explicit `_canSendText`/`_canSendAttachments` from server caps).

### Tests (added)
- Server: `TestEffectiveServicePrefersIMessageFromHistory`,
  `TestSendCapabilities`.
- Client: `capability_and_media_test.dart` — explicit caps win over local
  derivation; phone-number iMessage enabled; unknown read-only; text/attachment
  gates same source; older-server fallback; `StagedAttachment` image detection;
  multi-image each posts to `/send-attachment`.

## Validation

| Check | Result |
| --- | --- |
| Phone-number chat, server-effective iMessage: badge iMessage, composer enabled, text+image/file/video send allowed | ✅ effectiveService=imessage → one gate |
| Phone-number chat, effective SMS + SMS-send off: readable, send disabled | ✅ |
| Effective SMS + SMS-send on: text + media allowed | ✅ (media when server allows) |
| Unknown read-only; `any;-;` never disables iMessage send | ✅ |
| Attachment gate == text gate (same source) | ✅ `_canSendNow` |
| Image/video/file MIME detection BB-style | ✅ unchanged |
| Sticker/emoji/tapback no regression | ✅ tests pass |
| `go build`/`go test`, `flutter analyze`/`test`, APK, `xcodebuild` | ✅ |

## C21d continuation — delta sync, virtual contact merge, composer polish

Three correctness/UX passes. Firebase is **not** implemented yet (still
WebSocket realtime + catch-up). See `c21-sync-firebase-audit.md` for the model.

### Part 1 — Delta sync / client cursor (correctness path)
The WebSocket is the *fast* path; a persistent client cursor is the
*correctness* path so messages received while backgrounded / disconnected /
WS-down are caught up on reconnect, resume, startup, and the fallback poll —
without a full reload and without duplicate bubbles.

- **Server**: every `MessageJSON` now carries `sourceRowId` (the chat.db
  `ROWID`, monotonic — the cursor). New `GET /api/messages/delta?since=&limit=`
  → `relaydb.ListMessagesSince` returns `{messages, chatGuids, cursor, hasMore}`
  oldest-first above `since`. Seeding: `since < 0` returns `cursor = max(rowid)`
  with **no** messages (no first-run backfill flood); on a quiet period the
  cursor advances to the ceiling so we don't re-scan. Debug-only rows excluded;
  `limit+1` paging detects `hasMore` (cap 500, default 200).
- **Client**: `AppController.runDeltaSync` persists `sync_cursor` in cache
  metadata (survives restart), pages until `!hasMore`, upserts each message into
  the local cache, and republishes via a broadcast `deltaMessages` stream. It is
  wired into `catchUp`, so all four triggers (reconnect / resume / startup /
  fallback poll) run it. `ThreadController` and `ChatListController` subscribe:
  the thread `upsertServer`s (GUID dedup → no duplicate bubble), the list
  debounce-reloads its summaries.
- Tests: `relaydb.TestListMessagesSinceDelta` (seed / since / paging / noise
  excluded); client `delta_sync_test.dart` (parse + seed).

### Part 2 — Client-side virtual contact merge (view only)
Different iMessage/SMS chats for the **same contact** are merged into one
chat-list entry **in the UI only** — server chat rows and relay DB rows are
never merged, and every send still targets a real `chat.guid`.

- `MergedChat` + `mergeChatsByContact(chats, contactIdFor)`
  (`models/merged_chat.dart`): groups 1:1 chats whose handle resolves (via
  `ContactsService.contactIdFor` → normalized phone/email) to the **same**
  contact id. Safety — *prefer safety over over-merging*: group chats are never
  merged, and an unresolved handle (null id) stays standalone (don't merge if
  uncertain). Routes are ranked iMessage → RCS → SMS → unknown, then by recency;
  `primary` (the default route) is the first.
- Chat list renders one row per `MergedChat` (a merge glyph + a route subtitle
  like "iMessage · SMS" when merged). The thread screen takes a `MergedChat`,
  views one route at a time, and shows a **route selector** in the header when
  there are ≥2 routes; picking a route rebinds the thread to that route's real
  GUID and sends/gates with **its** server `canSendText/canSendAttachments`.
  Default prefers iMessage; SMS is last unless explicitly selected.
- Tests: `merged_chat_test.dart` (merge phone+email+SMS; default prefers
  iMessage over a more-recent SMS; unresolved not merged; groups never merged;
  newest-route preview/timestamp).

### Part 3 — Composer / media UI polish
- Attachment panel: the standalone **Video** action tile was removed — only
  **Camera** and **Files** remain; recent **videos still appear in the grid**
  (play badge) and send like any other attachment. Multi-select + staged preview
  unchanged.
- Composer redesign (`_Composer` is now stateful): **`+` on the left** only
  (morphs to ×, toggles the panel); a **black rounded "Message" capsule** in the
  centre (`inverseSurface`) with the **voice** button inside on the right when
  idle/empty and the **emoji** button when the field is focused; the **send**
  button sits **outside on the right**, enabled when there's text *or* staged
  attachments. Small animations: focus border (`AnimatedContainer`), voice↔emoji
  swap and +/× (`AnimatedSwitcher` scale+fade), send enabled/disabled
  (`AnimatedScale`+`AnimatedOpacity`), panel open/close (`AnimatedSize`).
- **Voice is a UI affordance only** — recording isn't implemented, so the mic
  button shows a clear "not available yet" snackbar rather than shipping a
  half-working recorder (the audio send path would reuse `sendAttachments`).
- Unchanged: text send, attachment send, SMS gating, and route selection all
  still read the server-authoritative capabilities.

## C21u continuation — focused UI/UX refinement

A polish pass (no sync rewrite; delta cursor logic untouched; effectiveService /
canSendText / canSendAttachments still server-authoritative).

1. **Thread top-right → search/details.** The bare Refresh icon was replaced by a
   **search/details** action (`Icons.search`) that opens a bottom sheet with the
   contact's routes (server service per route), an in-thread search box (filters
   this thread's messages), and a manual Refresh — refresh is still available,
   just not the primary action.
2. **Composer — floating capsule + theme colors.** The composer is now a
   **floating capsule** (horizontal margin, rounded `surfaceContainer`, soft
   shadow) instead of a full-width bar. The earlier hardcoded `inverseSurface`
   ("black") capsule was replaced with **scheme-derived** colors
   (`surfaceContainerHighest` fill, `onSurface` text, `onSurfaceVariant` hint),
   so dark mode stays dark and light mode stays light. Layout kept: **`+` left,
   Message capsule centre, send outside right**; **voice inside when empty/
   unfocused, emoji when focused**. The **emoji button now has a real action** —
   a native inline emoji grid (`_EmojiPicker`, no plugin) that inserts at the
   cursor; tapping again closes it. Animations cover capsule float/focus
   (`AnimatedContainer`), the voice↔emoji swap (`AnimatedSwitcher`), the picker
   open/close (`AnimatedSize`), and send enabled/disabled.
3. **Top-anchored notifications.** New `TopBanner` (`core/ui/top_banner.dart`)
   renders system messages as a slide-in banner **under the title bar** over the
   root overlay, de-duped (identical message within 3s is suppressed) and
   auto-dismissed. Connection lost/recovered + fallback switch (transient
   `ConnectionNoticeHost` notices), send/attachment errors, the voice affordance,
   media-permission errors, and the SMS-setting error all route through it
   instead of bottom snackbars. The sticky offline banner already lived at the
   top and is unchanged.
4. **Large-screen sidebar centering.** `NavigationRail.groupAlignment: 0.0`
   centers the rail items vertically. Structure unchanged.
5. **Timestamp/status grouping (BlueBubbles-style).** The footer no longer shows
   a time under **every** bubble. `ThreadPresentationBuilder` now emits a
   centered **time chip** only on a large same-day gap (`kTimeClusterGap` = 60m,
   `TimeSeparatorItem`), sets `showTimestamp` on just the **newest** message, and
   bubbles **reveal their own time on tap** (`_MessageBubble` is now stateful;
   long-press still opens the Message Inspector — unchanged). Delivery status
   (Sent/Delivered/Read/Failed) stays on the latest outgoing; edited/unsent/
   retracted/system hints and tapbacks/reactions/stickers are untouched.
6. **Paired devices — no duplicates, delete, live state.** The Flutter client now
   generates a **stable device id** (`generateStableDeviceId`, persisted, memoized
   so concurrent reconnects can't race into two rows) and **always** sends it, so
   the server upserts the same row. Registration also reports **app version**,
   **mode** (`lan` / `lan_public`, derived from the active connection candidate),
   and push capability; the device `name` is now clean (version is its own field).
   A **30s heartbeat** (`POST /api/devices/{id}/heartbeat`) keeps the device in
   the server's **90s connected window** — when the app/network goes away the
   ticks stop and it shows disconnected. The server adds `app_version` + `mode`
   columns (additive `ensureColumn` migration) and exposes `appVersion`, `mode`,
   and a derived `connected` on `DeviceJSON`. The **Companion** device card was
   redesigned (`DeviceCardRow`): main line **"{name} - MicaGo {version}"**,
   secondary **"mode: …, push: …"** (push shows **"not configured"** when absent),
   right column **Connected/Disconnected + last-connected time**, and a top-right
   **edit menu** exposing **Remove Device** (uses the existing `DELETE
   /api/devices/{id}`) and Test Push. No private data is shown.

### Tests (added)
- Server: `relaydb.TestDeviceReregisterUpsertsNoDuplicates` (same stable id →
  one row, mode/version/last-seen updated); existing `TestDeviceUpsertListDelete`
  covers delete. `httpapi.TestDeviceConnectedDerivation` (freshness window +
  `deviceToJSON` carries appVersion/mode/connected).
- Client: `thread_presentation_test.dart` — time-separator grouping (no chip when
  close, chip on >60m gap), newest-only default timestamp, pure
  `shouldShowTimeSeparator`/`timeOfDayLabel`. `device_identity_test.dart` — stable
  id always sent + unique, clean name, mode default. `top_banner_test.dart` — the
  banner renders in the top half and identical messages don't stack.

### Validation
| Check | Result |
| --- | --- |
| Thread top-right shows search/details, not refresh | ✅ |
| Composer is a floating capsule; dark/light correct (scheme colors) | ✅ |
| Emoji button inserts emoji (native inline picker) | ✅ |
| Popups appear under the title bar (top banner) | ✅ |
| Large-screen sidebar items centered | ✅ `groupAlignment: 0.0` |
| No timestamp under every bubble (grouping + tap reveal) | ✅ |
| Paired devices don't duplicate on re-register; stale devices deletable | ✅ |
| Devices show connected state + last-connected time | ✅ |
| `go build`/`go test`, `flutter analyze`/`test`, APK, `xcodebuild` | ✅ |
