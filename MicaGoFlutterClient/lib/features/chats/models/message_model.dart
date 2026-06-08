/// Client-side message + attachment models for the thread.
///
/// Mirrors the MicaGo `Message`/`Attachment` (v0.9 + v0.11.5) JSON, with extra
/// **optional** fields kept ready for future iMessage features (reactions,
/// replies) and local-only fields for optimistic sending. The server does not
/// yet expose reactions/replies or a `chatGuid` on messages — those stay
/// empty/null and the UI degrades gracefully.
library;

/// Local delivery state for an outgoing message we sent from this client.
enum LocalSendState { none, pending, confirmed, failed }

class AttachmentModel {
  final String guid;
  final String? filename;
  final String? mimeType;
  final String? transferName;
  final int totalBytes;
  final String downloadUrl; // server-relative, e.g. /api/attachments/<guid>
  final String? uti;
  final bool isSticker;
  final String attachmentKind; // image|video|audio|file|sticker|unknown
  final bool isVoiceMessage;

  const AttachmentModel({
    required this.guid,
    required this.downloadUrl,
    this.filename,
    this.mimeType,
    this.transferName,
    this.totalBytes = 0,
    this.uti,
    this.isSticker = false,
    this.attachmentKind = 'unknown',
    this.isVoiceMessage = false,
  });

  bool get isImage =>
      attachmentKind == 'image' || (mimeType?.startsWith('image/') ?? false);
  bool get isAudio =>
      attachmentKind == 'audio' || (mimeType?.startsWith('audio/') ?? false);
  bool get isVideo =>
      attachmentKind == 'video' || (mimeType?.startsWith('video/') ?? false);

  String get displayName =>
      (transferName?.trim().isNotEmpty ?? false)
          ? transferName!.trim()
          : (filename?.trim().isNotEmpty ?? false)
              ? filename!.trim()
              : 'Attachment';

  factory AttachmentModel.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return AttachmentModel(
      guid: (json['guid'] as String?) ?? '',
      filename: json['filename'] as String?,
      mimeType: json['mimeType'] as String?,
      transferName: json['transferName'] as String?,
      totalBytes: asInt(json['totalBytes']),
      downloadUrl: (json['downloadUrl'] as String?) ?? '',
      uti: json['uti'] as String?,
      isSticker: (json['isSticker'] as bool?) ?? false,
      attachmentKind: (json['attachmentKind'] as String?) ?? 'unknown',
      isVoiceMessage: (json['isVoiceMessage'] as bool?) ?? false,
    );
  }
}

/// A reaction/tapback — placeholder model only (the server does not surface
/// these yet, so the list is always empty for now).
class ReactionModel {
  final String type;
  final String? fromHandle;
  const ReactionModel({required this.type, this.fromHandle});
}

class MessageModel {
  final String guid;
  final String? text;
  final String? subject;
  final String? service;
  final int? dateCreated; // Unix ms
  final int? dateRead;
  final int? dateDelivered;
  final bool isFromMe;
  final bool isRead;
  final bool isDelivered;
  final String? handleId;
  final String? handleService;
  final bool cacheHasAttachments;
  final List<AttachmentModel> attachments;

  // Future/optional (empty until the server exposes them):
  final List<ReactionModel> reactions;
  final String? replyToGuid;

  // iMessage compatibility fields (BlueBubbles-compatible). Parsed when the
  // server exposes them. See docs/bluebubbles-compatibility-notes.md.
  final String? chatGuid; // owning chat (also on WS events for routing)
  final int? associatedMessageType; // tapback code: 2000-2005 add / 3000-3005 remove
  final String? associatedMessageGuid; // tapback target (p:/bp: prefixed)
  final String? threadOriginatorGuid; // reply target message guid
  final int itemType; // 0 = normal; >0 = service/group event
  final int groupActionType;
  final String? groupTitle;
  final String? balloonBundleId; // interactive app / effect balloon
  final String? expressiveSendStyleId; // message send effect
  final bool payloadDataPresent;
  final int errorCode; // >0 = send failed (server-side)
  final int? dateRetracted; // unsent timestamp (Unix ms)
  final int? dateEdited; // edited timestamp (Unix ms)
  final bool isRetracted;
  final bool isEdited;

  /// The original server JSON for this message — **debug only**. Never rendered
  /// as content; surfaced (redacted) in the Message Debug inspector.
  final Map<String, dynamic>? raw;

  // Local-only (optimistic send):
  final String? tempId;
  final LocalSendState localState;

