# chat.db Read Analysis

Scope: only how BlueBubbles Server reads macOS Messages `chat.db`, starting from `packages/server/src/server/databases/imessage/index.ts` and `MessageRepository`.

## 1. How the `chat.db` path is determined

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.constructor` | `not found` | `dbPath`, `dbPathWal`, `process.env.HOME` | The repository hardcodes the Messages database path as `${HOME}/Library/Messages/chat.db` and also records `${HOME}/Library/Messages/chat.db-wal`. | Yes |

## 2. How the SQLite/TypeORM connection is initialized

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.initialize` | `chat`, `handle`, `message`, `attachment` | `name`, `type`, `database`, `entities` | BlueBubbles creates a TypeORM `DataSource` using the `better-sqlite3` driver pointed at `dbPath` and maps only the `Chat`, `Handle`, `Message`, and `Attachment` entities. | Yes |

## 3. How `getChats` works

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getChats` | `chat`, `chat_handle_join`, `handle`, `chat_message_join`, `message` | `chat.guid`, `chat.is_archived`, `chat.ROWID`, `message.ROWID` | `getChats` starts from `chat`, optionally joins participants and/or messages, optionally filters archived chats and `guid`, applies caller-provided extra predicates, and returns paginated results ordered by a chosen column. | Yes |
| `packages/server/src/server/databases/imessage/entity/Chat.ts` | `Chat` | `chat`, `chat_handle_join`, `chat_message_join` | `ROWID`, `guid`, `service_name`, `is_archived`, `last_read_message_timestamp` | The `Chat` entity defines the join shape: `chat_handle_join` links chats to participants and `chat_message_join` links chats to messages. | Yes |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getChats` | `chat`, `message` | `chat.guid`, `message.ROWID` | When `withLastMessage` is true, it left-joins messages, groups by `chat.guid`, and uses `HAVING message.ROWID = MAX(message.ROWID)` to approximate “last message per chat.” | Maybe |

## 4. How `getMessages` works

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getMessages` | `message`, `handle`, `message_attachment_join`, `attachment`, `chat_message_join`, `chat`, `chat_handle_join` | `message.date`, `message.guid`, `chat.guid`, `message.ROWID` | `getMessages` starts from `message`, always left-joins the sender `handle`, optionally joins attachments, optionally joins chats, optionally joins chat participants, applies custom `where` clauses and date bounds, then paginates and orders. | Yes |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.applyMessageDateQuery` | `message` | `message.date` | Date filtering in `getMessages` is applied only against the raw `message.date` column, using converted Apple-epoch timestamps. | Yes |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getMessagesRaw` | `message`, `handle`, `attachment`, `chat` | `getQueryAndParameters` | BlueBubbles also has a raw-SQL variant that builds the same TypeORM query and then executes the generated SQL directly. | No |

## 5. How `getMessage` works

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getMessage` | `message`, `handle`, `chat_message_join`, `chat`, `message_attachment_join`, `attachment` | `message.guid`, `message.ROWID`, `handle_id`, `attachment_id`, `chat_id` | `getMessage` fetches one message by exact `message.guid`, always joins its sender handle, and optionally joins its chats and attachments. | Yes |

## 6. How `getAttachment` works

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getAttachment` | `attachment`, `message_attachment_join`, `message` | `attachment.guid`, `attachment.original_guid` | `getAttachment` queries `attachment` by GUID, optionally also joins back to messages, and on High Sierra+ searches both `original_guid` and `guid` because attachment identifiers can be prefixed. | Maybe |
| `packages/server/src/server/databases/imessage/entity/Attachment.ts` | `Attachment` | `attachment`, `message_attachment_join` | `guid`, `original_guid`, `filename`, `mime_type`, `transfer_name` | The entity maps attachment metadata and the many-to-many relation to messages via `message_attachment_join`. | Yes |

## 7. Which macOS Messages tables are used

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/entity/Chat.ts` | `Chat` | `chat`, `chat_handle_join`, `chat_message_join` | `ROWID`, `guid`, `service_name`, `chat_identifier`, `is_archived` | The chat entity reads the main chat row and its participant/message join tables. | Yes |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message` | `message`, `chat_message_join`, `message_attachment_join` | `ROWID`, `guid`, `text`, `service`, `date`, `handle_id`, `is_from_me` | The message entity maps the main message table and joins to chats and attachments. | Yes |
| `packages/server/src/server/databases/imessage/entity/Handle.ts` | `Handle` | `handle`, `chat_handle_join` | `ROWID`, `id`, `service`, `uncanonicalized_id` | The handle entity maps sender/participant identities and their chat membership join table. | Yes |
| `packages/server/src/server/databases/imessage/entity/Attachment.ts` | `Attachment` | `attachment`, `message_attachment_join` | `ROWID`, `guid`, `filename`, `mime_type`, `transfer_name`, `original_guid` | The attachment entity maps attachment metadata and the message linkage join table. | Yes |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getParticipantOrder` | `chat_handle_join` | `chat_id`, `handle_id` | There is also one direct raw query against `chat_handle_join` to preserve participant insertion order. | No |

