import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/endpoint_utils.dart';

void main() {
  group('normalizeBaseUrl', () {
    test('adds http scheme when missing', () {
      expect(normalizeBaseUrl('192.168.1.5:3000'),
          'http://192.168.1.5:3000');
    });

    test('trims whitespace and trailing slashes', () {
      expect(normalizeBaseUrl('  https://mica.example.com//  '),
          'https://mica.example.com');
    });

    test('empty stays empty', () {
      expect(normalizeBaseUrl('   '), '');
    });
  });

  group('deriveWebSocketUrl', () {
    test('https -> wss and appends /ws', () {
      expect(deriveWebSocketUrl('https://mica.example.com'),
          'wss://mica.example.com/ws');
    });

    test('http -> ws with port', () {
      expect(deriveWebSocketUrl('http://127.0.0.1:3000'),
          'ws://127.0.0.1:3000/ws');
    });

    test('does not double-append /ws', () {
      expect(deriveWebSocketUrl('https://mica.example.com/ws'),
          'wss://mica.example.com/ws');
    });

    test('empty stays empty', () {
      expect(deriveWebSocketUrl(''), '');
    });
  });

  group('isValidHttpUrl', () {
    test('accepts host without scheme (normalized)', () {
      expect(isValidHttpUrl('mica.example.com'), isTrue);
    });

    test('accepts https url', () {
      expect(isValidHttpUrl('https://mica.example.com'), isTrue);
    });

    test('rejects empty', () {
      expect(isValidHttpUrl(''), isFalse);
    });
  });
}
