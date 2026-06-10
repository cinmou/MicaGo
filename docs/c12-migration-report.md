# C12 — Migration report (destructive rewrite)

Scope: review `Ref/imsg` + `Ref/imsgweb-main`, then collapse MicaGo's message
pipeline to **one** canonical IMSG-inspired renderable timeline path, deleting
the duplicate/legacy paths. Breaking, destructive changes were authorized.

The first C12 pass only fixed reaction chat-list aggregation; this pass does the
real cleanup. This report lists exactly what was deleted, what was retained, and
why.

## 1. Normal message paths that existed before C12

Mapping the code showed **two competing "normal" serving implementations**, both
satisfying the same `apiQueryService`/`messageQueries` interface and selectable
at runtime by `--api-store` (default `relaydb`):

| Path | Backing store | Methods | Filtering |
| --- | --- | --- | --- |
| **relaydb** (default) | `relay.db` cache | `relaydb.DB.ListChats/ListChatMessages/ListRecentMessages/ChatExists/GetChatInfo/FindOutgoingMessageMatch` | classified at sync time; chat list hides noise; thread filtered in **Go after pagination**; `/messages/recent` **not filtered at all** |
| **chatdb** | live `chat.db` | `store.Queries.ListChats/ListChatMessages/ListRecentMessages/ChatExists/GetChatInfo/FindOutgoingMessageMatch` | ad-hoc empty-text SQL filter; `ListChats` never computed the renderable aggregate so it **never hid noise** |

Plus two realtime/ingestion leaks into the "normal" timeline:
- **WS broadcast** (`broadcastSyncResult`) pushed `result.NewMessages` — populated
  by `GetMessagesByGUIDs`, **unfiltered** — so a freshly-synced debug-only/noise
  row was broadcast as `message:new` and the Flutter client upserted it
  unconditionally into the thread.
- **Android local cache** (`LocalCacheStore`, schema v1) stored whatever it
  received with **no renderable guard**, and had no migration — pre-C12 noise
  rows could persist forever.

The Message Inspector (`/api/debug/recent-messages`, `store/debug.go`) is a
separate read of chat.db and is **not** a normal path — it is the intended raw
view.

## 2. Code deleted / disabled

**The entire `chatdb` API serving path is gone.** chat.db is now read by exactly
two things: the sync reader (`store.Queries` *sync* methods) and the debug
inspector. Clients only ever read the classified relay.

Deleted:
- `internal/app/app.go`: `selectAPIStore()` + the `chatdb` branch; `apiStore`
  selection logic — replaced by `var apiQueries apiQueryService = relay`.
  `Options.APIStore` removed.
- `internal/config/config.go`: `APIStore`, `DefaultAPIStore`,
  `defaultDefaultAPIStore` removed.
- `cmd/micago/main.go`: `--api-store` flag removed.
- `internal/store/queries.go`: **−418 lines.** Deleted serving methods
  `ListRecentMessages`, `ListChats`, `ChatExists`, `GetChatInfo`,
  `ListChatMessages`, `FindOutgoingMessageMatch`; dead helpers `scanMessages`,
  `scanMessageRow`, `rowToMessageJSON`, `attachMessageAttachments`,
  `buildRecentMessagesQuery`, `buildChatsQuery`, `buildChatMessagesQuery`; dead
  consts `recentMessagesBaseSQL`, `chatsBaseSQL`, `chatExistsSQL`, `chatInfoSQL`,
  `chatMessagesBaseSQL`.
- `internal/store/models.go`: `ChatRow` type (only used by the deleted `ListChats`).
- Deleted stale tests that locked in old behavior:
  `internal/store/queries_test.go` (tested the deleted `buildRecentMessagesQuery`
  empty-text SQL builder) and `internal/app/app_test.go`
  (`TestSelectAPIStoreInvalid`).
- `internal/store/text_test.go`: rewrote `TestRowToMessageJSON…` (used the
  deleted `rowToMessageJSON`) to exercise the surviving canonical decoder
  `ExtractMessageText` directly.

## 3. The one canonical normal timeline path (new)

```
chat.db (read-only)
  └─ store.Queries (SYNC methods only)  ── canonical reader
       └─ relaydb upsert + classification (is_debug_only, is_reaction persisted)
            └─ relaydb.ListChats / ListChatMessages / ListRecentMessages  ← SQL-filtered
                 └─ httpapi REST + WS (renderable-only)  → clients
```

- `relaydb.ListChatMessages` / `ListRecentMessages` now filter
  `COALESCE(is_debug_only,0)=0` **in SQL, before LIMIT/OFFSET**, so pagination is
  stable (the old Go post-pagination filter could silently shrink a page).
  `includeDebug=true` returns the raw timeline.
