# BlueBubbles Plain-Text Send Flow

Scope:

- Reference only: `../bluebubbles-server`
- Focus only on the plain-text outbound send path
- No code changes to BlueBubbles or MicaGoServer

This document follows the BlueBubbles text-message send flow from API entry through send confirmation in `chat.db`, and calls out which pieces are relevant for a minimal MicaGoServer v0.2 send implementation.

## 1. HTTP route or socket event entry point

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/api/http/api/v1/httpRoutes.ts` | Message route registration | Registers `POST /message/text` and wires it to validation plus `MessageRouter.sendText`. | Yes |
| `packages/server/src/server/api/http/api/v1/routers/messageRouter.ts` | `MessageRouter.sendText` | Main HTTP plain-text send controller; adds `tempGuid` to send cache, delegates to `MessageInterface.sendMessageSync`, serializes the confirmed message, and maps failures into API errors. | Yes |
| `packages/server/src/server/api/http/api/v1/socketRoutes.ts` | `socket.on("send-message")` | Socket entry point for outbound sends; supports text and attachment in one event, performs lightweight inline checks, and also delegates to `MessageInterface.sendMessageSync`. | No |

Plain-text send starts in two places in BlueBubbles:

- HTTP: `POST /message/text`
- Socket: `send-message`

For a minimal MicaGoServer v0.2 send implementation, the HTTP route is enough. The socket path is not required.

## 2. Request payload shape

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/api/http/api/v1/validators/messageValidator.ts` | `MessageValidator.sendTextRules` | Defines the expected HTTP send-text payload fields and basic type checks. | Yes |
| `packages/server/src/server/api/http/api/v1/routers/messageRouter.ts` | `MessageRouter.sendText` | Destructures the payload fields actually passed into the send interface. | Yes |
| `packages/server/src/server/api/privateApi/apis/PrivateApiMessage.ts` | `PrivateApiMessage.send` | Shows the richer private API payload shape used when the helper process sends the message. | Later / not v0.2 |

HTTP plain-text payload fields accepted by BlueBubbles:

- `chatGuid`: required string
- `tempGuid`: optional string, but required for AppleScript sends
- `message`: present string
- `method`: optional string, one of `apple-script`, `private-api`
- `effectId`: optional string
- `subject`: optional string
- `selectedMessageGuid`: optional string for replies
- `partIndex`: optional number
- `ddScan`: optional boolean
- `attributedBody`: optional rich-message body, not validated here but checked for method forcing

Effective minimal plain-text payload for MicaGoServer v0.2:

- `chatGuid`
- `tempGuid`
- `message`

Everything else is tied to private API or richer iMessage features and can be deferred.

## 3. Validation

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/api/http/api/v1/validators/messageValidator.ts` | `MessageValidator.validateText` | Validates type/shape, defaults method, upgrades to private API when advanced fields are present, enforces `tempGuid` for AppleScript, and rejects duplicate queued sends. | Yes |
| `packages/server/src/server/api/http/api/v1/validators/messageValidator.ts` | `MessageValidator.sendTextRules` | Raw field rules used by `ValidateInput`. | Yes |
| `packages/server/src/server/api/http/api/v1/socketRoutes.ts` | `socket.on("send-message")` | Socket path repeats some validation inline instead of using the HTTP validator. | No |

Important validation behavior:

- If `method` is omitted, BlueBubbles defaults to `apple-script`.
- If `effectId`, `subject`, `selectedMessageGuid`, `ddScan`, or `attributedBody` is present, BlueBubbles forces `method = "private-api"`.
- AppleScript sends require:
  - `tempGuid`
  - non-empty `message`
- Private API sends require at least one of:
  - `message`
  - `subject`
- If `tempGuid` is already present in the send cache, the send is rejected as already queued.

Minimal MicaGoServer v0.2 validation should keep:

- `chatGuid` required
- `message` required and non-empty
- `tempGuid` required
- duplicate `tempGuid` rejection

It does not need the private API promotion logic in v0.2.

## 4. How chat/handle target is resolved

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/api/apple/scripts.ts` | `sendMessage` | AppleScript primary path sends to `chat id "<chatGuid>"`, so it targets an existing Messages chat directly. | Yes |
| `packages/server/src/server/helpers/utils.ts` | `getiMessageAddressFormat` | Normalizes direct-message addresses, especially phone numbers, into iMessage-friendly format. | Maybe |
| `packages/server/src/server/api/apple/scripts.ts` | `sendMessageFallback` | Fallback path extracts address and service from the GUID and targets a Messages `participant` / `buddy` instead of a chat id. Only works for non-group chats. | Maybe |
| `packages/server/src/server/api/apple/scripts.ts` | `getAddressFromInput`, `getServiceFromInput` | Splits the BlueBubbles chat identifier into target address and service for fallback sending. | Maybe |
| `packages/server/src/server/helpers/utils.ts` | `generateChatNameList` | Used for group-chat UI actions like rename/open/add/remove participants, but not for normal plain-text send. | No |

