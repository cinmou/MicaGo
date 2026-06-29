import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/message_render.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

MessageModel _msg({
  String? text,
  bool isFromMe = false,
  bool isRead = false,
  bool isDelivered = false,
  int? dateRead,
  int? dateDelivered,
  String? handleId,
  List<AttachmentModel> attachments = const [],
  int? associatedType,
  String? associatedGuid,
  int itemType = 0,
  int groupActionType = 0,
  int errorCode = 0,
  bool isEdited = false,
  int? dateEdited,
  bool isDebugOnly = false,
  bool cacheHasAttachments = false,
  String? semanticKind,
  String? renderRecommendation,
  String? unsupportedReason,
  String? tempId,
  LocalSendState localState = LocalSendState.confirmed,
}) {
  return MessageModel(
    guid: 'g',
    text: text,
    isFromMe: isFromMe,
    isRead: isRead,
    isDelivered: isDelivered,
    dateRead: dateRead,
    dateDelivered: dateDelivered,
    handleId: handleId,
    attachments: attachments,
    associatedMessageType: associatedType,
    associatedMessageGuid: associatedGuid,
    itemType: itemType,
    groupActionType: groupActionType,
    errorCode: errorCode,
    isEdited: isEdited,
    dateEdited: dateEdited,
    isDebugOnly: isDebugOnly,
    cacheHasAttachments: cacheHasAttachments,
    semanticKind: semanticKind,
    renderRecommendation: renderRecommendation,
    unsupportedReason: unsupportedReason,
    tempId: tempId,
    localState: localState,
  );
}

