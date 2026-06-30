import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import 'realtime_event_helpers.dart' as rt;
import '../../core/theme_controller.dart';
import '../../core/ui/top_banner.dart';
import 'package:photo_manager/photo_manager.dart';

import '../contacts/contacts_service.dart';
import 'attachment_panel.dart';
import 'attachment_views.dart';
import 'avatar.dart';
import 'chat_service.dart';
import '../settings/message_display_controller.dart';
import 'diagnostics_store.dart';
import 'emoji_text.dart';
import 'message_debug_sheet.dart';
import 'message_display.dart';
import 'message_render.dart';
import 'media_viewer.dart';
import 'models/chat_summary.dart';
import 'models/merged_chat.dart';
import 'models/message_model.dart';
import 'voice_recorder.dart';
import 'route_label.dart';
import 'store/thread_presentation.dart';
import 'url_preview.dart';
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
  final bool flatSplitView;
  final double? embeddedHeaderHeight;

  const MessageThreadScreen({
    super.key,
    required this.merged,
    this.embedded = false,
    this.flatSplitView = false,
    this.embeddedHeaderHeight,
  });

  @override
  State<MessageThreadScreen> createState() => _MessageThreadScreenState();
}

class _MessageThreadScreenState extends State<MessageThreadScreen>
    with WidgetsBindingObserver {
  late ThreadController _controller;
  final _scroll = ScrollController();
  final _composer = TextEditingController();
  final Map<String, GlobalKey> _messageKeys = {};
  bool _showJumpToBottom = false;
  String? _flashGuid;

  // C47: the open thread is the single authority on "the user has seen this
  // conversation". It advances the read watermark for every route on open, on
  // each arriving message (any route), and on resume — while the app is
  // foreground. Ingestion never clears a dot, so this is what makes it clear.
  late Set<String> _routeGuids;
  StreamSubscription<WsEvent>? _seenWsSub;
  StreamSubscription<MessageModel>? _seenDeltaSub;

  /// The real server chat currently being viewed/sent on. Defaults to the
  /// merged conversation's preferred route (iMessage first); switchable when the
  /// contact has more than one route.
  late ChatSummary _active;

  @override
  void initState() {
    super.initState();
    _active = widget.merged.primary;
    _routeGuids = widget.merged.routes.map((r) => r.guid).toSet();
    final app = context.read<AppController>();
    app.setActiveChatGuid(_active.guid);
    WidgetsBinding.instance.addObserver(this);
    // C43/C47: opening a thread is the authoritative read event — advance the
    // read watermark for every route so the unread dot clears, and keep it
    // caught up as messages arrive on any route while the thread is foreground.
    unawaited(app.markChatsViewed(_routeGuids));
    _seenDeltaSub = app.deltaMessages.listen((m) {
      if (m.chatGuid != null && _routeGuids.contains(m.chatGuid)) {
        _markViewedIfForeground(upTo: m.dateCreated);
      }
    });
    _seenWsSub = app.ws.events.listen((e) {
      final guid = rt.chatGuidFromWsEvent(e);
      if (guid != null && _routeGuids.contains(guid)) {
        _markViewedIfForeground(upTo: rt.messageFromWsEvent(e)?.dateCreated);
      }
    });
    _controller = ThreadController(app: app, chatGuid: _active.guid)..start();
    _composer.addListener(() => setState(() {}));
    _scroll.addListener(_onScroll);
    _controller.addListener(_publishDiagnostics);
  }

  /// Advance the read watermark for this contact's routes, but only while the
  /// app is actually in the foreground — a message landing while backgrounded
  /// (even with this thread mounted) must still light the dot (C45/C47).
  void _markViewedIfForeground({int? upTo}) {
    if (!mounted) return;
    final app = context.read<AppController>();
    if (!app.isForeground) return;
    unawaited(app.markChatsViewed(_routeGuids, upTo: upTo));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // C50: close the keyboard before backgrounding. Otherwise a retained focus
      // can leave a stale MediaQuery.viewInsets.bottom on resume — a blank gap
      // above the composer that never collapses until the field is tapped again.
      FocusManager.instance.primaryFocus?.unfocus();
    }
    // Resuming with this thread on screen means the user is now looking at it —
    // catch the watermark up so anything that arrived while backgrounded clears,
    // and recompute the layout so any stale bottom inset is dropped.
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _markViewedIfForeground();
        if (mounted) setState(() {});
      });
    }
  }

  // C21: switch the active send/view route. The thread is bound to a single
  // chat GUID, so we tear down the controller and rebuild it on the new route's
  // real GUID. Staged attachments carry over; the composer text is preserved.
  void _switchRoute(ChatSummary route) {
    if (route.guid == _active.guid) return;
    _controller.removeListener(_publishDiagnostics);
    _controller.dispose();
    final app = context.read<AppController>();
    app.setActiveChatGuid(route.guid);
    unawaited(app.markChatsViewed([route.guid]));
    setState(() {
      _active = route;
      _controller = ThreadController(app: app, chatGuid: route.guid)..start();
      _controller.addListener(_publishDiagnostics);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _seenWsSub?.cancel();
    _seenDeltaSub?.cancel();
    _scroll.removeListener(_onScroll);
    _controller.removeListener(_publishDiagnostics);
    _controller.dispose();
    _scroll.dispose();
    _composer.dispose();
    _recorder.dispose();
    final app = context.read<AppController>();
    if (app.isChatActive(_active.guid)) {
      app.setActiveChatGuid(null);
    }
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
    final showJump = _scroll.position.pixels > 420;
    if (showJump != _showJumpToBottom && mounted) {
      setState(() => _showJumpToBottom = showJump);
    }
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 320) {
      _controller.loadOlder();
    }
  }

  GlobalKey _messageKey(String guid) =>
      _messageKeys.putIfAbsent(guid, GlobalKey.new);

  Future<void> _scrollToBottom() async {
    if (!_scroll.hasClients) return;
    await _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _jumpToMessage(String? guid) async {
    if (guid == null || guid.isEmpty) return;
    final key = _messageKeys[guid];
    final targetContext = key?.currentContext;
    if (targetContext == null) {
      TopBanner.show(context, 'Quoted message is not loaded yet.');
      return;
    }
    await Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0.42,
    );
    if (!mounted) return;
    setState(() => _flashGuid = guid);
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted && _flashGuid == guid) setState(() => _flashGuid = null);
    });
  }

  // C21c: staged attachments selected via the BlueBubbles-style panel, sent on
  // the next Send. The + toggles the panel instead of opening a picker directly.
  bool _attachOpen = false;
  // C24: the emoji panel is now a bottom panel (below the composer), mutually
  // exclusive with the attachment panel.
  bool _emojiOpen = false;
  final List<StagedAttachment> _staged = [];

  void _toggleAttachPanel() {
    if (!_canSendAttachments) return;
    final opening = !_attachOpen;
    if (opening) FocusScope.of(context).unfocus();
    setState(() {
      _attachOpen = opening;
      if (_attachOpen) _emojiOpen = false; // mutually exclusive
    });
  }

  // C24: open/close the bottom emoji panel. Opening it closes the attachment
  // panel and dismisses the keyboard so the panel takes the keyboard's place.
  void _toggleEmojiPanel() {
    final opening = !_emojiOpen;
    if (opening) FocusScope.of(context).unfocus();
    setState(() {
      _emojiOpen = opening;
      if (_emojiOpen) _attachOpen = false;
    });
  }

  // When the user taps into the text field, the keyboard returns — close the
  // bottom panels so they don't overlap.
  void _onInputFocused() {
    if (_emojiOpen || _attachOpen) {
      setState(() {
        _emojiOpen = false;
        _attachOpen = false;
      });
    }
  }

  bool _closeBottomPanelIfOpen() {
    if (!_emojiOpen && !_attachOpen) return false;
    setState(() {
      _emojiOpen = false;
      _attachOpen = false;
    });
    return true;
  }

  // Insert an emoji at the caret (or append), and remember it as a recent.
  void _insertEmoji(String emoji) {
    final sel = _composer.selection;
    final text = _composer.text;
    if (sel.isValid && sel.start >= 0) {
      final newText = text.replaceRange(sel.start, sel.end, emoji);
      _composer.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + emoji.length),
      );
    } else {
      _composer.text = text + emoji;
      _composer.selection = TextSelection.collapsed(
        offset: _composer.text.length,
      );
    }
    EmojiPanel.remember(emoji);
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
      _staged.add(
        StagedAttachment(
          bytes: bytes,
          filename: name.isNotEmpty ? name : '${asset.id}.jpg',
          sourceId: asset.id,
        ),
      );
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

  // C37: voice messages — record to a temp m4a and ship it through the existing
  // send-attachment path. Mic permission is requested on first record.
  final VoiceRecorder _recorder = VoiceRecorder();
  bool _recording = false;
  bool _voiceBusy = false;
  ({Uint8List bytes, String filename})? _pendingVoice;
  Duration _pendingVoiceDuration = Duration.zero;
  List<double> _pendingVoiceLevels = const [];

  Future<void> _startVoice() async {
    if (_recording || _voiceBusy) return;
    if (!_canSendAttachments) {
      TopBanner.show(context, 'Attachments can’t be sent in this chat.');
      return;
    }
    setState(() {
      _voiceBusy = true;
      _pendingVoice = null;
      _pendingVoiceDuration = Duration.zero;
      _pendingVoiceLevels = const [];
    });
    final ok = await _recorder.start();
    if (!mounted) return;
    setState(() {
      _voiceBusy = false;
      _recording = ok;
    });
    if (!ok) {
      TopBanner.show(
        context,
        'Couldn’t start recording — allow microphone access in Android Settings.',
        kind: TopBannerKind.error,
      );
    }
  }

  Future<void> _stopVoiceForReview() async {
    if (!_recording || _voiceBusy) return;
    setState(() => _voiceBusy = true);
    final duration = _recorder.elapsed.value;
    final levels = List<double>.from(_recorder.levels.value);
    final result = await _recorder.stop();
    if (!mounted) return;
    setState(() {
      _voiceBusy = false;
      _recording = false;
      _pendingVoice = result;
      _pendingVoiceDuration = duration;
      _pendingVoiceLevels = levels;
    });
    if (result == null) {
      TopBanner.show(context, 'Recording failed.', kind: TopBannerKind.error);
    }
  }

  Future<void> _sendVoice() async {
    final result = _pendingVoice;
    if (result == null || _voiceBusy) return;
    setState(() => _voiceBusy = true);
    await _controller.sendAttachments([
      StagedAttachment(
        bytes: result.bytes,
        filename: result.filename,
        isAudioMessage: true,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      _voiceBusy = false;
      _pendingVoice = null;
      _pendingVoiceDuration = Duration.zero;
      _pendingVoiceLevels = const [];
    });
    _showAttachErrorIfAny();
  }

  Future<void> _cancelVoice() async {
    if (_recording) {
      await _recorder.cancel();
    }
    if (mounted) {
      setState(() {
        _recording = false;
        _voiceBusy = false;
        _pendingVoice = null;
        _pendingVoiceDuration = Duration.zero;
        _pendingVoiceLevels = const [];
      });
    }
  }

  Future<void> _discardPendingVoice() async {
    if (_voiceBusy) return;
    setState(() {
      _pendingVoice = null;
      _pendingVoiceDuration = Duration.zero;
      _pendingVoiceLevels = const [];
    });
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
  bool get _canSendText => _active.canSendText(
    allowSmsSend: context.read<AppController>().allowSmsSend,
  );

  /// Whether attachments can be sent right now — the server's explicit
  /// capability (same source as text today, separate field for the future).
  bool get _canSendAttachments => _active.canSendAttachments(
    allowSmsSend: context.read<AppController>().allowSmsSend,
  );

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

    final bottomOverlay = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_staged.isNotEmpty)
          StagedAttachmentStrip(items: _staged, onRemove: _removeStaged),
        _recording
            ? _VoiceRecordingBar(
                elapsed: _recorder.elapsed,
                levels: _recorder.levels,
                busy: _voiceBusy,
                onCancel: _cancelVoice,
                onStop: _stopVoiceForReview,
              )
            : _pendingVoice != null
            ? _VoiceReviewBar(
                duration: _pendingVoiceDuration,
                levels: _pendingVoiceLevels,
                busy: _voiceBusy,
                onCancel: _discardPendingVoice,
                onSend: _sendVoice,
              )
            : ListenableBuilder(
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
                  onVoice: _startVoice,
                  emojiOpen: _emojiOpen,
                  onEmoji: _toggleEmojiPanel,
                  onInputFocused: _onInputFocused,
                ),
              ),
        // C21/C24: bottom panels live below the composer, taking the keyboard's
        // place. Opening attachments also dismisses the keyboard.
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
        // C24: emoji panel slides up from the bottom, below the composer —
        // like a keyboard/attachment panel.
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
          child: _emojiOpen
              ? EmojiPanel(onPick: _insertEmoji)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
    final content = Stack(
      children: [
        Positioned.fill(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _buildBody(context, api, contacts, prefs),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          // Keep the jump button above the composer/panel overlay (C50).
          bottom: math.max(94, _bottomInset(context) - 32),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _showJumpToBottom
                  ? _JumpToBottomButton(onTap: _scrollToBottom)
                  : const SizedBox.shrink(),
            ),
          ),
        ),
        Positioned(left: 0, right: 0, bottom: 0, child: bottomOverlay),
      ],
    );
    final headerBg = _accent1_100(Theme.of(context).colorScheme);
    final themedContent = DecoratedBox(
      decoration: BoxDecoration(color: headerBg),
      child: ClipRRect(
        borderRadius: widget.flatSplitView
            ? const BorderRadius.vertical(top: Radius.circular(24))
            : const BorderRadius.vertical(top: Radius.circular(24)),
        child: _ChatBackground(child: content),
      ),
    );

    final titleRow = Row(
      children: [
        HandleAvatar(
          title: title,
          handle: _active.isGroup ? null : _active.chatIdentifier,
          participantHandles: _active.participants,
          isGroup: _active.isGroup,
          radius: 19,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                _lastActivityLabel(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.embedded) {
      // Detail pane: slim header instead of an AppBar (the shell owns the bar).
      return PopScope(
        canPop: !_attachOpen && !_emojiOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _closeBottomPanelIfOpen();
        },
        child: Column(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: headerBg),
              child: SizedBox(
                height: widget.embeddedHeaderHeight ?? 72,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(child: titleRow),
                    ?_routeSelector(context),
                    IconButton(
                      tooltip: 'Details',
                      icon: const Icon(Icons.info_outline),
                      onPressed: _openDetailsSearch,
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
            Expanded(child: themedContent),
          ],
        ),
      );
    }

    return PopScope(
      canPop: !_attachOpen && !_emojiOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeBottomPanelIfOpen();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: headerBg,
          surfaceTintColor: Colors.transparent,
          titleSpacing: 0,
          title: titleRow,
          actions: [
            ?_routeSelector(context),
            IconButton(
              tooltip: 'Details',
              icon: const Icon(Icons.info_outline),
              onPressed: _openDetailsSearch,
            ),
          ],
        ),
        body: themedContent,
      ),
    );
  }

  String _lastActivityLabel() {
    int? ts = _active.lastMessageAt;
    for (final m in _controller.messages) {
      final candidate = m.dateCreated;
      if (candidate != null && (ts == null || candidate > ts)) {
        ts = candidate;
      }
    }
    if (ts == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (sameDay) return _timeOfDay(dt);
    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday =
        dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day;
    if (isYesterday) return 'Yesterday ${_timeOfDay(dt)}';
    return '${dt.month}/${dt.day} ${_timeOfDay(dt)}';
  }

  String _timeOfDay(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // C21u: the top-right action now opens chat details + in-thread search
  // instead of being a bare refresh. Manual refresh still lives inside the
  // sheet (and the thread already auto-refreshes via WS + delta catch-up).
  void _openDetailsSearch() {
    final contacts = context.read<ContactsService>();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ThreadDetailsSheet(
          title: _resolveTitle(contacts),
          merged: widget.merged,
          active: _active,
          messages: _controller.messages,
          resolveName: contacts.displayNameFor,
          api: context.read<AppController>().api,
          onRefresh: () => _controller.load(),
          onLoadOlder: () => _controller.loadOlder(),
          onSwitchRoute: _switchRoute,
          onJumpToMessage: (guid) {
            Navigator.of(context).pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) unawaited(_jumpToMessage(guid));
            });
          },
        ),
      ),
    );
  }

  // C21/C24: route selector — only when the contact has more than one real
  // chat. The label includes the concrete handle/address so two routes on the
  // same service (e.g. two iMessage numbers/emails) are distinguishable. Picking
  // a route rebinds the thread to that route's real GUID; sends target it with
  // its own server-provided send capabilities.
  Widget? _routeSelector(BuildContext context) {
    final routes = widget.merged.routes;
    if (routes.length < 2) return null;
    final scheme = Theme.of(context).colorScheme;
    final allowSms = context.read<AppController>().allowSmsSend;
    return PopupMenuButton<String>(
      tooltip: 'Send route',
      icon: Icon(Icons.swap_horiz, color: scheme.onSurfaceVariant),
      onSelected: (guid) {
        final route = routes.firstWhere((r) => r.guid == guid);
        _switchRoute(route);
      },
      itemBuilder: (context) => [
        for (final r in routes)
          PopupMenuItem<String>(
            value: r.guid,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  r.guid == _active.guid
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(r.service.label),
                      if (routeHandle(r).isNotEmpty)
                        Text(
                          routeHandle(r),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      Text(
                        routeSendabilityLabel(r, allowSmsSend: allowSms),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: r.canSendText(allowSmsSend: allowSms)
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
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
          padding: EdgeInsets.fromLTRB(8, 8, 8, _bottomInset(context)),
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

  // C50: the composer + staged strip + any open panel sit in a bottom overlay
  // stacked over the message list, so the list must reserve matching bottom space
  // or the newest messages hide behind them (and a scroll-to-bottom lands under
  // the panel). Reserve the composer baseline plus whatever is currently open.
  double _bottomInset(BuildContext context) {
    var inset = 104.0; // composer baseline
    if (_staged.isNotEmpty) inset += 72;
    if (_attachOpen) inset += AttachmentPanel.panelHeightFor(context);
    if (_emojiOpen) inset += EmojiPanel.initialHeightFor(context);
    return inset;
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
      showSenderName: m.showSenderName,
      showSenderAvatar: m.showSenderAvatar,
      body: m.body,
      reactions: m.reactions,
      stickers: m.stickers,
      reply: m.reply,
      highlighted: m.message.guid == _flashGuid,
      effectHint: m.effectHint,
      showStatus: m.showStatus,
      showTimestamp: m.showTimestamp,
      showBubbleTail: m.showBubbleTail,
      compactWithPrevious: m.compactWithPrevious,
      compactWithNext: m.compactWithNext,
      onRetry: () {
        final t = m.message.tempId;
        if (t != null) _controller.retry(t);
      },
      onReplyTap: (guid) => _jumpToMessage(guid),
      onActions: (position) => showMessageActionMenu(
        context,
        m.message,
        position,
        chatGuid: _active.guid,
        api: api,
        onRetracted: (guid) => _controller.markRetractedLocally(guid),
        onChanged: () => _controller.load(showSpinner: false),
        onHide: () => _controller.hideMessage(m.message.guid),
      ),
    );
    final keyed = m.message.guid.isEmpty
        ? bubble
        : KeyedSubtree(key: _messageKey(m.message.guid), child: bubble);
    return m.message.hasAttachments ? RepaintBoundary(child: keyed) : keyed;
  }
}

class _JumpToBottomButton extends StatelessWidget {
  final VoidCallback onTap;

  const _JumpToBottomButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(18),
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 4),
              Text(
                'Bottom',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatBackground extends StatelessWidget {
  final Widget child;
  const _ChatBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = context.watch<ThemeController>().chatBackgroundPath;
    if (path == null || path.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(color: _accent1_50(scheme)),
        child: child,
      );
    }

    final file = File(path);
    if (!file.existsSync()) {
      return DecoratedBox(
        decoration: BoxDecoration(color: _accent1_50(scheme)),
        child: child,
      );
    }
    final brightness = Theme.of(context).brightness;
    final overlay = brightness == Brightness.dark
        ? Colors.black.withValues(alpha: 0.38)
        : Colors.white.withValues(alpha: 0.30);

    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(child: Image.file(file, fit: BoxFit.cover)),
        ExcludeSemantics(
          child: DecoratedBox(decoration: BoxDecoration(color: overlay)),
        ),
        child,
      ],
    );
  }
}

Color _accent1_10(ColorScheme scheme) =>
    Color.alphaBlend(scheme.primary.withValues(alpha: 0.06), scheme.surface);

Color _accent1_50(ColorScheme scheme) =>
    Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), scheme.surface);

