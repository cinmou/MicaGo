import Foundation
import Combine

/// Lifecycle of the *companion-launched* cloudflared tunnel.
enum TunnelState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)
    case runningExternally // a cloudflared we did not launch is already up
    case unknown
}

/// Optional integration with an **already-configured** Cloudflare Tunnel.
///
/// MicaGo never logs into Cloudflare, creates tunnels/DNS, or bundles/downloads
/// cloudflared. It only runs an existing local `cloudflared tunnel run <name>`
/// if the user enables it, so the public URL keeps working without Terminal.
@MainActor
final class TunnelController: ObservableObject {
    static let shared = TunnelController()

    // Discovery
    @Published private(set) var installed = false
    @Published private(set) var configFound = false
    @Published private(set) var tunnelName = "micago-server"
    @Published private(set) var publicHostname = ""
    @Published private(set) var cloudflaredPath: String?

    // Runtime
    @Published private(set) var state: TunnelState = .stopped
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastError: String?

    // Persisted settings
    @Published var startWithServer: Bool { didSet { defaults.set(startWithServer, forKey: K.startWithServer) } }
    @Published var stopWithServer: Bool { didSet { defaults.set(stopWithServer, forKey: K.stopWithServer) } }

    var publicURL: String { publicHostname.isEmpty ? "" : "https://\(publicHostname)" }

    private var process: Process?
    private var intentionalStop = false
    private let defaults = UserDefaults.standard
    private static let maxLogLines = 200

    private enum K {
        static let startWithServer = "tunnelStartWithServer"
        static let stopWithServer = "tunnelStopWithServer"
    }

    init() {
        startWithServer = defaults.bool(forKey: K.startWithServer)
        stopWithServer = defaults.bool(forKey: K.stopWithServer)
        refreshDiscovery()
    }

    var isProcessAlive: Bool {
        switch state {
        case .starting, .running: return true
        default: return false
        }
    }

    // MARK: - Discovery

    /// Re-detects cloudflared, the config file, tunnel name + hostname, and any
    /// externally-running tunnel.
    func refreshDiscovery() {
        cloudflaredPath = Self.findCloudflared()
        installed = cloudflaredPath != nil
        readConfig()
        if process == nil {
            if Self.externalTunnelRunning() {
                state = .runningExternally
            } else if state == .runningExternally {
                state = .stopped
            }
        }
    }

    private func readConfig() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".cloudflared/config.yml")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            configFound = false
            return
        }
        configFound = true
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("tunnel:") {
                let v = line.dropFirst("tunnel:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !v.isEmpty { tunnelName = v }
            } else if line.hasPrefix("- hostname:") || line.hasPrefix("hostname:") {
                let v = line.replacingOccurrences(of: "- hostname:", with: "")
                    .replacingOccurrences(of: "hostname:", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !v.isEmpty && publicHostname.isEmpty { publicHostname = v }
            }
        }
    }

    /// Locates cloudflared in common install paths, then the login-shell PATH.
    private static func findCloudflared() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared",
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return c
        }
        // Fall back to the user's PATH via a login shell.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v cloudflared"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, fm.isExecutableFile(atPath: out) { return out }
        } catch {}
        return nil
    }

    /// True if a `cloudflared tunnel run` process is already running.
    private static func externalTunnelRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "cloudflared tunnel run"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        guard let path = cloudflaredPath else {
            state = .failed("cloudflared is not installed.")
            lastError = "cloudflared is not installed."
            return
        }
        guard configFound else {
            state = .failed("No ~/.cloudflared/config.yml found.")
            lastError = "No ~/.cloudflared/config.yml found."
            return
        }
        if Self.externalTunnelRunning() {
            state = .runningExternally
            appendLog("a cloudflared tunnel is already running (not launched by MicaGo)")
            return
        }

        intentionalStop = false
        lastError = nil
        state = .starting

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["tunnel", "run", tunnelName]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    self?.appendLog(String(line))
                }
                // cloudflared prints "Registered tunnel connection" once connected.
                if text.contains("Registered tunnel connection") || text.contains("Connection ") {
                    self?.markRunning()
                }
            }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(code: code) }
        }

        do {
            try proc.run()
            process = proc
            appendLog("started cloudflared tunnel run \(tunnelName)")
            // Optimistically mark running after a short grace if no error.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.process != nil, self.state == .starting else { return }
                self.markRunning()
            }
        } catch {
            process = nil
            state = .failed("could not launch cloudflared: \(error.localizedDescription)")
            lastError = error.localizedDescription
            appendLog("error: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let proc = process else {
            // Nothing of ours to stop; refresh in case an external one cleared.
            refreshDiscovery()
            return
        }
        intentionalStop = true
        appendLog("stopping tunnel…")
        proc.terminate()
    }

    func restart() {
        if process != nil {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.intentionalStop = false
                self?.start()
            }
        } else {
            start()
        }
    }

    /// Called by the app when the local server health changes, to coordinate the
    /// "start/stop tunnel with server" settings.
    func serverHealthChanged(healthy: Bool) {
        guard installed, configFound else { return }
        if healthy, startWithServer, state == .stopped {
            start()
        } else if !healthy, stopWithServer, process != nil {
            stop()
        }
    }

    /// Stop our child on app quit (never affects external processes).
    func shutdownForQuit() {
        intentionalStop = true
        process?.terminate()
    }

    private func markRunning() {
        if state == .starting { state = .running; appendLog("tunnel connected") }
    }

    private func handleTermination(code: Int32) {
        process = nil
        if intentionalStop {
            state = .stopped
            appendLog("tunnel stopped")
            return
        }
        let reason = code == 0 ? "tunnel exited" : "tunnel exited (code \(code))"
        state = .failed(reason)
        lastError = reason
        appendLog(reason)
    }

    private func appendLog(_ line: String) {
        // Defensive redaction — cloudflared logs are normally safe, but never
        // surface anything token-like.
        var safe = line
        if safe.lowercased().contains("token") { safe = "<redacted line>" }
        logLines.append(safe)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }
}
