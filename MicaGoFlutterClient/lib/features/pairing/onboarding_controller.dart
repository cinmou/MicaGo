/// First-run onboarding state machine (C10 Part C).
///
/// Given a parsed [PairingPayload] and a chosen [ConnectionMode], it tests the
/// candidate endpoints in policy order (LAN first, Public fallback; LAN-only
/// never tries Public), then activates the connection and runs the initial
/// per-chat backfill. The endpoint probe is injected so the whole flow is
/// unit-testable without a network.
library;

import 'package:flutter/foundation.dart';

import '../../core/models/connection_profile.dart';
import 'endpoint_selection.dart';
import 'pairing_payload.dart';

enum OnboardingPhase {
  idle,
  testingLan,
  testingPublic,
  connected,
  syncing,
  done,
  failed,
}

class OnboardingStatus {
  final OnboardingPhase phase;
  final EndpointKind? activeKind;
  final String message;
  const OnboardingStatus(this.phase, this.message, {this.activeKind});
}

/// Probes one endpoint: returns true when it is reachable AND the token is
/// accepted. Injected (the real impl builds an ApiClient and calls
/// health()+authCheck()).
typedef EndpointProber =
    Future<bool> Function(PairingEndpoint endpoint, String token);

/// Runs the initial sync/backfill after a connection is active. Injected so the
/// controller stays testable. Reports progress via [onProgress].
typedef InitialSyncRunner =
    Future<void> Function(
      ConnectionProfile profile,
      void Function(String) onProgress,
    );

class OnboardingController extends ChangeNotifier {
  final EndpointProber prober;
  final InitialSyncRunner runInitialSync;

  OnboardingController({required this.prober, required this.runInitialSync});

  OnboardingStatus status = const OnboardingStatus(
    OnboardingPhase.idle,
    'Ready to connect.',
  );

  /// The active endpoint chosen during testing (null until connected).
  PairingEndpoint? activeEndpoint;

  /// The profile to persist once connected (null until connected).
  ConnectionProfile? resultProfile;

  void _set(OnboardingStatus s) {
    status = s;
    notifyListeners();
  }

  /// Tests endpoints for [payload] under [mode] and, on success, builds the
  /// profile and runs the initial sync. Returns the activated profile, or null
  /// when every endpoint failed (status becomes [OnboardingPhase.failed]).
  Future<ConnectionProfile?> run(
    PairingPayload payload,
    ConnectionMode mode,
  ) async {
    activeEndpoint = null;
    resultProfile = null;
    final order = endpointTryOrder(mode, payload.endpoints);
    if (order.isEmpty) {
      _set(
        const OnboardingStatus(
          OnboardingPhase.failed,
          'No endpoints to try for this mode.',
        ),
      );
      return null;
    }

    for (final endpoint in order) {
      final isLan = endpoint.kind == EndpointKind.lan;
      _set(
        OnboardingStatus(
          isLan ? OnboardingPhase.testingLan : OnboardingPhase.testingPublic,
          isLan ? 'Testing LAN…' : 'LAN unavailable — trying Public…',
          activeKind: endpoint.kind,
        ),
      );
      final ok = await prober(endpoint, payload.token);
      if (ok) {
        activeEndpoint = endpoint;
        _set(
          OnboardingStatus(
            OnboardingPhase.connected,
            isLan ? 'LAN connected.' : 'Public connected.',
            activeKind: endpoint.kind,
          ),
        );
        break;
      }
    }

    if (activeEndpoint == null) {
      _set(
        OnboardingStatus(
          OnboardingPhase.failed,
          mode == ConnectionMode.lanOnly
              ? 'Could not reach the server on your LAN. Check Wi-Fi and the chosen LAN address, then retry.'
              : 'Could not reach the server on LAN or Public.',
        ),
      );
      return null;
    }

    // Build the profile with the active endpoint as primary, retaining the
    // candidates + mode so the runtime can fall back later.
    final profile = _profileFor(payload, mode, activeEndpoint!);
    resultProfile = profile;

    _set(const OnboardingStatus(OnboardingPhase.syncing, 'Syncing chats…'));
    try {
      await runInitialSync(profile, (msg) {
        _set(
          OnboardingStatus(
            OnboardingPhase.syncing,
            msg,
            activeKind: activeEndpoint!.kind,
          ),
        );
      });
    } catch (_) {
      _set(
        OnboardingStatus(
          OnboardingPhase.failed,
          'Local database bootstrap failed. Retry, or continue later with cached data warning.',
          activeKind: activeEndpoint!.kind,
        ),
      );
      return null;
    }
    _set(
      OnboardingStatus(
        OnboardingPhase.done,
        'Sync complete.',
        activeKind: activeEndpoint!.kind,
      ),
    );
    return profile;
  }

  ConnectionProfile _profileFor(
    PairingPayload payload,
    ConnectionMode mode,
    PairingEndpoint active,
  ) {
    final base = payload.toProfile();
    return ConnectionProfile(
      baseUrl: active.baseUrl,
      token: payload.token,
      wsUrlOverride: active.wsUrl,
      lanBaseUrl: base.lanBaseUrl,
      lanWsUrl: base.lanWsUrl,
      publicBaseUrl: base.publicBaseUrl,
      publicWsUrl: base.publicWsUrl,
      mode: mode,
      configRevision: base.configRevision,
    );
  }
}