Color _accent1_100(ColorScheme scheme) => Color.alphaBlend(
  scheme.primary.withValues(alpha: 0.18),
  scheme.surfaceContainerLowest,
);

Color _accent1_500(ColorScheme scheme) => scheme.primary;

Color _accent1_600(ColorScheme scheme) => scheme.primary;

Color _accent1_800(ColorScheme scheme) => scheme.primary;

Color _accent2_600(ColorScheme scheme) => scheme.secondary;

Color _accent2_800(ColorScheme scheme) => Color.alphaBlend(
  scheme.secondary.withValues(alpha: 0.94),
  scheme.surfaceContainerHighest,
);

Color _accent3_500(ColorScheme scheme) => scheme.tertiary;

Color _accent3_600(ColorScheme scheme) => scheme.tertiary;

enum MessageAction { copy, hide, edit, retract, delete }

Future<void> showMessageActionMenu(
  BuildContext context,
  MessageModel message,
  Offset globalPosition, {
  String? chatGuid,
  ApiClient? api,
  void Function(String guid)? onRetracted,
  Future<void> Function()? onChanged,
  Future<void> Function()? onHide,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final text = displayText(message);
  var caps = const MessageActionCapabilities();
  if (api != null) {
    try {
      caps = await api.getMessageActionCapabilities();
    } catch (_) {
      caps = const MessageActionCapabilities();
    }
  }
  if (!context.mounted) return;
  final scheme = Theme.of(context).colorScheme;
  final canMutate =
      api != null &&
      chatGuid != null &&
      chatGuid.isNotEmpty &&
      message.guid.isNotEmpty &&
      !message.guid.startsWith('tmp-') &&
      !message.isRetracted;
  final items = <PopupMenuEntry<MessageAction>>[
    if (text != null)
      const PopupMenuItem<MessageAction>(
        value: MessageAction.copy,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.copy),
          title: Text('Copy'),
        ),
      ),
    if (onHide != null && message.guid.isNotEmpty)
      PopupMenuItem<MessageAction>(
        value: MessageAction.hide,
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.visibility_off_outlined),
          title: Text(MicaLocalizations.of(context).t('chat.hideMessage')),
        ),
      ),
    if (canMutate && caps.edit && message.isFromMe && text != null)
      const PopupMenuItem<MessageAction>(
        value: MessageAction.edit,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.edit_outlined),
          title: Text('Edit'),
        ),
      ),
    if (canMutate && caps.retract && message.isFromMe)
      const PopupMenuItem<MessageAction>(
        value: MessageAction.retract,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.undo),
          title: Text('Undo Send'),
        ),
      ),
    if (canMutate && caps.delete)
      const PopupMenuItem<MessageAction>(
        value: MessageAction.delete,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.delete_outline),
          title: Text('Delete'),
        ),
      ),
  ];
  final selected = await showMenu<MessageAction>(
    context: context,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    color: Color.alphaBlend(
      _accent3_600(scheme).withValues(alpha: 0.08),
      scheme.surface,
    ),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
  if (!context.mounted || selected == null) return;
  switch (selected) {
    case MessageAction.copy:
      if (text == null) return;
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Message copied')));
      break;
    case MessageAction.hide:
      await onHide?.call();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(MicaLocalizations.of(context).t('chat.messageHidden')),
        ),
      );
      break;
    case MessageAction.edit:
      if (api == null || chatGuid == null || text == null) return;
      final edited = await _promptForEditedMessage(context, text);
      if (!context.mounted || edited == null) return;
      await _runMessageAction(
        context,
        () => api.editMessage(chatGuid, message.guid, edited),
        success: 'Message edit queued',
        onChanged: onChanged,
      );
      break;
    case MessageAction.retract:
      if (api == null || chatGuid == null) return;
      final ok = await _confirmMessageAction(
        context,
        title: 'Undo Send',
        body: 'Undo send for this iMessage?',
        confirm: 'Undo Send',
      );
      if (!context.mounted || !ok) return;
      await _runMessageAction(
        context,
        () => api.retractMessage(chatGuid, message.guid),
        success: 'Undo send queued',
        onChanged: () async {
          await onChanged?.call();
          onRetracted?.call(message.guid);
        },
      );
      break;
    case MessageAction.delete:
      if (api == null || chatGuid == null) return;
      final ok = await _confirmMessageAction(
        context,
        title: 'Delete Message',
        body: 'Delete this message from this Mac?',
        confirm: 'Delete',
      );
      if (!context.mounted || !ok) return;
      await _runMessageAction(
        context,
        () => api.deleteMessage(chatGuid, message.guid),
        success: 'Delete queued',
        onChanged: onChanged,
      );
      break;
  }
}

