# C11 — BlueBubbles chat.db realtime sync audit

Exact files read under `Ref/bluebubbles server/packages/server/src/server`.

## Files inspected
- `lib/MultiFileWatcher.ts` — `MultiFileWatcher` (class): `fs.watch()` per file,
  emits `change` with prev/current `fs.Stats`.
- `databases/imessage/listeners/IMessageListener.ts` — `IMessageListener`:
  `start()`, `getEarliestModifiedDate()`, `handleChangeEvent()`
  (`@DebounceSubsequentWithWait(500)`), `poll(after, emitResults)`; `lastCheck`
  watermark; `processLock = new Sema(1)`.
- `databases/imessage/pollers/MessagePoller.ts` — `MessagePoller.poll(after)`:
  1-week `dateCreated` lookback + JS filter; `unsentIds` tracking;
  `handleGroupChanges`, `handlePreviouslyUnsent`.
- `databases/imessage/pollers/index.ts` — `IMessagePoller.processMessageEvent`
  (new-entry vs updated-entry via dateCreated/Delivered/Read/Edited/Retracted),
  `IMessageCache`.
- `index.ts` (~1270) — wires the listener with
  `filePaths: [dbPath, dbPathWal]` and adds `MessagePoller` + `ChatUpdatePoller`.
- `databases/imessage/index.ts` — `dbPath`, `dbPathWal = …/chat.db-wal`.
- `managers/outgoingMessageManager/messagePromise.ts` — `MessagePromise`
  (timeout 2 min msg / 20 min attachment), `resolve()/reject()`,
  `emitMessageMatch`; poller calls `messageManager.resolve(entry)` for
  `isFromMe` rows.

## Answers
1. **How does it know chat.db changed?** A file watcher (`fs.watch`) on the DB
   files emits a `change` event; that drives the poll. It is **event-driven**,
   not a fixed poll timer.
2. **DB / WAL / SHM / polling?** It watches **`chat.db` and `chat.db-wal`**
   (not SHM) via `MultiFileWatcher`. WAL is the one that changes on every write,
   so WAL is the primary trigger.
3. **How often does it poll?** Only when a watched file changes, **debounced
   500 ms** (`@DebounceSubsequentWithWait`). No constant timer.
4. **Scan by ROWID / date / chat / lookback?** By **`dateCreated` with a 1-week
   lookback** (`afterLookback = after − 7 days`), because `date` is indexed.
   Results are then filtered in JS to the real `after` watermark across
   created/delivered/read/edited/retracted.
5. **How does it avoid missing changed rows?** Two layers: (a) the change
   watermark is rewound **30 s** (`afterTime = prevTime − 30000`, clamped to
   ≤24h) on every change event; (b) the poller's **1-week lookback** re-scans
   recent history each time and re-filters by the mutable date fields — so a row
   whose state changed outside a narrow window is still re-examined.
6. **DB lock / busy?** Reads run on a read-only repo; the `Sema(1)` `processLock`
   guarantees **no overlapping** polls (waiters coalesce with a 100 ms yield).
7. **Delayed outgoing rows after sending?** `MessagePromise` keeps the send
   pending (2-min timeout); the poller keeps scanning and calls
   `messageManager.resolve(entry)` when the matching `isFromMe` row finally
   appears — `unsentIds` also re-checks not-yet-sent rows.
8. **Live socket events?** `IMessageListener.poll` emits per result
   (`new-message`, `updated-message`, group events, read-status) with a 10 ms
   spacing; `Server().emitMessage(...)` pushes to socket clients.
9. **Client receipt?** The Flutter client's `socket_service` → `action_handler`
   patches the in-memory `ChatMessages` struct by guid (insert/update/replace),
   never a full reload (see `docs/c7-client-store-architecture-audit.md`).
10. **What MicaGo should port:** (a) **date-based bounded lookback** for *new*
    message discovery (not ROWID-only) so WAL/rowid races never drop a row;
    (b) **WAL-driven trigger** (we already poll WAL mtime); (c) a **30 s rewind**
    on the new-row watermark; (d) **single non-overlapping, coalescing** sync
    worker; (e) **keep sends pending and re-scan** until the DB row appears.
