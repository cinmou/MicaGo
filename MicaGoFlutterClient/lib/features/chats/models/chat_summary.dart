/// A chat row for the chat list.
///
/// The MicaGo server's `Chat` object (v0.9 contract) currently exposes only
/// `guid, chatIdentifier, serviceName, displayName, isArchived`. The extra
/// fields below (last message, unread, participants, pinned/muted, group) are
/// **optional** and parsed only if a future server adds them — the UI falls back
/// gracefully when they are absent. This keeps the model ready for richer
/// iMessage features without breaking on today's responses.
class ChatSummary {
  final String guid;
  final String? chatIdentifier;
  final String? serviceName; // iMessage | SMS | RCS | null
  final String? displayName; // group name; null for 1:1 (per server contract)
  final bool isArchived;

  // --- optional / future fields (null/empty when the server omits them) ---
  final String? lastMessagePreview;
  final int? lastMessageAt; // Unix epoch ms
  final int? unreadCount;
  final List<String> participants;
  final bool? isGroupRaw; // explicit flag if the server provides one
  final bool isPinned;
  final bool isMuted;

  // --- C7 renderable-timeline summary (server-computed) ---
  final bool hasRenderableMessages;
  final bool unsupportedOnly;
  final String hiddenReason; // "" | "debug_only" | "empty"

  const ChatSummary({
    required this.guid,
    this.chatIdentifier,
    this.serviceName,
    this.displayName,
    this.isArchived = false,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.unreadCount,
    this.participants = const [],
    this.isGroupRaw,
    this.isPinned = false,
    this.isMuted = false,
    this.hasRenderableMessages = true,
    this.unsupportedOnly = false,
    this.hiddenReason = '',
  });

  /// True when this chat has no normal content (only debug/noise or empty) and
  /// should be hidden from the default list.
  bool get isNoiseOnly => !hasRenderableMessages;

  /// Best display title: group/display name, else the handle/identifier, else
  /// the opaque GUID as a last resort.
  String get title {
    final dn = displayName?.trim() ?? '';
    if (dn.isNotEmpty) return dn;
    final id = chatIdentifier?.trim() ?? '';
    if (id.isNotEmpty) return id;
    return guid;
  }

  /// Heuristic group detection: an explicit flag if present, else "has a group
  /// display name" (the server sets `displayName` only for groups) or more than
  /// one participant.
  bool get isGroup {
    if (isGroupRaw != null) return isGroupRaw!;
    if ((displayName?.trim() ?? '').isNotEmpty) return true;
    return participants.length > 1;
  }

  /// 1–2 character avatar initials derived from the title.
  String get initials {
    final source = title.trim();
    if (source.isEmpty) return '#';
    // Phone numbers / handles: use a generic glyph rather than digits.
    if (RegExp(r'^[+\d][\d\s()\-]*$').hasMatch(source)) return '#';
    final words = source
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '#';
    if (words.length == 1) return _firstLetter(words.first);
    return _firstLetter(words[0]) + _firstLetter(words[1]);
  }

  static String _firstLetter(String word) {
    if (word.isEmpty) return '';
    return String.fromCharCode(word.runes.first).toUpperCase();
  }

  bool get hasUnread => (unreadCount ?? 0) > 0;

  factory ChatSummary.fromJson(Map<String, dynamic> json) {
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    return ChatSummary(
      guid: (json['guid'] as String?) ?? '',
      chatIdentifier: json['chatIdentifier'] as String?,
      serviceName: json['serviceName'] as String?,
      displayName: json['displayName'] as String?,
      isArchived: (json['isArchived'] as bool?) ?? false,
      // Prefer the C7 server-computed renderable preview/timestamp (real data).
      lastMessagePreview:
          json['latestRenderablePreview'] as String? ??
          json['lastMessagePreview'] as String? ??
          json['lastMessage'] as String?,
      lastMessageAt:
          asInt(json['latestRenderableAt']) ??
          asInt(json['lastMessageAt']) ??
          asInt(json['lastMessageDate']),
      unreadCount: asInt(json['unreadCount']),
      participants:
          (json['participants'] as List?)?.whereType<String>().toList(
            growable: false,
          ) ??
          const [],
      isGroupRaw: json['isGroup'] as bool?,
      isPinned: (json['isPinned'] as bool?) ?? false,
      isMuted: (json['isMuted'] as bool?) ?? false,
      hasRenderableMessages: (json['hasRenderableMessages'] as bool?) ?? true,
      unsupportedOnly: (json['unsupportedOnly'] as bool?) ?? false,
      hiddenReason: (json['hiddenReason'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'guid': guid,
    'chatIdentifier': chatIdentifier,
    'serviceName': serviceName,
    'displayName': displayName,
    'isArchived': isArchived,
    'latestRenderablePreview': lastMessagePreview,
    'latestRenderableAt': lastMessageAt,
    'unreadCount': unreadCount,
    'participants': participants,
    'isGroup': isGroupRaw,
    'isPinned': isPinned,
    'isMuted': isMuted,
    'hasRenderableMessages': hasRenderableMessages,
    'unsupportedOnly': unsupportedOnly,
    'hiddenReason': hiddenReason,
  };
}