Future<String?> _promptForEditedMessage(
  BuildContext context,
  String initialText,
) async {
  final controller = TextEditingController(text: initialText);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Edit Message'),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 1,
        maxLines: 5,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null || result.isEmpty || result == initialText) return null;
  return result;
}

Future<bool> _confirmMessageAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirm,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirm),
            ),
          ],
        ),
      ) ??
      false;
}

Future<void> _runMessageAction(
  BuildContext context,
  Future<void> Function() run, {
  required String success,
  Future<void> Function()? onChanged,
}) async {
  try {
    await run();
    await onChanged?.call();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(success)));
  } on ApiException catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(e.friendly)));
  }
}

class _DateSeparator extends StatelessWidget {
  final String label;
  const _DateSeparator({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Semantics(
        label: label,
        child: ExcludeSemantics(
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
  final bool showSenderName;
  final bool showSenderAvatar;
  final String? body;

  /// Part I: whether to render the delivery-status line.
  final bool showStatus;

  /// C21u: whether the footer shows the time by default (the newest message).
  /// Other bubbles reveal their time on tap.
  final bool showTimestamp;
  final bool showBubbleTail;
  final bool compactWithPrevious;
  final bool compactWithNext;

  /// Tapbacks merged onto this message (chips), the quoted reply (if any), and
  /// the send-effect hint label (if any).
  final List<MessageModel> reactions;
  final List<MessageModel> stickers;
  final ReplyPreview? reply;
  final bool highlighted;
  final String? effectHint;
  final VoidCallback onRetry;
  final ValueChanged<String?> onReplyTap;
  final void Function(Offset globalPosition) onActions;

  const _MessageBubble({
    required this.message,
    required this.api,
    required this.senderName,
    required this.showSenderName,
    required this.showSenderAvatar,
    required this.body,
    required this.showStatus,
    required this.showTimestamp,
    required this.showBubbleTail,
    required this.compactWithPrevious,
    required this.compactWithNext,
    this.reactions = const [],
    this.stickers = const [],
    this.reply,
    required this.highlighted,
    this.effectHint,
    required this.onRetry,
    required this.onReplyTap,
    required this.onActions,
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
    final stickers = widget.stickers;
    final reply = widget.reply;
    final effectHint = widget.effectHint;
    final scheme = Theme.of(context).colorScheme;
    final fromMe = message.isFromMe;
    final showGroupSender = !fromMe && widget.senderName != null;
    final hasMedia = message.hasAttachments && api != null;
    // C24: emoji-only messages render larger and without the colored bubble
    // (BlueBubbles-style). Mixed text + emoji stays a normal text bubble.
    final body = widget.body;
    final bigEmoji = body != null && !hasMedia && isBigEmoji(body);
    // C27: a media-only message (renderable images/stickers, no text or reply)
    // renders as a clean media bubble — no colored chat bubble wrapping it,
    // matching BlueBubbles. Mixed media + text keeps the normal bubble.
    final attachmentOnly =
        hasMedia && widget.body == null && message.attachments.isNotEmpty;
    final cleanMediaOnly =
        attachmentOnly &&
        message.attachments.every((a) => a.canRenderInlineImage);
    final stickerOnly =
        hasMedia &&
        widget.body == null &&
        message.attachments.isNotEmpty &&
        message.attachments.every((a) => a.isStickerLike);
    // C37: handwriting / Digital Touch ship their rendered media as the
    // attachment — show it with no chat bubble behind it (like a sticker).
    final embeddedMedia =
        message.isEmbeddedMedia && hasMedia && widget.body == null;
    final stripBubble =
        bigEmoji ||
        attachmentOnly ||
        cleanMediaOnly ||
        stickerOnly ||
        embeddedMedia;
    final bubbleColor = stripBubble
        ? Colors.transparent
        : (fromMe ? _accent1_600(scheme) : _accent2_600(scheme));
    final textColor = fromMe ? scheme.onPrimary : scheme.onSecondary;

    final images = message.attachments
        .where((a) => a.canRenderInlineImage)
        .toList(growable: false);
    // Local copies so Dart can flow-promote the nullable presentation fields.
    final sender = widget.senderName;
    final senderText = sender ?? '';
    final bodyText = widget.body;
    final effect = effectHint;
    final bodyUrls = bodyText == null ? const <String>[] : urlsInText(bodyText);
    final previewUrl = bodyUrls.length == 1 ? bodyUrls.first : null;
    final hasLinkAttachment = message.attachments.any((a) => a.isLinkPreview);
    final tightTop = widget.compactWithPrevious && !widget.showSenderName;
    final tightBottom =
        widget.compactWithNext && !widget.showStatus && !widget.showTimestamp;
    final bubbleTopPadding = tightTop ? 0.5 : 2.0;
    final bubbleBottomPadding = tightBottom ? 0.5 : 2.0;
    final rowTopPadding = tightTop ? 0.5 : 3.0;
    final rowBottomPadding = tightBottom ? 0.5 : 3.0;

    final crossAxis = fromMe
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;

    final mediaWidgets = <Widget>[
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
    ];
    final textWidgets = <Widget>[
      if (bodyText != null)
        _LinkedMessageText(
          text: bodyText,
          style: bigEmoji
              ? TextStyle(fontSize: bigEmojiFontSize(bodyText), height: 1.1)
              : TextStyle(color: textColor),
          linkColor: textColor,
        ),
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
    ];

    // Wraps [child] in the painted iMessage bubble (or nothing, when stripped).
    Widget paint(Widget child, {required bool mediaTopPad}) {
      if (stripBubble) return child;
      return CustomPaint(
        painter: _IosBubblePainter(
          color: bubbleColor,
          fromMe: fromMe,
          showTail:
              widget.showBubbleTail ||
              reactions.isNotEmpty ||
              stickers.isNotEmpty,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, mediaTopPad ? 6 : 8, 16, 8),
          child: child,
        ),
      );
    }

    // C50: a photo/video sent *with* a caption renders as two visual siblings —
    // the media as a bubble-less block, the text in its own chat bubble — instead
    // of being merged into one combined bubble (matches how iMessage stacks them).
    final mixedMediaText = hasMedia && bodyText != null && !stripBubble;
    final Widget bubbleInner;
    if (mixedMediaText) {
      bubbleInner = Column(
        crossAxisAlignment: crossAxis,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...mediaWidgets,
          paint(
            Column(
              crossAxisAlignment: crossAxis,
              mainAxisSize: MainAxisSize.min,
              children: textWidgets,
            ),
            mediaTopPad: false,
          ),
        ],
      );
    } else {
      bubbleInner = paint(
        Column(
          crossAxisAlignment: crossAxis,
          mainAxisSize: MainAxisSize.min,
          children: [...mediaWidgets, ...textWidgets],
        ),
        mediaTopPad: hasMedia && bodyText == null,
      );
    }

    final bubble = Padding(
      padding: EdgeInsets.only(
        top: bubbleTopPadding,
        bottom: bubbleBottomPadding,
      ),
      child: bubbleInner,
    );

    final bubbleWithOverlays = reactions.isEmpty && stickers.isEmpty
        ? bubble
        : Semantics(
            container: true,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: stickers.isEmpty ? 8 : 22),
                  child: bubble,
                ),
                if (stickers.isNotEmpty && api != null)
                  Positioned(
                    top: -4,
                    right: fromMe ? 4 : null,
                    left: fromMe ? null : 4,
                    child: _AssociatedStickerStrip(
                      api: api,
                      stickers: stickers,
                    ),
                  ),
                if (reactions.isNotEmpty)
                  Positioned(
                    top: stickers.isEmpty ? -4 : 8,
                    right: fromMe ? null : 4,
                    left: fromMe ? 4 : null,
                    child: _ReactionChips(reactions: reactions),
                  ),
              ],
            ),
          );

