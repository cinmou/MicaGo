# C22 — Firebase / FCM + background behavior (BlueBubbles-faithful)

Implements the missing client-side FCM wake + background behavior by porting
BlueBubbles' proven model rather than inventing a new design. The server FCM
dispatch was already built (C12) and BB-aligned; this pass adds the **client**
(the gap the C21 audit identified) plus the small server payload/config pieces.

> Model in one line (BlueBubbles): **the socket is the realtime path; FCM is a
> thin wake/awareness signal; the real message data always comes from sync, never
> from the push body.** MicaGo keeps WebSocket as foreground realtime and the
> **delta cursor** (C21d) as the catch-up/correctness path.

## BlueBubbles source ported (cited)

Server (`Ref/bluebubbles server/packages/server`):
- `src/server/services/fcmService/index.ts` — `sendNotification(devices, data,
  priority)` sends a **data-only** multicast (no `notification` block), Android
  priority normal/high, **24h TTL**, and ignores `registration-token-not-registered`.
- `src/server/index.ts` `emitMessage(type, data)` — sends the **same payload over
  both socket and FCM** as `{ type, data: JSON.stringify(data) }`. FCM mirrors the
  socket event; a separate `NewServerUrl` push follows the Mac's changing address.

App (`Ref/bluebubbles-app-master/lib`):
- `services/network/firebase/cloud_messaging_service.dart` — `registerDevice()`
  gets the FCM token and `http.addFcmDevice(name, token)` registers it; **skipped
  when `keepAppAlive` (foreground service) is on** — FCM and keep-alive are
  mutually exclusive.
- `services/backend/java_dart_interop/method_channel_service.dart` `new-message`
  handler — the **dedup rule**: if the app is alive *and* the socket is connected,
  **ignore** the FCM message (the socket already handled it); otherwise parse the
  payload and apply it / queue it. `NewServerUrl` saves the address + restarts the
  socket.

## Server (MicaGo)

Already built (C12): real `FCMProvider` (HTTP v1 + service-account OAuth),
`Dispatcher.DispatchNewMessages` firing on each sync's `NotificationEvents`,
per-device token storage, dead-token pruning, data-only payload, high priority,
24h TTL. C22 additions:

- **Payload**: added `sourceRowId` (the chat.db ROWID / delta cursor) to the push
  data alongside the existing BB-style fields `type` (`message:new`), `chatGuid`,
  `messageGuid`, `title`, `body`, `previewMode`, `createdAt`. Lightweight — no
  message history; the client uses `sourceRowId`/the cursor to run a precise
  catch-up. (`internal/notify/payload.go`, `dispatcher.go`, `fcm.go`.)
- **User-owned Firebase config**: `GET /api/fcm/client` serves the client config
  parsed from the admin's own `google-services.json` (config key
  `fcm.google_services_path`) — `{configured, projectId, appId, apiKey,
  messagingSenderId, storageBucket}`. These are public client identifiers (not the
  service account). Absent/misconfigured → `{configured:false}` so the app stays
  on WS + delta. (`internal/notify/firebaseclient.go`, `handlers.go`, `router.go`,
  `config.go`.)
- **Device fields**: registration now accepts `pushToken`, and `background`
  (FCM-wake capability); the device row + `DeviceJSON` carry `background`
  alongside `mode`/`appVersion`/`connected` (additive `ensureColumn` migration).
- Respects `pushEnabled` + `pushProvider` (disabled/`none` devices are skipped),
  and skips outgoing (`isFromMe`) messages.

## Flutter client (the C22 gap)

- Deps: `firebase_core`, `firebase_messaging`, `flutter_local_notifications`
  (+ core-library desugaring). The APK builds on the existing AGP 9 / compileSdk 36
  setup. **No `google-services.json` is baked into the APK.**
