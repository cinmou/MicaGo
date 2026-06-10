import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models/connection_profile.dart';
import 'models/server_urls.dart';
import 'network/api_client.dart';
import 'network/websocket_client.dart';
import 'storage/local_cache_store.dart';
import 'storage/secure_store.dart';

/// Counts from a per-chat initial backfill (C10 Part F diagnostics).
class BackfillDiagnostics {
  int chatsScanned = 0;
  int messagesFetched = 0;
  int renderableRows = 0;
  int failedChats = 0;

  int get hiddenOrDebugRows => messagesFetched - renderableRows;

  @override
  String toString() =>
      'chats=$chatsScanned messages=$messagesFetched renderable=$renderableRows '
      'hidden=$hiddenOrDebugRows failed=$failedChats';
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

  AppController({required this.store}) {
    ws.addListener(_onWebSocketStatusChanged);
  }

  ConnectionProfile? get profile => _profile;
  ApiClient? get api => _api;
  ServerUrls? get serverUrls => _serverUrls;
  bool get hasProfile => _profile?.isComplete ?? false;
  bool get bootstrapped => _bootstrapped;
  DateTime? get lastCatchUpSyncAt => _lastCatchUpSyncAt;

  /// Loads any persisted profile at startup.
  Future<void> bootstrap() async {
    await cache.open();
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
      await api.syncNow();
      _lastCatchUpSyncAt = DateTime.now();
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
      unawaited(catchUp(reason: 'websocket'));
    }
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
      // Ensure realtime catch-up first so the relay has fresh rows to serve.
      try {
        await client.syncNow();
      } catch (_) {/* opportunistic */}

      onProgress?.call('Fetching chats…');
      final chats = await client.getChats();
      await cache.upsertChats(chats);
      diag.chatsScanned = chats.length;

      var i = 0;
      for (final chat in chats) {
        i++;
        onProgress?.call('Syncing chat $i of ${chats.length}…');
        try {
          final msgs = await client.getMessages(chat.guid, limit: perChat);
          await cache.replaceServerPage(chat.guid, msgs);
          diag.messagesFetched += msgs.length;
          diag.renderableRows +=
              msgs.where((m) => !(m.isDebugOnly)).length;
        } catch (_) {
          diag.failedChats++;
        }
      }
      onProgress?.call('Sync complete (${diag.messagesFetched} messages).');
    } catch (_) {
      // Chat-list failure: keep whatever we have; onboarding still proceeds.
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
