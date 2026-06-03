#!/bin/sh

set -eu

base_url="http://127.0.0.1:3000"

cat <<'EOF'
WebSocket smoke for v0.4.0

Requirements:
- server running locally
- one of:
  - websocat
  - wscat

Examples:
  websocat ws://127.0.0.1:3000/ws
  wscat -c ws://127.0.0.1:3000/ws

Expected event envelope:
  {"type":"message:new","data":...}
  {"type":"send:match","data":...}
  {"type":"send:error","data":...}
  {"type":"sync:error","data":...}
EOF

printf '\n== Health ==\n'
curl -sS "$base_url/api/health"
printf '\n'

printf '\n== WebSocket endpoint ==\n'
printf 'ws://127.0.0.1:3000/ws\n'