    final messageColumn = Column(
      crossAxisAlignment: fromMe
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showGroupSender && widget.showSenderName && senderText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 2, top: 2),
            child: Text(
              senderText,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (previewUrl != null && !hasLinkAttachment) ...[
          UrlPreviewCard(url: previewUrl),
          const SizedBox(height: 4),
        ],
        if (reply != null)
          _ReplyPreviewBlock(
            reply: reply,
            fromMe: fromMe,
            onTap: () => widget.onReplyTap(reply.targetGuid),
          ),
        bubbleWithOverlays,
        _Footer(
          message: message,
          showStatus: widget.showStatus,
          showTime: widget.showTimestamp || _revealed,
          onRetry: widget.onRetry,
        ),
      ],
    );

    final row = showGroupSender
        ? Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _GroupSenderAvatarSlot(
                title: senderText.isNotEmpty
                    ? senderText
                    : (message.handleId ?? 'Unknown'),
                handle: message.handleId,
                showAvatar: widget.showSenderAvatar,
              ),
              const SizedBox(width: 8),
              Flexible(child: messageColumn),
            ],
          )
        : messageColumn;

    return Align(
      alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth:
              MediaQuery.of(context).size.width *
              (showGroupSender ? 0.86 : 0.78),
        ),
        child: GestureDetector(
          onTap: () => setState(() => _revealed = !_revealed),
          onLongPressStart: (details) =>
              widget.onActions(details.globalPosition),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.fromLTRB(3, rowTopPadding, 3, rowBottomPadding),
            decoration: BoxDecoration(
              color: widget.highlighted
                  ? scheme.tertiary.withValues(alpha: 0.24)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(24),
            ),
            child: row,
          ),
        ),
      ),
    );
  }
}

