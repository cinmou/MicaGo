# C27 — Real IMCore helper binary (edit / unsend / delete)

Replaces the "no helper component in this build" placeholder with a real,
MicaGo-bundled IMCore helper, so the install → rescan → ready → actions chain is
complete end-to-end. Builds on the C28 rescan chain and the C26c install flow.

## 1 — imsg audit (what was reused)

`Ref/imsg` performs the advanced actions through a **dylib injected into
Messages.app** (`Sources/IMsgHelper/IMsgInjected.m`), which requires **SIP
disabled** + DYLD injection and is increasingly blocked on newer macOS. We do
**not** ship or require that (and never require the user to install
imsg/imsgbridge). We ported only the minimal IMCore action logic:

- Chat resolve: `IMChatRegistry.sharedInstance` → `existingChatWithGUID:` /
  `existingChatWithChatIdentifier:`.
- Message lookup: `IMChatHistoryController` load + poll `chat.chatItems` by GUID.
- **Edit:** `editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:`
  (or legacy `editMessage:…`), with the `__kIMMessagePartAttributeName`
  attributed body IMCore expects.
- **Unsend/retract:** `retractMessagePart:` on the resolved message part.
- **Delete:** `deleteChatItems:`.
- Capability probe: `[IMChat instancesRespondToSelector:…]` for each selector.

## 2 — The helper binary

`MicaGoServer/micago-mac-companion/helper/micago-imcore-helper.m` — a single,
self-contained Objective-C CLI (≈250 lines):

- Speaks the exact backend protocol (`internal/imessage/actions.go`
  `helperEnvelope`): reads one JSON object on stdin, writes one on stdout, exits
  0. `status` → `{"capabilities":{edit,retract,delete}}`; `edit`/`retract`/
  `delete` → `{"ok":true}` or `{"ok":false,"code":…,"error":…}`.
- Loads IMCore with `dlopen` (no private-framework link → builds + signs like any
  normal binary; only Foundation is linked), connects to the Messages daemon
  (`IMDaemonController.sharedInstance` → `connectToDaemon`), and probes selectors.
- Returns clear machine-readable codes the backend already maps: `not_found`,
  `unsupported`, `not_allowed`, `bad_request`, `action_failed` (and the backend
  still maps `expired`/permission strings).
- **Honest capabilities:** reports edit/unsend/delete available only when the
  selectors exist **and** the daemon is reachable — otherwise the actions can't
  run, so it reports them unavailable rather than promising a failing action.

## 3 — Bundling

The Companion's existing "Bundle Go Backend" Xcode build phase now also compiles
the helper into the app Resources:

```
clang -fobjc-arc -framework Foundation -o \
  "$RESOURCES/micago-imcore-helper" helper/micago-imcore-helper.m
```

So **debug and release builds both include** `MicaGoCompanion.app/Contents/
Resources/micago-imcore-helper` (same pattern/signing path as the bundled
`micago` backend). `scripts/build-imcore-helper.sh` builds it standalone for
local testing.

## 4 — Install

`IMCoreHelperInstaller.install()` finds the bundled helper in Resources, copies
it to **`~/.micago/bin/micago-imcore-helper`**, and `chmod 0755`s it — the exact
path the backend scans (`imessage.helperPath` / `HelperInstallDir`). The Install
button now installs a real binary; it no longer "does nothing". Verified: bundled
binary runs, the installed copy runs, and the Go `helperPath` test finds it.

## 5 — Rescan + status (from C28, now end-to-end)

After install the Companion calls `POST /api/messages/actions/refresh`, which
invalidates the backend's cached probe and re-scans immediately;
`/api/server/status` + the capability endpoint update with no restart. The
Dashboard card shows missing → installing → (ready | not_runnable |
unsupported_selectors). Flutter re-fetches capabilities live each time the
long-press menu opens.

## 6 — Action chain

- Backend `EditMessage`/`RetractMessage`/`DeleteMessage` → `HelperPerformer.perform`
  → runs the helper with the JSON envelope → maps the helper's code/error.
- Flutter shows Edit/Unsend/Delete only when `capabilities` report them ready.
- Failures surface as `unsupported` / `not_allowed` / `not_found` / clear helper
  errors — never a fake success.

## Honest limitation

Whether edit/unsend/delete actually **execute** depends on the runtime
environment: the helper must be allowed to drive IMCore via the Messages daemon
(Full Disk Access / Automation; on locked-down macOS the same SIP/entitlement
limits imsg documents). Where that isn't available the helper truthfully reports
unavailable (capabilities false → backend `unsupported_selectors`) and the UI
hides the actions. On a machine without that access (e.g. this CI), `status`
returns all-false — which is correct, not a failure. The binary, protocol,
bundling, install, rescan, and gating are all real and verified; only the
private-API execution is environment-gated.

## Validation

| Check | Result |
| --- | --- |
| Helper compiles (`build-imcore-helper.sh`) | ✅ |
| Helper runs + valid JSON (`status`, actions, bad action) | ✅ |
| Companion `xcodebuild` Debug + helper bundled into Resources | ✅ BUILD SUCCEEDED |
| Install copies to `~/.micago/bin`; backend scans same path | ✅ (path-aligned; Go `helperPath` test) |
| Go tests | ✅ except pre-existing env-only `TestSendAttachmentSMSGate` |
| `flutter analyze` / `flutter test` | ✅ / ✅ 278 passed |
| debug APK | ✅ Built |

Manual: fresh Mac (no helper) → Dashboard "missing" + Install → click Install →
helper lands in `~/.micago/bin` → backend rescans → card updates (ready where the
environment permits, else unsupported with a reason) → Flutter shows Edit/Unsend/
Delete only when ready.
