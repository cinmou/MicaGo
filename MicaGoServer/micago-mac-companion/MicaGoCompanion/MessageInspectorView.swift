import SwiftUI

// MARK: - Message Inspector (debug)

/// A debug/power-user tool for finding and inspecting problematic messages.
/// Backed by GET /api/debug/recent-messages (live chat.db, bearer-auth). It is
/// not a chat client — read-only, with redaction-safe payloads.
struct MessageInspectorPage: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var vm = MessageInspectorModel()
    @State private var selected: DebugMessage?

    var body: some View {
        Group {
            FiltersCard(vm: vm)

            if let err = vm.error {
                SectionCard(title: "Message Inspector") {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !vm.groups.isEmpty {
                GroupSummaryCard(vm: vm)
            }

            ResultsCard(vm: vm, selected: $selected)
        }
        .task { await vm.autoRefresh(model) }
        .sheet(item: $selected) { msg in
            MessageDetailSheet(message: msg)
        }
    }
}

// MARK: - View model

@MainActor
final class MessageInspectorModel: ObservableObject {
    @Published var query = ""
    @Published var senderMode: SenderMode = .all
    @Published var specificSender = ""
    @Published var chatGuid = ""        // "" = all
    @Published var direction = "all"
    @Published var type = "all"
    @Published var attachments = "all"
    @Published var groupBy = "flat"
    @Published var limit = 100

    @Published private(set) var messages: [DebugMessage] = []
    @Published private(set) var groups: [DebugGroup] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    enum SenderMode: String, CaseIterable, Identifiable {
        case all, fromMe, unknown, specific
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All senders"
            case .fromMe: return "From me"
            case .unknown: return "Unknown sender"
            case .specific: return "Specific handle"
            }
        }
    }

    private weak var model: AppModel?

    func autoRefresh(_ model: AppModel) async {
        self.model = model
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    func reload() async {
        guard let model, let base = model.baseURL else {
            error = "Server is not reachable. Start the server first."
            return
        }
        loading = true
        error = nil
        let client = APIClient(baseURL: base, token: model.token)

        // The sender filters map onto direction (from me) or a server-side
        // handle filter; "unknown sender" is refined client-side (no handle).
        var dir = direction
        var senderParam = ""
        switch senderMode {
        case .all: break
        case .fromMe: dir = "outgoing"
        case .specific: senderParam = specificSender
        case .unknown: break
        }

        do {
            var resp = try await client.debugRecentMessages(
                q: query, chatGuid: chatGuid, sender: senderParam,
                direction: dir, type: type, hasAttachments: attachments,
                groupBy: groupBy, limit: limit)

            if senderMode == .unknown {
                resp.data = resp.data.filter { !$0.isFromMe && ($0.handleId?.isEmpty ?? true) }
            }
            messages = resp.data
            groups = resp.groups ?? []
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            messages = []
            groups = []
        }
        loading = false
    }

    /// Distinct senders in the current result set, for the specific-handle menu.
    var sendersInResults: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for m in messages where !m.isFromMe {
            if let h = m.handleId, !h.isEmpty, !seen.contains(h) {
                seen.insert(h); out.append(h)
            }
        }
        return out.sorted()
    }
}

// MARK: - Filters

private struct FiltersCard: View {
    @ObservedObject var vm: MessageInspectorModel
    private let limits = [20, 50, 100, 500]

    var body: some View {
        SectionCard(title: "Message Inspector") {
            Text("Find and inspect problematic messages from the live chat.db. Read-only debug tool — payloads are redaction-safe (no token, file paths, or credentials).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text, chat, sender, or attachment name", text: $vm.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await vm.reload() } }
            }

