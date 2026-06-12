import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/chat_service.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

/// The server is the single source of truth for iMessage/SMS classification.
/// The client must never infer SMS from a phone-number handle, a `+` prefix,
/// an `any;-;` chat GUID, or a missing display name.
void main() {
  group('regression: server says iMessage, phone-shaped everything', () {
    // The exact reported case: service=iMessage, chatGuid=any;-;+8618083772301,
    // handle=+8618083772301 — must display iMessage, never SMS.
    test('message must classify as iMessage', () {
      final m = MessageModel.fromJson({
        'guid': 'm1',
        'text': 'hello',
        'service': 'iMessage',
        'chatGuid': 'any;-;+8618083772301',
        'handle': {'id': '+8618083772301', 'service': 'iMessage'},
      });
      final s = chatServiceFromServer(
        category: m.serviceCategory,
        rawService: m.service,
      );
      expect(s, ChatService.imessage);
      expect(s.label, 'iMessage');
      expect(s.canSend, isTrue);
    });

    test('chat must classify as iMessage', () {
      final c = ChatSummary.fromJson({
        'guid': 'any;-;+8618083772301',
        'chatIdentifier': '+8618083772301',
        'serviceName': 'iMessage',
      });
      expect(c.service, ChatService.imessage);
    });

    test('serverCategory wins and is round-tripped through the cache json', () {
      final c = ChatSummary.fromJson({
        'guid': 'any;-;+8618083772301',
        'chatIdentifier': '+8618083772301',
        'serviceName': 'weird-raw-value',
        'serviceCategory': 'imessage',
      });
      expect(c.service, ChatService.imessage);
      // toJson → fromJson (the sqflite cache path) must not lose the category.
      final roundTripped = ChatSummary.fromJson(c.toJson());
      expect(roundTripped.service, ChatService.imessage);
    });
  });

  group('SMS and unknown', () {
    test('server says SMS → SMS, read-only', () {
      final s = chatServiceFromServer(category: 'sms', rawService: 'SMS');
      expect(s, ChatService.sms);
      expect(s.label, 'SMS');
      expect(s.canSend, isFalse);
    });

    test('raw service fallback normalizes like the server', () {
      expect(
        chatServiceFromServer(rawService: 'iMessageLite'),
        ChatService.imessage,
      );
      expect(chatServiceFromServer(rawService: 'Text'), ChatService.sms);
      expect(chatServiceFromServer(rawService: 'RCS'), ChatService.rcs);
    });

    test('missing service → Unknown, never SMS', () {
      final s = chatServiceFromServer(category: null, rawService: null);
      expect(s, ChatService.unknown);
      expect(s.label, 'Unknown');
      expect(s.canSend, isFalse);
    });

    test('phone-shaped chat with no service is Unknown, not SMS', () {
      final c = ChatSummary.fromJson({
        'guid': 'any;-;+8618083772301',
        'chatIdentifier': '+8618083772301',
      });
      expect(c.service, ChatService.unknown);
    });

    test('message serviceCategory round-trips through cache json', () {
      final m = MessageModel.fromJson({
        'guid': 'm2',
        'text': 'hi',
        'service': 'SMS',
        'serviceCategory': 'sms',
      });
      final roundTripped = MessageModel.fromJson(m.toJson());
      expect(roundTripped.serviceCategory, 'sms');
      expect(
        chatServiceFromServer(
          category: roundTripped.serviceCategory,
          rawService: roundTripped.service,
        ),
        ChatService.sms,
      );
    });
  });
}
