import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/models/server_urls.dart';

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
          }
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
