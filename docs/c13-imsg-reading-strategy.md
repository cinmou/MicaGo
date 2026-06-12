# C13 IMSG Reading Strategy

Second-pass references read:

- `Ref/imsg/Sources/IMsgCore/MessageStore+Queries.swift`
- `Ref/imsg/Sources/IMsgCore/MessageStore+MessageConstruction.swift`
- `Ref/imsg/Sources/IMsgCore/MessageStore+Attachments.swift`
- `Ref/imsg/Sources/IMsgCore/MessageStore+Helpers.swift`
- `Ref/imsg/Sources/IMsgCore/MessageStore+ServiceAvailability.swift`
- `Ref/imsg/Sources/imsg/Commands/HistoryCommand.swift`
- `Ref/imsgweb-main/server/index.ts`
- `Ref/imsgweb-main/server/preview.ts`
- `Ref/imsgweb-main/server/payloads.ts`
- `Ref/imsgweb-main/server/rpc/types.ts`
- `Ref/imsgweb-main/server/attachments.ts`

| IMSG/imsgweb behavior | file/function/query | MicaGo current behavior | gap | exact migration |
| --- | --- | --- | --- | --- |
| Reads chats from `chat` and exposes `id`, `identifier`, `guid`, `name`, `service`, participants, group state, latest time. | `MessageStore.listChats` as called by `Sources/imsg/Commands/ChatsCommand.swift`; imsgweb calls RPC `chats.list` in `server/index.ts`. | Relay reads `chats` table populated by sync. C12 made this the only normal API path. | Sync source hard-filtered `chat.service_name = 'iMessage'`. | Removed that source filter; relay now stores all chat services and normal API applies server service scope. |
| Reads messages per chat through `chat_message_join`. | `ChatMessagesQuery` in `MessageStore+Queries.swift`: `JOIN chat_message_join cmj ON m.ROWID = cmj.message_id WHERE cmj.chat_id = ? ORDER BY m.date DESC LIMIT ?`. | Initial sync used global latest/date windows. Thread API reads relay only. | Low-activity chats can be starved by busy chats. | Added `ListSyncRecentMessagesForChat` with the same join/order/limit shape and integrated it into hybrid/per-chat initial relay sync. |
| History/backfill is per chat, newest first, with date/participant filters optional. | `HistoryCommand.swift` calls `store.messages(chatID:limit:filter:)`; `ChatMessagesQuery` applies start/end/participants then `ORDER BY m.date DESC LIMIT ?`. | Initial relay sync was global recent plus incremental rowid/date lookback. | Global latest can miss quiet chats. | Server setting: `global_recent`, `per_chat_recent`, `hybrid`; default `hybrid`, 100 per chat. |
| Reaction rows are excluded from history by default. | `ChatMessagesQuery` adds `associated_message_type IS NULL OR < 2000 OR > 3006`; `MessagesAfterQuery` only includes reactions when requested. | C12 stores reaction rows but excludes them from chat-list preview/order and marks them merge. | Normal thread still must not treat reactions as standalone previews. | Kept persisted `is_reaction`; chat-list aggregate excludes it. Debug can still show raw rows. |
| Valid/displayable rows preserve text, attributedBody text, attachments, replies, service events, effects, edited/retracted state. | `MessageStore+MessageConstruction.swift` builds `Message`; `MessageStore+Helpers.swift` decodes reactions/replies; imsgweb `payloads.ts` drops false reply quotes unless `thread_originator_guid` exists. | MicaGo classifies relay messages in `internal/store/classify.go`. | Missing services and global starvation caused valid rows not to enter relay. | Sync now scans all services and per-chat rows; display classification remains relay-backed. |
| SMS/plain rows are supported as services in history/send detection. | `MessageStore+ServiceAvailability.swift` treats handle service `SMS` as SMS; `README.md` documents `--service imessage|sms|auto`. | MicaGo source query excluded SMS chats/messages. | SMS rows could be missing even from relay debug after sync. | Removed hard iMessage source filter; added service category/scope. |
| RCS/non-iMessage services are open-set. | imsgweb `server/rpc/types.ts` says chat service is open set and notes `RCS` appears on newer macOS. IMSG code does not special-case RCS reads beyond reading raw service strings. | MicaGo only parsed `iMessage`, `SMS`, `RCS` in request service filters, but sync excluded non-iMessage. | RCS rows were not reliably scanned. | Categorize exact `RCS` as `rcs`; unknown services hidden by default but visible in debug. |
| Empty/noise rows are avoided by history reaction filtering and imsgweb preview cleaning. | `preview.ts` strips U+FFFC/U+FFFD placeholders; `payloads.ts` labels attachment-only quotes. | MicaGo stores `is_debug_only` and filters normal SQL. | Source sync skipped some rows before classification. | Sync still requires text/attributedBody/attachment flag, but service scope no longer prevents insertion. Debug Inspector reads raw chat.db directly. |
| Attachments are metadata by default. | `MessageStore+Attachments.swift` selects filename, transfer name, UTI, MIME, size, sticker; docs say metadata only. imsgweb `attachments.ts` serves bytes only when URL is requested. | Relay stores attachment metadata and serves `/api/attachments/{guid}` or `/preview` on request. | Bootstrap must not download bytes. | Kept metadata-only sync; Android bootstrap only writes attachment metadata from message JSON. |
| imsgweb display maps RPC payloads into browser API. | `server/index.ts` calls `messages.history` with `attachments: true`; `payloads.ts` rewrites attachment URLs; `preview.ts` labels placeholder-only rows. | Flutter displays relay JSON and attachment URLs. | Some display semantics need future parity for polls/rich app rows. | C13 docs record remaining display gaps; no invented behavior added. |
