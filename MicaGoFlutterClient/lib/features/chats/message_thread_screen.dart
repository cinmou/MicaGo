import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../contacts/contacts_service.dart';
import 'attachment_views.dart';
import 'models/chat_summary.dart';
import 'models/message_model.dart';
import 'thread_controller.dart';

/// Real message thread (C2): history, attachments, optimistic text send, and
/// realtime updates. Clean Material chat UI — not an iMessage clone.
class MessageThreadScreen extends StatefulWidget {
  final ChatSummary chat;
  const MessageThreadScreen({super.key, required this.chat});

  @override
  State<MessageThreadScreen> createState() => _MessageThreadScreenState();
}

class _MessageThreadScreenState extends State<MessageThreadScreen> {
  late final ThreadController _controller;
  final _scroll = ScrollController();
  final _composer = TextEditingController();
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _controller = ThreadController(
      app: context.read<AppController>(),
      chatGuid: widget.chat.guid,
    )..start();
    _composer.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _maybeScrollToBottom(int count) {
    if (count == _lastCount) return;
    _lastCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _send() {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _controller.send(text);
    _composer.clear();
  }

  String _resolveTitle(ContactsService contacts) {
    if (!widget.chat.isGroup) {
      final name = contacts.displayNameFor(widget.chat.chatIdentifier);
      if (name != null && name.isNotEmpty) return name;
    }
    return widget.chat.title;
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsService>();
    final api = context.read<AppController>().api;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_resolveTitle(contacts),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (widget.chat.serviceName != null)
              Text(widget.chat.serviceName!,
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.load(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => _buildBody(context, api, contacts),
            ),
          ),
          _Composer(
            controller: _composer,
            canSend: _composer.text.trim().isNotEmpty,
            onSend: _send,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
      BuildContext context, ApiClient? api, ContactsService contacts) {
    switch (_controller.state) {
      case ThreadState.loading:
        return const Center(child: CircularProgressIndicator());
      case ThreadState.error:
        return _ErrorState(
          message: _controller.error ?? 'Failed to load messages.',
          onRetry: () => _controller.load(),
        );
      case ThreadState.empty:
        return RefreshIndicator(
          onRefresh: () => _controller.load(showSpinner: false),
          child: ListView(
            children: const [
              SizedBox(height: 120),
              Center(child: Text('No messages yet')),
            ],
          ),
        );
      case ThreadState.loaded:
        final msgs = _controller.messages;
        _maybeScrollToBottom(msgs.length);
        return RefreshIndicator(
          onRefresh: () => _controller.load(showSpinner: false),
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            itemCount: msgs.length,
            itemBuilder: (context, i) => _MessageBubble(
              message: msgs[i],
              api: api,
              isGroup: widget.chat.isGroup,
              contacts: contacts,
              onRetry: () {
                final t = msgs[i].tempId;
                if (t != null) _controller.retry(t);
              },
            ),
          ),
        );
    }
  }
}

class _MessageBubble extends StatelessWidget {
  final MessageModel message;
  final ApiClient? api;
  final bool isGroup;
  final ContactsService contacts;
  final VoidCallback onRetry;

  const _MessageBubble({
    required this.message,
    required this.api,
    required this.isGroup,
    required this.contacts,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fromMe = message.isFromMe;
    final bubbleColor =
        fromMe ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final textColor =
        fromMe ? scheme.onPrimaryContainer : scheme.onSurface;

    final senderName = (!fromMe && isGroup)
        ? (contacts.displayNameFor(message.handleId) ?? message.handleId)
        : null;

    return Align(
      alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment:
                fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (senderName != null && senderName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(senderName,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          )),
                ),
              if (message.hasAttachments && api != null)
                for (final a in message.attachments)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: AttachmentView(api: api!, attachment: a),
                  ),
              if (message.hasText)
                Text(message.text!, style: TextStyle(color: textColor)),
              const SizedBox(height: 2),
              _Footer(message: message, onRetry: onRetry),
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final MessageModel message;
  final VoidCallback onRetry;
  const _Footer({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.labelSmall;

    if (message.localState == LocalSendState.failed) {
      return GestureDetector(
        onTap: onRetry,
        child: Text('Failed — tap to retry',
            style: small?.copyWith(color: scheme.error)),
      );
    }

    final parts = <String>[];
    final ts = message.dateCreated;
    if (ts != null) parts.add(_time(ts));
    if (message.localState == LocalSendState.pending) {
      parts.add('Sending…');
    } else if (message.isFromMe) {
      if (message.isRead) {
        parts.add('Read');
      } else if (message.isDelivered) {
        parts.add('Delivered');
      }
    }
    return Text(parts.join(' · '),
        style: small?.copyWith(color: scheme.onSurfaceVariant));
  }

  String _time(int unixMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixMs);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool canSend;
  final VoidCallback onSend;

  const _Composer({
    required this.controller,
    required this.canSend,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              // The server has no media-send endpoint yet (C2 gap).
              onPressed: null,
              tooltip: 'Attachments are not supported by this server yet',
              icon: const Icon(Icons.add),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  hintText: 'Message',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              onPressed: canSend ? onSend : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
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
