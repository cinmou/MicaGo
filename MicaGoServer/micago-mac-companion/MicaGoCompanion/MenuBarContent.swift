import SwiftUI
import AppKit

/// Menu-bar control surface. Coexists with the main window (it does not replace
/// it). Reads the same shared `BackendController` / `AppModel` / `RuntimeMonitor`
/// as the Dashboard, so state is always consistent.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var runtime: RuntimeMonitor
    @EnvironmentObject var backend: BackendController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = serverDisplayState(process: backend.processState, reachable: model.reachable)

        Text("MicaGo — \(state.label)")

        if let lan = lanURL {
            Text("LAN: \(lan)")
        }
        if let pub = publicURL {
            Text("Public: \(pub)")
        }

        Divider()

        Button("Open Dashboard") { presentDashboard(openWindow: openWindow) }

        Button("Start Server") { backend.start() }
            .disabled(!canStart(state))
        Button("Stop Server") { backend.stop() }
            .disabled(!canStop)

        Button(runtime.messagesRunning ? "Messages.app is running" : "Open Messages") {
            runtime.openMessages()
        }
        .disabled(runtime.messagesRunning)

        Toggle("Keep Awake", isOn: Binding(
            get: { runtime.keepAwakeActive },
            set: { runtime.setKeepAwake($0) }
        ))

        Divider()

        Button("Quit MicaGo Companion") {
            backend.shutdownForQuit()
            NSApp.terminate(nil)
        }
    }

    // C25: show the Android-usable LAN address (loopback is no longer surfaced).
    private var lanURL: String? {
        model.urls?.lan.first?.baseUrl
    }

    private var publicURL: String? {
        guard let pub = model.urls?.public, pub.enabled, !pub.baseUrl.isEmpty else { return nil }
        return pub.baseUrl
    }

    private func canStart(_ state: ServerDisplayState) -> Bool {
        guard backend.binaryExists else { return false }
        if state == .externalUnmanaged { return false } // never start over a live external server
        switch backend.processState {
        case .stopped, .exited, .failed, .notInstalled: return true
        default: return false
        }
    }

    private var canStop: Bool {
        switch backend.processState {
        case .running, .starting: return true
        default: return false
        }
    }
}
