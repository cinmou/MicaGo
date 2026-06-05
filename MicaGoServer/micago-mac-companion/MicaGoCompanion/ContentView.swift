import SwiftUI
import AppKit

// MARK: - Sidebar

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard, connections, devices, syncControl, notifications, permissions, server, logs, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .connections: return "Connections"
        case .devices: return "Devices"
        case .syncControl: return "Sync Control"
        case .notifications: return "Notifications"
        case .permissions: return "Permissions"
        case .server: return "Server"
        case .logs: return "Logs"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .connections: return "network"
        case .devices: return "iphone.gen3"
        case .syncControl: return "line.3.horizontal.decrease.circle"
        case .notifications: return "bell"
        case .permissions: return "lock.shield"
        case .server: return "server.rack"
        case .logs: return "text.alignleft"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

// MARK: - Shell

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var runtime: RuntimeMonitor
    @EnvironmentObject var backend: BackendController
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("MicaGo")
            .frame(minWidth: 200)
        } detail: {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailContent
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(selection?.title ?? "MicaGo")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { ServerStatusChip() }
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 560, idealHeight: 720)
        // Bootstrap (config/poll/auto-start/runtime) is owned by the AppDelegate
        // so it runs even when launched silently with no window. Polling stays
        // alive for the menu-bar surface; it is not torn down when the window
        // closes.
    }

    @ViewBuilder private var detailContent: some View {
        switch selection ?? .dashboard {
        case .dashboard: DashboardPage()
        case .connections: ConnectionsPage()
        case .devices: DevicesSection()
        case .syncControl: SyncControlPage()
        case .notifications: NotificationsPage()
        case .permissions: PermissionsPage()
        case .server: ServerPage()
        case .logs: LogsPage()
        case .advanced: AdvancedPage()
        }
    }
}

// MARK: - Shared display helpers

@MainActor
private func displayState(_ backend: BackendController, _ model: AppModel) -> ServerDisplayState {
    serverDisplayState(process: backend.processState, reachable: model.reachable)
}

private func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
}

/// Shown when the backend failed due to Full Disk Access, or the running server
/// reports FDA denied. Clear remediation instead of raw "operation not permitted".
private struct FullDiskAccessBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.red)
                Text("Full Disk Access required").fontWeight(.semibold)
            }
            Text("MicaGo can't read the Messages database. Grant Full Disk Access to MicaGo Companion (and the bundled server), then start the server again.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Full Disk Access Settings") { openFullDiskAccessSettings() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.4), lineWidth: 1))
    }
}

@MainActor
private func fdaNeeded(_ backend: BackendController, _ model: AppModel) -> Bool {
    if backend.failureKind == .fullDiskAccess { return true }
    if model.status?.permissions.fullDiskAccess.status == "denied" { return true }
    return false
}

// MARK: - Persistent status chip

private struct ServerStatusChip: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        let state = displayState(backend, model)
        HStack(spacing: 8) {
            StatusDot(on: state.isHealthyDot)
            Text(state.label).font(.callout)
            if let version = model.status?.version {
                Text("v\(version)").font(.caption).foregroundStyle(.secondary)
            }
            startStopButton(state)
        }
    }

    @ViewBuilder private func startStopButton(_ state: ServerDisplayState) -> some View {
        switch backend.processState {
        case .running, .starting:
            Button { backend.stop() } label: { Image(systemName: "stop.fill") }
                .help("Stop server")
        default:
            Button { backend.start() } label: { Image(systemName: "play.fill") }
                .help("Start server")
                .disabled(!backend.binaryExists || state == .externalUnmanaged)
        }
    }
}

// MARK: - Dashboard

