# C15 — IMSG chat.db open + error handling (reference study)

Goal: before touching MicaGo, understand exactly how the working reference
(`Ref/imsg`, `Ref/imsgweb-main`) opens `~/Library/Messages/chat.db` and handles
read/WAL/error conditions, so the fix for `database disk image is malformed`
follows the reference instead of guessing.

## Exact files / symbols read

IMSG (`Ref/imsg`):
- `Sources/IMsgCore/MessageStore.swift` — `init(path:)` (the real DB open),
  `withConnection`, the serial `imsg.db` `DispatchQueue`.
- `Sources/IMsgCore/MessageStore+Helpers.swift` — `enhance(error:path:)`
  (error mapping), `tableColumns` (PRAGMA table_info probing).
- `Sources/IMsgCore/Errors.swift` — `IMsgError` cases.
- `Sources/IMsgCore/MessageWatcher.swift` — `WatchState`: `watchedFilePaths`,
  `watchDirectoryPath`, `refreshFileSources`, `installDirectorySource`,
  `fileIdentity`, `makeSource`, `poll`, `scheduleFallbackPoll`.

imsgweb (`Ref/imsgweb-main`):
- `server/rpc/index.ts` — `spawnRpcProcess`, `defaultCmd` (`["imsg","rpc"]`),
  `RpcClient`. imsgweb never opens chat.db; it spawns `imsg rpc` and speaks
  JSON-RPC. The DB open is entirely IMSG's.

## 1–2. How IMSG opens chat.db (flags)

`MessageStore.init` (MessageStore.swift:34-42):

```swift
let uri = URL(fileURLWithPath: normalized).absoluteString
let location = Connection.Location.uri(uri, parameters: [.mode(.readOnly)])
self.connection = try Connection(location, readonly: true)
self.connection.busyTimeout = 5
```

- **read-only** via SQLite URI `mode=ro` + `readonly: true`.
- **`busyTimeout = 5` seconds** — waits out `SQLITE_BUSY`/locked instead of
  failing immediately.
- **No `immutable=1`.** This is the critical detail. `mode=ro` is *WAL-aware*:
  SQLite still reads `-wal`/`-shm`, coordinates with the writer via the shared
  memory index, and returns a consistent committed snapshot. `immutable=1` would
  tell SQLite the file can never change, so it skips locking **and ignores the
  WAL**, reading raw pages from the main file — which, while Messages.app is
  mid-write/mid-checkpoint, yields torn pages → `database disk image is
  malformed`.
- All access is serialized on one `DispatchQueue` (`imsg.db`); a single
  connection, never concurrent.

## 3. WAL / SHM handling

