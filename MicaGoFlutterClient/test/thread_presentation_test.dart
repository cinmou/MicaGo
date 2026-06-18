import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/message_display.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/chats/store/thread_presentation.dart';

const _day = 24 * 60 * 60 * 1000;

MessageModel _m({
  required String guid,
  String? text,
  bool isFromMe = false,
  String? handleId,
  int? dateCreated,
  int? associatedMessageType,
  String? associatedMessageGuid,
  String? threadOriginatorGuid,
  String? expressiveSendStyleId,
  bool isRetracted = false,
  bool isEdited = false,
  int? dateEdited,
  bool cacheHasAttachments = false,
  String? semanticKind,
  String? renderRecommendation,
  String? unsupportedReason,
  int itemType = 0,
}) => MessageModel(
  guid: guid,
  text: text,
  isFromMe: isFromMe,
  handleId: handleId,
  dateCreated: dateCreated,
  associatedMessageType: associatedMessageType,
  associatedMessageGuid: associatedMessageGuid,
  threadOriginatorGuid: threadOriginatorGuid,
  expressiveSendStyleId: expressiveSendStyleId,
  isRetracted: isRetracted,
  isEdited: isEdited,
  dateEdited: dateEdited,
  cacheHasAttachments: cacheHasAttachments,
  semanticKind: semanticKind,
  renderRecommendation: renderRecommendation,
  unsupportedReason: unsupportedReason,
  itemType: itemType,
  localState: LocalSendState.confirmed,
);

List<ThreadViewItem> _build(
  List<MessageModel> msgs, {
  MessageDisplayPrefs prefs = const MessageDisplayPrefs(),
  bool isGroup = false,
  ContactNameResolver? resolve,
  bool loadingOlder = false,
}) => ThreadPresentationBuilder.build(
  messages: msgs,
  prefs: prefs,
  isGroup: isGroup,
  resolveName: resolve ?? (_) => null,
  loadingOlder: loadingOlder,
);

