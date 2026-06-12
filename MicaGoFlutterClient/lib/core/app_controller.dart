import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models/connection_profile.dart';
import 'models/server_urls.dart';
import 'network/api_client.dart';
import 'network/websocket_client.dart';
import 'storage/local_cache_store.dart';
import 'storage/secure_store.dart';
import '../features/chats/realtime_event_helpers.dart';

/// Counts from a per-chat initial backfill (C10 Part F diagnostics).
class BackfillDiagnostics {
  int chatsFetched = 0;
  int chatsWritten = 0;
  int messagesFetched = 0;
  int messagesWritten = 0;
  int attachmentsMetadataWritten = 0;
  int hiddenDebugRowsIgnored = 0;
  int failedChats = 0;
  String? lastError;

  @override
  String toString() =>
      'chats=$chatsFetched/$chatsWritten messages=$messagesFetched/$messagesWritten '
      'attachments=$attachmentsMetadataWritten hidden=$hiddenDebugRowsIgnored '
      'failed=$failedChats error=${lastError ?? ""}';
}

class RealtimeRefreshDiagnostics {
  String? lastAppliedEventCursor;
  DateTime? lastEventAt;
  DateTime? lastReconnectAt;
  String? lastCatchUpCursor;
  int lastCatchUpResultCount = 0;
  int eventsPatchedDirectly = 0;
  int eventsForcedReload = 0;
  int chatListEventReloads = 0;
  int droppedMissingChatGuid = 0;
  int droppedMalformedEvents = 0;
  int localDbWrites = 0;
  int reconnectCount = 0;
  String? lastReconnectReason;
}

/// App-wide state: the active connection profile, the REST client built from
/// it, the realtime WebSocket client, and the last-fetched server endpoints.
///
/// Exposed via `provider` and used as the router's refresh listenable so route
/// guards re-evaluate when the profile is saved or cleared.
class AppController extends ChangeNotifier {
  final SecureStore store;
  final LocalCacheStore cache = LocalCacheStore();

  /// The realtime client is long-lived; home screen listens to it directly.
  final WebSocketClient ws = WebSocketClient();

  ConnectionProfile? _profile;
  ApiClient? _api;
  ServerUrls? _serverUrls;
  bool _bootstrapped = false;
  DateTime? _lastCatchUpSyncAt;
  bool _catchUpInFlight = false;
  bool _realtimeCatchingUp = false;
  final RealtimeRefreshDiagnostics realtimeDiagnostics =
      RealtimeRefreshDiagnostics();

  AppController({required this.store}) {
    ws.addListener(_onWebSocketStatusChanged);
  }

  ConnectionProfile? get profile => _profile;
  ApiClient? get api => _api;
  ServerUrls? get serverUrls => _serverUrls;
  bool get hasProfile => _profile?.isComplete ?? false;
  bool get bootstrapped => _bootstrapped;
  DateTime? get lastCatchUpSyncAt => _lastCatchUpSyncAt;
  bool get realtimeCatchingUp => _realtimeCatchingUp;

  /// Loads any persisted profile at startup.
  Future<void> bootstrap() async {
    await cache.open();
    await _loadRealtimeDiagnostics();
    _profile = await store.loadProfile();
    _rebuildApi();
    _bootstrapped = true;
    notifyListeners();
  }

  /// Builds a throwaway [ApiClient] for the connection-test screen without
  /// persisting anything.
  ApiClient buildProbeClient(ConnectionProfile profile) {
    return ApiClient(baseUrl: profile.baseUrl, token: profile.token);
  }

  /// Persists [profile] and activates it as the live connection.
  Future<void> saveAndActivate(ConnectionProfile profile) async {
    await store.saveProfile(profile);
    _profile = profile;
    _serverUrls = null;
    _rebuildApi();
    notifyListeners();
    unawaited(catchUp(reason: 'profile'));
  }

  /// Fetches `GET /api/server/urls` using the active client.
  Future<void> refreshServerUrls() async {
    final api = _api;
    if (api == null) return;
    _serverUrls = await api.getServerUrls();
    await _persistEndpointCandidates(_serverUrls!);
    notifyListeners();
  }

  Future<void> _persistEndpointCandidates(ServerUrls urls) async {
    final profile = _profile;
    if (profile == null) return;
    final lan = urls.lan.isNotEmpty ? urls.lan.first : null;
    final pub = urls.public?.enabled == true ? urls.public : null;
    final next = profile.copyWith(
      lanBaseUrl: lan?.baseUrl,
      lanWsUrl: lan?.wsUrl,
      publicBaseUrl: pub?.baseUrl,
      publicWsUrl: pub?.wsUrl,
    );
    _profile = next;
    await store.saveProfile(next);
    _rebuildApi();
  }

  /// Opens the realtime WebSocket using the active profile.
  void connectWebSocket() {
    final profile = _profile;
    if (profile == null) return;
    ws.connect(profile.effectiveWsUrl, profile.token);
  }

