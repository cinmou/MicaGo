# MicaGoServer v0.32.0 Sticker Preview Compatibility

## Problem

Sticker attachments can be stored as HEIC/HEIF or third-party sticker payloads.
The Flutter Android client cannot reliably decode those raw files, so it may
fall back to a plain "Sticker" placeholder even when Messages and BlueBubbles
show the sticker image.

## BlueBubbles Reference

BlueBubbles treats stickers as visual media, downloads/caches the attachment
bytes, validates that the bytes decode as an image, and only falls back to an
unsupported placeholder when no renderable image can be produced.

## MicaGo Behavior

- Sticker rows keep `attachmentKind=sticker` and `displayKind=sticker`.
- Sticker rows expose `/api/attachments/{guid}/preview`.
- The preview endpoint converts the local attachment to PNG with `sips`.
- The client first tries the PNG preview and falls back to the raw attachment
  bytes if conversion fails.
- Sticker-only messages render with a transparent bubble background.

This keeps Android rendering stable without changing the raw attachment download
endpoint or hiding unrenderable sticker rows.
