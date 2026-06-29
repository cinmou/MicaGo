# CLAUDE.md — working guide

Live notes for Claude when working in this repo. Keep it short; update it as part of any pass.

## What MicaGo is

Three components:

- **Go relay server** — `MicaGoServer/micago-server`. Reads the Mac's Messages DB, exposes a local control + chat API, syncs into `relay.db`, serves chats/messages/delta + WebSocket. Tests: `go test ./...`, `go vet ./...`.
- **macOS Companion** (SwiftUI) — `MicaGoServer/micago-mac-companion`. Menu-bar + dashboard that launches/monitors the server, manages pairing/URLs, sync rules, devices, notifications. Build: `xcodebuild`.
- **Flutter Android client** — `MicaGoFlutterClient`. Pairs over LAN/public URL, syncs, sends, optional FCM push. Checks: `flutter analyze`, `flutter test`, `flutter build apk --debug`.

## Important rules

- **Never commit unless explicitly asked.** Branch first if on `main`.
- **Never log, commit, or expose** bearer tokens, push tokens, or service-account paths. The Companion redacts tokens in captured server stdout (`BackendController.redact`).
- Keep it **lightweight** — no new dependencies without a clear need.
- **Firebase, keep-alive, and IMCore message actions are all optional and off by default.** Don't word docs/UI as if they're required or guaranteed.
- Keep final logs clean (debug-guarded only).
- Companion menu-bar icon must use **template rendering** (no hard-coded colors) so it adapts to light/dark menu bars.
- **Before debugging sync, check the running backend binary's version against source** — a stale binary is a common false lead. Rebuild via `scripts/build-backend.sh`.

## Known UI/state notes

- `serverDisplayState(process:reachable:)` (`BackendController.swift`) is the single source of truth for combined process+reachability state; both the menu-bar icon and the dashboard pill derive from it.
- Sync Control loads four endpoints (`sync/rules`, `sync/settings`, `chats`, `messages/recent`). A failure in any one is what users see as a page error.
- Contacts permission on macOS can only be prompted by the app once (`.notDetermined`); after that it's System-Settings-only. The UI must not offer a dead "Allow" button.

## Localization (zh-Hans + zh-Hant)

- **Flutter client:** `lib/core/l10n/app_localizations.dart` holds `en` / `zhHans`
  / `zhHant` tables (kept key-for-key parallel — verify with a key-diff before
  adding). `MicaLocalizations.of(context).t('key')` (falls back to `en`, then the
  raw key). Locale chosen in Settings (`settings.systemLanguage`/`english`/
  `zhHans`/`zhHant`); delegate maps `zh`+`Hant`→zhHant, `zh`→zhHans. The
  Notifications settings card + the chat "Sticker" label are localized
  (`notif.*`, `chat.sticker`); technical diagnostic key/value pairs stay English.
  Background-isolate notification strings (push_service) have no context, so they
  aren't localized.
- **Companion:** `Localization.swift` (`L10n.tr`) covers the sidebar + menu
  (en/zhHans/zhHant). Most dashboard body text is still hardcoded English (large
  follow-up).
- **Docs:** `README.md` + `README.zh-Hans.md` / `.zh-Hant.md` and `docs/index.md` +
  `index.zh-Hans.md` / `.zh-Hant.md` and `docs/getting-started.*` — each with a
  language switcher. C38 restyled the README + docs hub in a hero / language-switcher
  / key-links-bar / emoji-section / capability-table / "what it does vs does not do" /
  honest-limitations / closing-CTA style (centered `<div>` blocks render on GitHub).
  zh-Hant uses Taiwan terms (伺服器/訊息/預設/推播/貼圖/權杖/影片). The 4 individual
  guides (android-client-connection / remote-access-cloudflare / notifications-setup /
  manual-test-flow) are still English-only — the localized index marks them "(英文)".

## Chat-row crash fix + cleanup (C44, backend v0.36)

- **White-screen fix.** The chat row used a `ListTile` whose `trailing` (time +
  draggable badge) could be reported full-width → "Trailing widget consumes the
  entire tile width" layout assertion → blank home page. Rebuilt `_ChatRow` as a
  custom `Row` (`InkWell` + avatar + `Expanded` title/preview + trailing column),
  so there's no `ListTile` trailing-width constraint. Same visual spec (tinted
  rounded card for numbered unread, plain dot otherwise).
