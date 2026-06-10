import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late LocalCacheStore store;

  setUp(() async {
    store = LocalCacheStore();
    await store.open();
    await store.clearAll();
  });

  tearDown(() async {
    await store.clearAll();
    await store.close();
  });

  test('cold start returns cached chats and messages', () async {
    await store.upsertChats([
      const ChatSummary(
        guid: 'chat-1',
        chatIdentifier: '+15550001',
        lastMessageAt: 20,
        lastMessagePreview: 'hello',
      ),
    ]);
    await store.replaceServerPage('chat-1', [
      MessageModel.fromJson({
        'guid': 'm1',
        'chatGuid': 'chat-1',
        'text': 'hello',
        'dateCreated': 20,
      }),
    ]);

    final chats = await store.listChats();
    final messages = await store.listMessages('chat-1');

    expect(chats.single.guid, 'chat-1');
    expect(messages.single.text, 'hello');
  });

  test('message update and unsend patch existing row', () async {
    await store.upsertMessage(
      'chat-1',
      MessageModel.fromJson({
        'guid': 'm1',
        'chatGuid': 'chat-1',
        'text': 'hello',
        'dateCreated': 20,
      }),
    );
    await store.upsertMessage(
      'chat-1',
      MessageModel.fromJson({
        'guid': 'm1',
        'chatGuid': 'chat-1',
        'text': 'hello',
        'dateCreated': 20,
        'dateDelivered': 30,
        'isDelivered': true,
      }),
    );
    expect((await store.listMessages('chat-1')).single.isDelivered, isTrue);

    await store.applyUnsend('chat-1', 'm1', 40);
    final retracted = (await store.listMessages('chat-1')).single;
    expect(retracted.isRetracted, isTrue);
    expect(retracted.text, '');
  });

  test('sentUnconfirmed survives restart and reconciles with send match', () async {
    final pending = MessageModel.optimistic(
      tempId: 'tmp-1',
      text: 'slow',
      dateCreated: 100,
    ).copyWith(localState: LocalSendState.sentUnconfirmed);
    await store.addPending('chat-1', pending);
    await store.close();

    store = LocalCacheStore();
    await store.open();
    var messages = await store.listMessages('chat-1');
    expect(messages.single.localState, LocalSendState.sentUnconfirmed);

    await store.confirmPending(
      'chat-1',
      'tmp-1',
      MessageModel.fromJson({
        'guid': 'real-1',
        'chatGuid': 'chat-1',
        'text': 'slow',
        'dateCreated': 101,
        'isFromMe': true,
      }),
    );
    messages = await store.listMessages('chat-1');
    expect(messages.single.guid, 'real-1');
    expect(messages.single.localState, LocalSendState.confirmed);
  });

  test('hidden chat is hidden locally and always visible overrides', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'noise', hasRenderableMessages: false),
    ]);
    expect(await store.listChats(), isEmpty);
    expect(await store.listChats(includeDebug: true), hasLength(1));

    await store.setChatAlwaysVisible('noise', true);
    expect(await store.listChats(), hasLength(1));

    await store.setChatHidden('noise', true);
    expect(await store.listChats(), hasLength(1));
  });
}
