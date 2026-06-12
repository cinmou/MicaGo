import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../contacts/contacts_service.dart';
import '../settings/message_display_controller.dart';
import 'avatar.dart';
import 'chat_list_controller.dart';
import 'chat_service.dart';
import 'models/chat_summary.dart';

/// The chat list: loads `GET /api/chats` and shows loading/empty/error/loaded
/// states with pull-to-refresh. Material 3 list rows (no iMessage styling).
/// Selection is delegated to [onOpen] so the same widget works single-pane
/// (push a thread) and two-pane (select into the detail pane).
class ChatListScreen extends StatefulWidget {
  final void Function(ChatSummary chat) onOpen;
  final String? selectedGuid;

  const ChatListScreen({super.key, required this.onOpen, this.selectedGuid});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  late final ChatListController _controller;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _controller = ChatListController(context.read<AppController>());
    _controller.includeDebug = context
        .read<MessageDisplayController>()
        .prefs
        .showDebugChats;
    _controller.startRealtime();
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  List<ChatSummary> _filtered(
    List<ChatSummary> chats,
    ContactsService contacts,
  ) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return chats;
    return chats
        .where((c) {
          final name = !c.isGroup
              ? contacts.displayNameFor(c.chatIdentifier)
              : null;
          final hay = [
            c.title,
            name ?? '',
            c.chatIdentifier ?? '',
            c.service.label,
            c.lastMessagePreview ?? '',
          ].join(' ').toLowerCase();
          return hay.contains(q);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    // React to the "show debug chats" preference: reloads with/without noise.
    _controller.setIncludeDebug(
      context.watch<MessageDisplayController>().prefs.showDebugChats,
    );
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
            final contacts = context.watch<ContactsService>();
            final chats = _filtered(_controller.chats, contacts);
            return Column(
              children: [
                _SearchField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _controller.load(showSpinner: false),
                    child: chats.isEmpty
                        ? _NoMatches(query: _query)
                        : ListView.separated(
                            itemCount: chats.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1, indent: 72),
                            itemBuilder: (context, i) {
                              final chat = chats[i];
                              return _ChatRow(
                                chat: chat,
                                selected: chat.guid == widget.selectedGuid,
                                onTap: () => widget.onOpen(chat),
                              );
                            },
                          ),
                  ),
                ),
              ],
            );
        }
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SearchBar(
        controller: controller,
        onChanged: onChanged,
        hintText: 'Search chats',
        leading: const Icon(Icons.search),
        trailing: [
          if (controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                controller.clear();
                onChanged('');
              },
            ),
        ],
        elevation: const WidgetStatePropertyAll(0),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  final String query;
  const _NoMatches({required this.query});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.2),
        const Icon(Icons.search_off, size: 48),
        const SizedBox(height: 12),
        Center(child: Text('No chats match "$query"')),
      ],
    );
  }
}

class _ChatRow extends StatelessWidget {
  final ChatSummary chat;
  final bool selected;
  final VoidCallback onTap;

  const _ChatRow({
    required this.chat,
    required this.onTap,
    this.selected = false,
  });

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
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.4),
      leading: HandleAvatar(
        title: title,
        handle: chat.isGroup ? null : chat.chatIdentifier,
        isGroup: chat.isGroup,
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
            Icon(
              Icons.archive_outlined,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
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
    // Server-authoritative service label (normalized), never the raw chat.db
    // string and never guessed from the handle/GUID shape.
    final parts = <String>[
      if (chat.service != ChatService.unknown) chat.service.label,
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
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
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
