import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/ui/top_banner.dart';

void main() {
  testWidgets('TopBanner appears in the top half of the screen', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    TopBanner.show(ctx, 'Connection lost');
    await tester.pump(); // insert overlay
    await tester.pump(const Duration(milliseconds: 250)); // finish slide-in

    expect(find.text('Connection lost'), findsOneWidget);

    // The banner must be anchored to the top, not the bottom.
    final bannerY = tester.getTopLeft(find.text('Connection lost')).dy;
    final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(bannerY, lessThan(screenH / 2));
  });

  testWidgets('identical messages do not stack (de-duped)', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    TopBanner.show(ctx, 'Send failed');
    await tester.pump();
    TopBanner.show(ctx, 'Send failed'); // repeat within the window
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Send failed'), findsOneWidget);

    // Let it auto-dismiss so it doesn't leak into other tests.
    await tester.pump(const Duration(seconds: 4));
  });
}
