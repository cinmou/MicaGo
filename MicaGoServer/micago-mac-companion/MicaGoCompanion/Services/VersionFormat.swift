import Foundation

/// Normalizes a server/build version for display with exactly one leading "v"
/// (C19 fix for "vv0.15.0"). The server's version string already carries a "v"
/// (e.g. "v0.15.0"); older/other sources may not. Trims whitespace and collapses
/// any run of leading "v"s to a single one. Empty input → "v?".
func displayVersion(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "v?" }
    var body = Substring(trimmed)
    while body.first == "v" || body.first == "V" {
        body = body.dropFirst()
    }
    if body.isEmpty { return "v?" }
    return "v" + body
}
