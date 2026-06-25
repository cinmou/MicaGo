import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../chats/message_display.dart';
import 'message_display_controller.dart';

/// Settings → "Message display" (Part I). Local display preferences only — they
/// never delete or change server data, and never hide failed outgoing messages.
class MessageDisplayPage extends StatelessWidget {
  const MessageDisplayPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<MessageDisplayController>();
    final p = controller.prefs;
    void set(MessageDisplayPrefs next) => controller.update(next);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'These settings only change how messages are displayed on this '
          'device. They never delete messages or change server data, and '
          'failed messages are always shown.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Hide unsupported / system debug rows'),
                subtitle: const Text('Hide rows we can\'t render as content'),
                value: p.hideUnsupportedRows,
                onChanged: (v) => set(p.copyWith(hideUnsupportedRows: v)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('Merge consecutive system messages'),
                value: p.mergeConsecutiveSystem,
                onChanged: (v) => set(p.copyWith(mergeConsecutiveSystem: v)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('Merge tapbacks into the target message'),
                subtitle: const Text(
                  'Show reactions as chips, not separate rows',
                ),
                value: p.mergeTapbacks,
                onChanged: (v) => set(p.copyWith(mergeTapbacks: v)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('Show effect hints'),
                subtitle: const Text('e.g. "Sent with Slam"'),
                value: p.showEffectHints,
                onChanged: (v) => set(p.copyWith(showEffectHints: v)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('Show debug-only chats'),
                subtitle: const Text(
                  'Reveal chats whose only content is system/noise rows',
                ),
                value: p.showDebugChats,
                onChanged: (v) => set(p.copyWith(showDebugChats: v)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Delivery & read labels',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final mode in DeliveryLabelMode.values)
                _ChoiceTile(
                  label: _deliveryLabel(mode),
                  selected: p.deliveryLabels == mode,
                  onTap: () => set(p.copyWith(deliveryLabels: mode)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Debug details for unsupported messages',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final mode in UnsupportedDetailMode.values)
                _ChoiceTile(
                  label: _detailLabel(mode),
                  selected: p.unsupportedDetails == mode,
                  onTap: () => set(p.copyWith(unsupportedDetails: mode)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _deliveryLabel(DeliveryLabelMode m) {
    switch (m) {
      case DeliveryLabelMode.off:
        return 'Off';
      case DeliveryLabelMode.compact:
        return 'Compact (latest outgoing only)';
      case DeliveryLabelMode.detailed:
        return 'Detailed (every outgoing message)';
    }
  }

  String _detailLabel(UnsupportedDetailMode m) {
    switch (m) {
      case UnsupportedDetailMode.off:
        return 'Off';
      case UnsupportedDetailMode.debugOnly:
        return 'Debug only (tap to inspect)';
      case UnsupportedDetailMode.always:
        return 'Always show details';
    }
  }
}

/// A single-select list row (avoids the deprecated RadioListTile API).
class _ChoiceTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(label),
      onTap: onTap,
      trailing: selected
          ? Icon(Icons.check, color: scheme.primary)
          : const SizedBox(width: 24),
    );
  }
}
