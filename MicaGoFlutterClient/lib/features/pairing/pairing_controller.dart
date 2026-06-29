import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/models/connection_profile.dart';
import '../../core/network/api_client.dart';
import 'onboarding_controller.dart';
import 'pairing_payload.dart';

enum PairingStage { scanning, preview, testing, success, failure }

/// Drives the QR pairing + onboarding flow: parse a scanned code, preview it,
/// let the user pick a connection mode (when the payload offers more than one),
/// then test endpoints in policy order (LAN first, Public fallback), activate
/// the connection, and run the initial per-chat backfill. The token lives only
/// inside the parsed payload and is never logged.
class PairingController extends ChangeNotifier {
  final AppController app;

  PairingController(this.app);

  PairingStage stage = PairingStage.scanning;
  PairingPayload? payload;
  String? message;

  /// C23: there is no user-facing mode anymore. The unified payload always tries
  /// LAN first, then Public as an optional fallback.
  ConnectionMode get effectiveMode => payload?.mode ?? ConnectionMode.lanFirst;

  void onScan(String raw) {
    if (stage != PairingStage.scanning) return;
    try {
      payload = parsePairingPayload(raw);
      message = null;
      stage = PairingStage.preview;
    } on PairingParseException catch (e) {
      payload = null;
      message = e.message;
    }
    notifyListeners();
  }

  void scanAgain() {
    stage = PairingStage.scanning;
    payload = null;
    message = null;
    notifyListeners();
  }

  /// Tests endpoints, activates the connection, and warms the local cache.
  Future<bool> useScanned() async {
    final p = payload;
    if (p == null) return false;

    stage = PairingStage.testing;
    message = 'Testing connection…';
    notifyListeners();

    final onboarding = OnboardingController(
      prober: (endpoint, token) async {
        final probe = app.buildProbeClient(
          ConnectionProfile(baseUrl: endpoint.baseUrl, token: token),
        );
        try {
          await probe.health();
          await probe.authCheck();
          return true;
        } on ApiException {
          return false;
        } finally {
          probe.close();
        }
      },
      runInitialSync: (profile, onProgress) =>
          app.backfill(profile, onProgress: onProgress),
    );

    onboarding.addListener(() {
      message = onboarding.status.message;
      notifyListeners();
    });

    final profile = await onboarding.run(p, effectiveMode);
    if (profile == null) {
      stage = PairingStage.failure;
      message = onboarding.status.message;
      notifyListeners();
      return false;
    }

    await app.saveAndActivate(profile);
    stage = PairingStage.success;
    final active = onboarding.activeEndpoint;
    message = active?.kind == EndpointKind.public
        ? 'Paired via Public. ${onboarding.status.message}'
        : 'Paired via LAN. ${onboarding.status.message}';
    notifyListeners();
    return true;
  }
}
