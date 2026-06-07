import 'package:flutter/material.dart';

import '../../core/network/websocket_client.dart';

/// A collapsible debug panel showing the WebSocket connection state and a
/// rolling log of received event names. Read-only; for C0 diagnostics.
class DebugLogPanel extends StatelessWidget {
  final WebSocketClient ws;

  const DebugLogPanel({super.key, required this.ws});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ws,
      builder: (context, _) {
        final entries = ws.log.reversed.toList(growable: false);
        return Card(
          child: ExpansionTile(
            shape: const Border(),
            collapsedShape: const Border(),
            leading: const Icon(Icons.terminal),
            title: const Text('Debug — WebSocket events'),
            subtitle: Text('${ws.status.name} · ${ws.log.length} logged'),
            childrenPadding:
                const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: ws.log.isEmpty ? null : ws.clearLog,
                  icon: const Icon(Icons.clear_all, size: 18),
                  label: const Text('Clear'),
                ),
              ),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No events yet.'),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${_ts(e.at)}  ${e.text}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _ts(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