            // Row 1: sender + direction
            HStack(spacing: 12) {
                Picker("Sender", selection: $vm.senderMode) {
                    ForEach(MessageInspectorModel.SenderMode.allCases) { Text($0.label).tag($0) }
                }
                if vm.senderMode == .specific {
                    Picker("Handle", selection: $vm.specificSender) {
                        Text("—").tag("")
                        ForEach(vm.sendersInResults, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Direction", selection: $vm.direction) {
                    Text("All").tag("all")
                    Text("Incoming").tag("incoming")
                    Text("Outgoing").tag("outgoing")
                }
                .disabled(vm.senderMode == .fromMe)
            }

            // Row 2: type + attachments
            HStack(spacing: 12) {
                Picker("Type", selection: $vm.type) {
                    Text("All").tag("all")
                    Text("Text").tag("text")
                    Text("Attachment").tag("attachment")
                    Text("Image").tag("image")
                    Text("Video").tag("video")
                    Text("Audio").tag("audio")
                    Text("Voice").tag("voice")
                    Text("File").tag("file")
                    Text("Reaction candidate").tag("reaction")
                    Text("Reply candidate").tag("reply")
                    Text("Service candidate").tag("service")
                    Text("Unsupported").tag("unsupported")
                }
                Picker("Attachments", selection: $vm.attachments) {
                    Text("All").tag("all")
                    Text("Has attachments").tag("has")
                    Text("No attachments").tag("none")
                    Text("Image").tag("image")
                    Text("Audio/voice").tag("audio")
                    Text("Unsupported type").tag("unsupported")
                }
            }

            // Row 3: chat + group-by + limit
            HStack(spacing: 12) {
                Picker("Chat", selection: $vm.chatGuid) {
                    Text("All chats").tag("")
                    ForEach(chatOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Group by", selection: $vm.groupBy) {
                    Text("Flat").tag("flat")
                    Text("Sender").tag("sender")
                    Text("Chat").tag("chat")
                    Text("Type").tag("type")
                    Text("Unsupported reason").tag("unsupported")
                }
                Picker("Show", selection: $vm.limit) {
                    ForEach(limits, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            HStack {
                Spacer()
                if vm.loading { ProgressView().controlSize(.small) }
                Button { Task { await vm.reload() } } label: {
                    Label("Apply", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        // Re-query immediately on discrete picker changes (search uses Submit/Apply).
        .onChange(of: vm.senderMode) { _ in Task { await vm.reload() } }
        .onChange(of: vm.direction) { _ in Task { await vm.reload() } }
        .onChange(of: vm.type) { _ in Task { await vm.reload() } }
        .onChange(of: vm.attachments) { _ in Task { await vm.reload() } }
        .onChange(of: vm.chatGuid) { _ in Task { await vm.reload() } }
        .onChange(of: vm.groupBy) { _ in Task { await vm.reload() } }
        .onChange(of: vm.limit) { _ in Task { await vm.reload() } }
        .onChange(of: vm.specificSender) { _ in Task { await vm.reload() } }
    }

    // Build a chat option list from whatever chats appear in the loaded model.
    @EnvironmentObject var model: AppModel
    private var chatOptions: [(String, String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for m in vm.messages {
            guard let g = m.chatGuid, !g.isEmpty, !seen.contains(g) else { continue }
            seen.insert(g)
            out.append((g, m.chatLabel))
        }
        return out.sorted { $0.1 < $1.1 }
    }
}

// MARK: - Group summary

private struct GroupSummaryCard: View {
    @ObservedObject var vm: MessageInspectorModel

    var body: some View {
        SectionCard(title: "Groups (\(vm.groups.count))") {
            ForEach(vm.groups) { g in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.label).fontWeight(.medium).lineLimit(1)
                        Text(subtitle(g)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(g.count)").font(.callout).monospacedDigit().fontWeight(.semibold)
                    if g.unsupportedCount > 0 {
                        Text("· \(g.unsupportedCount) unsupported")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
    }

    private func subtitle(_ g: DebugGroup) -> String {
        var parts: [String] = []
        if g.attachmentCount > 0 { parts.append("\(g.attachmentCount) attachments") }
        if let ts = g.latestTimestamp { parts.append("latest \(relativeTime(ts))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Results

private struct ResultsCard: View {
    @ObservedObject var vm: MessageInspectorModel
    @Binding var selected: DebugMessage?

    var body: some View {
        SectionCard(title: "Messages (\(vm.messages.count))") {
            if vm.messages.isEmpty {
                Text(vm.loading ? "Loading…" : "No messages match the current filters.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(vm.messages) { msg in
                    Button { selected = msg } label: {
                        MessageInspectorRow(message: msg)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                Text("Click a row to open the debug detail and copy redacted JSON.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MessageInspectorRow: View {
    let message: DebugMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.isFromMe ? "arrow.up.right" : "arrow.down.left")
                .foregroundStyle(.secondary).font(.caption)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.senderLabel).font(.callout).fontWeight(.medium).lineLimit(1)
                    Text("· \(message.chatLabel)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let ts = message.dateCreated {
                        Text(relativeTime(ts)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(message.safePreview)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 4) {
                    TypeBadges(message: message)
                    if message.cacheHasAttachments && message.attachments.isEmpty {
                        Badge(text: "no attachment rows", color: .orange)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct TypeBadges: View {
    let message: DebugMessage

    var body: some View {
        let (text, color) = badge(for: message.kind)
        HStack(spacing: 4) {
            Badge(text: text, color: color)
            if message.payloadDataPresent { Badge(text: "payload", color: .purple) }
            if message.balloonBundleId != nil { Badge(text: "interactive", color: .purple) }
        }
    }

    private func badge(for kind: String) -> (String, Color) {
        switch kind {
        case "text": return ("text", .secondary)
        case "image": return ("image", .blue)
        case "video": return ("video", .blue)
        case "audio": return ("audio", .teal)
        case "voice": return ("voice", .teal)
        case "file": return ("file", .gray)
        case "reaction_candidate": return ("reaction?", .pink)
        case "reply_candidate": return ("reply?", .indigo)
        case "service_candidate": return ("service?", .orange)
        case "unsupported_candidate": return ("unsupported", .red)
        default: return (kind, .secondary)
        }
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Detail sheet

private struct MessageDetailSheet: View {
    let message: DebugMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Message Debug").font(.headline)
                Spacer()
                Button {
                    copyToPasteboard(message.clientFixtureJSON)
                } label: { Label("Copy client fixture", systemImage: "ladybug") }
                Button {
                    copyToPasteboard(debugJSON)
                } label: { Label("Copy Debug JSON", systemImage: "doc.on.doc") }
                Button("Close") { dismiss() }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Badge(text: message.kind, color: message.kind == "unsupported_candidate" ? .red : .secondary)
                    if !message.candidates.isEmpty {
                        Text("candidates: \(message.candidates.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    group("Rendering recommendation") {
                        kv("Recommendation", message.renderingRecommendation)
                        if message.isReactionRow {
                            kv("Reaction target", message.reactionTargetGuid ?? "—")
                        }
                        if message.isReplyRow {
                            kv("Reply target", message.threadOriginatorGuid ?? "—")
                        }
                        if let eff = message.effectLabelText {
                            kv("Effect", "Sent with \(eff)")
                        }
                        if message.isRetractedRow { kv("Unsent", "yes") }
                        if message.isEdited == true { kv("Edited", "yes") }
                    }

                    group("Identity") {
                        kv("GUID", message.guid)
                        kv("ROWID", "\(message.rowid)")
                        kv("Chat GUID", message.chatGuid ?? "—")
                        kv("Chat identifier", message.chatIdentifier ?? "—")
                        kv("Chat display name", message.chatDisplayName ?? "—")
                        kv("Handle / sender", message.handleId ?? "—")
                        kv("Is from me", message.isFromMe ? "yes" : "no")
                        kv("Service", message.service ?? "—")
                        if let acc = message.account { kv("Account", acc) }
                    }

                    group("Text") {
                        kv("Length", "\(message.textLength)")
                        kv("Sanitized preview", message.safePreview)
                        kv("Raw text", message.text ?? "—", mono: true)
                        kv("Has attributedBody", message.hasAttributedBody ? "yes" : "no")
                        if let s = message.subject { kv("Subject", s) }
                    }

                    group("Dates (Unix ms)") {
                        kv("Created", message.dateCreated.map { "\($0)" } ?? "—")
                        kv("Delivered", message.dateDelivered.map { "\($0)" } ?? "—")
                        kv("Read", message.dateRead.map { "\($0)" } ?? "—")
                    }

                    group("iMessage compatibility fields") {
                        kv("associatedMessageType", message.associatedMessageType.map { "\($0)" } ?? "—")
                        kv("associatedMessageGuid", message.associatedMessageGuid ?? "—")
                        kv("threadOriginatorGuid", message.threadOriginatorGuid ?? "—")
                        kv("dateRetracted", message.dateRetracted.map { "\($0)" } ?? "—")
                        kv("dateEdited", message.dateEdited.map { "\($0)" } ?? "—")
                        kv("itemType", message.itemType.map { "\($0)" } ?? "—")
                        kv("groupActionType", message.groupActionType.map { "\($0)" } ?? "—")
                        kv("groupTitle", message.groupTitle ?? "—")
                        kv("balloonBundleId", message.balloonBundleId ?? "—")
                        kv("expressiveSendStyleId", message.expressiveSendStyleId ?? "—")
                        kv("payloadData present", message.payloadDataPresent ? "yes" : "no")
                        kv("error", message.error.map { "\($0)" } ?? "—")
                    }

                    if !message.attachments.isEmpty {
                        group("Attachments (\(message.attachments.count))") {
                            ForEach(message.attachments) { a in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.displayName).fontWeight(.medium).font(.caption)
                                    kv("GUID", a.guid)
                                    kv("MIME / UTI", "\(a.mimeType ?? "—") / \(a.uti ?? "—")")
                                    kv("Transfer name", a.transferName ?? "—")
                                    kv("Kind", a.attachmentKind)
                                    kv("Voice message", a.isVoiceMessage ? "yes" : "no")
                                    kv("Total bytes", "\(a.totalBytes)")
                                    kv("Download URL present", a.hasDownloadUrl ? "yes" : "no")
                                }
                                .padding(.vertical, 3)
                                Divider()
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 640)
    }

    @ViewBuilder private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            content()
        }
    }

    private func kv(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            Text(v)
                .font(mono ? .system(.caption2, design: .monospaced) : .caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Pretty-printed, redaction-safe debug JSON for this message. The server
    /// payload already omits the token, local paths, and tokenized URLs; this
    /// re-encodes the decoded message so the copied text matches what is shown.
    private var debugJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(message),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}

// MARK: - Shared

/// Compact relative time for inspector rows/groups.
func relativeTime(_ unixMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000)
    let diff = Date().timeIntervalSince(date)
    if diff < 60 { return "now" }
    if diff < 3600 { return "\(Int(diff / 60))m" }
    if diff < 86400 { return "\(Int(diff / 3600))h" }
    let fmt = DateFormatter()
    fmt.dateFormat = "MMM d"
    return fmt.string(from: date)
}
