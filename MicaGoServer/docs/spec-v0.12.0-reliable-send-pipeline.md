# spec-v0.12.0 — Reliable local send pipeline (plain text)

Status: **Implemented (server)**. A focused hardening of the existing
AppleScript send path, taking the small useful ideas from BlueBubbles' outgoing
flow **without** copying its architecture (no Socket.IO command surface, no
Private API, no attachment/reaction/edit/unsend/scheduled sends, no Firebase).

> ⚠️ **Version-number note.** `v0.12.0` was previously assigned to the Firebase
> self-host push milestone ([`spec-v0.12.0-firebase-self-host.md`](spec-v0.12.0-firebase-self-host.md),
> "In validation"). This send-pipeline work was also requested as "v0.12.0".
> Both specs currently coexist; renumber one if the linear history matters.

## Background (BlueBubbles reference)

Reviewed for ideas only:
`api/apple/scripts.ts`, `api/apple/actions.ts`,
`api/interfaces/messageInterface.ts`,
`managers/outgoingMessageManager/{index,messagePromise}.ts`,
`databases/imessage/pollers/MessagePoller.ts`.

Reused/simplified concepts: send via `osascript`; treat `osascript` completion as
**"send requested"**, not delivered; keep a small in-memory pending registry;
poll `chat.db` after sending; match the new outgoing row back to the pending
send; confirm only when the row appears; emit a clear failure on timeout.

## What already existed (pre-v0.12.0)

The send path already: created a pending record, enforced duplicate-`tempGuid` →
409, ran one AppleScript attempt, checked Messages.app was running, polled
`chat.db` for a match (`FindOutgoingMessageMatch`), fast-failed on a non-zero
`message.error` (capability-gated), and emitted `send:match` / `send:error`.

## What v0.12.0 adds/changes

### 1. Richer pending-send manager (`internal/send/`)
`PendingSend` gained `CreatedAt`, `Deadline`, `Status`
(`pending`/`confirmed`/`failed`), `MatchedGUID`, `MatchedROWID`, `FailReason`.
`PendingSendManager` gained:

- `Add` (stamps `CreatedAt`/`Deadline`/`Status` when unset),
- `Resolve(tempGUID, matchedGUID, rowid) bool` — atomically **claims** the
  matched row and marks the send confirmed; returns `false` if the row was
  already claimed by another in-flight send,
- `Reject(tempGUID, reason)`,
- `Get`, `List`, `ExpireTimedOut(now)`,
- `ClaimedSnapshot()` + claim release on `Remove`.

The claim set implements the **"ignore already matched messages"** rule so two
concurrent identical sends to the same chat never confirm against the same row.

### 2. Confirmation matching
`FindOutgoingMessageMatch(...)` gained an `excludedGUIDs` parameter. Match rule
(unchanged otherwise): `is_from_me = 1`, same chat GUID, `dateCreated >=
sentAt` (sentAt is backdated ~10s for tolerance), normalized text equal, newest
first, **skipping excluded/claimed rows**.

### 3. Timeout
Confirmation timeout is now **15s** (was 120s); poll interval **500ms**. On
timeout the server returns `504 send_confirmation_timeout` with a structured
`details` object `{tempGuid, chatGuid, text}` and the explanation that
"AppleScript completed but no matching outgoing row appeared in chat.db". The
matching WS `send:error` carries the same fields plus `text`.

### 4. Result states (REST + WS)
| Stage | REST | WebSocket |
| --- | --- | --- |
| accepted / pending created | (request in flight) | `send:pending` |
| Messages.app not running | `409 messages_app_not_running` | `send:error` |
| AppleScript failed | `500 send_failed` | `send:error` |
| chat.db error code (gated) | `502 send_error` | `send:error` |
| confirmed | `200` + `Message` | `send:match` |
| confirmation timed out | `504 send_confirmation_timeout` + `details` | `send:error` + `text` |

The REST call is synchronous (waits up to 15s for confirmation or timeout); the
WS stream additionally emits a `send:pending` then a terminal `send:match` /
`send:error` for clients that don't hold the HTTP request open.

### 5. Stage logging
Concise single-line logs keyed by tempGuid: `request received`, `pending
created`, `applescript started`, `applescript ok`/`failed`, `confirmation poll
started`, `candidate found`, `confirmed`, `timed out`.

### 6. Retry / Messages restart
Conservative: **one** AppleScript attempt; **no** automatic Messages restart.
The existing Messages-running precondition stays as the only proactive check.

### 7. Normalization (unchanged, documented)
`send.NormalizeText` is intentionally a **fuzzy match key** (trims, drops
whitespace/control runs, lowercases, keeps emoji/Unicode) used **only** to match
the AppleScript-sent text against the `chat.db` row — which can differ in
whitespace/case. The **displayed** text is never altered: `OriginalMessage` and
the returned `Message.text` carry the verbatim content. So this does not
"over-normalize" user-visible data.

## Non-goals (unchanged)
Private API, attachment sending, reactions, editing, unsend, scheduled messages,
a Socket.IO-style command surface, Firebase, webhooks.

## Files changed
- `internal/send/pending.go` — richer `PendingSend` + `SendStatus`.
- `internal/send/manager.go` — Resolve/Reject/Get/List/ExpireTimedOut/ClaimedSnapshot + claim tracking.
- `internal/send/manager_test.go` — manager behavior tests.
- `internal/store/queries.go`, `internal/relaydb/query.go` — `FindOutgoingMessageMatch` excluded-GUID param.
- `internal/relaydb/query_test.go` — exclusion test.
- `internal/httpapi/handlers.go` — SendText flow (15s, stages, pending event, resolve/reject, structured timeout), broadcast helpers, `logSend`.
- `internal/httpapi/errors.go` — `apiError.details` + `writeAPIErrorDetails`.
- `internal/httpapi/handlers_test.go` — confirmation-success test + interface fakes.
- `internal/app/app.go` — `apiQueryService` matcher signature.

No schema migrations.

## Manual test checklist
1. Send a simple text to an existing iMessage chat → `200` with the matched `Message`; row GUID appears in logs (`confirmed guid=…`).
2. Send text with emoji → confirmed; emoji preserved in returned `text`.
3. Send text with line breaks → confirmed (normalization is match-only).
4. Verify the message appears in Messages.app and `send:match` is emitted on the WS.
5. Invalid chat GUID → `404 not_found` (no AppleScript run).
6. Messages.app closed → `409 messages_app_not_running` (if precondition wired).
7. Duplicate `tempGuid` while one is pending → `409 conflict`.
8. Force a no-match (e.g. send to a chat then stop sync) → after 15s, `504 send_confirmation_timeout` with `details {tempGuid, chatGuid, text}`.
9. Two rapid identical sends to the same chat → each confirms against a distinct row (claim dedup), or the second times out rather than re-confirming the first's row.
10. Confirm `send:pending` precedes the terminal `send:match`/`send:error` on the WS for the same `tempGuid`.