private struct DashboardPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var runtime: RuntimeMonitor
    @EnvironmentObject var backend: BackendController

    var body: some View {
        let state = displayState(backend, model)

        if fdaNeeded(backend, model) {
            FullDiskAccessBanner()
        }

        SectionCard(title: "Status") {
            HStack(spacing: 10) {
                StatusDot(on: state.isHealthyDot)
                Text(state.label).font(.headline)
                Spacer()
                if let s = model.status {
                    Text("v\(s.version) · up \(uptime(s.uptimeSeconds))").foregroundStyle(.secondary)
                }
            }
            LabeledRow(label: "Control", value: managedLabel(state))
            if let s = model.status {
                LabeledRow(label: "Store", value: s.store)
                LabeledRow(label: "Sync", value: s.sync.loopEnabled ? "every \(s.sync.intervalSeconds)s" : "loop off")
                LabeledRow(label: "WebSocket clients", value: "\(s.websocket.clients)")
            }
            if case .failed(let reason) = backend.processState {
                Text(reason).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let next = backend.nextRestartInfo {
                Text(next).font(.caption).foregroundStyle(.secondary)
            }
        }

        SectionCard(title: "Endpoints") {
            CopyableRow(label: "Local", value: localURL)
            if let lan = model.urls?.lan, !lan.isEmpty {
                ForEach(lan) { CopyableRow(label: "LAN", value: $0.baseUrl) }
            } else {
                LabeledRow(label: "LAN", value: "—")
            }
            if let pub = model.urls?.public, pub.enabled {
                CopyableRow(label: "Public", value: pub.baseUrl)
            } else {
                LabeledRow(label: "Public", value: "not configured")
            }
        }

        SectionCard(title: "Runtime & Permissions") {
            SummaryRow(label: "Messages.app", ok: runtime.messagesRunning,
                       value: runtime.messagesRunning ? "running" : "not running")
            SummaryRow(label: "Keep Awake", ok: runtime.keepAwakeActive,
                       value: runtime.keepAwakeActive ? "active" : "off", neutralWhenOff: true)
            if let p = model.status?.permissions {
                StatusValueRow(label: "Full Disk Access", status: p.fullDiskAccess.status)
                StatusValueRow(label: "Automation", status: p.automation.status)
            } else {
                Text("Start the server to read permission diagnostics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        CapabilitiesCard()
    }

    private func managedLabel(_ state: ServerDisplayState) -> String {
        switch state {
        case .externalUnmanaged: return "external (not launched by the companion)"
        case .running, .starting, .startingUnreachable, .stopping: return "managed by the companion"
        default: return backend.binaryExists ? "managed by the companion" : "no backend installed"
        }
    }

    private var localURL: String {
        model.urls?.local.first?.baseUrl
            ?? model.status?.address.baseUrl
            ?? model.baseURL?.absoluteString
            ?? "—"
    }

    private func uptime(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

private struct SummaryRow: View {
    let label: String
    let ok: Bool
    let value: String
    var neutralWhenOff: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : (neutralWhenOff ? "circle" : "exclamationmark.triangle.fill"))
                .foregroundStyle(ok ? Color.green : (neutralWhenOff ? Color.secondary : Color.orange))
            Text(label)
            Spacer()
            Text(value).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StatusValueRow: View {
    let label: String
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(label)
            Spacer()
            Text(status).font(.caption).foregroundStyle(color)
        }
    }

    private var icon: String {
        switch status {
        case "ok": return "checkmark.circle.fill"
        case "denied": return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }
    private var color: Color {
        switch status {
        case "ok": return .green
        case "denied": return .red
        default: return .secondary
        }
    }
}

private struct CapabilitiesCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Detected chat.db Capabilities") {
            if let schema = model.status?.capabilities?.schema {
                CapabilityRow(label: "Edited messages", on: schema.editedMessages)
                CapabilityRow(label: "Unsent / retracted", on: schema.unsentMessages)
                CapabilityRow(label: "Read status", on: schema.readStatus)
                CapabilityRow(label: "Delivered status", on: schema.deliveredStatus)
                CapabilityRow(label: "Send error", on: schema.sendError)
                CapabilityRow(label: "Group actions", on: schema.groupActions)
                CapabilityRow(label: "Attachment metadata", on: schema.attachmentMetadata)
            } else {
                Text("Start the server to read detected capabilities.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CapabilityRow: View {
    let label: String
    let on: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(on ? Color.green : Color.secondary)
            Text(label)
            Spacer()
            Text(on ? "available" : "unavailable").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Connections page

private struct ConnectionsPage: View {
    var body: some View {
        ConnectionEndpointsSection()
        TokenSection()
    }
}

// MARK: - Permissions page

private struct PermissionsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        if fdaNeeded(backend, model) {
            FullDiskAccessBanner()
        }
        DiagnosticsSection()
        RuntimeCard()
    }
}

private struct RuntimeCard: View {
    @EnvironmentObject var runtime: RuntimeMonitor

    var body: some View {
        SectionCard(title: "Runtime") {
            HStack(spacing: 8) {
                StatusDot(on: runtime.messagesRunning)
                Text("Messages.app")
                Text(runtime.messagesRunning ? "running" : "not running")
                    .font(.caption)
                    .foregroundStyle(runtime.messagesRunning ? Color.secondary : Color.orange)
                Spacer()
                if !runtime.messagesRunning {
                    Button("Open Messages") { runtime.openMessages() }
                }
            }
            Text("Messages.app must be running to send via AppleScript.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()

            Toggle(isOn: Binding(
                get: { runtime.keepAwakeActive },
                set: { runtime.setKeepAwake($0) }
            )) {
                Text("Keep this Mac awake while serving")
            }
            Text("Status: \(runtime.keepAwakeActive ? "active (caffeinate)" : "off")")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Server page (controls + binary + logs/exit reason)

private struct ServerPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        let state = displayState(backend, model)

        SectionCard(title: "Server") {
            HStack(spacing: 10) {
                StatusDot(on: state.isHealthyDot)
                Text(state.label).font(.headline)
                Spacer()
                if let version = model.status?.version {
                    Text("v\(version)").foregroundStyle(.secondary)
                }
            }

            if state == .externalUnmanaged {
                Text("A server is already reachable at this address but was not launched by the companion. It will not be stopped or restarted from here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button { backend.start() } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(!backend.binaryExists || backend.isProcessAlive || state == .externalUnmanaged)
                Button { backend.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!backend.isProcessAlive)
                Button { backend.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    .disabled(!backend.binaryExists || state == .externalUnmanaged)
                Spacer()
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.triangle.2.circlepath") }
            }

            BinaryPathRow()

            if let s = model.status {
                LabeledRow(label: "Bind address", value: s.address.listen)
                LabeledRow(label: "Store", value: s.store)
            }

            if case .failed(let reason) = backend.processState {
                Text("Exited: \(reason)").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let code = backend.lastExitCode, backend.processState != .running {
                Text("Last exit code: \(code)").font(.caption).foregroundStyle(.secondary)
            }
            if let next = backend.nextRestartInfo {
                Text(next).font(.caption).foregroundStyle(.secondary)
            }
        }

        if fdaNeeded(backend, model) {
            FullDiskAccessBanner()
        }

        RecentStderrCard()
    }
}

private struct BinaryPathRow: View {
    @EnvironmentObject var backend: BackendController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: backend.binaryExists ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(backend.binaryExists ? .green : .orange)
                TextField("Backend path (leave empty to use the bundled binary)", text: $backend.userBinaryPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                Button("Choose…") { chooseBinary() }
            }
            Text(resolvedDescription)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private var resolvedDescription: String {
        if let r = backend.resolveBinary() {
            return "Using \(r.source) binary: \(r.path)"
        }
        return "No runnable backend found (bundled binary missing and no valid path set)."
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            backend.userBinaryPath = url.path
        }
    }
}

private struct RecentStderrCard: View {
    @EnvironmentObject var backend: BackendController

    var body: some View {
        SectionCard(title: "Recent Output") {
            if backend.logLines.isEmpty {
                Text("No output yet. Output appears when the companion launches the backend.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(backend.logLines.suffix(60).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
        }
    }
}

// MARK: - Logs page

private struct LogsPage: View {
    @EnvironmentObject var backend: BackendController

    var body: some View {
        SectionCard(title: "Server Log") {
            if backend.logLines.isEmpty {
                Text("No output yet. The log shows output from a server started by this companion. Tokens are redacted.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(backend.logLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 320)
            }
        }
    }
}

// MARK: - Advanced page (launch/login/silent/auto-restart settings)

private struct AdvancedPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        SectionCard(title: "Startup & Lifecycle") {
            Toggle("Start server automatically when the companion launches", isOn: $backend.autoStart)
            Toggle("Restart the server automatically if it crashes", isOn: $backend.autoRestart)
            Toggle("Launch hidden (menu-bar only; no window at launch)", isOn: $backend.launchHidden)
            Toggle("Hide Dock icon when running in menu bar", isOn: $backend.hideDockIcon)
                .onChange(of: backend.hideDockIcon) { _ in
                    // Apply immediately: turning it off restores the Dock icon now.
                    applyActivationPolicy()
                }
            Text("“Hide Dock icon” removes the Dock icon while no Dashboard window is open; the menu-bar item stays. Open Dashboard from the menu bar to show the window again. Auto-restart uses exponential backoff, stops after repeated crashes, never restarts after you Stop the server, and never restarts a Full Disk Access failure.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        LaunchAtLoginSection()
        CapabilitiesCard()

        SectionCard(title: "Configuration") {
            LabeledRow(label: "Config file", value: "~/.micago/config.yaml")
            LabeledRow(label: "Backend source", value: backend.binarySource)
            if let url = model.urls {
                LabeledRow(label: "Preferred pairing", value: url.preferredPairingEndpoint)
                LabeledRow(label: "Verify TLS (public)", value: url.public.verifyTls ? "yes" : "no")
            }
            Text("Notification provider configuration and Firebase self-host (FCM) are planned for v0.12.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Connection Endpoints

private struct ConnectionEndpointsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Connection Endpoints") {
            Text("Local")
                .font(.subheadline).fontWeight(.medium).foregroundStyle(.secondary)
            if let urls = model.urls, !urls.local.isEmpty {
                ForEach(urls.local) { EndpointRow(endpoint: $0) }
            } else {
                LabeledRow(label: "Local", value: model.baseURL?.absoluteString ?? "—")
            }

            Divider()

            Text("LAN")
                .font(.subheadline).fontWeight(.medium).foregroundStyle(.secondary)
            if let urls = model.urls, !urls.lan.isEmpty {
                ForEach(urls.lan) { EndpointRow(endpoint: $0) }
            } else {
                Text("Not bound to a LAN address (loopback only). Bind to 0.0.0.0 to expose on the LAN.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Public URL (optional)")
                .font(.subheadline).fontWeight(.medium).foregroundStyle(.secondary)
            PublicURLEditor()
        }
    }
}

private struct EndpointRow: View {
    let endpoint: ConnectionEndpoint

    var body: some View {
        HStack(spacing: 8) {
            ReachableDot(endpoint.reachable)
            Text(endpoint.baseUrl)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(endpoint.reachable.label).font(.caption2).foregroundStyle(.secondary)
            Button { copyToPasteboard(endpoint.baseUrl) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
        }
    }
}

private struct PublicURLEditor: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("https://mica.example.com (leave empty for none)", text: $model.publicURLInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))

            Toggle("Verify TLS certificate", isOn: $model.publicVerifyTLS)
                .font(.caption)

            HStack(spacing: 12) {
                Button("Save") { Task { await model.savePublicURL() } }
                    .disabled(model.publicBusy)
                Button("Validate Public URL") { Task { await model.validatePublicURL() } }
                    .disabled(model.publicBusy || (model.urls?.public.enabled != true))
                if model.publicBusy { ProgressView().controlSize(.small) }
                Spacer()
                if let pub = model.urls?.public, pub.enabled {
                    Button { copyToPasteboard(pub.baseUrl) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                }
            }

            if let pub = model.urls?.public, pub.enabled {
                HStack(spacing: 6) {
                    ReachableDot(pub.reachable)
                    Text("\(pub.baseUrl) — \(pub.reachable.label)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let hint = pub.providerHint, hint != "custom" {
                        Text("(\(hint))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let result = model.publicCheckResult {
                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(result.ok ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Public access is an optional EXTRA endpoint — local and LAN stay active regardless. Produce a public URL with Cloudflare Tunnel, Ngrok, a reverse proxy, or DDNS + port-forwarding. Tailscale is an advanced option. See docs/spec-v0.11.0-connection-endpoints.md.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ReachableDot: View {
    let reachable: Reachability
    init(_ reachable: Reachability) { self.reachable = reachable }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private var color: Color {
        switch reachable {
        case .yes: return .green
        case .no: return .red
        case .unknown: return .secondary
        }
    }
}

// MARK: - Token (pairing — intentionally includes the token in the QR/copy)

private struct TokenSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Bearer Token") {
            HStack {
                Text(displayToken)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(model.tokenRevealed ? "Hide" : "Reveal") {
                    model.tokenRevealed.toggle()
                }
                Button("Copy") {
                    copyToPasteboard(model.token)
                }
                .disabled(model.token.isEmpty)
            }

            if !model.token.isEmpty {
                DisclosureGroup("Pairing QR code") {
                    if model.pairingTargets.isEmpty {
                        Text("Start the server to choose a pairing endpoint.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Pairing endpoint", selection: $model.selectedPairingBaseURL) {
                            ForEach(model.pairingTargets) { target in
                                Text(target.label).tag(target.baseUrl)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.top, 4)

                        if let image = QRCode.image(from: model.pairingPayload) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 180, height: 180)
                                .padding(.top, 6)
                        } else {
                            Text("Could not render QR code.").foregroundStyle(.secondary)
                        }

                        Text("Encodes the SELECTED endpoint's base URL, WebSocket URL, and token. Pick Local for this Mac, LAN for same-network clients, or Public for remote clients — this is a per-pairing choice, not a server mode.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var displayToken: String {
        guard !model.token.isEmpty else { return "—" }
        if model.tokenRevealed { return model.token }
        return String(model.token.prefix(6)) + "••••••••••••"
    }
}

// MARK: - Devices

private struct DevicesSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Registered Devices (\(model.devices.count))") {
            if model.devices.isEmpty {
                Text("No devices registered.").foregroundStyle(.secondary)
            } else {
                ForEach(model.devices) { device in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(device.name).fontWeight(.medium)
                                Text(device.platform).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(device.clientType) · push: \(device.pushProvider)\(device.pushEnabled ? " (on)" : "")\(device.pushTokenSet ? " · token set" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Test Push") { Task { await model.testPush(deviceID: device.id) } }
                            .buttonStyle(.borderless)
                            .disabled(model.notifBusy || !device.pushEnabled)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
                if let result = model.notifResult {
                    Text(result).font(.caption)
                        .foregroundStyle(result.contains("sent") ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Notification Providers") {
            if let n = model.status?.notifications {
                LabeledRow(label: "Enabled", value: n.enabled ? "yes" : "no")
                LabeledRow(label: "Provider", value: n.provider)
                LabeledRow(label: "Preview", value: n.preview)
                LabeledRow(label: "Implemented", value: n.implemented.joined(separator: ", "))
                LabeledRow(label: "Stub", value: n.stub.isEmpty ? "—" : n.stub.joined(separator: ", "))
            } else {
                Text("Unavailable.").foregroundStyle(.secondary)
            }
            Text("Provider status is read-only here. Configuring providers and Firebase self-host (FCM) is planned for v0.12.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Permission Diagnostics") {
            if let p = model.status?.permissions {
                PermissionRow(label: "Full Disk Access", check: p.fullDiskAccess)
                PermissionRow(label: "Attachments", check: p.attachments)
                PermissionRow(label: "Automation", check: p.automation)
            } else {
                Text("Start the server to read diagnostics.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let label: String
    let check: PermissionCheck

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).fontWeight(.medium)
                    Text(check.status).font(.caption).foregroundStyle(color)
                }
                if let detail = check.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch check.status {
        case "ok": return "checkmark.circle.fill"
        case "denied": return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }
    private var color: Color {
        switch check.status {
        case "ok": return .green
        case "denied": return .red
        default: return .secondary
        }
    }
}

// MARK: - Launch at login

private struct LaunchAtLoginSection: View {
    @State private var enabled = LaunchAtLogin.isEnabled
    @State private var error: String?

    var body: some View {
        SectionCard(title: "Launch at Login") {
            Toggle(isOn: $enabled) {
                Text("Start MicaGo Companion when I log in")
            }
            .disabled(!LaunchAtLogin.isSupported)
            .onChange(of: enabled) { newValue in
                do {
                    try LaunchAtLogin.set(newValue)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                    enabled = LaunchAtLogin.isEnabled
                }
            }
            Text("Status: \(LaunchAtLogin.statusDescription)")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Reusable pieces

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).fontWeight(.semibold)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

struct LabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

struct CopyableRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                copyToPasteboard(value)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .disabled(value == "—" || value == "not configured")
        }
    }
}

struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle()
            .fill(on ? Color.green : Color.secondary)
            .frame(width: 10, height: 10)
    }
}

func copyToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
        .environmentObject(RuntimeMonitor())
        .environmentObject(BackendController.shared)
        .environmentObject(ContactsStore())
}