class _IosBubblePainter extends CustomPainter {
  final Color color;
  final bool fromMe;
  final bool showTail;

  const _IosBubblePainter({
    required this.color,
    required this.fromMe,
    required this.showTail,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final bodyRect = Offset.zero & size;
    final radius = Radius.circular(math.min(18, size.height / 2));
    if (!showTail) {
      canvas.drawRRect(RRect.fromRectAndRadius(bodyRect, radius), paint);
      return;
    }

    final softBottom = Radius.circular(math.min(18, size.height / 2));
    final pointedBottom = Radius.circular(math.min(8, size.height / 4));
    final body = RRect.fromRectAndCorners(
      bodyRect,
      topLeft: radius,
      topRight: radius,
      bottomLeft: fromMe ? softBottom : pointedBottom,
      bottomRight: fromMe ? pointedBottom : softBottom,
    );
    canvas.drawRRect(body, paint);
  }

  @override
  bool shouldRepaint(covariant _IosBubblePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.fromMe != fromMe ||
      oldDelegate.showTail != showTail;
}

class _GroupSenderAvatarSlot extends StatelessWidget {
  final String title;
  final String? handle;
  final bool showAvatar;

  const _GroupSenderAvatarSlot({
    required this.title,
    required this.handle,
    required this.showAvatar,
  });

  @override
  Widget build(BuildContext context) {
    const size = 40.0;
    if (!showAvatar) {
      return const SizedBox(width: size, height: size);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: HandleAvatar(
          title: title,
          handle: handle,
          isGroup: false,
          radius: 18,
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

/// BlueBubbles-style associated stickers: sticker messages (associated type
/// 1000) are rendered as a compact, transparent strip over the target bubble.
class _AssociatedStickerStrip extends StatelessWidget {
  final ApiClient api;
  final List<MessageModel> stickers;
  const _AssociatedStickerStrip({required this.api, required this.stickers});

  @override
  Widget build(BuildContext context) {
    final attachments = [
      for (final message in stickers)
        for (final attachment in message.attachments)
          if (attachment.isStickerLike) attachment,
    ];
    if (attachments.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.6,
        maxHeight: 100,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final attachment in attachments)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: AttachmentView(api: api, attachment: attachment),
              ),
          ],
        ),
      ),
    );
  }
}

/// Quoted reply preview shown above the message body.
class _ReplyPreviewBlock extends StatelessWidget {
  final ReplyPreview reply;
  final bool fromMe;
  final VoidCallback onTap;

  const _ReplyPreviewBlock({
    required this.reply,
    required this.fromMe,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = reply.targetLoaded
        ? (reply.text ?? 'Attachment')
        : 'Replying to a message';
    final bubbleColor = scheme.surface.withValues(alpha: 0.72);
    final textColor = scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Opacity(
        opacity: 0.88,
        child: Transform.scale(
          scale: 0.92,
          alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Material(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.reply, size: 14, color: textColor),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (reply.targetLoaded && reply.sender.isNotEmpty)
                            Text(
                              reply.sender,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: textColor,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: textColor),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
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
    if (ts != null && (showTime || showStatus)) parts.add(_time(ts));
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
      padding: const EdgeInsets.only(top: 2, left: 10, right: 10),
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

class _LinkedMessageText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Color linkColor;

  const _LinkedMessageText({
    required this.text,
    required this.style,
    required this.linkColor,
  });

  @override
  State<_LinkedMessageText> createState() => _LinkedMessageTextState();
}

class _LinkedMessageTextState extends State<_LinkedMessageText> {
  final List<TapGestureRecognizer> _recognizers = [];
  List<InlineSpan>? _spans;

  @override
  void initState() {
    super.initState();
    _spans = _buildSpans();
  }

  @override
  void didUpdateWidget(covariant _LinkedMessageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.linkColor != widget.linkColor) {
      _disposeRecognizers();
      _spans = _buildSpans();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = urlPreviewRegex.allMatches(widget.text).toList();
    if (matches.isEmpty) return Text(widget.text, style: widget.style);
    return RichText(
      text: TextSpan(style: widget.style, children: _spans ?? const []),
    );
  }

  List<InlineSpan> _buildSpans() {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in urlPreviewRegex.allMatches(widget.text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
      }
      final raw = widget.text.substring(match.start, match.end);
      final url = normalizePreviewUrl(raw);
      final recognizer = TapGestureRecognizer()
        ..onTap = () async {
          final uri = Uri.tryParse(url);
          if (uri != null) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        };
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: raw,
          style: widget.style?.copyWith(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
          ),
          recognizer: recognizer,
        ),
      );
      cursor = match.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }
    return spans;
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }
}

/// C21u composer: a **floating capsule** bar (not a full-width bottom bar) with
/// C37: replaces the composer while a voice message is being recorded — a red
/// pulse, an elapsed timer, and Cancel / Send.
class _VoiceRecordingBar extends StatefulWidget {
  final ValueNotifier<Duration> elapsed;
  final ValueNotifier<List<double>> levels;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onStop;
  const _VoiceRecordingBar({
    required this.elapsed,
    required this.levels,
    required this.busy,
    required this.onCancel,
    required this.onStop,
  });

