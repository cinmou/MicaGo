# C12 — Message pipeline (IMSG-aligned, canonical)

This documents the single canonical pipeline that produces MicaGo's renderable
timeline, after the C12 review of `Ref/imsg` + `Ref/imsgweb-main`. The C12 audit
(`docs/c12-imsg-rewrite-audit.md`) concluded the IMSG correctness ideas were
already ported across C7–C11; C12 closes the one remaining divergence
(reaction rows leaking into the chat-list aggregate) rather than rewriting a
working pipeline. This doc is the source of truth for "how a row becomes a
renderable message."

## One reader → relay → clients

```
chat.db (read-only)
  └─ store.queries.go  ──┐  canonical SQL (cmj JOIN + handle, attributedBody,
                         │   semantic columns, message_state for edit/retract)
  store.text.go         ─┤  attributedBody decode (TypedStream → text)
  store.classify.go     ─┤  ClassifyMessageJSON → semanticKind / renderRecommendation
                         │   / isDebugOnly  + IsReactionForSyncRow
                         ▼
  relaydb (SQLite)        upsertMessagesTx persists every row + flags
                         │   is_debug_only, is_reaction, message_state
                         ▼
  app.SyncEngine          coalesced WAL/SHM-watch + bounded date-lookback union
                         ▼
  httpapi  ── REST + WS ──▶ Android (LocalCacheStore) / companion / inspector
```

There is exactly one normal read path: `store` SQL → `relaydb` → REST/WS. The
relay is the only thing the clients read; clients never touch chat.db. The
Message Inspector / `/api/debug/*` reads the **same** relay rows with the
debug flag set, so it can reveal everything (including hidden/noise rows).

## Row classification (the only filter)

`store.ClassifyMessageJSON` assigns each row:
- `semanticKind` — text / attachment / reaction / reply / service-event / edited
  / retracted / unsupported.
- `renderRecommendation` — `show` | `merge` (tapbacks merged onto target) | `hide`.
- `isDebugOnly` — true for sync-artifact / placeholder / empty / unsupported-only
  rows. These never enter the renderable timeline.

Two persisted booleans drive the chat list aggregate:
- `is_debug_only` — excluded from renderable count, ordering, and preview.
- `is_reaction` (C12, new) — a tapback (`associated_message_type` in 2000–3006
  **and** a non-empty target GUID, per `IsReactionForSyncRow`). Excluded from the
  chat-list renderable count / `latest_at` / `latest_text` so a reaction never
  bumps a chat to the top or becomes its preview — matching IMSG, where reaction
  rows are folded into the target and never appear in the message list. The row
  is still synced so the client can merge the tapback chip onto its target.

`FilterRenderableMessages` (drop `isDebugOnly`) is the single renderable filter.
A chat with content but zero renderable, non-reaction rows is
`unsupportedOnly = true` and hidden by default; debug mode reveals it.

## Ordering & preview

`relaydb.ListChats` orders by `COALESCE(latest_at, 0) DESC` where `latest_at` /
`latest_text` come from the newest row that is **not** debug-only and **not** a
reaction. So ordering and preview both reflect the latest *renderable* message,
never a tapback or a sync artifact.

## Realtime & send (unchanged in C12, documented for completeness)

- Realtime: `app.SyncEngine` coalesces WAL/SHM mtime triggers and runs a bounded
  date-lookback union (`SyncOnce(ctx, source, relay, limit, lookback)`) so
  edits/retractions/read/delivered on older rows are caught despite a rowid-only
  cursor. New/outgoing rows arrive on the next coalesced tick.
- Send: optimistic pending row → AppleScript command result → DB confirmation by
  text+time match replaces the pending row; timeout ≠ final failure; AppleScript
  error = final failure; delivered/read upgrade the same row. (C11 Part F/G.)

## What is intentionally NOT here
- No push/Firebase in this path (out of scope).
- No request-time RPC-per-read (imsgweb model) — MicaGo uses a relay snapshot by
  design; the relay is the cache + WS fan-out source.
