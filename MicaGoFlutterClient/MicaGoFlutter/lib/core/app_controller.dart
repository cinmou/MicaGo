import 'package:flutter/foundation.dart';

import 'models/connection_profile.dart';
import 'models/server_urls.dart';
import 'network/api_client.dart';
import 'network/websocket_client.dart';
import 'storage/secure_store.dart';

/// App-wide state: the active connection profile, the REST client built from
/// it, the realtime WebSocket client, and the last-fetched server endpoints.
///
/// Exposed via `provider` and used as the router's refresh listenable so route
/// guards re-evaluate when the profile is saved or cleared.
class AppController extends ChangeNotifier {
  final SecureStore store;

  /// The realtime client is long-lived; home screen listens to it directly.
  final WebSocketClient ws = WebSocketClient();

  ConnectionProfile? _profile;
  ApiClient? _api;
  ServerUrls? _serverUrls;
  bool _bootstrapped = false;

  AppController({required this.store});

  ConnectionProfile? get profile => _profile;
  ApiClient? get api => _api;
  ServerUrls? get serverUrls => _serverUrls;
  bool get hasProfile => _profile?.isComplete ?? false;
  bool get bootstrapped => _bootstrapped;

  /// Loads any persisted profile at startup.
  Future<void> bootstrap() async {
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
  }

  /// Fetches `GET /api/server/urls` using the active client.
  Future<void> refreshServerUrls() async {
    final api = _api;
    if (api == null) return;
    _serverUrls = await api.getServerUrls();
    notifyListeners();
  }

  /// Opens the realtime WebSocket using the active profile.
  void connectWebSocket() {
    final profile = _profile;
    if (profile == null) return;
    ws.connect(profile.effectiveWsUrl, profile.token);
  }

  /// Clears the saved profile and tears down clients.
  Future<void> signOut() async {
    ws.disconnect();
    await store.clearProfile();
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
        ? ApiClient(baseUrl: profile.baseUrl, token: profile.token)
        : null;
  }

  @override
  void dispose() {
    ws.dispose();
    _api?.close();
    super.dispose();
  }
}
