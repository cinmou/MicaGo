import Foundation
import Combine

/// Lifecycle state of the *companion-launched* backend process. This is purely
/// about the child process; reachability/auth come from the API poll and are
/// combined separately (see `ServerDisplayState`).
enum BackendProcessState: Equatable {
    case notInstalled   // no runnable binary found
    case stopped        // never started, or stopped cleanly by the user
    case starting       // launch requested, process not yet confirmed
    case running        // child process is alive
    case stopping       // user asked to stop; awaiting exit
    case exited(Int32)  // process ended (not a user stop), exit code
    case failed(String) // failed to launch / crashed with a summarized reason
}

/// Classified backend failure, used to drive remediation UI (esp. Full Disk
/// Access) and to suppress pointless auto-restarts.
enum BackendFailureKind: Equatable {
    case fullDiskAccess
    case addressInUse
    case messagesNotRunning
    case configInvalid
    case unknown
}

/// BackendController is the isolated, testable process manager for the bundled
/// Go relay binary. It only ever controls a process **it** launched; it never
/// touches an external/unmanaged server (see `ServerDisplayState`).
@MainActor
final class BackendController: ObservableObject {
    // Process state
    @Published private(set) var processState: BackendProcessState = .stopped
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var lastExitReason: String?
    @Published private(set) var lastStderrLine: String?
    @Published private(set) var failureKind: BackendFailureKind?
    @Published private(set) var nextRestartInfo: String?
    @Published private(set) var binarySource: String = "none"  // bundled | override | default | none

    // Persisted settings
    @Published var userBinaryPath: String { didSet { defaults.set(userBinaryPath, forKey: K.binaryPath) } }
    @Published var autoStart: Bool { didSet { defaults.set(autoStart, forKey: K.autoStart) } }
    @Published var autoRestart: Bool { didSet { defaults.set(autoRestart, forKey: K.autoRestart) } }
    @Published var launchHidden: Bool { didSet { defaults.set(launchHidden, forKey: K.launchHidden) } }
    // v0.11.2.1: hide the Dock icon while running menu-bar-only (no window open).
    // Persistence only — activation policy is applied centrally (applyActivationPolicy()).
    @Published var hideDockIcon: Bool { didSet { defaults.set(hideDockIcon, forKey: K.hideDockIcon) } }

    private var process: Process?
    private var intentionalStop = false
    private var restartAttempt = 0
    private var restartWork: DispatchWorkItem?
    private var healthyResetWork: DispatchWorkItem?

    private let backoff: [TimeInterval] = [1, 2, 5, 15, 30, 60]
    private let maxConsecutiveCrashes = 5
    private static let maxLogLines = 300
    private let defaults = UserDefaults.standard

    private enum K {
        static let binaryPath = "serverBinaryPath"
        static let autoStart = "autoStartServer"
        static let autoRestart = "autoRestartServer"
        static let launchHidden = "launchHidden"
        static let hideDockIcon = "hideDockIcon"
    }

    init() {
        userBinaryPath = defaults.string(forKey: K.binaryPath) ?? ""
        autoStart = defaults.bool(forKey: K.autoStart)
        autoRestart = defaults.bool(forKey: K.autoRestart)
        launchHidden = defaults.bool(forKey: K.launchHidden)
        hideDockIcon = defaults.bool(forKey: K.hideDockIcon)
        refreshInstalledState()
    }

    // MARK: - Binary resolution (bundled → user override → default path)

    struct ResolvedBinary { let path: String; let source: String }

    func resolveBinary() -> ResolvedBinary? {
        let fm = FileManager.default
        let override = userBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return ResolvedBinary(path: override, source: "override")
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("micago").path,
           fm.isExecutableFile(atPath: bundled) {
            return ResolvedBinary(path: bundled, source: "bundled")
        }
        let def = (NSHomeDirectory() as NSString).appendingPathComponent(".micago/bin/micago")
        if fm.isExecutableFile(atPath: def) {
            return ResolvedBinary(path: def, source: "default")
        }
        return nil
    }

    var binaryExists: Bool { resolveBinary() != nil }

    var resolvedBinaryPath: String? { resolveBinary()?.path }

    /// True while a companion-launched process is alive (or being launched).
    var isProcessAlive: Bool {
        switch processState {
        case .running, .starting, .stopping: return true
        default: return false
        }
    }

    private func refreshInstalledState() {
        if let r = resolveBinary() {
            binarySource = r.source
            if case .notInstalled = processState { processState = .stopped }
        } else {
            binarySource = "none"
            if process == nil { processState = .notInstalled }
        }
    }

    // MARK: - Lifecycle

