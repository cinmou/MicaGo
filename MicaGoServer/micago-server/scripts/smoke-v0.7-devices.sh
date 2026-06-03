#!/bin/zsh
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:3000}"
CONFIG_PATH="${HOME}/.micago/config.yaml"
TOKEN="$(sed -n 's/^  token: "\(.*\)"$/\1/p' "$CONFIG_PATH" | head -n 1)"
AUTH_HEADER="Authorization: Bearer $TOKEN"

if [[ -z "$TOKEN" ]]; then
  echo "failed to read token from $CONFIG_PATH"
  exit 1
fi

echo "== register device =="
REGISTER_RESPONSE="$(curl -sS -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"name":"Smoke Device","platform":"android","clientType":"flutter","pushProvider":"none","pushEnabled":false}' \
  "$BASE_URL/api/devices/register")"
echo "$REGISTER_RESPONSE"
DEVICE_ID="$(printf '%s' "$REGISTER_RESPONSE" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1)"
if [[ -z "$DEVICE_ID" ]]; then
  echo "failed to extract device id"
  exit 1
fi

echo
echo "== list devices =="
curl -sS -H "$AUTH_HEADER" "$BASE_URL/api/devices"
echo
echo

echo "== heartbeat =="
curl -sS -H "$AUTH_HEADER" -X POST "$BASE_URL/api/devices/$DEVICE_ID/heartbeat"
echo
echo

echo "== patch name =="
curl -sS -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -X PATCH \
  -d '{"name":"Smoke Device Renamed"}' \
  "$BASE_URL/api/devices/$DEVICE_ID"
echo
echo

echo "== delete device =="
curl -sS -H "$AUTH_HEADER" -X DELETE "$BASE_URL/api/devices/$DEVICE_ID"
echo
