#!/bin/sh
# Build the MicaGo backend with full build identity (version/commit/buildTime)
# and install it where the companion looks for it (~/.micago/bin/micago by
# default; pass a different output path as $1).
#
# This is THE supported way to refresh the dev backend — a plain `go build`
# works but loses the commit/buildTime stamp the companion uses to detect
# stale binaries (C17).
set -eu

cd "$(dirname "$0")/.."

COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  COMMIT="${COMMIT}-dirty"
fi
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUT="${1:-$HOME/.micago/bin/micago}"

mkdir -p "$(dirname "$OUT")"
go build \
  -ldflags "-X micagoserver/internal/version.Commit=$COMMIT -X micagoserver/internal/version.BuildTime=$BUILD_TIME" \
  -o "$OUT" ./cmd/micago

echo "built: $OUT"
"$OUT" --version
