# C13 Migration Report

Implemented:

- Re-read IMSG/imsgweb and documented exact files/functions in `docs/c13-imsg-reading-strategy.md`.
- Removed the hardcoded iMessage-only sync source filters.
- Added service category/scope for iMessage, SMS/plain, RCS, and unknown services.
- Added server-owned sync settings and Dashboard controls.
- Added IMSG-shaped per-chat initial backfill and hybrid mode.
- Kept normal API relay-backed.
- Kept Message Inspector/debug raw chat.db visibility.
- Added Android local DB diagnostics and made onboarding bootstrap failure visible/retryable.
- Kept attachment bootstrap metadata-only.

Copied query patterns:

- Per-chat history uses IMSG `chat_message_join` + `WHERE chat_id/guid` + `ORDER BY m.date DESC LIMIT ?`.
- Reaction range follows IMSG reaction exclusion semantics for normal chat-list preview ordering.
- imsgweb preview behavior is documented: strip placeholders, label attachment-only rows, keep browser attachment URLs demand-driven.

Tests added:

- SMS service included/excluded by server settings.
- Unknown service hidden by default but visible in debug.
- Hybrid per-chat backfill recovers quiet chats.
- Attachment metadata is stored without byte reads.
- Android local cache diagnostics reports path/schema/counts.
- Onboarding bootstrap failure blocks normal completion.

Remaining gaps:

- RCS detection is exact service string `RCS`; no deeper Apple-private RCS mapping was found in IMSG.
- Unknown-service “debug mode only” is implemented by normal scope off/debug reads on; enabling unknown makes normal API show them.
- Full display parity for polls/rich app rows is not complete beyond existing semantic fields.
- Server does not yet persist last bootstrap REST call count or attachment preview/full download counters.
