import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../chats/chat_list_screen.dart';
import '../contacts/people_screen.dart';
import '../settings/settings_screen.dart';
import 'connection_status_view.dart';

/// The post-pairing app shell: a native Material 3 messenger layout with an
/// adaptive bottom NavigationBar (narrow) / side NavigationRail (wide). Tabs:
/// Chats, People, Connection, Settings. People is a placeholder for C1.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _destinations = <_Destination>[
    _Destination('Chats', Icons.chat_bubble_outline, Icons.chat_bubble),
    _Destination('People', Icons.people_outline, Icons.people),
    _Destination('Connection', Icons.lan_outlined, Icons.lan),
    _Destination('Settings', Icons.settings_outlined, Icons.settings),
  ];

  @override
  void initState() {
    super.initState();
    // Open the realtime socket + load endpoints once the shell appears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppController>();
      app.connectWebSocket();
      app.refreshServerUrls().catchError((_) {});
    });
  }

  Widget _body(int index) {
    switch (index) {
      case 0:
        return const ChatListScreen();
      case 1:
        return const PeopleScreen();
      case 2:
        return const ConnectionStatusView();
      case 3:
        return const SettingsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;

    final scaffold = Scaffold(
      appBar: AppBar(title: Text(_destinations[_index].label)),
      body: SafeArea(
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
                    label: d.label,
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
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Scaffold(
                appBar: AppBar(title: Text(_destinations[_index].label)),
                body: IndexedStack(
                  index: _index,
                  children: [for (var i = 0; i < _destinations.length; i++) _body(i)],
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
