// C23 standalone tests (no XCTest target exists). Run via:
//   swiftc MicaGoCompanion/Services/VersionFormat.swift \
//          MicaGoCompanion/Services/ConnectionPayload.swift \
//          scripts/tests/main.swift -o /tmp/vftest && /tmp/vftest
import Foundation

// MARK: displayVersion — exactly one leading "v".
func expect(_ input: String, _ want: String) {
    let got = displayVersion(input)
    precondition(got == want, "displayVersion(\"\(input)\") = \"\(got)\", want \"\(want)\"")
}
expect("v0.15.0", "v0.15.0")
expect("0.15.0", "v0.15.0")
expect("vv0.15.0", "v0.15.0")   // collapses the old "vv" bug
expect("  V0.15.0 ", "v0.15.0") // trims + lowercases the marker
expect("", "v?")
print("displayVersion: all assertions passed")

// MARK: unifiedConnectionPayload — LAN and Public are independent (C23r).
func decode(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}
func kinds(_ json: String) -> [String] {
    let obj = decode(json)
    let cands = (obj["candidates"] as? [[String: Any]]) ?? []
    return cands.compactMap { $0["kind"] as? String }
}

let lan = ConnectionCandidate(kind: "lan", baseUrl: "http://192.168.1.5:3000", wsUrl: "ws://192.168.1.5:3000/ws")
let pub = ConnectionCandidate(kind: "public", baseUrl: "https://x.example.com", wsUrl: "wss://x.example.com/ws")

// LAN only — a valid payload with no Public required.
let lanOnly = unifiedConnectionPayload(lan: [lan], publicCandidate: nil,
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: false)
precondition(kinds(lanOnly) == ["lan"], "LAN-only payload should have exactly one lan candidate")
precondition((decode(lanOnly)["token"] as? String) == "tok", "LAN-only payload should carry the token")

// LAN + Public — LAN first, Public second.
let both = unifiedConnectionPayload(lan: [lan], publicCandidate: pub,
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: false)
precondition(kinds(both) == ["lan", "public"], "LAN+Public payload should be lan then public")

// Public only — still valid.
let pubOnly = unifiedConnectionPayload(lan: [], publicCandidate: pub,
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: false)
precondition(kinds(pubOnly) == ["public"], "Public-only payload should have one public candidate")

// Neither — empty payload (UI shows an empty state instead of copying this).
let none = unifiedConnectionPayload(lan: [], publicCandidate: nil,
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: false)
precondition(none == "{}", "no candidates should produce an empty object")

// Redaction hides the token.
let red = unifiedConnectionPayload(lan: [lan], publicCandidate: nil,
    token: "tok", serverName: "Mac", configRevision: "rev1", redacted: true)
precondition((decode(red)["token"] as? String) == "<redacted>", "redacted payload must hide the token")

print("unifiedConnectionPayload: all assertions passed")