  Future<void> catchUp({
    required String reason,
    Duration minInterval = const Duration(seconds: 4),
  }) async {
    final api = _api;
    if (api == null || _catchUpInFlight) return;
    final last = _lastCatchUpSyncAt;
    if (last != null && DateTime.now().difference(last) < minInterval) {
      return;
    }
    _catchUpInFlight = true;
    try {
      final cursor = realtimeDiagnostics.lastAppliedEventCursor;
      realtimeDiagnostics.lastCatchUpCursor = cursor;
      await cache.writeMetadata('last_catch_up_cursor', cursor ?? '');
      final count = await api.syncNow();
      realtimeDiagnostics.lastCatchUpResultCount = count;
      _lastCatchUpSyncAt = DateTime.now();
      await cache.writeMetadata(
        'last_catch_up_time',
        _lastCatchUpSyncAt!.millisecondsSinceEpoch.toString(),
      );
      await cache.writeMetadata('last_catch_up_result_count', '$count');
      notifyListeners();
    } catch (_) {
      // Foreground catch-up is opportunistic; normal REST loads still surface
      // actionable errors in the views that requested data.
    } finally {
      _catchUpInFlight = false;
    }
  }

  void _onWebSocketStatusChanged() {
    if (ws.status == WsStatus.connected) {
      unawaited(_handleWebSocketReconnect());
    }
  }

  Future<void> _handleWebSocketReconnect() async {
    realtimeDiagnostics.lastReconnectAt = DateTime.now();
    realtimeDiagnostics.reconnectCount++;
    realtimeDiagnostics.lastReconnectReason = 'websocket_connected';
    _realtimeCatchingUp = true;
    await cache.writeMetadata(
      'last_reconnect_at',
      realtimeDiagnostics.lastReconnectAt!.millisecondsSinceEpoch.toString(),
    );
    await cache.writeMetadata(
      'reconnect_count',
      '${realtimeDiagnostics.reconnectCount}',
    );
    await cache.writeMetadata('last_reconnect_reason', 'websocket_connected');
    notifyListeners();
    try {
      await catchUp(reason: 'websocket', minInterval: Duration.zero);
    } finally {
      _realtimeCatchingUp = false;
      notifyListeners();
    }
  }

  Future<bool> markRealtimeEventApplied(
    WsEvent event, {
    int localDbWrites = 1,
  }) async {
    final cursor = realtimeCursorForEvent(event);
    final previous = realtimeDiagnostics.lastAppliedEventCursor;
    if (cursor != null && _shouldAdvanceCursor(previous, cursor)) {
      realtimeDiagnostics.lastAppliedEventCursor = cursor;
      await cache.writeMetadata('last_applied_event_cursor', cursor);
    }
    realtimeDiagnostics.lastEventAt = DateTime.now();
    realtimeDiagnostics.eventsPatchedDirectly++;
    realtimeDiagnostics.localDbWrites += localDbWrites;
    await cache.writeMetadata(
      'last_event_at',
      realtimeDiagnostics.lastEventAt!.millisecondsSinceEpoch.toString(),
    );
    await _writeCounter(
      'events_patched_directly',
      realtimeDiagnostics.eventsPatchedDirectly,
    );
    await _writeCounter(
      'realtime_local_db_writes',
      realtimeDiagnostics.localDbWrites,
    );
    notifyListeners();
    return cursor != null;
  }

  Future<void> recordRealtimeFallback({
    bool missingChatGuid = false,
    bool malformed = false,
    bool chatListReload = false,
  }) async {
    realtimeDiagnostics.eventsForcedReload++;
    if (missingChatGuid) realtimeDiagnostics.droppedMissingChatGuid++;
    if (malformed) realtimeDiagnostics.droppedMalformedEvents++;
    if (chatListReload) realtimeDiagnostics.chatListEventReloads++;
    await _writeCounter(
      'events_forced_reload',
      realtimeDiagnostics.eventsForcedReload,
    );
    await _writeCounter(
      'dropped_missing_chat_guid',
      realtimeDiagnostics.droppedMissingChatGuid,
    );
    await _writeCounter(
      'dropped_malformed_events',
      realtimeDiagnostics.droppedMalformedEvents,
    );
    await _writeCounter(
      'chat_list_event_reloads',
      realtimeDiagnostics.chatListEventReloads,
    );
    notifyListeners();
  }

  Future<void> _writeCounter(String key, int value) =>
      cache.writeMetadata(key, '$value');

