import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import 'pairing_payload.dart';

enum PairingStage { scanning, preview, testing, success, failure }

/// Drives the QR pairing flow: parse a scanned code, preview it, then (on
/// confirmation) save the profile and run a health + auth test before handing
/// off to Home. The token is held only inside the parsed payload and is never
/// logged.
class PairingController extends ChangeNotifier {
  final AppController app;

  PairingController(this.app);

  PairingStage stage = PairingStage.scanning;
  PairingPayload? payload;
  String? message;

  /// Handles a raw scanned string. On success moves to [PairingStage.preview];
  /// on a parse error stays scanning and surfaces [message] (transiently).
  void onScan(String raw) {
    if (stage != PairingStage.scanning) return;
    try {
      payload = parsePairingPayload(raw);
      message = null;
      stage = PairingStage.preview;
    } on PairingParseException catch (e) {
      payload = null;
      message = e.message;
      // Stay in scanning so the user can try another code.
    }
    notifyListeners();
  }

  /// Returns to scanning from the preview/error state.
  void scanAgain() {
    stage = PairingStage.scanning;
    payload = null;
    message = null;
    notifyListeners();
  }

  /// Saves the previewed profile and runs a connectivity + auth test.
  Future<bool> useScanned() async {
    final p = payload;
    if (p == null) return false;

    stage = PairingStage.testing;
    message = null;
    notifyListeners();

    final profile = p.toProfile();
    final probe = app.buildProbeClient(profile);
    try {
      await probe.health();
      await probe.authCheck();
      await app.saveAndActivate(profile);
      stage = PairingStage.success;
      message = 'Paired. Server reachable and token accepted.';
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      stage = PairingStage.failure;
      message = e.friendly;
      notifyListeners();
      return false;
    } finally {
      probe.close();
    }
  }
}
