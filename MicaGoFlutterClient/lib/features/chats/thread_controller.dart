import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import 'models/message_model.dart';

enum ThreadState { loading, loaded, empty, error }

/// Loads a chat's message history, sends text (optimistically), and reacts to
/// realtime events.
///
/// Server gap: `message:new`/`message:update`/`message:unsend` payloads do not
/// include a chat GUID, so we cannot route an incoming message to a specific
/// open thread. The safe, documented fallback is a debounced reload of the
/// thread on any such event. `send:match`/`send:error` carry our `tempGuid`, so
/// those update the matching optimistic message precisely.
class ThreadController extends ChangeNotifier {
  final AppController app;
  final String chatGuid;

  ThreadController({required this.app, required this.chatGuid});

  static const int _pageSize = 50;

  ThreadState state = ThreadState.loading;
  String? error;

  // Confirmed messages from the server (chronological), deduped by GUID.
  final List<MessageModel> _server = [];
  // Optimistic outgoing messages (pending/failed), keyed by tempId.
  final List<MessageModel> _locals = [];
  final Set<String> _serverGuids = {};

  /// Older-message pagination (server has no cursor → limit/offset).
  int _offset = 0;
  bool hasMore = true;
  bool loadingOlder = false;

  StreamSubscription<WsEvent>? _wsSub;
  Timer? _reloadDebounce;

  /// Display list: server history followed by not-yet-confirmed local sends.
  /// Chronological (oldest → newest); the thread view renders it reversed.
  List<MessageModel> get messages => [..._server, ..._locals];

  void start() {
    _wsSub = app.ws.events.listen(_onWsEvent);
    load();
  }

  /// Loads (or reloads) the newest page. Resets pagination.
  Future<void> load({bool showSpinner = true}) async {
    final api = app.api;
    if (api == null) {
      state = ThreadState.error;
      error = 'Not connected.';
      notifyListeners();
      return;
    }
    if (showSpinner) {
      state = ThreadState.loading;
      error = null;
      notifyListeners();
    }
    try {
      final fetched = await api.getMessages(chatGuid, limit: _pageSize, offset: 0);
      // Server returns newest-first; reverse to chronological (oldest → newest).
      _server.clear();
      _serverGuids.clear();
      for (final m in fetched.reversed) {
        if (m.guid.isEmpty || _serverGuids.add(m.guid)) _server.add(m);
      }
      _offset = fetched.length;
      hasMore = fetched.length >= _pageSize;
      // Drop any local message the server now reports (matched by guid).
      _locals.removeWhere((l) =>
          l.guid.isNotEmpty && _serverGuids.contains(l.guid));
      state = (_server.isEmpty && _locals.isEmpty)
          ? ThreadState.empty
          : ThreadState.loaded;
      error = null;
    } on ApiException catch (e) {
      state = ThreadState.error;
      error = _humanize(e);
    }
    notifyListeners();
  }

  /// Loads the next older page and **prepends** it, deduping by GUID. The thread
  /// view uses a reversed list, so prepending older history does not shift the
  /// visible viewport (scroll position is preserved).
  Future<void> loadOlder() async {
    if (loadingOlder || !hasMore) return;
    final api = app.api;
    if (api == null) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final fetched =
          await api.getMessages(chatGuid, limit: _pageSize, offset: _offset);
      // Older batch, chronological, deduped, prepended at the front.
      final older = <MessageModel>[];
      for (final m in fetched.reversed) {
        if (m.guid.isEmpty || _serverGuids.add(m.guid)) older.add(m);
      }
      _server.insertAll(0, older);
      _offset += fetched.length;
      hasMore = fetched.length >= _pageSize;
    } on ApiException {
      // Keep what we have; a transient failure shouldn't break the thread.
      // hasMore stays true so the user can retry by scrolling up again.
    }
    loadingOlder = false;
    notifyListeners();
  }

  /// Optimistically sends [text]. Returns immediately after queuing; state
  /// updates flow through [notifyListeners].
  Future<void> send(String text) async {
    final trimmed = text.trim();
    final api = app.api;
    if (trimmed.isEmpty || api == null) return;

    final tempId = 'tmp-${DateTime.now().microsecondsSinceEpoch}';
    _locals.add(MessageModel.optimistic(
      tempId: tempId,
      text: trimmed,
      dateCreated: DateTime.now().millisecondsSinceEpoch,
    ));
    state = ThreadState.loaded;
    notifyListeners();

    try {
      final confirmed = await api.sendText(
        chatGuid: chatGuid,
        tempGuid: tempId,
        message: trimmed,
      );
      _confirmLocal(tempId, confirmed);
    } on ApiException {
      _markLocalFailed(tempId);
    }
  }

  /// Retries a previously failed local send.
  Future<void> retry(String tempId) async {
    final idx = _locals.indexWhere((m) => m.tempId == tempId);
    if (idx < 0) return;
    final text = _locals[idx].text ?? '';
    _locals.removeAt(idx);
    notifyListeners();
    await send(text);
  }

  void _confirmLocal(String tempId, MessageModel confirmed) {
    _locals.removeWhere((m) => m.tempId == tempId);
    if (confirmed.guid.isEmpty || _serverGuids.add(confirmed.guid)) {
      _server.add(confirmed);
    }
    state = ThreadState.loaded;
    notifyListeners();
  }

  void _markLocalFailed(String tempId) {
    final idx = _locals.indexWhere((m) => m.tempId == tempId);
    if (idx >= 0) {
      _locals[idx] = _locals[idx].copyWith(localState: LocalSendState.failed);
      notifyListeners();
    }
  }

  void _onWsEvent(WsEvent e) {
    switch (e.type) {
      case 'send:match':
        final tempId = e.data['tempGuid'] as String?;
        final msg = e.data['message'];
        if (tempId != null && msg is Map<String, dynamic>) {
          if (_locals.any((m) => m.tempId == tempId)) {
            _confirmLocal(tempId, MessageModel.fromJson(msg));
          }
        }
        break;
      case 'send:error':
        final tempId = e.data['tempGuid'] as String?;
        if (tempId != null) _markLocalFailed(tempId);
        break;
      case 'message:new':
      case 'message:update':
      case 'message:unsend':
        // No chatGuid on the payload → safe fallback: debounced reload.
        _scheduleReload();
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
