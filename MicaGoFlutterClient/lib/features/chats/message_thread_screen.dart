import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../contacts/contacts_service.dart';
import 'attachment_views.dart';
import 'avatar.dart';
import 'chat_service.dart';
import '../settings/message_display_controller.dart';
import 'diagnostics_store.dart';
import 'message_debug_sheet.dart';
import 'message_display.dart';
import 'message_render.dart';
import 'models/chat_summary.dart';
import 'models/message_model.dart';
import 'store/thread_presentation.dart';
import 'thread_controller.dart';

/// Real message thread (C2): history, attachments, optimistic text send, and
/// realtime updates. Clean Material chat UI — not an iMessage clone.
class MessageThreadScreen extends StatefulWidget {
  final ChatSummary chat;

  /// When true, render as a detail pane (slim header, no Scaffold/back button)
  /// for the two-pane tablet layout.
  final bool embedded;

  const MessageThreadScreen({
    super.key,
    required this.chat,
    this.embedded = false,
  });

  @override
  State<MessageThreadScreen> createState() => _MessageThreadScreenState();
}

class _MessageThreadScreenState extends State<MessageThreadScreen> {
  late final ThreadController _controller;
  final _scroll = ScrollController();
  final _composer = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = ThreadController(
      app: context.read<AppController>(),
      chatGuid: widget.chat.guid,
    )..start();
    _composer.addListener(() => setState(() {}));
    _scroll.addListener(_onScroll);
    _controller.addListener(_publishDiagnostics);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _controller.removeListener(_publishDiagnostics);
    _controller.dispose();
    _scroll.dispose();
    _composer.dispose();
    super.dispose();
  }

  // Recompute per-thread compatibility diagnostics whenever the message list
  // changes, so the Settings → Message Compatibility Diagnostics page reflects
  // the open thread. Done after the frame to avoid notifying during build.
  void _publishDiagnostics() {
    final msgs = _controller.messages;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      lastThreadDiagnostics.value = computeThreadDiagnostics(msgs);
    });
  }

  // The list is reversed (newest at the bottom), so the *top* of the history is
  // near maxScrollExtent. Load older pages as the user approaches it.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 320) {
      _controller.loadOlder();
    }
  }

  void _send() {
    // Server-authoritative gate: only iMessage conversations are sendable.
    if (!_effectiveService.canSend) return;
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

  /// Server-authoritative service for this thread. The newest server message's
  /// service wins (chat.db chat rows can carry a stale service_name); the chat
  /// row is only the fallback when no message states one. Never guessed from
  /// the GUID/handle/phone shape.
  ChatService get _effectiveService {
    final fromMessages = _controller.serviceFromMessages;
    if (fromMessages != ChatService.unknown) return fromMessages;
    return widget.chat.service;
  }

  /// Header badge text, e.g. "iMessage", "SMS · Read only", "Unknown · Read only".
  String get _serviceBadge {
    final s = _effectiveService;
    return s.canSend ? s.label : '${s.label} · Read only';
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsService>();
    final prefs = context.watch<MessageDisplayController>().prefs;
    final api = context.read<AppController>().api;

    final title = _resolveTitle(contacts);

    final content = Column(
      children: [
        Expanded(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _buildBody(context, api, contacts, prefs),
          ),
        ),
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => _Composer(
            controller: _composer,
            service: _effectiveService,
            canSend: _composer.text.trim().isNotEmpty,
            onSend: _send,
          ),
        ),
      ],
    );

    final titleRow = Row(
      children: [
        HandleAvatar(
          title: title,
          handle: widget.chat.isGroup ? null : widget.chat.chatIdentifier,
          isGroup: widget.chat.isGroup,
          radius: 16,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => Text(
                  _serviceBadge,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.embedded) {
      // Detail pane: slim header instead of an AppBar (the shell owns the bar).
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                Expanded(child: titleRow),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _controller.load(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: content),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: titleRow,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.load(),
          ),
        ],
      ),
      body: content,
    );
  }

  Widget _buildBody(
    BuildContext context,
    ApiClient? api,
    ContactsService contacts,
    MessageDisplayPrefs prefs,
  ) {
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
        // Precompute the entire view-item list ONCE (classification, labels,
        // reply previews, reactions, effects, delivery visibility, date
        // separators). The hot itemBuilder below only renders.
        final items = ThreadPresentationBuilder.build(
          messages: _controller.messages,
          prefs: prefs,
          isGroup: widget.chat.isGroup,
          resolveName: contacts.displayNameFor,
          loadingOlder: _controller.loadingOlder,
        );
        // Reversed list: newest at the bottom; prepending older history (top)
        // does not shift the viewport, so scroll position is preserved.
        return ListView.builder(
          controller: _scroll,
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[items.length - 1 - i];
            return KeyedSubtree(
              key: ValueKey(item.key),
              child: _buildRow(context, item, api),
            );
          },
        );
    }
  }

  Widget _buildRow(BuildContext context, ThreadViewItem item, ApiClient? api) {
    if (item is DateSeparatorItem) {
      return _DateSeparator(label: item.label);
    }
    if (item is LoadingOlderItem) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final m = item as MessageViewItem;
    if (m.isSystem) {
      return _SystemRow(
        message: m.message,
        baseLabel: m.systemLabel ?? 'Unsupported message',
        mergedCount: m.mergedSystemCount,
        isUnknown: m.kind == MessageRenderableKind.unknown,
        onDebug: () => showMessageDebugSheet(context, m.message),
      );
    }
    // Wrap media-bearing bubbles in a RepaintBoundary so image decode/paint
    // doesn't invalidate neighbouring rows during scroll.
    final bubble = _MessageBubble(
      message: m.message,
      api: api,
      senderName: m.senderLabel,
      body: m.body,
      reactions: m.reactions,
      reply: m.reply,
      effectHint: m.effectHint,
      showStatus: m.showStatus,
      onRetry: () {
        final t = m.message.tempId;
        if (t != null) _controller.retry(t);
      },
      onDebug: () => showMessageDebugSheet(context, m.message),
    );
    return m.message.hasAttachments ? RepaintBoundary(child: bubble) : bubble;
  }
}