  @override
  State<_VoiceRecordingBar> createState() => _VoiceRecordingBarState();
}

class _VoiceRecordingBarState extends State<_VoiceRecordingBar> {
  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final outerColor = dark ? _accent2_800(scheme) : _accent1_500(scheme);
    final inputColor = _accent1_10(scheme);
    final inputIconColor = _accent1_800(scheme);
    final bar = Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              decoration: BoxDecoration(
                color: outerColor,
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: outerColor.withValues(alpha: 0.22),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).cancelButtonLabel,
                    onPressed: widget.busy ? null : widget.onCancel,
                    color: scheme.onPrimary,
                    icon: const Icon(Icons.delete_outline),
                  ),
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: inputColor,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Row(
                        children: [
                          _RecordingDot(color: scheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ValueListenableBuilder<List<double>>(
                              valueListenable: widget.levels,
                              builder: (context, levels, _) => _VoiceWaveform(
                                levels: levels,
                                color: inputIconColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          ValueListenableBuilder<Duration>(
                            valueListenable: widget.elapsed,
                            builder: (context, d, _) => Text(
                              _fmt(d),
                              style: TextStyle(
                                color: inputIconColor,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          widget.busy
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton.filled(
                  tooltip: 'Stop',
                  style: IconButton.styleFrom(
                    backgroundColor: _accent3_500(scheme),
                    foregroundColor: scheme.onTertiary,
                    fixedSize: const Size(52, 52),
                  ),
                  onPressed: widget.onStop,
                  icon: const Icon(Icons.stop),
                ),
        ],
      ),
    );
    return SafeArea(top: false, child: bar);
  }
}

class _VoiceReviewBar extends StatelessWidget {
  final Duration duration;
  final List<double> levels;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onSend;
  const _VoiceReviewBar({
    required this.duration,
    required this.levels,
    required this.busy,
    required this.onCancel,
    required this.onSend,
  });

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final outerColor = dark ? _accent2_800(scheme) : _accent1_500(scheme);
    final inputColor = _accent1_10(scheme);
    final inputIconColor = _accent1_800(scheme);
    final bar = Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              decoration: BoxDecoration(
                color: outerColor,
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: outerColor.withValues(alpha: 0.22),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).cancelButtonLabel,
                    onPressed: busy ? null : onCancel,
                    color: scheme.onPrimary,
                    icon: const Icon(Icons.delete_outline),
                  ),
                  Expanded(
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: inputColor,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.graphic_eq,
                            color: inputIconColor,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _VoiceWaveform(
                              levels: levels,
                              color: inputIconColor,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _fmt(duration),
                            style: TextStyle(
                              color: inputIconColor,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          busy
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton.filled(
                  tooltip: MicaLocalizations.of(context).t('chat.send'),
                  style: IconButton.styleFrom(
                    backgroundColor: _accent3_500(scheme),
                    foregroundColor: scheme.onTertiary,
                    fixedSize: const Size(52, 52),
                  ),
                  onPressed: onSend,
                  icon: const Icon(Icons.send),
                ),
        ],
      ),
    );
    return SafeArea(top: false, child: bar);
  }
}

class _RecordingDot extends StatefulWidget {
  final Color color;
  const _RecordingDot({required this.color});

  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.45,
        end: 1,
      ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: Icon(Icons.fiber_manual_record, color: widget.color, size: 12),
    );
  }
}

class _VoiceWaveform extends StatelessWidget {
  final List<double> levels;
  final Color color;
  const _VoiceWaveform({required this.levels, required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _VoiceWaveformPainter(levels: levels, color: color),
      child: const SizedBox(height: 28),
    );
  }
}

class _VoiceWaveformPainter extends CustomPainter {
  final List<double> levels;
  final Color color;
  const _VoiceWaveformPainter({required this.levels, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.78)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    const bars = 28;
    final values = levels.isEmpty
        ? List<double>.filled(bars, 0.08)
        : levels.length >= bars
        ? levels.sublist(levels.length - bars)
        : [...List<double>.filled(bars - levels.length, 0.08), ...levels];
    final gap = size.width / bars;
    final center = size.height / 2;
    for (var i = 0; i < bars; i++) {
      final normalized = values[i].clamp(0.04, 1.0);
      final height = 4 + normalized * (size.height - 8);
      final x = gap * i + gap / 2;
      canvas.drawLine(
        Offset(x, center - height / 2),
        Offset(x, center + height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceWaveformPainter oldDelegate) =>
      oldDelegate.levels != levels || oldDelegate.color != color;
}

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
  // C24: the emoji panel is owned by the parent (a bottom panel). The composer
  // just reports taps on the emoji button and keeps it visible while open.
  final bool emojiOpen;
  final VoidCallback onEmoji;
  final VoidCallback onInputFocused;

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
    required this.emojiOpen,
    required this.onEmoji,
    required this.onInputFocused,
  });

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Rebuild on focus change so the voice↔emoji swap animates; tapping into the
    // field (keyboard returns) closes the bottom emoji panel.
    _focus.addListener(() {
      if (_focus.hasFocus) widget.onInputFocused();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
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

    final dark = Theme.of(context).brightness == Brightness.dark;
    final outerColor = dark ? _accent2_800(scheme) : _accent1_500(scheme);
    final attachIconColor = dark ? _accent1_50(scheme) : scheme.onPrimary;
    final inputColor = _accent1_10(scheme);
    final inputIconColor = _accent1_800(scheme);
    final onInput = scheme.onSurface;
    final hintColor = scheme.onSurface.withValues(alpha: 0.68);
    // Show the emoji button while the field is focused OR the bottom emoji panel
    // is open (so it stays reachable after the keyboard is dismissed); otherwise
    // the voice button.
    final showEmoji = _focus.hasFocus || widget.emojiOpen;

    final bar = Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              decoration: BoxDecoration(
                color: outerColor,
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: outerColor.withValues(alpha: 0.22),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
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
                          color: attachIconColor,
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
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.only(left: 18, right: 4),
                      decoration: BoxDecoration(
                        color: inputColor,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: widget.controller,
                              focusNode: _focus,
                              minLines: 1,
                              maxLines: 5,
                              style: TextStyle(color: onInput, fontSize: 18),
                              cursorColor: inputIconColor,
                              textAlignVertical: TextAlignVertical.center,
                              textInputAction: TextInputAction.newline,
                              keyboardType: TextInputType.multiline,
                              decoration: InputDecoration(
                                hintText: 'Message',
                                hintStyle: TextStyle(
                                  color: hintColor,
                                  fontSize: 18,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            transitionBuilder: (child, anim) => ScaleTransition(
                              scale: anim,
                              child: FadeTransition(
                                opacity: anim,
                                child: child,
                              ),
                            ),
                            child: showEmoji
                                ? IconButton(
                                    key: const ValueKey('emoji'),
                                    tooltip: 'Emoji',
                                    visualDensity: VisualDensity.compact,
                                    color: widget.emojiOpen
                                        ? _accent3_500(scheme)
                                        : inputIconColor,
                                    icon: const Icon(
                                      Icons.emoji_emotions_outlined,
                                      size: 22,
                                    ),
                                    onPressed: widget.onEmoji,
                                  )
                                : IconButton(
                                    key: const ValueKey('voice'),
                                    tooltip: 'Voice message',
                                    visualDensity: VisualDensity.compact,
                                    color: inputIconColor,
                                    icon: const Icon(Icons.mic_none, size: 22),
                                    onPressed: widget.onVoice,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          AnimatedScale(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            scale: widget.canSend ? 1.0 : 0.85,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: widget.canSend ? 1.0 : 0.5,
              child: IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: _accent3_500(scheme),
                  foregroundColor: scheme.onTertiary,
                  fixedSize: const Size(52, 52),
                ),
                onPressed: widget.canSend ? widget.onSend : null,
                icon: const Icon(Icons.send),
              ),
            ),
          ),
        ],
      ),
    );
    // SafeArea bottom is applied by the emoji panel when it's open; here the bar
    // keeps its own bottom margin.
    return SafeArea(top: false, child: bar);
  }
}

/// C24: a bottom emoji panel (keyboard-style) — rounded top corners, theme-aware
/// background, a recents row, category tabs, and a curated multi-category emoji
/// set (no plugin). Taps insert at the composer's cursor; picks are remembered
/// as recents. Works in dark/light and narrow/wide layouts (the grid reflows by
/// available width).
class EmojiPanel extends StatefulWidget {
  final void Function(String emoji) onPick;
  const EmojiPanel({super.key, required this.onPick});

  /// The panel's initial on-screen height, so the thread can reserve matching
  /// bottom space in the message list (C50). Mirrors [_EmojiPanelState] bounds.
  static double initialHeightFor(BuildContext context) {
    final maxHeight =
        MediaQuery.sizeOf(context).height * _EmojiPanelState._maxScreenFraction;
    return _EmojiPanelState._initialHeight
        .clamp(_EmojiPanelState._minHeight, maxHeight)
        .toDouble();
  }