## 8. How `chat`, `message`, `handle`, `chat_message_join`, `chat_handle_join`, `attachment`, and `message_attachment_join` are joined

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/entity/Chat.ts` | `Chat.participants` | `chat`, `chat_handle_join`, `handle` | `chat_handle_join.chat_id`, `chat_handle_join.handle_id`, `chat.ROWID`, `handle.ROWID` | Chat participants are modeled as `chat` many-to-many `handle` through `chat_handle_join`. | Yes |
| `packages/server/src/server/databases/imessage/entity/Chat.ts` | `Chat.messages` | `chat`, `chat_message_join`, `message` | `chat_message_join.chat_id`, `chat_message_join.message_id`, `chat.ROWID`, `message.ROWID` | Chat messages are modeled as `chat` many-to-many `message` through `chat_message_join`. | Yes |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message.handle` | `message`, `handle` | `message.handle_id`, `handle.ROWID` | Each message joins to one sender handle with `message.handle_id -> handle.ROWID`. | Yes |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message.chats` | `message`, `chat_message_join`, `chat` | `chat_message_join.message_id`, `chat_message_join.chat_id`, `message.ROWID`, `chat.ROWID` | Message-to-chat linkage is modeled as the inverse many-to-many through `chat_message_join`. | Yes |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message.attachments` | `message`, `message_attachment_join`, `attachment` | `message_attachment_join.message_id`, `message_attachment_join.attachment_id`, `message.ROWID`, `attachment.ROWID` | Message attachments are modeled as many-to-many through `message_attachment_join`. | Yes |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getMessage` | `message`, `message_attachment_join`, `attachment` | `message.ROWID = message_attachment.message_id`, `attachment.ROWID = message_attachment.attachment_id` | `getMessage` uses an explicit join condition for attachments instead of relying only on the decorator metadata. | Yes |

## 9. How timestamps are converted

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/transformers/MessagesDateTransformer.ts` | `MessagesDateTransformer` | `message`, `chat`, `attachment` | mapped date columns | BlueBubbles uses a TypeORM value transformer to convert database timestamps to JS `Date` on read and back to Apple epoch on write. | Yes |
| `packages/server/src/server/databases/imessage/helpers/dateUtil.ts` | `getDateUsing2001`, `convertDateTo2001Time`, `get2001Time` | `message`, `chat`, `attachment` | Apple epoch values such as `date`, `date_read`, `created_date` | Apple timestamps are treated as time since `2001-01-01 00:00:00 UTC`; on macOS 10.13+ the code assumes microseconds and divides by `10^6`, otherwise it assumes seconds and multiplies by `1000`. | Yes |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message` | `message` | `date`, `date_read`, `date_delivered`, `date_played`, `date_retracted`, `date_edited`, `time_expressive_send_played` | Message date-like fields are all mapped through `MessagesDateTransformer`. | Yes |
| `packages/server/src/server/databases/imessage/entity/Chat.ts` | `Chat` | `chat` | `last_read_message_timestamp` | Chat-level read marker timestamps are also mapped through `MessagesDateTransformer`. | Maybe |
| `packages/server/src/server/databases/imessage/entity/Attachment.ts` | `Attachment` | `attachment` | `created_date`, `start_date` | Attachment timestamps are also converted through the same transformer. | No |

## 10. How incoming/outgoing direction is determined

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message` | `message` | `is_from_me`, `handle_id` | Message direction is read from `message.is_from_me`, with the sender handle also available through `handle_id`. | Yes |
| `packages/server/src/server/databases/imessage/entity/Attachment.ts` | `Attachment` | `attachment` | `is_outgoing` | Attachments also carry their own `is_outgoing` flag. | Maybe |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getMessageCount` | `message` | `is_from_me` | For counts, BlueBubbles filters outgoing messages by `message.is_from_me = 1`. | Maybe |

## 11. How service type is handled, such as iMessage vs SMS

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/entity/Chat.ts` | `Chat` | `chat` | `service_name` | Chat rows expose `chat.service_name`, which is the main chat-level service discriminator. | Yes |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message` | `message` | `service`, `account`, `account_guid`, `service_center` | Message rows also expose per-message service fields, including `message.service`. | Yes |
| `packages/server/src/server/databases/imessage/entity/Handle.ts` | `Handle` | `handle` | `service` | Handles expose a `service` field too. | Maybe |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getiMessageAccount` | `chat` | `service_name`, `account_login` | The repository explicitly queries `chat.service_name = 'iMessage'` when looking up the iMessage account login. | No |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getChats`, `getMessages`, `getMessage` | `not found` | `not found` | There is no built-in repository filter that limits reads to only iMessage or only SMS; service-type filtering is left to callers. | Yes |

## 12. How deleted, hidden, empty, or special messages are filtered

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getChats` | `chat` | `is_archived` | The only built-in chat filter here is optional exclusion of archived chats via `chat.is_archived == 0` when `withArchived` is false. | Yes |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.getMessages`, `getMessage`, `getAttachment` | `not found` | `not found` | These repository read methods do not hardcode filters for deleted, hidden, empty, spam, corrupt, service, or system messages. | Yes |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message` | `message` | `is_empty`, `is_system_message`, `is_service_message`, `is_spam`, `is_corrupt`, `is_archive`, `item_type`, `group_action_type`, `associated_message_guid`, `associated_message_type`, `balloon_bundle_id` | BlueBubbles maps many “special message” fields from `message`, but reading them is separate from filtering them. | Maybe |
| `packages/server/src/server/databases/imessage/entity/Attachment.ts` | `Attachment` | `attachment` | `hide_attachment` | Hidden attachments are represented by a field on the attachment row, but repository reads do not filter them out. | Maybe |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message` | `message` | `deleted` | A dedicated deleted-message field is not found in the mapped entity or repository query logic. | No |

## 13. How read/unread fields are handled, if present

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message` | `message` | `is_read`, `date_read`, `date_delivered`, `is_delivered`, `is_sent` | Message read/delivery state is read directly from the mapped columns and exposed on the message entity. | Yes |
| `packages/server/src/server/databases/imessage/entity/Chat.ts` | `Chat` | `chat` | `last_read_message_timestamp` | Chats also expose a last-read timestamp field, gated to High Sierra+. | Maybe |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.applyMessageUpdateDateQuery` | `message` | `date_delivered`, `date_read`, `date_edited`, `date_retracted` | When fetching “updated” messages, BlueBubbles treats delivery, read, edited, and retracted timestamps as update signals. | No |

## 14. How attachments are represented in message results

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message.attachments` | `message_attachment_join`, `attachment` | `message_id`, `attachment_id` | At the repository level, attachments are represented as a `Message.attachments: Attachment[]` relation populated only when attachment joins are requested. | Yes |
| `packages/server/src/server/databases/imessage/entity/Attachment.ts` | `Attachment` | `attachment` | `guid`, `filename`, `uti`, `mime_type`, `transfer_name`, `total_bytes`, `original_guid` | Each attachment row carries the file path and display metadata needed to expose downloadable media. | Yes |
| `packages/server/src/server/api/serializers/MessageSerializer.ts` | `MessageSerializer.convert` | `message`, `attachment` | `attachments` | When serialized for API output, message results include an `attachments` array produced from `message.attachments ?? []`. | Maybe |
| `packages/server/src/server/api/serializers/AttachmentSerializer.ts` | `AttachmentSerializer.convert` | `attachment` | `guid`, `uti`, `mimeType`, `transferName`, `totalBytes`, `transferState`, `isOutgoing`, `hideAttachment`, `originalGuid` | Attachment serialization keeps the DB-backed metadata and can optionally add file data and derived metadata. | No |

