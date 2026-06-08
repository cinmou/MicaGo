import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/avatar.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('ContactAvatar fallback', () {
    testWidgets('shows two-letter initials for a full name', (tester) async {
      await tester.pumpWidget(_wrap(const ContactAvatar(title: 'Jane Doe')));
      expect(find.text('JD'), findsOneWidget);
    });

    testWidgets('shows a group icon for group chats', (tester) async {
      await tester.pumpWidget(
          _wrap(const ContactAvatar(title: 'Family', isGroup: true)));
      expect(find.byIcon(Icons.group), findsOneWidget);
      expect(find.text('F'), findsNothing);
    });

    testWidgets('shows a generic glyph for a phone-like handle', (tester) async {
      await tester.pumpWidget(
          _wrap(const ContactAvatar(title: '+1 (555) 123-4567')));
      expect(find.text('#'), findsOneWidget);
    });

    testWidgets('single-word name uses one initial', (tester) async {
      await tester.pumpWidget(_wrap(const ContactAvatar(title: 'Bob')));
      expect(find.text('B'), findsOneWidget);
    });
  });
}
