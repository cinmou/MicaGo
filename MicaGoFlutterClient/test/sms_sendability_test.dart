import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/chat_service.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';

// C20: SMS sendability is server-authoritative — iMessage always; SMS only when
// the server's allowSmsSend is on; RCS/unknown never. Never from GUID/handle.
void main() {
  ChatSummary chat(String? service, String? category) => ChatSummary.fromJson({
    'guid': 'g',
    'chatIdentifier': '+8618083772301',
    'serviceName': service,
    'serviceCategory': category,
  });

  test('iMessage is send-enabled regardless of the SMS setting', () {
    final s = chat('iMessage', 'imessage').service;
    expect(s.canSendWith(allowSmsSend: false), isTrue);
    expect(s.canSendWith(allowSmsSend: true), isTrue);
  });

  test('SMS composer disabled by default, enabled when the setting is on', () {
    final s = chat('SMS', 'sms').service;
    expect(s.canSendWith(allowSmsSend: false), isFalse); // default off → read-only
    expect(s.canSendWith(allowSmsSend: true), isTrue); // enabled
  });

  test('Unknown stays read-only even when SMS sending is on', () {
    final s = chat(null, null).service;
    expect(s, ChatService.unknown);
    expect(s.canSendWith(allowSmsSend: true), isFalse);
  });

  test('RCS stays read-only even when SMS sending is on', () {
    final s = chat('RCS', 'rcs').service;
    expect(s.canSendWith(allowSmsSend: true), isFalse);
  });

  test('phone-number SMS chat is still gated only by the setting, not shape', () {
    // Phone-shaped handle + any;-; GUID must not change the decision.
    final s = ChatSummary.fromJson({
      'guid': 'SMS;-;+8618083772301',
      'chatIdentifier': '+8618083772301',
      'serviceName': 'SMS',
      'serviceCategory': 'sms',
    }).service;
    expect(s.canSendWith(allowSmsSend: false), isFalse);
    expect(s.canSendWith(allowSmsSend: true), isTrue);
  });
}
