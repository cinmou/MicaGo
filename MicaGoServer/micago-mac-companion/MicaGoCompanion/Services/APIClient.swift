import Foundation

/// Minimal async client for the MicaGoServer local control API. It only calls
/// the read-only / control endpoints the companion needs; it is NOT a chat
/// client.
struct APIClient {
    var baseURL: URL
    var token: String

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 4
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }

    /// Liveness check against the unauthenticated health endpoint.
    func health() async -> Bool {
        let req = request("api/health")
        guard let (_, response) = try? await Self.session().data(for: req),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return http.statusCode == 200
    }

    /// Returns true if the configured token is accepted.
    func checkAuth() async -> Bool {
        let req = request("api/auth/check", method: "POST")
        guard let (_, response) = try? await Self.session().data(for: req),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return http.statusCode == 200
    }

    func status() async throws -> ServerStatus {
        let (data, response) = try await Self.session().data(for: request("api/server/status"))
        try Self.validate(response)
        return try JSONDecoder().decode(ServerStatus.self, from: data)
    }

    func devices() async throws -> [DeviceInfo] {
        let (data, response) = try await Self.session().data(for: request("api/devices"))
        try Self.validate(response)
        return try JSONDecoder().decode(DeviceListResponse.self, from: data).data
    }

    // MARK: - Connection endpoints (v0.11)

    func serverURLs() async throws -> ServerURLs {
        let (data, response) = try await Self.session().data(for: request("api/server/urls"))
        try Self.validate(response)
        return try JSONDecoder().decode(ServerURLs.self, from: data)
    }

    /// Sets (or clears, with an empty string) the optional public endpoint.
    @discardableResult
    func setPublicURL(_ publicBaseURL: String, verifyTLS: Bool, preferred: String) async throws -> ServerURLs {
        var req = request("api/server/public-url", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "publicBaseUrl": publicBaseURL,
            "verifyTls": verifyTLS,
            "preferredPairingEndpoint": preferred,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session().data(for: req)
        try Self.validate(response)
        return try JSONDecoder().decode(ServerURLs.self, from: data)
    }

    func checkPublicURL() async throws -> PublicURLCheckResult {
        let (data, response) = try await Self.session().data(for: request("api/server/public-url/check", method: "POST"))
        try Self.validate(response)
        return try JSONDecoder().decode(PublicURLCheckResult.self, from: data)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.status(http.statusCode)
        }
    }
}

enum APIError: LocalizedError {
    case badResponse
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from the server."
        case .status(let code): return "Server returned HTTP \(code)."
        }
    }
}
