# C19 — Client usability (attachments, connection notices, device visibility, version fix)

Fills missing client usability behavior without redesigning. Five goals.

## 1. Attachment sending (iMessage)

**Audit:** the server had no attachment-send endpoint — only `SendText`
(AppleScript `send … to chat`) and attachment *download*. So a minimal endpoint
was added; no new protocol was invented for an existing capability because none
existed.

**Server** (`internal/send`, `internal/httpapi`):
- `AppleScriptSender.SendAttachment` → `send (POSIX file "<path>") to chat id …`.
- `POST /api/chats/{guid}/send-attachment` — multipart (`file`, optional
  `tempGuid`). Gated to iMessage (`ServiceName == "iMessage"`), same as text;
  SMS/RCS/unknown are rejected `400`. Saves the upload to
  `<attachmentsRoot>/outgoing/<rand>-<name>` (0600), runs AppleScript, removes
  the temp file. Confirmation is optimistic (no text to match): a successful
  osascript replies `202` and the real row arrives via the normal sync/WS path.
  100 MiB cap.

**Client** (`file_picker` dep):
- `ApiClient.sendAttachment` — `MultipartRequest` to the new route.
- `ThreadController.sendAttachment` — transient `attachmentSending` / error
  state, **no** optimistic bubble (the server can't reconcile an attachment by
  content, so a bubble would duplicate the real row). Triggers a catch-up sync.
- Composer attach button: enabled only when the chat is sendable
  (`ChatService.canSend` → iMessage, including phone-number/`any;-;` iMessage
  chats). Read-only chats hide the composer entirely (existing C-prev behavior),
  so attachments are impossible there. A spinner shows while sending; failures
  raise a snackbar.

## 2. Connection status notifications

`lib/core/network/connection_notice.dart` — a pure `connectionNoticeFor(prev,
current)` over `(WsStatus, activeKind, serverReachable)`. Emits only on
transitions (no noisy repeats): connected, reconnecting, disconnected, server
unavailable, switched-to-public, switched-to-lan, websocket-lost,
websocket-recovered. `AppController` feeds snapshots from the WS listener and
`selectReachableCandidate` (the LAN↔Public fallback) into a one-shot
`ValueNotifier<ConnectionNotice?>`. `ConnectionNoticeHost` (mounted in the home
shell) shows a sticky error banner for problem states (offline / public
fallback) and a 2s snackbar for recoveries, then clears the one-shot.

## 3. Connected-device visibility

**Audit:** the WS hub tracked only a connection *count*
(`map[*websocket.Conn]`); device identity lived in the separate
`/api/devices/register` + `GET /api/devices`, which the Companion already
renders (Paired Devices card) alongside the live WS client count in the Status
card. The gap was that the Flutter client never registered.

- Flutter now registers on WS connect (`AppController._registerDeviceIfPossible`)
  via the existing endpoint with a **small** identity (`device_identity.dart`):
  name + app version, platform (mapped to the server's accepted set),
  `clientType: flutter`. No contacts/tokens/message data. The server device id
  is persisted in the cache and reused so reconnects refresh the same record
  (no duplicates). Stale clients drop from the live WS count on close.
- Companion: stale empty-state text updated ("a device appears here when a
  MicaGo client connects and registers").

## 4. Version display (`vv0.15.0`)

The server's version string already carries a leading `v` (`v0.15.0`), and the
Companion Dashboard rendered `Text("v\(s.version)…")` → `vv0.15.0`.
`Services/VersionFormat.swift` `displayVersion(_:)` collapses any leading `v`/`V`
run to exactly one and is used at both version display sites. The Flutter client
displays no server version, so no change there.

## 5. Cleanup

- One sendability source (`ChatService.canSend`) drives both text and attachment
  gating — no parallel checks.
- One WebSocket state source (`WsStatus`); the notice layer derives from it
  rather than duplicating it.
- One version-formatting helper.
- No new debug panels; C18 layout untouched.

## Build note

`file_picker` pulls a `flutter_plugin_android_lifecycle` that requires
compileSdk 36; the app `compileSdk` was bumped to 36 (compile-time only — minSdk
/ targetSdk unchanged, the Gradle-recommended safe action) and the lifecycle
plugin is pinned to its android-34 build via `dependency_overrides` to keep
file_picker's own AAR metadata consistent.

## Validation

| Check | Result |
| --- | --- |
| Text send still works | ✅ unchanged path |
| Attachment send (iMessage, incl. phone-number) | ✅ endpoint + composer; `send_attachment_test.go`, `attachment_send_test.dart` |
| Attachment disabled for SMS/Unknown | ✅ server 400 + client gate; tests |
| Server-off → disconnected/unavailable, restore → recovered | ✅ `connection_notice_test.dart` state machine |
| LAN failure → Public fallback notice | ✅ `switchedToPublic`; test |
| Companion shows a connected client | ✅ Flutter registers; Paired Devices + WS count; `device_identity_test.dart` |
| Version shows exactly one `v` | ✅ `displayVersion`; `test-version-format.sh` |
| `go build` / `go test ./...` | ✅ |
| `flutter analyze` / `flutter test` (199) | ✅ |
| `flutter build apk` | ✅ |
| `xcodebuild` Debug | ✅ BUILD SUCCEEDED |