- **Badge controller crash fix.** `_DraggableUnreadBadge` held the spring
  `AnimationController` in a **lazy** `late final = AnimationController(...)`. When
  the badge was removed the same frame it appeared, the field was first constructed
  inside `dispose()`, which touches an inherited widget (`TickerMode`) on a
  deactivated element → "Looking up a deactivated widget's ancestor is unsafe."
  Now created eagerly in `initState`.
- **Dead-code cleanup.** Removed the zero-caller `ChatListController.hideChat`
  (single) and `ChatListController.alwaysShowChat`. Kept `setChatAlwaysVisible`
  (still tested + part of the hidden-chat filter).
- Versions bumped to **0.36.0** (Go, Flutter pubspec + `kAppVersion`, Companion).

## Watermark-derived unread dot (C43)

- **The home unread dot is now derived from chat data, not a live counter.**
  Replaced the fragile "increment `unreadCount` only on WS/delta `message:new`"
  model (which missed app-closed / FCM-wake / reconnect cases) with BlueBubbles'
  rule, computed on every refresh:
  `hasUnread = latestRenderableAt > lastSeenAt && !latestRenderableFromMe`.
- **Server:** `ChatJSON.latestRenderableFromMe` (added to the `ListChats` query —
  the `is_from_me` of the latest renderable message). Additive; no version bump.
- **Client cache (schema v5):** new `chats.last_seen_at` + `chats.latest_from_me`
  columns. `last_seen_at` is seeded to the chat's latest **only on first insert**
  (existing history starts "seen"); `bumpChatWithMessage` advances
  `latest_renderable_at`/`latest_from_me` but leaves the watermark behind unless
  `seen` (my message OR the chat is open); `markChatsSeen` catches the watermark up
  (open / mark-read / badge-drag). `_chatFromRow` derives `hasUnread`. `load()` now
  displays from the cache (filtered to the server's guids) so reload/delta/resume/
  pull-to-refresh all agree.
- **Decoupled from notifications entirely** — FCM/WS/keep-alive never gate the dot.
  `ChatSummary.hasUnread` is the source of truth; `unreadCount` is only the badge
  number. Visuals: `hasUnread && count>0` → tinted rounded card + red number pill;
  `hasUnread && count==0` → plain accent dot, no tint; `!hasUnread` → normal row.
- **Draggable badge** (`_DraggableUnreadBadge`): long-press the badge to grab, drag
  it away; past ~44px on release → `markRoutesRead` (advances `lastSeenAt`, dot
  clears); under → elastic spring-back. Doesn't open the chat (long-press gesture,
  no scroll conflict).
- **Deleted** the old `clearUnreadForChats` / `setChatUnreadCount` / `unreadCounts`
  cache methods and the `load()` unread-overlay.

## Pin/hide + test-contact Debug card (C42, backend v0.34)

