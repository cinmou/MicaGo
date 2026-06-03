import Foundation

/// The values the companion needs from ~/.micago/config.yaml.
struct MicaConfig {
    var addr: String
    var token: String
    var publicURL: String?
    var configPath: String
}

/// Reads ~/.micago/config.yaml using the same lightweight line parsing the
/// smoke scripts use. The server writes a flat, predictable YAML, so a full
/// YAML parser is unnecessary (and avoids a dependency).
enum ConfigReader {
    static var configPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".micago/config.yaml")
    }

    static func read() -> MicaConfig? {
        let path = configPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        var addr = "127.0.0.1:3000"
        var token = ""
        var publicURL: String?
        var section = ""

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if !rawLine.hasPrefix(" ") && trimmed.hasSuffix(":") {
                section = String(trimmed.dropLast())
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch (section, key) {
            case ("server", "addr"): addr = value
            case ("server", "public_url"): if !value.isEmpty { publicURL = value }
            case ("auth", "token"): token = value
            default: break
            }
        }

        return MicaConfig(addr: addr, token: token, publicURL: publicURL, configPath: path)
    }

    static func baseURL(for config: MicaConfig) -> URL? {
        if let raw = config.publicURL, let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://\(config.addr)")
    }
}
