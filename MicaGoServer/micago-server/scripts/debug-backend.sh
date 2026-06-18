#!/bin/sh
# Build the CURRENT backend source to a throwaway debug path and show how to make
# the Companion launch it via MICAGO_BACKEND_BIN — WITHOUT touching the cached
# binary (~/.micago/bin/micago) or the bundled one. Use this to prove which
# binary the Companion is actually running when versions look stale.
#
# Usage: scripts/debug-backend.sh [output-path]   (default: /tmp/micago-debug/micago)
set -eu

cd "$(dirname "$0")/.."

OUT="${1:-/tmp/micago-debug/micago}"

# Reuse the supported builder so the binary carries commit/buildTime stamps.
sh scripts/build-backend.sh "$OUT"

echo
echo "Debug backend built at: $OUT"
echo "Version it reports:"
"$OUT" --version
echo
echo "Launch the Companion against THIS binary (env override, cache untouched):"
echo
echo "  # Installed app:"
echo "  MICAGO_BACKEND_BIN=\"$OUT\" /Applications/MicaGoCompanion.app/Contents/MacOS/MicaGoCompanion"
echo
echo "  # Or a debug build from Xcode's DerivedData:"
echo "  MICAGO_BACKEND_BIN=\"$OUT\" \\"
echo "    \"\$(ls -d ~/Library/Developer/Xcode/DerivedData/MicaGoCompanion-*/Build/Products/Debug/MicaGoCompanion.app 2>/dev/null | head -1)/Contents/MacOS/MicaGoCompanion\""
echo
echo "Then check Companion → Log: it should print"
echo "  backend launch: source=env-override path=$OUT"
echo "and Advanced → Backend Build should report this binary's version."
