#!/bin/sh

set -eu

relay_db="$HOME/.micago/relay.db"
base_url="http://127.0.0.1:3000"
timestamp="$(date '+%Y%m%d-%H%M%S')"
out_dir="tmp/smoke-v0.2.2-v0.2.3/$timestamp"

mkdir -p "$out_dir"

if [ "${1:-}" = "--reset" ]; then
  printf '\n== Reset relay.db ==\n'
  rm -f "$relay_db"
  go run ./cmd/micago --sync-once
fi

printf '\n== relay.db counts ==\n'
chat_count="$(sqlite3 "$relay_db" 'SELECT COUNT(*) FROM chats;')"
message_count="$(sqlite3 "$relay_db" 'SELECT COUNT(*) FROM messages;')"
last_rowid="$(sqlite3 "$relay_db" "SELECT COALESCE(value, '') FROM sync_state WHERE key = 'last_message_rowid';")"
first_chat_guid="$(sqlite3 "$relay_db" "SELECT COALESCE(guid, '') FROM chats ORDER BY updated_at DESC LIMIT 1;")"
first_message_guid="$(sqlite3 "$relay_db" "SELECT COALESCE(guid, '') FROM messages ORDER BY source_rowid DESC LIMIT 1;")"
printf 'chats=%s messages=%s last_message_rowid=%s\n' "$chat_count" "$message_count" "$last_rowid"
printf 'top_chat_guid=%s\n' "$first_chat_guid"
printf 'top_message_guid=%s\n' "$first_message_guid"

printf '\n== API health ==\n'
curl -sS "$base_url/api/health" | tee "$out_dir/health.json"
printf '\n'

printf '\n== API chats ==\n'
curl -sS "$base_url/api/chats?limit=5" | tee "$out_dir/chats.json" >/dev/null
grep -o '"guid":"[^"]*"' "$out_dir/chats.json" | head -n 5

printf '\n== API recent messages ==\n'
curl -sS "$base_url/api/messages/recent?limit=5" | tee "$out_dir/messages.json" >/dev/null
grep -o '"guid":"[^"]*"' "$out_dir/messages.json" | head -n 5

printf '\n== API chat messages ==\n'
if [ -n "$first_chat_guid" ]; then
  curl -sS "$base_url/api/chats/$first_chat_guid/messages?limit=5" | tee "$out_dir/chat-messages.json" >/dev/null
  grep -o '"guid":"[^"]*"' "$out_dir/chat-messages.json" | head -n 5
fi

printf '\n== Presence checks ==\n'
if [ -n "$first_chat_guid" ] && grep -q "\"guid\":\"$first_chat_guid\"" "$out_dir/chats.json"; then
  printf 'relay top chat GUID found in API: yes\n'
else
  printf 'relay top chat GUID found in API: no\n'
fi

if [ -n "$first_message_guid" ] && grep -q "\"guid\":\"$first_message_guid\"" "$out_dir/messages.json"; then
  printf 'relay top message GUID found in recent API: yes\n'
else
  printf 'relay top message GUID found in recent API: no\n'
fi

printf '\nSaved outputs under %s\n' "$out_dir"
