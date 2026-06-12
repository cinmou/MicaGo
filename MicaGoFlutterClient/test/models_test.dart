import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/models/server_urls.dart';
import 'package:mica_go/core/network/connection_candidate.dart';

void main() {
  group('ConnectionProfile', () {
    test('effectiveWsUrl derives from baseUrl when no override', () {
      const p = ConnectionProfile(
        baseUrl: 'https://mica.example.com',
        token: 'secret',
      );
      expect(p.effectiveWsUrl, 'wss://mica.example.com/ws');
    });

    test('effectiveWsUrl honors override', () {
      const p = ConnectionProfile(
        baseUrl: 'https://mica.example.com',
        token: 'secret',
        wsUrlOverride: 'wss://ws.example.com/ws',
      );
      expect(p.effectiveWsUrl, 'wss://ws.example.com/ws');
    });

    test('json round-trip', () {
      const p = ConnectionProfile(
        baseUrl: 'http://127.0.0.1:3000',
        token: 'tok',
        wsUrlOverride: null,
      );
      final back = ConnectionProfile.fromJson(p.toJson());
      expect(back.baseUrl, p.baseUrl);
      expect(back.token, p.token);
      expect(back.wsUrlOverride, isNull);
    });

    test('candidate list and token survive json round-trip', () {
      const p = ConnectionProfile(
        baseUrl: 'http://192.168.1.5:3000',
        token: 'tok',
        lanBaseUrl: 'http://192.168.1.5:3000',
        lanWsUrl: 'ws://192.168.1.5:3000/ws',
        publicBaseUrl: 'https://micago.example.com',
        publicWsUrl: 'wss://micago.example.com/ws',
        mode: ConnectionMode.lanFirst,
      );

      final back = ConnectionProfile.fromJson(p.toJson());
      final candidates = connectionCandidatesForProfile(back);

      expect(back.token, 'tok');
      expect(candidates.map((e) => e.kind), [
        ConnectionCandidateKind.lan,
        ConnectionCandidateKind.public,
      ]);
      expect(candidates.map((e) => e.wsUrl), [
        'ws://192.168.1.5:3000/ws',
        'wss://micago.example.com/ws',
      ]);
    });

    test('toString never leaks the token', () {
      const p = ConnectionProfile(baseUrl: 'http://x', token: 'topsecret');
      expect(p.toString().contains('topsecret'), isFalse);
      expect(p.toString().contains('redacted'), isTrue);
    });
  });

  group('ServerUrls.fromJson', () {
    test('parses local/lan/public', () {
      final urls = ServerUrls.fromJson({
        'local': [
          {
            'kind': 'loopback',
            'label': 'This Mac',
            'baseUrl': 'http://127.0.0.1:3000',
            'wsUrl': 'ws://127.0.0.1:3000/ws',
            'reachable': true,
          },
        ],
        'lan': [],
        'public': {
          'enabled': true,
          'kind': 'custom',
          'baseUrl': 'https://mica.example.com',
          'wsUrl': 'wss://mica.example.com/ws',
          'reachable': 'unknown',
          'verifyTls': true,
          'lastCheckedAt': 1717372805000,
        },
        'preferredPairingEndpoint': 'auto',
      });

      expect(urls.local, hasLength(1));
      expect(urls.local.first.reachableLabel, 'reachable');
      expect(urls.lan, isEmpty);
      expect(urls.public?.enabled, isTrue);
      expect(urls.public?.reachableLabel, 'unknown');
      expect(urls.preferredPairingEndpoint, 'auto');
    });

    test('handles missing public block', () {
      final urls = ServerUrls.fromJson({'local': [], 'lan': []});
      expect(urls.public, isNull);
      expect(urls.preferredPairingEndpoint, 'auto');
    });
  });
}
