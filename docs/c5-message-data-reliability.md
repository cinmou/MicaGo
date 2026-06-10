# C5 Message Data Reliability

Date: 2026-06-08

This phase implements the first data-reliability fixes from
`docs/micago-message-compatibility-investigation.md`. It intentionally does not
include a UI rewrite, push/Firebase client work, or Cloudflare/tunnel changes.

## Server Classification Policy

Normal message JSON now includes safe advisory fields:

- `semanticKind`
- `renderRecommendation`
- `isDebugOnly`
- `unsupportedReason`
- `hasAttributedBody`

Classification is additive and does not remove rows from `chat.db` or
`/api/debug/recent-messages`. The debug endpoint remains the raw inspection
surface.

Current kinds:

| `semanticKind` | Recommendation | Meaning |
| --- | --- | --- |
| `normal_text` | `bubble` | Regular message text. |
| `attributed_body_text` | `bubble` | Text extracted from `attributedBody`. |
| `attachment` | `bubble` | Message has materialized attachment rows. |
| `missing_attachment_rows` | `system` | Source says attachments exist but none were joined. |
| `tapback` | `merge` | Tapback/reaction row targeting another message. |
| `reply` | `bubble` | Message replies to another message. |
| `service_event` | `system` | Group/system event. |
| `effect` | `bubble` | Normal message carrying an expressive send effect. |
| `edited` | `bubble` | Message has edit state. |
| `retracted` | `system` | Message has unsend/retract state. |
| `sync_noise` | `debug_only` | Empty/control-like row that should not render as a bubble. |
| `unknown` | `unsupported` | Reserved fallback. |

## TIFF Behavior

Attachments now expose:

- `originalMimeType`
- `displayKind`
- `isPreviewableImage`
- `needsPreviewConversion`

TIFF is detected by:

- MIME: `image/tiff`, `image/tif`, `image/x-tiff`
- UTI: `public.tiff`
- filename/transfer name: `.tif` or `.tiff`

TIFF remains an image attachment, but is not marked previewable. Flutter no
longer sends TIFF bytes to `Image.memory`; it shows a clear placeholder:

- `TIFF image`
- `Preview not available yet`
- filename and size when available

Recommended future endpoint:

`GET /api/attachments/{guid}/preview`

It should return a safe PNG/JPEG preview for TIFF/HEIC/problem formats while
leaving `GET /api/attachments/{guid}` as the original file stream.

## Send-State Reconciliation

Flutter now reconciles failed/pending optimistic sends with later real outgoing
rows even when `tempGuid` is no longer available.

A local optimistic message is replaced by a server row when:

- both are outgoing,
- server row has a real GUID,
- normalized text matches,
- timestamps are within two minutes,
- or the real GUID/temp correlation already matches.

This handles the common case where `/send` times out, Android marks the local
row failed, and the real iMessage row appears later as delivered/read. The
failed optimistic row is removed to avoid duplicate outgoing bubbles.

## Incoming WebSocket Routing

Thread handling now uses `chatGuid` from WebSocket events:

- `message:new` for the current chat is inserted/updated in memory.
- `message:update` for the current chat updates the existing message in memory.
- `message:unsend` for the current chat marks the message retracted and clears
  visible text/attachments in memory.
- Events for other chats no longer reload the current thread.
- Incomplete/legacy events still fall back to a debounced reload.

The chat list now listens for message events and does a silent refresh with a
short debounce so recent changes appear without manual refresh.

## Edited and Retracted Rendering

Flutter now exposes an `Edited` footer marker for messages with `isEdited` or
`dateEdited`.

Retracted messages render as system rows. For live `message:unsend` events, the
in-memory row is marked retracted and visible content/attachments are cleared so
stale media does not remain visible.

Display preferences still keep failed outgoing messages visible even when
unsupported/system rows are hidden or merged.

## Remaining Gaps

- Server-side preview conversion is not implemented yet.
- Direct `api-store=chatdb` cannot classify every semantic field as richly as
  relay-backed API unless the direct query is expanded further.
- Chat list updates still use a silent reload rather than an in-memory summary
  patch because chat summary payloads do not include last-message fields
  end-to-end yet.
- Background receive/push remains out of scope for C5.
