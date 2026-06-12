import Foundation

// Codable mirrors of the v0.11.3 sync-control API.
// See docs/spec-v0.11.3-sync-control-and-privacy-rules.md.

struct SyncRule: Codable, Identifiable, Hashable {
    var targetKind: String   // "chat" | "handle"
    var targetValue: String
    var syncMode: String     // "allow" | "block" | "inherit"
    var pushMode: String     // "enabled" | "muted" | "inherit"
    var createdAt: Int64
    var updatedAt: Int64

    var id: String { "\(targetKind):\(targetValue)" }
}

struct SyncRulesResponse: Codable {
    var defaultSyncPolicy: String   // "allow_all" | "block_all"
    var defaultPushPolicy: String   // "enabled" | "muted"
    var rules: [SyncRule]
}

struct SyncSettings: Codable, Equatable {
    var backfillMode: String
    var recentMessagesPerChat: Int
    var includeIMessage: Bool
    var includeSMS: Bool
    var includeRCS: Bool
    var includeUnknown: Bool
    var includeDebugInNormal: Bool

    static let defaults = SyncSettings(backfillMode: "hybrid",
                                       recentMessagesPerChat: 100,
                                       includeIMessage: true,
                                       includeSMS: true,
                                       includeRCS: true,
                                       includeUnknown: false,
                                       includeDebugInNormal: false)
}

struct SyncSettingsResponse: Codable {
    var settings: SyncSettings
    var diagnostics: SyncDiagnostics?
}

// GET /api/messages/recent -> { data: [RecentMessage], meta: {...} }
struct RecentMessagesResponse: Codable {
    var data: [RecentMessage]
}

struct RecentMessage: Codable, Identifiable {
    var guid: String
    var text: String?
    var service: String?
    var dateCreated: Int64?
    var isFromMe: Bool
    var handle: HandleRef?

    var id: String { guid }
}

struct HandleRef: Codable, Hashable {
    var id: String
    var service: String?
}

// GET /api/chats -> { data: [ChatSummary], meta: {...} }
struct ChatListResponse: Codable {
    var data: [ChatSummary]
}

struct ChatSummary: Codable, Identifiable {
    var guid: String
    var chatIdentifier: String?
    var serviceName: String?
    var displayName: String?
    var isArchived: Bool

    var id: String { guid }

    var label: String {
        if let d = displayName, !d.isEmpty { return d }
        if let c = chatIdentifier, !c.isEmpty { return c }
        return guid
    }
}
