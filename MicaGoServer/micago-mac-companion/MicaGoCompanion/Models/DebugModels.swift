import Foundation

// Codable mirrors of GET /api/debug/recent-messages (companion Message Inspector).
// All fields are redaction-safe by construction on the server: no bearer token,
// no local file paths, and download URLs are reduced to a boolean.

struct DebugRecentResponse: Codable {
    var data: [DebugMessage]
    var groups: [DebugGroup]?
    var meta: DebugMeta
}

struct DebugMeta: Codable {
    var limit: Int
    var offset: Int
    var groupBy: String
    var total: Int
}

struct DebugAttachment: Codable, Identifiable, Hashable {
    var guid: String
    var filename: String?
    var transferName: String?
    var mimeType: String?
    var uti: String?
    var attachmentKind: String
    var isVoiceMessage: Bool
    var totalBytes: Int64
    var hasDownloadUrl: Bool

    var id: String { guid }

    var displayName: String {
        if let t = transferName, !t.isEmpty { return t }
        if let f = filename, !f.isEmpty { return f }
        return "Attachment"
    }
}

struct DebugMessage: Codable, Identifiable, Hashable {
    var guid: String
    var rowid: Int64
    var chatGuid: String?
    var chatIdentifier: String?
    var chatDisplayName: String?

    var handleId: String?
    var handleService: String?
    var isFromMe: Bool
    var service: String?
    var account: String?

    var text: String?
    var textLength: Int
    var hasAttributedBody: Bool
    var subject: String?

    var dateCreated: Int64?
    var dateDelivered: Int64?
    var dateRead: Int64?

    var associatedMessageType: Int64?
    var associatedMessageGuid: String?
    var threadOriginatorGuid: String?
    var itemType: Int64?
    var groupActionType: Int64?
    var groupTitle: String?
    var balloonBundleId: String?
    var expressiveSendStyleId: String?
    var payloadDataPresent: Bool
    var error: Int64?
    var dateRetracted: Int64?
    var dateEdited: Int64?
    var isRetracted: Bool?
    var isEdited: Bool?

    var cacheHasAttachments: Bool
    var attachments: [DebugAttachment]

    var kind: String
    var candidates: [String]

    var id: String { guid }

    /// A preview that never shows a raw control payload as the main text.
    var safePreview: String {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            if !attachments.isEmpty { return "[\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")]" }
            if kind == "unsupported_candidate" { return "Unsupported iMessage item" }
            return "(no text)"
        }
        if isControlLike(t) { return "Control-like payload" }
        return t
    }

    var senderLabel: String {
        if isFromMe { return "You" }
        if let h = handleId, !h.isEmpty { return h }
        return "Unknown"
    }

    var chatLabel: String {
        if let d = chatDisplayName, !d.isEmpty { return d }
        if let c = chatIdentifier, !c.isEmpty { return c }
        return chatGuid ?? "—"
    }

    private func isControlLike(_ s: String) -> Bool {
        let cleaned = s.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return true }
        return !cleaned.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: - Rendering recommendation (Part K)

    var isReactionRow: Bool {
        guard let t = associatedMessageType else { return false }
        return t != 0 && t != 1000 && (associatedMessageGuid?.isEmpty == false)
    }
    var isReplyRow: Bool { (threadOriginatorGuid?.isEmpty == false) }
    var isServiceRow: Bool {
        (itemType ?? 0) != 0 || (groupActionType ?? 0) != 0 || (groupTitle?.isEmpty == false)
    }
    var isRetractedRow: Bool { (isRetracted ?? false) || dateRetracted != nil }

    /// Human label for the send effect, or nil.
    var effectLabelText: String? {
        guard let id = expressiveSendStyleId, !id.isEmpty else { return nil }
        let map: [String: String] = [
            "com.apple.MobileSMS.expressivesend.impact": "Slam",
            "com.apple.MobileSMS.expressivesend.loud": "Loud",
            "com.apple.MobileSMS.expressivesend.gentle": "Gentle",
            "com.apple.MobileSMS.expressivesend.invisibleink": "Invisible Ink",
            "com.apple.messages.effect.CKEchoEffect": "Echo",
            "com.apple.messages.effect.CKSpotlightEffect": "Spotlight",
            "com.apple.messages.effect.CKHappyBirthdayEffect": "Balloons",
            "com.apple.messages.effect.CKConfettiEffect": "Confetti",
            "com.apple.messages.effect.CKHeartEffect": "Love",
            "com.apple.messages.effect.CKLasersEffect": "Lasers",
            "com.apple.messages.effect.CKFireworksEffect": "Fireworks",
            "com.apple.messages.effect.CKSparklesEffect": "Celebration",
        ]
        return map[id] ?? "an effect"
    }

    /// The single best rendering recommendation for a client.
    var renderingRecommendation: String {
        if isRetractedRow { return "service event (unsent)" }
        if isReactionRow { return "tapback (attach to target)" }
        if isReplyRow { return "reply (quote target)" }
        if isServiceRow { return "service event" }
        if effectLabelText != nil { return "normal text + effect hint" }
        if !attachments.isEmpty { return "attachment(s)" }
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "unsupported (no content)" }
        if isControlLike(t) { return "unsupported (control-like)" }
        return "normal text"
    }

    /// Reaction target GUID parsed from the p:/bp: prefix, if any.
    var reactionTargetGuid: String? {
        guard let raw = associatedMessageGuid?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        if raw.hasPrefix("p:"), let slash = raw.firstIndex(of: "/") {
            return String(raw[raw.index(after: slash)...])
        }
        if raw.hasPrefix("bp:") { return String(raw.dropFirst(3)) }
        return raw
    }

    /// A sanitized, MicaGo-client-shaped JSON fixture for Flutter tests.
    var clientFixtureJSON: String {
        var obj: [String: Any] = [
            "guid": guid,
            "isFromMe": isFromMe,
            "payloadDataPresent": payloadDataPresent,
        ]
        if let v = text { obj["text"] = v }
        if let v = chatGuid { obj["chatGuid"] = v }
        if let v = handleId { obj["handle"] = ["id": v] }
        if let v = service { obj["service"] = v }
        if let v = dateCreated { obj["dateCreated"] = v }
        if let v = dateDelivered { obj["dateDelivered"] = v }
        if let v = dateRead { obj["dateRead"] = v }
        if let v = associatedMessageType { obj["associatedMessageType"] = v }
        if let v = associatedMessageGuid { obj["associatedMessageGuid"] = v }
        if let v = threadOriginatorGuid { obj["threadOriginatorGuid"] = v }
        if let v = itemType { obj["itemType"] = v }
        if let v = groupActionType { obj["groupActionType"] = v }
        if let v = groupTitle { obj["groupTitle"] = v }
        if let v = balloonBundleId { obj["balloonBundleId"] = v }
        if let v = expressiveSendStyleId { obj["expressiveSendStyleId"] = v }
        if let v = error { obj["error"] = v }
        if let v = dateRetracted { obj["dateRetracted"] = v }
        if let v = dateEdited { obj["dateEdited"] = v }
        obj["isRetracted"] = isRetracted ?? (dateRetracted != nil)
        obj["isEdited"] = isEdited ?? (dateEdited != nil)
        obj["cacheHasAttachments"] = cacheHasAttachments
        if let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}

struct DebugGroup: Codable, Identifiable, Hashable {
    var key: String
    var label: String
    var count: Int
    var unsupportedCount: Int
    var attachmentCount: Int
    var latestTimestamp: Int64?

    var id: String { key }
}
