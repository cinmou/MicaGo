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

    // Connection endpoints (v0.11)
    @Published var urls: ServerURLs?
    @Published var publicURLInput: String = ""
    @Published var publicVerifyTLS: Bool = true
    @Published var publicCheckResult: PublicURLCheckResult?
    @Published var publicBusy = false

    // C23 cleanup: the per-pairing LAN selection (`selectedPairingBaseURL`),
    // the `pairingMode` (lanOnly/lanFirst), `selectedPairingTarget`, and
    // `tokenRevealed` were removed. The unified v3 payload includes every LAN
    // candidate plus Public when configured — there is no manual mode or
    // single-LAN selection anymore.

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
    @Published var syncSettings: SyncSettings = .defaults

    // C11 live sync monitor
    @Published var syncNowBusy = false
    @Published var lastSyncDiagnostics: SyncDiagnostics?

    /// Effective sync diagnostics: the last manual run, else the live status poll.
    var syncDiagnostics: SyncDiagnostics? { lastSyncDiagnostics ?? status?.sync.diagnostics }

    /// Triggers an immediate server sync (C11 debug) and refreshes status.
    func runSyncNow() async {
        guard let baseURL else { return }
        syncNowBusy = true
        defer { syncNowBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            lastSyncDiagnostics = try await client.runSyncNow()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Redaction-safe, copyable diagnostics text (no token, no message text).
    var syncDiagnosticsText: String {
        guard let d = syncDiagnostics else { return "No sync diagnostics yet." }
        func ms(_ v: Int64?) -> String { v.map { "\($0)" } ?? "—" }
        return """
        MicaGo sync diagnostics
        lastTrigger: \(d.lastTriggerReason ?? "—")
        lastStartedAt: \(ms(d.lastStartedAt))  lastCompletedAt: \(ms(d.lastCompletedAt))
        lastDurationMs: \(ms(d.lastDurationMillis))
        mode: \(d.lastBackfillMode ?? "—")  perChatLimit: \(d.lastPerChatLimit ?? 0)
        inserted: \(d.lastInsertedMessages ?? 0)  synced: \(d.lastSyncedMessages ?? 0)  rowsScanned: \(d.lastRowsScanned ?? 0)
        renderable: \(d.lastRenderableRows ?? 0)  hiddenDebug: \(d.lastHiddenDebugRows ?? 0)  updates: \(d.lastUpdatePassCount ?? 0)  unsent: \(d.lastUnsentCount ?? 0)
        scannedRowId: \(ms(d.lastScannedMessageRowId))
        chatDbMtime: \(ms(d.lastChatDbMtime))  walMtime: \(ms(d.lastWalMtime))  shmMtime: \(ms(d.lastShmMtime))
        pendingTriggers: \(d.pendingTriggerCount ?? 0)  lockRetries: \(d.lockRetryCount ?? 0)
        pendingSends: \(d.pendingSendsCount ?? 0)  lateMatchedSends: \(d.lateMatchedSendsCount ?? 0)
        lastEvent: \(d.lastEmittedEventType ?? "—")  chat: \(d.lastEmittedChatGuid ?? "—")
        lastError: \(d.lastSyncError ?? "—")
        """
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
        for e in urls.lan where !hiddenLANBaseURLs.contains(e.baseUrl) {
            targets.append(PairingTarget(scope: .lan, label: "LAN · \(e.baseUrl)", baseUrl: e.baseUrl, wsUrl: e.wsUrl))
        }
        if urls.public.enabled {
            targets.append(PairingTarget(scope: .public, label: "Public · \(urls.public.baseUrl)",
                                         baseUrl: urls.public.baseUrl, wsUrl: urls.public.wsUrl))
        }
        return targets
    }

    /// C23 v3 unified connection payload for the QR code / copy-JSON. It always
    /// includes ALL available candidates (every LAN endpoint + the Public
    /// endpoint when configured) so the client can auto-select — there is no
    /// LAN-only vs LAN+Public mode anymore. Carries the server's connection
    /// config revision so paired clients can detect later URL changes without
    /// rescanning. Loopback/local is never included. Token redacted when asked.
    func pairingPayloadV3(redacted: Bool) -> String {
        // LAN and Public are independent: LAN candidates always go in (when the
        // server is bound to a LAN address); Public is an optional extra.
        let lan = pairingTargets
            .filter { $0.scope == .lan }
            .map { ConnectionCandidate(kind: "lan", baseUrl: $0.baseUrl, wsUrl: $0.wsUrl) }
        let pub = pairingTargets.first { $0.scope == .public }
            .map { ConnectionCandidate(kind: "public", baseUrl: $0.baseUrl, wsUrl: $0.wsUrl) }
        return unifiedConnectionPayload(
            lan: lan,
            publicCandidate: pub,
            token: token,
            serverName: Host.current().localizedName ?? "MicaGo Server",
            configRevision: urls?.connectionRevision ?? "",
            redacted: redacted
        )
    }

    /// Unified connection payload encoded into the QR code (v3).
    var pairingPayload: String { pairingPayloadV3(redacted: false) }

    /// Same payload with the token redacted — safe to show/copy.
    var pairingPayloadRedacted: String { pairingPayloadV3(redacted: true) }

    /// Quick capability flags for the Create Connection status line.
    var hasLanCandidate: Bool { pairingTargets.contains { $0.scope == .lan } }
    var hasPublicCandidate: Bool { pairingTargets.contains { $0.scope == .public } }

    // MARK: - Hidden LAN endpoints (pairing filter only)

    func isLANHidden(_ baseUrl: String) -> Bool { hiddenLANBaseURLs.contains(baseUrl) }

    func setLANHidden(_ baseUrl: String, hidden: Bool) {
        if hidden { hiddenLANBaseURLs.insert(baseUrl) } else { hiddenLANBaseURLs.remove(baseUrl) }
        persistHiddenLAN()
    }

    func resetHiddenLANEndpoints() {
        hiddenLANBaseURLs.removeAll()
        persistHiddenLAN()
    }

    private func persistHiddenLAN() {
        UserDefaults.standard.set(Array(hiddenLANBaseURLs), forKey: "hiddenLANEndpoints")
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
        // C23 cleanup: no per-pairing LAN selection to maintain — the unified v3
        // payload already includes every candidate.
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
            async let settings = client.syncSettings()
            async let chats = client.chats()
            async let recent = client.recentMessages(limit: recentCount)
            syncRules = try await rules
            syncSettings = try await settings
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

    func saveSyncSettings(_ settings: SyncSettings) async {
        guard let baseURL else { return }
        syncBusy = true
        defer { syncBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            let resp = try await client.putSyncSettings(settings)
            syncSettings = resp.settings
            if let d = resp.diagnostics { lastSyncDiagnostics = d }
            lastError = nil
            await loadSyncControl()
        } catch {
            lastError = "Save sync settings: \(error.localizedDescription)"
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

    /// C21u: remove a stale/historical paired device, then refresh the list.
    func deleteDevice(deviceID: String) async {
        guard let baseURL else { return }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            try await client.deleteDevice(deviceID: deviceID)
            devices.removeAll { $0.id == deviceID }
            devices = (try? await client.devices()) ?? devices
        } catch {
            notifResult = "Could not remove device: \(error.localizedDescription)"
        }
    }
}
