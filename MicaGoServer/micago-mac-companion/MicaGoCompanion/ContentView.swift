import SwiftUI
import AppKit

// MARK: - Sidebar

enum SidebarItem: String, CaseIterable, Identifiable {
    // Devices + Permissions moved into the Dashboard (no longer separate items).
    case dashboard, connections, syncControl, messageInspector, notifications, server, logs, tutorials, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .connections: return "Connections"
        case .syncControl: return "Sync Control"
        case .messageInspector: return "Message Inspector"
        case .notifications: return "Notifications"
        case .server: return "Server"
        case .logs: return "Logs"
        case .tutorials: return "Tutorials"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .connections: return "network"
        case .syncControl: return "line.3.horizontal.decrease.circle"
        case .messageInspector: return "ladybug"
        case .notifications: return "bell"
        case .server: return "server.rack"
        case .logs: return "text.alignleft"
        case .tutorials: return "book"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

// MARK: - Shell

/// Shared sidebar selection so deep views can switch tabs (e.g. "Open Logs").
@MainActor final class NavState: ObservableObject {
    @Published var selection: SidebarItem? = .dashboard
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var runtime: RuntimeMonitor
    @EnvironmentObject var backend: BackendController
    @StateObject private var nav = NavState()

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $nav.selection) { item in
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
                .navigationTitle(nav.selection?.title ?? "MicaGo")
                // Server status + primary control live in the native window
                // toolbar (trailing). Two separate ToolbarItems so macOS 26
                // gives each its own Liquid-Glass treatment instead of fusing
                // them into one oversized capsule.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { ServerStatusToolbarPill() }
                    ToolbarItem(placement: .primaryAction) { ServerPrimaryToolbarButton() }
                }
            }
        }
        .environmentObject(nav)
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 560, idealHeight: 720)
        // Bootstrap (config/poll/auto-start/runtime) is owned by the AppDelegate
        // so it runs even when launched silently with no window. Polling stays
        // alive for the menu-bar surface; it is not torn down when the window
        // closes.
    }

    @ViewBuilder private var detailContent: some View {
        switch nav.selection ?? .dashboard {
        case .dashboard: DashboardPage()
        case .connections: ConnectionsPage()
        case .syncControl: SyncControlPage()
        case .messageInspector: MessageInspectorPage()
        case .notifications: NotificationsPage()
        case .server: ServerPage()
        case .logs: LogsPage()
        case .tutorials: TutorialsPage()
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

// MARK: - Toolbar server status + control

/// Compact server-status indicator for the window toolbar: a status dot (or
/// warning icon when crashed) plus a short label. Plain content only — it draws
/// **no** background of its own, so it sits cleanly inside the single system
/// toolbar (Liquid-Glass) group alongside the control button.
private struct ServerStatusToolbarPill: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        let state = displayState(backend, model)
        HStack(spacing: 8) {
            if state == .crashed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Circle()
                    .fill(state.isHealthyDot ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
            }
            Text(state.compactLabel)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(minHeight: 24)
        .help(state.label)
    }
}

/// Primary server control for the toolbar. Renders as a native `Button` so it
/// picks up the system toolbar (Liquid-Glass) styling automatically. While
/// starting/stopping it shows a progress indicator instead of a button.
private struct ServerPrimaryToolbarButton: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        // Uniform breathing room around the control (kept toolbar-sized). The
        // trailing pad gives the whole glass group its right-hand margin; the
        // leading pad separates the control from the status label.
        control
            .padding(.leading, 6)
            .padding(.trailing, 12)
    }

    @ViewBuilder private var control: some View {
        let state = displayState(backend, model)

        switch backend.processState {
        case .starting, .stopping:
            ProgressView()
                .controlSize(.small)
                .help(backend.processState == .stopping ? "Stopping server…" : "Starting server…")
        case .running:
            Button { backend.stop() } label: {
                Label("Stop server", systemImage: "stop.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help("Stop server")
        default:
            // stopped / crashed / exited / notInstalled, or an external server.
            let canStart = backend.binaryExists && state != .externalUnmanaged
            Button { backend.start() } label: {
                Label("Start server", systemImage: "play.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(!canStart)
            .help(startHelp(state))
        }
    }

    private func startHelp(_ state: ServerDisplayState) -> String {
        if state == .externalUnmanaged {
            return "An external server is running; the companion can't control it"
        }
        if !backend.binaryExists { return "No backend binary installed" }
        return "Start server"
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
            if let code = backend.lastExitCode, backend.processState != .running {
                LabeledRow(label: "Last exit code", value: "\(code)")
            }
            if case .failed(let reason) = backend.processState {
                Text(reason).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let next = backend.nextRestartInfo {
                Text(next).font(.caption).foregroundStyle(.secondary)
            }
            Text("Use the toolbar control (top‑right) to start or stop the server.")
                .font(.caption2).foregroundStyle(.secondary)
        }

        RemoteTunnelCard()

        // Pairing lives on the Dashboard now (the main place to set up a client).
        ClientSetupSection()

        DashboardDevicesCard()

        SectionCard(title: "Permissions") {
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
            if fdaNeeded(backend, model) {
                Button("Open Full Disk Access Settings") { openFullDiskAccessSettings() }
                    .controlSize(.small)
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

    private func uptime(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

// MARK: - Dashboard: Remote Tunnel card

private struct RemoteTunnelCard: View {
    @EnvironmentObject var tunnel: TunnelController
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Remote Tunnel") {
            HStack(spacing: 10) {
                tunnelStatusChip
                Spacer()
                Button { tunnel.refreshDiscovery() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }.buttonStyle(.borderless).help("Re-check cloudflared/config")
            }

            LabeledRow(label: "cloudflared", value: tunnel.installed ? "installed" : "not found")
            LabeledRow(label: "Config", value: tunnel.configFound ? "found (~/.cloudflared/config.yml)" : "not found")
            LabeledRow(label: "Tunnel", value: tunnel.tunnelName)
            if !tunnel.publicURL.isEmpty {
                CopyableRow(label: "Public URL", value: tunnel.publicURL)
            }
            if let err = tunnel.lastError {
                Text(err).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !tunnel.installed {
                Text("Install cloudflared and configure a tunnel to use remote access. MicaGo only runs an existing local tunnel — it never logs into Cloudflare or creates tunnels.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !tunnel.configFound {
                Text("No ~/.cloudflared/config.yml found. Create your tunnel config first (see docs/remote-access-cloudflare.md).")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button { tunnel.start() } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(!tunnel.installed || !tunnel.configFound || tunnel.isProcessAlive || tunnel.state == .runningExternally)
                Button { tunnel.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!tunnel.isProcessAlive)
                Button { tunnel.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    .disabled(!tunnel.installed || !tunnel.configFound)
                Spacer()
                Button("Validate Public URL") { Task { await model.validatePublicURL() } }
                    .disabled(model.publicBusy || (model.urls?.public.enabled != true))
                if model.publicBusy { ProgressView().controlSize(.small) }
            }

            if let v = validationText {
                Label(v.text, systemImage: v.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(v.ok ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Start tunnel with MicaGoServer", isOn: $tunnel.startWithServer)
                .font(.caption)
            Toggle("Stop tunnel when the server stops", isOn: $tunnel.stopWithServer)
                .font(.caption)
            Text("When enabled, starting the server also starts this tunnel once the server is healthy. If the tunnel fails, the server keeps running.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tunnelStatusChip: some View {
        let (color, label): (Color, String) = {
            switch tunnel.state {
            case .stopped: return (.secondary, "Stopped")
            case .starting: return (.orange, "Starting…")
            case .running: return (.green, "Running")
            case .failed: return (.red, "Failed")
            case .runningExternally: return (.blue, "Running externally")
            case .unknown: return (.secondary, "Unknown")
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.headline)
        }
    }

    /// Plain-language result of the last public-URL validation, mapping the
    /// tunnel-specific statuses (530 / 502 / 401). Never shows the token.
    private var validationText: (text: String, ok: Bool)? {
        guard let r = model.publicCheckResult else { return nil }
        if r.ok { return ("Remote access is ready.", true) }
        if !r.reachable { return ("Cloudflare is configured, but no tunnel connector is running.", false) }
        switch r.status {
        case 530:
            return ("Cloudflare is configured, but no tunnel connector is running.", false)
        case 502, 503, 504:
            return ("Tunnel is running, but MicaGoServer is not reachable on this Mac.", false)
        case 401, 403:
            return ("The URL reached a server, but the token was rejected.", false)
        default:
            return (r.message.isEmpty ? "Validation failed (HTTP \(r.status))." : r.message, false)
        }
    }
}

// MARK: - Dashboard: Devices card

private struct DashboardDevicesCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Paired Devices (\(model.devices.count))") {
            if model.devices.isEmpty {
                Text("Device registration will appear here after push / device registration is implemented.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.devices) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(device.name).fontWeight(.medium)
                            Text(device.platform).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(device.clientType) · push: \(device.pushProvider)\(device.pushEnabled ? " (on)" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
            }
        }
    }
}

// MARK: - Tutorials (placeholder)

private struct TutorialsPage: View {
    private let entries: [(String, String)] = [
        ("Getting Started", "First setup, permissions, and your first connection."),
        ("Remote Access", "Reach your Mac from anywhere with your own domain + tunnel."),
        ("Android Client", "Pair the Android app by QR and use chats."),
        ("Troubleshooting", "Common connection problems and fixes."),
        ("Documentation site", "Full docs (link added when MicaGo is published)."),
    ]

    var body: some View {
        SectionCard(title: "Tutorials") {
            Text("Guides will appear here when MicaGo is published.")
                .foregroundStyle(.secondary)
            Divider()
            ForEach(entries, id: \.0) { entry in
                HStack(spacing: 10) {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.0).fontWeight(.medium)
                        Text(entry.1).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Soon").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Divider()
            }
            Text("This is a reserved entry point for in‑app guides and the published documentation site.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

// MARK: - Server page (runtime + bind address + advanced binary)

private struct ServerPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        ServerRuntimeCard()

        if fdaNeeded(backend, model) {
            FullDiskAccessBanner()
        }

        LiveSyncMonitorCard()
        ServerBindAddressCard()
    }
}

/// C11 live sync monitor: shows chat.db/WAL/SHM mtimes, last sync trigger /
/// timing / result, pending triggers, lock retries, pending/late sends, and the
/// last emitted event. "Run sync now" + "Copy diagnostics" for debugging.
/// Tokens and full message text are never shown.
private struct LiveSyncMonitorCard: View {
    @EnvironmentObject var model: AppModel

    private func t(_ ms: Int64?) -> String {
        guard let ms, ms > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    var body: some View {
        SectionCard(title: "Live Sync Monitor") {
            let d = model.syncDiagnostics
            HStack(spacing: 10) {
                StatusDot(on: model.reachable)
                Text(model.reachable ? "Server running" : "Server unreachable")
                    .font(.headline)
                Spacer()
                if model.syncNowBusy { ProgressView().controlSize(.small) }
                Button { Task { await model.runSyncNow() } } label: {
                    Label("Run sync now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.syncNowBusy || !model.reachable)
                Button { copyToPasteboard(model.syncDiagnosticsText) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            if let d {
                LabeledRow(label: "Last trigger", value: d.lastTriggerReason ?? "—")
                LabeledRow(label: "Last sync", value: t(d.lastCompletedAt))
                LabeledRow(label: "Duration", value: "\(d.lastDurationMillis ?? 0) ms")
                LabeledRow(label: "Inserted / updated / unsent",
                           value: "\(d.lastInsertedMessages ?? 0) / \(d.lastUpdatePassCount ?? 0) / \(d.lastUnsentCount ?? 0)")
                LabeledRow(label: "chat.db / WAL / SHM mtime",
                           value: "\(t(d.lastChatDbMtime)) / \(t(d.lastWalMtime)) / \(t(d.lastShmMtime))")
                LabeledRow(label: "Pending triggers / lock retries",
                           value: "\(d.pendingTriggerCount ?? 0) / \(d.lockRetryCount ?? 0)")
                LabeledRow(label: "Pending / late-matched sends",
                           value: "\(d.pendingSendsCount ?? 0) / \(d.lateMatchedSendsCount ?? 0)")
                LabeledRow(label: "Last event",
                           value: "\(d.lastEmittedEventType ?? "—") \(d.lastEmittedChatGuid ?? "")")
                if let err = d.lastSyncError, !err.isEmpty {
                    Text("Last error: \(err)").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No sync diagnostics yet. Start the server and trigger a sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Diagnostics only — no tokens or message text are shown.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct ServerRuntimeCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController
    @EnvironmentObject var nav: NavState

    var body: some View {
        let state = displayState(backend, model)

        SectionCard(title: "Server Runtime") {
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

            if let listen = model.status?.address.listen, !listen.isEmpty {
                LabeledRow(label: "Listening on", value: "http://\(listen)")
            }
            if let code = backend.lastExitCode, backend.processState != .running {
                LabeledRow(label: "Last exit code", value: "\(code)")
            }
            if case .failed(let reason) = backend.processState {
                Text("Exited: \(reason)").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let next = backend.nextRestartInfo {
                Text(next).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // Logs live on their own page — link to it instead of duplicating.
            Button {
                nav.selection = .logs
            } label: {
                Label("Open Logs", systemImage: "text.alignleft")
            }
            .controlSize(.small)

            DisclosureGroup("Advanced") {
                BinaryPathRow()
            }
            .font(.subheadline)
        }
    }
}

private struct RecentOutputView: View {
    @EnvironmentObject var backend: BackendController

    var body: some View {
        Group {
            if backend.logLines.isEmpty {
                Text("No output yet. Output appears when the companion launches the backend. Tokens are redacted.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.top, 4)
    }
}

private struct BinaryPathRow: View {
    @EnvironmentObject var backend: BackendController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Backend binary")
                .font(.caption).fontWeight(.medium)
            HStack(spacing: 8) {
                Image(systemName: backend.binaryExists ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(backend.binaryExists ? .green : .orange)
                TextField("Bundled backend (leave empty)", text: $backend.userBinaryPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Button("Choose…") { chooseBinary() }
                    .controlSize(.small)
            }
            Text("Advanced: normally you do not need to change this. MicaGo uses the bundled backend.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(resolvedDescription)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.top, 4)
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

// MARK: - Server Bind Address

private enum BindMode: String, CaseIterable, Identifiable {
    case thisMac, localNetwork, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thisMac: return "This Mac only"
        case .localNetwork: return "Local network"
        case .custom: return "Custom"
        }
    }
}

private struct ServerBindAddressCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    @State private var mode: BindMode = .thisMac
    @State private var host: String = "127.0.0.1"
    @State private var port: String = "3000"
    @State private var loaded = false

    var body: some View {
        SectionCard(title: "Server Bind Address") {
            Text("Choose whether the server is reachable only from this Mac, or from other devices on your network. This applies to the server the companion launches.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $mode) {
                ForEach(BindMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { newMode in applyModeDefaults(newMode) }

            Text(explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Remote access via Cloudflare Tunnel still works with “This Mac only”, because cloudflared runs on this Mac and connects to 127.0.0.1.",
                systemImage: "info.circle")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if mode == .custom {
                    TextField("Host", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: 180)
                }
                Text("Port").foregroundStyle(.secondary)
                TextField("3000", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 90)
                Spacer()
            }

            if mode == .custom {
                Text("Examples: 192.168.1.23:3000 · 127.0.0.1:3000 · 0.0.0.0:3000")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let listen = model.status?.address.listen, !listen.isEmpty {
                Text("Currently listening on: http://\(listen)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Server is not running. The change applies the next time it starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if restartRequired {
                Text("Restart required for this change to take effect.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button { saveAndRestart() } label: { Label("Save & Restart", systemImage: "arrow.clockwise") }
                    .disabled(!isValid || !backend.binaryExists || displayState(backend, model) == .externalUnmanaged)
                Spacer()
            }

            if displayState(backend, model) == .externalUnmanaged {
                Text("This server was not launched by the companion, so its bind address can't be changed from here.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: loadInitial)
    }

    private var explanation: String {
        switch mode {
        case .thisMac:
            return "Only apps on this Mac can connect. This is the safest local setting. (Local / loopback only.)"
        case .localNetwork:
            return "Devices on the same Wi‑Fi can connect using the LAN address. (Local / loopback + LAN / same Wi‑Fi.)"
        case .custom:
            return "Use this only if you know which interface the server should listen on."
        }
    }

    private var portNumber: Int? {
        guard let n = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) else { return nil }
        return n
    }

    private var isValid: Bool {
        guard portNumber != nil else { return false }
        if mode == .custom {
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    private var desiredAddress: String {
        let p = port.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .thisMac: return "127.0.0.1:\(p)"
        case .localNetwork: return "0.0.0.0:\(p)"
        case .custom: return "\(host.trimmingCharacters(in: .whitespaces)):\(p)"
        }
    }

    private var restartRequired: Bool {
        guard isValid else { return false }
        if let listen = model.status?.address.listen, !listen.isEmpty {
            return desiredAddress != listen
        }
        // Server not running: compare against the persisted launch value.
        return desiredAddress != backend.bindAddress
    }

    private func loadInitial() {
        guard !loaded else { return }
        loaded = true
        let source = !backend.bindAddress.isEmpty
            ? backend.bindAddress
            : (model.status?.address.listen ?? "127.0.0.1:3000")
        let (h, p) = splitHostPort(source)
        host = h.isEmpty ? "127.0.0.1" : h
        port = p.isEmpty ? "3000" : p
        switch host {
        case "127.0.0.1", "localhost", "::1": mode = .thisMac
        case "0.0.0.0", "": mode = .localNetwork
        default: mode = .custom
        }
    }

    private func applyModeDefaults(_ newMode: BindMode) {
        switch newMode {
        case .thisMac: host = "127.0.0.1"
        case .localNetwork: host = "0.0.0.0"
        case .custom:
            if host == "127.0.0.1" || host == "0.0.0.0" { /* keep as a starting point */ }
        }
    }

    private func saveAndRestart() {
        backend.bindAddress = desiredAddress
        backend.restart()
    }
}

/// Splits "host:port" (IPv4/hostname) into components. Leaves host empty for a
/// bare ":port". Falls back gracefully for unexpected input.
private func splitHostPort(_ value: String) -> (String, String) {
    guard let idx = value.lastIndex(of: ":") else { return (value, "") }
    let host = String(value[value.startIndex..<idx])
    let port = String(value[value.index(after: idx)...])
    return (host, port)
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
            EndpointGroupHeader(
                title: "Local / loopback",
                subtitle: "Use this only on the Mac running MicaGo. 127.0.0.1 means “this Mac”.")
            if let urls = model.urls, !urls.local.isEmpty {
                ForEach(urls.local) { EndpointRow(endpoint: $0) }
            } else if let base = model.baseURL?.absoluteString {
                EndpointURLRow(label: "Base", value: base)
            } else {
                Text("Start the server to see the local endpoint.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            EndpointGroupHeader(
                title: "LAN / same Wi‑Fi",
                subtitle: "Use this from Android devices on the same Wi‑Fi. Hide noisy VPN/virtual addresses so they aren’t offered for pairing (they stay active on the server).")
            if let urls = model.urls, !urls.lan.isEmpty {
                ForEach(urls.lan) { LANEndpointRow(endpoint: $0) }
                if !model.hiddenLANBaseURLs.isEmpty {
                    Button("Reset hidden LAN endpoints (\(model.hiddenLANBaseURLs.count))") {
                        model.resetHiddenLANEndpoints()
                    }
                    .controlSize(.small).font(.caption)
                }
            } else {
                Text("LAN access is not available because the server is listening on 127.0.0.1 only. Choose “Local network” in Server Bind Address and restart the server.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            EndpointGroupHeader(
                title: "Public / remote",
                subtitle: "Use this from mobile data or another network. Optional and external.")
            PublicURLEditor()
        }
    }
}

private struct EndpointGroupHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EndpointRow: View {
    let endpoint: ConnectionEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ReachableDot(endpoint.reachable)
                Text(endpoint.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(endpoint.reachable.label).font(.caption2).foregroundStyle(.secondary)
            }
            EndpointURLRow(label: "Base", value: endpoint.baseUrl)
            EndpointURLRow(label: "WS", value: endpoint.wsUrl)
        }
        .padding(.vertical, 2)
    }
}

/// A LAN endpoint row with a hide-from-pairing toggle. Hiding is a UI/pairing
/// filter only — it never changes server networking.
private struct LANEndpointRow: View {
    @EnvironmentObject var model: AppModel
    let endpoint: ConnectionEndpoint

    var body: some View {
        let hidden = model.isLANHidden(endpoint.baseUrl)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ReachableDot(endpoint.reachable)
                Text(endpoint.label).font(.caption).foregroundStyle(.secondary)
                if hidden {
                    Text("hidden from pairing").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.setLANHidden(endpoint.baseUrl, hidden: !hidden)
                } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(hidden ? "Show this address for pairing" : "Hide this address from pairing")
            }
            EndpointURLRow(label: "Base", value: endpoint.baseUrl)
            EndpointURLRow(label: "WS", value: endpoint.wsUrl)
        }
        .opacity(hidden ? 0.55 : 1)
        .padding(.vertical, 2)
    }
}

/// A monospaced URL with a copy button, used across endpoint cards.
private struct EndpointURLRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { copyToPasteboard(value) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .disabled(value.isEmpty)
        }
    }
}

private struct PublicURLEditor: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("https://micago.example.com", text: $model.publicURLInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))

            Text("Enter only the origin. Do not include /api, /ws, or a trailing path.")
                .font(.caption2).foregroundStyle(.secondary)

            if let warning = originWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Verify TLS certificate", isOn: $model.publicVerifyTLS)
                .font(.caption)

            HStack(spacing: 12) {
                Button("Save") { Task { await model.savePublicURL() } }
                    .disabled(model.publicBusy || originWarning != nil)
                Button("Validate Public URL") { Task { await model.validatePublicURL() } }
                    .disabled(model.publicBusy || (model.urls?.public.enabled != true))
                if model.publicBusy { ProgressView().controlSize(.small) }
                Spacer()
                if let pub = model.urls?.public, pub.enabled {
                    Button { copyToPasteboard(pub.baseUrl) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 6) {
                Text("Status:").font(.caption).foregroundStyle(.secondary)
                Text(reachabilityState).font(.caption).fontWeight(.medium)
                    .foregroundStyle(reachabilityColor)
                if let pub = model.urls?.public, pub.enabled,
                   let hint = pub.providerHint, hint != "custom" {
                    Text("· \(providerLabel(hint))").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let pub = model.urls?.public, pub.enabled {
                Text(pub.baseUrl).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            if let diag = publicDiagnostic {
                Label(diag.text, systemImage: diag.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(diag.ok ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Public access is an optional EXTRA endpoint — Local and LAN stay active regardless. Produce a public URL with Cloudflare Tunnel, Ngrok, a reverse proxy, or DDNS + port‑forwarding (set up separately). MicaGo does not manage these. See docs/remote-access-cloudflare.md.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reachabilityState: String {
        guard let pub = model.urls?.public, pub.enabled else { return "Not configured" }
        switch pub.reachable {
        case .yes: return "Reachable"
        case .no: return "Failed"
        case .unknown: return "Unknown"
        }
    }

    /// Plain-language result of the last "Validate Public URL" check. Never
    /// includes the token. Maps HTTP statuses to actionable messages.
    private var publicDiagnostic: (text: String, ok: Bool)? {
        guard let r = model.publicCheckResult else { return nil }
        if r.ok {
            return ("Reachable and the token was accepted — Public is ready for pairing.", true)
        }
        if !r.reachable {
            return ("Couldn’t reach the public URL. Check that the tunnel is running and forwards to this server’s port (timeout or connection refused).", false)
        }
        switch r.status {
        case 401, 403:
            return ("Reached a server, but it rejected the token (\(r.status)). The public URL may point to a different server than this one.", false)
        case 502, 503, 504:
            return ("The public URL reached the tunnel, but no server answered behind it (\(r.status)). Make sure MicaGo is running and the tunnel forwards to its port.", false)
        default:
            return (r.message.isEmpty ? "Validation failed (HTTP \(r.status))." : r.message, false)
        }
    }

    private var reachabilityColor: Color {
        guard let pub = model.urls?.public, pub.enabled else { return .secondary }
        switch pub.reachable {
        case .yes: return .green
        case .no: return .orange
        case .unknown: return .secondary
        }
    }

    private func providerLabel(_ hint: String) -> String {
        switch hint {
        case "cloudflare_tunnel": return "Cloudflare Tunnel"
        case "ngrok": return "Ngrok"
        case "tailscale": return "Tailscale"
        default: return hint
        }
    }

    /// A non-nil warning means the entered text is not a bare http(s) origin.
    /// An empty field is allowed (it clears the public URL).
    private var originWarning: String? {
        let raw = model.publicURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        guard let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else {
            return "Enter a full origin like https://micago.example.com"
        }
        if !(comps.path.isEmpty || comps.path == "/") {
            return "Remove the path — enter only the origin (no /api, /ws, etc.)."
        }
        if comps.query != nil || comps.fragment != nil {
            return "Remove the query/fragment — enter only the origin."
        }
        return nil
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

// MARK: - Client Setup (pairing endpoint + token; QR encodes the token)


private struct ClientSetupSection: View {
    @EnvironmentObject var model: AppModel

    private var lanTargets: [PairingTarget] {
        model.pairingTargets.filter { $0.scope == .lan }
    }
    private var publicTarget: PairingTarget? {
        model.pairingTargets.first { $0.scope == .public }
    }
    private var selectedLan: PairingTarget? {
        lanTargets.first { $0.baseUrl == model.selectedPairingBaseURL } ?? lanTargets.first
    }
    private var hasEndpoint: Bool { selectedLan != nil || publicTarget != nil }

    var body: some View {
        SectionCard(title: "Client Setup") {
            Text("Pick a pairing mode, choose your LAN address, then scan the QR code from the Android app.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // C10: only LAN-only and LAN + Public fallback are offered.
            Picker("Mode", selection: Binding(
                get: { model.pairingMode },
                set: { model.pairingMode = $0 }
            )) {
                Text("LAN only").tag("lanOnly")
                Text("LAN + Public fallback").tag("lanFirst")
            }
            .pickerStyle(.segmented)

            Text(model.pairingMode == "lanOnly"
                 ? "The client connects only on your local network and never uses the public address."
                 : "The client tries your LAN first, then falls back to the public address if LAN is unreachable.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Preferred LAN IP.
            if lanTargets.isEmpty {
                Text("No LAN endpoint. Choose “Local network” in Server Bind Address and restart the server.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Text("LAN address").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { selectedLan?.baseUrl ?? lanTargets.first!.baseUrl },
                        set: { model.selectedPairingBaseURL = $0 }
                    )) {
                        ForEach(lanTargets) { Text($0.baseUrl).tag($0.baseUrl) }
                    }
                    .labelsHidden()
                }
                if let lan = selectedLan {
                    EndpointURLRow(label: "Base", value: lan.baseUrl)
                    EndpointURLRow(label: "WS", value: lan.wsUrl)
                }
            }

            if model.pairingMode == "lanFirst" {
                if let pub = publicTarget {
                    EndpointURLRow(label: "Public", value: pub.baseUrl)
                } else {
                    Text("No public URL configured. Set one under Connections to enable the fallback.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("Token").font(.caption).foregroundStyle(.secondary)
                Text(displayToken)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(model.tokenRevealed ? "Hide" : "Reveal") { model.tokenRevealed.toggle() }
                    .controlSize(.small)
                    .disabled(model.token.isEmpty)
                Button("Copy") { copyToPasteboard(model.token) }
                    .controlSize(.small)
                    .disabled(model.token.isEmpty)
            }
            Text("Keep your token private. Don’t paste it into screenshots, logs, or chats.")
                .font(.caption2).foregroundStyle(.secondary)

            if !model.token.isEmpty, hasEndpoint {
                Button {
                    copyToPasteboard(model.pairingPayload)
                } label: {
                    Label("Copy setup JSON", systemImage: "curlybraces")
                }
                .controlSize(.small)

                DisclosureGroup("Show payload (token hidden)") {
                    Text(model.pairingPayloadRedacted)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.subheadline)

                DisclosureGroup("Show QR code") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let image = QRCode.image(from: model.pairingPayload) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 180, height: 180)
                                .padding(.top, 6)
                        } else {
                            Text("Could not render QR code.").foregroundStyle(.secondary)
                        }
                        Text("Encodes the chosen LAN address" + (model.pairingMode == "lanFirst" ? " and the public fallback," : ",") + " the connection mode, and the token (v2 pairing).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.subheadline)
            }
        }
        .onAppear {
            // Default the preferred LAN IP to the first detected LAN endpoint.
            if model.selectedPairingBaseURL.isEmpty, let first = lanTargets.first {
                model.selectedPairingBaseURL = first.baseUrl
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
