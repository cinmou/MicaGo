import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/contacts/contact_identity.dart';

void main() {
  group('normalization', () {
    test('email is lowercased and trimmed', () {
      expect(normalizeEmail('  John.Doe@iCloud.com '), 'john.doe@icloud.com');
    });
    test('non-email returns empty', () {
      expect(normalizeEmail('+15551234567'), '');
    });
    test('phone reduces to last 10 digits', () {
      expect(normalizePhone('+1 (555) 123-4567'), '5551234567');
      expect(normalizePhone('555-123-4567'), '5551234567');
    });
    test('too-short phone returns empty', () {
      expect(normalizePhone('12345'), '');
    });
    test('isEmailHandle detects @', () {
      expect(isEmailHandle('a@b.com'), isTrue);
      expect(isEmailHandle('+15551234567'), isFalse);
    });
  });

  group('ContactIndex matching', () {
    final index = ContactIndex.fromContacts(const [
      ContactIdentity(
        id: '1',
        displayName: 'Jane Doe',
        phones: ['+1 555-123-4567'],
        emails: ['Jane@iCloud.com', 'jane.work@example.com'],
      ),
      ContactIdentity(
        id: '2',
        displayName: 'Bob',
        phones: ['(555) 987 6543'],
        emails: [],
      ),
    ]);

    test('matches by email case-insensitively', () {
      expect(index.displayNameFor('JANE@icloud.com'), 'Jane Doe');
    });
    test('matches an alternate email for the same contact', () {
      expect(index.displayNameFor('jane.work@example.com'), 'Jane Doe');
    });
    test('matches by phone with a country code prefix', () {
      expect(index.displayNameFor('+1 (555) 123-4567'), 'Jane Doe');
    });
    test('matches a phone with different formatting', () {
      expect(index.displayNameFor('5559876543'), 'Bob');
    });
    test('returns null for an unknown handle', () {
      expect(index.displayNameFor('+19998887777'), isNull);
    });
    test('returns null for a group GUID', () {
      expect(index.displayNameFor('iMessage;-;chat123456'), isNull);
    });
    test('empty index matches nothing', () {
      expect(const ContactIndex.empty().displayNameFor('a@b.com'), isNull);
    });
  });
}
