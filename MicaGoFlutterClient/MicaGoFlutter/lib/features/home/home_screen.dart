import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../core/app_controller.dart';
import '../../core/models/server_urls.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import '../debug/debug_log_panel.dart';

/// Post-connection home: connection status, endpoint summary, and placeholder
/// sections for the features that later phases will build. C0 foundation only.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _urlsError;
  bool _loadingUrls = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppController>();
      app.connectWebSocket();
      _refreshUrls();
    });
  }

  Future<void> _refreshUrls() async {
    final app = context.read<AppController>();
    setState(() {
      _loadingUrls = true;
      _urlsError = null;
    });
    try {
      await app.refreshServerUrls();
    } on ApiException catch (e) {
      if (mounted) setState(() => _urlsError = '${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _loadingUrls = false);
    }
  }

  Future<void> _signOut() async {
    final app = context.read<AppController>();
    await app.signOut();
    if (!mounted) return;
    context.go(Routes.connection);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('MicaGo'),
        actions: [
          IconButton(
            tooltip: 'Edit connection',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go(Routes.connection),
          ),
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshUrls,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _C0Banner(),
              const SizedBox(height: 12),
              _ConnectionStatusCard(
                app: app,
                onReconnect: () => app.connectWebSocket(),
              ),
              const SizedBox(height: 12),
              _EndpointSummaryCard(
                urls: app.serverUrls,
                loading: _loadingUrls,
                error: _urlsError,
                onRefresh: _refreshUrls,
              ),
              const SizedBox(height: 12),
              const _PlaceholderSections(),
              const SizedBox(height: 12),
              DebugLogPanel(ws: app.ws),
            ],
          ),
        ),
      ),
    );
  }
}

class _C0Banner extends StatelessWidget {
  const _C0Banner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.5),
      child: ListTile(
        leading: Icon(Icons.construction, color: scheme.onSecondaryContainer),
        title: const Text('C0 foundation'),
        subtitle: const Text(
          'Connection, REST, and realtime plumbing only. Chats, messages, '
          'contacts, and settings come in later phases.',
        ),
      ),
    );
  }
}

class _ConnectionStatusCard extends StatelessWidget {
  final AppController app;
  final VoidCallback onReconnect;

  const _ConnectionStatusCard({required this.app, required this.onReconnect});

  @override
  Widget build(BuildContext context) {
    final profile = app.profile;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connection', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _kv(context, 'Server', profile?.baseUrl ?? '—'),
            const SizedBox(height: 6),
            _kv(context, 'WebSocket', profile?.effectiveWsUrl ?? '—'),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: app.ws,
              builder: (context, _) {
                final ws = app.ws;
                return Row(
                  children: [
                    _WsStatusChip(status: ws.status),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: onReconnect,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Reconnect'),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(k,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ),
        Expanded(child: SelectableText(v)),
      ],
    );
  }
}

class _WsStatusChip extends StatelessWidget {
  final WsStatus status;
  const _WsStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color color, String label, IconData icon) = switch (status) {
      WsStatus.connected => (Colors.green, 'Connected', Icons.bolt),
      WsStatus.connecting => (scheme.tertiary, 'Connecting…', Icons.sync),
      WsStatus.failed => (scheme.error, 'Failed', Icons.error_outline),
      WsStatus.disconnected => (scheme.outline, 'Disconnected', Icons.power_off),
      WsStatus.idle => (scheme.outline, 'Idle', Icons.circle_outlined),
    };
    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _EndpointSummaryCard extends StatelessWidget {
  final ServerUrls? urls;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;

  const _EndpointSummaryCard({
    required this.urls,
    required this.loading,
    required this.error,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Server endpoints',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh),
                    onPressed: onRefresh,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (error != null)
              Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error))
            else if (urls == null && !loading)
              const Text('Pull to refresh to load /api/server/urls.')
            else if (urls != null) ...[
              for (final e in urls!.local)
                _EndpointRow(label: e.label, url: e.baseUrl, badge: e.reachableLabel),
              for (final e in urls!.lan)
                _EndpointRow(label: e.label, url: e.baseUrl, badge: e.reachableLabel),
              if (urls!.public?.enabled == true)
                _EndpointRow(
                  label: 'Public',
                  url: urls!.public!.baseUrl,
                  badge: urls!.public!.reachableLabel,
                )
              else
                Text('Public endpoint: not configured',
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _EndpointRow extends StatelessWidget {
  final String label;
  final String url;
  final String badge;

  const _EndpointRow({
    required this.label,
    required this.url,
    required this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label,
                style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: SelectableText(url)),
          const SizedBox(width: 8),
          Text(badge, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _PlaceholderSections extends StatelessWidget {
  const _PlaceholderSections();

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.chat_bubble_outline, 'Chats', 'Conversation list'),
      (Icons.message_outlined, 'Messages', 'Message threads'),
      (Icons.contacts_outlined, 'Contacts', 'Handle → name mapping'),
      (Icons.settings_outlined, 'Settings', 'Preferences & account'),
    ];
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            ListTile(
              leading: Icon(items[i].$1),
              title: Text(items[i].$2),
              subtitle: Text(items[i].$3),
              trailing: const Chip(
                label: Text('Soon'),
                visualDensity: VisualDensity.compact,
              ),
              enabled: false,
            ),
            if (i < items.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}
