# BlueBubbles Message Text Extraction

Scope:

- Reference only: `bluebubbles server`
- Goal: understand the smallest part of BlueBubbles' `universalText(true)` behavior that matters for MicaGoServer send confirmation and clean relay sync

## Findings

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.3.1 |
| --- | --- | --- | --- |
| `bluebubbles server/packages/server/src/server/databases/imessage/entity/Message.ts` | `Message.universalText(sanitize = false)` | BlueBubbles first uses `message.text`; if empty, it falls back to extracted `attributedBody` text. | Yes |
| `bluebubbles server/packages/server/src/server/utils/AttributedBodyUtils.ts` | `AttributedBodyUtils.extractText` | The actual fallback is intentionally small: iterate attributed-body items and return the first non-empty `.string`. | Yes |
| `bluebubbles server/packages/server/src/server/databases/imessage/helpers/utils.ts` | `convertAttributedBody` | Decodes raw `message_attributedBody` blobs from `chat.db` into `NSAttributedString[]` using `node-typedstream`, then flattens the result. | Reference only |
| `bluebubbles server/packages/server/src/server/api/serializers/MessageSerializer.ts` | `MessageSerializer.convert` | API serialization writes `text: message.universalText(true)`, so downstream consumers see normalized display text instead of raw `message.text`. | Yes |
| `bluebubbles server/packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise.isSame` | Outgoing match logic compares normalized request text against `onlyAlphaNumeric(message.universalText(true))`. | Yes |
| `bluebubbles server/packages/server/src/server/helpers/utils.ts` | `onlyAlphaNumeric` | BlueBubbles' send matcher removes non-alphanumeric characters before comparing text. | Reference only |
| `bluebubbles server/packages/server/src/server/api/interfaces/messageInterface.ts` | `MessageInterface.sendMessageSync` | The send path creates a pending matcher, dispatches AppleScript, then waits for a message whose `universalText(true)` matches the request. | Yes |

## Effective BlueBubbles fallback order

For plain-text send confirmation, the relevant behavior is:

1. Use `message.text` if present.
2. Otherwise, extract text from `message.attributedBody`.
3. Use that extracted value in API serialization and in outgoing-message matching.

BlueBubbles does not need a more complex fallback than that for this path. Subject and attachment metadata are separate concerns; they are not part of the plain-text `universalText(true)` implementation.

## What matters for MicaGoServer

The live v0.3.0 mismatch happened because AppleScript-sent rows in `chat.db` can have:

- `is_from_me = 1`
- correct joined chat GUID
- `text = NULL`
- non-null `attributedBody`

That means a minimal MicaGoServer fix should do three things:

1. Carry `attributedBody` through `chat.db` reads where messages are filtered or matched.
2. Compute a small "display text" helper with the same priority as BlueBubbles:
   - `text`
   - else decoded `attributedBody`
   - else nil
3. Use that display text for:
   - clean view filtering
   - relay sync text storage
   - send confirmation matching

## Chosen minimal approach for MicaGoServer v0.3.1

BlueBubbles fully decodes typed streams into `NSAttributedString[]` with `node-typedstream`. MicaGoServer does not need that whole stack right now.

For v0.3.1, the smallest reliable approach is:

- inspect BlueBubbles' fallback order first
- keep raw `attributedBody` only inside `chat.db` read code
- extract the plain-text payload from the common AppleScript-sent typed-stream shape
- store only the extracted display text in `relay.db`

## Known limitation

MicaGoServer's v0.3.1 decoder is intentionally narrower than BlueBubbles:

- it targets the observed plain-text `attributedBody` shape from AppleScript-sent messages
- it does not attempt full general `NSAttributedString` deserialization
- some richer future message bodies may still require a fuller decoder
