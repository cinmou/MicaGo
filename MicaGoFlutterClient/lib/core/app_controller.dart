import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models/connection_profile.dart';
import 'models/server_urls.dart';
import 'network/api_client.dart';
import 'network/connection_candidate.dart';
import 'network/connection_notice.dart';
import 'network/endpoint_utils.dart';
import 'network/device_identity.dart';
import 'network/push_logic.dart';
import 'network/refresh_coordinator.dart';
import 'network/websocket_client.dart';
import 'storage/local_cache_store.dart';
import 'storage/secure_store.dart';
import '../features/chats/models/message_model.dart';
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

  /// C19: one-shot connection notices for the UI (banner/snackbar). Emits only
  /// on real transitions, de-duplicated, so there are no noisy repeated alerts.
  final ValueNotifier<ConnectionNotice?> connectionNotice =
      ValueNotifier<ConnectionNotice?>(null);

  /// C26: whether the realtime connection is currently healthy (WS connected).
  /// The notice host clears any sticky "Reconnecting…"/offline banner the moment
  /// this flips true, so a recovered connection never leaves a stale problem
  /// banner on screen — independent of whether the one-shot derivation happened
  /// to emit a transition for the connecting→connected edge.
  final ValueNotifier<bool> connectionHealthy = ValueNotifier<bool>(false);
  ConnectionSnapshot? _lastConnectionSnapshot;
  bool _serverReachable = false;
  bool _hasCompletedFirstConnectAttempt = false;
  bool _hasEverConnected = false;
  DateTime? _connectionNoticeGraceUntil;
  DateTime _startupConnectionNoticeQuietUntil = DateTime.now().add(
    const Duration(seconds: 10),
  );
  bool _hasSuppressedStartupConnectionNotice = false;

  /// C20: the server's authoritative sync settings (incl. allowSmsSend),
  /// fetched on connect. The composer reads [allowSmsSend] from here — the
  /// client never guesses SMS sendability.
  Map<String, dynamic>? _syncSettings;
  bool get allowSmsSend => _syncSettings?['allowSmsSend'] == true;
  Map<String, dynamic>? get syncSettings => _syncSettings;

  ConnectionProfile? _profile;
  ApiClient? _api;
  ServerUrls? _serverUrls;
  ConnectionCandidate? _activeCandidate;
  final List<String> _connectionLog = <String>[];
  bool _bootstrapped = false;
  DateTime? _lastCatchUpSyncAt;
  bool _catchUpInFlight = false;
  bool _realtimeCatchingUp = false;
  final RealtimeRefreshDiagnostics realtimeDiagnostics =
      RealtimeRefreshDiagnostics();

  /// C20: owns the fallback refresh tier (reconnect backoff + poll while the
  /// socket is down). Realtime + targeted refresh stay in the controllers.
  late final RefreshCoordinator _refresh = RefreshCoordinator(
    reconnect: () => selectReachableCandidate(reason: 'reconnect'),
    catchUp: (reason) => catchUp(reason: reason, minInterval: Duration.zero),
    wsStatus: () => ws.status,
  );

  AppController({required this.store}) {
    ws.addListener(_onWebSocketStatusChanged);
    // C23: when the server's connection settings change it pushes
    // connection:updated — refresh our candidates so we follow the new LAN/
    // Public URLs without the user rescanning a QR.
    _connSub = ws.events.listen((e) {
      if (e.type == 'connection:updated') {
        unawaited(refreshServerUrls());
      } else if (e.type == 'message:new') {
        // C31: keep-alive local-notification path (no Firebase required).
        unawaited(_maybeNotifyBackgroundMessage(e));
      }
    });
  }

  StreamSubscription<WsEvent>? _connSub;

  // C31: whether the app is currently foregrounded. Drives notification dedup —
  // a realtime message that arrives while foregrounded is shown by the UI, not as
  // a system notification. The app shell updates this from lifecycle events.
  bool _foreground = true;
  bool get isForeground => _foreground;
  void setForeground(bool value) => _foreground = value;

  /// Called by the app shell on foreground resume (lightweight refresh).
  void onResume() {
    if (hasProfile && ws.status != WsStatus.connected) {
      _connectionNoticeGraceUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _startupConnectionNoticeQuietUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _hasSuppressedStartupConnectionNotice = false;
    }
    _refresh.onResume();
  }

  ConnectionProfile? get profile => _profile;
  ApiClient? get api => _api;
  ServerUrls? get serverUrls => _serverUrls;
  ConnectionCandidate? get activeCandidate => _activeCandidate;
  List<ConnectionCandidate> get connectionCandidates =>
      _profile == null ? const [] : connectionCandidatesForProfile(_profile!);
  List<String> get connectionLog => List.unmodifiable(_connectionLog);
  bool get hasProfile => _profile?.isComplete ?? false;
  bool get bootstrapped => _bootstrapped;
  DateTime? get lastCatchUpSyncAt => _lastCatchUpSyncAt;
  bool get realtimeCatchingUp => _realtimeCatchingUp;

  /// Loads any persisted profile at startup.
  Future<void> bootstrap() async {
    await cache.open();
    await _loadRealtimeDiagnostics();
    _profile = await store.loadProfile();
    if (_profile != null) {
      _activeCandidate = connectionCandidatesForProfile(_profile!).firstOrNull;
      _hasCompletedFirstConnectAttempt = false;
      _connectionNoticeGraceUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _startupConnectionNoticeQuietUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _hasSuppressedStartupConnectionNotice = false;
      _logConnectionSelection('bootstrap profile mode=${_profile!.mode.name}');
      _logConnectionSelection(
        'candidates: ${connectionCandidates.join(' | ')}',
      );
    }
    _rebuildApi();
    // C29: restore the keep-alive setting (and re-arm the service if it was on).
    await _loadKeepAlive();
    _bootstrapped = true;
    notifyListeners();
  }

  /// Builds a throwaway [ApiClient] for the connection-test screen without
  /// persisting anything.
  ApiClient buildProbeClient(ConnectionProfile profile) {
    final candidate = connectionCandidatesForProfile(profile).firstOrNull;
    return ApiClient(
      baseUrl: candidate?.baseUrl ?? profile.effectiveBaseUrl,
      token: profile.token,
    );
  }

  /// Persists [profile] and activates it as the live connection.
  Future<void> saveAndActivate(ConnectionProfile profile) async {
    await store.saveProfile(profile);
    _profile = profile;
    _serverUrls = null;
    _activeCandidate = null;
    _hasCompletedFirstConnectAttempt = false;
    _connectionNoticeGraceUntil = DateTime.now().add(
      const Duration(seconds: 10),
    );
    _startupConnectionNoticeQuietUntil = DateTime.now().add(
      const Duration(seconds: 10),
    );
    _hasSuppressedStartupConnectionNotice = false;
    _logConnectionSelection('save profile mode=${profile.mode.name}');
    _logConnectionSelection(
      'candidates: ${connectionCandidatesForProfile(profile).join(' | ')}',
    );
    _rebuildApi();
    // C29b: pairing is a user-visible connect — arm the 10s cannot-connect error.
    _armInitialConnectWatchdog();
    notifyListeners();
    unawaited(selectReachableCandidate(reason: 'profile'));
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
    // C23: skip the rebuild churn when the server's connection config is
    // unchanged (same revision) and we already have candidates stored.
    if (urls.connectionRevision.isNotEmpty &&
        urls.connectionRevision == profile.configRevision &&
        (profile.lanRoutes.isNotEmpty || profile.publicBaseUrl != null)) {
      return;
    }
    // C26: keep EVERY advertised LAN route, not just the first interface, so the
    // user can switch between them.
    final lanRoutes = [
      for (final e in urls.lan)
        if (e.baseUrl.trim().isNotEmpty)
          EndpointRef(baseUrl: e.baseUrl, wsUrl: e.wsUrl),
    ];
    final pub = urls.public?.enabled == true ? urls.public : null;
    // C26: a manual route pin must survive refresh. Keep the selection if its
    // URL still exists in the new candidate set; otherwise drop it (auto).
    final usableUrls = {
      for (final r in lanRoutes) r.baseUrl,
      if (pub != null) pub.baseUrl,
    };
    final keptSelection =
        (profile.selectedBaseUrl != null &&
            usableUrls.contains(profile.selectedBaseUrl))
        ? profile.selectedBaseUrl
        : null;
    final next = ConnectionProfile(
      baseUrl: profile.baseUrl,
      token: profile.token,
      wsUrlOverride: profile.wsUrlOverride,
      lanRoutes: lanRoutes.isNotEmpty ? lanRoutes : null,
      selectedBaseUrl: keptSelection,
      publicBaseUrl: pub?.baseUrl,
      publicWsUrl: pub?.wsUrl,
      mode: profile.mode,
      configRevision: urls.connectionRevision,
    );
    _profile = next;
    // Keep the active candidate if it still exists; only reset when it's gone so
    // the displayed/used endpoint doesn't silently jump on a routine refresh.
    final active = _activeCandidate;
    if (active != null && !usableUrls.contains(active.baseUrl)) {
      _activeCandidate = null;
    }
    await store.saveProfile(next);
    _rebuildApi();
  }

  /// C26: pin a specific candidate (LAN interface or Public) as the route to use,
  /// persist it, and immediately reconnect through it. Passing null clears the
  /// pin and returns to automatic LAN-first selection.
  Future<void> selectRoute(String? baseUrl) async {
    final profile = _profile;
    if (profile == null) return;
    final normalized = baseUrl == null || baseUrl.trim().isEmpty
        ? null
        : normalizeBaseUrl(baseUrl);
    final next = profile.copyWith(selectedBaseUrl: normalized);
    _profile = next;
    _activeCandidate = null;
    await store.saveProfile(next);
    _rebuildApi();
    _logConnectionSelection('manual route selected: ${normalized ?? 'auto'}');
    notifyListeners();
    await selectReachableCandidate(reason: 'manual-route');
  }

  /// Opens the realtime WebSocket using the active profile.
  void connectWebSocket() {
    final profile = _profile;
    if (profile == null) return;
    final candidate =
        _activeCandidate ?? connectionCandidatesForProfile(profile).firstOrNull;
    if (candidate == null) return;
    _activeCandidate = candidate;
    _logConnectionSelection(
      'WS connect ${candidate.label}: ${candidate.wsUrl}',
    );
    ws.connect(candidate.wsUrl, profile.token);
  }

  /// Foreground startup/resume entry point: test candidates first, then connect.
  /// During the first attempt we suppress scary offline banners unless the attempt
  /// actually fails.
  Future<bool> connectForeground({required String reason}) {
    if (hasProfile && ws.status != WsStatus.connected) {
      _connectionNoticeGraceUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _startupConnectionNoticeQuietUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _hasSuppressedStartupConnectionNotice = false;
      // C29b: this is a user-visible connect attempt — arm the 10s watchdog so
      // the user gets a clear "can't reach the server" error instead of being
      // stuck on "Reconnecting…" forever.
      _armInitialConnectWatchdog();
    }
    return selectReachableCandidate(reason: reason);
  }

  /// C29b: surfaces a clear, user-visible error when the INITIAL connection
  /// attempt (startup or just after pairing) can't reach any server candidate
  /// within 10s. Cleared the moment a connection succeeds. Background reconnects
  /// never arm this, so it can't spam.
  final ValueNotifier<bool> initialConnectFailed = ValueNotifier<bool>(false);
  Timer? _initialConnectWatchdog;

  void _armInitialConnectWatchdog() {
    _initialConnectWatchdog?.cancel();
    initialConnectFailed.value = false;
    if (ws.status == WsStatus.connected || _serverReachable) return;
    _initialConnectWatchdog = Timer(const Duration(seconds: 10), () {
      if (ws.status != WsStatus.connected && !_serverReachable) {
        _logConnectionSelection('initial connect watchdog: no server in 10s');
        initialConnectFailed.value = true;
      }
    });
  }

  void _clearInitialConnectWatchdog() {
    _initialConnectWatchdog?.cancel();
    _initialConnectWatchdog = null;
    if (initialConnectFailed.value) initialConnectFailed.value = false;
  }

  /// Manual retry from the cannot-connect dialog.
  Future<bool> retryInitialConnect() => connectForeground(reason: 'retry');

  Future<bool> selectReachableCandidate({
    required String reason,
    ConnectionCandidateKind? skipKind,
  }) async {
    final profile = _profile;
    if (profile == null) return false;
    final allCandidates = connectionCandidatesForProfile(profile);
    final candidates = allCandidates
        .where((c) => c.kind != skipKind)
        .toList(growable: false);
    _logConnectionSelection(
      'select candidate reason=$reason mode=${profile.mode.name}',
    );
    _logConnectionSelection('all candidates: ${allCandidates.join(' | ')}');
    if (skipKind != null) {
      _logConnectionSelection('trying candidates: ${candidates.join(' | ')}');
    }
    for (final candidate in candidates) {
      _logConnectionSelection(
        'checking ${candidate.label}: ${candidate.baseUrl}',
      );
      final client = ApiClient(
        baseUrl: candidate.baseUrl,
        token: profile.token,
      );
      try {
        final healthy = await client.health();
        if (healthy) {
          await client.authCheck();
          _activeCandidate = candidate;
          _serverReachable = true;
          _hasCompletedFirstConnectAttempt = true;
          _connectionNoticeGraceUntil = null;
          _logConnectionSelection('${candidate.label} health=true auth=true');
          _logConnectionSelection('selected ${candidate.label}');
          _rebuildApi();
          // C29b: reached the server → clear any pending cannot-connect error.
          _clearInitialConnectWatchdog();
          // C29: register this device as soon as the server is reachable over
          // REST — not only when the WebSocket connects. A flaky/slow WS must not
          // keep a working device out of the Companion's Paired Devices list.
          unawaited(_registerDeviceIfPossible());
          // Surface a LAN↔Public fallback switch before the WS reconnects.
          _emitConnectionNotice();
          notifyListeners();
          connectWebSocket();
          unawaited(catchUp(reason: reason, minInterval: Duration.zero));
          return true;
        }
        _logConnectionSelection('${candidate.label} health=false');
      } catch (error) {
        _logConnectionSelection('${candidate.label} failed: $error');
      } finally {
        client.close();
      }
    }
    _logConnectionSelection('no reachable candidate');
    _serverReachable = false;
    _hasCompletedFirstConnectAttempt = true;
    _connectionNoticeGraceUntil = null;
    _emitConnectionNotice();
    notifyListeners();
    return false;
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
      // C21: after the server relay refresh, pull any messages we missed via the
      // delta cursor — the correctness path that guarantees nothing is lost while
      // disconnected/backgrounded, independent of WebSocket events.
      await runDeltaSync(reason: reason);
    } catch (_) {
      // Foreground catch-up is opportunistic; normal REST loads still surface
      // actionable errors in the views that requested data.
    } finally {
      _catchUpInFlight = false;
    }
  }

  // --- C21 delta cursor sync (correctness path) --------------------------------

  int? _syncCursor; // persistent; -1/null seeds to "now" on first run
  bool _deltaInFlight = false;
  final StreamController<MessageModel> _deltaController =
      StreamController<MessageModel>.broadcast();

  /// Messages applied by the delta catch-up. Thread/chat-list controllers
  /// subscribe and patch their state (GUID dedup prevents duplicate bubbles).
  Stream<MessageModel> get deltaMessages => _deltaController.stream;

  /// Fetches everything newer than the persisted cursor and applies it to the
  /// cache + open views, paging until caught up. Idempotent and safe to call on
  /// reconnect, resume, startup, and the fallback poll.
  Future<void> runDeltaSync({required String reason}) async {
    final api = _api;
    if (api == null || _deltaInFlight) return;
    _deltaInFlight = true;
    try {
      _syncCursor ??= int.tryParse(
        await cache.readMetadata('sync_cursor') ?? '',
      );
      var guard = 0;
      while (guard++ < 20) {
        final delta = await api.fetchDelta(since: _syncCursor);
        for (final msg in delta.messages) {
          final chatGuid = msg.chatGuid;
          if (chatGuid != null && chatGuid.isNotEmpty) {
            await cache.upsertMessage(chatGuid, msg);
          }
          _deltaController.add(msg);
        }
        final advanced = delta.cursor != _syncCursor;
        _syncCursor = delta.cursor;
        await cache.writeMetadata('sync_cursor', '${delta.cursor}');
        if (delta.messages.isNotEmpty) notifyListeners();
        if (!delta.hasMore) break;
        if (!advanced) break; // safety: never loop on a non-advancing cursor
      }
    } catch (_) {
      // Opportunistic; the next trigger retries.
    } finally {
      _deltaInFlight = false;
    }
  }

  /// Recomputes the connection snapshot and surfaces a one-shot notice on a
  /// real transition (C19). Called whenever WS status or the active endpoint /
  /// reachability changes. De-duplicates by only emitting on a non-null
  /// transition result; the UI clears [connectionNotice] after showing it.
  void _emitConnectionNotice() {
    final current = ConnectionSnapshot(
      ws: ws.status,
      activeKind: _activeCandidate?.kind,
      serverReachable: _serverReachable || ws.status == WsStatus.connected,
    );
    final notice = connectionNoticeFor(_lastConnectionSnapshot, current);
    _lastConnectionSnapshot = current;
    // Keep the healthy flag in lock-step with the live snapshot so the notice
    // host can clear a stale "Reconnecting…" banner the instant we reconnect,
    // even on the connecting→connected edge (which the one-shot derivation
    // intentionally reports as null to stay quiet).
    connectionHealthy.value =
        current.ws == WsStatus.connected && current.serverReachable;
    if (_shouldSuppressConnectionNotice(notice)) return;
    if (notice != null) connectionNotice.value = notice;
  }

  bool _shouldSuppressConnectionNotice(ConnectionNotice? notice) {
    if (notice == null) return false;
    if (_shouldSuppressStartupConnectionNotice(notice)) return true;
    if (!notice.isProblem) return false;
    // C26: a brief reconnect after a background→resume (or a fresh activate)
    // is expected and self-heals — don't flash "Reconnecting…" during the
    // grace window even once we've connected before. Other problems (offline,
    // dropped) still surface immediately.
    final grace = _connectionNoticeGraceUntil;
    if (notice == ConnectionNotice.reconnecting &&
        grace != null &&
        DateTime.now().isBefore(grace)) {
      return true;
    }
    if (_hasEverConnected) return false;
    if (_hasCompletedFirstConnectAttempt) return false;
    if (grace == null) return false;
    return DateTime.now().isBefore(grace);
  }

  bool _shouldSuppressStartupConnectionNotice(ConnectionNotice notice) {
    if (_hasSuppressedStartupConnectionNotice) return false;
    if (DateTime.now().isAfter(_startupConnectionNoticeQuietUntil)) {
      return false;
    }
    final isStartupNoise = switch (notice) {
      ConnectionNotice.connected ||
      ConnectionNotice.webSocketRecovered ||
      ConnectionNotice.disconnected ||
      ConnectionNotice.serverUnavailable ||
      ConnectionNotice.webSocketLost ||
      ConnectionNotice.reconnecting => true,
      ConnectionNotice.switchedToLan ||
      ConnectionNotice.switchedToPublic => false,
    };
    if (!isStartupNoise) return false;
    _hasSuppressedStartupConnectionNotice = true;
    return true;
  }

  void _onWebSocketStatusChanged() {
    if (ws.status == WsStatus.connected) {
      _serverReachable = true;
      _hasEverConnected = true;
      _hasCompletedFirstConnectAttempt = true;
      _connectionNoticeGraceUntil = null;
      _clearInitialConnectWatchdog(); // C29b: connected → clear the 10s error
    }
    // Surface a user-visible notice for any status transition (connect, lost,
    // reconnecting, disconnect). De-dup is handled in the pure derivation.
    _emitConnectionNotice();

    if (ws.status == WsStatus.connected) {
      unawaited(refreshServerUrls());
      unawaited(_handleWebSocketReconnect());
    } else if (ws.status == WsStatus.failed ||
        ws.status == WsStatus.disconnected) {
      _logConnectionSelection(
        'WS ${ws.status.name}: ${ws.lastError ?? 'closed'}',
      );
    }
    // C20: the coordinator owns all reconnect scheduling + the fallback poll —
    // covering clean disconnects and single-mode profiles, which the old
    // failed-only path missed.
    _refresh.onWsStatusChanged(ws.status);
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
    unawaited(_registerDeviceIfPossible());
    unawaited(refreshSyncSettings());
    try {
      await catchUp(reason: 'websocket', minInterval: Duration.zero);
    } finally {
      _realtimeCatchingUp = false;
      notifyListeners();
    }
  }

  /// Fetches the server's sync settings (server-authoritative SMS sendability).
  Future<void> refreshSyncSettings() async {
    final settings = await _api?.getSyncSettings();
    if (settings != null) {
      _syncSettings = settings;
      notifyListeners();
    }
  }

  /// Updates "Allow SMS sending through Mac" on the server, then refreshes the
  /// local copy. Returns true on success.
  Future<bool> setAllowSmsSend(bool value) async {
    final api = _api;
    if (api == null) return false;
    final current = _syncSettings ?? await api.getSyncSettings();
    if (current == null) return false;
    final updated = await api.putSyncSettings({
      ...current,
      'allowSmsSend': value,
    });
    if (updated == null) return false;
    _syncSettings = updated;
    notifyListeners();
    return true;
  }

  /// C19/C21u: register this client so the Companion shows a connected device.
  /// Best-effort and idempotent — sends a **stable, client-generated** device id
  /// (memoized below) on every reconnect so the server upserts the same row
  /// rather than creating duplicates. Also reports the app version, the active
  /// connection mode (LAN vs LAN+Public), and the push capability.
  bool _registerInFlight = false;
  String? _lastRegisterResult;

  /// Human-readable summary of the last device-registration attempt (for the
  /// debug diagnostics panel). Never contains the token.
  String? get lastRegisterResult => _lastRegisterResult;

  String _recordRegister(String summary) {
    _lastRegisterResult = '${DateTime.now().toIso8601String()} $summary';
    _logConnectionSelection('device register: $summary');
    notifyListeners();
    return _lastRegisterResult!;
  }

  /// Registers this device (C29c: fully instrumented + hardened). Returns a
  /// result summary; never throws and never swallows a failure silently.
  /// [force] bypasses the in-flight guard (used by the debug "Register now").
  Future<String> _registerDeviceIfPossible({bool force = false}) async {
    if (_registerInFlight && !force) {
      return _lastRegisterResult ?? 'in flight';
    }
    final profile = _profile;
    if (profile == null || profile.token.trim().isEmpty) {
      return _recordRegister('skipped: no profile or empty token');
    }
    final candidates = _registrationCandidates(profile);
    if (candidates.isEmpty) {
      return _recordRegister('skipped: no candidate base URL');
    }

    _registerInFlight = true;
    try {
      final String id;
      try {
        id = await _ensureDeviceId();
      } catch (e) {
        return _recordRegister('FAILED: could not load device id: $e');
      }
      if (id.isEmpty) {
        return _recordRegister('FAILED: empty device id');
      }
      final hasPublic = candidates.any(
        (c) => c.kind == ConnectionCandidateKind.public,
      );
      final mode = hasPublic ? 'lan_public' : 'lan';
      final background = _pushEnabled || _keepAliveEnabled;
      final body = buildDeviceRegistration(
        name: 'micaGO on ${defaultTargetPlatform.name}',
        platform: serverPlatformFor(defaultTargetPlatform, isWeb: kIsWeb),
        id: id,
        mode: mode,
        pushProvider: _pushProvider,
        pushToken: _pushToken,
        pushEnabled: _pushEnabled,
        background: background,
      );
      _logConnectionSelection(
        'device register → ${candidates.length} candidate(s) '
        'id=$id mode=$mode tokenLen=${profile.token.trim().length} '
        'provider=$_pushProvider bg=$background',
      );
      final failures = <String>[];
      for (final candidate in candidates) {
        // DEDICATED short-lived client: the shared _api can be closed by a
        // concurrent _rebuildApi() (endpoint refresh), aborting the POST. Retry
        // per endpoint, then move to the next advertised endpoint so stale LAN
        // or Public URLs do not make the Companion-managed server look empty.
        final client = ApiClient(
          baseUrl: candidate.baseUrl,
          token: profile.token,
        );
        try {
          ({String? id, int status, String? error}) result = (
            id: null,
            status: 0,
            error: 'not attempted',
          );
          for (var attempt = 1; attempt <= 2; attempt++) {
            _recordRegister(
              'attempt $attempt/2 ${candidate.label} '
              '${candidate.baseUrl}',
            );
            result = await client.registerDevice(body);
            if (result.status == 200) {
              _activeCandidate = candidate;
              _startDeviceHeartbeat(id);
              return _recordRegister(
                'OK id=$id status=200 via ${candidate.label} '
                '${candidate.baseUrl}',
              );
            }
            final failure =
                '${candidate.label} ${candidate.baseUrl} '
                        'status=${result.status} ${result.error ?? ''}'
                    .trim();
            failures.add(failure);
            _recordRegister('FAILED $failure');
            if (attempt < 2 && result.status == 0) {
              await Future<void>.delayed(const Duration(seconds: 1));
            } else {
              break;
            }
          }
        } finally {
          client.close();
        }
      }
      return _recordRegister('FAILED all endpoints: ${failures.join(' | ')}');
    } finally {
      _registerInFlight = false;
    }
  }

  List<ConnectionCandidate> _registrationCandidates(ConnectionProfile profile) {
    final out = <ConnectionCandidate>[];
    final active = _activeCandidate;
    if (active != null && active.baseUrl.trim().isNotEmpty) out.add(active);
    out.addAll(connectionCandidates);
    out.addAll(connectionCandidatesForProfile(profile));
    final seen = <String>{};
    return [
      for (final c in out)
        if (c.baseUrl.trim().isNotEmpty && seen.add(c.baseUrl)) c,
    ];
  }

  /// Debug: force a registration attempt now and return its result summary.
  Future<String> registerDeviceNow() => _registerDeviceIfPossible(force: true);

  /// Debug: a redacted connection/registration diagnostics snapshot.
  Future<String> connectionDiagnostics() async {
    final profile = _profile;
    String deviceId = '(unavailable)';
    try {
      deviceId = await _ensureDeviceId();
    } catch (_) {}
    return [
      'profile: ${profile == null ? "none" : "set"}',
      'token: ${(profile?.token.trim().isNotEmpty ?? false) ? "present (${profile!.token.trim().length} chars)" : "MISSING"}',
      'deviceId: $deviceId',
      'activeBaseUrl: ${_activeCandidate?.baseUrl ?? "(none)"}',
      'apiBaseUrl: ${_api?.baseUrl ?? "(none)"}',
      'ws: ${ws.status.name}',
      'serverReachable: $_serverReachable',
      'candidates: ${connectionCandidates.map((c) => c.baseUrl).join(", ")}',
      'pushProvider: $_pushProvider  pushEnabled: $_pushEnabled  keepAlive: $_keepAliveEnabled',
      'lastRegister: ${_lastRegisterResult ?? "(never attempted)"}',
    ].join('\n');
  }

  // C22: push capability reported on registration, set by PushService once it
  // has (or loses) an FCM token. Defaults to "no push" so a missing/optional
  // Firebase config simply keeps WebSocket + delta sync as the only paths.
  String _pushProvider = 'none';
  String? _pushToken;
  bool _pushEnabled = false;

  // C31 notification wiring (set during app composition / by PushService).
  // Both are optional: when unset the corresponding behavior simply no-ops.

  /// Resolves a raw handle to an on-device contact name (set from ContactsService
  /// in the app composition root). Used to title local notifications with a real
  /// name rather than a bare phone/email handle.
  String? Function(String? handle)? contactNameResolver;

  /// Shows a local message notification through the shared, already-initialized
  /// notifications plugin (set by [PushService] once local notifications are up,
  /// independent of Firebase). The keep-alive path calls this.
  Future<void> Function({
    required String title,
    String? body,
    required String? chatGuid,
    required String? messageGuid,
  })?
  showLocalNotification;

  // The server's notification preview mode governs how much a local notification
  // shows. We default to the common "sender + text" layout; `none`/`sender` hide
  // the text. (The FCM path is gated server-side; this keeps the local path in
  // step for the default.)
  final String _notificationPreview = 'sender_and_text';

  // C31 diagnostics -----------------------------------------------------------
  String? _notificationPermission; // 'granted' | 'denied' | null = unknown
  String? get notificationPermission => _notificationPermission;
  void noteNotificationPermission(bool? granted) {
    final v = granted == null ? null : (granted ? 'granted' : 'denied');
    if (_notificationPermission == v) return;
    _notificationPermission = v;
    notifyListeners();
  }

  String? _lastNotificationSource; // timestamped 'FCM' | 'keep-alive'
  String? get lastNotificationSource => _lastNotificationSource;
  void noteNotificationSource(String source) {
    _lastNotificationSource = '${DateTime.now().toIso8601String()} $source';
    notifyListeners();
  }

  String? _lastReplyResult; // timestamped direct-reply outcome
  String? get lastReplyResult => _lastReplyResult;
  void noteReplyResult(String result) {
    _lastReplyResult = '${DateTime.now().toIso8601String()} $result';
    notifyListeners();
  }

  /// C31: when the app is backgrounded and the keep-alive service is holding the
  /// socket open (no Firebase needed), turn an incoming realtime message into a
  /// local notification — same formatting, contact-name resolution, tap routing
  /// and direct-reply action as the FCM path. Foreground messages are shown by
  /// the UI, so this no-ops; the shared notification id dedupes against any FCM
  /// notification for the same message (only one is shown).
  Future<void> _maybeNotifyBackgroundMessage(WsEvent e) async {
    if (_foreground || !_keepAliveEnabled) return;
    final show = showLocalNotification;
    if (show == null) return; // local notifications not initialized yet
    final msg = messageFromWsEvent(e);
    if (msg == null || msg.isFromMe) return;
    if (isReactionMessage(msg)) {
      return; // tapbacks shouldn't raise a notification
    }
    final chatGuid = chatGuidFromWsEvent(e);
    final contactName = contactNameResolver?.call(msg.handleId);
    final title = messageNotificationTitle(
      contactName: contactName,
      handle: msg.handleId,
    );
    final body = localNotificationBody(msg.text, _notificationPreview);
    await show(
      title: title,
      body: body,
      chatGuid: chatGuid,
      messageGuid: msg.guid,
    );
    noteNotificationSource('keep-alive');
  }

  // C29: optional Android keep-alive foreground service. Persisted; default off.
  // When on, the device reports `background: true` and a foreground service keeps
  // the WebSocket alive. Firebase is NOT required for this.
  static const MethodChannel _keepAliveChannel = MethodChannel(
    'micago/keepalive',
  );
  static const String _keepAlivePrefKey = 'micago.keepalive.v1';
  bool _keepAliveEnabled = false;
  bool get keepAliveEnabled => _keepAliveEnabled;

  /// Turn the keep-alive foreground service on/off, persist the choice, and
  /// re-register so the Companion shows the updated background status.
  Future<void> setKeepAliveEnabled(bool enabled) async {
    _keepAliveEnabled = enabled;
    await store.writeValue(_keepAlivePrefKey, enabled ? '1' : '0');
    await _applyKeepAlive(enabled);
    notifyListeners();
    unawaited(_registerDeviceIfPossible());
  }

  Future<void> _loadKeepAlive() async {
    _keepAliveEnabled = (await store.readValue(_keepAlivePrefKey)) == '1';
    if (_keepAliveEnabled) await _applyKeepAlive(true);
  }

  Future<void> _applyKeepAlive(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _keepAliveChannel.invokeMethod(enabled ? 'start' : 'stop');
    } catch (_) {
      // Platform channel unavailable (non-Android / older build) → no-op.
    }
  }

  /// Called by [PushService] when the FCM token is obtained, refreshed, or
  /// cleared. Re-registers this device so the server can wake it (C22).
  Future<void> updatePushRegistration({
    required String provider,
    required String? token,
    required bool enabled,
  }) async {
    _pushProvider = provider;
    _pushToken = token;
    _pushEnabled = enabled;
    await _registerDeviceIfPossible();
    notifyListeners();
  }

  // C27: push status surfaced to the Settings → Notifications card.
  String get pushProvider => _pushProvider;
  bool get pushEnabled => _pushEnabled;
  bool get pushConfigured => _pushEnabled && (_pushToken?.isNotEmpty ?? false);

  /// C27: ask the server to deliver a test notification to THIS device. Returns
  /// null on success, or a user-facing error message. Requires a registered push
  /// token (Firebase configured + permission granted).
  Future<String?> sendTestPush() async {
    final api = _api;
    if (api == null) return 'Not connected to the server.';
    if (!pushConfigured) {
      return 'Push is not configured on this device yet.';
    }
    try {
      final id = await _ensureDeviceId();
      await api.sendTestPush(id);
      return null;
    } on ApiException catch (e) {
      return e.friendly;
    } catch (e) {
      return 'Could not send a test notification.';
    }
  }

  /// C22: a chat GUID requested via a notification tap. The shell listens and
  /// opens the conversation (after a delta sync) when possible.
  final ValueNotifier<String?> pendingOpenChat = ValueNotifier<String?>(null);
  void requestOpenChat(String chatGuid) {
    if (chatGuid.isEmpty) return;
    pendingOpenChat.value = chatGuid;
  }

  void clearPendingOpenChat() => pendingOpenChat.value = null;

  /// Whether the realtime WebSocket is currently connected. Used by the push
  /// path to apply BlueBubbles' dedup rule: if the socket is live it already
  /// delivered the event, so the FCM wake is ignored (C22).
  bool get isRealtimeConnected => ws.status == WsStatus.connected;

  // C21u: keep this device "connected" on the server by refreshing its
  // last-seen time every 30s. When the app/network goes away the ticks stop and
  // the device naturally falls out of the server's connected window.
  Timer? _heartbeatTimer;
  void _startDeviceHeartbeat(String id) {
    _heartbeatTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_api?.deviceHeartbeat(id) ?? Future<void>.value());
    });
  }

  // The stable device id is loaded/created exactly once; the memoized Future
  // makes concurrent registrations (reconnect + resume + startup) converge on
  // the same id, so they can never race into two server rows.
  Future<String>? _deviceIdFuture;
  Future<String> _ensureDeviceId() =>
      _deviceIdFuture ??= _loadOrCreateDeviceId();

  Future<String> _loadOrCreateDeviceId() async {
    final existing = await cache.readMetadata('device_id');
    if (existing != null && existing.isNotEmpty) return existing;
    final id = generateStableDeviceId();
    await cache.writeMetadata('device_id', id);
    return id;
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
    _activeCandidate = null;
    notifyListeners();
  }

  void _rebuildApi() {
    _api?.close();
    final profile = _profile;
    final candidate = profile == null
        ? null
        : (_activeCandidate ??
              connectionCandidatesForProfile(profile).firstOrNull);
    _activeCandidate = candidate;
    _api = profile != null && candidate != null && profile.token.isNotEmpty
        ? ApiClient(baseUrl: candidate.baseUrl, token: profile.token)
        : null;
  }

  void _logConnectionSelection(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    debugPrint('[MicaGo connection] $line');
    _connectionLog.add(line);
    if (_connectionLog.length > 80) {
      _connectionLog.removeRange(0, _connectionLog.length - 80);
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _initialConnectWatchdog?.cancel();
    unawaited(_connSub?.cancel());
    _refresh.dispose();
    unawaited(_deltaController.close());
    ws.removeListener(_onWebSocketStatusChanged);
    ws.dispose();
    _api?.close();
    connectionNotice.dispose();
    connectionHealthy.dispose();
    initialConnectFailed.dispose();
    unawaited(cache.close());
    super.dispose();
  }
}

extension _FirstOrNull<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