  Future<void> _loadRealtimeDiagnostics() async {
    realtimeDiagnostics.lastAppliedEventCursor = await cache.readMetadata(
      'last_applied_event_cursor',
    );
    realtimeDiagnostics.lastCatchUpCursor = await cache.readMetadata(
      'last_catch_up_cursor',
    );
    realtimeDiagnostics.lastReconnectReason = await cache.readMetadata(
      'last_reconnect_reason',
    );
    realtimeDiagnostics.lastEventAt = _dateFromMetadata(
      await cache.readMetadata('last_event_at'),
    );
    realtimeDiagnostics.lastReconnectAt = _dateFromMetadata(
      await cache.readMetadata('last_reconnect_at'),
    );
    realtimeDiagnostics.lastCatchUpResultCount =
        int.tryParse(
          await cache.readMetadata('last_catch_up_result_count') ?? '',
        ) ??
        0;
    realtimeDiagnostics.eventsPatchedDirectly =
        int.tryParse(
          await cache.readMetadata('events_patched_directly') ?? '',
        ) ??
        0;
    realtimeDiagnostics.eventsForcedReload =
        int.tryParse(await cache.readMetadata('events_forced_reload') ?? '') ??
        0;
    realtimeDiagnostics.chatListEventReloads =
        int.tryParse(
          await cache.readMetadata('chat_list_event_reloads') ?? '',
        ) ??
        0;
    realtimeDiagnostics.droppedMissingChatGuid =
        int.tryParse(
          await cache.readMetadata('dropped_missing_chat_guid') ?? '',
        ) ??
        0;
    realtimeDiagnostics.droppedMalformedEvents =
        int.tryParse(
          await cache.readMetadata('dropped_malformed_events') ?? '',
        ) ??
        0;
    realtimeDiagnostics.localDbWrites =
        int.tryParse(
          await cache.readMetadata('realtime_local_db_writes') ?? '',
        ) ??
        0;
    realtimeDiagnostics.reconnectCount =
        int.tryParse(await cache.readMetadata('reconnect_count') ?? '') ?? 0;
  }

  DateTime? _dateFromMetadata(String? raw) {
    final millis = int.tryParse(raw ?? '');
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  bool _shouldAdvanceCursor(String? previous, String next) {
    if (previous == null || previous.isEmpty) return true;
    final prevNum = _numericCursor(previous);
    final nextNum = _numericCursor(next);
    if (prevNum != null && nextNum != null) return nextNum > prevNum;
    if (prevNum != null && nextNum == null) return false;
    return previous != next;
  }

  int? _numericCursor(String cursor) {
    if (!cursor.startsWith('n:')) return null;
    return int.tryParse(cursor.substring(2));
  }

  /// Per-chat initial backfill (C10 Part F). Fetches the visible chat list, then
  /// the latest [perChat] renderable messages for each chat, writing everything
  /// to the local DB. Uses a client built from [profile] (which may not be the
  /// active profile yet, e.g. during onboarding). Reports human progress via
  /// [onProgress] and returns counts. Never throws — partial results are kept.
  Future<BackfillDiagnostics> backfill(
    ConnectionProfile profile, {
    int perChat = 100,
    void Function(String message)? onProgress,
  }) async {
    final client = buildProbeClient(profile);
    final diag = BackfillDiagnostics();
    try {
      await cache.open();
      // Ensure realtime catch-up first so the relay has fresh rows to serve.
      try {
        await client.syncNow();
      } catch (_) {
        /* opportunistic */
      }

      onProgress?.call('Fetching chats…');
      final chats = await client.getChats();
      await cache.upsertChats(chats);
      diag.chatsFetched = chats.length;
      diag.chatsWritten = chats.length;

      var i = 0;
      for (final chat in chats) {
        i++;
        onProgress?.call('Syncing chat $i of ${chats.length}…');
        try {
          final msgs = await client.getMessages(chat.guid, limit: perChat);
          await cache.replaceServerPage(chat.guid, msgs);
          diag.messagesFetched += msgs.length;
          diag.messagesWritten += msgs.where((m) => !m.isDebugOnly).length;
          diag.hiddenDebugRowsIgnored += msgs
              .where((m) => m.isDebugOnly)
              .length;
          diag.attachmentsMetadataWritten += msgs.fold<int>(
            0,
            (sum, m) => sum + m.attachments.length,
          );
        } catch (error) {
          diag.failedChats++;
          diag.lastError = error.toString();
        }
      }
      await cache.writeMetadata(
        'last_bootstrap_time',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      await cache.writeMetadata(
        'last_write_count',
        (diag.chatsWritten + diag.messagesWritten).toString(),
      );
      await cache.writeMetadata(
        'last_attachment_metadata_count',
        diag.attachmentsMetadataWritten.toString(),
      );
      await cache.writeMetadata('last_error', diag.lastError ?? '');
      onProgress?.call('Sync complete (${diag.messagesFetched} messages).');
      if (diag.failedChats > 0) {
        throw StateError(
          'Initial DB bootstrap partially failed: ${diag.failedChats} chats failed.',
        );
      }
    } catch (error) {
      diag.lastError = error.toString();
      await cache.writeMetadata('last_error', diag.lastError!);
      rethrow;
    } finally {
      client.close();
    }
    return diag;
  }

  /// Clears the saved profile and tears down clients.
  Future<void> signOut() async {
    ws.disconnect();
    await store.clearProfile();
    await cache.clearAll();
    _api?.close();
    _api = null;
    _profile = null;
    _serverUrls = null;
    notifyListeners();
  }

  void _rebuildApi() {
    _api?.close();
    final profile = _profile;
    _api = profile != null && profile.isComplete
        ? ApiClient(baseUrl: profile.effectiveBaseUrl, token: profile.token)
        : null;
  }

  @override
  void dispose() {
    ws.removeListener(_onWebSocketStatusChanged);
    ws.dispose();
    _api?.close();
    unawaited(cache.close());
    super.dispose();
  }
}
