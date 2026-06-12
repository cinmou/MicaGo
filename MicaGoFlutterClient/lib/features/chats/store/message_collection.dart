/// Pure, testable per-chat message store (C7).
///
/// This is the single source of truth for one thread's messages. REST pages and
/// WebSocket events are *patched* into the keyed maps — never a full reload —
/// mirroring BlueBubbles' in-memory `ChatMessages` struct. It has no Flutter or
/// async dependencies so every event/reconciliation case is unit-testable.
///
/// - Confirmed/server messages are keyed by `guid`.
/// - Optimistic outgoing messages are keyed by `tempId` until reconciled.
/// - Dedupe is by guid (server) and tempId (pending); a pending row is removed
///   when a matching server row arrives (see [shouldReconcileLocalWithServer]).
library;

import '../models/message_model.dart';

class MessageCollection {
  final Map<String, MessageModel> _server = {}; // by guid
  final Map<String, MessageModel> _pending = {}; // by tempId

  /// Cached, sorted display list; rebuilt lazily after mutations.
  List<MessageModel>? _orderedCache;

  bool get isEmpty => _server.isEmpty && _pending.isEmpty;
  int get length => _server.length + _pending.length;

  /// Chronological (oldest → newest) display list: confirmed server messages
  /// followed by not-yet-reconciled optimistic sends, stably ordered by
  /// dateCreated then identity.
  List<MessageModel> get ordered {
    return _orderedCache ??= _buildOrdered();
  }

  List<MessageModel> _buildOrdered() {
    final all = <MessageModel>[..._server.values, ..._pending.values];
    all.sort((a, b) {
      final byDate = (a.dateCreated ?? 0).compareTo(b.dateCreated ?? 0);
      if (byDate != 0) return byDate;
      // Pending after server at the same instant; otherwise stable by key.
      final ap = a.tempId != null && a.guid.isEmpty ? 1 : 0;
      final bp = b.tempId != null && b.guid.isEmpty ? 1 : 0;
      if (ap != bp) return ap - bp;
      return a.dedupeKey.compareTo(b.dedupeKey);
    });
    return List.unmodifiable(all);
  }

  void _invalidate() => _orderedCache = null;

  MessageModel? serverByGuid(String guid) => _server[guid];
  MessageModel? pendingByTempId(String tempId) => _pending[tempId];

  void clear() {
    _server.clear();
    _pending.clear();
    _invalidate();
  }

  /// Replaces the confirmed set with a freshly fetched page (newest-first or
  /// any order; we key by guid). Pending sends are kept and reconciled.
  void replaceServerPage(Iterable<MessageModel> page) {
    _server.clear();
    for (final m in page) {
      if (m.guid.isNotEmpty) {
        _server[m.guid] = m;
      } else if (m.tempId != null) {
        _pending[m.tempId!] = m;
      }
    }
    _reconcilePending();
    _invalidate();
  }

  /// Merges an older page (pagination) without dropping existing messages.
  void mergeOlder(Iterable<MessageModel> older) {
    for (final m in older) {
      if (m.guid.isNotEmpty) _server.putIfAbsent(m.guid, () => m);
    }
    _invalidate();
  }

  /// Inserts/merges a single server message (message:new / send confirmation).
  /// Patches in place by guid and reconciles any matching optimistic row.
  void upsertServer(MessageModel m) {
    if (m.guid.isEmpty) return;
    _server[m.guid] = m;
    _reconcileOne(m);
    _invalidate();
  }

  /// Patches an existing message by guid (message:update: delivered/read/edit).
  /// If the guid isn't present, inserts it (so updates are never lost).
  void applyUpdate(MessageModel m) => upsertServer(m);

  /// Marks an existing message retracted and clears its displayed content.
  /// Returns false when the guid is unknown (caller may schedule a reload).
  bool applyUnsend(String guid, int? dateRetracted) {
    final existing = _server[guid];
    if (existing == null) return false;
    _server[guid] = existing.copyWith(
      text: '',
      attachments: const [],
      isRetracted: true,
      dateRetracted: dateRetracted,
      errorCode: 0,
      localState: LocalSendState.confirmed,
    );
    _invalidate();
    return true;
  }

  bool applyReactionEvent({
    required String targetGuid,
    required ReactionModel reaction,
    required bool add,
  }) {
    final target = _server[targetGuid];
    if (target == null) return false;
    final filtered = target.reactions
        .where(
          (r) =>
              !(r.type == reaction.type &&
                  r.fromHandle == reaction.fromHandle &&
                  r.isFromMe == reaction.isFromMe),
        )
        .toList(growable: true);
    _server[targetGuid] = target.copyWith(
      reactions: add ? [...filtered, reaction] : filtered,
    );
    _invalidate();
    return true;
  }

  // --- Optimistic send lifecycle -------------------------------------------

  void addPending(MessageModel optimistic) {
    final t = optimistic.tempId;
    if (t == null) return;
    _pending[t] = optimistic;
    _invalidate();
  }

  void setPendingState(String tempId, LocalSendState state) {
    final p = _pending[tempId];
    if (p == null) return;
    _pending[tempId] = p.copyWith(localState: state);
    _invalidate();
  }

  /// Replaces an optimistic row with its confirmed server message.
  void confirmPending(String tempId, MessageModel server) {
    _pending.remove(tempId);
    upsertServer(server);
  }

  /// Removes a pending row entirely (e.g. before a retry re-adds it).
  String? removePending(String tempId) {
    final removed = _pending.remove(tempId);
    _invalidate();
    return removed?.text;
  }

  // --- Reconciliation -------------------------------------------------------

  void _reconcilePending() {
    if (_pending.isEmpty) return;
    _pending.removeWhere(
      (_, local) =>
          _server.values.any((s) => shouldReconcileLocalWithServer(local, s)),
    );
  }

  void _reconcileOne(MessageModel server) {
    if (_pending.isEmpty) return;
    _pending.removeWhere(
      (_, local) => shouldReconcileLocalWithServer(local, server),
    );
  }
}

/// True when an optimistic local send should be replaced by a server message —
/// matched by guid, tempId, or (chat-scoped) identical text within a 2-minute
/// window. Prevents showing both a pending bubble and its confirmed server row.
bool shouldReconcileLocalWithServer(MessageModel local, MessageModel server) {
  if (!local.isFromMe || !server.isFromMe || server.guid.isEmpty) return false;
  if (local.guid.isNotEmpty && local.guid == server.guid) return true;
  if (local.tempId != null && local.tempId == server.tempId) return true;
  final localText = _normaliseComparableText(local.text);
  final serverText = _normaliseComparableText(server.text);
  if (localText.isEmpty || localText != serverText) return false;
  final localAt = local.dateCreated;
  final serverAt = server.dateCreated;
  if (localAt == null || serverAt == null) return false;
  return (localAt - serverAt).abs() <=
      const Duration(minutes: 2).inMilliseconds;
}

String _normaliseComparableText(String? text) =>
    (text ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