- The open is plain `mode=ro`, so the WAL is consulted automatically; IMSG does
  not set journal mode (that would be a write to Apple's DB) and never
  checkpoints.
- The **watcher** explicitly tracks all three files —
  `[store.path, store.path + "-wal", store.path + "-shm"]`
  (MessageWatcher.swift:137) — plus the **containing directory**
  (`watchDirectoryPath` / `installDirectorySource`).
- `refreshFileSources` re-`stat`s each file and keys the dispatch source on
  `(st_dev, st_ino)` (`FileWatchIdentity`). When a WAL checkpoint or atomic
  replace recreates `-wal`/`-shm` (new inode), it cancels the stale source and
  re-installs on the new file. Watching the directory catches create/rename of
  files that don't exist yet. This is how IMSG survives Messages.app's
  checkpointing without reopening the SQLite connection.

## 4. Directory watching

Yes — `watchDirectoryPath` returns the parent of `chat.db` and
`installDirectorySource` installs a `DispatchSourceFileSystemObject` on it
(`.write,.extend,.rename,.delete`), so file (re)creation in
`~/Library/Messages` triggers a poll.

## 5. Retry after read errors

- `WatchState.poll()` (MessageWatcher.swift:236-265): on a thrown DB error it
  calls `continuation.finish(throwing: error)` — i.e. it **ends the watch
  stream** and surfaces the error to the caller. There is **no internal retry**
  of a hard SQLite read error.
- The only retry loop is `yieldDecision`: a row whose chat isn't joined yet
  (`chatID <= 0`) is retried up to 20 times via `schedulePoll()` before being
  skipped — that is a *not-yet-written-row* race, not a corruption retry.
- `scheduleFallbackPoll` re-polls every 5 s regardless, so a *transient*
  condition that didn't throw is naturally re-read on the next tick.

## 6. Busy / locked / malformed

- Busy/locked: handled by `busyTimeout = 5` (waits).
- Malformed/corrupt: **not handled.** `enhance(error:path:)`
  (MessageStore+Helpers.swift:58-66) only maps permission-class strings
  (`out of memory (14)`, `authorization denied`, `unable to open`,
  `cannot open`) to a helpful Full-Disk-Access message. `IMsgError` (Errors.swift)
  has **no** corrupt/malformed case. A malformed read simply ends the stream /
  throws to the caller.
- `tableColumns` (schema probing) swallows PRAGMA errors and returns `[]`, so
  schema detection degrades instead of crashing.

## 7. Integrity checks

None. IMSG never runs `PRAGMA integrity_check`/`quick_check`.

## 8. Repair / writes to Apple chat.db

None. The connection is read-only; IMSG never writes, vacuums, reindexes, or
repairs `chat.db`. (Sending messages goes through AppleScript / the IMCore
bridge, never a DB write.)

## 9. Snapshots while Messages.app is writing

Handled purely by SQLite's WAL read semantics under `mode=ro` + `busyTimeout`
(consistent committed snapshot, wait-on-busy) **plus** the inode-aware
file/dir watcher that re-arms when WAL/SHM are recreated. No app-level locking,
copy, or snapshotting.

## 10. How imsgweb avoids the malformed issue

imsgweb never touches `chat.db`. `server/rpc/index.ts` spawns `imsg rpc`
(`defaultCmd() => ["imsg","rpc"]`) and talks JSON-RPC over stdio. Every DB read
goes through IMSG's WAL-aware `mode=ro` connection, so imsgweb inherits the
correct access pattern for free and never opens the file with the wrong flags.

## What MicaGo currently does differently

`internal/store/db.go`:

```go
dsn := fmt.Sprintf("file:%s?mode=ro&immutable=1&_busy_timeout=5000", path)
```

- **`immutable=1`** — the divergence. Under WAL with Messages.app actively
  writing/checkpointing, immutable makes SQLite ignore the WAL and read raw,
  possibly torn, pages from the main file → `database disk image is malformed`.
  IMSG deliberately does **not** set this.
- `mode=ro` ✅ and `_busy_timeout=5000` ✅ already match IMSG.
- MicaGo already watches `chat.db`/`-wal`/`-shm` mtimes (C11 `runDBMtimeSyncLoop`)
  and has a coalescing SyncEngine + bounded date-lookback, which is the Go
  analogue of IMSG's watcher + fallback poll. It does **not** watch by inode or
  watch the containing directory, but mtime polling already re-reads after
  checkpoints, so that is a smaller gap.

## What to copy into MicaGo

1. **Drop `immutable=1`.** Open chat.db `mode=ro` + `_busy_timeout=5000` only —
   exactly IMSG's flags (WAL-aware, busy-wait). This is the smallest change that
   follows the reference and is the direct fix for the malformed error.
2. **Keep the server alive on a transient chat.db read error.** Like IMSG (which
   ends a stream but the process lives and re-polls), MicaGo's sync loop already
   continues on error and records `LastSyncError` into `/api/server/status`
   diagnostics — that is the degraded-state signal. Do not repair/vacuum/delete
   Apple chat.db.
3. **IMSG does NOT handle `database disk image is malformed`** — stated honestly.
   So for the one DB MicaGo *owns* (`relay.db`, a rebuildable cache), add the
   safest minimal recovery the reference lacks: on a corruption error at open,
   move the file aside (`relay.db.corrupt-<ts>`, plus `-wal`/`-shm`) and rebuild
   fresh. Never applied to Apple `chat.db`.
