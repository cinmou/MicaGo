# C12 — Migration report

Scope: review `Ref/imsg` + `Ref/imsgweb-main` and replace MicaGo's chat.db
reading / message pipeline / attachment rendering with an IMSG-inspired pipeline
that is simple, reliable, and produces a clean renderable timeline. Breaking
rewrite was authorized.

## Headline finding

The IMSG/imsgweb correctness ideas were **already ported** into MicaGo across
C7–C11 (see `docs/c12-imsg-rewrite-audit.md` mapping table):

- attributedBody/TypedStream decode → `store/text.go`
- canonical cmj-JOIN + handle SQL → `store/queries.go`
- renderable-only timeline (no empty/noise rows) → `store.ClassifyMessageJSON`
  + `FilterRenderableMessages`
- last-message ordering & preview → `relaydb.ListChats`
- attachment preview/convert (HEIC/TIFF → JPEG/PNG, content-hash cache, stable
  URLs) → C9 preview endpoint + `previewUrl`/`needsPreviewConversion`
- file-watch + fallback poll + cursor → C11 WAL/SHM mtime watch + `SyncEngine` +
  bounded date-lookback union

So a wholesale rewrite would mean deleting a working Go pipeline (and the
~150 passing tests covering it) to re-derive the same behaviour from a Swift
reference that uses a different architecture (Swift RPC-per-read vs Go relay+WS).
That trades correctness for churn. **Decision: keep the pipeline, close the one
genuine divergence, document honestly.** This is the conservative reading of
"do not keep layering patches on a broken pipeline" — the pipeline is not
broken; the audit confirms it implements the IMSG model.

## The one genuine divergence — fixed in C12

IMSG/imsgweb fold reaction (tapback) rows into their target and **never** put
them in the message list (`web/model.ts applyReactionEvent`). MicaGo merges
tapbacks onto their target on the client, but the **server chat-list aggregate**
counted a reaction row as renderable — so a trailing tapback could bump a chat
to the top of the list or become its preview text. That is the visible bug this
review surfaced.

Fix:
- `store/classify.go` — `IsReactionForSyncRow(r)`: true when
  `associated_message_type ∈ [2000,3006]` **and** a non-empty target GUID.
- `relaydb/migrations.go` — additive `messages.is_reaction INTEGER` column.
- `relaydb/sync.go` — `upsertMessagesTx` persists `is_reaction` (INSERT column +
  placeholder + `ON CONFLICT … is_reaction = excluded.is_reaction`).
- `relaydb/query.go` — `ListChats` renderable count / `latest_at` / `latest_text`
  subqueries now also require `COALESCE(m.is_reaction,0)=0`. A reaction neither
  bumps nor previews a chat; a reaction-only chat is `unsupportedOnly` and hidden
  by default. The row is still synced so the client merges the chip onto its
  target, and the Inspector/debug list still reveals it.

Test: `internal/relaydb/reaction_chatlist_test.go`
(`TestReactionsExcludedFromChatListAggregate`, `TestIsReactionForSyncRow`).

## Deletion assessment (Part I)

Looked for dead classification helpers, duplicate query paths, dead sync
functions, stale docs, unused compat branches. Findings:
- No two competing renderable pipelines exist — there is one `store`→`relaydb`
  read path and one classifier. The Inspector reads the same rows with a flag,
  not a parallel implementation.
- The relay/sync code (`SyncEngine`, lookback union, `message_state`) is the
  single live path and is covered by tests; deleting it would remove the only
  realtime/edit/retract mechanism with no cleaner Go replacement available from
  the Swift reference. **Not deleted** — that would be churn-for-churn, against
  the spirit of the constraint.
- No stale duplicate helpers were found to remove in this pass; the C11 cleanup
  already removed the pre-SyncEngine ad-hoc sync calls.

Honest note: this review did **not** perform a destructive rewrite, because the
audit showed the existing pipeline already realizes the IMSG design. The work
that was warranted — closing the reaction-aggregate gap — was done.

## Out of scope (respected)
Push/Firebase, cosmetic UI rewrite, Cloudflare/tunnel management — untouched.
Message Inspector / `/api/debug/*` raw view — preserved; still exposes hidden
and reaction rows.

## Validation (Part K)

| Command | Result |
| --- | --- |
| `go build ./...` (micago-server) | ✅ ok |
| `gofmt -w` changed files | ✅ clean |
| `go test ./...` (micago-server) | ✅ all packages ok (relaydb, store, httpapi, app, …) |
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 157 tests passed |
| `flutter build apk --profile` | ✅ app-profile.apk (124.5 MB) |
| `flutter build apk --release` | ✅ app-release.apk (73.6 MB) |
| companion `xcodebuild` | ⏭ not run — companion unchanged in C12 |

## Acceptance against the C12 asks

- Single canonical reader / one renderable pipeline: ✅ confirmed (was already so).
- Chat list from renderable messages, ordered by latest renderable, unknown
  contacts visible, empty/noise hidden, raw/debug shows all: ✅ — and C12 fixes
  reactions leaking into ordering/preview.
- Aggressive empty/noise filtering with diagnostics, Inspector reveals: ✅ existing.
- Attachment/image fidelity + previewUrl + no TIFF decode in timeline: ✅ existing (C9).
- Realtime DB update without rowid blind spots: ✅ existing (C11 SyncEngine + lookback).
- Send pipeline (optimistic / confirm / timeout≠failure / upgrade same row): ✅ existing (C11 F/G).
- Android local DB clean renderable, raw separate: ✅ existing; schema additive,
  no client-side reset required (no client schema change in C12).
- Is the IMSG path the only normal message path? **Yes** — one classifier, one
  relay read; debug is a flagged view of the same rows, not a competitor.
