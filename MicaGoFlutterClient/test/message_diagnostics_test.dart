import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/message_render.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

MessageModel _msg({
  String guid = 'g',
  String? text,
  bool isFromMe = false,
  String? handleId,
  String? service,
  bool cacheHasAttachments = false,
  List<AttachmentModel> attachments = const [],
  int? associatedType,
  String? associatedGuid,
  int itemType = 0,
  Map<String, dynamic>? raw,
}) {
  return MessageModel(
    guid: guid,
    text: text,
    isFromMe: isFromMe,
    handleId: handleId,
    service: service,
    cacheHasAttachments: cacheHasAttachments,
    attachments: attachments,
    associatedMessageType: associatedType,
    associatedMessageGuid: associatedGuid,
    itemType: itemType,
    raw: raw,
  );
}

void main() {
  group('classifyMessage reasons', () {
    test('supported text has reason none', () {
      final c = classifyMessage(_msg(text: 'Hello'));
      expect(c.kind, MessageRenderableKind.normal);
      expect(c.reason, UnsupportedReason.none);
      expect(c.isUnsupported, isFalse);
    });

    test('control-like text → unknown + controlText', () {
      final c = classifyMessage(_msg(text: '+!'));
      expect(c.isUnsupported, isTrue);
      expect(c.reason, UnsupportedReason.controlText);
    });

    test('cacheHasAttachments but none delivered → missingServerFields', () {
      final c = classifyMessage(_msg(cacheHasAttachments: true));
      expect(c.isUnsupported, isTrue);
      expect(c.reason, UnsupportedReason.missingServerFields);
    });

    test('empty message → noContent', () {
      final c = classifyMessage(_msg(text: null));
      expect(c.isUnsupported, isTrue);
      expect(c.reason, UnsupportedReason.noContent);
    });

    test('tapback detected as reaction, not unsupported', () {
      final c = classifyMessage(
          _msg(associatedType: 2000, associatedGuid: 'p:0/abc'));
      expect(c.kind, MessageRenderableKind.reaction);
      expect(c.isUnsupported, isFalse);
    });
  });

  group('debug JSON redaction', () {
    test('redacts sensitive keys and bearer/token value patterns', () {
      final raw = <String, dynamic>{
        'guid': 'g1',
        'token': 'super-secret-abc',
        'Authorization': 'Bearer eyJhbGciOi.payload.sig',
        'nested': {
          'apiKey': 'k-123',
          'note': 'see https://host/api/attachments/x?token=leak123&z=1',
        },
        'header': 'Bearer abc.def.ghi',
      };
      final json = messageDebugJson(_msg(raw: raw));

      expect(json.contains('super-secret-abc'), isFalse);
      expect(json.contains('k-123'), isFalse);
      expect(json.contains('leak123'), isFalse);
      expect(json.contains('eyJhbGciOi.payload.sig'), isFalse);
      expect(json.contains('abc.def.ghi'), isFalse);
      expect(json.contains('<redacted>'), isTrue);
      // Non-sensitive content is preserved.
      expect(json.contains('g1'), isTrue);
    });

    test('debug map never leaks attachment download token', () {
      final m = _msg(
        attachments: const [
          AttachmentModel(
            guid: 'a1',
            downloadUrl: '/api/attachments/a1?token=secrettoken',
            filename: 'pic.jpg',
            mimeType: 'image/jpeg',
            attachmentKind: 'image',
          ),
        ],
      );
      final map = messageDebugMap(m);
      final atts = map['attachments'] as List;
      final first = atts.first as Map;
      // Only a boolean presence flag — never the URL or its token.
      expect(first['hasDownloadUrl'], isTrue);
      expect(first.containsKey('downloadUrl'), isFalse);
      expect(messageDebugJson(m).contains('secrettoken'), isFalse);
    });

    test('text preview is clipped to 200 chars', () {
      final long = 'a' * 500;
      final map = messageDebugMap(_msg(text: long));
      final preview = map['textPreview'] as String;
      expect(preview.length, lessThanOrEqualTo(201)); // 200 + ellipsis
      expect(map['textLength'], 500);
    });
  });

  group('attachment presentation', () {
    test('image/audio/file detection by kind and mime', () {
      const img = AttachmentModel(
          guid: 'i', downloadUrl: '/x', attachmentKind: 'image');
      const aud = AttachmentModel(
          guid: 'a', downloadUrl: '/x', mimeType: 'audio/mp4');
      const file = AttachmentModel(
          guid: 'f', downloadUrl: '/x', attachmentKind: 'file');
      expect(img.isImage, isTrue);
      expect(aud.isAudio, isTrue);
      expect(file.isImage, isFalse);
      expect(file.isAudio, isFalse);
    });
  });

  group('thread diagnostics', () {
    test('counts kinds and unsupported reasons', () {
      final msgs = <MessageModel>[
        _msg(text: 'hi'), // normal
        _msg(text: 'there'), // normal
        _msg(attachments: const [
          AttachmentModel(
              guid: 'i', downloadUrl: '/x', attachmentKind: 'image'),
        ]), // image
        _msg(itemType: 2), // service
        _msg(associatedType: 2000, associatedGuid: 'p:0/a'), // reaction
        _msg(text: '+!'), // unsupported controlText
        _msg(text: null), // unsupported noContent
      ];
      final d = computeThreadDiagnostics(msgs);
      expect(d.total, 7);
      expect(d.text, 2);
      expect(d.image, 1);
      expect(d.service, 1);
      expect(d.reaction, 1);
      expect(d.unsupported, 2);
      expect(d.reasons[UnsupportedReason.controlText], 1);
      expect(d.reasons[UnsupportedReason.noContent], 1);
      expect(d.lastUnsupported, isNotNull);
    });

    test('report includes counts and is redacted', () {
      final d = computeThreadDiagnostics([
        _msg(
          text: null,
          raw: {'token': 'xyz-secret', 'guid': 'g'},
        ),
      ]);
      final report = threadDiagnosticsReport(d);
      expect(report.contains('unsupported: 1'), isTrue);
      expect(report.contains('xyz-secret'), isFalse);
    });

    test('empty diagnostics', () {
      final d = computeThreadDiagnostics(const []);
      expect(d.total, 0);
      expect(d.lastUnsupported, isNull);
    });
  });
}
