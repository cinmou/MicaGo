import 'package:flutter/material.dart';

import 'chat_list_screen.dart';
import 'message_thread_screen.dart';
import 'models/chat_summary.dart';

/// Responsive Chats surface:
/// - **compact** (phone): single pane — tapping a chat pushes the thread.
/// - **wide** (tablet / desktop): two-pane — chat list on the left, the selected
///   thread on the right, with a clean empty state when nothing is selected.
///
/// The selected chat is held in state, so it survives rotation / window resize.
class ChatsPane extends StatefulWidget {
  const ChatsPane({super.key});

  @override
  State<ChatsPane> createState() => _ChatsPaneState();
}

class _ChatsPaneState extends State<ChatsPane> {
  ChatSummary? _selected;

  static const double _wideBreakpoint = 720;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;

        if (!wide) {
          return ChatListScreen(
            onOpen: (chat) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MessageThreadScreen(chat: chat),
              ),
            ),
          );
        }

        return Row(
          children: [
            SizedBox(
              width: 360,
              child: ChatListScreen(
                selectedGuid: _selected?.guid,
                onOpen: (chat) => setState(() => _selected = chat),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: _selected == null
                  ? const _NoSelection()
                  : MessageThreadScreen(
                      key: ValueKey(_selected!.guid),
                      chat: _selected!,
                      embedded: true,
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text('Select a chat',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
