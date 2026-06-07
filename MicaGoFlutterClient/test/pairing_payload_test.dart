import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/pairing/pairing_payload.dart';

void main() {
  group('parsePairingPayload', () {
    test('valid payload with explicit websocketUrl', () {
      final p = parsePairingPayload(
          '{"baseUrl":"https://go.example.com","websocketUrl":"wss://go.example.com/ws","token":"abc123"}');
      expect(p.baseUrl, 'https://go.example.com');
      expect(p.websocketUrl, 'wss://go.example.com/ws');
      expect(p.token, 'abc123');
      expect(p.effectiveWsUrl, 'wss://go.example.com/ws');
    });

    test('valid payload without websocketUrl derives effectiveWsUrl', () {
      final p = parsePairingPayload(
          '{"baseUrl":"https://go.example.com","token":"t"}');
      expect(p.websocketUrl, isNull);
      expect(p.effectiveWsUrl, 'wss://go.example.com/ws');
    });

    test('missing token throws', () {
      expect(() => parsePairingPayload('{"baseUrl":"https://x.com"}'),
          throwsA(isA<PairingParseException>()));
    });

    test('missing baseUrl throws', () {
      expect(() => parsePairingPayload('{"token":"t"}'),
          throwsA(isA<PairingParseException>()));
    });

    test('non-http baseUrl scheme throws', () {
      expect(() => parsePairingPayload('{"baseUrl":"ftp://x.com","token":"t"}'),
          throwsA(isA<PairingParseException>()));
    });

    test('non-ws websocketUrl scheme throws', () {
      expect(
          () => parsePairingPayload(
              '{"baseUrl":"https://x.com","websocketUrl":"http://x.com/ws","token":"t"}'),
          throwsA(isA<PairingParseException>()));
    });

    test('non-JSON throws', () {
      expect(() => parsePairingPayload('not a qr payload'),
          throwsA(isA<PairingParseException>()));
    });

    test('empty throws', () {
      expect(() => parsePairingPayload('   '),
          throwsA(isA<PairingParseException>()));
    });

    test('toProfile normalizes baseUrl and carries ws override', () {
      final p = parsePairingPayload(
          '{"baseUrl":"https://go.example.com/","token":"t","websocketUrl":"wss://go.example.com/ws"}');
      final prof = p.toProfile();
      expect(prof.baseUrl, 'https://go.example.com'); // trailing slash trimmed
      expect(prof.wsUrlOverride, 'wss://go.example.com/ws');
      expect(prof.token, 't');
    });

    test('toString never leaks the token', () {
      final p = parsePairingPayload(
          '{"baseUrl":"https://x.com","token":"supersecret"}');
      expect(p.toString().contains('supersecret'), isFalse);
      expect(p.toString().contains('redacted'), isTrue);
    });
  });
}
