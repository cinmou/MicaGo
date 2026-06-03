#!/bin/sh

set -eu

base_url="http://127.0.0.1:3000"
chat_guid="${CHAT_GUID:-}"
message="${MESSAGE:-test from MicaGoServer}"

if [ -z "$chat_guid" ]; then
  echo "Usage: CHAT_GUID=<guid> MESSAGE=\"test from MicaGoServer\" $0"
  exit 1
fi

temp_guid="mica-$(date '+%Y%m%d%H%M%S')"
payload=$(printf '{"tempGuid":"%s","message":"%s"}' "$temp_guid" "$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')")

printf '\n== Health ==\n'
curl -sS "$base_url/api/health"
printf '\n'

printf '\n== Send ==\n'
printf 'chatGuid=%s\n' "$chat_guid"
printf 'tempGuid=%s\n' "$temp_guid"
printf 'message=%s\n' "$message"
curl -i -sS -X POST "$base_url/api/chats/$chat_guid/send" \
  -H 'Content-Type: application/json' \
  -d "$payload"
printf '\n'
