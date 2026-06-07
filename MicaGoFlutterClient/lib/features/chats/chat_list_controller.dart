import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import 'models/chat_summary.dart';

enum ChatListState { idle, loading, loaded, empty, error }

/// Loads and holds the chat list from `GET /api/chats`.
class ChatListController extends ChangeNotifier {
  final AppController app;

  ChatListController(this.app);

  ChatListState state = ChatListState.idle;
  List<ChatSummary> chats = const [];
  String? error;

  bool get isLoading => state == ChatListState.loading;

  /// Loads the chat list. [showSpinner] controls whether to flip into the
  /// loading state (false for a silent pull-to-refresh).
  Future<void> load({bool showSpinner = true}) async {
    final api = app.api;
    if (api == null) {
      state = ChatListState.error;
      error = 'Not connected to a server.';
      notifyListeners();
      return;
    }

    if (showSpinner) {
      state = ChatListState.loading;
      error = null;
      notifyListeners();
    }

    try {
      final result = await api.getChats();
      chats = result;
      state = result.isEmpty ? ChatListState.empty : ChatListState.loaded;
      error = null;
    } on ApiException catch (e) {
      state = ChatListState.error;
      error = _humanize(e);
    }
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
}
