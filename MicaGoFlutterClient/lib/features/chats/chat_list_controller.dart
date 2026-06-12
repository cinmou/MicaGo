import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import 'models/chat_summary.dart';
import 'realtime_event_helpers.dart' as rt;

enum ChatListState { idle, loading, loaded, empty, error }

/// Loads and holds the chat list from `GET /api/chats`.
class ChatListController extends ChangeNotifier {
  final AppController app;

  ChatListController(this.app);

  ChatListState state = ChatListState.idle;
  List<ChatSummary> chats = const [];
  String? error;
  StreamSubscription<WsEvent>? _wsSub;
  Timer? _reloadDebounce;

  /// When true, also request debug-only/noise-only chats from the server.
  bool includeDebug = false;

  bool get isLoading => state == ChatListState.loading;

  void startRealtime() {
    _wsSub ??= app.ws.events.listen(_onWsEvent);
    unawaited(app.catchUp(reason: 'chat-list'));
  }

  /// Updates the debug-chats preference and reloads if it changed.
  void setIncludeDebug(bool value) {
    if (includeDebug == value) return;
    includeDebug = value;
    unawaited(load(showSpinner: false));
  }

  /// Loads the chat list. [showSpinner] controls whether to flip into the
  /// loading state (false for a silent pull-to-refresh).
  Future<void> load({bool showSpinner = true}) async {
    final api = app.api;
    if (api == null) {
      final cached = await app.cache.listChats(includeDebug: includeDebug);
      chats = cached;
      state = cached.isEmpty ? ChatListState.error : ChatListState.loaded;
      error = cached.isEmpty ? 'Not connected to a server.' : null;
      notifyListeners();
      return;
    }

    if (showSpinner) {
      final cached = await app.cache.listChats(includeDebug: includeDebug);
      if (cached.isNotEmpty) {
        chats = cached;
        state = ChatListState.loaded;
      } else {
        state = ChatListState.loading;
      }
      error = null;
      notifyListeners();
    }

    try {
      final result = await api.getChats(debug: includeDebug);
      await app.cache.upsertChats(result);
      chats = result;
      state = result.isEmpty ? ChatListState.empty : ChatListState.loaded;
      error = null;
    } on ApiException catch (e) {
      final cached = await app.cache.listChats(includeDebug: includeDebug);
      if (cached.isNotEmpty) {
        chats = cached;
        state = ChatListState.loaded;
        error = null;
      } else {
        state = ChatListState.error;
        error = _humanize(e);
      }
    }
    notifyListeners();
  }

  Future<void> hideChat(String guid, bool hidden) async {
    await app.cache.setChatHidden(guid, hidden);
    chats = await app.cache.listChats(includeDebug: includeDebug);
    notifyListeners();
  }

  Future<void> alwaysShowChat(String guid, bool visible) async {
    await app.cache.setChatAlwaysVisible(guid, visible);
    chats = await app.cache.listChats(includeDebug: includeDebug);
    notifyListeners();
  }

  String _humanize(ApiException e) {
    switch (e.code) {
      case 'unauthorized':
        return 'Token rejected (401). Re-pair with the server.';
      case 'timeout':
        return 'Timed out loading chats.';
      case 'network_error':
        return 'Could not reach the server.';
      default:
        return e.message;
    }
  }

  void _onWsEvent(WsEvent e) {
    switch (e.type) {
      case 'message:new':
      case 'message:update':
        unawaited(_patchMessageEvent(e));
        break;
      case 'message:unsend':
        unawaited(_patchUnsendEvent(e));
        break;
      default:
        break;
    }
  }

  Future<void> _patchMessageEvent(WsEvent e) async {
    final msg = rt.messageFromWsEvent(e);
    final chatGuid = msg?.chatGuid;
    if (msg == null || chatGuid == null || chatGuid.isEmpty) {
      await app.recordRealtimeFallback(
        missingChatGuid: msg != null,
        malformed: msg == null,
        chatListReload: true,
      );
      _scheduleServerReload();
      return;
    }
    try {
      if (rt.isReactionMessage(msg)) {
        final ok = await app.cache.applyReactionEvent(chatGuid, msg);
        if (!ok) {
          await app.recordRealtimeFallback(chatListReload: true);
          _scheduleServerReload();
          return;
        }
        await app.markRealtimeEventApplied(e);
        return;
      }

      await app.cache.upsertMessage(chatGuid, msg);
      final known = await app.cache.bumpChatWithMessage(msg);
      if (!known) {
        await app.recordRealtimeFallback(chatListReload: true);
        _scheduleServerReload();
        return;
      }
      chats = await app.cache.listChats(includeDebug: includeDebug);
      state = chats.isEmpty ? ChatListState.empty : ChatListState.loaded;
      error = null;
      await app.markRealtimeEventApplied(e, localDbWrites: 2);
      notifyListeners();
    } catch (_) {
      await app.recordRealtimeFallback(chatListReload: true);
      _scheduleServerReload();
    }
  }

  Future<void> _patchUnsendEvent(WsEvent e) async {
    final chatGuid = rt.chatGuidFromWsEvent(e);
    final guid = e.data['guid'] as String?;
    if (chatGuid == null || guid == null) {
      await app.recordRealtimeFallback(
        missingChatGuid: chatGuid == null,
        malformed: guid == null,
        chatListReload: true,
      );
      _scheduleServerReload();
      return;
    }
    try {
      await app.cache.applyUnsend(
        chatGuid,
        guid,
        _asInt(e.data['dateRetracted']),
      );
      chats = await app.cache.listChats(includeDebug: includeDebug);
      await app.markRealtimeEventApplied(e);
      notifyListeners();
    } catch (_) {
      await app.recordRealtimeFallback(chatListReload: true);
      _scheduleServerReload();
    }
  }

  void _scheduleServerReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 150), () {
      load(showSpinner: false);
    });
  }

  int? _asInt(Object? value) => value is num ? value.toInt() : null;

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _wsSub?.cancel();
    super.dispose();
  }
}