- **Test contact, two-way via the Companion Debug card.** New
  `POST /api/test-contact/inbound` injects a message *from* the test contact
  (`is_from_me=0`) + broadcasts `message:new` → pushes to the phone like a received
  iMessage (`internal/relaydb/testcontact.go` `AppendTestInboundMessage`; handler in
  `internal/httpapi/testcontact.go`). The Companion's **Message Inspector** (Debug)
  has a `TestContactDebugCard` pinned at the top: a 2-way scratchpad (text field →
  inbound; the phone's loopback replies poll in via `GET /api/chats/{guid}/messages`).
  Each **server (re)start resets** the conversation to just the greeting
  (`ResetTestContactMessages`, called from `app.Run`).
- **Sync Control ↔ Debug alignment.** `RecentMessagesCard` now fetches
  `messages/recent?debug=true` (the full raw set — no silently dropped rows) and
  shows a bracketed placeholder (`[图片]`/`[视频]`/`[语音]`/`[贴图]`/`[文件]`, via
  `RecentMessage.previewLabel` + `RecentAttachment.placeholder`) instead of a blank
  "(no text)" row.
- **Client pin/hide (chat-level + message-level), all client-only.** Cache schema
  **v4**: `chats.pinned` column + a `hidden_messages` tombstone table (kept out of
  the messages table so a server re-sync's delete+reinsert can't resurrect a hidden
  message). Chat list: **swipe right = clear the unread dot, swipe left = hide**
  (`Dismissible`); **long-press = Pin/Unpin or Hide** (`_showChatMenu`). Pinned chats
  sort to the top (`ORDER BY pinned DESC`). Thread: long-press a message → **Hide**
  (`MessageAction.hide` → `ThreadController.hideMessage`). Settings → **Hidden items**:
  "Release hidden messages" + "Release hidden contacts" (`_HiddenItemsCard`).
- **Fixed a latent bug:** `upsertChats` used `ConflictAlgorithm.replace`, which
  delete+reinserts and **reset the flag columns** (`hidden`/`always_visible`/`pinned`)
  on every server refresh. Switched to `INSERT … ON CONFLICT(guid) DO UPDATE` that
  only rewrites json/timestamp, so the flags persist.
- **Requires rebuilding the bundled backend** (new endpoint + reset-on-start) and the
  client (schema v4 rebuilds the cache).

## Unread badges (C41)

- The chat-list card shows a circular unread count (`_UnreadCountPill` in
  `chat_list_screen.dart`). The count is **client-tracked** — the server's
  `ChatJSON` does not carry unread.
- **Ownership:** the local cache holds the count. `bumpChatWithMessage(markUnread:)`
  increments on an incoming WS `message:new`; the list's `markRoutesRead` (run from
  `_openMerged`, the single thread-entry point for both panes and notification
  deep-links) clears on open; `_switchRoute` clears a sibling route on switch.
- **The bug that was fixed:** `load()` displayed the raw server list (no unread), so
  every reload wiped the badges even though `upsertChats` preserved the count in the
  cache. `load()` now overlays the cached counts (`LocalCacheStore.unreadCounts()`)
  onto the authoritative server result — badges survive reloads, and chats the
  server drops still disappear (don't read the whole list back from cache, which
  never prunes).
- **Idempotent increment:** `_patchMessageEvent` checks `hasMessageGuid` **before**
  the upsert and only marks unread for a genuinely new guid, so a replayed WS event
  can't over-count.
