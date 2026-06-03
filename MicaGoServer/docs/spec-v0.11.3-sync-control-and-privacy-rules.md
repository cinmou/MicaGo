# v0.11.3 — Sync Control & Privacy Rules

Status: **Planned** (spec only; no code in this pass).

## Goal

Give users control over **which iMessage conversations and handles are synced
into `relay.db` and which generate push** — a privacy/control layer, not a chat
client. Users review recent messages for management, then set per-chat /
per-handle rules (sync allowed/blocked, push enabled/muted).

## Non-goals

No full chat client; no message analytics; no cloud rule storage; no
scripting/DSL rules; **no deletion of historical `relay.db` messages** in the
first version (future sync only) unless an explicit, clearly-labeled user action
is added later.

## Design

### Companion: Sync Control page

A new sidebar destination **Sync Control** (fits the v0.10.1 shell). It contains:
- a **Recent Messages** list (management view only);
- a **Rules** overview (current whitelist/blacklist entries, editable);
- a default-policy selector (see precedence).

### Recent Messages (management, not chat)

- Reuses `GET /api/messages/recent` with a **count picker: 20 / 50 / 100 / 500**
  (maps to `limit`, capped at the server's max of 500).
- Read-only rows: chat label / handle, snippet, timestamp, direction. **No
  composing, no threads, no media gallery.** Selecting a row opens the chat /
  contact detail for rule editing.
- Display only; never used to exfiltrate content anywhere.

### Chat / contact detail page (rule editing)

- Opened from a Recent Messages row or from search. Shows the chat GUID /
  participants and the **effective rule** plus controls to set:
  - **Sync**: allowed / blocked
  - **Push**: enabled / muted
- Scope selector: apply the rule to **this chat** (chat GUID) or to a
  **handle** (phone/email) that may appear across chats.

### Whitelist / blacklist model

A single rules table with an explicit **default policy** plus overrides:
- **Default sync policy**: `allow_all` (default) or `block_all` (allowlist mode).
- **Default push policy**: `enabled` (default) or `muted`.
- **Rules** override the default for a target (chat or handle).

This supports both blacklist (default allow + block specific) and whitelist
(default block + allow specific) without separate tables.

### Per-chat and per-handle rules

- **Target kinds**: `chat` (a `chat.guid`) and `handle` (a normalized
  phone/email address).
- Each rule carries `syncMode` (`allow` | `block` | `inherit`) and `pushMode`
  (`enabled` | `muted` | `inherit`).

### Rule precedence

Most specific wins, evaluated per message:
1. **Chat rule** for the message's chat GUID (if not `inherit`).
2. else **Handle rule** for the message's handle (if not `inherit`).
3. else the **default policy**.

Push is gated by sync: a message that is **not synced cannot push**. Push mode
is only consulted for messages that pass the sync decision.

### How rules affect relay.db sync

- The sync pipeline (`relaydb.SyncOnce` new-message insert, and the v0.11.x
  update pass) consults the rules **before inserting/updating** a message:
  - **sync blocked** → the message is **not inserted** into `relay.db`
    (and not broadcast / not dispatched for push). The rowid watermark
    (`last_message_rowid`) still advances so blocked messages are not re-scanned
    forever.
  - **sync allowed, push muted** → inserted/broadcast as normal but **excluded
    from notification dispatch** (`DispatchNewMessages`).
- The chat list still needs enough metadata to *offer* a rule for a chat the
  user hasn't synced. Two options (decide at implementation):
  (a) keep syncing the lightweight **chat** rows always (chats are not message
  content), and only gate **messages**; or (b) gate chats too. **Recommended:
  always sync chat rows (cheap, lets users pick targets), gate messages.**

### Blocked chats: future-only vs hide/delete existing

- **First version: stop FUTURE sync only. Do NOT delete or hide existing
  `relay.db` rows.** Blocking a chat prevents new inserts/updates and push for
  it; already-synced messages remain until a later, explicit purge feature.
- A future, clearly-labeled **"Remove already-synced messages for this chat"**
  action may be added later (behind confirmation). Out of scope here.

### Required `relay.db` schema changes

New table (additive migration, same `CREATE TABLE IF NOT EXISTS` pattern):

```sql
CREATE TABLE IF NOT EXISTS sync_rules (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  target_kind  TEXT NOT NULL,         -- 'chat' | 'handle'
  target_value TEXT NOT NULL,         -- chat.guid or normalized handle
  sync_mode    TEXT NOT NULL,         -- 'allow' | 'block' | 'inherit'
  push_mode    TEXT NOT NULL,         -- 'enabled' | 'muted' | 'inherit'
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  UNIQUE(target_kind, target_value)
);
```

Default policy stored in the existing `sync_state` table as
`sync_default_policy` (`allow_all` | `block_all`) and `push_default_policy`
(`enabled` | `muted`). No `chat.db` schema changes (read-only source).

### Required Go API endpoints

All under the existing bearer auth:
- `GET /api/sync/rules` → `{ defaultSyncPolicy, defaultPushPolicy, rules: [...] }`.
- `PUT /api/sync/rules` (or `POST`) → set a rule for a target
  (`{ targetKind, targetValue, syncMode, pushMode }`); upsert by target.
- `DELETE /api/sync/rules/{kind}/{value}` → remove a rule (revert to inherit).
- `PUT /api/sync/policy` → set default sync/push policy.
- Rules are evaluated inside the sync/dispatch code paths (not a separate
  filter service). Add a small `internal/relaydb` rule store + an evaluator
  used by `SyncOnce`, the update pass, and `DispatchNewMessages`.

### Required SwiftUI pages

- **Sync Control** sidebar destination: Recent Messages list (count picker),
  default-policy controls, rules overview.
- **Chat/Contact detail** sheet/page: sync + push toggles, scope (chat/handle),
  save/clear.
- Models: `SyncRule`, `SyncPolicy`; an `APIClient` group for the rule endpoints.

### WebSocket / event behavior when rules change

- Changing a rule does **not** retroactively emit or withdraw past events.
- Going forward, blocked chats/handles produce **no** `message:new` /
  `message:update` / `message:unsend` and **no** push.
- Optionally emit a Mica-native `rules:update` event so connected clients can
  refresh their local rule view. (Optional; the companion can also just refetch.)
- Muted (but synced) messages still emit `message:new` over `/ws` (the data is
  in `relay.db`); only **push notification dispatch** is suppressed.

### Privacy model

- Rules are stored **locally** in `relay.db` only; never uploaded anywhere.
- Blocking a chat keeps its **content out of `relay.db`** entirely (strongest
  privacy for that conversation), at the cost of no history for it.
- Recent Messages is a local management view; content is shown only in the
  companion on the same Mac, never logged or transmitted.

## Manual test checklist

1. Sync Control shows recent messages at 20/50/100/500 counts.
2. Block a chat → new messages in it stop appearing in `relay.db` / `/ws`;
   existing rows for it remain (future-only).
3. Mute a chat (sync allowed) → messages still sync and appear over `/ws`, but
   **no push** is dispatched.
4. Whitelist mode (`block_all` default + allow one chat) → only the allowed chat
   syncs.
5. Precedence: a chat `allow` overrides a handle `block` for that chat; a handle
   `block` applies across chats lacking a chat rule.
6. Rules persist across server restart (stored in `relay.db`).
7. Blocked-chat rowid watermark still advances (no infinite re-scan).
8. No rule data leaves the Mac; `go test ./...` green; companion builds.
