import 'package:flutter/material.dart';

import 'models/chat_summary.dart';

/// Placeholder thread screen (C1). Message history/sending arrive in a later
/// phase; for now it confirms the selected chat and its GUID.
class ChatThreadPlaceholderScreen extends StatelessWidget {
  final ChatSummary chat;

  const ChatThreadPlaceholderScreen({super.key, required this.chat});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (chat.serviceName != null)
              Text(chat.serviceName!,
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined, size: 56, color: scheme.primary),
              const SizedBox(height: 16),
              Text('Messages will appear here in the next phase.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SelectableText(
                'Chat GUID:\n${chat.guid}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
