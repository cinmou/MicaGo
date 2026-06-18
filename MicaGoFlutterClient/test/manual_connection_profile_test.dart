import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/network/connection_candidate.dart';
import 'package:mica_go/core/network/manual_connection_profile.dart';

void main() {
  group('advanced manual connection profile', () {
    test('public-only manual entry creates a public candidate', () {
      final profile = advancedManualProfile(
        publicBaseUrl: 'https://micago.example.com/',
        lanBaseUrl: '',
        token: 'tok',
      );

      expect(profile.mode, ConnectionMode.publicOnly);
      expect(profile.publicBaseUrl, 'https://micago.example.com');
      expect(profile.publicWsUrl, 'wss://micago.example.com/ws');
      expect(
        connectionCandidatesForProfile(profile).single.kind,
        ConnectionCandidateKind.public,
      );
    });

    test('lan plus public tries LAN first and derives both websocket URLs', () {
      final profile = advancedManualProfile(
        publicBaseUrl: 'https://micago.example.com',
        lanBaseUrl: 'http://192.168.1.23:3000',
        token: 'tok',
      );

      final candidates = connectionCandidatesForProfile(profile);
      expect(profile.mode, ConnectionMode.lanFirst);
      expect(candidates.map((c) => c.kind), [
        ConnectionCandidateKind.lan,
        ConnectionCandidateKind.public,
      ]);
      expect(candidates.map((c) => c.wsUrl), [
        'ws://192.168.1.23:3000/ws',
        'wss://micago.example.com/ws',
      ]);
    });
  });
}
