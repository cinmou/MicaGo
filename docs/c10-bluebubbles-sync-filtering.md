# C10 — BlueBubbles-based sync & noise filtering

## BlueBubbles files inspected
- Server: `packages/server/src/server/databases/imessage/pollers/MessagePoller.ts`
  + `ChatChangePoller.ts` (how BB polls chat.db for new/updated rows and emits
    socket events), `helpers/utils.ts`.
- Client: `lib/database/io/message.dart` (message getters incl. empty/transparent
  checks), `lib/helpers/types/helpers/message_helper.dart` (reaction/empty
  handling), `lib/database/global/chat_messages.dart` (in-memory store; reactions
  kept out of the renderable list).
- Earlier audits: `docs/c7-client-store-architecture-audit.md`,
  `docs/bluebubbles-compatibility-notes.md`.

## What we migrated (conceptually)
- **Reactions are not bubbles.** Like BB's separate `_reactions` map, MicaGo
  classifies tapbacks (`semanticKind=tapback`, `renderRecommendation=merge`) and
  the client merges them onto the target instead of showing standalone rows.
- **Empty/control rows are noise.** BB skips transparent/empty messages; MicaGo's
  server classifier marks empty-text + no-attachment + no-semantic rows, and
  control-like text ("+!"/"+$"), as `sync_noise` (`isDebugOnly=true`).
- **Poll → patch, don't reload.** BB pollers emit per-row socket events that the
  client patches into its store. MicaGo mirrors this: WS events patch the local
  DB + `MessageCollection`; no whole-thread reloads for complete payloads.

## Server filtering (default = renderable)
- `GET /api/chats/{guid}/messages` returns the renderable timeline only
  (drops `isDebugOnly`); `?debug=true` returns the raw timeline.
- `GET /api/chats` hides chats with no renderable content
  (`hasRenderableMessages=false`); `?debug=true` reveals them. Each chat carries
  `latestRenderableAt`, `latestRenderablePreview`, `unsupportedOnly`,
  `hiddenReason` (`empty`/`debug_only`). `is_debug_only` is persisted per relay
  message (computed at sync time) so the chat aggregate is cheap SQL.
- The Message Inspector / `GET /api/debug/recent-messages` still expose
  **everything** (raw). No server data is deleted.

## Chat list hides by default
- chats whose only content is `sync_noise`,
- chats with only debug-only unsupported rows,
- chats with only missing-attachment placeholders that are themselves noise,
- chats with only empty/no-content rows.

Kept visible: chats with any renderable content (incl. unknown contacts),
chats with failed/pending outgoing messages, meaningful service events.

## Thread hides by default
`sync_noise`, debug-only unsupported rows, empty no-content rows. Kept:
failed/pending outgoing, retraction notices, meaningful service events.

## Settings (client, `MessageDisplayPrefs`)
- **Hide unsupported-only chats** — default on (server hides them unless debug).
- **Show debug-only chats** — default off; on ⇒ client requests `?debug=true`.
- **Show hidden chats** — `listChats(includeHidden:true)` (debug).
- **Per-chat hide / always-show** — `LocalCacheStore.setChatHidden` /
  `setChatAlwaysVisible`; persisted in the DB. **Reset** clears the rows.

## Chat sorting (Part I)
Sorted by `latest_renderable_at DESC` (a raw debug/noise row never bumps a chat
because only renderable messages set that column). Failed/pending outgoing
messages have a real `dateCreated` and therefore affect ordering.

## Remaining gaps
- Reply-target backfill (fetch nearby context when the target isn't cached) is
  not implemented; the reply shows "Replying to a message" until the target
  loads.
- Link-preview metadata from the Messages DB is not surfaced (no web scraping,
  by policy).
