import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/models/connection_profile.dart';
import '../../core/models/server_urls.dart';
import '../../core/network/api_client.dart';

enum TestState { idle, testing, success, failure }

/// Drives the connection-setup form: runs a non-persisting connectivity test
/// (`GET /api/health` → `POST /api/auth/check`) and persists the profile.
class ConnectionController extends ChangeNotifier {
  final AppController app;

  ConnectionController(this.app);

  TestState state = TestState.idle;
  String? message;
  ServerUrls? urlsPreview;

  /// Runs a connectivity + auth test against [profile] without saving it.
  Future<void> test(ConnectionProfile profile) async {
    state = TestState.testing;
    message = null;
    urlsPreview = null;
    notifyListeners();

    final probe = app.buildProbeClient(profile);
    try {
      await probe.health();
      await probe.authCheck();
      // Best-effort: fetch endpoints to preview (non-fatal if it fails).
      try {
        urlsPreview = await probe.getServerUrls();
      } on ApiException {
        urlsPreview = null;
      }
      state = TestState.success;
      message = 'Connected. Server is reachable and the token was accepted.';
    } on ApiException catch (e) {
      state = TestState.failure;
      message = e.friendly;
    } finally {
      probe.close();
      notifyListeners();
    }
  }

  /// Persists and activates [profile].
  Future<void> save(ConnectionProfile profile) => app.saveAndActivate(profile);

  void reset() {
    state = TestState.idle;
    message = null;
    urlsPreview = null;
    notifyListeners();
  }
}
