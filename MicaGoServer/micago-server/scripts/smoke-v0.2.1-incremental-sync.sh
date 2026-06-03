#!/bin/sh

set -eu

relay_db="$HOME/.micago/relay.db"

printf '\n== Remove relay.db ==\n'
rm -f "$relay_db"

printf '\n== Initial sync ==\n'
go run ./cmd/micago --sync-once

printf '\n== Inspect after initial sync ==\n'
sqlite3 "$relay_db" 'SELECT COUNT(*) AS message_count FROM messages;'
sqlite3 "$relay_db" "SELECT value FROM sync_state WHERE key = 'last_message_rowid';"

printf '\n== Second sync ==\n'
go run ./cmd/micago --sync-once

printf '\n== Inspect after second sync ==\n'
sqlite3 "$relay_db" 'SELECT COUNT(*) AS message_count FROM messages;'
sqlite3 "$relay_db" "SELECT value FROM sync_state WHERE key = 'last_message_rowid';"

printf '\nManual step: send or receive a new iMessage, then rerun:\n'
printf '  go run ./cmd/micago --sync-once\n'
printf '  sqlite3 %s \"SELECT COUNT(*) FROM messages;\"\n' "$relay_db"
printf '  sqlite3 %s \"SELECT value FROM sync_state WHERE key = '\''last_message_rowid'\'';\"\n' "$relay_db"
