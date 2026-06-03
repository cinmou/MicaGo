#!/bin/zsh
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:3000}"
CONFIG_PATH="${HOME}/.micago/config.yaml"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "config not found: $CONFIG_PATH"
  exit 1
fi

TOKEN="$(sed -n 's/^  token: "\(.*\)"$/\1/p' "$CONFIG_PATH" | head -n 1)"
if [[ -z "$TOKEN" ]]; then
  echo "failed to read token from $CONFIG_PATH"
  exit 1
fi

MASKED_TOKEN="${TOKEN[1,6]}..."
AUTH_HEADER="Authorization: Bearer $TOKEN"

echo "Using token: $MASKED_TOKEN"
echo

echo "== GET /api/health without token =="
curl -sS "$BASE_URL/api/health"
echo
echo

echo "== GET /api/chats without token =="
curl -sS -i "$BASE_URL/api/chats?limit=1"
echo
echo

echo "== GET /api/chats with token =="
curl -sS -H "$AUTH_HEADER" "$BASE_URL/api/chats?limit=1"
echo
echo

echo "== GET /api/server/info with token =="
curl -sS -H "$AUTH_HEADER" "$BASE_URL/api/server/info"
echo
echo

echo "== GET /ws without token =="
curl -sS -i "$BASE_URL/ws"
echo
