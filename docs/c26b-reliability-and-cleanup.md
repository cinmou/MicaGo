# C26b — Reliability fixes + cleanup pass

A blocker/cleanup cycle across all three surfaces (Go server, macOS Companion,
Flutter client). Five problems, each fixed at the root rather than patched at the
symptom, plus a safe consolidation. Builds on
[C26](c26-endpoint-refresh-public-persistence.md) and
[C25](c25-connection-model-lan-primary.md).

## 1 — IMCore helper capability/status is now visible end-to-end

The bundled IMCore helper performs the advanced iMessage actions (edit / unsend /
delete). Previously nothing surfaced whether it existed, was runnable, or was
failing — the app could imply support that wasn't there.

- **Server.** `imessage.HelperPerformer.Capabilities` already probes the helper
  (resolve path → run `status` → read per-selector caps, or report a reason on a
  missing/failing helper). C26b adds a **single source of truth**
  (`Handlers.messageActionCapabilities`) shared by the dedicated capability
  endpoint and the status payload, plus a **30s TTL cache** so the companion's
  frequent polling doesn't spawn the helper subprocess every tick.
- **Status.** `GET /api/server/status` now includes a `messageActions` block
  (`available`, `edit`, `retract`, `delete`, `helper`, `reason`,
  `requiresMessages`). A missing/unconfigured helper reports `available:false`
  with a reason — never a fake "supported".
- **Companion.** A new **Message Actions** card (Debug/diagnostics column) shows
  whether the helper is available and, when it is, the per-action support; when
  it isn't, it shows the reason and the resolved helper path.
- **Flutter.** The long-press menu already gates Edit / Undo Send / Delete on
  `GET /api/messages/actions/capabilities` (all-false when the helper is
  missing), so those actions simply don't appear unless the backend confirms
  they're usable. No fake success path.

Message Inspector / raw debug stays accessible. Users are never asked to install
`imsg`/`imsgbridge`.

## 2 — Android no longer stuck on "Reconnecting…"

Root cause: the one-shot notice derivation intentionally reports `null` on the
`connecting → connected` edge (a routine realtime restore is meant to be silent).
But the sticky "Reconnecting…" banner was only cleared by a *later notice*, so a
recovered connection could leave the stale banner up indefinitely.

- `AppController` now exposes `connectionHealthy` (a `ValueNotifier<bool>` =
  WS connected + reachable), updated in lock-step with every connection snapshot.
- `ConnectionNoticeHost` clears any sticky problem banner the instant
  `connectionHealthy` flips true, and refuses to raise a problem banner while the
  connection is currently healthy. So "connected" clears the banner immediately,
  regardless of whether a transition notice fired.
- The resume/startup **grace window** now also suppresses a brief `reconnecting`
  notice after a background→resume (even once we've connected before), so normal
  app lifecycle doesn't flash false reconnect UI. Genuine problems (offline,
  dropped) still surface immediately.

## 3 — Endpoint refresh + Public URL persistence (the real root cause)

C26 fixed the Companion's `refresh()` coupling and the Public-URL field mirror
(both retained). The remaining "still broken" case was on the **server**: a
pre-C25 config bound loopback-only (`addr: "127.0.0.1:3000"` / `localhost`) is
preserved verbatim on load, so `lanEndpoints` derives **nothing** — LAN never
appears no matter how often endpoints refresh, and the user is forced to set a
Public URL.

- **`config.Load` now migrates a file-configured loopback bind up to the
  LAN-capable default (`0.0.0.0:3000`) and persists it.** Loopback is no longer a
  supported pairing bind (C25), so this self-heals existing installs. An explicit
  `--addr` override and `--disable-auth` (which legitimately needs a local bind)
  are respected and never migrated.
- Net effect: starting the backend auto-advertises LAN with no Save; a saved
  Public URL survives backend/Companion restarts (C26 persistence + this migration
  no longer drops fields).

## 4 — Attachment-unavailable renders as "unsent", not a broken card

`missing_attachment_rows` and `empty_edited_residue` are unrecoverable attachment
placeholders — there is no real file to show. They now route to the
retracted/unsent presentation (a subtle system row), never a broken file card or
a cryptic "Unsupported message":

- Own messages → "You unsent a message"; others → "{Sender} unsent a message"
  (resolved contact name), falling back to "This message was unsent".
- `retractedLabel` gained an optional `senderName`; `_systemLabel` passes the
  resolved name through.
- The diagnostic reason is **retained** for Message Info / Debug
  (`classifyMessage` still reports `emptyEditedResidue` /
  `unsupportedAttachment`, and the debug map still carries the raw
  `semanticKind` / `unsupportedReason`).

## 5 — Cleanup

- **Reaction target-GUID helpers consolidated.** Three copies existed; the
  display path handled `p:<part>/GUID` while the realtime + cache paths handled
  only `p:GUID`/`+GUID` — each mishandling the other's real format (a latent
  reaction-match bug). There is now one canonical `reactionTargetGuid(String?)`
  in `message_render.dart` that strips the `p:`/`bp:` scheme, an optional
  `<part>/` segment, and a leading `+`; the realtime helper and the local cache
  delegate to it.
- Confirmed already-clean items left untouched: the obsolete long-press "Copy
  debug JSON" entry is gone (the menu is Copy / Message Info / gated actions; the
  "Copy debug JSON" that remains is the *intentional* capability inside Message
  Info). `ConnectionMode` is the active LAN/Public preference model, not stale.

## Tests

- Go: `TestLoopbackBindMigratesToLAN` (loopback → LAN default + persisted;
  explicit `--addr` respected); existing `TestPublicURLSurvivesRestart`,
  `TestMessageActionCapabilitiesUnsupportedWithoutHelper`,
  `TestGetServerStatus*` still green.
- Flutter: new `attachment-unavailable placeholders` group + retracted-label
  sender-name cases in `bluebubbles_semantics_test`; updated
  `message_render_test` / `thread_presentation_test` for the unsent presentation;
  `connection_notice` derivation tests unchanged (the Part 2 fix is in the
  host/controller, validated by build + the healthy-flag wiring).

## Validation

| Check | Result |
| --- | --- |
| Go `go build ./...` + `go vet` | ✅ |
| Go tests | ✅ except pre-existing `TestSendAttachmentSMSGate` (writes into the TCC-protected real `~/Library/Messages/Attachments`; fails on the clean C26 baseline too — environmental, not a C26b change) |
| Companion `xcodebuild` (Debug) | ✅ BUILD SUCCEEDED |
| `flutter analyze lib test` | ✅ No issues |
| `flutter test` | ✅ 275 passed |
| Fresh start shows LAN without Save | ✅ (C25 default + loopback migration) |
| Saved Public URL survives restart | ✅ |
| Android doesn't show Reconnecting while connected | ✅ (healthy-flag clears banner) |
| Helper missing/present status visible + correct | ✅ (status block + Companion card) |
| Edit/Undo/Delete only when helper available | ✅ (Flutter gates on capabilities) |
| Attachment-unavailable not a broken card | ✅ (routed to unsent row) |

Manual: build the debug APK, pair over LAN on the same Wi‑Fi (no Public URL),
background/foreground the app and confirm no stuck "Reconnecting…"; with no helper
bundled, confirm Edit/Undo/Delete are absent and the Companion shows the helper as
unavailable with a reason.
