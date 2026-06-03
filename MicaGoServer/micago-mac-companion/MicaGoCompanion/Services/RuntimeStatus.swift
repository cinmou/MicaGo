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

/// KeepAwakeController prevents the Mac from idle/system sleeping while the relay
/// should stay reachable. It owns a `caffeinate` child process (conservative,
/// matches what a Mac admin would run by hand). Keep-awake lives in the
/// companion, never in the Go relay core.
@MainActor
final class KeepAwakeController: ObservableObject {
    @Published private(set) var active = false

    private var process: Process?

    func setActive(_ on: Bool) {
        if on {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard process == nil else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -i: prevent idle sleep, -s: prevent system sleep (on AC),
        // -w <pid>: exit automatically if the companion exits (safety).
        proc.arguments = ["-i", "-s", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.active = false
            }
        }
        do {
            try proc.run()
            process = proc
            active = true
        } catch {
            process = nil
            active = false
        }
    }

    func stop() {
        process?.terminate()
        // terminationHandler clears state asynchronously.
    }
}
