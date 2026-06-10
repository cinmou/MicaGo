import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import 'models/message_model.dart';
import 'store/message_collection.dart';
// Re-export the reconciliation predicate so existing callers/tests that import
// it from thread_controller continue to work after the store extraction.
export 'store/message_collection.dart' show shouldReconcileLocalWithServer;

enum ThreadState { loading, loaded, empty, error }

/// Drives one chat thread. Holds a [MessageCollection] (the per-chat store) and
/// *patches* it from REST pages + WebSocket events — it never reloads the whole
/// thread on an event when the payload is complete. Optimistic sends live in the
/// store and reconcile against later server rows.
class ThreadController extends ChangeNotifier {
  final AppController app;
  final String chatGuid;

  ThreadController({required this.app, required this.chatGuid});

  static const int _pageSize = 50;

  ThreadState state = ThreadState.loading;
  String? error;

  final MessageCollection _col = MessageCollection();

  int _offset = 0;
  bool hasMore = true;
  bool loadingOlder = false;

  StreamSubscription<WsEvent>? _wsSub;
  Timer? _reloadDebounce;

  /// Chronological (oldest → newest); the thread view renders it reversed.
  List<MessageModel> get messages => _col.ordered;

  void start() {
    _wsSub = app.ws.events.listen(_onWsEvent);
    unawaited(app.catchUp(reason: 'thread:$chatGuid'));
    load();
  }

  Future<void> load({bool showSpinner = true}) async {
    final api = app.api;
    if (api == null) {
      final cached = await app.cache.listMessages(chatGuid, limit: _pageSize);
      if (cached.isNotEmpty) {
        _col.replaceServerPage(cached);
        state = ThreadState.loaded;
        error = null;
      } else {
        state = ThreadState.error;
        error = 'Not connected.';
      }
      notifyListeners();
      return;
    }
    if (showSpinner) {
      final cached = await app.cache.listMessages(chatGuid, limit: _pageSize);
      if (cached.isNotEmpty) {
        _col.replaceServerPage(cached);
        state = ThreadState.loaded;
      } else {
        state = ThreadState.loading;
      }
      error = null;
      notifyListeners();
    }
    try {
      final fetched = await api.getMessages(
        chatGuid,
        limit: _pageSize,
        offset: 0,
      );
      await app.cache.replaceServerPage(chatGuid, fetched);
      _col.replaceServerPage(fetched);
      _offset = fetched.length;
      hasMore = fetched.length >= _pageSize;
      state = _col.isEmpty ? ThreadState.empty : ThreadState.loaded;
      error = null;
    } on ApiException catch (e) {
      final cached = await app.cache.listMessages(chatGuid, limit: _pageSize);
      if (cached.isNotEmpty) {
        _col.replaceServerPage(cached);
        state = ThreadState.loaded;
        error = null;
      } else {
        state = ThreadState.error;
        error = _humanize(e);
      }
    }
    notifyListeners();
  }

  Future<void> loadOlder() async {
    if (loadingOlder || !hasMore) return;
    final api = app.api;
    if (api == null) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final fetched = await api.getMessages(
        chatGuid,
        limit: _pageSize,
        offset: _offset,
      );
      for (final m in fetched) {
        await app.cache.upsertMessage(chatGuid, m);
      }
      _col.mergeOlder(fetched);
      _offset += fetched.length;
      hasMore = fetched.length >= _pageSize;
    } on ApiException {
      // Keep what we have; a transient failure shouldn't break the thread.
    }
    loadingOlder = false;
    notifyListeners();
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    final api = app.api;
    if (trimmed.isEmpty || api == null) return;

    final tempId = 'tmp-${DateTime.now().microsecondsSinceEpoch}';
    final optimistic = MessageModel.optimistic(
      tempId: tempId,
      text: trimmed,
      dateCreated: DateTime.now().millisecondsSinceEpoch,
    );
    _col.addPending(optimistic);
    await app.cache.addPending(chatGuid, optimistic);
    state = ThreadState.loaded;
    notifyListeners();

