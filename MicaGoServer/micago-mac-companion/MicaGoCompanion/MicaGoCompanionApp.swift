import SwiftUI
import AppKit

@main
struct MicaGoCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Shared singletons so bootstrap/shutdown work even with no window open
    // (silent launch / menu-bar-only mode) and the AppDelegate can reach them.
    @StateObject private var model = AppModel.shared
    @StateObject private var runtime = RuntimeMonitor.shared
    @StateObject private var backend = BackendController.shared

    var body: some Scene {
        WindowGroup(id: "dashboard") {
            ContentView()
                .environmentObject(model)
                .environmentObject(runtime)
                .environmentObject(backend)
        }
        .defaultSize(width: 1000, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(runtime)
                .environmentObject(backend)
        } label: {
            Image(systemName: menuBarSymbol)
        }
    }

    private var menuBarSymbol: String {
        switch backend.processState {
        case .running: return "bolt.horizontal.circle.fill"
        case .starting, .stopping: return "bolt.horizontal.circle"
        case .failed, .exited: return "exclamationmark.triangle.fill"
        case .notInstalled: return "bolt.horizontal.circle"
        case .stopped: return model.reachable ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
        }
    }
}

/// AppDelegate owns app-lifetime bootstrap (so polling/auto-start run even when
/// launched silently with no window) and clean shutdown of the child backend.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let hidden = UserDefaults.standard.bool(forKey: "launchHidden")
        if hidden {
            // Menu-bar accessory: no Dock icon, no window at launch.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                for window in NSApp.windows where !(window is NSPanel) {
                    window.close()
                }
            }
        }

        // Bootstrap regardless of whether a window is shown.
        Task { @MainActor in
            AppModel.shared.reloadConfig()
            await AppModel.shared.refresh()
            BackendController.shared.autoStartIfNeeded(externalReachable: AppModel.shared.reachable)
            AppModel.shared.startPolling()
            RuntimeMonitor.shared.startMonitoring()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackendController.shared.shutdownForQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.activate(ignoringOtherApps: true) }
        return true
    }
}

extension BackendController {
    static let shared = BackendController()
}

/// Brings the app to the foreground and opens the dashboard window. Used by the
/// menu-bar "Open Dashboard" action and after a silent launch.
@MainActor
func presentDashboard(openWindow: OpenWindowAction) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "dashboard")
}
