#!/bin/sh
# C19: displayVersion must render exactly one leading "v".
set -eu
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'EOF'
import Foundation

var exitCode: Int32 = 0
func check(_ got: String, _ want: String, _ name: String) {
    if got == want { print("ok   \(name)") }
    else { print("FAIL \(name): got \(got), want \(want)"); exitCode = 1 }
}

// Server already prefixes "v" → must NOT become "vv".
check(displayVersion("v0.15.0"), "v0.15.0", "v-prefixed stays single v")
// Unprefixed → gets exactly one v.
check(displayVersion("0.15.0"), "v0.15.0", "unprefixed gets one v")
// Pathological double prefix collapses.
check(displayVersion("vv0.15.0"), "v0.15.0", "double v collapses")
check(displayVersion("V0.15.0"), "v0.15.0", "uppercase V normalizes")
check(displayVersion("  v0.15.0 "), "v0.15.0", "whitespace trimmed")
check(displayVersion(""), "v?", "empty is safe")

exit(exitCode)
EOF

xcrun swiftc -o "$TMP/version_test" MicaGoCompanion/Services/VersionFormat.swift "$TMP/main.swift"
"$TMP/version_test"
echo "version format tests passed"
