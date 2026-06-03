#!/bin/sh

set -eu

base_url="http://127.0.0.1:3000"
attachment_guid="${ATTACHMENT_GUID:-}"

if [ -z "$attachment_guid" ]; then
  echo "Usage: ATTACHMENT_GUID=<guid> $0"
  exit 1
fi

printf '\n== Health ==\n'
curl -sS "$base_url/api/health"
printf '\n'

printf '\n== Attachment HEAD/GET metadata ==\n'
curl -sSI "$base_url/api/attachments/$attachment_guid" || true

printf '\n== Attachment byte count only ==\n'
curl -sS "$base_url/api/attachments/$attachment_guid" | wc -c
