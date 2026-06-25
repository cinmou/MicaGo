import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../core/app_controller.dart';
import '../../core/network/notification_display.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/models/connection_profile.dart';
import '../../core/network/connection_candidate.dart';
import '../../core/theme_controller.dart';
import '../../core/ui/top_banner.dart';
import '../contacts/people_screen.dart';
import '../debug/debug_log_panel.dart';
import '../home/connection_status_view.dart';
import 'message_display_controller.dart';
import 'message_display_page.dart';

/// Settings tab: shows the current connection (token masked), and lets the user
/// edit the connection or disconnect. Kept minimal for C1.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final profile = app.profile;
    final theme = context.watch<ThemeController>();
    final strings = MicaLocalizations.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          strings.t('settings.appearance'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        _AppearanceCard(theme: theme),
        const SizedBox(height: 20),
        Text(
          strings.t('settings.messaging'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        _SmsSendingCard(app: app),
        const SizedBox(height: 20),
        Text(
          strings.t('settings.notifications'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        _NotificationsCard(app: app),
        const SizedBox(height: 20),
        Text(
          strings.t('settings.more'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: _leadingIcon(Icons.contacts_outlined),
                title: Text(strings.t('settings.contacts')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _push(
                  context,
                  strings.t('settings.contacts'),
                  const PeopleScreen(),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: _leadingIcon(Icons.chat_bubble_outline),
                title: Text(strings.t('settings.messageDisplay')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _push(
                  context,
                  strings.t('settings.messageDisplay'),
                  const MessageDisplayPage(),
                ),
              ),
              if (kDebugMode) ...[
                const Divider(height: 1),
                ListTile(
                  leading: _leadingIcon(Icons.bug_report_outlined),
                  title: Text(strings.t('settings.debugTools')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(
                    context,
                    strings.t('settings.debugTools'),
                    const _DebugToolsBody(),
                  ),
                ),
              ],
              const Divider(height: 1),
              ListTile(
                leading: _leadingIcon(Icons.info_outline),
                title: Text(strings.t('settings.about')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _push(
                  context,
                  strings.t('settings.about'),
                  const _AboutBody(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (profile != null) _RouteSwitcher(app: app, profile: profile),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => context.go(Routes.connection),
          icon: const Icon(Icons.edit_outlined),
          label: Text(strings.t('settings.editConnection')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => _confirmDisconnect(context, app),
          icon: const Icon(Icons.logout),
          label: Text(strings.t('settings.disconnect')),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            'micaGO · C1 foundation',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  /// Pushes a Settings sub-page wrapped in its own Scaffold (title + back).
  void _push(BuildContext context, String title, Widget body) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(child: body),
        ),
      ),
    );
  }

  Future<void> _confirmDisconnect(
    BuildContext context,
    AppController app,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          MicaLocalizations.of(context).t('settings.disconnectTitle'),
        ),
        content: Text(
          MicaLocalizations.of(context).t('settings.disconnectBody'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(MicaLocalizations.of(context).t('settings.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(MicaLocalizations.of(context).t('settings.disconnect')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await app.signOut();
      if (context.mounted) context.go(Routes.connection);
    }
  }
}

Widget _leadingIcon(IconData icon, {Color? color}) => SizedBox(
  width: 40,
  child: Center(child: Icon(icon, color: color)),
);

/// C26: when the server advertises more than one route (multiple LAN interfaces,
/// or LAN + Public), let the user pick which one to use. "Automatic" keeps the
/// LAN-first behaviour; picking a specific route pins it (persisted) and the app
/// reconnects through it. Hidden when there is only one candidate.
class _RouteSwitcher extends StatelessWidget {
  final AppController app;
  final ConnectionProfile profile;
  const _RouteSwitcher({required this.app, required this.profile});

  @override
  Widget build(BuildContext context) {
    final candidates = app.connectionCandidates;
    if (candidates.length < 2) return const SizedBox.shrink();
    final activeBase = app.activeCandidate?.baseUrl;
    final pinned = profile.selectedBaseUrl;
    final scheme = Theme.of(context).colorScheme;

    String labelFor(ConnectionCandidate c) {
      final host = Uri.tryParse(c.baseUrl)?.host ?? c.baseUrl;
      return '${c.label} · $host';
    }

    return Card(
      child: RadioGroup<String?>(
        groupValue: pinned,
        onChanged: (v) => app.selectRoute(v),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Server route',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const RadioListTile<String?>(
              value: null,
              title: Text('Automatic (LAN-first)'),
              subtitle: Text('Pick the best reachable route'),
              dense: true,
            ),
            for (final c in candidates)
              RadioListTile<String?>(
                value: c.baseUrl,
                title: Text(labelFor(c)),
                subtitle: c.baseUrl == activeBase
                    ? Text('Connected', style: TextStyle(color: scheme.primary))
                    : Text(c.baseUrl),
                secondary: c.baseUrl == activeBase
                    ? Icon(Icons.check_circle, color: scheme.primary, size: 20)
                    : null,
                dense: true,
              ),
          ],
        ),
      ),
    );
  }
}

/// C27: push notification status + a "Send test notification" action. Push is
/// optional (BlueBubbles user-owned Firebase): when it isn't configured the card
/// explains that the app stays on its live socket + catch-up sync, which still
/// delivers messages while open.
/// C29c: device-registration diagnostics + a "Register device now" button so a
/// failing registration can be debugged on-device instead of guessed.
class _DeviceRegisterDebug extends StatefulWidget {
  const _DeviceRegisterDebug();

  @override
  State<_DeviceRegisterDebug> createState() => _DeviceRegisterDebugState();
}

class _DeviceRegisterDebugState extends State<_DeviceRegisterDebug> {
  String _diagnostics = 'Loading…';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final text = await context.read<AppController>().connectionDiagnostics();
    if (mounted) setState(() => _diagnostics = text);
  }

  Future<void> _registerNow() async {
    setState(() => _busy = true);
    final result = await context.read<AppController>().registerDeviceNow();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(result)));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _registerNow,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              label: const Text('Register device now'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _diagnostics,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Tap "Register device now", then check the Mac server log and '
          'curl <baseUrl>/api/devices. The result line above shows the exact '
          'HTTP status / error (401 = token, 0 = unreachable, 400 = rejected).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _DebugToolsBody extends StatelessWidget {
  const _DebugToolsBody();

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final app = context.read<AppController>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            children: [
              ListTile(
                leading: _leadingIcon(Icons.lan_outlined),
                title: Text(strings.t('settings.connectionDiagnostics')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(
                        title: Text(
                          strings.t('settings.connectionDiagnostics'),
                        ),
                      ),
                      body: const SafeArea(child: ConnectionStatusView()),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: _leadingIcon(Icons.terminal),
                title: Text(strings.t('settings.realtimeEvents')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(
                        title: Text(strings.t('settings.realtimeEvents')),
                      ),
                      body: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: DebugLogPanel(ws: app.ws, app: app),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: _leadingIcon(Icons.devices_other_outlined),
                title: Text(strings.t('settings.deviceRegistration')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(
                        title: Text(strings.t('settings.deviceRegistration')),
                      ),
                      body: const SafeArea(child: _DeviceRegisterDebug()),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NotificationsCard extends StatefulWidget {
  final AppController app;
  const _NotificationsCard({required this.app});

  @override
  State<_NotificationsCard> createState() => _NotificationsCardState();
}

class _NotificationsCardState extends State<_NotificationsCard> {
  bool _busy = false;

  Future<void> _sendTest() async {
    setState(() => _busy = true);
    final error = await widget.app.sendTestPush();
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = error ?? 'Test notification sent.';
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _enableNotifications() async {
    final granted = await requestSystemNotificationPermission();
    widget.app.noteNotificationPermission(granted);
    if (!mounted) return;
    if (granted == false) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Notifications are blocked. Enable them in Android Settings → '
              'Apps → micaGO → Notifications.',
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final configured = app.pushConfigured;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: _leadingIcon(
              configured
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
              color: configured ? scheme.primary : scheme.onSurfaceVariant,
            ),
            title: Text(
              configured
                  ? 'Push notifications enabled'
                  : 'Push notifications not configured',
            ),
            subtitle: Text(
              configured
                  ? 'This device can be woken for new messages (${app.pushProvider.toUpperCase()}).'
                  : 'Optional. Set up your own Firebase project on the Mac to enable background pushes. Messages still arrive while the app is open.',
            ),
            isThreeLine: true,
          ),
          if (configured) ...[
            const Divider(height: 1),
            ListTile(
              leading: _leadingIcon(Icons.send_outlined),
              title: const Text('Send test notification'),
              subtitle: const Text('Delivers a test push to this device'),
              trailing: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _busy ? null : _sendTest,
            ),
          ],
          // Android 13+ permission warning — a denied POST_NOTIFICATIONS means
          // no pushes OR keep-alive notifications can appear, however configured.
          if (defaultTargetPlatform == TargetPlatform.android &&
              !kIsWeb &&
              app.notificationPermission == 'denied') ...[
            const Divider(height: 1),
            ListTile(
              leading: _leadingIcon(
                Icons.warning_amber_outlined,
                color: scheme.error,
              ),
              title: const Text('Notifications are turned off'),
              subtitle: const Text(
                'Android is blocking notifications, so neither push nor '
                'keep-alive can alert you. Turn them on to receive messages.',
              ),
              isThreeLine: true,
              trailing: TextButton(
                onPressed: _enableNotifications,
                child: const Text('Turn on'),
              ),
            ),
          ],
          // C29: advanced opt-in keep-alive (Android only). Default off. Works
          // even without Firebase — a foreground service holds the connection.
          if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) ...[
            const Divider(height: 1),
            SwitchListTile(
              secondary: _leadingIcon(Icons.bolt_outlined),
              title: const Text('Keep micaGO running in background'),
              subtitle: const Text(
                'Advanced. A foreground service holds the connection open and '
                'shows local notifications even without Firebase — so you get '
                'alerts with no push setup. Android/OEM battery limits can still '
                'throttle it, and it uses more battery.',
              ),
              isThreeLine: true,
              value: app.keepAliveEnabled,
              onChanged: (v) => app.setKeepAliveEnabled(v),
            ),
          ],
          const Divider(height: 1),
          _NotificationDiagnosticsTile(app: app),
        ],
      ),
    );
  }
}

/// C31: read-only notification diagnostics — FCM configured/registered,
/// keep-alive, permission, last notification source, last direct-reply result.
/// "Copy" exports the same (no token, no message text).
class _NotificationDiagnosticsTile extends StatelessWidget {
  final AppController app;
  const _NotificationDiagnosticsTile({required this.app});

  List<MapEntry<String, String>> _rows() {
    String perm = switch (app.notificationPermission) {
      'granted' => 'granted',
      'denied' => 'denied',
      _ => 'unknown',
    };
    return [
      MapEntry('Firebase push', app.pushConfigured ? 'configured' : 'off'),
      MapEntry(
        'Token registered',
        app.pushConfigured ? 'yes (${app.pushProvider})' : 'no',
      ),
      MapEntry('Keep-alive', app.keepAliveEnabled ? 'enabled' : 'off'),
      MapEntry('Notification permission', perm),
      MapEntry('Last notification', app.lastNotificationSource ?? '—'),
      MapEntry('Last direct reply', app.lastReplyResult ?? '—'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return ExpansionTile(
      leading: const SizedBox(width: 40, child: Icon(Icons.info_outline)),
      title: const Text('Notification diagnostics'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 4, child: Text(r.key)),
                Expanded(
                  flex: 6,
                  child: Text(
                    r.value,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy diagnostics'),
            onPressed: () {
              final text = [
                'micaGO notification diagnostics',
                for (final r in rows) '${r.key}: ${r.value}',
              ].join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(
                  const SnackBar(content: Text('Diagnostics copied')),
                );
            },
          ),
        ),
      ],
    );
  }
}

/// Theme mode, color, and language controls.
/// C20: server-authoritative "Allow SMS sending through Mac" toggle. Reads and
/// writes the server's sync settings — the client never guesses. Default off:
/// SMS chats stay read-only until the user turns this on (and the server's
/// Messages can actually send SMS).
class _SmsSendingCard extends StatefulWidget {
  final AppController app;
  const _SmsSendingCard({required this.app});

  @override
  State<_SmsSendingCard> createState() => _SmsSendingCardState();
}

class _SmsSendingCardState extends State<_SmsSendingCard> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Pull the current server value when the screen opens (it is also fetched
    // on connect). Best-effort.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.app.syncSettings == null) {
        widget.app.refreshSyncSettings();
      }
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    final ok = await widget.app.setAllowSmsSend(value);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      TopBanner.show(
        context,
        'Could not update the SMS setting',
        kind: TopBannerKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final unreachable = app.syncSettings == null;
    return Card(
      child: SwitchListTile(
        secondary: _leadingIcon(Icons.sms_outlined),
        title: const Text('Allow SMS sending through Mac'),
        subtitle: Text(
          unreachable
              ? 'Connect to the server to change this setting.'
              : 'When on, SMS conversations can be sent through your Mac’s '
                    'Messages. When off, SMS is read-only. iMessage is always '
                    'sendable; Unknown is always read-only.',
        ),
        value: app.allowSmsSend,
        onChanged: (_busy || unreachable) ? null : _toggle,
      ),
    );
  }
}

class _AppearanceCard extends StatelessWidget {
  final ThemeController theme;
  const _AppearanceCard({required this.theme});

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final display = context.watch<MessageDisplayController>();
    final prefs = display.prefs;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Theme mode ---
            Text(
              strings.t('settings.theme'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              segments: [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text(strings.t('settings.system')),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text(strings.t('settings.light')),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text(strings.t('settings.dark')),
                ),
              ],
              selected: {theme.themeMode},
              onSelectionChanged: (s) => theme.setThemeMode(s.first),
            ),
            const Divider(height: 28),

            // --- Color ---
            Text(
              strings.t('settings.color'),
              style: Theme.of(context).textTheme.labelLarge,
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
                        : CircleAvatar(radius: 8, backgroundColor: _seedFor(c)),
                    label: Text(_colorLabel(c)),
                  ),
              ],
            ),
            const Divider(height: 28),

            Text(
              strings.t('settings.collection'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Text(
              strings.t('settings.recentPerChat'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final n in const [50, 100, 200])
                  ChoiceChip(
                    selected: prefs.messagesPerChat == n,
                    onSelected: (_) =>
                        display.update(prefs.copyWith(messagesPerChat: n)),
                    label: Text('$n'),
                  ),
              ],
            ),
            const Divider(height: 28),

            // --- Language ---
            Text(
              strings.t('settings.language'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            DropdownButton<LanguageChoice>(
              value: theme.language,
              isExpanded: true,
              onChanged: (l) {
                if (l != null) theme.setLanguage(l);
              },
              items: [
                DropdownMenuItem(
                  value: LanguageChoice.system,
                  child: Text(strings.t('settings.systemLanguage')),
                ),
                DropdownMenuItem(
                  value: LanguageChoice.english,
                  child: Text(strings.t('settings.english')),
                ),
                DropdownMenuItem(
                  value: LanguageChoice.simplifiedChinese,
                  child: Text(strings.t('settings.zhHans')),
                ),
                DropdownMenuItem(
                  value: LanguageChoice.traditionalChinese,
                  child: Text(strings.t('settings.zhHant')),
                ),
              ],
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
        return 'micaGO';
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

class _AboutBody extends StatefulWidget {
  const _AboutBody();

  @override
  State<_AboutBody> createState() => _AboutBodyState();
}

class _AboutBodyState extends State<_AboutBody> {
  bool _revealToken = false;

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final app = context.watch<AppController>();
    final profile = app.profile;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: _leadingIcon(Icons.bolt),
          title: const Text('micaGO'),
          subtitle: const Text('Android client'),
        ),
        ListTile(
          leading: _leadingIcon(Icons.lock_outline),
          title: Text(strings.t('settings.privacy')),
          subtitle: const Text('No micaGO cloud. Contacts stay local.'),
        ),
        ListTile(
          leading: _leadingIcon(Icons.science_outlined),
          title: Text(strings.t('settings.status')),
          subtitle: Text(strings.t('settings.preRelease')),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: _leadingIcon(Icons.dns_outlined),
                title: Text(strings.t('settings.activeServerUrl')),
                subtitle: SelectableText(
                  app.activeCandidate?.baseUrl ??
                      profile?.effectiveBaseUrl ??
                      '—',
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: _leadingIcon(Icons.cable_outlined),
                title: Text(strings.t('settings.websocketUrl')),
                subtitle: SelectableText(
                  app.activeCandidate?.wsUrl ?? profile?.effectiveWsUrl ?? '—',
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: _leadingIcon(Icons.key_outlined),
                title: Text(strings.t('settings.bearerToken')),
                subtitle: SelectableText(_tokenText(profile?.token ?? '')),
                trailing: IconButton(
                  tooltip: _revealToken ? 'Hide' : 'Reveal',
                  icon: Icon(
                    _revealToken
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: (profile?.token.isEmpty ?? true)
                      ? null
                      : () => setState(() => _revealToken = !_revealToken),
                ),
              ),
            ],
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
}