- The handlers no longer post-filter; they pass one `raw` flag
  (`?debug=true`, with `?includeEmpty=true` kept as a legacy alias) straight
  through. `parseIncludeEmpty` was replaced by `parseRawTimeline`.
- `ListChats` orders by latest renderable, non-reaction message and excludes
  reactions from the preview/count (C12 part 1).

## 4. Raw/noise/debug rows live only in the debug path

- Noise rows are still **persisted** in relay.db (so nothing is lost) but carry
  `is_debug_only=1` and are excluded from every normal read.
- The Message Inspector (`/api/debug/recent-messages`) and `?debug=true` on the
  normal endpoints are the only ways to see them — unchanged, still fully
  capable (required: debug capability must remain).

## 5. Realtime path closed

`internal/relaydb/sync.go` + `internal/app/app.go`: the WS `message:new`
broadcast and notification dispatch now apply `store.FilterRenderableMessages`,
so a freshly-synced noise row is **never** broadcast or notified. Reaction rows
survive (renderRecommendation=merge) so tapbacks still reach the client to be
folded onto their target. `result.NewMessages` itself stays raw so the rowid
watermark and send-reconciliation are unaffected.

## 6. Android local cache rebuilt (destructive)

`lib/core/storage/local_cache_store.dart`: schema bumped to **v2** with a
destructive `onUpgrade`/`onDowngrade` that drops and recreates all tables, so
pre-C12 polluted rows cannot survive (safe: app unreleased, cache repopulates
from the server). Added a renderable guard in `_batchUpsertMessages`: a row with
`isDebugOnly` is never stored in the normal thread cache (defense-in-depth on top
of the server-side filter). The raw timeline lives behind the server Inspector
API, not in this cache.

## 7. Code retained, and why

- **`store.Queries` sync methods** (`ListSyncChats`, `ListSyncRecentMessages*`,
  `ListMessageUpdatesSince`, `ListSyncAttachmentsForMessages`, `buildSyncMessagesSQL`,
  `scanSyncRowSemantic`): the canonical chat.db reader that feeds the relay. Not
  a competing serving path — there is no other reader.
- **`store.Queries.FindOutgoingMessageError`**: reads `message.error` from
  chat.db for fail-fast send failure detection. The relay schema does not keep
  `error` on the message row, so there is no relay equivalent; it is a targeted
  single-row reality check wired directly to the send path, not a list path.
- **relaydb/SyncEngine/lookback/message_state**: the single live realtime + edit
  + retract mechanism, fully tested; the Swift reference offers no Go substitute.
- **Message Inspector / `store/debug.go`**: the required raw/debug view.

## 8. Tests added (proving the invariants)

- `internal/relaydb/renderable_timeline_test.go`:
  - `TestRenderableThreadAndRecentExcludeNoise` — an empty/noise row cannot enter
    the normal thread or normal recent list; `debug=true` reveals it (req #7).
  - `TestReactionDoesNotReorderChats` — a reaction newer than all text does not
    pull its chat above one with newer text; preview stays the text (req #9).
- `internal/store/classify_test.go`:
  - `TestAttachmentOnlyMessageIsRenderableNotBrokenBubble` — an attachment-only
    row (real attachment, empty text) is renderable and survives the filter; a
    cache_has_attachments placeholder with no rows is surfaced as unsupported,
    never a silent broken bubble (req #8).
- `internal/relaydb/reaction_chatlist_test.go` (C12 part 1): reaction excluded
  from chat-list aggregate; reaction-only chat hidden.
- `test/local_cache_store_test.dart`:
  - `debug-only/noise rows cannot enter the normal thread cache` — client-side
    guard, both `replaceServerPage` and `upsertMessage` (req #7, client).
- Updated `internal/httpapi/handlers_test.go` stub to model the relay SQL filter
  (the handler no longer post-filters), keeping the default-renderable /
  debug-raw assertions meaningful.

## 9. Validation

| Command | Result |
| --- | --- |
| `gofmt -l` (changed files) | ✅ clean |
| `go build ./...` | ✅ |
| `go vet ./...` | ✅ (one pre-existing `t.Context` go1.24 advisory, unrelated) |
| `go test ./...` | ✅ all packages |
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 158 tests passed |
| `flutter build apk --profile` | ✅ 124.5 MB |
| `flutter build apk --release` | ✅ 73.6 MB |
| companion `xcodebuild` | ⏭ not run — companion unchanged in C12 |

## 10. Is the IMSG path the only normal message path? — Yes

After this pass there is exactly one normal serving implementation (relaydb,
SQL-filtered), one canonical chat.db reader (the sync methods), one realtime feed
(renderable-only), and one local cache (renderable-only with a guard). The raw
timeline exists only behind the debug API. The competing `chatdb` API path, its
~418 lines of duplicate query code, the runtime switch, and the stale tests that
pinned the old behavior are deleted.
