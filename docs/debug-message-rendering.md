# Debugging message rendering (Message Inspector)

When the Android client shows a message as **"Unsupported item"**, renders the
wrong sender, or displays a weird payload (e.g. `+!`), use the companion's
**Message Inspector** to see exactly what the server read from `chat.db`. This
is a read-only debug/power-user tool — not a chat client.

Open it from the companion sidebar: **Message Inspector** (ladybug icon).

It is backed by an authenticated debug endpoint, `GET /api/debug/recent-messages`,
which reads the **live `chat.db`** (so it can show iMessage fields the synced
relay does not keep). The endpoint requires the bearer token, exactly like every
other API route.

## How to find a problematic message

1. Open **Message Inspector**.
2. Type part of the message text, the chat name, the sender handle, or an
   attachment filename into the **search** box and press Return (or **Apply**).
3. Narrow with the filters:
   - **Sender** — All / From me / Unknown sender / Specific handle.
   - **Direction** — All / Incoming / Outgoing.
   - **Type** — text, attachment, image, video, audio, voice, file,
     reaction candidate, reply candidate, service candidate, or **Unsupported**.
   - **Attachments** — has / none / image / audio-voice / unsupported type.
   - **Chat** — limit to one conversation.
   - **Show** — last 20 / 50 / 100 / 500 messages.

To see only the messages that would render badly on the client, set
**Type → Unsupported**.

## Filter by sender / group by sender

- To see everything from one person: set **Sender → Specific handle** and pick
  the handle, **or** set **Group by → Sender**.
- **Group by → Sender** shows one row per handle with: the handle/label, message
  **count**, **unsupported count**, **attachment count**, and the **latest
  timestamp**. This is the fastest way to spot a sender whose messages are mostly
  unsupported.
- Other grouping modes: **Chat**, **Type**, and **Unsupported reason**
  (control-like payload vs. no content vs. other).

## Reading a message row

Each row shows the direction marker, sender, chat, a **sanitized** text preview,
and **type badges** (text / image / audio / file / `reaction?` / `reply?` /
`service?` / `unsupported`). A control-like payload is never shown as the
preview — it is replaced with **"Control-like payload"** or **"Unsupported
iMessage item"**. A row whose `cache_has_attachments` is set but that has no
attachment rows is flagged **"no attachment rows"**.

## Copy Debug JSON

Click a row to open the **Message Debug** detail panel. It lists the identity
(GUID, ROWID, chat GUID/identifier/display name, handle, service, account),
text (length, sanitized preview, raw text, has-attributedBody), dates, the
attachment list (GUID, MIME/UTI, transfer name, kind, voice flag, total bytes,
download-URL-present), and the iMessage-compatibility fields:
`associatedMessageType`, `associatedMessageGuid`, `itemType`, `groupActionType`,
`groupTitle`, `balloonBundleId`, `expressiveSendStyleId`, `payloadData` presence,
and `error`.

Press **Copy Debug JSON** to copy the whole record.

### What to send back when a message renders incorrectly

1. Reproduce the bad row on the client.
2. Find it in the Inspector (search by text/sender, or Type → Unsupported).
3. Open it and press **Copy Debug JSON**.
4. Paste that JSON into the bug report, plus a one-line "the client showed X, I
   expected Y."

## What is included vs. redacted

**Included (safe to share):** message GUIDs, chat GUIDs, handle identifiers,
timestamps, message text and subject, classification + candidate reasons, and
attachment metadata (filename, transfer name, MIME/UTI, kind, size, voice flag).

**Never included (redacted by construction):**

- the **bearer token** (it is sent in the request header, never echoed);
- **local file paths** of attachments (only the filename/transfer name);
- **full attachment download URLs** — reduced to a `hasDownloadUrl` boolean so a
  tokenized URL can never leak;
- Cloudflare credentials and private config paths (not part of this payload).

So the copied JSON is safe to paste into an issue.

## Classification is heuristic

The server's classification is for debugging only. Confident kinds
(`text`, `image`, `video`, `audio`, `voice`, `file`) describe content the server
can see. Anything ending in `_candidate` (`reaction_candidate`,
`reply_candidate`, `service_candidate`) is a **guess** based on iMessage fields,
and `unsupported_candidate` means nothing renderable was found. Heuristics:

- `associatedMessageType` present and non-zero → reaction/tapback candidate.
- `associatedMessageGuid` present with no/zero type → reply candidate.
- `itemType` / `groupActionType` / `groupTitle` present → service/group event.
- `balloonBundleId` present → interactive (Apple Pay / Digital Touch / app).
- attachment MIME/UTI decides image/video/audio/file; voice flag → voice.
- empty text + no attachments + no associated fields → unsupported (no content).
- text with no letters/digits (e.g. `+!`, `+$`) → unsupported (control-like).

## Remaining server fields for full BlueBubbles-level compatibility

The debug query now **reads** the compatibility columns when the running
`chat.db` schema has them (`associated_message_type`, `associated_message_guid`,
`item_type`, `group_action_type`, `group_title`, `balloon_bundle_id`,
`expressive_send_style_id`, `payload_data`, `error`, `account`). The normal
**client** API (`/api/chats/{guid}/messages`, `/api/messages/recent`) still does
**not** expose them — so to actually fix client rendering (not just diagnose it),
these need to be added to the client message model/serializer:

- `associatedMessageType` + `associatedMessageGuid` → reactions/tapbacks & replies.
- `itemType` + `groupActionType` + `groupTitle` → group/service event text.
- `balloonBundleId` + `payloadData` → interactive/rich-link balloons.
- `expressiveSendStyleId` → send effects.
- message-level `error` → incoming/failed status.
- a `chatGuid` on `message:new`/`update`/`unsend` WebSocket events → routing.

Use the Inspector to confirm which of these are actually present on real rows
before prioritizing the client work.
