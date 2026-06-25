import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/network/push_service.dart';
import '../chats/chats_pane.dart';
import '../settings/settings_screen.dart';
import 'connection_notice_host.dart';

/// The post-pairing app shell: a native Material 3 messenger layout with an
/// adaptive bottom NavigationBar (narrow) / side NavigationRail (wide).
///
/// Lean nav (Mategram-style): only **Chats** and **Settings**. People /
/// Connection / Diagnostics / Debug all live inside Settings now.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  PushService? _push;
  AppController? _app;

  static const _destinations = <_Destination>[
    _Destination('nav.chats', Icons.chat_bubble_outline, Icons.chat_bubble),
    _Destination('nav.settings', Icons.settings_outlined, Icons.settings),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Open the realtime socket + load endpoints once the shell appears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppController>();
      _app = app;
      unawaited(app.connectForeground(reason: 'startup'));
      app.refreshServerUrls().catchError((_) {});
      // C22: start the optional FCM wake path (no-op without Firebase config).
      _push = PushService(app);
      unawaited(_push!.start());
      // A notification tap routes here: jump to the Chats tab so the chat opens.
      app.pendingOpenChat.addListener(_onOpenChatRequested);
    });
  }

  void _onOpenChatRequested() {
    if (_app?.pendingOpenChat.value == null) return;
    if (_index != 0) setState(() => _index = 0);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final app = _app ?? context.read<AppController>();
    // C31: track foreground/background so the keep-alive path only raises a
    // system notification when the UI isn't already showing the message.
    app.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      // C20: one entry point — reconnect if needed + lightweight catch-up.
      // C22: this resume → catchUp is also the post-FCM-wake correctness path.
      app.onResume();
      unawaited(_push?.start() ?? Future<void>.value());
      // Refresh the Android 13+ notification-permission diagnostic on resume.
      unawaited(_push?.refreshNotificationPermission() ?? Future<void>.value());
    }
  }

  @override
  void dispose() {
    _app?.pendingOpenChat.removeListener(_onOpenChatRequested);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _body(int index) {
    switch (index) {
      case 0:
        return const ChatsPane();
      case 1:
        return const SettingsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    final strings = MicaLocalizations.of(context);

    final scaffold = Scaffold(
      appBar: AppBar(title: Text(strings.t(_destinations[_index].label))),
      body: SafeArea(
        // C19: connection banner (offline / public-fallback) + recovery snackbars.
        child: ConnectionNoticeHost(
          child: IndexedStack(
            index: _index,
            children: [
              for (var i = 0; i < _destinations.length; i++)
                // Build lazily-ish: only the visible body needs to be live, but
                // IndexedStack keeps state across tab switches.
                _body(i),
            ],
          ),
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final d in _destinations)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: strings.t(d.label),
                  ),
              ],
            ),
    );

    if (!wide) return scaffold;

    // Wide layout: side rail + the same scaffold body.
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              // Center the rail items vertically within the rail (default is
              // top-aligned). Alignment only — the destinations are unchanged.
              groupAlignment: 0.0,
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(strings.t(d.label)),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Scaffold(
                appBar: AppBar(title: Text(_destinations[_index].label)),
                body: ConnectionNoticeHost(
                  child: IndexedStack(
                    index: _index,
                    children: [
                      for (var i = 0; i < _destinations.length; i++) _body(i),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Destination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const _Destination(this.label, this.icon, this.selectedIcon);
}