Primary send target resolution:

- BlueBubbles expects a BlueBubbles/Messages chat GUID-like string such as:
  - `iMessage;-;+15551234567`
  - `SMS;-;+15551234567`
  - group `chat...` style IDs
- Main AppleScript send path uses:
  - `set targetChat to a reference to chat id "<chatGuid>"`

Direct-message formatting nuance:

- If the GUID contains `";-;"`, BlueBubbles re-formats the right-hand side address through `getiMessageAddressFormat(...)` before rebuilding the `chatGuid`.
- That helps normalize phone numbers into E.164-like form.

Fallback resolution:

- Extracts `address` and `service` from the chatGuid
- Builds a Messages `participant` / `buddy` target from the address
- Explicitly refuses group chats whose extracted address starts with `chat`

Minimal MicaGoServer v0.2 can start with:

- existing chat GUID required
- AppleScript targeting by chat id

Direct-message fallback by handle/address is optional and can come later.

## 5. AppleScript send path

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/api/interfaces/messageInterface.ts` | `MessageInterface.sendMessageSync` | Main orchestration function for text sends; creates the pending matcher, adds it to the outgoing manager, and dispatches AppleScript when `method === "apple-script"`. | Yes |
| `packages/server/src/server/api/apple/actions.ts` | `ActionHandler.sendMessage` | Executes the AppleScript send workflow with retry-after-restart and a DM-only fallback script. | Yes |
| `packages/server/src/server/api/apple/scripts.ts` | `sendMessage` | Builds the primary AppleScript that sends to `chat id`. | Yes |
| `packages/server/src/server/api/apple/scripts.ts` | `restartMessages` | Used when AppleScript times out or throws error `1002`, then the send is retried. | Maybe |
| `packages/server/src/server/api/apple/scripts.ts` | `sendMessageFallback` | Builds the fallback script that targets a direct participant rather than a chat id. | Maybe |

AppleScript plain-text send sequence:

1. `MessageRouter.sendText` calls `MessageInterface.sendMessageSync(...)`.
2. `sendMessageSync(...)` creates a `MessagePromise` with:
   - `chatGuid`
   - normalized text to match later
   - `sentAt = now - 10s`
   - `tempGuid`
3. It adds that promise to `Server().messageManager`.
4. If the chat is in typing cache, it removes the typing state and tries to stop typing via private API.
5. For `method === "apple-script"` it calls:
   - `ActionHandler.sendMessage(chatGuid, message, null)`
6. `ActionHandler.sendMessage(...)`:
   - builds the main AppleScript using `scripts.sendMessage(...)`
   - executes it
   - if the error looks like a timeout or `1002`, restarts Messages and retries once
   - if still failing, tries `sendMessageFallback(...)`
   - if that also fails, throws a cleaned-up error
7. After AppleScript execution returns, `sendMessageSync(...)` waits on `awaiter.promise` for the actual database-backed message match.

Minimal MicaGoServer v0.2 needs:

- one AppleScript send path
- one pending matcher
- one DB confirmation wait

Retry and fallback are useful but optional in the first cut.

## 6. Private API send path

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/api/interfaces/messageInterface.ts` | `MessageInterface.sendMessagePrivateApi` | Sends via helper transport, expects an identifier back, then polls `chat.db` by that identifier until the message appears. | Later / not v0.2 |
| `packages/server/src/server/api/privateApi/apis/PrivateApiMessage.ts` | `PrivateApiMessage.send` | Wraps helper transaction message `send-message` with rich fields like `subject`, `attributedBody`, reply targeting, and `ddScan`. | Later / not v0.2 |

