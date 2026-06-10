import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../features/chats/models/chat_summary.dart';
import '../../features/chats/models/message_model.dart';

class LocalCacheStore {
  Database? _db;

  Future<void> open() async {
    if (_db != null) return;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'micago_client_cache.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
CREATE TABLE chats (
  guid TEXT PRIMARY KEY,
  json TEXT NOT NULL,
  latest_renderable_at INTEGER,
  hidden INTEGER NOT NULL DEFAULT 0,
  always_visible INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
''');
        await db.execute('''
CREATE TABLE messages (
  key TEXT PRIMARY KEY,
  guid TEXT,
  temp_id TEXT,
  chat_guid TEXT NOT NULL,
  json TEXT NOT NULL,
  local_state TEXT NOT NULL,
  date_created INTEGER,
  updated_at INTEGER NOT NULL
);
''');
        await db.execute(
          'CREATE INDEX messages_chat_date ON messages(chat_guid, date_created);',
        );
        await db.execute('CREATE INDEX messages_guid ON messages(guid);');
        await db.execute('CREATE INDEX messages_temp ON messages(temp_id);');
        await db.execute('''
CREATE TABLE metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
''');
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> clearAll() async {
    final db = await _ready();
    await db.delete('messages');
    await db.delete('chats');
    await db.delete('metadata');
  }

  Future<List<ChatSummary>> listChats({
    bool includeDebug = false,
    bool includeHidden = false,
  }) async {
    final db = await _ready();
    final rows = await db.query(
      'chats',
      orderBy: 'COALESCE(latest_renderable_at, 0) DESC, updated_at DESC',
    );
    return rows
        .map(_chatFromRow)
        .where((chat) => includeDebug || chat.hasRenderableMessages)
        .where((chat) => includeHidden || !_isHiddenRow(rows, chat.guid))
        .toList(growable: false);
  }

  Future<void> upsertChats(Iterable<ChatSummary> chats) async {
    final db = await _ready();
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final chat in chats) {
      batch.insert('chats', {
        'guid': chat.guid,
        'json': jsonEncode(chat.toJson()),
        'latest_renderable_at': chat.lastMessageAt,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> setChatHidden(String guid, bool hidden) async {
    final db = await _ready();
    await db.update(
      'chats',
      {'hidden': hidden ? 1 : 0},
      where: 'guid = ?',
      whereArgs: [guid],
    );
  }

  Future<void> setChatAlwaysVisible(String guid, bool visible) async {
    final db = await _ready();
    await db.update(
      'chats',
      {'always_visible': visible ? 1 : 0},
      where: 'guid = ?',
      whereArgs: [guid],
    );
  }

  Future<List<MessageModel>> listMessages(
    String chatGuid, {
    int limit = 200,
  }) async {
    final db = await _ready();
    final rows = await db.query(
      'messages',
      where: 'chat_guid = ?',
      whereArgs: [chatGuid],
      orderBy: 'date_created DESC, updated_at DESC',
      limit: limit,
    );
    return rows.map(_messageFromRow).toList(growable: false);
  }

  Future<void> replaceServerPage(
    String chatGuid,
    Iterable<MessageModel> messages,
  ) async {
    final db = await _ready();
    final batch = db.batch();
    batch.delete(
      'messages',
      where: "chat_guid = ? AND (temp_id IS NULL OR temp_id = '')",
      whereArgs: [chatGuid],
    );
    _batchUpsertMessages(batch, chatGuid, messages);
    await batch.commit(noResult: true);
  }

  Future<void> upsertMessage(String chatGuid, MessageModel message) async {
    final db = await _ready();
    final batch = db.batch();
    _batchUpsertMessages(batch, chatGuid, [message]);
    await batch.commit(noResult: true);
  }

  Future<void> addPending(String chatGuid, MessageModel message) async {
    await upsertMessage(chatGuid, message);
  }

  Future<void> setPendingState(String tempId, LocalSendState state) async {
    final db = await _ready();
    final rows = await db.query(
      'messages',
      where: 'temp_id = ?',
      whereArgs: [tempId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final msg = _messageFromRow(rows.first).copyWith(localState: state);
    await db.update(
      'messages',
      {
        'json': jsonEncode(msg.toJson()),
        'local_state': state.name,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'temp_id = ?',
      whereArgs: [tempId],
    );
  }

  Future<void> confirmPending(
    String chatGuid,
    String tempId,
    MessageModel server,
  ) async {
    final db = await _ready();
    final batch = db.batch();
    batch.delete('messages', where: 'temp_id = ?', whereArgs: [tempId]);
    _batchUpsertMessages(batch, chatGuid, [server]);
    await batch.commit(noResult: true);
  }

  Future<void> applyUnsend(
    String chatGuid,
    String guid,
    int? dateRetracted,
  ) async {
    final db = await _ready();
    final rows = await db.query(
      'messages',
      where: 'guid = ?',
      whereArgs: [guid],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final msg = _messageFromRow(rows.first).copyWith(
      text: '',
      attachments: const [],
      isRetracted: true,
      dateRetracted: dateRetracted,
      errorCode: 0,
      localState: LocalSendState.confirmed,
    );
    await upsertMessage(chatGuid, msg);
  }

  Future<void> writeMetadata(String key, String value) async {
    final db = await _ready();
    await db.insert('metadata', {
      'key': key,
      'value': value,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> readMetadata(String key) async {
    final db = await _ready();
    final rows = await db.query(
      'metadata',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<Database> _ready() async {
    await open();
    return _db!;
  }

  void _batchUpsertMessages(
    Batch batch,
    String chatGuid,
    Iterable<MessageModel> messages,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final message in messages) {
      final key = message.guid.isNotEmpty
          ? 'guid:${message.guid}'
          : 'temp:${message.tempId}';
      if (key.endsWith('null')) continue;
      batch.insert('messages', {
        'key': key,
        'guid': message.guid,
        'temp_id': message.tempId,
        'chat_guid': message.chatGuid ?? chatGuid,
        'json': jsonEncode(message.toJson(chatGuidFallback: chatGuid)),
        'local_state': message.localState.name,
        'date_created': message.dateCreated,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  ChatSummary _chatFromRow(Map<String, Object?> row) {
    final raw = jsonDecode(row['json'] as String) as Map<String, dynamic>;
    final chat = ChatSummary.fromJson(raw);
    final alwaysVisible = (row['always_visible'] as int? ?? 0) != 0;
    return alwaysVisible && !chat.hasRenderableMessages
        ? ChatSummary.fromJson({...raw, 'hasRenderableMessages': true})
        : chat;
  }

  bool _isHiddenRow(List<Map<String, Object?>> rows, String guid) {
    final row = rows.cast<Map<String, Object?>?>().firstWhere(
      (r) => r?['guid'] == guid,
      orElse: () => null,
    );
    if (row == null) return false;
    final alwaysVisible = (row['always_visible'] as int? ?? 0) != 0;
    if (alwaysVisible) return false;
    return (row['hidden'] as int? ?? 0) != 0;
  }

  MessageModel _messageFromRow(Map<String, Object?> row) {
    final raw = jsonDecode(row['json'] as String) as Map<String, dynamic>;
    return MessageModel.fromJson(raw).copyWith(
      localState: LocalSendState.values.firstWhere(
        (s) => s.name == row['local_state'],
        orElse: () => LocalSendState.confirmed,
      ),
    );
  }
}
