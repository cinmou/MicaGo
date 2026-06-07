import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../contacts/contacts_service.dart';
import 'chat_list_controller.dart';
import 'message_thread_screen.dart';
import 'models/chat_summary.dart';

/// The Chats tab: loads `GET /api/chats` and shows loading/empty/error/loaded
/// states with pull-to-refresh. Material 3 list rows (no iMessage styling).
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  late final ChatListController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ChatListController(context.read<AppController>());
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openThread(ChatSummary chat) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MessageThreadScreen(chat: chat),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        switch (_controller.state) {
          case ChatListState.idle:
          case ChatListState.loading:
            return const Center(child: CircularProgressIndicator());
          case ChatListState.error:
            return _ErrorState(
              message: _controller.error ?? 'Failed to load chats.',
              onRetry: () => _controller.load(),
            );
          case ChatListState.empty:
            return RefreshIndicator(
              onRefresh: () => _controller.load(showSpinner: false),
              child: const _EmptyState(),
            );
          case ChatListState.loaded:
            return RefreshIndicator(
              onRefresh: () => _controller.load(showSpinner: false),
              child: ListView.separated(
                itemCount: _controller.chats.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 72),
                itemBuilder: (context, i) => _ChatRow(
                  chat: _controller.chats[i],
                  onTap: () => _openThread(_controller.chats[i]),
                ),
              ),
            );
        }
      },
    );
  }
}

class _ChatRow extends StatelessWidget {
  final ChatSummary chat;
  final VoidCallback onTap;

  const _ChatRow({required this.chat, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Prefer a local contact name (1:1) when contacts matching is enabled.
    final contacts = context.watch<ContactsService>();
    final resolvedName = (!chat.isGroup)
        ? contacts.displayNameFor(chat.chatIdentifier)
        : null;
    final title = (resolvedName != null && resolvedName.isNotEmpty)
        ? resolvedName
        : chat.title;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: chat.isGroup
            ? const Icon(Icons.group)
            : Text(chat.initials, style: const TextStyle(fontSize: 14)),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: chat.hasUnread ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          if (chat.isArchived) ...[
            const SizedBox(width: 6),
            Icon(Icons.archive_outlined,
                size: 14, color: scheme.onSurfaceVariant),
          ],
        ],
      ),
      // Last-message preview is shown only if the server provides it; today's
      // server does not, so fall back to the service/identifier subtitle.
      subtitle: Text(
        _subtitle(chat),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _trailing(context, chat),
    );
  }

  String _subtitle(ChatSummary chat) {
    final preview = chat.lastMessagePreview?.trim() ?? '';
    if (preview.isNotEmpty) return preview;
    final parts = <String>[
      if (chat.serviceName != null && chat.serviceName!.isNotEmpty)
        chat.serviceName!,
      if (chat.isGroup) 'Group',
    ];
    if (parts.isEmpty && chat.chatIdentifier != null) {
      return chat.chatIdentifier!;
    }
    return parts.join(' · ');
  }

  Widget? _trailing(BuildContext context, ChatSummary chat) {
    final scheme = Theme.of(context).colorScheme;
    if (chat.hasUnread) {
      return Badge(label: Text('${chat.unreadCount}'));
    }
    if (chat.lastMessageAt != null) {
      return Text(
        _relativeTime(chat.lastMessageAt!),
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    return null;
  }

  String _relativeTime(int unixMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixMs);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.25),
        const Icon(Icons.chat_bubble_outline, size: 56),
        const SizedBox(height: 12),
        const Center(child: Text('No chats yet')),
        const SizedBox(height: 4),
        Center(
          child: Text(
            'Pull down to refresh.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
