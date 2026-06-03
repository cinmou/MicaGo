import Foundation

/// Launches and stops the Go relay server binary as a child process. The
/// companion does not embed the server; it controls a separate `micago`
/// executable and talks to its local HTTP API.
@MainActor
final class ServerController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var logLines: [String] = []
    @Published var binaryPath: String {
        didSet { UserDefaults.standard.set(binaryPath, forKey: Self.binaryPathKey) }
    }

    private var process: Process?
    private static let binaryPathKey = "serverBinaryPath"
    private static let maxLogLines = 250

    /// Default build location documented in the spec:
    ///   go build -o ~/.micago/bin/micago ./cmd/micago
    static var defaultBinaryPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".micago/bin/micago")
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.binaryPathKey)
        binaryPath = (stored?.isEmpty == false) ? stored! : Self.defaultBinaryPath
    }

    var binaryExists: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    func start() {
        guard process == nil else { return }
        guard binaryExists else {
            appendLog("error: server binary not found or not executable at \(binaryPath)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

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

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
                self?.appendLog("server process exited")
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            appendLog("started server: \(binaryPath)")
        } catch {
            appendLog("error: failed to start server: \(error.localizedDescription)")
            process = nil
            isRunning = false
        }
    }

    func stop() {
        guard let proc = process else { return }
        appendLog("stopping server…")
        proc.terminate()
        // Best-effort: the terminationHandler clears state asynchronously.
    }

    func restart() {
        if isRunning {
            stop()
            // Give the process a moment to exit before relaunching.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.start()
            }
        } else {
            start()
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }
}