    func start() {
        restartWork?.cancel(); restartWork = nil
        guard process == nil else { return }
        guard let resolved = resolveBinary() else {
            processState = .notInstalled
            binarySource = "none"
            appendLog("error: no runnable backend binary (set a path, or build the bundled binary)")
            return
        }

        binarySource = resolved.source
        intentionalStop = false
        failureKind = nil
        nextRestartInfo = nil
        processState = .starting

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved.path)

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
            }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(code: code) }
        }

        do {
            try proc.run()
            process = proc
            processState = .running
            appendLog("started backend (\(resolved.source)): \(resolved.path)")
            scheduleHealthyReset()
        } catch {
            process = nil
            processState = .failed("could not launch: \(error.localizedDescription)")
            appendLog("error: failed to start backend: \(error.localizedDescription)")
        }
    }

    func stop() {
        restartWork?.cancel(); restartWork = nil
        nextRestartInfo = nil
        guard let proc = process else { return }
        intentionalStop = true
        processState = .stopping
        appendLog("stopping backend…")
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

    /// Auto-start at companion launch when enabled, the binary exists, and no
    /// external/unmanaged server already answers (never start over a live one).
    func autoStartIfNeeded(externalReachable: Bool) {
        guard autoStart, process == nil, binaryExists, !externalReachable else { return }
        appendLog("auto-start: launching backend")
        start()
    }

    /// Stop our child cleanly on app quit. Never affects external processes.
    func shutdownForQuit() {
        restartWork?.cancel()
        intentionalStop = true
        process?.terminate()
    }

    // MARK: - Termination handling + auto-restart backoff

    private func handleTermination(code: Int32) {
        process = nil
        lastExitCode = code
        healthyResetWork?.cancel(); healthyResetWork = nil

        if intentionalStop {
            processState = .stopped
            nextRestartInfo = nil
            restartAttempt = 0
            appendLog("backend stopped")
            return
        }

        // Unexpected exit: classify from recent output.
        let kind = classifyFailure()
        failureKind = kind
        let reason = summarize(kind: kind, code: code)
        lastExitReason = reason
        processState = .failed(reason)
        appendLog("backend exited unexpectedly (code \(code)): \(reason)")
        scheduleRestartIfEnabled(kind: kind)
    }

    private func scheduleRestartIfEnabled(kind: BackendFailureKind) {
        guard autoRestart else { nextRestartInfo = nil; return }
        if kind == .fullDiskAccess {
            nextRestartInfo = "Will not auto-restart: Full Disk Access is required."
            return
        }
        if restartAttempt >= maxConsecutiveCrashes {
            nextRestartInfo = "Stopped after \(maxConsecutiveCrashes) crashes — start manually."
            return
        }
        let delay = backoff[min(restartAttempt, backoff.count - 1)]
        restartAttempt += 1
        nextRestartInfo = "Restarting in \(Int(delay))s (attempt \(restartAttempt) of \(maxConsecutiveCrashes))…"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.autoRestart, !self.intentionalStop, self.process == nil else { return }
            self.start()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// If the server stays up for a while, reset the crash counter so a later,
    /// unrelated crash gets a fresh backoff budget.
    private func scheduleHealthyReset() {
        healthyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .running = self.processState else { return }
            self.restartAttempt = 0
            self.nextRestartInfo = nil
        }
        healthyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    // MARK: - Failure classification

    private func classifyFailure() -> BackendFailureKind {
        let recent = logLines.suffix(30).joined(separator: "\n").lowercased()
        if recent.contains("operation not permitted") || recent.contains("unable to open database file") {
            return .fullDiskAccess
        }
        if recent.contains("address already in use") || recent.contains("bind:") || recent.contains("eaddrinuse") {
            return .addressInUse
        }
        if recent.contains("auth token is empty") || recent.contains("invalid ") || recent.contains("parse ") {
            return .configInvalid
        }
        if recent.contains("messages") && recent.contains("not running") {
            return .messagesNotRunning
        }
        return .unknown
    }

    private func summarize(kind: BackendFailureKind, code: Int32) -> String {
        switch kind {
        case .fullDiskAccess: return "Full Disk Access is required to read the Messages database."
        case .addressInUse: return "The listen address is already in use (another server may be running)."
        case .configInvalid: return "The server configuration is missing or invalid (~/.micago/config.yaml)."
        case .messagesNotRunning: return "Messages.app is required for sending."
        case .unknown: return lastStderrLine ?? "Backend exited with code \(code)."
        }
    }

    // MARK: - Logs (with token redaction)

    private func appendLog(_ line: String) {
        let safe = Self.redact(line)
        logLines.append(safe)
        lastStderrLine = safe
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }

    /// Defensively mask anything that looks like a bearer/auth token so captured
    /// stdout/stderr never shows a secret (the server prints the token on first
    /// run). Replaces long hex runs and `Bearer <x>`.
    static func redact(_ line: String) -> String {
        var out = line
        if let re = try? NSRegularExpression(pattern: "[0-9a-fA-F]{24,}") {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "••••")
        }
        if let re = try? NSRegularExpression(pattern: "(?i)bearer\\s+\\S+") {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "Bearer ••••")
        }
        return out
    }
}

// MARK: - Combined display state (process + reachability)

/// What the UI shows, combining the managed process state with API reachability.
/// "externalUnmanaged" = something answers health but we did not launch it.
enum ServerDisplayState: Equatable {
    case notInstalled
    case stopped
    case starting
    case running           // managed process up + reachable
    case startingUnreachable // managed process up but not yet answering
    case stopping
    case externalUnmanaged // reachable, but not launched by us
    case crashed

    var label: String {
        switch self {
        case .notInstalled: return "No backend installed"
        case .stopped: return "Stopped"
        case .starting, .startingUnreachable: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .externalUnmanaged: return "External server (unmanaged)"
        case .crashed: return "Crashed"
        }
    }

    /// Short label for the compact toolbar status capsule (e.g. "Running",
    /// "Stopped", "External"). The longer `label` is used elsewhere.
    var compactLabel: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .stopped: return "Stopped"
        case .starting, .startingUnreachable: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .externalUnmanaged: return "External"
        case .crashed: return "Crashed"
        }
    }

    var isHealthyDot: Bool {
        switch self {
        case .running, .externalUnmanaged: return true
        default: return false
        }
    }
}

func serverDisplayState(process: BackendProcessState, reachable: Bool) -> ServerDisplayState {
    switch process {
    case .running:
        return reachable ? .running : .startingUnreachable
    case .starting:
        return .starting
    case .stopping:
        return .stopping
    case .notInstalled:
        return reachable ? .externalUnmanaged : .notInstalled
    case .stopped:
        return reachable ? .externalUnmanaged : .stopped
    case .exited, .failed:
        return reachable ? .externalUnmanaged : .crashed
    }
}
