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
    @StateObject private var contacts = ContactsStore()

    var body: some Scene {
        WindowGroup(id: "dashboard") {
            ContentView()
                .environmentObject(model)
                .environmentObject(runtime)
                .environmentObject(backend)
                .environmentObject(contacts)
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
            // Silent launch: close the window opened by the WindowGroup.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.styleMask.contains(.titled) {
                    window.close()
                }
                applyActivationPolicy()
            }
        }

        // Apply the Dock-icon policy now (and again whenever a window opens/closes).
        applyActivationPolicy()

        // Re-evaluate the policy whenever a window closes so the app can drop
        // back to menu-bar-only (accessory) once the Dashboard is dismissed.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            // willClose fires before the window leaves the list; re-evaluate next tick.
            DispatchQueue.main.async { applyActivationPolicy() }
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

    // Keep the app (and menu bar) alive when the Dashboard window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.activate(ignoringOtherApps: true) }
        return true
    }
}

extension BackendController {
    static let shared = BackendController()
}

/// Whether a main Dashboard window (titled, visible) is currently on screen.
/// The MenuBarExtra's status window is an untitled panel and is excluded.
func hasVisibleDashboardWindow() -> Bool {
    NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
}

/// Single source of truth for the app's Dock presence. Accessory (no Dock icon)
/// only when the user enabled "Hide Dock icon" AND no Dashboard window is open;
/// otherwise regular. The menu-bar item is unaffected by activation policy.
func applyActivationPolicy() {
    let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
    let target: NSApplication.ActivationPolicy = (hideDock && !hasVisibleDashboardWindow()) ? .accessory : .regular
    if NSApp.activationPolicy() != target {
        NSApp.setActivationPolicy(target)
    }
}

/// Brings the app to the foreground and opens the dashboard window. Used by the
/// menu-bar "Open Dashboard" action and after a silent launch. Always restores
/// the regular activation policy first so the window can take focus.
@MainActor
func presentDashboard(openWindow: OpenWindowAction) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "dashboard")
}
