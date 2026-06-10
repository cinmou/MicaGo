# C12 — Message pipeline (IMSG-aligned, canonical)

This documents the **single** canonical pipeline that produces MicaGo's
renderable timeline, after the C12 review of `Ref/imsg` + `Ref/imsgweb-main` and
the C12 destructive cleanup. Before C12 there were two competing normal serving
paths (a `relaydb` cache path and a `chatdb` live-read path, switchable by
`--api-store`) plus unfiltered realtime + local-cache ingestion. C12 deleted the
`chatdb` serving path (~418 lines) and its runtime switch, moved renderable
filtering into SQL, and made the realtime feed + Android cache renderable-only.
See `docs/c12-migration-report.md` for the exact deletions. This doc is the
source of truth for "how a row becomes a renderable message."

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

There is exactly one normal read path: chat.db → `store.Queries` **sync methods**
→ `relaydb` → REST/WS. chat.db is read by only two things now — the sync reader
and the Message Inspector (`/api/debug/*`, a separate raw view). Clients never
touch chat.db; they read the classified relay. The relay's normal reads
(`ListChats`/`ListChatMessages`/`ListRecentMessages`) filter noise in SQL and
accept `?debug=true` (legacy alias `?include_empty=true`) to return the raw
timeline for the Inspector.

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

## Realtime & send

- Realtime: `app.SyncEngine` coalesces WAL/SHM mtime triggers and runs a bounded
  date-lookback union (`SyncOnce(ctx, source, relay, limit, lookback)`) so
  edits/retractions/read/delivered on older rows are caught despite a rowid-only
  cursor. New/outgoing rows arrive on the next coalesced tick. **C12: the WS
  `message:new` broadcast and notification dispatch apply
  `FilterRenderableMessages`, so a freshly-synced debug-only/noise row is never
  broadcast or notified** — it cannot enter the normal client thread via
  realtime. Reaction rows survive (merge) so tapbacks reach the client.
- Send: optimistic pending row → AppleScript command result → DB confirmation by
  text+time match replaces the pending row; timeout ≠ final failure; AppleScript
  error = final failure; delivered/read upgrade the same row. (C11 Part F/G.)
- Android cache (`LocalCacheStore`): renderable-only, schema v2 with a
  destructive rebuild on upgrade so pre-C12 noise cannot survive, plus an
  `isDebugOnly` upsert guard (defense-in-depth).

## What is intentionally NOT here
- No push/Firebase in this path (out of scope).
- No request-time RPC-per-read (imsgweb model) — MicaGo uses a relay snapshot by
  design; the relay is the cache + WS fan-out source.
