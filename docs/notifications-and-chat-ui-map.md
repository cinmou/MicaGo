# Android stability, notifications, and chat-UI map

Reference for testing the Android client, the BlueBubbles notification gap
analysis, and the chat-UI file map for later polish. (C30)

## 1. Android stability audit

Status of the common failure modes, with where each is handled. Most were
hardened in earlier cycles (see `CHANGELOG.md`); this pass re-confirmed them.

| Area | Status | Where / notes |
| --- | --- | --- |
| Reconnect loop / backoff | OK | `RefreshCoordinator` (reconnect + fallback poll). Single owner; no competing timers. |
| Stuck "Reconnecting…" while connected | Fixed | `AppController.connectionHealthy` clears the sticky banner on the `connecting→connected` edge (`ConnectionNoticeHost`). |
| First-connect never resolves | Fixed | 10s watchdog → clear "can't reach server" dialog with Retry; cleared on success; background reconnects don't arm it. |
| Device registration | Fixed | Registers on **REST** candidate selection *and* WS connect, via a dedicated short-lived client (immune to `_rebuildApi()` close-race), retried 3×, logged both sides. Idempotent by stable device id. |
| Keep-alive foreground service | OK | `KeepAliveService` (Android, `dataSync` type), opt-in, default off, persisted (`micago.keepalive.v1`), restored on bootstrap. |
| Firebase optional path | OK | `PushService.start()` no-ops when `/api/fcm/client` reports unconfigured → app stays on WS + delta. |
| Notification permission | OK (FCM path) | `FirebaseMessaging.requestPermission()` requests POST_NOTIFICATIONS on first run when Firebase is configured. **Residual:** with keep-alive on but permission denied on Android 13+, the persistent notification may be hidden though the service still runs. |
| Background/foreground lifecycle | OK | `home_screen.didChangeAppLifecycleState` → `onResume()` → refresh-coordinator resume + push start. |
| Resume delta catch-up | OK | `onResume` → `catchUp`; WS connect → `_handleWebSocketReconnect` → `catchUp`. |
| Notification tap routing | OK | `onMessageOpenedApp` / `getInitialMessage` / local-notif payload → `requestOpenChat(chatGuid)` → `pendingOpenChat` → Chats tab opens the thread. |
| Duplicate foreground notifications | OK | `pushShouldCatchUp`: when the socket is connected the FCM message is ignored (no duplicate); local notifications are only shown from the background isolate. |

No new always-on logging was added; registration/connection already log to the
in-app connection log (Debug → realtime events) and the backend stdout. The only
additions this cycle are the (debug-guarded) `debugPrint`s already present.

## 2. BlueBubbles notification gap table

BlueBubbles builds notifications **natively in Kotlin**
(`CreateIncomingMessageNotification.kt`); MicaGo builds them in Dart via
`flutter_local_notifications`. Behavior compared:

| Behavior | BlueBubbles | MicaGo (now) | Decision |
| --- | --- | --- | --- |
| When to send push | Server pushes on new message; client treats it as a wake | Same (server FCM provider; wake-only) | — |
| Foreground vs background | FG handled by socket; BG shows a notification | Same (FG = socket dedup, BG = local notification) | — |
| Deduplication | Skip if socket already delivered | Same (`pushShouldCatchUp`) | — |
| Grouped notifications | Group key + group summary + `GROUP_ALERT_CHILDREN` | **Group key added (C30)** | **Ported (group key).** Summary notification deferred (low value for a wake signal). |
| Notification title/body | Sender name + message preview | Cleaned title/body helpers (C30) | **Ported.** |
| Channel importance | High-importance channel | High-importance channel | — |
| Tap → open chat | Opens the conversation | Same | — |
| Direct / inline reply | `RemoteInput` "Reply" action → native send | **Added (C30):** RemoteInput action → backend `sendText` via persisted profile (works from the background isolate) | **Ported (lightweight).** |
| Contact avatar in notification | `Person` + `contact_avatar` bitmap (MessagingStyle) | App icon only | **Defer.** Needs the contact photo plumbed into the (background) isolate; heavier and permission-dependent. |
| Mark read from notification | "Mark read" action → marks read on the Mac | Not supported | **Defer.** MicaGo's read path is one-directional; there is no server "mark read" endpoint (would need IMCore mark-read). |
| Conversation bubbles | `BubbleMetadata` | Not supported | **Defer.** Niche; heavier. |
| Foreground-service keep-alive | Opt-in `keepAlive` socket service | Opt-in `KeepAliveService` | Parity (already present). |

## 3. Notification improvements shipped (C30)

In `lib/core/network/push_service.dart` + `push_logic.dart`, no new dependencies:

- **Grouping:** message notifications share `groupKey: micago.messages` so the OS
  bundles them.
