import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';

void main() {
  group('ChatSummary.fromJson', () {
    test('parses minimal server fields (1:1 chat)', () {
      final c = ChatSummary.fromJson({
        'guid': 'iMessage;-;+15551234567',
        'chatIdentifier': '+15551234567',
        'serviceName': 'iMessage',
        'displayName': null,
        'isArchived': false,
      });
      expect(c.guid, 'iMessage;-;+15551234567');
      expect(c.serviceName, 'iMessage');
      expect(c.isArchived, isFalse);
      expect(c.isGroup, isFalse); // no displayName, single participant
      expect(c.title, '+15551234567'); // falls back to identifier
      expect(c.hasUnread, isFalse);
    });

    test('treats a display name as a group', () {
      final c = ChatSummary.fromJson(
          {'guid': 'g', 'displayName': 'Family', 'serviceName': 'iMessage'});
      expect(c.isGroup, isTrue);
      expect(c.title, 'Family');
      expect(c.initials, 'F');
    });

    test('title falls back to GUID when nothing else is present', () {
      final c = ChatSummary.fromJson({'guid': 'only-guid'});
      expect(c.title, 'only-guid');
    });

    test('parses optional/future fields when present', () {
      final c = ChatSummary.fromJson({
        'guid': 'g',
        'displayName': 'Team',
        'unreadCount': 3,
        'lastMessagePreview': 'see you soon',
        'lastMessageAt': 1717372800000,
        'participants': ['+1', '+2'],
        'isPinned': true,
        'isMuted': true,
        'isGroup': true,
      });
      expect(c.hasUnread, isTrue);
      expect(c.unreadCount, 3);
      expect(c.lastMessagePreview, 'see you soon');
      expect(c.lastMessageAt, 1717372800000);
      expect(c.participants, ['+1', '+2']);
      expect(c.isPinned, isTrue);
      expect(c.isMuted, isTrue);
      expect(c.isGroup, isTrue);
    });

    test('initials for a two-word name', () {
      final c = ChatSummary.fromJson({'guid': 'g', 'displayName': 'Jane Doe'});
      expect(c.initials, 'JD');
    });

    test('initials for a phone-like identifier is a generic glyph', () {
      final c = ChatSummary.fromJson(
          {'guid': 'g', 'chatIdentifier': '+1 (555) 123-4567'});
      expect(c.initials, '#');
    });
  });
}
