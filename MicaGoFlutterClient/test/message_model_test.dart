import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

void main() {
  group('MessageModel.fromJson', () {
    test('parses core fields and handle', () {
      final m = MessageModel.fromJson({
        'guid': 'p:0/ABC',
        'text': 'Hello',
        'service': 'iMessage',
        'dateCreated': 1717372800000,
        'isFromMe': false,
        'isRead': false,
        'isDelivered': true,
        'handle': {'id': '+15551234567', 'service': 'iMessage'},
        'cacheHasAttachments': false,
        'semanticKind': 'normal_text',
        'renderRecommendation': 'bubble',
        'attachments': [],
      });
      expect(m.guid, 'p:0/ABC');
      expect(m.text, 'Hello');
      expect(m.isFromMe, isFalse);
      expect(m.isDelivered, isTrue);
      expect(m.handleId, '+15551234567');
      expect(m.hasText, isTrue);
      expect(m.hasAttachments, isFalse);
      expect(m.localState, LocalSendState.confirmed);
      expect(m.dedupeKey, 'p:0/ABC');
      expect(m.semanticKind, 'normal_text');
      expect(m.renderRecommendation, 'bubble');
    });

    test('parses attachments with kinds', () {
      final m = MessageModel.fromJson({
        'guid': 'g',
        'attachments': [
          {
            'guid': 'a1',
            'mimeType': 'image/jpeg',
            'attachmentKind': 'image',
            'downloadUrl': '/api/attachments/a1',
            'totalBytes': 100,
          },
          {
            'guid': 'a2',
            'uti': 'com.apple.coreaudio-format',
            'attachmentKind': 'audio',
            'isVoiceMessage': true,
            'downloadUrl': '/api/attachments/a2',
          },
        ],
      });
      expect(m.attachments.length, 2);
      expect(m.attachments[0].isImage, isTrue);
      expect(m.attachments[1].isAudio, isTrue);
      expect(m.attachments[1].isVoiceMessage, isTrue);
      expect(m.hasAttachments, isTrue);
    });

    test('optimistic message is sending and keyed by tempId', () {
      final m = MessageModel.optimistic(
        tempId: 'tmp-1',
        text: 'hi',
        dateCreated: 1,
      );
      expect(m.isFromMe, isTrue);
      expect(m.localState, LocalSendState.sending);
      expect(m.guid, '');
      expect(m.dedupeKey, 'tmp-1');
    });

    test('copyWith confirms a pending message and re-keys by guid', () {
      final confirmed = MessageModel.optimistic(
        tempId: 'tmp-1',
        text: 'hi',
        dateCreated: 1,
      ).copyWith(guid: 'real-guid', localState: LocalSendState.confirmed);
      expect(confirmed.guid, 'real-guid');
      expect(confirmed.localState, LocalSendState.confirmed);
      expect(confirmed.dedupeKey, 'real-guid');
    });
  });

  group('AttachmentModel', () {
    test('infers image from mime when kind is unknown', () {
      final a = AttachmentModel.fromJson({
        'guid': 'a',
        'mimeType': 'image/png',
        'downloadUrl': '/x',
      });
      expect(a.isImage, isTrue);
      expect(a.isAudio, isFalse);
    });

    test('displayName falls back to a generic label', () {
      final a = AttachmentModel.fromJson({'guid': 'a', 'downloadUrl': '/x'});
      expect(a.displayName, 'Attachment');
    });

    test('prefers transferName for displayName', () {
      final a = AttachmentModel.fromJson({
        'guid': 'a',
        'transferName': 'photo.heic',
        'filename': '/var/x.heic',
        'downloadUrl': '/x',
      });
      expect(a.displayName, 'photo.heic');
    });

    test('TIFF is image but not inline-previewable', () {
      final a = AttachmentModel.fromJson({
        'guid': 'a',
        'mimeType': 'image/tiff',
        'originalMimeType': 'image/tiff',
        'uti': 'public.tiff',
        'transferName': 'screenshot.tiff',
        'attachmentKind': 'image',
        'displayKind': 'image_needs_preview',
        'isPreviewableImage': false,
        'needsPreviewConversion': true,
        'downloadUrl': '/x',
      });
      expect(a.isImage, isTrue);
      expect(a.isTiff, isTrue);
      expect(a.canRenderInlineImage, isFalse);
      expect(a.displayKind, 'image_needs_preview');
    });
  });
}
