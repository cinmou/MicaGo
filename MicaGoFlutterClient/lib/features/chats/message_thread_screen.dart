import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../../core/ui/top_banner.dart';
import 'package:photo_manager/photo_manager.dart';

import '../contacts/contacts_service.dart';
import 'attachment_panel.dart';
import 'attachment_views.dart';
import 'avatar.dart';
import 'chat_service.dart';
import '../settings/message_display_controller.dart';
import 'diagnostics_store.dart';
import 'message_debug_sheet.dart';
import 'message_display.dart';
import 'message_render.dart';
import 'models/chat_summary.dart';
import 'models/merged_chat.dart';
import 'models/message_model.dart';
import 'store/thread_presentation.dart';
import 'thread_controller.dart';

/// Real message thread (C2): history, attachments, optimistic text send, and
/// realtime updates. Clean Material chat UI — not an iMessage clone.
///
/// C21: the screen is opened on a [MergedChat] — a contact-level conversation
/// that may have several real server chats ("routes": iMessage, SMS, …). The
/// thread shows one route at a time (the active route's real `chat.guid`); a
/// route selector in the header switches between them. Sends always target the
/// active route's real GUID with its server-authoritative send capabilities.
class MessageThreadScreen extends StatefulWidget {
  final MergedChat merged;

  /// When true, render as a detail pane (slim header, no Scaffold/back button)
  /// for the two-pane tablet layout.
  final bool embedded;

  const MessageThreadScreen({
    super.key,
    required this.merged,
    this.embedded = false,
  });

  @override
  State<MessageThreadScreen> createState() => _MessageThreadScreenState();
}

class _MessageThreadScreenState extends State<MessageThreadScreen> {
  late ThreadController _controller;
  final _scroll = ScrollController();
  final _composer = TextEditingController();

  /// The real server chat currently being viewed/sent on. Defaults to the
  /// merged conversation's preferred route (iMessage first); switchable when the
  /// contact has more than one route.
  late ChatSummary _active;

  @override
  void initState() {
    super.initState();
    _active = widget.merged.primary;
    _controller = ThreadController(
      app: context.read<AppController>(),
      chatGuid: _active.guid,
    )..start();
    _composer.addListener(() => setState(() {}));
    _scroll.addListener(_onScroll);
    _controller.addListener(_publishDiagnostics);
  }

