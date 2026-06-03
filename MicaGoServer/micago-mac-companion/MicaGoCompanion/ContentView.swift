import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ServerControlSection()
                ConnectionEndpointsSection()
                TokenSection()
                DevicesSection()
                NotificationsSection()
                DiagnosticsSection()
                RuntimeSection()
                LaunchAtLoginSection()
                ServerLogSection()
            }
            .padding(20)
        }
        .navigationTitle("MicaGo Companion")
        .task {
            model.reloadConfig()
            model.startPolling()
        }
        .onDisappear { model.stopPolling() }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Server control

private struct ServerControlSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Server") {
            HStack(spacing: 10) {
                StatusDot(on: model.reachable)
                Text(statusText)
                    .font(.headline)
                Spacer()
                if let version = model.status?.version {
                    Text("v\(version)").foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    model.controller.start()
                } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(model.controller.isRunning || !model.controller.binaryExists)

                Button {
                    model.controller.stop()
                } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!model.controller.isRunning)

                Button {
                    model.controller.restart()
                } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    .disabled(!model.controller.binaryExists)

                Spacer()

                Button {
                    Task { await model.refresh() }
                } label: { Label("Refresh", systemImage: "arrow.triangle.2.circlepath") }
            }

            BinaryPathRow()

            if let error = model.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        if model.reachable {
            return model.authValid ? "Running" : "Running (token rejected)"
        }
        return model.controller.isRunning ? "Starting…" : "Stopped"
    }
}

private struct BinaryPathRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.controller.binaryExists ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.controller.binaryExists ? .green : .orange)
            TextField("Path to micago server binary", text: $model.controller.binaryPath)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            Button("Choose…") { chooseBinary() }
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.controller.binaryPath = url.path
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

// MARK: - Token

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
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(device.name).fontWeight(.medium)
                            Spacer()
                            Text(device.platform).foregroundStyle(.secondary)
                        }
                        Text("\(device.clientType) · push: \(device.pushProvider)\(device.pushEnabled ? " (on)" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Divider()
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

// MARK: - Runtime (Messages.app + Keep Awake + permission summary)

private struct RuntimeSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var keepAwake = KeepAwakeController()
    @State private var messagesRunning = MessagesApp.isRunning()

    var body: some View {
        SectionCard(title: "Runtime") {
            // Messages.app — required for sending.
            HStack(spacing: 8) {
                StatusDot(on: messagesRunning)
                Text("Messages.app")
                Text(messagesRunning ? "running" : "not running")
                    .font(.caption)
                    .foregroundStyle(messagesRunning ? Color.secondary : Color.orange)
                Spacer()
                if !messagesRunning {
                    Button("Open Messages") { MessagesApp.open() }
                }
            }
            Text("Messages.app must be running to send via AppleScript.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()

            // Keep Awake — conservative caffeinate owned by the companion.
            Toggle(isOn: Binding(
                get: { keepAwake.active },
                set: { keepAwake.setActive($0) }
            )) {
                Text("Keep this Mac awake while serving")
            }
            Text("Status: \(keepAwake.active ? "active (caffeinate)" : "off")")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()

            // Permission summary (sourced from the server's status diagnostics).
            if let p = model.status?.permissions {
                RuntimePermissionRow(label: "Full Disk Access", status: p.fullDiskAccess.status)
                RuntimePermissionRow(label: "Automation", status: p.automation.status)
            } else {
                Text("Start the server to read Full Disk Access / Automation status.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            // Lightweight local poll for Messages.app running state.
            while !Task.isCancelled {
                messagesRunning = MessagesApp.isRunning()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

private struct RuntimePermissionRow: View {
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

// MARK: - Server log

private struct ServerLogSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Server Log") {
            if model.controller.logLines.isEmpty {
                Text("No output yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(model.controller.logLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
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
                .disabled(value == "—")
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
    ContentView().environmentObject(AppModel())
}
