#!/bin/sh

set -eu

db_path="$HOME/Library/Messages/chat.db"
limit="${LIMIT:-20}"

printf '\n== Recent outgoing iMessage rows with attributedBody diagnostics ==\n'
sqlite3 -readonly -header -column "$db_path" "
SELECT DISTINCT
  m.ROWID,
  m.guid,
  CASE WHEN m.text IS NULL THEN 1 ELSE 0 END AS text_is_null,
  length(m.attributedBody) AS attributed_len,
  m.cache_has_attachments,
  m.is_from_me,
  c.guid AS chat_guid,
  c.chat_identifier,
  m.date
FROM message AS m
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
WHERE c.service_name = 'iMessage'
  AND m.is_from_me = 1
ORDER BY m.date DESC
LIMIT $limit;
"
