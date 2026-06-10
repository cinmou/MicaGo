# C7 — BlueBubbles / Mategram client store architecture audit

Read-only study of the reference apps to guide MicaGo's client rewrite. We port
**concepts**, not code.

## Files inspected

### BlueBubbles client (`Ref/bluebubbles-app-master`)
- `lib/database/global/chat_messages.dart` — the per-chat in-memory store
  (`ChatMessages`): `Map<String,Message> _messages`, `_reactions`,
  `_attachments`, `_threads`, `_edits`; `addMessages`, `getMessage`,
  `removeMessage`, `addThreadOriginator`.
- `lib/services/ui/message/messages_service.dart` — per-chat `MessagesService`
  (GetxController) wrapping a `ChatMessages struct`; `addMessage`,
  `updateMessage(updated, oldGuid)`, `removeMessage`, `loadNextChunk`.
- `lib/services/backend/action_handler.dart` — `handleNewMessage`,
  `handleUpdatedMessage`, and `replaceMessage(tempGuid, replacement)` (optimistic
  reconciliation).
- `lib/services/network/socket_service.dart` — socket wiring: `new-message`,
  `updated-message`, `chat-read-status-changed`, group events → `action_handler`.
- `lib/services/ui/chat/conversation_view_controller.dart`,
  `lib/services/backend/queue/{outgoing,incoming}_queue.dart` — send queue.

### Mategram (`Ref/Mategram-main`, Jetpack Compose/TDLib)
- `mategram/domain/.../ChatList*.kt`, `MessageSourceChatList.kt` — chat-list as a
  sorted, incrementally-updated collection (TDLib pushes deltas, not reloads).
- Compose `LazyColumn` message list + paging — lightweight row composables,
  stable keys, media separated from row layout.

## Answers

**1. Does BlueBubbles keep a local client-side message store?**
Yes. Two layers: a persistent ObjectBox DB and a per-chat **in-memory**
`ChatMessages` struct (keyed maps) that the conversation UI actually renders
from. Messages, reactions, attachments, thread-originators and edits are kept in
separate maps.

**2. How does it reconcile socket events into local state?**
`socket.on("new-message"/"updated-message")` → `action_handler.handleEvent` →
`handleNewMessage`/`handleUpdatedMessage`. It looks up an existing row by guid
(`Message.findOne`), and if found routes to *update* (patch in place) instead of
inserting a duplicate. The in-memory `MessagesService.struct` is patched via
`addMessage`/`updateMessage`/`removeMessage` — never a whole-thread reload.

**3. How does it replace optimistic outgoing messages?**
The optimistic row is created with a **temp guid** (`generateTempGuid`). When the
server row arrives, `replaceMessage(existingGuid /*temp*/, replacement)` swaps it
in place — same list position, new guid — and deletes the temp entry. So there is
never both a temp bubble and a confirmed bubble for one send.

**4. How does it update delivered/read/edited/unsent state?**
Via `updated-message` (and `chat-read-status-changed`): `handleUpdatedMessage`
finds the row by guid and patches `dateDelivered`/`dateRead`/`dateEdited`/
`dateRetracted`/`error`. Edits and retractions keep the same guid; retraction
clears displayed content.

**5. How does it avoid reloading entire threads?**
All event handling patches the keyed in-memory struct by guid. Full fetches only
happen on first open and on explicit pagination (`loadNextChunk` with
offset/limit). Reactions/threads are merged into existing rows, not re-fetched.

**6. How does it filter or hide system/noise rows?**
Reactions are stored in a **separate** `_reactions` map and merged onto their
target's `associatedMessages` — they are not standalone bubbles. `itemType`/group
events render as system lines. The renderable message list is derived from
`_messages` (excluding the reaction map).

**7. How does its thread UI avoid expensive rebuilds?**
The list renders from the in-memory maps via a reactive controller; only changed
rows rebuild. Classification/association is computed when a message enters the
struct, not inside the scroll item builder.

**8. What structure should MicaGo port conceptually?**
- A **MessageStore** keyed by guid (+ separate reaction handling), patched by WS
  events; dedupe by guid and reconcile optimistic rows by tempGuid.
- A **PendingSendStore** for optimistic rows with explicit send states; reconcile
  against later server rows / `send:match` instead of showing duplicates.
- A **ChatStore** of summaries patched by events (no full reload per event).
- **Precompute** classification/labels/associations once (a
  `ThreadPresentationBuilder`) so the scroll item builder stays trivial.
- Keep raw/debug rows out of the default renderable timeline (server-side
  `isDebugOnly`), mirroring BB's reaction/system separation.

### What MicaGo will NOT copy
- ObjectBox persistence (MicaGo stays in-memory over REST+WS for now).
- GetX; we use `ChangeNotifier`/provider + pure store classes.
- TDLib data model.
