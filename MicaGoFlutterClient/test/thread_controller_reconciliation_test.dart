import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/websocket_client.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/chats/realtime_event_helpers.dart' as rt;
import 'package:mica_go/features/chats/thread_controller.dart';

MessageModel _local({
  String text = 'hello',
  int at = 100000,
  LocalSendState state = LocalSendState.failed,
}) => MessageModel.optimistic(
  tempId: 'tmp-1',
  text: text,
  dateCreated: at,
).copyWith(localState: state);

MessageModel _server({
  String guid = 'real-1',
  String text = 'hello',
  int at = 100500,
  bool delivered = false,
  bool read = false,
}) => MessageModel(
  guid: guid,
  chatGuid: 'chat-a',
  text: text,
  isFromMe: true,
  dateCreated: at,
  isDelivered: delivered,
  isRead: read,
  localState: LocalSendState.confirmed,
);

void main() {
  group('send-state reconciliation', () {
    test(
      'timeout then later real row matches by outgoing text and close timestamp',
      () {
        expect(shouldReconcileLocalWithServer(_local(), _server()), isTrue);
      },
    );

    test('delivered/read confirmed row clears failed local match', () {
      expect(
        shouldReconcileLocalWithServer(
          _local(state: LocalSendState.failed),
          _server(delivered: true, read: true),
        ),
        isTrue,
      );
    });

    test('unrelated outgoing message does not match', () {
      expect(
        shouldReconcileLocalWithServer(
          _local(text: 'hello'),
          _server(text: 'different'),
        ),
        isFalse,
      );
      expect(
        shouldReconcileLocalWithServer(_local(at: 100000), _server(at: 400000)),
        isFalse,
      );
    });
  });

  group('websocket event routing helpers', () {
    test('message:new parses direct payload with chatGuid', () {
      final event = WsEvent('message:new', {
        'guid': 'm1',
        'chatGuid': 'chat-a',
        'text': 'hi',
      });
      final msg = messageFromWsEvent(event);
      expect(msg?.guid, 'm1');
      expect(chatGuidFromWsEvent(event), 'chat-a');
    });

    test('message:update parses nested message payload', () {
      final event = WsEvent('message:update', {
        'message': {'guid': 'm1', 'chatGuid': 'chat-a', 'dateDelivered': 1000},
        'changed': ['dateDelivered'],
      });
      final msg = messageFromWsEvent(event);
      expect(msg?.guid, 'm1');
      expect(msg?.dateDelivered, 1000);
      expect(chatGuidFromWsEvent(event), 'chat-a');
    });

    test('message:unsend exposes top-level chatGuid', () {
      final event = WsEvent('message:unsend', {
        'guid': 'm1',
        'chatGuid': 'chat-a',
        'dateRetracted': 2000,
      });
      expect(chatGuidFromWsEvent(event), 'chat-a');
      expect(messageFromWsEvent(event)?.guid, 'm1');
    });

    test(
      'cursor prefers numeric source row id and falls back to date/guid',
      () {
        expect(
          rt.realtimeCursorForEvent(
            WsEvent('message:new', {
              'sourceRowID': 42,
              'guid': 'm1',
              'dateCreated': 1000,
            }),
          ),
          'n:42',
        );
        expect(
          rt.realtimeCursorForEvent(
            WsEvent('message:new', {'guid': 'm1', 'dateCreated': 1000}),
          ),
          'f:1000:m1',
        );
      },
    );

    test('reaction helper identifies target and add/remove semantics', () {
      final add = MessageModel.fromJson({
        'guid': 'r1',
        'associatedMessageType': 2001,
        'associatedMessageGuid': 'p:target',
      });
      final remove = MessageModel.fromJson({
        'guid': 'r2',
        'associatedMessageType': 3001,
        'associatedMessageGuid': 'bp:target',
      });
      expect(rt.isReactionMessage(add), isTrue);
      expect(rt.reactionTargetGuid(add), 'target');
      expect(rt.reactionType(add), 'like');
      expect(rt.isReactionAdd(add), isTrue);
      expect(rt.isReactionAdd(remove), isFalse);
      expect(rt.reactionTargetGuid(remove), 'target');
    });
  });
}