- **Cleanup:** removed the redundant unread-clear in `MessageThreadScreen.initState`
  (the list's `markRoutesRead` already clears every open). `setActiveChatGuid` keeps
  the open route from re-incrementing while on screen.

## Offline test contact (C40)

- A self-contained **loopback test contact** (`test@micago.cinmou` — a domain
  that does not resolve, so nothing can ever be delivered). Lets you exercise the
  chat/notification pipeline without messaging a real person.
- **Server** (`internal/testcontact` constants + `internal/relaydb/testcontact.go`):
  a synthetic chat `iMessage;-;test@micago.cinmou` upserted into relay.db with a
  seeded inbound greeting. `SetTestContactEnabled` seeds/removes it; the on/off
  flag lives in `sync_state` (`test_contact_enabled`). Synthetic message rows use
  **NULL `source_rowid`** on purpose — the delta cursor is `MAX(source_rowid)`, so
  a synthetic rowid would corrupt real incremental sync; NULL keeps them out of
  the delta watermark entirely (they still show on chat open via `date_created`
  and live over WS). Endpoints: `GET/PUT /api/test-contact`.
- **Send interception** (`internal/httpapi`): `SendText` branches to
  `sendTestLoopback` for the test chat **before** any AppleScript/Messages
  machinery — it records the message as a delivered outgoing row and confirms it
  over the normal `send:match` path. `SendAttachment` rejects the test chat
  (text-only). Nothing ever reaches Messages.app. No auto-reply (record-only).
- **Client**: a **Settings → Testing** switch (`_TestContactCard`,
  `AppController.setTestContactEnabled` → `PUT /api/test-contact`). Enabling
  broadcasts the greeting as `message:new`; the chat-list controller reloads via a
  new `AppController.chatListReloads` signal (also fired on disable) so the chat
  appears/disappears without a manual refresh. New l10n: `settings.testing` +
  `settings.testContact*`.
- **Requires rebuilding the bundled backend** (new endpoints + send interception)
  and the client.

## Sticker bytes not served (C39)

- **Client showed "贴纸" but no image** because the sticker's file lives in
  `~/Library/Messages/**StickerCache**/…` — a **sibling** of `Attachments`. The
  `resolveAttachmentPath` guard (`internal/httpapi/handlers.go`) only allowed paths
  **under** `attachmentsRoot`, so it 404'd the sticker. Fixed: allow the
  `StickerCache` sibling too (`stickerCacheRoot`), guard still restricts to those
  two Messages subdirs. Verified live: `GET /api/attachments/{guid}` → 200 image/png
  served straight from StickerCache. Test: `internal/httpapi/sticker_path_test.go`.
- Also made sticker **preview conversion format-driven** (`NeedsPreviewConversion` /
  `attachmentNeedsPreviewConversion` no longer force-convert every sticker) — a PNG
  sticker serves as-is; only HEIC/TIFF convert.
- Removed the long-press **Message Info** entry (`MessageAction.info`) from
  `showMessageActionMenu`; the `_SystemRow` tap-to-diagnose stays. Tests updated.
- Requires rebuilding the bundled backend.

## Stickers / location / handwriting (C37, backend v0.32)

- See [MicaGoServer/docs/stickers-location-handwriting.md](MicaGoServer/docs/stickers-location-handwriting.md).
- **Server** (`internal/store/attachmentkind.go`): stickers also detected by UTI
  (`com.apple.sticker`/`*.sticker`) not just the `is_sticker` flag; new
  `AttachmentKindLocation`/`DisplayKindLocation` from vlocation
  (`text/x-vlocation`/`public.vlocation`/`.loc.vcf`). Tests in
  `attachmentkind_test.go`.
- **Client**: `_LocationAttachment` card (fetch vlocation → extract Maps URL →
  Open in Maps via url_launcher); `MessageModel.isHandwritten`/`isDigitalTouch`
  (balloon ids) + sticker-only/embedded-media → **transparent bubble**
  (`stripBubble` in `_MessageBubble`). New l10n: `chat.location`/`openInMaps`/
  `handwritten`/`digitalTouch`.
- **Voice send (shipped)**: `record: ^6.1.1` + `RECORD_AUDIO` + **minSdk→23**
  (record 6 needs API 23; `maxOf(flutter.minSdkVersion, 23)`). `voice_recorder.dart`
  records AAC/m4a to a temp file; the composer's voice button records, a
  `_VoiceRecordingBar` (timer + Cancel/Send) replaces the input, Send → existing
  `sendAttachments`. No server change (send-attachment already sends audio).
  **Needs device verification** (mic capture + delivery can't be tested in CI).
  Note: `record 5.x` had a broken transitive set (`record_linux 0.7.2` predates the
  interface it pulls) — must use record 6.x+.
- Fixed a pre-existing `test/widget_test.dart` compile error (fake `SecureStore`
  was missing `deleteValue`).
- Requires rebuilding the bundled backend for the server classification.

## Sync Control "Server returned HTTP 500" header (C36)

- **Page loads fine, but a stale "Server returned HTTP 500." stays in the Sync
  Control header.** `model.lastError` is a global catch-all, and the 3s background
  poll (`AppModel.refresh`) set `lastError` from its best-effort diagnostic fetches
  (`status`/`connections`/`devices`/`urls`). `lastError` is displayed in exactly
  ONE place — the Sync Control header (`SyncControlView.swift:25`) — so any poll
  500 (typically a **stale v0.26 bundled backend** on real data) showed up there.
  Fixed (client-side, robust to any endpoint): the poll now records diagnostic
  failures in `lastPollError` (Debug/Copy-diagnostics only) and clears `lastError`
  once reachable + authed; token-rejected + failed user actions still set
  `lastError`. Server endpoints themselves are robust (all 200 live). Rebuilding
  the backend to v0.30 removes the underlying 500 too. Companion change only —
  rebuild the Companion.

## Menu-bar "Open Dashboard" looked different (C35)

- **Dock/normal launch looked native; opening from the menu bar gave a different
  titlebar/toolbar (title shown in titlebar, controls collapsed).** Two window
  paths: the Dock/normal path uses the SwiftUI **`WindowGroup`** (`openWindow(id:)`),
  but the AppKit `NSStatusItem` menu (`MenuBarStatusItemController.openDashboard`)
  called `presentDashboardFromAppKit()` → a **hand-rolled `NSWindow`**
  (`DashboardWindowPresenter`) hosting `ContentView` in `NSHostingView`, which
  doesn't get SwiftUI's WindowGroup toolbar/titlebar treatment. Fixed: ContentView
  stores its `openWindow` action in `DashboardWindowOpener.shared` on appear, and
  `presentDashboardFromAppKit()` now (1) fronts an existing window, else (2)
  reopens the **same WindowGroup window** via that action; the hand-rolled NSWindow
  is only a last-resort fallback (launched-hidden-and-never-shown). Requires
  rebuilding the Companion. (Can't visually verify here — confirm the menu-bar
  window now matches the Dock one.)

## Link-preview "small files" above a URL (C34)

- **Sending/receiving a link showed 2–4 tiny "file" cards above it, but the
  server debug view didn't.** Apple marks a rich link's internal preview parts
  (site thumbnail, favicon, LinkPresentation payload) with **`hide_attachment=1`**.
  The messages API's `loadAttachmentsByMessageGUID` (`internal/relaydb/query.go`)
  never read or filtered `hide_attachment` — it only skipped no-MIME payloads via
  `IsAttachmentPreviewPayload` — so the thumbnail/icon (which have real `image/*`
  MIME) leaked to the client. Fixed: select `hide_attachment` and skip rows where
  it's set (matches the debug view + BlueBubbles, which exclude hidden
  attachments). Verified live (a `https://…` message returns only the real photo)
  + regression test `TestListChatMessagesExcludesHiddenAttachments`. **Requires
  rebuilding the bundled backend.**

## Sync Control timeout (C33)

- **"chats — The request timed out" / sporadic HTTP 500 with a healthy server:**
  relay.db had **no indexes**, so `ListChats` (`internal/relaydb/query.go`) ran its
  7 correlated per-chat subqueries as full scans of `messages` — O(chats × messages)
  — and blew past the Companion's **4s** request timeout on a real DB. Fixed:
  added `idx_messages_chat_date`/`idx_messages_source_rowid`/`idx_messages_date_created`/
  `idx_attachments_message_guid` in `internal/relaydb/migrations.go` (verified the
  planner now does `SEARCH … USING INDEX idx_messages_chat_date`); bumped the
  Companion request/resource timeout 4s→20s (`Services/APIClient.swift`); and
  `loadSyncControl` now clears the stale `lastError` so a leftover "HTTP 500"
  header no longer contradicts the timeout card. **Requires rebuilding the bundled
  backend** (indexes created on next start, migrations idempotent).
- **FCM self-test + remote push:** [docs/notifications-setup.md](docs/notifications-setup.md)
  has a step-by-step "Test FCM push end-to-end yourself";
  [docs/remote-access-cloudflare.md](docs/remote-access-cloudflare.md) explains push
  over the tunnel (push is Google→device; the tunnel is for the follow-up delta sync
  when off-LAN).

## Companion + server views (C32)

- **Root cause of "Sync Control 500" + "Paired Devices broken":** the chat.db
  sync reader scanned the flag columns (`is_from_me`/`is_read`/`is_delivered`/
  `cache_has_attachments`) into a plain `int64`; real chat.db stores these as
  **NULL** on many rows → `converting NULL to int64 is unsupported` → the
  **startup sync failed → `app.Run` returned the error → `log.Fatal` → the server
  never served.** Fixed: scan into `sql.NullInt64` (NULL→false) at both sites in
  `internal/store/queries.go`, plus made the **startup sync non-fatal**
  (`internal/app/app.go` — log + record `lastSyncError`, keep serving cached
  relay.db). Both endpoints' chains are otherwise correct (verified live: register
  → `/api/devices` → Companion decode all return 200). Regression test:
  `internal/store/queries_nullflags_test.go`.
