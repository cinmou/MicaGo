import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/chat_service.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';

// C21: the client uses the server's single message-aware effectiveService for
// the badge AND every send gate. effectiveService overrides the chat-row
// serviceName/serviceCategory; sendability never comes from GUID/handle shape.
void main() {
  group('effectiveService is the source of truth', () {
    test('phone-number chat: row says SMS but effective iMessage → iMessage, sendable', () {
      final c = ChatSummary.fromJson({
        'guid': 'any;-;+8618083772301', // ambiguous GUID must not matter
        'chatIdentifier': '+8618083772301',
        'serviceName': 'SMS', // stale/ambiguous chat row
        'serviceCategory': 'sms',
        'effectiveService': 'imessage', // server's resolved decision wins
      });
      expect(c.service, ChatService.imessage);
      expect(c.service.label, 'iMessage');
      expect(c.service.canSendWith(allowSmsSend: false), isTrue);
    });

    test('row says iMessage but effective SMS → SMS (server downgraded)', () {
      final c = ChatSummary.fromJson({
        'guid': 'iMessage;-;+1555',
        'serviceName': 'iMessage',
        'serviceCategory': 'imessage',
        'effectiveService': 'sms',
      });
      expect(c.service, ChatService.sms);
      // Read-only unless the SMS-send setting is on.
      expect(c.service.canSendWith(allowSmsSend: false), isFalse);
      expect(c.service.canSendWith(allowSmsSend: true), isTrue);
    });

    test('effective unknown stays read-only regardless of row/shape', () {
      final c = ChatSummary.fromJson({
        'guid': 'any;-;+8618083772301',
        'chatIdentifier': '+8618083772301',
        'effectiveService': 'unknown',
      });
      expect(c.service, ChatService.unknown);
      expect(c.service.canSendWith(allowSmsSend: true), isFalse);
    });

    test('older server (no effectiveService) falls back to category/raw', () {
      final cat = ChatSummary.fromJson({
        'guid': 'g',
        'serviceName': 'iMessageLite',
        'serviceCategory': 'imessage',
      });
      expect(cat.service, ChatService.imessage);

      final raw = ChatSummary.fromJson({'guid': 'g', 'serviceName': 'SMS'});
      expect(raw.service, ChatService.sms);
    });

    test('effectiveService survives the sqflite cache round-trip', () {
      final c = ChatSummary.fromJson({
        'guid': 'g',
        'serviceName': 'SMS',
        'effectiveService': 'imessage',
      });
      final back = ChatSummary.fromJson(c.toJson());
      expect(back.service, ChatService.imessage);
    });
  });
}
