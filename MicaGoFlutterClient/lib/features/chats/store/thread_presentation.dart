/// Precomputed thread view model (C7 Part E).
///
/// All per-row work (classification, sender label, reply preview, reaction
/// merge, effect label, delivery visibility, date separators, body text) is
/// done **once** here — outside the scroll item builder — so the hot
/// `itemBuilder` stays trivial and scrolling is smooth. Pure + testable: the
/// contact resolver is injected, so there is no Flutter/provider dependency.
library;

import '../message_display.dart';
import '../message_render.dart';
import '../models/message_model.dart';

/// A single rendered thread row: a date separator, a message, or the
/// loading-older spinner. Stable [key] drives ListView element reuse.
sealed class ThreadViewItem {
  String get key;
}

class DateSeparatorItem extends ThreadViewItem {
  final String label;
  DateSeparatorItem(this.label);
  @override
  String get key => 'date:$label';
}

class LoadingOlderItem extends ThreadViewItem {
  @override
  String get key => 'loading-older';
}

/// A fully-resolved message row. Widgets read these fields directly; they must
/// not re-derive anything in the build path.
class MessageViewItem extends ThreadViewItem {
  final MessageModel message;
  final MessageRenderableKind kind;
  final bool isSystem;

  // Precomputed presentation:
  final String? systemLabel; // for system/unknown/retracted/reaction rows
  final int mergedSystemCount;
  final String? senderLabel; // shown only in groups for incoming; else null
  final String? body; // sanitized display text (null = none)
  final ReplyPreview? reply;
  final List<MessageModel> reactions;
  final String? effectHint;
  final MessageDeliveryState deliveryState;
  final bool showStatus; // whether to render a delivery label

  MessageViewItem({
    required this.message,
    required this.kind,
    required this.isSystem,
    required this.systemLabel,
    required this.mergedSystemCount,
    required this.senderLabel,
    required this.body,
    required this.reply,
    required this.reactions,
    required this.effectHint,
    required this.deliveryState,
    required this.showStatus,
  });

  @override
  String get key => 'msg:${message.dedupeKey}';
}

/// Resolves a local contact display name for a handle (injected so the builder
/// stays pure/testable).
typedef ContactNameResolver = String? Function(String? handleId);

class ThreadPresentationBuilder {
  /// Builds the chronological (oldest → newest) view-item list. The thread view
  /// renders it reversed. [loadingOlder] appends a spinner item at the top
  /// (i.e. last in chronological order).
  static List<ThreadViewItem> build({
    required List<MessageModel> messages,
    required MessageDisplayPrefs prefs,
    required bool isGroup,
    required ContactNameResolver resolveName,
    bool loadingOlder = false,
  }) {
    final rows = buildDisplayRows(messages, prefs);
    final byGuid = {for (final m in messages) m.guid: m};

    // Delivery-label visibility: compact = latest outgoing only.
    String? lastOutgoingKey;
    for (final m in messages) {
      if (m.isFromMe) lastOutgoingKey = m.dedupeKey;
    }
    bool showStatusFor(MessageModel m) {
      switch (prefs.deliveryLabels) {
        case DeliveryLabelMode.off:
          return false;
        case DeliveryLabelMode.compact:
          return m.dedupeKey == lastOutgoingKey;
        case DeliveryLabelMode.detailed:
          return m.isFromMe;
      }
    }

    ReplyPreview? replyFor(MessageModel m) {
      if (!isReply(m)) return null;
      final target = byGuid[m.threadOriginatorGuid];
      if (target == null) {
        return const ReplyPreview(sender: '', text: null, targetLoaded: false);
      }
      return ReplyPreview(
        sender: resolveSenderLabel(
          target,
          isGroup: isGroup,
          contactName: resolveName(target.handleId),
        ),
        text: displayText(target),
        targetLoaded: true,
      );
    }

    final items = <ThreadViewItem>[];
    DateTime? lastDay;
    for (final row in rows) {
      final m = row.message;
      final ts = m.dateCreated;
      if (ts != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ts);
        final day = DateTime(dt.year, dt.month, dt.day);
        if (lastDay == null || day != lastDay) {
          items.add(DateSeparatorItem(dayLabel(day)));
          lastDay = day;
        }
      }

      final isSystem =
          row.kind == MessageRenderableKind.service ||
          row.kind == MessageRenderableKind.reaction ||
          row.kind == MessageRenderableKind.retracted ||
          row.kind == MessageRenderableKind.unknown;

      items.add(
        MessageViewItem(
          message: m,
          kind: row.kind,
          isSystem: isSystem,
          systemLabel: isSystem ? _systemLabel(row.kind, m) : null,
          mergedSystemCount: row.mergedSystemCount,
          senderLabel: (!isSystem && !m.isFromMe && isGroup)
              ? resolveSenderLabel(
                  m,
                  isGroup: isGroup,
                  contactName: resolveName(m.handleId),
                )
              : null,
          body: isSystem ? null : displayText(m),
          reply: isSystem ? null : replyFor(m),
          reactions: row.reactions,
          effectHint: (!isSystem && prefs.showEffectHints)
              ? effectLabel(m.expressiveSendStyleId)
              : null,
          deliveryState: deliveryStateFor(m),
          showStatus: !isSystem && showStatusFor(m),
        ),
      );
    }

    if (loadingOlder) items.add(LoadingOlderItem());
    return items;
  }

  static String _systemLabel(MessageRenderableKind kind, MessageModel m) {
    switch (kind) {
      case MessageRenderableKind.service:
        return serviceEventLabel(m);
      case MessageRenderableKind.retracted:
        return retractedLabel(m);
      case MessageRenderableKind.reaction:
        final t = tapbackFromCode(m.associatedMessageType);
        if (t == null) return 'Reacted to a message';
        final emoji = tapbackEmoji(t.kind);
        return t.isRemoval
            ? 'Removed a $emoji reaction'
            : '$emoji Reacted to a message';
      default:
        return 'Unsupported message';
    }
  }
}

/// Human day-separator label ("Today" / "Yesterday" / "Jan 5" / "Jan 5, 2024").
String dayLabel(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final base = '${months[day.month - 1]} ${day.day}';
  return day.year == now.year ? base : '$base, ${day.year}';
}
