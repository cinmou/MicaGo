# C15 — MicaGo vs IMSG/imsgweb delta (after the chat.db-open fix)

Snapshot of how MicaGo's chat.db access compares to the reference *after*
dropping `immutable=1` and adding relay.db corruption recovery. Companion to
`docs/c15-imsg-db-open-and-error-handling.md`.

## Now matching the reference

| Concern | IMSG (`Ref/imsg`) | MicaGo (after C15) | Status |
| --- | --- | --- | --- |
| Open mode | `mode=ro`, `readonly: true` | `file:…?mode=ro` | ✅ matched |
| Immutable flag | not set (WAL-aware) | **removed** (`internal/store/db.go readOnlyDSN`) | ✅ matched — this was the malformed-error cause |
| Busy timeout | `busyTimeout = 5` (5 s) | `_busy_timeout=5000` | ✅ matched |
| Writes to Apple chat.db | never | never (read-only conn; sends via AppleScript) | ✅ matched |
| Integrity check / repair / vacuum on chat.db | never | never | ✅ matched |
| Survive transient read error | stream ends, process lives, re-polls (5 s fallback) | sync loop logs + records `LastSyncError`, continues, retries next tick | ✅ equivalent |
| Degraded-state signal | error thrown to caller | `LastSyncError` in `/api/server/status` `sync.diagnostics` | ✅ equivalent |
| WAL/SHM change awareness | inode-keyed file watch + dir watch + 5 s fallback poll | `runDBMtimeSyncLoop` watches `chat.db`/`-wal`/`-shm` mtimes (750 ms) + coalescing SyncEngine + bounded date-lookback | ✅ equivalent in effect |

## Remaining differences (intentional or minor)

1. **Watcher granularity.** IMSG arms `DispatchSource` file watches keyed on
   `(st_dev, st_ino)` and also watches the **containing directory**, so it
   re-arms instantly when a WAL checkpoint recreates `-wal`/`-shm` (new inode).
   MicaGo polls the three files' **mtimes** every 750 ms instead. Functionally
   equivalent for "something changed → re-read", but MicaGo does not watch the
   directory and does not track inodes. Not a correctness gap for reads (every
   read now opens WAL-aware and gets a consistent snapshot); it is only a
   latency/al­ternate-mechanism difference. Left as-is — no evidence it causes
   missed updates given the date-lookback union re-scan.

2. **Malformed recovery scope.** IMSG does **not** handle
   `database disk image is malformed` at all (documented honestly in the study).
   MicaGo now adds recovery only for the DB it **owns** — `relay.db` is moved
   aside (`relay.db.corrupt-<ts>`, plus `-wal`/`-shm`) and rebuilt
   (`internal/relaydb/db.go Open` → `isCorruptionError` / `quarantineCorruptDB`).
   MicaGo deliberately does **not** do this for Apple `chat.db`: a transient
   malformed read there is now extremely unlikely (immutable removed), and if one
   occurs it is logged + retried, never repaired/moved/deleted. This is a
   superset of the reference, scoped to MicaGo-owned state only.

3. **Architecture (unchanged, by design).** IMSG is a single read-only
   connection serialized on one `DispatchQueue`, driven request-at-a-time;
   imsgweb spawns `imsg rpc` and never opens the DB. MicaGo keeps its Go
   relay-cache model: one chat.db reader (the sync `store.Queries`) feeds
   `relay.db`, which clients read over REST/WS. This is the C12 single-canonical
   path and is not changed here.

4. **Concurrency model.** IMSG funnels all chat.db access through one serial
   queue. MicaGo relies on `database/sql`'s connection pool over a `mode=ro`
   DSN. Reads are independent and WAL-consistent, so serialization is not
   required for correctness; `_busy_timeout` covers any momentary contention.
   Left as-is.

## Net

The one behavioral divergence that produced `database disk image is malformed`
— `immutable=1` — is removed, so MicaGo now opens Apple's chat.db with exactly
IMSG's flags. The remaining differences are either functionally-equivalent
mechanisms (mtime poll vs inode watch) or deliberate, safe supersets
(relay-only corruption recovery), not new competing read paths.