  const MessageModel({
    required this.guid,
    this.text,
    this.subject,
    this.service,
    this.dateCreated,
    this.dateRead,
    this.dateDelivered,
    this.isFromMe = false,
    this.isRead = false,
    this.isDelivered = false,
    this.handleId,
    this.handleService,
    this.cacheHasAttachments = false,
    this.attachments = const [],
    this.reactions = const [],
    this.replyToGuid,
    this.chatGuid,
    this.associatedMessageType,
    this.associatedMessageGuid,
    this.threadOriginatorGuid,
    this.itemType = 0,
    this.groupActionType = 0,
    this.groupTitle,
    this.balloonBundleId,
    this.expressiveSendStyleId,
    this.payloadDataPresent = false,
    this.errorCode = 0,
    this.dateRetracted,
    this.dateEdited,
    this.isRetracted = false,
    this.isEdited = false,
    this.raw,
    this.tempId,
    this.localState = LocalSendState.none,
  });

  bool get hasText => (text?.trim().isNotEmpty ?? false);
  bool get hasAttachments => attachments.isNotEmpty;

  /// Stable identity for de-duplication: real GUID if present, else the local
  /// temp id of an optimistic outgoing message.
  String get dedupeKey => guid.isNotEmpty ? guid : (tempId ?? '');

  MessageModel copyWith({
    String? guid,
    LocalSendState? localState,
    int? dateCreated,
  }) {
    return MessageModel(
      guid: guid ?? this.guid,
      text: text,
      subject: subject,
      service: service,
      dateCreated: dateCreated ?? this.dateCreated,
      dateRead: dateRead,
      dateDelivered: dateDelivered,
      isFromMe: isFromMe,
      isRead: isRead,
      isDelivered: isDelivered,
      handleId: handleId,
      handleService: handleService,
      cacheHasAttachments: cacheHasAttachments,
      attachments: attachments,
      reactions: reactions,
      replyToGuid: replyToGuid,
      chatGuid: chatGuid,
      associatedMessageType: associatedMessageType,
      associatedMessageGuid: associatedMessageGuid,
      threadOriginatorGuid: threadOriginatorGuid,
      itemType: itemType,
      groupActionType: groupActionType,
      groupTitle: groupTitle,
      balloonBundleId: balloonBundleId,
      expressiveSendStyleId: expressiveSendStyleId,
      payloadDataPresent: payloadDataPresent,
      errorCode: errorCode,
      dateRetracted: dateRetracted,
      dateEdited: dateEdited,
      isRetracted: isRetracted,
      isEdited: isEdited,
      raw: raw,
      tempId: tempId,
      localState: localState ?? this.localState,
    );
  }

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    final handle = json['handle'];
    final atts = (json['attachments'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(AttachmentModel.fromJson)
            .toList(growable: false) ??
        const <AttachmentModel>[];
    return MessageModel(
      guid: (json['guid'] as String?) ?? '',
      text: json['text'] as String?,
      subject: json['subject'] as String?,
      service: json['service'] as String?,
      dateCreated: asInt(json['dateCreated']),
      dateRead: asInt(json['dateRead']),
      dateDelivered: asInt(json['dateDelivered']),
      isFromMe: (json['isFromMe'] as bool?) ?? false,
      isRead: (json['isRead'] as bool?) ?? false,
      isDelivered: (json['isDelivered'] as bool?) ?? false,
      handleId: handle is Map<String, dynamic> ? handle['id'] as String? : null,
      handleService:
          handle is Map<String, dynamic> ? handle['service'] as String? : null,
      cacheHasAttachments: (json['cacheHasAttachments'] as bool?) ?? false,
      attachments: atts,
      chatGuid: json['chatGuid'] as String?,
      associatedMessageType: asInt(json['associatedMessageType']),
      associatedMessageGuid: json['associatedMessageGuid'] as String?,
      threadOriginatorGuid: json['threadOriginatorGuid'] as String?,
      itemType: asInt(json['itemType']) ?? 0,
      groupActionType: asInt(json['groupActionType']) ?? 0,
      groupTitle: json['groupTitle'] as String?,
      balloonBundleId: json['balloonBundleId'] as String?,
      expressiveSendStyleId: json['expressiveSendStyleId'] as String?,
      payloadDataPresent: (json['payloadDataPresent'] as bool?) ?? false,
      errorCode: asInt(json['error']) ?? 0,
      dateRetracted: asInt(json['dateRetracted']),
      dateEdited: asInt(json['dateEdited']),
      isRetracted: (json['isRetracted'] as bool?) ?? false,
      isEdited: (json['isEdited'] as bool?) ?? false,
      raw: json,
      localState: LocalSendState.confirmed,
    );
  }

  /// Builds an optimistic outgoing message for the composer.
  factory MessageModel.optimistic({
    required String tempId,
    required String text,
    required int dateCreated,
  }) {
    return MessageModel(
      guid: '',
      text: text,
      isFromMe: true,
      dateCreated: dateCreated,
      tempId: tempId,
      localState: LocalSendState.pending,
    );
  }
}
