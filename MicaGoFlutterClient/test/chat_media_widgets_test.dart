import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/features/chats/attachment_views.dart';
import 'package:mica_go/features/chats/message_thread_screen.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

AttachmentModel _att({
  required String guid,
  required String kind,
  String? mime,
  String? name,
}) => AttachmentModel(
  guid: guid,
  downloadUrl: '/api/attachments/$guid',
  filename: name,
  mimeType: mime,
  attachmentKind: kind,
);

void main() {
  final api = ApiClient(baseUrl: 'http://localhost:0', token: 't');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('EmojiPanel renders and tapping inserts the tapped emoji', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EmojiPanel(onPick: (e) => picked = e)),
      ),
    );
    // The first Smileys emoji is rendered; tap it.
    expect(find.text('😀'), findsOneWidget);
    await tester.tap(find.text('😀'));
    expect(picked, '😀');

    // Switching category shows a different set (hearts contains a heart).
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();
    expect(find.text('❤️'), findsOneWidget);
  });

  testWidgets('EmojiPanel.remember builds a Recent category', (tester) async {
    EmojiPanel.remember('🔥');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EmojiPanel(onPick: (_) {})),
      ),
    );
    // A history (Recent) tab appears once something has been remembered.
    expect(find.byIcon(Icons.history), findsOneWidget);
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(find.text('🔥'), findsWidgets);
  });

  testWidgets('a video attachment renders a tappable card (no crash)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentView(
            api: api,
            attachment: _att(
              guid: 'v1',
              kind: 'video',
              mime: 'video/mp4',
              name: 'clip.mp4',
            ),
          ),
        ),
      ),
    );
    // Video card shows the play affordance + filename — and does not throw.
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unsupported file renders a file card and does not crash', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentView(
            api: api,
            attachment: _att(
              guid: 'f1',
              kind: 'file',
              mime: 'application/octet-stream',
              name: 'data.bin',
            ),
          ),
        ),
      ),
    );
    expect(find.text('data.bin'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-press opens copy-only message action menu', (tester) async {
    const msg = MessageModel(guid: 'm1', text: 'Copy me');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => GestureDetector(
              onLongPressStart: (details) =>
                  showMessageActionMenu(context, msg, details.globalPosition),
              child: const Text('Copy me'),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('Copy me'));
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Message Info'), findsNothing);
    expect(find.text('Copy debug JSON'), findsNothing);
  });

  testWidgets('copy action copies text messages', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            copied = args['text'] as String?;
          }
          return null;
        });
    const msg = MessageModel(guid: 'm1', text: 'Copy me');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => GestureDetector(
              onLongPressStart: (details) =>
                  showMessageActionMenu(context, msg, details.globalPosition),
              child: const Text('Copy me'),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('Copy me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, 'Copy me');
    expect(find.text('Message copied'), findsOneWidget);
  });

  testWidgets('message info is not exposed from the normal action menu', (
    tester,
  ) async {
    const msg = MessageModel(guid: 'm1', text: 'Inspect me');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => GestureDetector(
              onLongPressStart: (details) =>
                  showMessageActionMenu(context, msg, details.globalPosition),
              child: const Text('Inspect me'),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('Inspect me'));
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Message Info'), findsNothing);
    expect(find.text('Copy debug JSON'), findsNothing);
  });
}
