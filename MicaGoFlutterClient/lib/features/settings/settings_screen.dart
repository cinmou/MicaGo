import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../core/app_controller.dart';
import '../../core/theme_controller.dart';

/// Settings tab: shows the current connection (token masked), and lets the user
/// edit the connection or disconnect. Kept minimal for C1.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _revealToken = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final profile = app.profile;

    final theme = context.watch<ThemeController>();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Appearance', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _AppearanceCard(theme: theme),
        const SizedBox(height: 20),
        Text('Connection', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Server URL'),
                subtitle: SelectableText(profile?.baseUrl ?? '—'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.cable_outlined),
                title: const Text('WebSocket URL'),
                subtitle: SelectableText(profile?.effectiveWsUrl ?? '—'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('Bearer token'),
                subtitle: Text(_tokenText(profile?.token ?? '')),
                trailing: IconButton(
                  tooltip: _revealToken ? 'Hide' : 'Reveal',
                  icon: Icon(_revealToken
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: (profile?.token.isEmpty ?? true)
                      ? null
                      : () => setState(() => _revealToken = !_revealToken),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => context.go(Routes.connection),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Edit connection'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => _confirmDisconnect(context, app),
          icon: const Icon(Icons.logout),
          label: const Text('Disconnect'),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            'MicaGo · C1 foundation',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  String _tokenText(String token) {
    if (token.isEmpty) return '—';
    if (_revealToken) return token;
    final head = token.length <= 4 ? token : token.substring(0, 4);
    return '$head••••••••';
  }

  Future<void> _confirmDisconnect(BuildContext context, AppController app) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect?'),
        content: const Text(
          'This removes the saved server and token from this device.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Disconnect')),
        ],
      ),
    );
    if (confirmed == true) {
      await app.signOut();
      if (context.mounted) context.go(Routes.connection);
    }
  }
}

/// Theme mode, color, and language controls.
class _AppearanceCard extends StatelessWidget {
  final ThemeController theme;
  const _AppearanceCard({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Theme mode ---
            Text('Theme', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {theme.themeMode},
              onSelectionChanged: (s) => theme.setThemeMode(s.first),
            ),
            const Divider(height: 28),

            // --- Color ---
            Text('Color', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              'On Android 12+, “Use system colors” follows your wallpaper '
              '(Material You).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in ThemeColorChoice.values)
                  ChoiceChip(
                    selected: theme.colorChoice == c,
                    onSelected: (_) => theme.setColorChoice(c),
                    avatar: c == ThemeColorChoice.system
                        ? const Icon(Icons.auto_awesome, size: 16)
                        : CircleAvatar(
                            radius: 8, backgroundColor: _seedFor(c)),
                    label: Text(_colorLabel(c)),
                  ),
              ],
            ),
            const Divider(height: 28),

            // --- Language ---
            Text('Language', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            DropdownButton<LanguageChoice>(
              value: theme.language,
              isExpanded: true,
              onChanged: (l) {
                if (l != null) theme.setLanguage(l);
              },
              items: const [
                DropdownMenuItem(
                    value: LanguageChoice.system,
                    child: Text('System language')),
                DropdownMenuItem(
                    value: LanguageChoice.english, child: Text('English')),
                DropdownMenuItem(
                    value: LanguageChoice.chinese,
                    child: Text('简体中文 (Simplified Chinese)')),
              ],
            ),
            Text(
              'Note: app text is not translated yet — this switches built-in '
              'system controls only. Full translations are planned.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Color _seedFor(ThemeColorChoice c) {
    switch (c) {
      case ThemeColorChoice.system:
      case ThemeColorChoice.micago:
        return MicaGoThemeSeed.value;
      case ThemeColorChoice.blue:
        return const Color(0xFF1565C0);
      case ThemeColorChoice.green:
        return const Color(0xFF2E7D32);
      case ThemeColorChoice.purple:
        return const Color(0xFF6A1B9A);
      case ThemeColorChoice.orange:
        return const Color(0xFFE65100);
    }
  }

  String _colorLabel(ThemeColorChoice c) {
    switch (c) {
      case ThemeColorChoice.system:
        return 'System';
      case ThemeColorChoice.micago:
        return 'MicaGo';
      case ThemeColorChoice.blue:
        return 'Blue';
      case ThemeColorChoice.green:
        return 'Green';
      case ThemeColorChoice.purple:
        return 'Purple';
      case ThemeColorChoice.orange:
        return 'Orange';
    }
  }
}

/// Tiny indirection so the settings swatch can reference the brand seed without
/// importing the app theme here.
class MicaGoThemeSeed {
  static const Color value = Color(0xFF5B6CFF);
}