    try {
      final confirmed = await api.sendText(
        chatGuid: chatGuid,
        tempGuid: tempId,
        message: trimmed,
      );
      _col.confirmPending(tempId, confirmed);
      await app.cache.confirmPending(chatGuid, tempId, confirmed);
    } on ApiException catch (e) {
      // AppleScript succeeded but DB confirmation timed out → sentUnconfirmed,
      // NOT failed; a later server row / update will upgrade it.
      _col.setPendingState(
        tempId,
        e.code == 'send_confirmation_timeout'
            ? LocalSendState.sentUnconfirmed
            : LocalSendState.failed,
      );
      await app.cache.setPendingState(
        tempId,
        e.code == 'send_confirmation_timeout'
            ? LocalSendState.sentUnconfirmed
            : LocalSendState.failed,
      );
    }
    notifyListeners();
  }

  Future<void> retry(String tempId) async {
    final text = _col.removePending(tempId);
    if (text == null) return;
    notifyListeners();
    await send(text);
  }

  void _onWsEvent(WsEvent e) {
    switch (e.type) {
      case 'send:match':
        final tempId = e.data['tempGuid'] as String?;
        final msg = e.data['message'];
        if (tempId != null &&
            msg is Map<String, dynamic> &&
            _col.pendingByTempId(tempId) != null) {
          _col.confirmPending(tempId, MessageModel.fromJson(msg));
          unawaited(
            app.cache.confirmPending(
              chatGuid,
              tempId,
              MessageModel.fromJson(msg),
            ),
          );
          notifyListeners();
        }
        break;
      case 'send:error':
        final tempId = e.data['tempGuid'] as String?;
        final code = e.data['code'] as String?;
        final recoverable =
            e.data['recoverable'] == true ||
            e.data['state'] == 'sent_unconfirmed' ||
            code == 'send_confirmation_timeout';
        if (tempId != null && _col.pendingByTempId(tempId) != null) {
          _col.setPendingState(
            tempId,
            recoverable
                ? LocalSendState.sentUnconfirmed
                : LocalSendState.failed,
          );
          unawaited(
            app.cache.setPendingState(
              tempId,
              recoverable
                  ? LocalSendState.sentUnconfirmed
                  : LocalSendState.failed,
            ),
          );
          notifyListeners();
        }
        break;
      case 'message:new':
      case 'message:update':
        final msg = messageFromWsEvent(e);
        if (msg == null || msg.chatGuid == null) {
          _scheduleReload();
          break;
        }
        if (msg.chatGuid == chatGuid) {
          _col.upsertServer(msg);
          unawaited(app.cache.upsertMessage(chatGuid, msg));
          state = ThreadState.loaded;
          notifyListeners();
        }
        break;
      case 'message:unsend':
        final eventChat = chatGuidFromWsEvent(e);
        if (eventChat == null) {
          _scheduleReload();
          break;
        }
        if (eventChat == chatGuid) {
          final guid = e.data['guid'] as String?;
          final dateRetracted = _asInt(e.data['dateRetracted']);
          if (guid == null || !_col.applyUnsend(guid, dateRetracted)) {
            _scheduleReload();
          } else {
            unawaited(app.cache.applyUnsend(chatGuid, guid, dateRetracted));
            notifyListeners();
          }
        }
        break;
      default:
        break;
    }
  }

  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      load(showSpinner: false);
    });
  }

  String _humanize(ApiException e) {
    switch (e.code) {
      case 'unauthorized':
        return 'Token rejected (401). Re-pair with the server.';
      case 'timeout':
        return 'Timed out loading messages.';
      case 'network_error':
        return 'Could not reach the server.';
      case 'not_found':
        return 'This chat was not found on the server.';
      default:
        return e.message;
    }
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _wsSub?.cancel();
    super.dispose();
  }
}

MessageModel? messageFromWsEvent(WsEvent e) {
  final raw = e.type == 'message:update' ? e.data['message'] : e.data;
  if (raw is Map<String, dynamic>) return MessageModel.fromJson(raw);
  return null;
}

String? chatGuidFromWsEvent(WsEvent e) {
  if (e.data['chatGuid'] is String) return e.data['chatGuid'] as String;
  final msg = e.data['message'];
  if (msg is Map<String, dynamic> && msg['chatGuid'] is String) {
    return msg['chatGuid'] as String;
  }
  return null;
}

int? _asInt(Object? v) => v is num ? v.toInt() : null;