class _DateSeparator extends StatelessWidget {
  final String label;
  const _DateSeparator({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final MessageModel message;
  final ApiClient? api;

  /// Precomputed (ThreadPresentationBuilder): sender label (groups only) + body.
  final String? senderName;
  final String? body;

  /// Part I: whether to render the delivery-status line.
  final bool showStatus;

  /// Tapbacks merged onto this message (chips), the quoted reply (if any), and
  /// the send-effect hint label (if any).
  final List<MessageModel> reactions;
  final ReplyPreview? reply;
  final String? effectHint;
  final VoidCallback onRetry;
  final VoidCallback onDebug;

  const _MessageBubble({
    required this.message,
    required this.api,
    required this.senderName,
    required this.body,
    required this.showStatus,
    this.reactions = const [],
    this.reply,
    this.effectHint,
    required this.onRetry,
    required this.onDebug,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fromMe = message.isFromMe;
    final bubbleColor = fromMe
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final textColor = fromMe ? scheme.onPrimaryContainer : scheme.onSurface;

    final hasMedia = message.hasAttachments && api != null;
    final images = message.attachments
        .where((a) => a.canRenderInlineImage)
        .toList(growable: false);
    // Local copies so Dart can flow-promote the nullable presentation fields.
    final sender = senderName;
    final bodyText = body;
    final effect = effectHint;

    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: hasMedia && body == null ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(fromMe ? 16 : 4),
          bottomRight: Radius.circular(fromMe ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: fromMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (sender != null && sender.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                sender,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (reply != null) _ReplyPreviewBlock(reply: reply!, fromMe: fromMe),
          if (hasMedia)
            for (final a in message.attachments)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: AttachmentView(
                  api: api!,
                  attachment: a,
                  imageSiblings: images,
                  imageIndex: a.canRenderInlineImage ? images.indexOf(a) : 0,
                ),
              ),
          if (bodyText != null)
            Text(bodyText, style: TextStyle(color: textColor)),
          if (effect != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    effectHint!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          _Footer(message: message, showStatus: showStatus, onRetry: onRetry),
        ],
      ),
    );

    return Align(
      alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: GestureDetector(
          onLongPress: onDebug,
          child: reactions.isEmpty
              ? bubble
              : Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: bubble,
                    ),
                    Positioned(
                      top: -4,
                      right: fromMe ? null : 4,
                      left: fromMe ? 4 : null,
                      child: _ReactionChips(reactions: reactions),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Compact reaction chips overlaid on the target bubble (merged tapbacks).
class _ReactionChips extends StatelessWidget {
  final List<MessageModel> reactions;
  const _ReactionChips({required this.reactions});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Latest reaction per sender, additions only (skip the -removed variants).
    final byHandle = <String, TapbackKind>{};
    for (final r in reactions) {
      final t = tapbackFromCode(r.associatedMessageType);
      if (t == null) continue;
      final key = r.isFromMe ? 'me' : (r.handleId ?? 'unknown');
      if (t.isRemoval) {
        byHandle.remove(key);
      } else {
        byHandle[key] = t.kind;
      }
    }
    if (byHandle.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        byHandle.values.map((k) => tapbackEmoji(k)).join(' '),
        style: const TextStyle(fontSize: 11),
      ),
    );
  }
}

/// Quoted reply preview shown above the message body.
class _ReplyPreviewBlock extends StatelessWidget {
  final ReplyPreview reply;
  final bool fromMe;
  const _ReplyPreviewBlock({required this.reply, required this.fromMe});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = reply.targetLoaded
        ? (reply.text ?? 'Attachment')
        : 'Replying to a message';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reply.targetLoaded && reply.sender.isNotEmpty)
            Text(
              reply.sender,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// A subtle, centered row for service/system/unknown items — never a broken
/// bubble. Tap opens the Message Debug inspector (Part A) so we can see why an
/// item is unsupported, without dumping raw payloads into the conversation.
class _SystemRow extends StatelessWidget {
  final MessageModel message;

  /// Precomputed (ThreadPresentationBuilder): the row label, merge count, and
  /// whether this is an unsupported/unknown row.
  final String baseLabel;
  final int mergedCount;
  final bool isUnknown;
  final VoidCallback onDebug;
  const _SystemRow({
    required this.message,
    required this.baseLabel,
    this.mergedCount = 1,
    required this.isUnknown,
    required this.onDebug,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // When consecutive system rows were merged, show a compact count.
    final label = mergedCount > 1
        ? '$baseLabel · +${mergedCount - 1} more'
        : baseLabel;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
      child: Center(
        child: InkWell(
          onTap: onDebug,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isUnknown)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.help_outline,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontStyle: isUnknown
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final MessageModel message;

  /// Whether to render a delivery-status word (latest outgoing only, Part I).
  final bool showStatus;
  final VoidCallback onRetry;
  const _Footer({
    required this.message,
    required this.showStatus,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.labelSmall;
    final state = deliveryStateFor(message);

    // Failed is always actionable, regardless of position.
    if (state == MessageDeliveryState.failed) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: GestureDetector(
          onTap: onRetry,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 13, color: scheme.error),
              const SizedBox(width: 4),
              Text(
                'Failed — tap to retry',
                style: small?.copyWith(color: scheme.error),
              ),
            ],
          ),
        ),
      );
    }

    final parts = <String>[];
    final ts = message.dateCreated;
    if (ts != null) parts.add(_time(ts));
    final edited = editedMarker(message);
    if (edited != null) parts.add(edited);
    // Status word is outgoing-only, shown only on the latest outgoing message.
    if (showStatus) {
      switch (state) {
        case MessageDeliveryState.sending:
          parts.add('Sending…');
          break;
        case MessageDeliveryState.sent:
          parts.add('Sent');
          break;
        case MessageDeliveryState.read:
          parts.add('Read');
          break;
        case MessageDeliveryState.delivered:
          parts.add('Delivered');
          break;
        case MessageDeliveryState.incoming:
        case MessageDeliveryState.failed:
        case MessageDeliveryState.unknown:
          break;
      }
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        parts.join(' · '),
        style: small?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }

  String _time(int unixMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixMs);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final ChatService service;
  final bool canSend;
  final VoidCallback onSend;

  const _Composer({
    required this.controller,
    required this.service,
    required this.canSend,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Sending is only supported on iMessage (server AppleScript pipeline).
    // SMS/RCS/unknown conversations are readable but read-only: show a label
    // instead of an enabled composer, per the server-authoritative service.
    if (!service.canSend) {
      return SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Text(
                '${service.label} · Read only',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ],
          ),
        ),
      );
    }

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