  // In-memory most-recently-used list (most recent first), shared across threads
  // for the session. Simple + dependency-free.
  static final List<String> _recents = <String>[];
  static void remember(String emoji) {
    _recents.remove(emoji);
    _recents.insert(0, emoji);
    if (_recents.length > 24) _recents.removeRange(24, _recents.length);
  }

  static const Map<String, List<String>> categories = {
    'Smileys': [
      '😀',
      '😃',
      '😄',
      '😁',
      '😆',
      '😅',
      '😂',
      '🤣',
      '🙂',
      '🙃',
      '😉',
      '😊',
      '😇',
      '🥰',
      '😍',
      '🤩',
      '😘',
      '😗',
      '😚',
      '😙',
      '😋',
      '😛',
      '😜',
      '🤪',
      '😝',
      '🤗',
      '🤔',
      '🤐',
      '😐',
      '😴',
      '😪',
      '😌',
      '😎',
      '🥳',
      '😏',
      '😒',
      '😔',
      '😟',
      '😕',
      '🙁',
      '😣',
      '😖',
      '😫',
      '😩',
      '🥺',
      '😢',
      '😭',
      '😤',
      '😠',
      '😡',
      '🤯',
      '😳',
      '🥵',
      '🥶',
      '😱',
      '😨',
      '😰',
      '😥',
      '🤥',
      '🤫',
      '😬',
      '🙄',
      '😯',
      '🥱',
    ],
    'Gestures': [
      '👍',
      '👎',
      '👏',
      '🙌',
      '🙏',
      '🤝',
      '👋',
      '🤙',
      '✌️',
      '🤞',
      '🫶',
      '🤟',
      '🤘',
      '👌',
      '🤏',
      '👈',
      '👉',
      '👆',
      '👇',
      '✋',
      '🖐️',
      '🖖',
      '💪',
      '🦾',
      '👀',
      '👁️',
      '🫡',
      '🫠',
      '🤌',
      '✊',
      '👊',
      '🫵',
    ],
    'Hearts': [
      '❤️',
      '🧡',
      '💛',
      '💚',
      '💙',
      '💜',
      '🖤',
      '🤍',
      '🤎',
      '💔',
      '❣️',
      '💕',
      '💞',
      '💓',
      '💗',
      '💖',
      '💘',
      '💝',
      '💟',
      '♥️',
      '💯',
      '💢',
      '💥',
      '✨',
      '⭐',
      '🌟',
      '💫',
      '🔥',
    ],
    'Animals': [
      '🐶',
      '🐱',
      '🐭',
      '🐹',
      '🐰',
      '🦊',
      '🐻',
      '🐼',
      '🐨',
      '🐯',
      '🦁',
      '🐮',
      '🐷',
      '🐸',
      '🐵',
      '🐔',
      '🐧',
      '🐦',
      '🐤',
      '🦄',
      '🐝',
      '🦋',
      '🐌',
      '🐞',
      '🐢',
      '🐍',
      '🐙',
      '🦀',
      '🐠',
      '🐬',
      '🐳',
      '🐡',
    ],
    'Food': [
      '🍏',
      '🍎',
      '🍐',
      '🍊',
      '🍋',
      '🍌',
      '🍉',
      '🍇',
      '🍓',
      '🫐',
      '🍒',
      '🍑',
      '🥭',
      '🍍',
      '🥥',
      '🥝',
      '🍅',
      '🥑',
      '🌽',
      '🌶️',
      '🍔',
      '🍟',
      '🍕',
      '🌭',
      '🥪',
      '🌮',
      '🍣',
      '🍜',
      '🍰',
      '🍩',
      '🍪',
      '☕',
    ],
    'Activities': [
      '⚽',
      '🏀',
      '🏈',
      '⚾',
      '🎾',
      '🏐',
      '🏉',
      '🎱',
      '🏓',
      '🏸',
      '🥅',
      '🎯',
      '🎮',
      '🎲',
      '🎸',
      '🎧',
      '🎉',
      '🎊',
      '🎁',
      '🏆',
      '🥇',
      '🚗',
      '✈️',
      '🚀',
      '🏝️',
      '🎢',
      '🎡',
      '📷',
      '💻',
      '📱',
      '⌚',
      '💡',
    ],
    'Symbols': [
      '✅',
      '❌',
      '⚠️',
      '❓',
      '❗',
      '💤',
      '♻️',
      '🔔',
      '🔕',
      '🔒',
      '🔑',
      '🔗',
      '📌',
      '📎',
      '✏️',
      '📝',
      '➡️',
      '⬅️',
      '⬆️',
      '⬇️',
      '🔄',
      '🔝',
      '🆗',
      '🆕',
      '🚫',
      '💲',
      '🎵',
      '🎶',
      '™️',
      '©️',
      '®️',
      '🔆',
    ],
  };

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  static const double _minHeight = 240;
  static const double _initialHeight = 280;
  static const double _maxScreenFraction = 0.58;