## 15. Which parts are actually needed for a minimal Go v0.1 implementation

| Exact file path | Function/class | Relevant table names | Relevant field names | One short explanation | Need in Go v0.1 |
| --- | --- | --- | --- | --- | --- |
| `packages/server/src/server/databases/imessage/index.ts` | `MessageRepository.constructor`, `initialize` | `not found` | `dbPath` | A Go version needs only the fixed DB path resolution and a read-only SQLite connection. | Yes |
| `packages/server/src/server/databases/imessage/entity/Chat.ts` | `Chat` | `chat`, `chat_handle_join`, `handle` | `ROWID`, `guid`, `chat_identifier`, `service_name`, `display_name`, `is_archived` | Minimal chat listing only needs chat identity, service, label, archive state, and optionally participants. | Yes |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message` | `message` | `ROWID`, `guid`, `text`, `attributedBody`, `service`, `date`, `is_from_me`, `is_read`, `handle_id`, `cache_has_attachments` | Minimal message reading needs identity, text fallback, timestamp, direction, read state, and whether attachments may exist. | Yes |
| `packages/server/src/server/databases/imessage/entity/Handle.ts` | `Handle` | `handle` | `ROWID`, `id`, `service` | Minimal sender/participant support only needs the handle identifier and maybe service. | Yes |
| `packages/server/src/server/databases/imessage/entity/Attachment.ts` | `Attachment` | `attachment`, `message_attachment_join` | `ROWID`, `guid`, `filename`, `mime_type`, `transfer_name`, `total_bytes` | Minimal attachment support only needs enough metadata to locate and label a file. | Yes |
| `packages/server/src/server/databases/imessage/helpers/dateUtil.ts` | `getDateUsing2001` | `message`, `chat`, `attachment` | Apple epoch values | Timestamp conversion is mandatory because raw values in `chat.db` are not Unix milliseconds. | Yes |
| `packages/server/src/server/databases/imessage/entity/Message.ts` | `Message` | `message` | Ventura-only and rich-message fields such as `message_summary_info`, `payload_data`, `balloon_bundle_id`, `date_edited`, `date_retracted` | Rich-message and post-send status fields can be deferred for a minimal read-only Go backend. | No |

## Minimal Go v0.1 plan

### Minimal Chat struct

```go
type Chat struct {
    RowID          int64
    GUID           string
    ChatIdentifier string
    ServiceName    string
    DisplayName    *string
    IsArchived     bool
}
```

### Minimal Message struct

```go
type Message struct {
    RowID              int64
    GUID               string
    Text               *string
    Subject            *string
    Service            *string
    DateCreated        time.Time
    DateRead           *time.Time
    DateDelivered      *time.Time
    IsFromMe           bool
    IsRead             bool
    IsDelivered        bool
    HandleID           *int64
    CacheHasAttachments bool
}
```

### Minimal Attachment struct

```go
type Attachment struct {
    RowID        int64
    GUID         string
    FileName     string
    MimeType     *string
    UTI          string
    TransferName string
    TotalBytes   int64
}
```

### SQL query for recent messages

```sql
SELECT
  m.ROWID,
  m.guid,
  m.text,
  m.subject,
  m.service,
  m.date,
  m.date_read,
  m.date_delivered,
  m.is_from_me,
  m.is_read,
  m.is_delivered,
  m.handle_id,
  m.cache_has_attachments,
  h.id AS handle_id_value,
  h.service AS handle_service
