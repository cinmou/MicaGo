import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/push_logic.dart';
import 'package:mica_go/core/network/push_service.dart';

void main() {
  group('C28 FCM options persistence (background-isolate init)', () {
    test('config → persisted map → FirebaseOptions round-trips', () {
      final cfg = {
        'configured': true,
        'apiKey': 'AIzaKEY',
        'appId': '1:123:android:abc',
        'messagingSenderId': '123',
        'projectId': 'my-proj',
        'storageBucket': 'my-proj.appspot.com',
      };
      final stored = fcmOptionsStorageMap(cfg);
      final decoded = jsonDecode(jsonEncode(stored)) as Map<String, dynamic>;
      final opts = firebaseOptionsFromMap(decoded);
      expect(opts.apiKey, 'AIzaKEY');
      expect(opts.appId, '1:123:android:abc');
      expect(opts.messagingSenderId, '123');
      expect(opts.projectId, 'my-proj');
      expect(opts.storageBucket, 'my-proj.appspot.com');
    });

    test('empty storageBucket maps to null (optional field)', () {
      final opts = firebaseOptionsFromMap({
        'apiKey': 'k',
        'appId': 'a',
        'messagingSenderId': 's',
        'projectId': 'p',
        'storageBucket': '',
      });
      expect(opts.storageBucket, isNull);
    });
  });

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

  group('C30 notification formatting + reply', () {
    test('title falls back to a generic label when sender is absent', () {
      expect(notificationTitle({'title': 'Jane'}), 'Jane');
      expect(notificationTitle({'title': ''}), 'New message');
      expect(notificationTitle({}), 'New message');
    });

    test('body is null when preview is off', () {
      expect(notificationBody({'body': 'hello'}), 'hello');
      expect(notificationBody({'body': ''}), isNull);
      expect(notificationBody({}), isNull);
    });

    test('reply text is trimmed and empty input rejected', () {
      expect(cleanReplyText('  hi  '), 'hi');
      expect(cleanReplyText(''), isNull);
      expect(cleanReplyText('   '), isNull);
      expect(cleanReplyText(null), isNull);
    });
  });

  group('C31 notification title + preview', () {
    test('prefers an on-device contact name over everything', () {
      expect(
        messageNotificationTitle(
          contactName: 'Mom',
          serverTitle: '+15550001',
          handle: '+15550001',
        ),
        'Mom',
      );
    });

    test('uses the server sender name when it is not a generic placeholder', () {
      expect(
        messageNotificationTitle(serverTitle: 'Jane', handle: '+15550001'),
        'Jane',
      );
      // Generic server titles fall through to the handle.
      expect(
        messageNotificationTitle(
          serverTitle: 'New message',
          handle: '+15550001',
        ),
        '+15550001',
      );
      expect(
        messageNotificationTitle(
          serverTitle: 'New iMessage',
          handle: 'a@b.com',
        ),
        'a@b.com',
      );
    });

    test('falls back to the handle, then a generic label — never empty', () {
      expect(messageNotificationTitle(handle: '+15550001'), '+15550001');
      expect(messageNotificationTitle(), 'New message');
      expect(
        messageNotificationTitle(serverTitle: 'New message'),
        'New message',
      );
      expect(messageNotificationTitle(contactName: '   '), 'New message');
    });

    test('local body honors the preview mode (matches FCM privacy)', () {
      expect(localNotificationBody('hello', 'sender_and_text'), 'hello');
      expect(localNotificationBody('hello', 'sender'), isNull);
      expect(localNotificationBody('hello', 'none'), isNull);
      expect(localNotificationBody('   ', 'sender_and_text'), isNull);
      expect(localNotificationBody(null, 'sender_and_text'), isNull);
    });
  });
}
