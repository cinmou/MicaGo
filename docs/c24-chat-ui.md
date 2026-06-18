# C24 — Chat UI polish: route labels, bottom emoji panel, big emoji, media viewer

Flutter-client chat experience only. No server, sync, Firebase, pairing, or
Companion changes (one new client dependency: `video_player`). Patterns adapted
from the BlueBubbles Flutter client where it had a clean approach.

## 1. Route selector shows the address, not just the service
The thread top-right route switcher now includes the concrete **handle/address**
so multiple routes on the **same** service (e.g. two iMessage chats) are
distinguishable.

- New pure helper `route_label.dart`:
  - `routeLabel(route, {name})` → `"iMessage · +447700900123"`,
    `"iMessage · a@icloud.com"`, `"SMS · +8618000000000"`, or
    `"iMessage · Alice (+447700900123)"` when a contact name adds info.
  - `routeHandle(route)`, `routeSendabilityLabel(route, allowSmsSend:)`.
- The compact toolbar button shows `service · handle` capped at 180px with an
  ellipsis. The popup menu shows, per route: **service**, **handle**,
  **sendability** ("Can send" / "Read only"), and the **active** radio marker.
- Sendability stays **server-authoritative** (`ChatSummary.canSendText`), never
  inferred from the handle shape.
- Tests: `route_label_test.dart` — two iMessage routes with different handles
  produce different labels; the active label includes service + handle; name is
  appended (and not duplicated when equal to the handle); sendability uses the
  server capability.

## 2. Emoji panel slides up from the bottom
The emoji panel is now a **bottom panel** below the composer (like the keyboard
/ attachment panel), not an awkward strip above the input.

- Tap the emoji button → the panel slides up (`AnimatedSize`) and the keyboard is
  dismissed; tap again, or tap into the text field, → it closes.
- The emoji panel and the attachment panel are **mutually exclusive** (opening one
  closes the other), and panel state is owned by the thread screen so both sit at
  the bottom.
- The emoji button stays visible while the panel is open (`showEmoji =
  focused || emojiOpen`), so it's reachable after the keyboard is gone.
- New `EmojiPanel` widget: rounded top corners, theme-aware
  (`surfaceContainerHigh`), **category tabs** (Smileys / Gestures / Hearts /
  Animals / Food / Activities / Symbols), a **Recent** tab backed by an in-memory
  MRU list, a much larger curated set, and a width-reflowing `GridView.extent`
  (works narrow + wide, dark + light). No new dependency — a curated built-in list.
- Insertion happens at the caret in the composer's controller (preserved from the
  prior inline picker); picks are remembered as recents.

## 3/4. Emoji-only messages render bigger
Adapted BlueBubbles' `shouldShowBigEmoji`. New pure `emoji_text.dart`:
`isEmojiOnly`, `emojiCount`, `isBigEmoji` (emoji-only with ≤3 emoji), and
`bigEmojiFontSize` (48/40/34 by count). A big-emoji bubble drops the colored
container and renders the emoji large; **mixed text + emoji stays a normal text
bubble**. Status, timestamp, reactions, edited/unsent rendering are untouched
(big-emoji is skipped when there's media or a reply). Tests: `emoji_text_test.dart`.

## 5. Media viewer (image + video)
MicaGo already had a strong image viewer (`MediaGalleryViewer`: full-screen,
swipe between images, `InteractiveViewer` zoom/pan, loading/error/retry). C24:

- The viewer top bar now shows the **file name** (alongside the page counter).
- **Video** attachments are now tappable → a new `FullscreenVideo` player
  (`video_player`): streams with the bearer token in the `Authorization` header
  (never in the URL), play/pause on tap, scrubbable progress, looping, and a
  graceful **error state with retry** — never a blank/broken viewer.
- Video renders in the list as a lightweight tappable **card** (play badge +
  name/size); the player is only created on demand in the viewer (low memory).
- Unsupported files keep their existing **file card** (no broken viewer); images
  and stickers open in the same image viewer as before. Existing
  download/rendering paths and the shared `imageByteCache` are unchanged.

## Tests
- `route_label_test.dart`, `emoji_text_test.dart`, `chat_media_widgets_test.dart`
  (EmojiPanel renders + tap inserts + Recent tab; video renders a tappable card;
  unsupported file renders a file card without crashing). Existing attachment-send,
  merged-chat, composer, and thread tests still pass.

## Validation
| Check | Result |
| --- | --- |
| Route selector shows distinguishable handles for two iMessage routes | ✅ |
| Active route label includes service + handle | ✅ |
| Emoji panel opens from the bottom, mutually exclusive with attachments | ✅ |
| Emoji insertion works at the cursor; composer paste/send unaffected | ✅ |
| Emoji-only renders big; mixed text stays normal | ✅ |
| Image tap opens the viewer; video tap opens the player | ✅ |
| Unsupported file tap does not crash (file card) | ✅ |
| `flutter analyze lib test` clean / `flutter test` (264) | ✅ |
| `flutter build apk --debug` (with `video_player`) | ✅ |

Scope note: no backend/sync/Firebase/connection/Companion files were touched, so
no `go test` was required.