- **Reproduce live:** `go build -o /tmp/micago ./cmd/micago`; run with
  `HOME=<tmp>` + a SQLite `chat.db` carrying the chat.db schema (see the store
  test DDL) — empty/0-byte chat.db aborts startup; a NULL `is_read` row used to.
- **Companion sidebar (`ContentView.swift`):** native `NavigationSplitView` with
  `.listStyle(.sidebar)`; **Settings + Debug + Log pinned at the bottom** via
  `.safeAreaInset(edge: .bottom)` (second sidebar List sharing `nav.selection`).
  "Advanced" relabeled **Settings** (`gearshape`). No fake title bars/traffic
  lights exist (window uses a real `.titled` styleMask); toolbar controls already
  trailing (`.primaryAction`).

## Chat UX (C32) — app renamed micaGO

- **Notifications are Android MessagingStyle**, grouped/stacked **per chat**
  (`notificationIdForChat`), with contact name + avatar. A small per-chat preview
  buffer (`notification_store.dart`, secure storage, cross-isolate) drives the
  stacking, dedups by message guid, and is cleared on chat open
  (`cancelChatNotification` via `requestOpenChat`). Avatar = on-device contact
  photo (keep-alive path, temp bitmap file) else monogram. **Reply action removed
  this pass.**
- **Stickers:** `AttachmentView` routes `isStickerLike` to `_StickerAttachment`
  first → renders the image, else a clean `_StickerPlaceholder` ("Sticker" chip),
  never a broken file card.
