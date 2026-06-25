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

        Text("micaGO — \(state.label)")

        Divider()

        Button("Open Dashboard") { presentDashboard(openWindow: openWindow) }

        Button("Start Server") { backend.start() }
            .disabled(!canStart(state))
        Button("Stop Server") { backend.stop() }
            .disabled(!canStop)

        Toggle("Keep Awake", isOn: Binding(
            get: { runtime.keepAwakeActive },
            set: { runtime.setKeepAwake($0) }
        ))

        Divider()

        Button("Quit micaGO Companion") {
            backend.shutdownForQuit()
            NSApp.terminate(nil)
        }
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
