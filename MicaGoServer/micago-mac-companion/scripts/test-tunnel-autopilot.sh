#!/bin/sh
# Focused tests for the C18 startup-decoupling bug. The project has no XCTest
# target, so this compiles the pure TunnelAutopilot together with assertions
# and runs them. Exits non-zero on any failure.
set -eu
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'EOF'
func check(_ got: TunnelAutopilotAction, _ want: TunnelAutopilotAction, _ name: String) {
    if got != want {
        print("FAIL \(name): got \(got), want \(want)")
        exitCode = 1
    } else {
        print("ok   \(name)")
    }
}
var exitCode: Int32 = 0

// Backend starts, user never opted in → tunnel untouched.
check(TunnelAutopilot.decide(previousHealthy: nil, healthy: true,
      startWithServer: false, stopWithServer: false,
      tunnelUsable: true, tunnelStopped: true, tunnelProcessAlive: false),
      .none, "backend start without opt-in never starts tunnel")

// Backend starts, opted in → tunnel follows.
check(TunnelAutopilot.decide(previousHealthy: nil, healthy: true,
      startWithServer: true, stopWithServer: false,
      tunnelUsable: true, tunnelStopped: true, tunnelProcessAlive: false),
      .start, "opt-in start follows backend health")

// Steady healthy polls do not retry a failed/stopped-then-failed tunnel.
check(TunnelAutopilot.decide(previousHealthy: true, healthy: true,
      startWithServer: true, stopWithServer: false,
      tunnelUsable: true, tunnelStopped: true, tunnelProcessAlive: false),
      .none, "steady health never re-fires start")

// First poll finds backend down → never stops a tunnel (app-launch case).
check(TunnelAutopilot.decide(previousHealthy: nil, healthy: false,
      startWithServer: false, stopWithServer: true,
      tunnelUsable: true, tunnelStopped: false, tunnelProcessAlive: true),
      .none, "initial unhealthy poll never stops tunnel")

// Observed healthy→unhealthy with opt-in stop → stop.
check(TunnelAutopilot.decide(previousHealthy: true, healthy: false,
      startWithServer: false, stopWithServer: true,
      tunnelUsable: true, tunnelStopped: false, tunnelProcessAlive: true),
      .stop, "opt-in stop follows backend going down")

// Backend restart blip without opt-in stop → tunnel untouched.
check(TunnelAutopilot.decide(previousHealthy: true, healthy: false,
      startWithServer: true, stopWithServer: false,
      tunnelUsable: true, tunnelStopped: false, tunnelProcessAlive: true),
      .none, "backend restart does not touch tunnel without opt-in")

// cloudflared not installed / no config → never any action.
check(TunnelAutopilot.decide(previousHealthy: nil, healthy: true,
      startWithServer: true, stopWithServer: true,
      tunnelUsable: false, tunnelStopped: true, tunnelProcessAlive: false),
      .none, "unusable tunnel is never started (backend unaffected)")

import Foundation
exit(exitCode)
EOF

xcrun swiftc -o "$TMP/autopilot_test" MicaGoCompanion/Services/TunnelAutopilot.swift "$TMP/main.swift"
"$TMP/autopilot_test"
echo "tunnel autopilot tests passed"
