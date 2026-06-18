import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/route_label.dart';

ChatSummary _route(
  String guid,
  String handle,
  String effective, {
  bool? canSendText,
}) => ChatSummary.fromJson({
  'guid': guid,
  'chatIdentifier': handle,
  'effectiveService': effective,
  'canSendText': ?canSendText,
});

void main() {
  group('C24 route label (service + handle)', () {
    test('label includes the concrete handle, not just the service', () {
      expect(
        routeLabel(_route('g1', '+447700900123', 'imessage')),
        'iMessage · +447700900123',
      );
      expect(
        routeLabel(_route('g2', 'a@icloud.com', 'imessage')),
        'iMessage · a@icloud.com',
      );
      expect(
        routeLabel(_route('g3', '+8618000000000', 'sms')),
        'SMS · +8618000000000',
      );
    });

    test('two iMessage routes with different handles are distinguishable', () {
      final phone = _route('p', '+447700900123', 'imessage');
      final email = _route('e', 'a@icloud.com', 'imessage');
      final lp = routeLabel(phone);
      final le = routeLabel(email);
      // Same service, but the labels differ because they include the handle.
      expect(lp, isNot(le));
      expect(lp.contains('+447700900123'), isTrue);
      expect(le.contains('a@icloud.com'), isTrue);
      expect(routeHandle(phone), '+447700900123');
      expect(routeHandle(email), 'a@icloud.com');
    });

    test('a resolved contact name is appended alongside the handle', () {
      expect(
        routeLabel(_route('g', '+447700900123', 'imessage'), name: 'Alice'),
        'iMessage · Alice (+447700900123)',
      );
      // When the name equals the handle, it is not duplicated.
      expect(
        routeLabel(_route('g', '+447700900123', 'imessage'),
            name: '+447700900123'),
        'iMessage · +447700900123',
      );
    });

    test('sendability label uses the server-provided capability', () {
      expect(
        routeSendabilityLabel(
          _route('g', '+1', 'imessage', canSendText: true),
          allowSmsSend: false,
        ),
        'Can send',
      );
      // SMS with the server setting off → read only (no local inference).
      expect(
        routeSendabilityLabel(
          _route('g', '+1', 'sms', canSendText: false),
          allowSmsSend: false,
        ),
        'Read only',
      );
    });
  });
}
