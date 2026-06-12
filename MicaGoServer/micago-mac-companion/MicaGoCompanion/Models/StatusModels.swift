import Foundation

// Codable mirrors of the server's GET /api/server/status payload.
// See MicaGoServer/docs/spec-v0.9.0-client-api-contract.md and
// spec-v0.10.0-mac-companion.md.

struct ServerStatus: Codable {
    var ok: Bool
    var version: String
    var startedAt: Int64
    var uptimeSeconds: Int64
    var address: AddressStatus
    var store: String
    var auth: AuthStatus
    var sync: SyncStatus
    var notifications: NotificationStatus
    var devices: DevicesStatus
    var websocket: WebSocketStatus
    var permissions: PermissionStatus
    // Added by v0.11.x schema probing. Optional so older servers still decode.
    var capabilities: ServerCapabilities?
    // C17 backend identity: which binary is actually running. Optional so
    // pre-v0.15 servers still decode — its absence itself means "stale backend".
    var backend: BackendStatus?
}

/// C17: identity of the running backend binary, from /api/server/status.
struct BackendStatus: Codable {
    var version: String
    var commit: String
    var buildTime: String
    var goVersion: String
    var osArch: String
    var executablePath: String
    var configPath: String
    var relayDbPath: String
    var chatDbPath: String
    var chatDbOpenOptions: String
    var chatDbImmutable: Bool
}

/// C17: live sync settings echoed by the server (backfill mode, service scope).
struct SyncSettingsStatus: Codable {
    var backfillMode: String
    var recentMessagesPerChat: Int
    var includeIMessage: Bool
    var includeSMS: Bool
    var includeRCS: Bool
    var includeUnknown: Bool
    var includeDebugInNormal: Bool
}

struct ServerCapabilities: Codable {
    var schema: SchemaCapabilities
}

struct SchemaCapabilities: Codable {
    var editedMessages: Bool
    var unsentMessages: Bool
    var readStatus: Bool
    var deliveredStatus: Bool
    var sendError: Bool
    var groupActions: Bool
    var attachmentMetadata: Bool
}

struct AddressStatus: Codable {
    var listen: String
    var baseUrl: String
    var websocketUrl: String
    var lan: [String]
}

struct AuthStatus: Codable {
    var enabled: Bool
}

struct SyncStatus: Codable {
    var loopEnabled: Bool
    var intervalSeconds: Int64
    var lastSyncAt: Int64?
    var lastMessageRowId: Int64?
    // C11 live sync monitor. Optional so older servers still decode.
    var diagnostics: SyncDiagnostics?
    // C17: settings the running backend actually loaded.
    var settings: SyncSettingsStatus?
}

/// Envelope for POST /api/sync/now (`{ok, diagnostics}`).
struct SyncNowResponse: Codable {
    var ok: Bool
    var diagnostics: SyncDiagnostics
}

/// C11 live-sync diagnostics surfaced by GET /api/server/status (and the
/// POST /api/sync/now response). No tokens or full message text.
struct SyncDiagnostics: Codable {
    var lastStartedAt: Int64?
    var lastCompletedAt: Int64?
    var lastDurationMillis: Int64?
    var lastTriggerReason: String?
    var lastInsertedMessages: Int?
    var lastSyncedMessages: Int?
    var lastRowsScanned: Int?
    var lastRenderableRows: Int?
    var lastHiddenDebugRows: Int?
    var lastPerChatLimit: Int?
    var lastBackfillMode: String?
    var lastUpdatePassCount: Int?
    var lastUnsentCount: Int?
    var lastScannedMessageRowId: Int64?
    var lastChatDbMtime: Int64?
    var lastWalMtime: Int64?
    var lastShmMtime: Int64?
    var lastSyncError: String?
    var pendingSendsCount: Int?
    var pendingTriggerCount: Int?
    var lockRetryCount: Int?
    var lateMatchedSendsCount: Int?
    var lastEmittedEventType: String?
    var lastEmittedChatGuid: String?
}

struct NotificationStatus: Codable {
    var enabled: Bool
    var provider: String
    var preview: String
    var providers: [String]
    var implemented: [String]
    var stub: [String]
}

struct DevicesStatus: Codable {
    var count: Int
}

struct WebSocketStatus: Codable {
    var clients: Int
}

struct PermissionStatus: Codable {
    var fullDiskAccess: PermissionCheck
    var attachments: PermissionCheck
    var automation: PermissionCheck
}

struct PermissionCheck: Codable {
    var status: String   // "ok" | "denied" | "unknown"
    var detail: String?
}

// GET /api/devices -> { "data": [DeviceInfo] }
struct DeviceListResponse: Codable {
    var data: [DeviceInfo]
}

struct DeviceInfo: Codable, Identifiable {
    var id: String
    var name: String
    var platform: String
    var clientType: String
    var pushProvider: String
    var pushEnabled: Bool
    var pushTokenSet: Bool
    var lastSeenAt: Int64?
    var createdAt: Int64
    var updatedAt: Int64
}