- `PushService` (`core/network/push_service.dart`):
  1. fetches `/api/fcm/client`; if `configured:false` it **no-ops** (WS + delta only);
  2. `Firebase.initializeApp(options: …)` **at runtime** from the server config
     (BlueBubbles' user-owned-project model);
  3. requests permission, gets the FCM token, and registers it via the existing
     stable-device-id registration (`pushProvider: fcm`, `pushToken`, `background`),
     re-registering on `onTokenRefresh`;
  4. **foreground** (`onMessage`): BB dedup — `pushShouldCatchUp(realtimeConnected)`
     → if the socket is up, ignore; else run a delta catch-up (GUID dedup ⇒ no
     duplicate bubbles). No system notification in foreground (no spam);
  5. **tap** (`onMessageOpenedApp` / `getInitialMessage`): delta-sync first, then
     `requestOpenChat(chatGuid)` → the shell jumps to Chats and the list opens the
     matching merged conversation;
  6. **background/terminated** (`micaGoFirebaseBackgroundHandler`, top-level
     `@pragma('vm:entry-point')`): inits Firebase in its own isolate and shows a
     local notification from the lightweight data; the real fetch happens via the
     existing **resume → `catchUp` → delta** path when the app is opened.
- Pure decision rules live in `core/network/push_logic.dart` (Firebase-free, unit
  tested): `pushShouldCatchUp`, `pushChatGuid`, `pushShouldNotify`.

### Background degradation ladder (BlueBubbles-style)
- **Foreground** → WebSocket realtime.
- **Background, alive** → WS stays connected where Android allows; resume runs
  `catchUp`.
- **Background, killed** → FCM wakes the isolate (notification) → on open, the
  existing resume → delta `catchUp` reconciles. App state is **warm**: the local
  cache and the persisted delta cursor are never torn down, so reopening is a
  cheap catch-up, not a cold full reload.
- **No Firebase** → reconnect + delta sync on app open (unchanged C21d path).

No native foreground service is added (it can't be exercised in this environment
and adds a persistent notification); the `background` flag reports FCM-wake
capability. This matches BB making `keepAppAlive` optional and FCM the default.

## Paired Devices (Companion)

`DeviceCardRow` secondary line now reads **"mode: …, push: …, background: …"**
(`push` shows **not configured** when `pushProvider == none`; `background` is
enabled when the client reports FCM-wake capability). No tokens are exposed.

## User-owned Firebase setup (guide)

1. Create your **own** Firebase project (free) and add an Android app with the
   application id `com.micago.message.mica_go`.
2. Download `google-services.json` and a **service account** key.
3. On the server set `fcm.enabled: true`, `fcm.service_account_path: …` (for
   sending) and `fcm.google_services_path: …/google-services.json` (served to the
   app). Restart/reload.
4. The app fetches the client config on connect, registers its token, and the
   Companion shows **push: enabled** for the device.
5. Leaving it unconfigured is fully supported — the app runs on WebSocket + delta.

## Tests
- Server: `notify.TestDispatchNewMessagesFakeProvider` (fake provider; only the
  enabled `fcm` device is sent to; payload carries BB fields + `sourceRowId`),
  `TestDispatchSkipsOwnMessages`, `notify.TestLoadFirebaseClientConfig*`
  (google-services.json parse + unconfigured), `fcm_test` payload-shape
  (data-only, allowed keys incl. `sourceRowId`),
  `relaydb.TestDeviceTokenRefreshUpdatesSameRow` (token refresh upserts the same
  row, no duplicate; push/background persisted).
- Client: `push_logic_test.dart` (foreground dedup, tap routing, notify gating),
  `device_identity_test.dart` (push fields included with a token; omitted /
  `none` when Firebase isn't configured).

## Validation
| Check | Result |
| --- | --- |
| Push dispatch uses a fake provider; payload matches BB fields + cursor | ✅ |
| Same-device token refresh updates the existing row (no duplicate) | ✅ |
| Foreground push → delta sync only when socket down (no dup bubbles) | ✅ |
| Notification tap targets the correct chat | ✅ (routing tested; UI best-effort) |
| Firebase missing/disabled does not break WS + delta | ✅ |
| Paired Devices shows push + background state | ✅ |
| `go build`/`go test`, `flutter analyze`/`test`, APK, `xcodebuild` | ✅ |

### Not done in this pass (honest scope)
- Real on-device FCM delivery needs the user's own Firebase project + a physical
  device; the integration is wired and builds, but end-to-end delivery is a manual
  step for the user.
- No native Android foreground service (BB's optional `keepAppAlive`); the FCM
  wake + warm-state ladder is used instead.

---

# C22 follow-up — BlueBubbles Firebase parity audit (audit only, no code change)

Reference = BlueBubbles. Goal: find where MicaGo's C22 differs and what the
smallest changes are to match. The headline gap is **automated setup**:
BlueBubbles creates/configures the user's Firebase project via Google OAuth;
MicaGo only supports the manual file path.

## 1. What BlueBubbles does

**Automated, OAuth-driven Firebase setup** (the differentiator):
- `src/server/services/oauthService/index.ts` — the whole flow. Hardcodes a
  **public BlueBubbles OAuth client id** + Firebase scopes
  (`cloudplatformprojects`, `service.management`, `firebase`, `datastore`,
  `iam`). Runs a local Koa server on `:8641` for the OAuth callback.
  `handleProjectCreation()` orchestrates, calling Google REST APIs with the
  user's access token:
  1. `createGoogleCloudProject()` → `cloudresourcemanager.googleapis.com` (reuses
     an existing "BlueBubbles" project if present).
  2. `enableService()` → `serviceusage` for cloudapis / cloudresourcemanager /
     firebase / firestore.
  3. `addFirebase()` → `firebase.googleapis.com/...:addFirebase`.
  4. `getServiceAccount()` → `iam.googleapis.com` create a SA **private key**
     (deletes old user-managed keys first) = the **server.json** credentials.
  5. `createDatabase()` → Firestore (used for the public server-URL sync).
  6. `createAndroidApp()` → `firebase .../androidApps` for the app package.
  7. `getGoogleServicesJson()` → downloads the Android app **config**
     (`/androidApps/{appId}/config`, base64) = the **client.json**
     (google-services.json).
  8. Saves both via `FileSystem.saveFCMServer(...)` / `saveFCMClient(...)`,
     creates Firestore security rules, **revokes** the OAuth token, restarts FCM.
- `src/windows/FirebaseOAuthWindow.ts` — Electron `BrowserWindow` loads the
  Google auth URL (implicit flow, `response_type: "token"`); on redirect to the
  localhost callback it parses `#access_token=…` from the URL fragment, sets
  `oauthService.authToken`, and triggers `handleProjectCreation()`.
- `ipcService` exposes `get-firebase-oauth-url` / `restart-oauth-service`;
  progress is pushed to the UI as `oauth-status` (NOT_STARTED / IN_PROGRESS /
  COMPLETED / FAILED). The desktop UI has a "Google Login" button + status/errors.

**Credential storage & serving:**
- `FileSystem` keeps two JSON files in an `fcmDir`: `server.json` (service
  account) and `client.json` (google-services.json). A **custom path** mode
  (`--fcm-server` / `--fcm-client`, `usingCustomFcm`) is the **manual fallback**;
  in that mode it does not overwrite the files.
- `fcmRouter.getClientConfig` (`GET /api/v1/fcm/client`) returns the **raw
  google-services.json** (plus a monkeypatch re-adding `oauth_client[]`).

**Runtime push** (already audited in C22 above): data-only FCM mirroring the
socket event (`{type, data}`), 24h TTL, token pruning; app registers the token
(`addFcmDevice`), authenticates via a **native Kotlin `firebase-auth` method
channel** using the raw config, dedups against the socket, shows notifications,
opens chats on tap, optional `keepAppAlive` foreground service.

## 2. What MicaGo currently does (C22)

- **No OAuth / no project creation / no scripts.** Setup is manual only:
  `fcm.service_account_path` (send credentials) + `fcm.google_services_path`
  (client config), both user-provided files.
- `GET /api/fcm/client` parses google-services.json server-side and returns a
  **subset** `{configured, projectId, appId, apiKey, messagingSenderId,
  storageBucket}`.
- Flutter `PushService` fetches that subset and calls
  `Firebase.initializeApp(options: FirebaseOptions(...))` at **runtime** (the
  `firebase_messaging` plugin), `getToken()`, registers via the stable-device-id
  registration (`pushProvider: fcm`, `pushToken`, `background`), token refresh.
- Push payload adds `sourceRowId` (delta cursor); foreground dedup vs socket;
  tap → delta-sync + open chat; background isolate notification + resume catch-up.
- Paired Devices shows `push` + `background`; fake-provider dispatch tests;
  fully optional (no Firebase → WS + delta); no bundled config.

## 3. Identical or close enough (keep as-is)
- **Push payload + dispatch conditions** — data-only, mirrors the socket event,
  TTL, token pruning, skip own messages, respect `pushEnabled`. MicaGo adds
  `sourceRowId`; harmless/better. ✅ matches.
- **Client gets config from the server, not bundled** — both serve config over
  HTTP; nothing in the APK. ✅ matches (MicaGo returns a parsed subset vs BB's raw
  json — necessary because MicaGo uses the `firebase_messaging` plugin + runtime
  `FirebaseOptions` instead of BB's native `firebase-auth`; both valid).
- **Token registration / refresh, dedup vs socket, tap→open, background→catch-up,
  optional-when-absent** — same logic/intent. ✅ matches.
- **Manual file fallback** — MicaGo's `service_account_path` / `google_services_path`
  is exactly BB's `usingCustomFcm` custom-path fallback. ✅ matches.

## 4. Missing in MicaGo (vs BlueBubbles)
1. **Automated Google-OAuth Firebase setup** (the big one): no Google sign-in, no
   project creation, no API enablement, no service-account-key generation, no
   google-services.json retrieval, no auto-save of credentials. MicaGo only has
   what BB calls the *manual/advanced* path.
2. **Setup UI + progress/error states** in the Companion (BB's "Google Login"
   button + `oauth-status`). MicaGo's Companion has no Firebase setup UI at all;
   the admin edits the config file by hand.
3. **Auto credential storage** (`server.json` + `client.json` written by the
   flow). MicaGo expects the admin to place files and point paths at them.
4. **Firebase-project-changed handling** (BB clears devices when the project id
   changes to avoid stale-token conflicts). MicaGo has no equivalent.
5. **Token revocation after setup** (BB revokes the short-lived OAuth token).

## 5. Should be deleted or replaced
- **Nothing should be deleted.** MicaGo's manual path == BB's custom-path
  fallback and the task says keep manual import as the advanced fallback.
- If the OAuth flow is added, the only *replacement* is that
  `/api/fcm/client` could optionally serve the **raw** google-services.json (BB
  shape) instead of the parsed subset — but only if MicaGo switches to a
  raw-json client init. Since MicaGo uses runtime `FirebaseOptions`, keeping the
  parsed subset is fine; no replacement strictly required.

## 6. Should MicaGo support BB-style Google auth + auto setup?
**Decision (current): NO — not yet. Keep the manual user-owned setup.** The
self-hosted, user-owned model is preserved: each user creates their own Firebase
project and imports `google-services.json` + a service account; Firebase stays
optional and the app keeps working on WebSocket + delta sync when it isn't
configured. BB's automated Google-OAuth flow is recorded below as a **future
enhancement only** — not implemented in this pass.

> If/when it is revisited, the adaptation notes and the one hard prerequisite are
> captured here so no re-audit is needed. Adaptation notes:
- BB's flow is **Electron-specific** (BrowserWindow capturing the implicit-flow
  token fragment). MicaGo's Companion is **native macOS SwiftUI** → use
  `ASWebAuthenticationSession` (or `WKWebView`) to run the same Google OAuth and
  capture the `access_token`, then call the **same Google REST APIs** (from Swift,
  or by handing the token to the Go server which performs the REST calls — Go is
  the cleaner home, mirroring BB's server-side service).
- **Prerequisite (decision needed):** BB hardcodes a **public OAuth client id**
  that BB registered (it is an app *identity*, not a secret, and each user's
  Firebase project is still created under *their own* Google account — no shared
  project). To replicate, MicaGo needs its **own public OAuth client id**
  registered in a MicaGo-owned Google Cloud project for the consent screen. This
  is not "a shared Firebase project" and not a secret, but it is a shared
  *app identity* and must be created/owned by the MicaGo project. Without it, the
  auto flow cannot exist and only the manual path is possible.
- Must remain **fully optional**; manual import stays as the advanced fallback;
  WS + delta unaffected.

## 7. Files that would change (if it proceeds)
Server (Go) — new `internal/notify/oauth.go` (or `internal/fcmsetup/`): Google
OAuth (token in, REST calls out), porting `oauthService`'s steps; write
`server.json` + `client.json` under the config dir; reuse existing
`LoadServiceAccount` + `/api/fcm/client`; add `fcm.google_services_path` default
to the written client.json; add a "project changed → clear devices" guard;
`router.go` for setup-status/start endpoints; `config.go` to record the
auto-written paths.
Companion (Swift) — a Firebase setup card: "Sign in with Google" via
`ASWebAuthenticationSession`, progress/error states (mirror `oauth-status`),
"Remove Firebase" + a manual-import advanced fallback; `APIClient`/`AppModel`
wiring to the new endpoints.
Flutter — none required (already consumes `/api/fcm/client` at runtime). Optional:
surface a "push not configured" hint.
Docs — this file.

## 8. Risks
- **OAuth client id ownership** (above) — the one true blocker; needs a
  MicaGo-owned public OAuth client + verified consent screen, or Google may warn
  users ("unverified app") for sensitive Cloud scopes.
- **Google API surface drift** — BB monkeypatches removed `oauth_client[]`;
  endpoints/quotas change. Porting must track BB's workarounds.
- **Security** — the SA private key is a real secret; store it locally with tight
  perms, never commit, never serve it (only the client config is served).
- **Scope/size** — this is a multi-day port (OAuth + 8 sequential REST steps +
  retries/waits + native auth window + UI). Higher risk than the rest of C22.
- **Testability** — the live Google flow can't be unit-tested; only the REST
  request shaping + storage can. End-to-end stays manual.

## 9. Validation plan (when implemented)
- Firebase disabled → app + WS/delta unaffected (regression).
- Manual `google_services_path` fallback still works.
- Google-auth setup creates/configures the project; `server.json` + `client.json`
  written; `/api/fcm/client` serves the generated config.
- Android registers an FCM token; Companion shows **push: enabled**; **Test Push**
  works; background push wakes/marks catch-up; tap opens the right chat; push +
  WS does not duplicate.
- Project-changed → devices cleared.
- Go / Flutter / APK / Companion builds + tests pass; unit tests for REST request
  shaping + credential storage with a fake Google endpoint.
