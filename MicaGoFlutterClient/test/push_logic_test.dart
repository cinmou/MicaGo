import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/push_logic.dart';

void main() {
  group('C22 push decision logic (BlueBubbles dedup + routing)', () {
    test('foreground push runs catch-up only when the socket is down', () {
      // Socket connected → it already delivered the event → no catch-up (no dup).
      expect(pushShouldCatchUp(realtimeConnected: true), isFalse);
      // Socket down → push is the wake signal → run a delta catch-up.
      expect(pushShouldCatchUp(realtimeConnected: false), isTrue);
    });

    test('routes a tap to the chat GUID in the payload', () {
      expect(pushChatGuid({'chatGuid': 'iMessage;-;+15550001'}),
          'iMessage;-;+15550001');
      expect(pushChatGuid({'chatGuid': ''}), isNull);
      expect(pushChatGuid({'type': 'message:new'}), isNull);
    });

    test('only shows a notification when there is something to show', () {
      expect(pushShouldNotify({'title': 'Jane', 'body': 'hi'}), isTrue);
      expect(pushShouldNotify({'title': '', 'body': ''}), isFalse); // preview off
      expect(pushShouldNotify({'type': 'test', 'title': 'x'}), isFalse);
    });
  });
}