  String _category = EmojiPanel.categories.keys.first;
  double _height = _initialHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * _maxScreenFraction;
    final panelHeight = _height.clamp(_minHeight, maxHeight).toDouble();
    final hasRecents = EmojiPanel._recents.isNotEmpty;
    final emoji = _category == 'Recent'
        ? EmojiPanel._recents
        : (EmojiPanel.categories[_category] ?? const <String>[]);
    return Container(
      height: panelHeight,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(18),
          topRight: Radius.circular(18),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                setState(() {
                  _height = (_height - details.delta.dy)
                      .clamp(_minHeight, maxHeight)
                      .toDouble();
                });
              },
              child: SizedBox(
                height: 20,
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
            // Category tabs (Recent first when available).
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                children: [
                  if (hasRecents)
                    _CategoryTab(
                      icon: Icons.history,
                      selected: _category == 'Recent',
                      onTap: () => setState(() => _category = 'Recent'),
                    ),
                  for (final entry in EmojiPanel.categories.entries)
                    _CategoryTab(
                      icon: _iconFor(entry.key),
                      selected: _category == entry.key,
                      onTap: () => setState(() => _category = entry.key),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: GridView.extent(
                // Reflows by width → works in narrow + wide layouts.
                maxCrossAxisExtent: 48,
                padding: const EdgeInsets.all(8),
                physics: const BouncingScrollPhysics(),
                children: [
                  for (final e in emoji)
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => widget.onPick(e),
                      child: Center(
                        child: Text(e, style: const TextStyle(fontSize: 26)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String category) {
    switch (category) {
      case 'Smileys':
        return Icons.emoji_emotions_outlined;
      case 'Gestures':
        return Icons.back_hand_outlined;
      case 'Hearts':
        return Icons.favorite_border;
      case 'Animals':
        return Icons.pets_outlined;
      case 'Food':
        return Icons.restaurant_outlined;
      case 'Activities':
        return Icons.sports_basketball_outlined;
      default:
        return Icons.tag;
    }
  }
}

class _CategoryTab extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryTab({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          icon,
          size: 20,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
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
  final ApiClient? api;
  final VoidCallback onRefresh;
  final VoidCallback onLoadOlder;
  final ValueChanged<ChatSummary> onSwitchRoute;
  final ValueChanged<String> onJumpToMessage;

  const _ThreadDetailsSheet({
    required this.title,
    required this.merged,
    required this.active,
    required this.messages,
    required this.resolveName,
    required this.api,
    required this.onRefresh,
    required this.onLoadOlder,
    required this.onSwitchRoute,
    required this.onJumpToMessage,
  });

  @override
  State<_ThreadDetailsSheet> createState() => _ThreadDetailsSheetState();
}

class _ThreadDetailsSheetState extends State<_ThreadDetailsSheet> {
  late String _activeGuid = widget.active.guid;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = context.watch<AppController>();
    final api = widget.api;
    final routeGuids = widget.merged.routes.map((r) => r.guid).toList();
    final muted = app.areChatsMuted(routeGuids);
    final allAttachments = [
      for (final m in widget.messages)
        for (final a in m.attachments)
          if (!a.isOpaquePreviewPayload) a,
    ];
    final media = allAttachments
        .where((a) => a.canRenderInlineImage || a.isVideo)
        .take(9)
        .toList(growable: false);
    final images = media
        .where((a) => a.canRenderInlineImage)
        .toList(growable: false);
    final files = allAttachments
        .where((a) => !a.canRenderInlineImage && !a.isVideo && !a.isLinkPreview)
        .take(18)
        .toList(growable: false);
    final linkSet = <String>{};
    for (final m in widget.messages) {
      final text = displayText(m);
      final url = text == null ? null : firstUrlInText(text);
      if (url != null) linkSet.add(url);
    }
    for (final a in allAttachments) {
      if (a.isLinkPreview) linkSet.add(a.displayName);
    }
    final linkUrls = linkSet.take(4).toList(growable: false);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final headerBg = _accent1_100(scheme);
    final pageBg = _accent1_50(scheme);
    final isGroup = widget.active.isGroup;
    final detailSubtitle = isGroup
        ? 'iMessage 群聊'
        : widget.active.chatIdentifier;
    final participants = widget.active.participants
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Details'),
        backgroundColor: headerBg,
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: _showDetailsSearchSheet,
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(color: headerBg),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: DecoratedBox(
            decoration: BoxDecoration(color: pageBg),
            child: SafeArea(
              top: false,
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + insets),
                children: [
                  Row(
                    children: [
                      HandleAvatar(
                        title: widget.title,
                        handle: widget.active.isGroup
                            ? null
                            : widget.active.chatIdentifier,
                        participantHandles: widget.active.participants,
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
                            if (detailSubtitle != null &&
                                detailSubtitle.isNotEmpty)
                              Text(
                                detailSubtitle,
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
                          TopBanner.show(context, 'Refreshing conversation');
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Actions',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Mute notifications'),
                    subtitle: const Text(
                      'Silence local notifications for every route here',
                    ),
                    value: muted,
                    onChanged: (value) => app.setChatsMuted(routeGuids, value),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            widget.onRefresh();
                            TopBanner.show(context, 'Refreshing conversation');
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            widget.onLoadOlder();
                            TopBanner.show(context, 'Fetching more messages');
                          },
                          icon: const Icon(Icons.history),
                          label: const Text('Fetch more'),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Text(
                    isGroup ? 'Accounts' : 'Routes',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  if (isGroup) ...[
                    for (final handle in participants)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: HandleAvatar(
                          title: widget.resolveName(handle) ?? handle,
                          handle: handle,
                          radius: 16,
                        ),
                        title: Text(widget.resolveName(handle) ?? handle),
                        subtitle: widget.resolveName(handle) != null
                            ? Text(handle)
                            : null,
                      ),
                    if (participants.isEmpty)
                      Text(
                        'No accounts found',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ] else
                    for (final r in widget.merged.routes)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          r.guid == _activeGuid
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 18,
                          color: scheme.primary,
                        ),
                        title: Text(r.service.label),
                        subtitle: r.chatIdentifier != null
                            ? Text(r.chatIdentifier!)
                            : null,
                        selected: r.guid == _activeGuid,
                        selectedTileColor: scheme.primary.withValues(
                          alpha: 0.08,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        onTap: () {
                          setState(() => _activeGuid = r.guid);
                          widget.onSwitchRoute(r);
                        },
                      ),
                  const Divider(height: 24),
                  if (api != null && media.isNotEmpty) ...[
                    Text(
                      'Images & Videos',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    _DetailsMediaGrid(api: api, media: media, images: images),
                    const Divider(height: 24),
                  ],
                  if (linkUrls.isNotEmpty) ...[
                    Text(
                      'Links',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    for (final url in linkUrls)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.link),
                        title: Text(
                          url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Uri.tryParse(url)?.host.isNotEmpty == true
                            ? Text(Uri.parse(url).host)
                            : null,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    const Divider(height: 24),
                  ],
                  if (api != null && files.isNotEmpty) ...[
                    Text(
                      'Files',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    for (final a in files)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          a.isAudio
                              ? Icons.graphic_eq
                              : a.isLocation
                              ? Icons.location_on_outlined
                              : Icons.insert_drive_file_outlined,
                        ),
                        title: Text(
                          a.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(a.displayKind),
                        onLongPress: () => showAttachmentActions(
                          context,
                          api: api,
                          attachment: a,
                        ),
                      ),
                    const Divider(height: 24),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showDetailsSearchSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (context) => _ThreadSearchSheet(
        messages: widget.messages,
        resolveName: widget.resolveName,
        onSelect: (guid) {
          Navigator.of(context).pop();
          widget.onJumpToMessage(guid);
        },
      ),
    );
  }
}

class _ThreadSearchSheet extends StatefulWidget {
  final List<MessageModel> messages;
  final String? Function(String? handle) resolveName;
  final ValueChanged<String> onSelect;

  const _ThreadSearchSheet({
    required this.messages,
    required this.resolveName,
    required this.onSelect,
  });

  @override
  State<_ThreadSearchSheet> createState() => _ThreadSearchSheetState();
}

class _ThreadSearchSheetState extends State<_ThreadSearchSheet> {
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
    final results = q.isEmpty
        ? const <MessageModel>[]
        : (widget.messages
              .where(
                (m) =>
                    (displayText(m) ?? m.text ?? '').toLowerCase().contains(q),
              )
              .toList(growable: false)
            ..sort(
              (a, b) => (b.dateCreated ?? 0).compareTo(a.dateCreated ?? 0),
            ));
    final insets = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: insets),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: FractionallySizedBox(
          heightFactor: 0.72,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _accent1_50(scheme),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 24,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Column(
                  children: [
                    Container(
                      width: 42,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    TextField(
                      controller: _search,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Search this conversation',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide(color: scheme.outlineVariant),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide(color: scheme.primary),
                        ),
                        filled: true,
                        fillColor: scheme.surface.withValues(alpha: 0.86),
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
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        q.isEmpty
                            ? 'Type to search messages'
                            : results.isEmpty
                            ? 'No matches'
                            : '${results.length} match${results.length == 1 ? '' : 'es'}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, i) {
                          final m = results[i];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              displayText(m) ?? m.text ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              _subtitle(m),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            onTap: () => widget.onSelect(m.guid),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle(MessageModel m) {
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

class _DetailsMediaGrid extends StatelessWidget {
  final ApiClient api;
  final List<AttachmentModel> media;
  final List<AttachmentModel> images;

  const _DetailsMediaGrid({
    required this.api,
    required this.media,
    required this.images,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: media.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemBuilder: (context, i) => _DetailsMediaTile(
        api: api,
        attachment: media[i],
        images: images,
        imageIndex: media[i].canRenderInlineImage
            ? images.indexOf(media[i])
            : 0,
      ),
    );
  }
}

class _DetailsMediaTile extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final List<AttachmentModel> images;
  final int imageIndex;

  const _DetailsMediaTile({
    required this.api,
    required this.attachment,
    required this.images,
    required this.imageIndex,
  });

  @override
  State<_DetailsMediaTile> createState() => _DetailsMediaTileState();
}

class _DetailsMediaTileState extends State<_DetailsMediaTile> {
  late final Future<Uint8List?> _future = _loadPreview();

  Future<Uint8List?> _loadPreview() async {
    if (!widget.attachment.canRenderInlineImage) return null;
    final cacheKey = widget.attachment.previewUrl ?? widget.attachment.guid;
    final cached = imageByteCache[cacheKey];
    if (cached != null) return cached;
    final bytes = await widget.api.getAttachmentPreviewBytes(widget.attachment);
    imageByteCache[cacheKey] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (widget.attachment.canRenderInlineImage) {
            MediaGalleryViewer.open(
              context,
              api: widget.api,
              images: widget.images,
              initialIndex: widget.imageIndex,
            );
          } else if (widget.attachment.isVideo) {
            FullscreenVideo.open(
              context,
              api: widget.api,
              attachment: widget.attachment,
            );
          }
        },
        onLongPress: () => showAttachmentActions(
          context,
          api: widget.api,
          attachment: widget.attachment,
        ),
        child: widget.attachment.isVideo
            ? Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      size: 42,
                      color: scheme.primary,
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Text(
                      widget.attachment.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              )
            : FutureBuilder<Uint8List?>(
                future: _future,
                builder: (context, snap) {
                  final bytes = snap.data;
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    );
                  }
                  if (snap.hasError || bytes == null || bytes.isEmpty) {
                    return Icon(
                      Icons.broken_image_outlined,
                      color: scheme.onSurfaceVariant,
                    );
                  }
                  return Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: 420,
                  );
                },
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
