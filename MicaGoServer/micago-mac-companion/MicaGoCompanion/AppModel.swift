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

    /// LAN base URLs the user has hidden from pairing/QR selection. This is a
    /// UI/pairing filter only — it does not change server networking; the
    /// endpoints remain present in `GET /api/server/urls`.
    @Published var hiddenLANBaseURLs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenLANEndpoints") ?? [])

    private var pollTask: Task<Void, Never>?
    private let pollInterval: UInt64 = 3 * 1_000_000_000 // 3s
    private var didSeedPublicInput = false

    init() {
        reloadConfig()
    }

    // Notifications / FCM config (v0.12)
    @Published var notifEnabled = false
    @Published var notifProvider = "none"
    @Published var notifPreview = "sender"
    @Published var fcmEnabled = false
    @Published var fcmProjectID = ""
    @Published var serviceAccountPath = ""
    @Published var firestoreURLSync = false
    @Published var notifBusy = false
    @Published var notifResult: String?
    @Published var firestoreSyncActive = false
    private var didSeedNotif = false

    // Sync control (v0.11.3)
    @Published var syncRules: SyncRulesResponse?
    @Published var recentMessages: [RecentMessage] = []
    @Published var chatsList: [ChatSummary] = []
    @Published var recentCount: Int = 50
    @Published var syncBusy = false

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
        for e in urls.lan where !hiddenLANBaseURLs.contains(e.baseUrl) {
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

    /// Same payload as the QR/setup JSON, but with the token redacted — safe to
    /// show in the UI or copy into a bug report.
    var pairingPayloadRedacted: String {
        let target = selectedPairingTarget
        let base = (target?.baseUrl ?? status?.address.baseUrl ?? baseURL?.absoluteString ?? "")
            .replacingOccurrences(of: "\"", with: "")
        let ws = (target?.wsUrl ?? status?.address.websocketUrl ?? "")
            .replacingOccurrences(of: "\"", with: "")
        return "{\"baseUrl\":\"\(base)\",\"websocketUrl\":\"\(ws)\",\"token\":\"<redacted>\"}"
    }

    // MARK: - Hidden LAN endpoints (pairing filter only)

    func isLANHidden(_ baseUrl: String) -> Bool { hiddenLANBaseURLs.contains(baseUrl) }

    func setLANHidden(_ baseUrl: String, hidden: Bool) {
        if hidden { hiddenLANBaseURLs.insert(baseUrl) } else { hiddenLANBaseURLs.remove(baseUrl) }
        persistHiddenLAN()
        ensureValidPairingSelection()
    }

    func resetHiddenLANEndpoints() {
        hiddenLANBaseURLs.removeAll()
        persistHiddenLAN()
    }

    private func persistHiddenLAN() {
        UserDefaults.standard.set(Array(hiddenLANBaseURLs), forKey: "hiddenLANEndpoints")
    }

    /// Keep selectedPairingBaseURL valid if the chosen endpoint was just hidden.
    private func ensureValidPairingSelection() {
        let targets = pairingTargets
        if !targets.contains(where: { $0.baseUrl == selectedPairingBaseURL }) {
            selectedPairingBaseURL = targets.first?.baseUrl ?? ""
        }
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
            seedNotificationsForm()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Seed the notifications form once from the server status (the
    // service-account path is never returned, so it stays user-entered).
    private func seedNotificationsForm() {
        guard !didSeedNotif, let n = status?.notifications else { return }
        notifEnabled = n.enabled
        notifProvider = n.provider
        notifPreview = n.preview
        fcmEnabled = n.implemented.contains("fcm")
        didSeedNotif = true
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

    // MARK: - Sync control actions (v0.11.3)

    func loadSyncControl() async {
        guard let baseURL else { return }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            async let rules = client.syncRules()
            async let chats = client.chats()
            async let recent = client.recentMessages(limit: recentCount)
            syncRules = try await rules
            chatsList = try await chats
            recentMessages = try await recent
            lastError = nil
        } catch {
            lastError = "Sync control: \(error.localizedDescription)"
        }
    }

    func setRecentCount(_ count: Int) async {
        recentCount = count
        guard let baseURL else { return }
        let client = APIClient(baseURL: baseURL, token: token)
        do { recentMessages = try await client.recentMessages(limit: count) }
        catch { lastError = "Recent messages: \(error.localizedDescription)" }
    }

    func saveSyncRule(targetKind: String, targetValue: String, syncMode: String, pushMode: String) async {
        guard let baseURL else { return }
        syncBusy = true
        defer { syncBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            syncRules = try await client.putSyncRule(targetKind: targetKind, targetValue: targetValue,
                                                     syncMode: syncMode, pushMode: pushMode)
            lastError = nil
        } catch {
            lastError = "Save rule: \(error.localizedDescription)"
        }
    }

    func clearSyncRule(targetKind: String, targetValue: String) async {
        guard let baseURL else { return }
        syncBusy = true
        defer { syncBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            syncRules = try await client.deleteSyncRule(targetKind: targetKind, targetValue: targetValue)
            lastError = nil
        } catch {
            lastError = "Clear rule: \(error.localizedDescription)"
        }
    }

    func saveDefaultPolicy(sync: String, push: String) async {
        guard let baseURL else { return }
        syncBusy = true
        defer { syncBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            syncRules = try await client.setSyncPolicy(defaultSync: sync, defaultPush: push)
            lastError = nil
        } catch {
            lastError = "Save policy: \(error.localizedDescription)"
        }
    }

    /// The stored rule for a target, if any (exact match; chat by GUID).
    func storedRule(kind: String, value: String) -> SyncRule? {
        syncRules?.rules.first { $0.targetKind == kind && $0.targetValue == value }
    }

    // MARK: - Notifications / FCM config actions (v0.12)

    func saveNotificationsConfig() async {
        guard let baseURL else { return }
        notifBusy = true
        defer { notifBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            let resp = try await client.setNotificationsConfig(
                enabled: notifEnabled, provider: notifProvider, preview: notifPreview,
                fcmEnabled: fcmEnabled, fcmProjectID: fcmProjectID,
                serviceAccountPath: serviceAccountPath, publicURLSync: firestoreURLSync)
            firestoreSyncActive = resp.firestoreSyncEnabled
            let fcmReady = resp.implemented.contains("fcm")
            notifResult = "Saved. FCM \(fcmReady ? "configured" : (fcmEnabled ? "config invalid" : "off"))."
            await refresh()
            lastError = nil
        } catch {
            notifResult = "Save failed: \(error.localizedDescription)"
        }
    }

    func clearNotificationsConfig() async {
        notifProvider = "none"
        notifEnabled = false
        fcmEnabled = false
        serviceAccountPath = ""
        fcmProjectID = ""
        firestoreURLSync = false
        await saveNotificationsConfig()
        notifResult = "Firebase configuration cleared."
    }

    func testPush(deviceID: String) async {
        guard let baseURL else { return }
        notifBusy = true
        defer { notifBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        notifResult = await client.testPush(deviceID: deviceID)
    }
}
