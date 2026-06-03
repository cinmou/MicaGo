#!/bin/sh

set -eu

db_path="$HOME/Library/Messages/chat.db"

run_query() {
	title="$1"
	sql="$2"

	printf '\n== %s ==\n' "$title"
	sqlite3 -readonly -header -column "$db_path" "$sql"
}

run_query "1. chat count by service_name" "
SELECT service_name, COUNT(*)
FROM chat
GROUP BY service_name
ORDER BY COUNT(*) DESC;
"

run_query "2. recent 20 chats" "
SELECT ROWID, guid, chat_identifier, service_name, display_name, is_archived
FROM chat
ORDER BY ROWID DESC
LIMIT 20;
"

run_query "3. message count by service" "
SELECT service, COUNT(*)
FROM message
GROUP BY service
ORDER BY COUNT(*) DESC;
"

run_query "4. recent 20 messages with handle" "
SELECT m.ROWID, m.guid, m.text, m.service, m.date, m.is_from_me, m.is_read, m.is_delivered, m.cache_has_attachments, h.id, h.service
FROM message m
LEFT JOIN handle h ON h.ROWID = m.handle_id
ORDER BY m.date DESC
LIMIT 20;
"

run_query "5. recent 20 messages joined to chats" "
SELECT DISTINCT m.ROWID, m.guid, m.text, m.service, c.guid, c.service_name, c.chat_identifier, m.date, m.is_from_me, m.cache_has_attachments
FROM message m
JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
JOIN chat c ON c.ROWID = cmj.chat_id
ORDER BY m.date DESC
LIMIT 20;
"

run_query "6. recent 20 iMessage messages joined to chats" "
SELECT DISTINCT m.ROWID, m.guid, m.text, m.service, c.guid, c.service_name, c.chat_identifier, m.date, m.is_from_me, m.cache_has_attachments
FROM message m
JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
JOIN chat c ON c.ROWID = cmj.chat_id
WHERE c.service_name = 'iMessage'
  AND (m.text IS NOT NULL OR m.cache_has_attachments = 1)
ORDER BY m.date DESC
LIMIT 20;
"
