# C11 — MicaGo sync failure analysis

Traced `internal/app/app.go`, `internal/relaydb/{sync,updatepass}.go`,
`internal/store/queries.go`.

## Current triggers
- **startup** → `syncAndBroadcast("startup")`.
- **periodic** → `runSyncLoop` every `cfg.SyncInterval` (default 5 s).
- **chatdb_mtime** → `runDBMtimeSyncLoop` polls `chat.db` + `chat.db-wal` mtime
  every 750 ms; syncs when either advances.
- **send** → `SendDependencies.SyncNow` runs one `syncAndBroadcast("send")`.
- **client_request** → `POST /api/sync/now`.
- All run through `runSync`, serialized by `syncMu` (Mutex).

## What each query does
- New messages: `SyncOnce` → `ListSyncRecentMessagesSince(previousLastRowID)`
  (incremental) or `ListSyncRecentMessages(limit)` (initial). **ROWID-only**;
  the `last_message_rowid` watermark advances over the full fetched set.
- Changed messages: `UpdatePass` scans a **date lookback** (`cfg.UpdateLookback`,
  7 days) for mutable state (delivered/read/edited/retracted/error) and updates
  existing rows — it does **not insert brand-new messages**.

## Findings (root causes)
- **What runs sync?** WAL/chat.db mtime change (750 ms), the 5 s timer, send, or
  a client request. So a trigger *exists*; the problem is discovery + coalescing.
- **New rows query:** ROWID-only `> last_message_rowid`. **Bug:** if the
  read-only connection observes a checkpoint/snapshot where the watermark has
  advanced but a row is later materialized, or rows arrive out of ROWID order
  relative to the watermark, the new row is **never re-scanned** — `UpdatePass`
  only updates *existing* rows, so a missed new row is missed permanently until
  a larger ROWID forces nothing (it won't). This is the primary "new messages
  missing/delayed" cause.
- **Changed rows query:** 7-day date lookback — good; updates outside the window
  are missed (acceptable; matches BB-ish).
- **DB locked:** a `SQLITE_BUSY` surfaces as a sync error (recorded), and the
  next trigger retries. **No explicit backoff/retry within a run.**
- **WAL written but chat.db mtime unchanged:** handled — we watch the **WAL**
  mtime too, so a WAL-only write still triggers.
- **WAL checkpoint timing:** not explicitly considered; the ROWID-only new-row
  query is the exposure (see above). A **date-based lookback for new rows** (BB
  style) removes this dependency.
- **Row skipped if watermark advances early?** **Yes** — the core bug above.
- **Updates missed outside lookback?** Yes (7 days), acceptable.
- **Outgoing row after pending expires?** `pendingSends.ReconcileMessages` runs
  on every `syncAndBroadcast` and emits `send:match` for late rows, so late
  outgoing rows *do* reconcile — **but** only if the row is discovered, which
  again depends on the new-row query finding it. **No dedicated send burst**:
  after a send we run one sync; the row often lands seconds later and is only
  caught by the next periodic/mtime trigger.
- **Observable from companion?** Partially — `syncDiagnostics` records trigger,
  duration, counts, mtimes; not yet surfaced as a live monitor with pending /
  lock-retry / SHM, and no "Run sync now"/"Copy diagnostics".
- **Why delayed/missing?** (1) ROWID-only new-row discovery drops rows under
  WAL/rowid races; (2) triggers serialize on `syncMu` (pile-up under bursts);
  (3) no aggressive short burst after send, so the just-sent row waits for the
  next tick.

## Fix (this phase)
- Add a **date-based bounded-lookback new-message scan** (default 7 days) that
  upserts any renderable rows in the window the relay doesn't have — idempotent
  (relay upserts by guid), removing the ROWID-race dependency.
- Replace `syncMu`-serialized triggers with a **coalescing single-worker
  SyncEngine** (pending reason + count; never overlap; never drop).
- Add a **bounded send burst** (short interval for a few seconds after send).
- Add **DB-lock backoff** retries inside a run.
- Surface engine state in the companion live monitor.