FROM message AS m
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
ORDER BY m.date DESC
LIMIT ? OFFSET ?;
```

### SQL query for chat list

```sql
SELECT
  c.ROWID,
  c.guid,
  c.chat_identifier,
  c.service_name,
  c.display_name,
  c.is_archived
FROM chat AS c
WHERE (? = 1 OR c.is_archived = 0)
ORDER BY c.ROWID DESC
LIMIT ? OFFSET ?;
```

If you want participants too:

```sql
SELECT
  c.ROWID AS chat_rowid,
  c.guid AS chat_guid,
  h.ROWID AS handle_rowid,
  h.id AS handle_value,
  h.service AS handle_service
FROM chat AS c
JOIN chat_handle_join AS chj
  ON chj.chat_id = c.ROWID
JOIN handle AS h
  ON h.ROWID = chj.handle_id
WHERE c.guid = ?
ORDER BY chj.rowid;
```

`chj.rowid` is a practical choice if present in the SQLite table; BlueBubbles itself does not rely on a declared primary key here and falls back to raw-table ordering logic.

### SQL query for messages in one chat

```sql
SELECT
  m.ROWID,
  m.guid,
  m.text,
  m.subject,
  m.service,
  m.date,
  m.date_read,
  m.date_delivered,
  m.is_from_me,
  m.is_read,
  m.is_delivered,
  m.handle_id,
  m.cache_has_attachments,
  h.id AS handle_id_value,
  h.service AS handle_service
FROM message AS m
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
WHERE c.guid = ?
ORDER BY m.date DESC
LIMIT ? OFFSET ?;
```

### SQL query for attachments of one message

```sql
SELECT
  a.ROWID,
  a.guid,
  a.filename,
  a.uti,
  a.mime_type,
  a.transfer_name,
  a.total_bytes,
  a.is_outgoing,
  a.hide_attachment,
  a.original_guid
FROM attachment AS a
JOIN message_attachment_join AS maj
  ON maj.attachment_id = a.ROWID
WHERE maj.message_id = ?;
```

### Notes about timestamp conversion

- `message.date`, `message.date_read`, `message.date_delivered`, `chat.last_read_message_timestamp`, `attachment.created_date`, and similar fields are not Unix milliseconds.
- BlueBubbles treats them as Apple epoch values relative to `2001-01-01 00:00:00 UTC`.
- On macOS 10.13 and newer, BlueBubbles divides the stored value by `1_000_000` before adding it to the 2001 epoch in milliseconds.
- On older systems, BlueBubbles treats the stored value as seconds and multiplies by `1000`.
- For Go v0.1, the practical conversion is: `time.UnixMilli(appleEpochMillis + raw/1_000_000)` for modern `chat.db` files.
