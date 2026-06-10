import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import 'models/chat_summary.dart';

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
      case 'message:unsend':
        _reloadDebounce?.cancel();
        _reloadDebounce = Timer(const Duration(milliseconds: 150), () {
          load(showSpinner: false);
        });
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _wsSub?.cancel();
    super.dispose();
  }
}
