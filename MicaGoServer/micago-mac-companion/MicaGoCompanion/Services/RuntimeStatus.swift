import Foundation
import AppKit

/// Local checks/actions for Messages.app. The companion runs on the same Mac as
/// the server, so it can check this directly via NSWorkspace — no server round
/// trip and no Automation permission required.
enum MessagesApp {
    static let bundleID = "com.apple.MobileSMS"

    static func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// RuntimeMonitor is a single shared source of macOS-local runtime state
/// (Messages.app running, Keep-Awake) so multiple companion surfaces (Dashboard,
/// Permissions) reflect the same values. Keep-awake lives in the companion,
/// never in the Go relay core: it owns a conservative `caffeinate` child process.
@MainActor
final class RuntimeMonitor: ObservableObject {
    static let shared = RuntimeMonitor()

    @Published private(set) var messagesRunning: Bool = MessagesApp.isRunning()
    @Published private(set) var keepAwakeActive: Bool = false

    private var caffeinate: Process?
    private var pollTask: Task<Void, Never>?

    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.messagesRunning = MessagesApp.isRunning()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshMessages() {
        messagesRunning = MessagesApp.isRunning()
    }

    func openMessages() {
        MessagesApp.open()
    }

    func setKeepAwake(_ on: Bool) {
        if on {
            startCaffeinate()
        } else {
            stopCaffeinate()
        }
    }

    private func startCaffeinate() {
        guard caffeinate == nil else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -i: prevent idle sleep, -s: prevent system sleep (on AC),
        // -w <pid>: exit automatically if the companion exits (safety).
        proc.arguments = ["-i", "-s", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.caffeinate = nil
                self?.keepAwakeActive = false
            }
        }
        do {
            try proc.run()
            caffeinate = proc
            keepAwakeActive = true
        } catch {
            caffeinate = nil
            keepAwakeActive = false
        }
    }

    private func stopCaffeinate() {
        caffeinate?.terminate()
        // terminationHandler clears state asynchronously.
    }
}