- **Title/body formatting:** pure `notificationTitle` / `notificationBody` helpers
  (tested) — sender name as title, preview as body, sensible fallbacks.
- **Direct reply:** an Android `RemoteInput` "Reply" action. The reply is sent by
  `sendNotificationReply` — it loads the persisted `ConnectionProfile` from
  secure storage and POSTs to `/api/chats/{guid}/send` (reusing the existing
  bearer token + send API), so it works even from the background isolate with no
  live `AppController`. Registered for both the foreground and background isolates.
- **Tap-opens-chat** and **dedup** unchanged (already correct).
- Firebase and keep-alive remain optional and off by default.

Deferred (documented above): contact avatar, mark-read, bubbles, group summary.

## 4. Chat UI code map (for later polish — not redesigned here)

All under `MicaGoFlutterClient/lib/`:

| UI element | File · widget |
| --- | --- |
| Chat list (screen) | `features/chats/chat_list_screen.dart` · `ChatListScreen` |
| Chat list (data/state) | `features/chats/chat_list_controller.dart`; rows use `features/chats/avatar.dart`, `route_label.dart` |
| Chats pane (large-screen layout) | `features/chats/chats_pane.dart` |
| Thread screen | `features/chats/message_thread_screen.dart` · `MessageThreadScreen` |
| Thread state / presentation | `features/chats/thread_controller.dart`, `store/thread_presentation.dart`, `store/message_collection.dart` |
| Message bubble | `message_thread_screen.dart` · `_MessageBubble` / `_MessageBubbleState` (also `_SystemRow`, `_Footer`, `_DateSeparator`) |
| Reaction chips / reply preview | `message_thread_screen.dart` · `_ReactionChips`, `_ReplyPreviewBlock` |
| Message classification / render rules | `features/chats/message_render.dart`, `message_display.dart` |
| Image / media rendering (inline) | `features/chats/attachment_views.dart` · `AttachmentView`, `_ImageAttachment`, `_VideoAttachment`, `_AudioAttachment`, `_FileAttachment`, `_PreviewUnavailableAttachment` |
| Full-screen media viewer | `features/chats/media_viewer.dart` · `MediaGalleryViewer`, `_ZoomableImage`, `FullscreenVideo` |
| Attachment picker / preview strip | `features/chats/attachment_panel.dart` · `AttachmentPanel`, `_MediaTile`, `StagedAttachmentStrip` |
| Input bar / composer | `message_thread_screen.dart` · `_Composer` / `_ComposerState` |
| Emoji panel | `message_thread_screen.dart` · `EmojiPanel`; glyph helper `features/chats/emoji_text.dart` |
| Long-press action menu | `message_thread_screen.dart` · `showMessageActionMenu` (Copy / Message Info / Edit / Unsend / Delete) |
| Message info / debug sheet | `features/chats/message_debug_sheet.dart` |
| Per-chat send route label | `features/chats/route_label.dart` · `routeLabel` |
| Server route selector (LAN/Public) | `features/settings/settings_screen.dart` · `_RouteSwitcher` |
| Notification-tap navigation | `core/app_controller.dart` `requestOpenChat`/`pendingOpenChat` → `features/home/home_screen.dart` `_onOpenChatRequested` → `features/chats/chat_list_screen.dart` (opens the thread) |

**Safe places for later UI polish** (self-contained widgets, low blast radius):
`_MessageBubble`, `attachment_views.dart`, `media_viewer.dart`, `EmojiPanel`,
`_Composer`, `avatar.dart`, and `chat_list_screen.dart` rows. Cross-cutting
logic (`message_render.dart`, `thread_presentation.dart`) is well-tested — change
with care and re-run the message-render/semantics tests.

## 5. Validation

- `flutter analyze` — clean.
- `flutter test` — passes (incl. new C30 notification-formatting/reply tests).
- `flutter build apk --debug` — builds.
- Go: backend send/notification APIs were **not** changed this cycle (the client
  reuses the existing `/api/chats/{guid}/send`), so no Go changes; `go test` is
  unaffected.

### Manual test checklist

- [ ] No Firebase configured → app works on WS + delta; no crashes.
- [ ] Firebase configured → token registers; Paired Devices shows the device.
- [ ] Keep-alive off → no persistent notification.
- [ ] Keep-alive on → persistent notification; survives app restart.
- [ ] Foreground message → no duplicate notification (socket delivered it).
- [ ] Background message → grouped notification with a Reply action.
- [ ] Killed-app push → best-effort notification (needs runtime options/keep-alive).
- [ ] Notification tap → opens the correct chat.
- [ ] Direct reply from the notification → message sends to that chat.
- [ ] Paired Devices shows the Android device with correct push/background status.