  // C21: switch the active send/view route. The thread is bound to a single
  // chat GUID, so we tear down the controller and rebuild it on the new route's
  // real GUID. Staged attachments carry over; the composer text is preserved.
  void _switchRoute(ChatSummary route) {
    if (route.guid == _active.guid) return;
    _controller.removeListener(_publishDiagnostics);
    _controller.dispose();
    setState(() {
      _active = route;
      _controller = ThreadController(
        app: context.read<AppController>(),
        chatGuid: route.guid,
      )..start();
      _controller.addListener(_publishDiagnostics);
    });
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

  // C21c: staged attachments selected via the BlueBubbles-style panel, sent on
  // the next Send. The + toggles the panel instead of opening a picker directly.
  bool _attachOpen = false;
  final List<StagedAttachment> _staged = [];

  void _toggleAttachPanel() {
    if (!_canSendAttachments) return;
    setState(() => _attachOpen = !_attachOpen);
  }

  void _onPicked(List<StagedAttachment> picked) {
    setState(() {
      _staged.addAll(picked);
      _attachOpen = false; // collapse the panel; show the staged strip
    });
  }

  // Toggle a gallery asset in/out of the staged selection (multi-select), like
  // BlueBubbles' tap-to-select. Keeps the panel open so more can be selected.
  Future<void> _toggleAsset(AssetEntity asset) async {
    final existing = _staged.indexWhere((s) => s.sourceId == asset.id);
    if (existing >= 0) {
      setState(() => _staged.removeAt(existing));
      return;
    }
    final bytes = await asset.originBytes;
    if (bytes == null) return;
    final name = await asset.titleAsync;
    if (!mounted) return;
    setState(() {
      _staged.add(StagedAttachment(
        bytes: bytes,
        filename: name.isNotEmpty ? name : '${asset.id}.jpg',
        sourceId: asset.id,
      ));
    });
  }

  void _removeStaged(int index) {
    setState(() => _staged.removeAt(index));
  }

  // Send staged attachments (multi) and/or text. Gated by the server's explicit
  // capabilities; the server is the final authority.
  Future<void> _send() async {
    final text = _composer.text.trim();
    final staged = List<StagedAttachment>.from(_staged);
    if (staged.isNotEmpty && _canSendAttachments) {
      setState(() => _staged.clear());
      await _controller.sendAttachments(staged);
      if (mounted) _showAttachErrorIfAny();
    }
    if (text.isNotEmpty && _canSendText) {
      _controller.send(text);
      _composer.clear();
    }
  }

  // C21: voice is a UI affordance only for now — recording is not implemented,
  // so rather than ship a half-working recorder we clearly tell the user it's
  // not available yet (the send path for audio would reuse sendAttachments).
  void _onVoiceAffordance() {
    TopBanner.show(context, 'Voice messages aren’t available yet.');
  }

  void _showAttachErrorIfAny() {
    final err = _controller.attachmentError;
    if (err != null) {
      TopBanner.show(
        context,
        'Attachment failed: $err',
        kind: TopBannerKind.error,
      );
      _controller.clearAttachmentError();
    }
  }

  String _resolveTitle(ContactsService contacts) {
    if (!_active.isGroup) {
      final name = contacts.displayNameFor(_active.chatIdentifier);
      if (name != null && name.isNotEmpty) return name;
    }
    return _active.title;
  }

  /// Server-authoritative service for this thread. The chat row is the
  /// conversation authority for UI behavior. Never guessed from the
  /// GUID/handle/phone shape.
  ChatService get _effectiveService => _active.service;

  /// Whether text can be sent right now — the server's explicit capability
  /// (C21c), no client inference. Same source drives the composer + retry.
  bool get _canSendText =>
      _active.canSendText(allowSmsSend: context.read<AppController>().allowSmsSend);

  /// Whether attachments can be sent right now — the server's explicit
  /// capability (same source as text today, separate field for the future).
  bool get _canSendAttachments => _active.canSendAttachments(
    allowSmsSend: context.read<AppController>().allowSmsSend,
  );

  /// Header badge text, e.g. "iMessage", "SMS · Read only", "Unknown · Read only".
  String _serviceBadge(bool canSend) {
    final s = _effectiveService;
    return canSend ? s.label : '${s.label} · Read only';
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsService>();
    final prefs = context.watch<MessageDisplayController>().prefs;
    final app = context.watch<AppController>();
    final api = app.api;
    // Server-explicit capability (C21c) — same source as the send gates;
    // rebuilds when the SMS-send setting changes.
    final canSend = _active.canSendText(allowSmsSend: app.allowSmsSend);

    final title = _resolveTitle(contacts);

    final content = Column(
      children: [
        Expanded(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _buildBody(context, api, contacts, prefs),
          ),
        ),
        if (_staged.isNotEmpty)
          StagedAttachmentStrip(items: _staged, onRemove: _removeStaged),
        // C21: animate the attachment panel open/close instead of snapping.
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
          child: _attachOpen
              ? AttachmentPanel(
                  selectedAssetIds: _staged
                      .map((s) => s.sourceId)
                      .whereType<String>()
                      .toSet(),
                  onToggleAsset: _toggleAsset,
                  onPicked: _onPicked,
                  onError: (msg) {
                    if (mounted) {
                      TopBanner.show(context, msg, kind: TopBannerKind.error);
                    }
                  },
                )
              : const SizedBox(width: double.infinity),
        ),
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => _Composer(
            controller: _composer,
            service: _effectiveService,
            serviceCanSend: canSend,
            // Send is enabled when there's text OR staged attachments.
            canSend:
                _composer.text.trim().isNotEmpty || _staged.isNotEmpty,
            onSend: _send,
            attachmentSending: _controller.attachmentSending,
            attachOpen: _attachOpen,
            onAttach: _toggleAttachPanel,
            onVoice: _onVoiceAffordance,
          ),
        ),
      ],
    );

    final titleRow = Row(
      children: [
        HandleAvatar(
          title: title,
          handle: _active.isGroup ? null : _active.chatIdentifier,
          isGroup: _active.isGroup,
          radius: 16,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                _serviceBadge(canSend),
                style: Theme.of(context).textTheme.bodySmall,
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
                ?_routeSelector(context),
                IconButton(
                  tooltip: 'Details & search',
                  icon: const Icon(Icons.search),
                  onPressed: _openDetailsSearch,
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
          ?_routeSelector(context),
          IconButton(
            tooltip: 'Details & search',
            icon: const Icon(Icons.search),
            onPressed: _openDetailsSearch,
          ),
        ],
      ),
      body: content,
    );
  }

  // C21u: the top-right action now opens chat details + in-thread search
  // instead of being a bare refresh. Manual refresh still lives inside the
  // sheet (and the thread already auto-refreshes via WS + delta catch-up).
  void _openDetailsSearch() {
    final contacts = context.read<ContactsService>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ThreadDetailsSheet(
        title: _resolveTitle(contacts),
        merged: widget.merged,
        active: _active,
        messages: _controller.messages,
        resolveName: contacts.displayNameFor,
        onRefresh: () => _controller.load(),
      ),
    );
  }

  // C21: route selector — only when the contact has more than one real chat
  // (e.g. iMessage + SMS). Picking a route rebinds the thread to that route's
  // real GUID; sends then target it with its own server send capabilities.
  Widget? _routeSelector(BuildContext context) {
    final routes = widget.merged.routes;
    if (routes.length < 2) return null;
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: 'Send route',
      onSelected: (guid) {
        final route = routes.firstWhere((r) => r.guid == guid);
        _switchRoute(route);
      },
      itemBuilder: (context) => [
        for (final r in routes)
          PopupMenuItem<String>(
            value: r.guid,
            child: Row(
              children: [
                Icon(
                  r.guid == _active.guid
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Text(r.service.label),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_horiz, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              _active.service.label,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      ),
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
          isGroup: _active.isGroup,
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
    if (item is TimeSeparatorItem) {
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
      showTimestamp: m.showTimestamp,
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

class _MessageBubble extends StatefulWidget {
  final MessageModel message;
  final ApiClient? api;

  /// Precomputed (ThreadPresentationBuilder): sender label (groups only) + body.
  final String? senderName;
  final String? body;

  /// Part I: whether to render the delivery-status line.
  final bool showStatus;

  /// C21u: whether the footer shows the time by default (the newest message).
  /// Other bubbles reveal their time on tap.
  final bool showTimestamp;

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
    required this.showTimestamp,
    this.reactions = const [],
    this.reply,
    this.effectHint,
    required this.onRetry,
    required this.onDebug,
  });

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  // C21u: tap-to-reveal this bubble's timestamp (BlueBubbles-style). Long-press
  // is reserved for the Message Inspector and is untouched.
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final api = widget.api;
    final reactions = widget.reactions;
    final reply = widget.reply;
    final effectHint = widget.effectHint;
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
    final sender = widget.senderName;
    final bodyText = widget.body;
    final effect = effectHint;

    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: hasMedia && bodyText == null ? 6 : 8,
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
          if (reply != null) _ReplyPreviewBlock(reply: reply, fromMe: fromMe),
          if (hasMedia)
            for (final a in message.attachments)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: AttachmentView(
                  api: api,
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
                    effect,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          _Footer(
            message: message,
            showStatus: widget.showStatus,
            showTime: widget.showTimestamp || _revealed,
            onRetry: widget.onRetry,
          ),
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
          onTap: () => setState(() => _revealed = !_revealed),
          onLongPress: widget.onDebug,
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

  /// C21u: whether to render the timestamp. The thread no longer shows a time
  /// under every bubble — only the newest message and tap-revealed bubbles do.
  final bool showTime;
  final VoidCallback onRetry;
  const _Footer({
    required this.message,
    required this.showStatus,
    required this.showTime,
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
    // Only show the time when grouping/tap asks for it (BlueBubbles-style).
    if (ts != null && showTime) parts.add(_time(ts));
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

/// C21u composer: a **floating capsule** bar (not a full-width bottom bar) with
/// `+` on the left, a themed "Message" capsule in the centre (voice inside when
/// idle/empty, emoji when focused), and a send button outside on the right.
/// Colors come from the Material scheme (surface / surfaceContainer / onSurface)
/// so dark mode stays dark and light mode stays light. The emoji button opens a
/// small native inline emoji picker that inserts at the cursor. Small animations
/// cover the capsule float/focus and the voice↔emoji swap.
class _Composer extends StatefulWidget {
  final TextEditingController controller;
  final ChatService service;
  // Whether this service is sendable (iMessage, or SMS when the server setting
  // is on). Read-only services show a label instead of an enabled composer.
  final bool serviceCanSend;
  final bool canSend;
  final VoidCallback onSend;
  final bool attachmentSending;
  final bool attachOpen;
  final VoidCallback onAttach;
  final VoidCallback onVoice;

  const _Composer({
    required this.controller,
    required this.service,
    required this.serviceCanSend,
    required this.canSend,
    required this.onSend,
    required this.attachmentSending,
    required this.attachOpen,
    required this.onAttach,
    required this.onVoice,
  });

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final FocusNode _focus = FocusNode();
  bool _emojiOpen = false;

  // A small, native set of common emoji for the inline picker (no plugin).
  static const _emoji = <String>[
    '😀', '😂', '🥰', '😍', '😊', '😉', '😎', '🤔',
    '😅', '😭', '😡', '👍', '👎', '🙏', '👏', '🙌',
    '🔥', '🎉', '❤️', '💔', '✅', '❌', '💯', '🤝',
    '😴', '🤯', '🥳', '😇', '🤷', '👀', '💪', '☕',
  ];

  @override
  void initState() {
    super.initState();
    // Rebuild on focus change so the voice↔emoji swap animates.
    _focus.addListener(() {
      // Closing the keyboard also closes the inline emoji picker.
      if (!_focus.hasFocus && _emojiOpen) _emojiOpen = false;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // Emoji button action: toggle the inline picker. We keep the field focused so
  // the swap state (emoji vs voice) and selection are preserved — a real,
  // crash-free action that works on every platform without a plugin.
  void _toggleEmoji() {
    _focus.requestFocus();
    setState(() => _emojiOpen = !_emojiOpen);
  }

  // Insert an emoji at the current cursor position (or append).
  void _insertEmoji(String emoji) {
    final c = widget.controller;
    final sel = c.selection;
    final text = c.text;
    if (sel.isValid && sel.start >= 0) {
      final newText = text.replaceRange(sel.start, sel.end, emoji);
      c.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + emoji.length),
      );
    } else {
      c.text = text + emoji;
      c.selection = TextSelection.collapsed(offset: c.text.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // SMS/RCS/unknown (and SMS when the server setting is off) are readable but
    // read-only: show a label instead of an enabled composer, per the
    // server-authoritative service + setting.
    if (!widget.serviceCanSend) {
      return SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Text(
                '${widget.service.label} · Read only',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    // Theme-derived colors only (no hardcoded inverted colors): the message
    // capsule uses a subtle elevated surface fill so it reads correctly in both
    // light and dark mode.
    final capsuleColor = scheme.surfaceContainerHighest;
    final onCapsule = scheme.onSurface;
    final hintColor = scheme.onSurfaceVariant;
    // Show the emoji button while the field is focused; otherwise voice.
    final showEmoji = _focus.hasFocus;

    final bar = Container(
      // A floating capsule: horizontal margin so it doesn't span edge-to-edge,
      // its own rounded surface, and a soft shadow to lift it off the list.
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Left: + only — toggles the attachment panel. The icon morphs
          // between + and × as the panel opens/closes.
          widget.attachmentSending
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  onPressed: widget.onAttach,
                  tooltip: 'Attachments',
                  color: scheme.onSurfaceVariant,
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: Icon(
                      widget.attachOpen ? Icons.close : Icons.add,
                      key: ValueKey(widget.attachOpen),
                    ),
                  ),
                ),
          // Centre: the "Message" capsule with the voice/emoji button inside.
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding: const EdgeInsets.only(left: 16, right: 4),
              decoration: BoxDecoration(
                color: capsuleColor,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _focus.hasFocus ? scheme.primary : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 5,
                      style: TextStyle(color: onCapsule),
                      cursorColor: scheme.primary,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        hintStyle: TextStyle(color: hintColor),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  // Inside-capsule trailing button: emoji when focused, voice
                  // when idle/empty — swapped with a scale+fade animation.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: showEmoji
                        ? IconButton(
                            key: const ValueKey('emoji'),
                            tooltip: 'Emoji',
                            visualDensity: VisualDensity.compact,
                            color: _emojiOpen
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                            icon: const Icon(
                              Icons.emoji_emotions_outlined,
                              size: 22,
                            ),
                            onPressed: _toggleEmoji,
                          )
                        : IconButton(
                            key: const ValueKey('voice'),
                            tooltip: 'Voice message',
                            visualDensity: VisualDensity.compact,
                            color: scheme.onSurfaceVariant,
                            icon: const Icon(Icons.mic_none, size: 22),
                            onPressed: widget.onVoice,
                          ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Right, outside the capsule: the send button. Scales/fades between
          // enabled and disabled.
          AnimatedScale(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            scale: widget.canSend ? 1.0 : 0.85,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: widget.canSend ? 1.0 : 0.5,
              child: IconButton.filled(
                onPressed: widget.canSend ? widget.onSend : null,
                icon: const Icon(Icons.send),
              ),
            ),
          ),
        ],
      ),
    );

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Inline emoji picker (native, no plugin) — animates open/closed.
          AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            alignment: Alignment.bottomCenter,
            child: _emojiOpen
                ? _EmojiPicker(emoji: _emoji, onPick: _insertEmoji)
                : const SizedBox(width: double.infinity),
          ),
          bar,
        ],
      ),
    );
  }
}

/// Lightweight inline emoji grid — taps insert into the composer at the cursor.
class _EmojiPicker extends StatelessWidget {
  final List<String> emoji;
  final void Function(String emoji) onPick;
  const _EmojiPicker({required this.emoji, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      height: 132,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: GridView.count(
        crossAxisCount: 8,
        physics: const BouncingScrollPhysics(),
        children: [
          for (final e in emoji)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onPick(e),
              child: Center(child: Text(e, style: const TextStyle(fontSize: 22))),
            ),
        ],
      ),
    );
  }
}

/// C21u: chat details + in-thread search, opened from the thread's top-right
/// action. Shows the contact's routes (server-authoritative service per route),
/// a search box that filters this thread's messages, and a manual refresh.
class _ThreadDetailsSheet extends StatefulWidget {
  final String title;
  final MergedChat merged;
  final ChatSummary active;
  final List<MessageModel> messages;
  final String? Function(String? handle) resolveName;
  final VoidCallback onRefresh;

  const _ThreadDetailsSheet({
    required this.title,
    required this.merged,
    required this.active,
    required this.messages,
    required this.resolveName,
    required this.onRefresh,
  });

  @override
  State<_ThreadDetailsSheet> createState() => _ThreadDetailsSheetState();
}

class _ThreadDetailsSheetState extends State<_ThreadDetailsSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    // Newest-first matches whose text contains the query.
    final results = q.isEmpty
        ? const <MessageModel>[]
        : (widget.messages
                  .where((m) => (m.text ?? '').toLowerCase().contains(q))
                  .toList(growable: false)
              ..sort(
                (a, b) => (b.dateCreated ?? 0).compareTo(a.dateCreated ?? 0),
              ));
    final insets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Row(
              children: [
                HandleAvatar(
                  title: widget.title,
                  handle: widget.active.isGroup
                      ? null
                      : widget.active.chatIdentifier,
                  isGroup: widget.active.isGroup,
                  radius: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.active.chatIdentifier != null)
                        Text(
                          widget.active.chatIdentifier!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: () {
                    widget.onRefresh();
                    Navigator.of(context).maybePop();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Routes for this contact (server-authoritative service per route).
            Text('Routes', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            for (final r in widget.merged.routes)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  r.guid == widget.active.guid
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: scheme.primary,
                ),
                title: Text(r.service.label),
                subtitle: r.chatIdentifier != null
                    ? Text(r.chatIdentifier!)
                    : null,
              ),
            const Divider(height: 24),
            TextField(
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search this conversation',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            if (q.isNotEmpty)
              Text(
                results.isEmpty
                    ? 'No matches'
                    : '${results.length} match${results.length == 1 ? '' : 'es'}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            for (final m in results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  m.text ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  _sheetSubtitle(m),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _sheetSubtitle(MessageModel m) {
    final who = m.isFromMe
        ? 'You'
        : (widget.resolveName(m.handleId) ?? m.handleId ?? 'Them');
    final ts = m.dateCreated;
    if (ts == null) return who;
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '$who · ${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
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
