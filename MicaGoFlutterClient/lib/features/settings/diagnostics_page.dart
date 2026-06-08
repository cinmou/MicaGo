import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chats/diagnostics_store.dart';
import '../chats/message_render.dart';

/// Settings → "Message Compatibility Diagnostics" (Part J).
///
/// Reads the most recently computed [ThreadDiagnostics] for the open thread and
/// shows how messages classified, why any are unsupported, and a redacted
/// preview of the last unsupported item. "Copy debug report" exports the same,
/// with the bearer token and credentials redacted.
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThreadDiagnostics>(
      valueListenable: lastThreadDiagnostics,
      builder: (context, d, _) {
        if (d.total == 0) {
          return const _Empty();
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Latest open thread',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  _row(context, 'Total messages', '${d.total}'),
                  const Divider(height: 1),
                  _row(context, 'Text', '${d.text}'),
                  _row(context, 'Images', '${d.image}'),
                  _row(context, 'Audio', '${d.audio}'),
                  _row(context, 'Files', '${d.file}'),
                  _row(context, 'Service events', '${d.service}'),
                  _row(context, 'Reactions', '${d.reaction}'),
                  const Divider(height: 1),
                  _row(context, 'Unsupported', '${d.unsupported}',
                      emphasize: d.unsupported > 0),
                ],
              ),
            ),
            if (d.reasons.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Why unsupported',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    for (final e in d.reasons.entries)
                      _row(context, unsupportedReasonLabel(e.key), '${e.value}'),
                  ],
                ),
              ),
            ],
            if (d.lastUnsupported != null) ...[
              const SizedBox(height: 20),
              Text('Last unsupported (redacted)',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    messageDebugJson(d.lastUnsupported!),
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: () {
                Clipboard.setData(
                    ClipboardData(text: threadDiagnosticsReport(d)));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Debug report copied (token redacted)')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy debug report'),
            ),
            const SizedBox(height: 12),
            Text(
              'These counters reflect the last chat thread you opened. Open a '
              'thread to refresh them. Reaction/service counts depend on '
              'server fields the MicaGo server does not expose yet — see the '
              'refactor notes for the required additions.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, String label, String value,
      {bool emphasize = false}) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: Text(
        value,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: emphasize ? scheme.error : null,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insights_outlined,
                size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text(
              'No diagnostics yet.\nOpen a chat thread to analyze its messages.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
