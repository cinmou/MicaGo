import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/network/push_service.dart';
import '../chats/chats_pane.dart';
import '../settings/settings_screen.dart';
import 'connection_notice_host.dart';

/// The post-pairing app shell: chat-first, with Settings as a secondary page.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  PushService? _push;
  AppController? _app;
  final ValueNotifier<int> _searchRequests = ValueNotifier<int>(0);
  static const double _tabletBreakpoint = 840;

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
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
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
    _searchRequests.dispose();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tablet = MediaQuery.sizeOf(context).width >= _tabletBreakpoint;
    final headerBg = _homeAccent1_100(scheme);
    final pageBg = _homeAccent1_50(scheme);
    final chats = ConnectionNoticeHost(
      child: ChatsPane(
        searchRequests: _searchRequests,
        onSearchRequested: () => _searchRequests.value++,
        onOpenSettings: _openSettings,
      ),
    );
    return Scaffold(
      backgroundColor: pageBg,
      appBar: tablet
          ? null
          : AppBar(
              centerTitle: true,
              backgroundColor: headerBg,
              surfaceTintColor: Colors.transparent,
              leading: IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search),
                onPressed: () => _searchRequests.value++,
              ),
              title: const Text('micaGO'),
              actions: [
                IconButton(
                  tooltip: strings.t('nav.settings'),
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _openSettings,
                ),
              ],
            ),
      body: tablet
          ? SafeArea(bottom: false, child: chats)
          : DecoratedBox(
              decoration: BoxDecoration(color: headerBg),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: pageBg),
                  child: SafeArea(top: false, bottom: false, child: chats),
                ),
              ),
            ),
    );
  }
}

Color _homeAccent1_50(ColorScheme scheme) =>
    Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), scheme.surface);

Color _homeAccent1_100(ColorScheme scheme) => Color.alphaBlend(
  scheme.primary.withValues(alpha: 0.18),
  scheme.surfaceContainerLowest,
);
