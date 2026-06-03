# MicaGoServer v0.3.1 Text Extraction Fix

## Goal

Fix the v0.3.0 live send-confirmation mismatch where AppleScript-sent iMessage rows appear in `chat.db`, but `message.text` is `NULL` and the actual plain text lives in `message.attributedBody`.

## Observed issue

Live rows after AppleScript send can look like:

- `is_from_me = 1`
- correct joined chat GUID
- `text = NULL`
- non-null `attributedBody`

That breaks two v0.3.0 assumptions:

1. clean view filtering only accepted `text IS NOT NULL OR cache_has_attachments = 1`
2. send confirmation only matched against `message.text`

## BlueBubbles reference

Reference summary from [04-message-text-extraction.md](/Users/Cinmou/Documents/GitHub/MicaGoServer/docs/analysis/04-message-text-extraction.md):

- BlueBubbles uses `message.universalText(true)`
- `universalText(true)` prefers `message.text`
- if `message.text` is empty, it extracts text from `attributedBody`
- outgoing send matching compares against that universal text, not raw `message.text`

## Chosen fallback order

MicaGoServer v0.3.1 uses this display-text order:

1. `message.text` if non-empty after trimming check
2. decoded plain text from `message.attributedBody`
3. otherwise `nil`

`relay.db.messages.text` stores the extracted display text. Raw `attributedBody` is not copied into `relay.db`.

## Scope of the decoder

The v0.3.1 decoder is intentionally minimal:

- it targets the observed AppleScript-sent plain-text `attributedBody` format
- it does not implement full `NSAttributedString` decoding
- it is isolated inside the `internal/store` text helper so it can be replaced later if needed

## Clean view behavior

For `chat.db` reads, the effective clean filter becomes:

- `message.text` non-empty
- or decoded `attributedBody` text non-empty
- or `cache_has_attachments = 1`

Because SQL cannot evaluate the decoded attributed-body text directly, `chat.db` queries may include `attributedBody IS NOT NULL` candidates and the Go layer performs the final drop if extracted text is still empty and there are no attachments.

## Send confirmation behavior

Outgoing match now compares the normalized request text against the extracted display text, not just raw `message.text`.

This applies to:

- direct `chat.db` confirmation
- `relay.db` confirmation after sync

## Manual test plan

1. Run the diagnostic script:
   `./scripts/inspect-v0.3.0-send-text.sh`
2. Confirm recent outgoing iMessage rows can have:
   - `text_is_null = 1`
   - non-zero `attributed_len`
3. Start the server and send a plain-text message through:
   `POST /api/chats/{guid}/send`
4. Confirm the send no longer times out when the matching row has `text = NULL` but a usable `attributedBody`.
5. Run sync again and verify the sent row is imported into `relay.db` with extracted `messages.text`.

## Test plan

- unit test `ExtractMessageText` text-first behavior
- unit test attributed-body fallback
- unit test clean filtering with `text=nil` and extracted attributed-body text
- unit test send-match text normalization path through extracted attributed-body text

## Known limitations

- the decoder is a minimal typed-stream text extractor, not a full attributed-string implementation
- future richer attributed bodies may require a more complete decoder
- this fix targets plain-text send confirmation and clean relay sync only
