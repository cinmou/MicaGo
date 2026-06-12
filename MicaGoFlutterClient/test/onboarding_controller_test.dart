import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/features/pairing/onboarding_controller.dart';
import 'package:mica_go/features/pairing/pairing_payload.dart';

PairingPayload _payload(
  ConnectionMode mode, {
  bool lan = true,
  bool public = true,
}) => PairingPayload(
  version: 2,
  mode: mode,
  token: 'tok',
  endpoints: [
    if (lan)
      const PairingEndpoint(
        kind: EndpointKind.lan,
        baseUrl: 'http://192.168.1.5:3000',
        priority: 1,
      ),
    if (public)
      const PairingEndpoint(
        kind: EndpointKind.public,
        baseUrl: 'https://pub.example.com',
        priority: 2,
      ),
  ],
);

OnboardingController _controller({
  required Future<bool> Function(PairingEndpoint, String) prober,
  List<String>? syncProgress,
}) => OnboardingController(
  prober: prober,
  runInitialSync: (profile, onProgress) async {
    onProgress('Syncing chats…');
    syncProgress?.add('synced:${profile.baseUrl}');
  },
);

void main() {
  test('LAN connects first; profile uses LAN endpoint', () async {
    final probed = <String>[];
    final c = _controller(
      prober: (e, _) async {
        probed.add(e.baseUrl);
        return true; // everything reachable
      },
    );
    final profile = await c.run(
      _payload(ConnectionMode.lanFirst),
      ConnectionMode.lanFirst,
    );
    expect(probed, ['http://192.168.1.5:3000']); // public never probed
    expect(c.activeEndpoint!.kind, EndpointKind.lan);
    expect(profile!.baseUrl, 'http://192.168.1.5:3000');
    expect(c.status.phase, OnboardingPhase.done);
  });

  test('LAN fails → falls back to Public; active endpoint = public', () async {
    final c = _controller(
      prober: (e, _) async => e.kind == EndpointKind.public,
    );
    final profile = await c.run(
      _payload(ConnectionMode.lanFirst),
      ConnectionMode.lanFirst,
    );
    expect(c.activeEndpoint!.kind, EndpointKind.public);
    expect(profile!.baseUrl, 'https://pub.example.com');
    expect(profile.mode, ConnectionMode.lanFirst);
  });

  test(
    'LAN-only never tries Public and fails cleanly when LAN is down',
    () async {
      final probed = <String>[];
      final c = _controller(
        prober: (e, _) async {
          probed.add(e.baseUrl);
          return false; // LAN down
        },
      );
      final profile = await c.run(
        _payload(ConnectionMode.lanOnly),
        ConnectionMode.lanOnly,
      );
      expect(profile, isNull);
      expect(c.status.phase, OnboardingPhase.failed);
      expect(probed, ['http://192.168.1.5:3000']); // public NEVER probed
      expect(c.status.message, contains('LAN'));
    },
  );

  test('runs initial sync after connecting', () async {
    final syncProgress = <String>[];
    final c = _controller(
      prober: (_, _) async => true,
      syncProgress: syncProgress,
    );
    await c.run(_payload(ConnectionMode.lanFirst), ConnectionMode.lanFirst);
    expect(syncProgress, ['synced:http://192.168.1.5:3000']);
    expect(c.status.phase, OnboardingPhase.done);
  });

  test('sync failure blocks onboarding and shows retry state', () async {
    final c = OnboardingController(
      prober: (_, _) async => true,
      runInitialSync: (_, _) async => throw Exception('network blip'),
    );
    final profile = await c.run(
      _payload(ConnectionMode.lanFirst),
      ConnectionMode.lanFirst,
    );
    expect(profile, isNull);
    expect(c.status.phase, OnboardingPhase.failed);
    expect(c.status.message, contains('bootstrap failed'));
  });
}
