# C12 — IMSG + imsgweb audit

Reference projects read under `Ref/imsg` (Swift chat.db reader/CLI/RPC) and
`Ref/imsgweb-main` (TypeScript web UI that drives `imsg` over RPC).

## IMSG files inspected
- `Sources/IMsgCore/MessageStore+Queries.swift` — `ChatMessagesQuery`,
  `MessagesAfterQuery`, `LatestSentMessageQuery` (the canonical SQL).
- `Sources/IMsgCore/MessageStore+Messages.swift` — `messages(chatID:limit:)`,
  `messagesAfter(...)`, `decodeMessageRow(...)`, URL-preview coalescing.
- `Sources/IMsgCore/MessageStore+MessageRows.swift` — `MessageRowSelection`,
  `DecodedMessageRow`, column list.
- `Sources/IMsgCore/MessageStore+Chats.swift` — chats query (`last_date`),
  participants join.
- `Sources/IMsgCore/MessageStore+Attachments.swift`, `AttachmentDisplay.swift` —
  attachment metadata + kind.
- `Sources/IMsgCore/TypedStreamParser.swift` — `parseAttributedBody(_:)`.
- `Sources/IMsgCore/MessageWatcher.swift` — fsevents + fallback poll watcher.
- `Sources/IMsgCore/MessageFilter.swift` — participant/date filter (not a noise filter).

## imsgweb files inspected
- `server/index.ts` — `/chats`, `/chats/:id/messages`, SSE `watch`, `/messages`
  send; drives `imsg` over RPC (`rpc.call("chats.list" | "messages.history")`).
- `server/attachments.ts` — converted-attachment cache
  (`~/Library/Caches/imsg/converted-attachments`, name = hash of size+mtime).
- `web/model.ts` — `applyReactionEvent` (reaction rows mutate the target's
  `reactions`, never inserted into the list); message normalisation.
- `web/components/{MessageList,MessageBubble,ChatList}.svelte` — rendering.

## IMSG answers
1. **Opens chat.db** read-only via SQLite.swift against
   `~/Library/Messages/chat.db` (the `MessageStore` + `MessageStoreSchema`
   probe optional columns like `attributedBody`, reaction columns,
   `destination_caller_id`).
2. **SQL queries** (`MessageStore+Queries.swift`):
   - messages (per chat): `SELECT … FROM message m JOIN chat_message_join cmj
     ON m.ROWID=cmj.message_id LEFT JOIN handle h ON m.handle_id=h.ROWID
     WHERE cmj.chat_id=? <reactionFilter> ORDER BY m.date DESC LIMIT ?`.
   - messages-after (watch): same joins, `WHERE m.ROWID > ? <reactionFilter>
     [AND cmj.chat_id=?] ORDER BY m.ROWID ASC LIMIT ?`.
   - chats: `SELECT c.ROWID, IFNULL(c.display_name,c.chat_identifier) AS name,
     … , <last message date> AS last_date FROM chat c … ORDER BY last_date DESC`.
   - handles: `SELECT h.id FROM chat_handle_join chj … WHERE chj.chat_id=?`.
   - attachments via `message_attachment_join` (see `+Attachments.swift`).
3. **Avoids noise** by: (a) an inline **reaction filter**
   `(m.associated_message_type IS NULL OR <2000 OR >3006)` so tapback rows are
   excluded from the message list; (b) **coalescing URL-preview balloons** into
   the preceding text message; (c) resolving `attributedBody` so "text-empty"
   rows are not actually empty. It does **not** hard-drop every empty row.
4. **Text extraction** (`decodeMessageRow`):
   `resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text`
   — DB `text` first, else decode the `attributedBody` typedstream.
5. **Handling**: attachments via join (kind from UTI/MIME in
   `AttachmentDisplay`); replies via `thread_originator_guid`/`reply_to_guid`;
   reactions via `associated_message_type`/`associated_guid` (filtered out of the
   list, surfaced as events); edited/retracted via date_edited/date_retracted +
   `message_summary_info`; group/service via `item_type`/`group_action_type`;
   links via `payload_data`/URL-preview balloon coalescing.
