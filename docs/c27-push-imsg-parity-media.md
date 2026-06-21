# C27 — Push completion, imsg parity audit, chat-media polish

Three independent workstreams. Builds on the C22 push foundation and the C26
connection/helper work.

## 1 — Push chain: audited end-to-end, finished the client gaps

The FCM chain was already wired; the audit found the **server side complete** and
two **client gaps** (no test-push trigger, no status surfaced). Both are now done.

| Link | State before | Now |
| --- | --- | --- |
| Config (user-owned Firebase) | `GET /api/fcm/client` serves parsed `google-services.json`; `PushService` inits Firebase at runtime | ✅ unchanged |
| Token registration | `PushService` → `updatePushRegistration` → device upsert with `pushProvider/pushToken/pushEnabled`; re-runs on `onTokenRefresh` | ✅ unchanged |
| Device capability/status | reported to server, but **not shown in-app** | ✅ new Settings → **Notifications** card shows enabled/provider, or the optional-setup hint |
| Foreground behaviour | dedup: socket-connected push ignored; socket-down → delta catch-up | ✅ unchanged |
| Background/terminated | data-only FCM message → background isolate → local notification; fetch via resume catch-up | ✅ unchanged |
| Test push | server `POST /api/devices/{id}/test-push` existed; **no client trigger** | ✅ `ApiClient.sendTestPush` + `AppController.sendTestPush` + a "Send test notification" button (only when push is configured) |
| Tap opens the right chat | `onMessageOpenedApp` / `getInitialMessage` / local-notif payload → `requestOpenChat(chatGuid)` after a delta sync | ✅ unchanged |
| Duplicate prevention | socket-connected dedup; notification id = `messageGuid.hashCode`; stable device id upsert (no dup rows); server skips `isFromMe` | ✅ unchanged |

**Server payload** is data-only (`type/messageGuid/chatGuid/title/body/previewMode/
createdAt`), preview-gated, truncated to 1500 chars, prunes `UNREGISTERED`
tokens, `high` priority + TTL. No contacts/tokens/history leave the Mac.

**Audit finding, not implemented (deliberate):** in the foreground MicaGo does not
raise a heads-up notification for a message in a *non-active* chat — the socket
already delivered it to the list, just without a banner. BlueBubbles drives that
from an in-app notification service on socket events (not FCM). Flagged for a
future cycle; it is in-app UX, not a push-chain gap.

## 2 — imsg parity audit

Scanned `Ref/imsg` (`BridgeAction` verbs + the `IMsgCore` read side). MicaGo is
intentionally **chat.db read + AppleScript/helper write**; most write/mutate verbs
in imsg require the private-API injection dylib (`IMsgHelper`), which MicaGo does
not bundle. Legend: ✅ implemented · ◑ partial · ✗ missing · ⚠️ private API.

| imsg feature | MicaGo | Risk | Recommended priority |
| --- | --- | --- | --- |
| List chats / chat metadata | ✅ | safe | — |
| Message history (chat.db + lookback) | ✅ | safe | — |
| Realtime watch (new/updated messages) | ✅ (WS + delta) | safe | — |
| Attachments read / download / preview | ✅ | safe | — |
| Reactions/tapbacks — **render** | ✅ | safe | — |
| Replies, effects, stickers — render | ✅ | safe | — |
| Contacts resolve (names) | ✅ (client-side) | safe | — |
| Send text | ✅ | safe (AppleScript) | — |
| Send attachment | ✅ | safe | — |
| Send multipart (multi-attachment) | ◑ (panel multi-send) | safe | Low |
| Edit / Unsend / Delete | ◑ wired + capability-gated; helper binary not shipped | ⚠️ IMCore | **High — finish the helper** |
| Send reaction (tapback) | ✗ | ⚠️ IMCore | **High** (big UX win, well-understood codes) |
| URL previews — render | ✗ | safe (typedstream decode) | **Medium** (read-only, no private API) |
| Polls — render | ✗ | safe (decode) | Medium (read-only) |
| Mark chat read / unread | ✗ (we show read state, can't set it) | ⚠️ IMCore | Medium |
| Typing indicators (start/stop/check) | ✗ | ⚠️ IMCore | Low (noisy, fragile) |
| Search messages (server-side) | ◑ (client-side filter only) | safe | Medium |
| Group: add/remove participant | ✗ | ⚠️ IMCore | Low |
| Group: rename / set photo / leave | ✗ | ⚠️ IMCore | Low |
| Create chat / delete chat | ✗ | ⚠️ IMCore | Low |
| Account / nickname / iMessage-availability info | ✗ | ⚠️ IMCore | Low |
| Download purged attachment | ✗ | ⚠️ IMCore | Low |
| notify-anyways | ✗ | ⚠️ IMCore | Skip |

**Decision:** don't migrate blindly. The worthwhile near-term items are the
**read-only** decoders (URL previews, polls) — they need no private API — and
finishing the already-wired **edit/unsend/delete** + adding **send-reaction**,
both of which ride the single IMCore helper MicaGo already gates on. Group
management, typing, and account introspection are low-value/high-risk private-API
surface and are explicitly **not** recommended.

## 3 — Chat media polish (clean image bubbles)

Compared to BlueBubbles, MicaGo wrapped image-only messages in the colored chat
bubble, so a photo looked like a card inside a bubble.

- A **media-only** message (renderable images/stickers, no body text, no reply)
  now renders with **no bubble** — transparent background, zero padding — so the
  photo shows as a clean rounded media card (the image already clips its own
  corners + bounds its decode). Matches `bigEmoji`'s existing bubble-less path.
- **Text bubbles are unchanged**; a message with both media *and* text keeps the
  normal bubble (media on top, text below).
- **Broken cards avoided:** the clean-media path requires every attachment to be
  inline-renderable, so a TIFF-needing-conversion or a failed load keeps its
  labeled card inside a bubble rather than a bare broken tile; unrecoverable
  placeholders (`missing_attachment_rows` / `empty_edited_residue`) still render
  as an unsent row (C26b), never a file card.

## Validation

| Check | Result |
| --- | --- |
| `flutter analyze lib test` | ✅ No issues |
| `flutter test` | ✅ |
| debug APK | ✅ |
| Go build + tests | ✅ (pre-existing `TestSendAttachmentSMSGate` env-only failure, see C26b) |
| Companion `xcodebuild` | ✅ |

No new dependencies added.