void main() {
  group('control-like text filter', () {
    test('flags "+!" and "+\$" artifacts', () {
      expect(isControlLikeText('+!'), isTrue);
      expect(isControlLikeText('+\$'), isTrue);
    });
    test('flags empty / object-replacement only', () {
      expect(isControlLikeText(''), isTrue);
      expect(isControlLikeText('￼'), isTrue);
    });
    test('does not flag real text or "+1"', () {
      expect(isControlLikeText('Hello there'), isFalse);
      expect(isControlLikeText('+1'), isFalse);
      expect(isControlLikeText('你好'), isFalse);
    });
    test('displayText strips placeholder and drops control payloads', () {
      expect(displayText(_msg(text: '￼Hello')), 'Hello');
      expect(displayText(_msg(text: '+!')), isNull);
      expect(displayText(_msg(text: '   ')), isNull);
    });
  });

  group('renderableKindFor', () {
    test('normal for real text', () {
      expect(renderableKindFor(_msg(text: 'Hi')), MessageRenderableKind.normal);
    });
    test('attachmentOnly when no text but attachments', () {
      final m = _msg(
        attachments: const [
          AttachmentModel(
            guid: 'a',
            downloadUrl: '/x',
            attachmentKind: 'image',
          ),
        ],
      );
      expect(renderableKindFor(m), MessageRenderableKind.attachmentOnly);
    });
    test('service for group/item events', () {
      expect(
        renderableKindFor(_msg(itemType: 2)),
        MessageRenderableKind.service,
      );
    });
    test('reaction for associated message', () {
      expect(
        renderableKindFor(
          _msg(associatedType: 2000, associatedGuid: 'p:0/abc'),
        ),
        MessageRenderableKind.reaction,
      );
    });
    test('unknown for control-only text and no attachments', () {
      expect(
        renderableKindFor(_msg(text: '+!')),
        MessageRenderableKind.unknown,
      );
      expect(
        renderableKindFor(_msg(text: null)),
        MessageRenderableKind.unknown,
      );
    });
    test('server debug-only recommendation renders as unknown', () {
      expect(
        renderableKindFor(_msg(text: 'hidden', isDebugOnly: true)),
        MessageRenderableKind.unknown,
      );
    });
    test(
      'empty edited residue renders as an unsent system row, not a bubble',
      () {
        final m = _msg(
          isEdited: true,
          semanticKind: 'empty_edited_residue',
          renderRecommendation: 'system',
          unsupportedReason: 'empty_edited_residue',
        );
        // C26: unrecoverable placeholders present as an unsent/retracted row
        // (no longer a hidden "unknown"), while the diagnostic reason is retained
        // for Message Info / Debug.
        expect(renderableKindFor(m), MessageRenderableKind.retracted);
        final cls = classifyMessage(m);
        expect(cls.isUnsupported, isFalse);
        expect(cls.reason, UnsupportedReason.emptyEditedResidue);
      },
    );
    test('normal edited text stays a normal message', () {
      expect(
        renderableKindFor(_msg(text: 'fixed typo', isEdited: true)),
        MessageRenderableKind.normal,
      );
    });
  });

  group('edited marker', () {
    test('shows marker for edited non-retracted messages', () {
      expect(editedMarker(_msg(text: 'hi', isEdited: true)), 'Edited');
      expect(editedMarker(_msg(text: 'hi')), isNull);
    });
  });

  group('chat list previews', () {
    test('uses compact attachment placeholders', () {
      expect(
        messagePreviewText(
          _msg(
            attachments: const [
              AttachmentModel(
                guid: 'img',
                downloadUrl: '/img',
                attachmentKind: 'image',
              ),
            ],
          ),
        ),
        '[图片]',
      );
      expect(
        messagePreviewText(
          _msg(
            attachments: const [
              AttachmentModel(
                guid: 'voice',
                downloadUrl: '/voice',
                attachmentKind: 'audio',
                isVoiceMessage: true,
              ),
            ],
          ),
        ),
        '[语音]',
      );
      expect(messagePreviewText(_msg()), '[文件]');
    });

    test('sanitizes stale server/cache previews', () {
      expect(chatListPreviewText('￼', hasMessage: true), '[文件]');
      expect(chatListPreviewText('obj', hasMessage: true), '[文件]');
      expect(chatListPreviewText('Message', hasMessage: true), '[文件]');
      expect(chatListPreviewText('（图片）', hasMessage: true), '[图片]');
      expect(chatListPreviewText('', hasMessage: false), '');
    });
  });

  group('deliveryStateFor', () {
    test('incoming never shows outgoing status', () {
      expect(
        deliveryStateFor(_msg(isFromMe: false, isDelivered: true)),
        MessageDeliveryState.incoming,
      );
    });
    test('sending while pending', () {
      expect(
        deliveryStateFor(
          _msg(isFromMe: true, tempId: 't', localState: LocalSendState.pending),
        ),
        MessageDeliveryState.sending,
      );
      expect(
        deliveryStateFor(
          _msg(isFromMe: true, tempId: 't', localState: LocalSendState.sending),
        ),
        MessageDeliveryState.sending,
      );
    });
    test('sent_unconfirmed renders as sent unless later state arrives', () {
      expect(
        deliveryStateFor(
          _msg(
            isFromMe: true,
            tempId: 't',
            localState: LocalSendState.sentUnconfirmed,
          ),
        ),
        MessageDeliveryState.sent,
      );
    });
    test('failed from local state or error code', () {
      expect(
        deliveryStateFor(
          _msg(isFromMe: true, localState: LocalSendState.failed),
        ),
        MessageDeliveryState.failed,
      );
      expect(
        deliveryStateFor(_msg(isFromMe: true, errorCode: 22)),
        MessageDeliveryState.failed,
      );
    });
    test('read > delivered > sent precedence', () {
      expect(
        deliveryStateFor(_msg(isFromMe: true, isRead: true)),
        MessageDeliveryState.read,
      );
      expect(
        deliveryStateFor(_msg(isFromMe: true, isDelivered: true)),
        MessageDeliveryState.delivered,
      );
      expect(deliveryStateFor(_msg(isFromMe: true)), MessageDeliveryState.sent);
    });
  });

  group('resolveSenderLabel', () {
    test('You for outgoing', () {
      expect(resolveSenderLabel(_msg(isFromMe: true), isGroup: true), 'You');
    });
    test('contact name preferred', () {
      expect(
        resolveSenderLabel(
          _msg(handleId: '+15551234567'),
          isGroup: true,
          contactName: 'Jane',
        ),
        'Jane',
      );
    });
    test('falls back to handle then Unknown', () {
      expect(
        resolveSenderLabel(_msg(handleId: '+15551234567'), isGroup: true),
        '+15551234567',
      );
      expect(
        resolveSenderLabel(_msg(handleId: null), isGroup: true),
        'Unknown',
      );
    });
  });
}
