# v0.13.0 — Scheduled Sending (Deferred)

Status: **Deferred** (spec only; documents a later phase). This is **not** an
immediate implementation target. It is sequenced **after** v0.11.2 (runtime),
v0.11.3 (sync control), v0.11.4 (contacts), and v0.12 (Firebase).

## Goal

Let a user schedule a plain-text iMessage to be sent later, with safe persistence
and clear failure handling — built on the existing AppleScript send path and
Messages.app precondition.

## BlueBubbles reference inspected

`server/services/scheduledMessagesService/index.ts` +
`databases/server/entity/ScheduledMessage.ts`: a `scheduled_message` row with
`type`, JSON `payload`, `scheduledFor` (epoch), JSON `schedule`
(once/recurring + interval), `status` (`pending`/…), `error`, `sentAt`; an
in-memory timer cache that re-arms on startup and notifies the UI on change. We
adopt the **data model concept**, not the Electron/TypeORM code.

## Why this is deferred

- **Reliability depends on runtime (v0.11.2):** scheduled sends only fire if the
  server is running, the Mac is awake, and Messages.app is open. Those
  guarantees (auto-start, keep-awake, crash recovery, Messages precondition) are
  delivered by v0.11.2 — scheduling on top of an unreliable runtime would misfire.
- **Targeting depends on contacts/rules (v0.11.3/4):** choosing a recipient and
  respecting mute/block rules is much safer once those exist.
- **Lower priority than push:** notifications (v0.12) are the more valuable
  productization step. Scheduling is a convenience feature layered last.

## Design (for the later phase)

### Schedule creation

- `POST /api/scheduled` with `{ chatGuid, message, scheduledFor (unix ms),
  schedule: { type: "once" | "recurring", recurring?: { interval, unit } } }`.
  v1 supports **text to an existing iMessage chat** only (mirrors the live send
  path). Returns the created schedule with a server-assigned id and
  `status: "pending"`.

### Edit / cancel scheduled sends

- `GET /api/scheduled` (list), `PATCH /api/scheduled/{id}` (edit time/message
  while `pending`), `DELETE /api/scheduled/{id}` (cancel). Cancelling a
  `pending` schedule removes its timer.

### Persistence

- New `relay.db` table (additive):

```sql
CREATE TABLE IF NOT EXISTS scheduled_messages (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_guid     TEXT NOT NULL,
  message       TEXT NOT NULL,
  scheduled_for INTEGER NOT NULL,   -- unix ms
  schedule_json TEXT NOT NULL,      -- {"type":"once"} | {"type":"recurring",...}
  status        TEXT NOT NULL,      -- pending | sent | error | canceled
  error         TEXT,
  sent_at       INTEGER,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);
```

### Server restart behavior

- On startup, load all `pending` schedules and **re-arm timers**. Schedules
  whose `scheduledFor` already passed while the server was down are sent
  immediately (with a small grace window) **or** marked `error: "missed"` if
  past a configurable max-late threshold — decide at implementation; default to
  fire-if-recent, mark-missed-if-stale, to avoid surprise late sends.

### Mac sleep behavior

- Timers don't fire while the Mac is asleep. On wake, the service reconciles:
  any `pending` schedule now in the past is handled per the restart policy
  above. Keep-Awake (v0.11.2) can be recommended for users relying on scheduling.

### Messages.app precondition

- Before firing, reuse the v0.11.x precondition: if Messages.app is not running,
  attempt a single launch or **defer** the send briefly and retry; if still
  unavailable, mark the attempt failed with a clear reason (don't silently drop).

### Automation permission

- Sending uses AppleScript → requires **Automation** permission for Messages.
  If denied at fire time, mark `error: "automation_denied"` with guidance; do
  not retry-loop on a permission error.

### Failure states

- `error` reasons: `messages_app_not_running`, `automation_denied`,
  `send_failed` (AppleScript), `send_timeout`, `chat_not_found`,
  `chat_not_imessage`, `missed`. Each is surfaced in the UI with the timestamp.

### Retry policy

- Conservative: on transient failure (Messages not running / brief timeout),
  retry a small bounded number of times with short backoff within a window
  (e.g. 3 tries over a few minutes). Permission/`not_imessage`/`chat_not_found`
  are **non-retryable** → mark `error` immediately. No infinite retries.

### User confirmation / anti-misfire design

- Creating a schedule shows an explicit **confirmation** with the resolved
  recipient (contact name + raw handle from v0.11.4), the exact local send time,
  and the message preview.
- A near-fire **"about to send"** state and the ability to cancel before fire.
- Recurring schedules require extra confirmation and show the next N occurrences.
- Respect v0.11.3 rules: warn (or block) if the target chat is **blocked**.

### Companion UI

- A **Scheduled** sidebar destination: list (pending/sent/error), create sheet
  (recipient via contact search, message, date/time picker, once/recurring),
  edit/cancel. Read-mostly; composing is limited to plain text.

## Non-goals

No private-API sending; no attachment scheduled sending in v1; no cloud
scheduled queue (all local in `relay.db`); no rich-text/effects.

## Manual test checklist (later)

1. Create a one-time schedule; it fires at the set time to the right chat and
   moves to `sent` with `sent_at`.
2. Edit a pending schedule's time/message; cancel a pending schedule (timer
   cleared, status `canceled`).
3. Restart the server before fire → schedule persists and re-arms; a just-passed
   schedule fires (recent) or is marked `missed` (stale) per policy.
4. Messages.app closed at fire → deferred/retried, then clear failure if still
   unavailable; Automation denied → `automation_denied`, no retry loop.
5. Scheduling to a **blocked** chat (v0.11.3) warns/blocks per design.
6. Confirmation shows resolved recipient + exact local time + preview before
   creating.