Private API plain-text send behavior:

- `MessageValidator.validateText` implicitly upgrades advanced sends to `private-api`
- `MessageInterface.sendMessagePrivateApi(...)` calls `Server().privateApi.message.send(...)`
- `PrivateApiMessage.send(...)` emits a helper transaction with:
  - `chatGuid`
  - `message`
  - `subject`
  - `attributedBody`
  - `effectId`
  - `selectedMessageGuid`
  - `partIndex`
  - `ddScan` on supported macOS versions
- The helper returns an `identifier`
- BlueBubbles polls `iMessageRepo.getMessage(identifier, true, false)` for up to 60 seconds

This is richer and more deterministic than AppleScript, but it depends on the private helper and is explicitly not needed for MicaGoServer v0.2.

## 7. How temporary GUID/cache/pending state works

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/api/http/api/v1/routers/messageRouter.ts` | `MessageRouter.sendText` | Inserts `tempGuid` into `httpService.sendCache` before sending and removes it after success or failure. | Yes |
| `packages/server/src/server/api/http/api/v1/validators/messageValidator.ts` | `MessageValidator.validateText` | Rejects a send if the same `tempGuid` is already in `sendCache`. | Yes |
| `packages/server/src/server/api/interfaces/messageInterface.ts` | `MessageInterface.sendMessageSync` | Creates the message awaiter and adds it to `Server().messageManager`. | Yes |
| `packages/server/src/server/managers/outgoingMessageManager/index.ts` | `OutgoingMessageManager.add` | Stores the pending send matcher until a database message resolves or rejects it. | Yes |
| `packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise.emitMessageMatch` | On successful match, removes the temp GUID from cache and emits a match event using the temp GUID. | Maybe |
| `packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise.emitMessageError` | On failed match with a message payload, removes the temp GUID and emits an error event. | Maybe |

BlueBubbles uses two layers of temporary state:

1. `sendCache`
   - deduplicates outbound requests by `tempGuid`
   - prevents duplicate queueing
2. `OutgoingMessageManager`
   - tracks unresolved sends as `MessagePromise` instances
   - later resolves them when matching DB rows appear

`tempGuid` is a client correlation key, not the final iMessage GUID.

Minimal MicaGoServer v0.2 needs:

- a `tempGuid` dedupe cache
- a pending-send registry keyed by matching rules

It does not need BlueBubbles’ match/error event emission unless you want real-time push behavior later.

## 8. How outgoing messages are matched when they appear in chat.db

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/managers/outgoingMessageManager/index.ts` | `OutgoingMessageManager.findIndex`, `find`, `resolve`, `reject` | Searches unresolved pending sends and resolves or rejects the first matching one. | Yes |
| `packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise.isSame` | Core match logic comparing chat, normalized text or attachment name, optional subject, and send timestamp. | Yes |
| `packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise.isSameChatGuid` | Allows some chat GUID variations, especially around phone-number prefixes. | Maybe |

Core text-message matching logic in `MessagePromise.isSame(message)`:

1. If the DB message has chats, at least one message chat GUID must match the pending `chatGuid`.
2. For plain text:
   - normalize original outbound text with `onlyAlphaNumeric(...)`
   - normalize the database message via `message.universalText(true)`
   - compare normalized text equality
3. If subject was provided, normalized subjects must also match.
4. The DB message timestamp must be at or after `sentAt`.

Important matching details:

- `sentAt` is intentionally backdated by 10 seconds before the send starts.
- That backdating compensates for timing skew between request time and `chat.db` write time.
- Attachments use a separate path matching attachment transfer names, not text.

Minimal MicaGoServer v0.2 needs:

- chat GUID match
- normalized text match
- timestamp lower bound

Subject matching is optional unless subject sending is in scope.

