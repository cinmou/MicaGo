#!/bin/sh
# Build and install the current MicaGo backend for local Companion testing.
#
# Default behavior:
#   - build with version/commit/buildTime stamps
#   - install to ~/.micago/bin/micago
#   - set the Companion backend-path override to that binary
#
# This avoids the common stale-binary trap: the Companion prefers its bundled
# Resources/micago unless a user override is set.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HOME/.micago/bin/micago"
APP=""
SET_OVERRIDE=1
RESTART=0
RUN_TESTS=0

usage() {
  cat <<'EOF'
Usage:
  scripts/update-backend.sh [options]

Options:
  --out PATH          Build/install backend to PATH.
                      Default: ~/.micago/bin/micago
  --app PATH          Also copy the built binary into PATH/Contents/Resources/micago.
                      Example: --app /Applications/MicaGoCompanion.app
  --no-override       Do not set Companion's backend-path override.
  --restart           Quit MicaGoCompanion after updating, so relaunch uses the new backend.
  --test              Run go test ./... before installing.
  -h, --help          Show this help.

Examples:
  scripts/update-backend.sh
  scripts/update-backend.sh --test
  scripts/update-backend.sh --app /Applications/MicaGoCompanion.app --restart
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      [ "$#" -ge 2 ] || { echo "missing value for --out" >&2; exit 2; }
      OUT="$2"
      shift 2
      ;;
    --app)
      [ "$#" -ge 2 ] || { echo "missing value for --app" >&2; exit 2; }
      APP="${2%/}"
      shift 2
      ;;
    --no-override)
      SET_OVERRIDE=0
      shift
      ;;
    --restart)
      RESTART=1
      shift
      ;;
    --test)
      RUN_TESTS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$RUN_TESTS" -eq 1 ]; then
  echo "==> running Go tests"
  (cd "$ROOT" && GOCACHE="$ROOT/.gocache" go test ./...)
fi

echo "==> building backend"
sh "$ROOT/scripts/build-backend.sh" "$OUT"
chmod +x "$OUT"

if [ "$SET_OVERRIDE" -eq 1 ]; then
  echo "==> setting Companion backend override"
  defaults write com.micago.companion serverBinaryPath "$OUT"
  echo "override: $OUT"
fi

if [ -n "$APP" ]; then
  DEST_DIR="$APP/Contents/Resources"
  DEST="$DEST_DIR/micago"
  if [ ! -d "$APP/Contents" ]; then
    echo "app bundle not found or invalid: $APP" >&2
    exit 1
  fi
  echo "==> copying backend into app bundle"
  mkdir -p "$DEST_DIR"
  cp "$OUT" "$DEST"
  chmod +x "$DEST"
  echo "bundled: $DEST"
  "$DEST" --version
fi

if [ "$RESTART" -eq 1 ]; then
  echo "==> quitting MicaGoCompanion"
  pkill -x MicaGoCompanion 2>/dev/null || true
  echo "relaunch MicaGoCompanion to start the updated backend."
else
  cat <<EOF

Done.

Next step:
  In MicaGoCompanion, use Stop/Start or Restart backend.

Check:
  Companion Log should say:
    backend launch: source=override path=$OUT

EOF
fi