- **Media viewers** (`media_viewer.dart`): images get animated double-tap zoom;
  video gets play/pause/replay + time labels + show/hide controls.

## Notification path (C31)

- Three layers, each optional/fallback: **FCM push** (user-owned Firebase, wake-only) → **keep-alive** foreground service (local notifications, no Firebase) → **delta catch-up** (silent, never lost). See [docs/notifications-setup.md](docs/notifications-setup.md).
- **One presenter:** `lib/core/network/notification_display.dart` defines the channel/group/reply-action and `notificationIdForMessage` (a deterministic FNV-1a hash — **not** `String.hashCode`, which isn't stable across the FCM background isolate vs the main isolate). FCM and keep-alive notifications for the same message share this id → collapse into one (cross-path dedup).
- **Title = who, body = what.** Title resolution: on-device contact name (keep-alive/main isolate only) → server sender/title → raw handle → generic; never a GUID/empty (`messageNotificationTitle` in `push_logic.dart`). The server FCM payload now carries `handle`; `buildNotification` (`internal/notify/dispatcher.go`) sets title=sender, body=text only in `sender_and_text`.
- **Keep-alive notifications** come from `AppController._maybeNotifyBackgroundMessage` (fires on `message:new` only when backgrounded + keep-alive on). Local notifications now init **independently of Firebase** (`PushService._ensureLocalNotifications`).
- Diagnostics in Settings → Notifications: permission (Android 13+), last notification source, last reply result; copyable.

## Changed in this pass (Companion UI/state, C30)

1. **Menu-bar icon** (`MicaGoCompanionApp.swift`): `mica.error` for hard-failure states (not installed, crashed/unreachable); normal `mica` dimmed for inactive/transitional (stopped/starting/stopping); full-strength active for running/external. Template-rendered, no hard-coded colors.
2. **Menu-bar dropdown** (`MenuBarContent.swift`): removed the `LAN:`, `Public:`, and `Messages.app is running` rows. Kept Open Dashboard / Start / Stop (correct enabled state) / Keep Awake / Quit.
3. **Contacts permission** (`SyncControlView.swift`, `ContactsService.swift`): replaced the misleading disabled "Allow Contacts access" button with **Open System Settings** (`ContactsStore.openSystemSettings()`) + guidance that names/photos need permission while raw handles still work.
4. **Sync Control HTTP 500** path: investigated — all four handlers are correct and wired in source (`internal/httpapi`); a live 500 is environmental (commonly a stale binary; rebuild). Made the client resilient: per-endpoint loading (`AppModel.loadSyncControl`) so one failure doesn't blank the page and the error names which call failed; the client now surfaces the server's `{error:{code,message}}` body (`APIClient.validate(_:body:)`) instead of a bare status; and a proper **error card with Retry + Copy diagnostics** (`SyncControlErrorCard`) replaces the small inline line.
