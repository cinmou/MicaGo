import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mica_go/features/chats/message_render.dart';

void main() {
  // Load locale date symbols so DateFormat works (flutter_localizations does
  // this on-device); the function also has a fallback if they're missing.
  setUpAll(() async => initializeDateFormatting());

  // A fixed "now" so the buckets are deterministic: Wed 2026-06-10, 15:00.
  final now = DateTime(2026, 6, 10, 15, 0);

  String label(DateTime dt, {bool use24h = true, String locale = 'en'}) =>
      chatTimestampLabel(dt, now: now, use24h: use24h, locale: locale);

  // intl can separate AM/PM with a narrow / non-breaking space; normalize it.
  String norm(String s) => s.replaceAll(RegExp(r'\s', unicode: true), ' ');

  group('chatTimestampLabel', () {
    test('under a minute -> now', () {
      expect(label(now.subtract(const Duration(seconds: 30))), 'now');
    });

    test('under an hour -> relative minutes', () {
      expect(label(now.subtract(const Duration(minutes: 5))), '5m');
      expect(label(now.subtract(const Duration(minutes: 59))), '59m');
    });

    test('same day but over an hour -> clock time (24h)', () {
      // 3 hours earlier today -> 12:00.
      expect(
        label(now.subtract(const Duration(hours: 3)), use24h: true),
        '12:00',
      );
    });

    test('same day -> clock time honours the 12h setting', () {
      final morning = DateTime(2026, 6, 10, 6, 6);
      expect(norm(label(morning, use24h: false)), '6:06 AM');
      expect(label(morning, use24h: true), '06:06');
    });

    test('earlier this week -> weekday name', () {
      // 2 days before Wed 2026-06-10 is Mon 2026-06-08.
      expect(label(DateTime(2026, 6, 8, 9, 0)), 'Monday');
    });

    test('yesterday -> weekday (not clock time)', () {
      expect(label(DateTime(2026, 6, 9, 23, 0)), 'Tuesday');
    });

    test('older than 7 days -> numeric date', () {
      // 2026-05-20 is well over a week before 2026-06-10.
      expect(label(DateTime(2026, 5, 20, 8, 0)), '5/20/2026');
    });
  });
}