6. **New messages**: `messagesAfter(afterRowID:)` with a `ROWID > cursor` cursor.
7. **Watch strategy** (`MessageWatcher`): **fsevents-style file watch** with a
   `debounceInterval` (0.25 s) **and** a `fallbackPollInterval` (5 s);
   request-time fresh reads otherwise. Cursor = max ROWID.
8. **Return shape**: a `Message` value (rowID, guid, sender, text, date,
   isFromMe, service, attachments, associated*, threadOriginator*, reply, body,
   poll, …) — newest-first from the query; the web reverses to oldest→newest.
9. **Why no empty-message problem**: attributedBody is always decoded, reactions
   are filtered out of the list, and URL-preview balloons are coalesced — so the
   list contains real content, not protocol rows.

## imsgweb answers
1. **Calls IMSG** as a single long-lived RPC child over stdio
   (`server/rpc`), `rpc.call("chats.list"|"messages.history")`, `rpc.watch(...)`.
2. **Message list**: `/chats/:id/messages` → `messages.history` (newest-first),
   sorted ascending by `id`, mapped to API messages.
3. **Attachments/images**: `server/attachments.ts` serves originals + **converted
   previews** (cached by content hash) so the browser never decodes TIFF/HEIC.
4. **Hide noise**: relies on IMSG's reaction filter + attributedBody decode;
   reaction events mutate the target's `reactions` and are **never inserted**.
5. **Replies/reactions/edited/deleted**: replies rendered with quoted target;
   reactions aggregated onto the target message; edited/retracted from message
   fields.
6. **Ordering**: chats by `last_date DESC`; messages ascending by id.
7. **Assumptions MicaGo should adopt**: a clean renderable list (no reaction
   rows), attributedBody-resolved text, converted-preview attachments, chat list
   ordered by last renderable message, watch = file-change + fallback poll.

## Mapping: IMSG concept → MicaGo

| IMSG concept | IMSG file/function | MicaGo equivalent | Keep/Replace/Delete | Migration plan |
| --- | --- | --- | --- | --- |
| Message SQL (cmj join + handle) | `ChatMessagesQuery` | `store/queries.go buildSyncMessagesSQL` + `chatMessagesBaseSQL` | **Keep** (equivalent join) | none — already matches |
| attributedBody decode | `TypedStreamParser.parseAttributedBody` | `store/text.go ExtractMessageText`/`decodeAttributedBodyText` | **Keep** | already ported (C-prior) |
| Reaction filter in list | `reactionFilter` in query | client-side merge (`thread_presentation` + `renderRecommendation=merge`) | **Keep** (MicaGo merges client-side; chips need the rows) | document divergence |
| Empty-row avoidance | attributedBody + reaction filter | `ClassifyMessageJSON`→`isDebugOnly` + `FilterRenderableMessages` | **Keep** | already realizes the intent |
| Chats by last_date | `MessageStore+Chats` | relay `ListChats` `latest_renderable_at DESC` | **Keep** | already matches |
| Attachment preview/convert | `server/attachments.ts` | C9 preview endpoint + `needsPreviewConversion`/`previewUrl` | **Keep** | already ported |
| Watch (fsevents + fallback poll) | `MessageWatcher` | C11 WAL/SHM mtime poll (750 ms) + SyncEngine + date-lookback | **Keep** | equivalent; MicaGo adds rowid-race recovery |
| ROWID-after cursor | `MessagesAfterQuery` | relay `last_message_rowid` + C11 date-lookback union | **Keep** | already hardened |
| Request-time RPC reads | imsgweb `rpc.call` | MicaGo relay snapshot + REST | **Keep** (relay model) | architecture choice differs intentionally |

**Conclusion:** the IMSG/imsgweb correctness ideas (attributedBody decode,
reaction handling, renderable-only list, preview conversion, file-watch +
fallback poll, last-message ordering) were already ported into MicaGo across
C7–C11. IMSG is Swift; MicaGo is Go with a relay+WS architecture, so the
migration is conceptual, and the concepts are present. See
`docs/c12-migration-report.md` for the deletion assessment.
