import Foundation
import Combine

/// Central observable state for the companion UI. Owns the server controller,
/// reads the config/token, and periodically polls the local control API while
/// the window is visible.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var config: MicaConfig?
    @Published var reachable = false
    @Published var authValid = false
    @Published var status: ServerStatus?
    @Published var devices: [DeviceInfo] = []
    @Published var lastError: String?
    @Published var tokenRevealed = false

    // Connection endpoints (v0.11)
    @Published var urls: ServerURLs?
    @Published var publicURLInput: String = ""
    @Published var publicVerifyTLS: Bool = true
    @Published var publicCheckResult: PublicURLCheckResult?
    @Published var publicBusy = false
    /// The pairing target the QR code currently encodes (a per-pairing choice,
    /// not a global mode). Stored by baseUrl.
    @Published var selectedPairingBaseURL: String = ""

    private var pollTask: Task<Void, Never>?
    private let pollInterval: UInt64 = 3 * 1_000_000_000 // 3s
    private var didSeedPublicInput = false

    init() {
        reloadConfig()
    }

    var baseURL: URL? {
        guard let config else { return nil }
        return ConfigReader.baseURL(for: config)
    }

    var token: String { config?.token ?? "" }

    /// All endpoints the user can pick for pairing: local, LAN, and public (if
    /// configured). Local/LAN always remain present.
    var pairingTargets: [PairingTarget] {
        guard let urls else { return [] }
        var targets: [PairingTarget] = []
        for e in urls.local {
            targets.append(PairingTarget(scope: .local, label: "Local · \(e.label)", baseUrl: e.baseUrl, wsUrl: e.wsUrl))
        }
        for e in urls.lan {
            targets.append(PairingTarget(scope: .lan, label: "LAN · \(e.baseUrl)", baseUrl: e.baseUrl, wsUrl: e.wsUrl))
        }
        if urls.public.enabled {
            targets.append(PairingTarget(scope: .public, label: "Public · \(urls.public.baseUrl)",
                                         baseUrl: urls.public.baseUrl, wsUrl: urls.public.wsUrl))
        }
        return targets
    }

    var selectedPairingTarget: PairingTarget? {
        let targets = pairingTargets
        return targets.first { $0.baseUrl == selectedPairingBaseURL } ?? targets.first
    }

    /// Pairing payload for the QR code, built from the selected endpoint.
    /// Local-network/remote use depends on which endpoint was chosen.
    var pairingPayload: String {
        let target = selectedPairingTarget
        let base = (target?.baseUrl ?? status?.address.baseUrl ?? baseURL?.absoluteString ?? "")
            .replacingOccurrences(of: "\"", with: "")
        let ws = (target?.wsUrl ?? status?.address.websocketUrl ?? "")
            .replacingOccurrences(of: "\"", with: "")
        let escapedToken = token.replacingOccurrences(of: "\"", with: "")
        return "{\"baseUrl\":\"\(base)\",\"websocketUrl\":\"\(ws)\",\"token\":\"\(escapedToken)\"}"
    }

    func reloadConfig() {
        config = ConfigReader.read()
        if config == nil {
            lastError = "Could not read \(ConfigReader.configPath). Start the server once to generate it."
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: self?.pollInterval ?? 3_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard let baseURL else {
            reachable = false
            return
        }
        let client = APIClient(baseURL: baseURL, token: token)

        let isUp = await client.health()
        reachable = isUp
        guard isUp else {
            status = nil
            devices = []
            authValid = false
            return
        }

        authValid = await client.checkAuth()
        guard authValid else {
            lastError = "Server is up but the token was rejected. Check \(ConfigReader.configPath)."
            return
        }

        do {
            status = try await client.status()
            devices = try await client.devices()
            let fetched = try await client.serverURLs()
            applyURLs(fetched)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func applyURLs(_ fetched: ServerURLs) {
        urls = fetched

        // Seed the public URL editor once from the server's configured value.
        if !didSeedPublicInput {
            publicURLInput = fetched.public.baseUrl
            publicVerifyTLS = fetched.public.verifyTls
            didSeedPublicInput = true
        }

        // Keep a valid pairing selection, defaulting from the server's preference.
        let targets = pairingTargets
        if targets.first(where: { $0.baseUrl == selectedPairingBaseURL }) == nil {
            selectedPairingBaseURL = defaultPairingBaseURL(for: fetched, targets: targets)
        }
    }

    private func defaultPairingBaseURL(for fetched: ServerURLs, targets: [PairingTarget]) -> String {
        switch fetched.preferredPairingEndpoint {
        case "lan":
            if let lan = targets.first(where: { $0.scope == .lan }) { return lan.baseUrl }
        case "public":
            if let pub = targets.first(where: { $0.scope == .public }) { return pub.baseUrl }
        case "local":
            if let local = targets.first(where: { $0.scope == .local }) { return local.baseUrl }
        default:
            break
        }
        return targets.first?.baseUrl ?? ""
    }

    // MARK: - Public endpoint actions

    func savePublicURL() async {
        guard let baseURL else { return }
        publicBusy = true
        defer { publicBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            let updated = try await client.setPublicURL(
                publicURLInput.trimmingCharacters(in: .whitespacesAndNewlines),
                verifyTLS: publicVerifyTLS,
                preferred: urls?.preferredPairingEndpoint ?? "auto")
            applyURLs(updated)
            publicCheckResult = nil
            lastError = nil
        } catch {
            lastError = "Could not save public URL: \(error.localizedDescription)"
        }
    }

    func validatePublicURL() async {
        guard let baseURL else { return }
        publicBusy = true
        defer { publicBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            publicCheckResult = try await client.checkPublicURL()
            await refresh()
        } catch {
            lastError = "Could not validate public URL: \(error.localizedDescription)"
        }
    }
}