## 9. Timeout and error handling

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise` constructor timeout | Starts a send timeout: 2 minutes for text, 20 minutes for attachments. | Yes |
| `packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise.reject` | Rejects the pending send with `MessagePromiseRejection`, optionally carrying the matched message and temp GUID. | Yes |
| `packages/server/src/server/api/apple/actions.ts` | `ActionHandler.sendMessage` | Cleans and rethrows AppleScript errors after retry/fallback attempts fail. | Yes |
| `packages/server/src/server/api/http/api/v1/routers/messageRouter.ts` | `MessageRouter.sendText` catch block | Converts `Message`, `MessagePromiseRejection`, or generic exceptions into stable API errors. | Yes |
| `packages/server/src/server/api/interfaces/messageInterface.ts` | `MessageInterface.sendMessagePrivateApi` | Uses a fixed 60-second DB polling timeout for the private API path. | Later / not v0.2 |

BlueBubbles error model for AppleScript text send:

- AppleScript execution can fail immediately
- If it times out or returns `1002`, BlueBubbles retries after restarting Messages
- If fallback also fails, a generic error is thrown
- Even if AppleScript returns successfully, the send still fails if no matching DB message appears before the timeout
- The HTTP route removes `tempGuid` from cache on both success and failure paths

For text sends, the pending matcher timeout is:

- 2 minutes

Minimal MicaGoServer v0.2 needs:

- send timeout
- send cache cleanup on error
- clear API error when no DB match is found

It does not need BlueBubbles’ full error polymorphism.

## 10. What is required for a minimal MicaGoServer send implementation

| File path | Function/class | One short explanation | Needed in MicaGoServer v0.2 |
| --- | --- | --- | --- |
| `packages/server/src/server/api/http/api/v1/routers/messageRouter.ts` | `MessageRouter.sendText` | Best reference for the minimal HTTP send controller shape. | Yes |
| `packages/server/src/server/api/http/api/v1/validators/messageValidator.ts` | `MessageValidator.validateText` | Best reference for the minimum safe validation and duplicate-temp-guid checks. | Yes |
| `packages/server/src/server/api/interfaces/messageInterface.ts` | `MessageInterface.sendMessageSync` | Best reference for the minimal orchestration contract: add pending matcher, send, await DB confirmation. | Yes |
| `packages/server/src/server/api/apple/actions.ts` | `ActionHandler.sendMessage` | Best reference for the actual AppleScript dispatch path. | Yes |
| `packages/server/src/server/managers/outgoingMessageManager/messagePromise.ts` | `MessagePromise.isSame` | Best reference for the matching logic needed to correlate the outbound request with the eventual `chat.db` row. | Yes |
| `packages/server/src/server/api/privateApi/apis/PrivateApiMessage.ts` | `PrivateApiMessage.send` | Reference for a future richer send path, but not needed for the first MicaGoServer send milestone. | Later / not v0.2 |

Minimum viable plain-text send scope for MicaGoServer v0.2:

1. One HTTP endpoint for plain-text send.
2. Request payload:
   - `chatGuid`
   - `tempGuid`
   - `message`
3. Validation:
   - all three required
   - reject duplicate `tempGuid`
4. Targeting:
   - send to an existing Messages chat by chat id
5. Transport:
   - AppleScript only
6. Pending state:
   - send cache for `tempGuid`
   - pending-send matcher list
7. Confirmation:
   - wait for a matching outgoing DB message in `chat.db`
8. Matching:
   - same chat
   - same normalized text
   - DB timestamp after request send time
9. Timeout:
   - short text-send timeout
10. Response:
   - return the actual matched message row once it appears

Not required for MicaGoServer v0.2:

- socket send entry point
- attachments
- multipart messages
- reactions
- edits / unsend
- effect IDs
- subjects
- replies via `selectedMessageGuid`
- attributed body / rich message formatting
- private API send path
- typing-state cleanup
- event emission for live match/error notifications

## Practical takeaways

BlueBubbles’ text send flow is conceptually small under the feature surface:

- validate a request
- dedupe by `tempGuid`
- add a pending matcher
- trigger AppleScript
- wait until `chat.db` shows the new outgoing message
- either return the matched row or time out

That is the smallest reusable slice for MicaGoServer v0.2. The private API path, socket path, and richer iMessage features should be treated as later layers, not part of the minimal send milestone.
