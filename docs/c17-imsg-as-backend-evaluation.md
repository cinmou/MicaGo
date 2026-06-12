# C17 — IMSG-as-backend evaluation

Question: now that backend freshness is fixed, should MicaGo eventually replace
its Go chat.db reader with `imsg` (Swift, `Ref/imsg`)? Three options, evaluated
against the same criteria. **Decision input only — no migration in C17.**

Reference facts (re-read for this evaluation):
- `imsg` is MIT-licensed (single maintainer, Peter Steinberger). `imsgweb` has
  no license file in the vendored copy — would need clarification before reuse.
- `imsg rpc` speaks JSON-RPC over stdio with methods: `chats.list/create/delete`,
  `messages.history`, `watch.subscribe/unsubscribe`, `send.rich`,
  `send.attachment`, `poll.send`, `message.edit/unsend/delete/send_status`,
  `group.rename/leave`, `handles.check`.
- Watch = inode-aware fsevents on chat.db/-wal/-shm + dir + 5 s fallback poll,
  ROWID cursor with resume (`sinceRowID`), batch limit, optional reactions.
- Attachment conversion (HEIC→JPEG etc.) is in **imsgweb** (TS,
  `server/attachments.ts`), not in imsg itself; imsg returns metadata/paths.
- Send goes through AppleScript/IMCore bridge inside imsg, same approach as
  MicaGo's AppleScript sender.

## Option 1 — Keep the current Go backend reader

**Pros**
- Already implements the IMSG read model: WAL-aware `mode=ro` open (C15),
  attributedBody/TypedStream decode, reaction/noise classification, renderable
  relay timeline (C12), per-chat/hybrid backfill (C13), watch via WAL/SHM mtime
  poll + coalescing engine + bounded date-lookback (C11) — each covered by the
  existing Go test suite (~170 tests).
- One process, one language, one packaging story; relay.db gives offline-capable
  Android sync + WS fan-out that imsg does not provide at all.
- Full control of the raw/debug Inspector path (reads chat.db directly).

**Cons / remaining gaps**
- We re-derive Apple schema quirks ourselves (imsg has more field coverage:
  polls, rich sends, typing indicators, sticker/audio columns).
- mtime polling (750 ms) is marginally less precise than inode-keyed fsevents.
- TypedStream decode is a hand-rolled parser; rare bodies may still decode
  imperfectly (Inspector reveals such rows).

**Risk: low.** The C17 finding was that recent fixes weren't *running*, not
that the reader design is wrong. Verify with a fresh binary before judging.

## Option 2 — Spawn `imsg rpc` as a subprocess of MicaGoServer

**Pros**
- Battle-tested reader/watcher; richest schema coverage; maintained upstream.
- JSON-RPC surface maps cleanly: `messages.history` → backfill,
  `watch.subscribe` → realtime ingest, `message.send_status` → send confirm.
- MicaGo keeps relay.db/REST/WS unchanged — imsg would only replace the
  *ingest* side (`store.Queries` sync methods), not the client API.

**Cons / costs**
- **Packaging:** must build, codesign, and notarize a second (Swift) binary
  inside the companion bundle; Swift toolchain joins the build chain; macOS
  Full Disk Access now applies to the child-of-child process. Bundle size grows
  (SQLite.swift + Swift runtime).
- **Process supervision:** stdio child lifecycle, restart-on-exit, demuxing
  watch streams vs request/response (imsgweb's `RpcClient` shows ~300 lines of
  this in TS; we'd rewrite it in Go).
- **Error handling:** a crashed child loses in-flight watches; resume relies on
  `sinceRowID` replay — workable but new failure modes vs in-process reads.
- **Attachment conversion stays ours** (imsg doesn't convert) — the C9 preview
  pipeline remains either way.
- **Debug/raw view:** imsg returns its *decoded* model; the Inspector's
  raw-row view would still need a direct chat.db connection, so the "two
  readers" smell returns (imsg for normal + Go for debug).
- Performance: JSON over stdio per page is fine for chat volumes; not a real
  concern, just no upside either.
- Licensing: imsg MIT = fine; vendoring requires attribution. Upstream is a
  single-maintainer project — version pinning + fork readiness required.

**Integration cost estimate:** medium-large (supervisor + RPC client + ingest
adapter + packaging/signing changes + dual-reader story for debug).

## Option 3 — Port IMSG's reader logic into Go more directly

**Pros**
- Keeps one process/language and the existing relay; upgrades correctness
  piecemeal (e.g. adopt imsg's URL-balloon dedupe, audio/sticker columns,
  poll support) with tests per piece.
- No new runtime, signing, or supervision burden.

**Cons**
- It is largely **already done** — C11–C15 ported the load-bearing concepts
  (open flags, reaction filter, renderable list, watch+fallback, per-chat
  history). What remains is long-tail field coverage, which can be ported
  on demand when a concrete rendering gap shows up.
- Maintenance: tracking upstream imsg improvements is manual.

**Difficulty: low per-feature; risk: low.**

## Criteria matrix

| Criterion | Go reader (today) | imsg subprocess | Port more into Go |
| --- | --- | --- | --- |
| Live watch reliability | good (mtime 750 ms + lookback) | best (fsevents+inode) | can adopt inode/dir watch |
| History correctness | good, tested | best field coverage | incremental |
| Attachment conversion | ours (C9) either way | not provided by imsg | ours |
| Replies/reactions/effects | implemented (C12) | implemented | implemented |
| Send status | DB-reality match + error column | `message.send_status` | keep ours |
| Raw/debug | native | needs second reader | native |
| Packaging | single Go binary | + Swift binary, sign/notarize | single Go binary |
| Licensing | n/a | MIT (attribution; imsgweb unlicensed) | concept-port, cite |
| Swift runtime dep | none | yes | none |
| Sandbox/signing | current story | FDA for child-of-child, more entitlements | current story |
| Android API shape | unchanged | unchanged (relay stays) | unchanged |

## Recommendation

**Stay on Option 1 now; treat Option 3 as the standing improvement path;
re-evaluate Option 2 only if a concrete correctness gap survives a verified
fresh binary.** C17 just proved that every recent sync fix may have been
running on a stale binary — judging the Go reader before testing it fresh
would repeat the same mistake. The first imsg features worth porting if gaps
appear: inode-keyed file/dir watching and URL-balloon dedupe.