void main() {
  test('inserts a date separator before each new day', () {
    final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
    final items = _build([
      _m(guid: 'a', text: 'day1', dateCreated: t0),
      _m(guid: 'b', text: 'day1b', dateCreated: t0 + 60000),
      _m(guid: 'c', text: 'day2', dateCreated: t0 + 2 * _day),
    ]);
    final separators = items.whereType<DateSeparatorItem>().length;
    expect(separators, 2); // two distinct days
    expect(items.first, isA<DateSeparatorItem>());
  });

  test('precomputes body + sender label (group, incoming) via resolver', () {
    final items = _build(
      [_m(guid: 'a', text: 'hi', handleId: '+15550001', dateCreated: 1000)],
      isGroup: true,
      resolve: (h) => h == '+15550001' ? 'Alice' : null,
    );
    final msg = items.whereType<MessageViewItem>().single;
    expect(msg.body, 'hi');
    expect(msg.senderLabel, 'Alice');
    expect(msg.isSystem, isFalse);
  });

  test('outgoing / 1:1 rows have no sender label', () {
    final items = _build([
      _m(guid: 'a', text: 'hi', isFromMe: true, dateCreated: 1000),
    ]);
    expect(items.whereType<MessageViewItem>().single.senderLabel, isNull);
  });

  test('reply preview resolved from loaded target', () {
    final items = _build(
      [
        _m(guid: 'target', text: 'original', handleId: '+1', dateCreated: 1000),
        _m(
          guid: 'reply',
          text: 'replying',
          threadOriginatorGuid: 'target',
          dateCreated: 2000,
        ),
      ],
      isGroup: true,
      resolve: (_) => 'Bob',
    );
    final reply = items.whereType<MessageViewItem>().firstWhere(
      (i) => i.message.guid == 'reply',
    );
    expect(reply.reply, isNotNull);
    expect(reply.reply!.targetLoaded, isTrue);
    expect(reply.reply!.text, 'original');
  });

  test('reaction merged into target as a precomputed system-free row', () {
    final items = _build([
      _m(guid: 'target', text: 'nice', dateCreated: 1000),
      _m(
        guid: 'r',
        associatedMessageType: 2000,
        associatedMessageGuid: 'p:0/target',
        dateCreated: 1100,
      ),
    ], prefs: const MessageDisplayPrefs(mergeTapbacks: true));
    final msgs = items.whereType<MessageViewItem>().toList();
    expect(msgs.length, 1); // reaction merged, not a separate row
    expect(msgs.single.reactions.length, 1);
  });

  test('retracted + service rows are system with precomputed labels', () {
    final items = _build([
      _m(guid: 's', itemType: 2, dateCreated: 1000),
      _m(
        guid: 'r',
        text: 'gone',
        isRetracted: true,
        isFromMe: true,
        dateCreated: 2000,
      ),
    ], prefs: const MessageDisplayPrefs(mergeConsecutiveSystem: false));
    final msgs = items.whereType<MessageViewItem>().toList();
    expect(msgs.every((m) => m.isSystem), isTrue);
    final retracted = msgs.firstWhere((m) => m.message.guid == 'r');
    expect(retracted.systemLabel, 'You unsent a message');
  });

  test('empty edited residue is a system row, not a normal bubble', () {
    final items = _build([
      _m(
        guid: 'edited-residue',
        isEdited: true,
        semanticKind: 'empty_edited_residue',
        renderRecommendation: 'system',
        unsupportedReason: 'empty_edited_residue',
        dateCreated: 1000,
      ),
    ], prefs: const MessageDisplayPrefs(mergeConsecutiveSystem: false));
    final row = items.whereType<MessageViewItem>().single;
    expect(row.kind.name, 'unknown');
    expect(row.isSystem, isTrue);
    expect(row.body, isNull);
    expect(row.systemLabel, 'Unsupported message');
  });

  test('effect hint precomputed only when prefs enable it', () {
    final on = _build([
      _m(
        guid: 'a',
        text: 'boom',
        expressiveSendStyleId: 'com.apple.MobileSMS.expressivesend.impact',
        dateCreated: 1,
      ),
    ], prefs: const MessageDisplayPrefs(showEffectHints: true));
    expect(on.whereType<MessageViewItem>().single.effectHint, 'Sent with Slam');

    final off = _build([
      _m(
        guid: 'a',
        text: 'boom',
        expressiveSendStyleId: 'com.apple.MobileSMS.expressivesend.impact',
        dateCreated: 1,
      ),
    ], prefs: const MessageDisplayPrefs(showEffectHints: false));
    expect(off.whereType<MessageViewItem>().single.effectHint, isNull);
  });

  test(
    'compact delivery visibility: only the latest outgoing shows status',
    () {
      final items = _build(
        [
          _m(guid: 'o1', text: 'one', isFromMe: true, dateCreated: 1000),
          _m(guid: 'o2', text: 'two', isFromMe: true, dateCreated: 2000),
        ],
        prefs: const MessageDisplayPrefs(
          deliveryLabels: DeliveryLabelMode.compact,
        ),
      );
      final msgs = items.whereType<MessageViewItem>().toList();
      expect(
        msgs.firstWhere((m) => m.message.guid == 'o1').showStatus,
        isFalse,
      );
      expect(msgs.firstWhere((m) => m.message.guid == 'o2').showStatus, isTrue);
    },
  );

  group('C21u timestamp grouping', () {
    test('no time separator for closely-spaced same-day messages', () {
      final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
      final items = _build([
        _m(guid: 'a', text: 'one', dateCreated: t0),
        _m(guid: 'b', text: 'two', dateCreated: t0 + 5 * 60 * 1000), // +5 min
      ]);
      expect(items.whereType<TimeSeparatorItem>(), isEmpty);
      // Exactly one date separator (the day), no extra time chips.
      expect(items.whereType<DateSeparatorItem>().length, 1);
    });

    test('inserts a time separator on a large same-day gap', () {
      final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
      final items = _build([
        _m(guid: 'a', text: 'one', dateCreated: t0),
        _m(guid: 'b', text: 'two', dateCreated: t0 + 90 * 60 * 1000), // +90 min
      ]);
      expect(items.whereType<TimeSeparatorItem>().length, 1);
    });

    test('only the newest message shows a default timestamp', () {
      final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
      final items = _build([
        _m(guid: 'a', text: 'one', dateCreated: t0),
        _m(guid: 'b', text: 'two', dateCreated: t0 + 60 * 1000),
      ]);
      final msgs = items.whereType<MessageViewItem>().toList();
      expect(
        msgs.firstWhere((m) => m.message.guid == 'a').showTimestamp,
        isFalse,
      );
      expect(
        msgs.firstWhere((m) => m.message.guid == 'b').showTimestamp,
        isTrue,
      );
    });

    test('shouldShowTimeSeparator + label are pure and correct', () {
      expect(shouldShowTimeSeparator(null, 100), isFalse);
      expect(shouldShowTimeSeparator(0, 30 * 60 * 1000), isFalse); // 30 min
      expect(shouldShowTimeSeparator(0, 60 * 60 * 1000), isTrue); // 60 min
      expect(timeOfDayLabel(DateTime(2024, 1, 1, 15, 45)), '3:45 PM');
      expect(timeOfDayLabel(DateTime(2024, 1, 1, 0, 5)), '12:05 AM');
    });
  });

  test('loadingOlder appends a spinner item at the chronological end', () {
    final items = _build([
      _m(guid: 'a', text: 'hi', dateCreated: 1),
    ], loadingOlder: true);
    expect(items.last, isA<LoadingOlderItem>());
  });

  test('stable keys per item', () {
    final items = _build([_m(guid: 'a', text: 'hi', dateCreated: 1)]);
    final keys = items.map((i) => i.key).toList();
    expect(keys.toSet().length, keys.length); // unique
    expect(keys.contains('msg:a'), isTrue);
  });
}
