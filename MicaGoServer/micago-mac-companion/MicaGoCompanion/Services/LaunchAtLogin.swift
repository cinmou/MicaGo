import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService for the "Launch at Login" toggle. Kept
/// deliberately conservative: it registers the main app as a login item via
/// the modern ServiceManagement API (macOS 13+) and never installs a separate
/// helper or daemon.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// Returns a human-readable status string for display.
    static var statusDescription: String {
        guard #available(macOS 13.0, *) else { return "unavailable (requires macOS 13+)" }
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval in System Settings"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    static func set(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
