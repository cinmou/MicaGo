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

/// C21u: a centered time chip inserted only between **large time gaps** within
/// the same day (BlueBubbles-style), so timestamps appear when useful instead
/// of under every bubble. Keyed by the boundary message so it stays stable.
class TimeSeparatorItem extends ThreadViewItem {
  final String label;
  final String afterKey;
  TimeSeparatorItem(this.label, this.afterKey);
  @override
  String get key => 'time:$afterKey';
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
  final bool showTimestamp; // whether the footer shows the time by default

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
    required this.showTimestamp,
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

    // Delivery-label visibility: compact = latest outgoing plus separate
    // read/delivered boundaries, so the footer shows where the recipient read
    // up to instead of collapsing everything onto the bottom-most outgoing row.
    String? lastOutgoingKey;
    String? lastReadOutgoingKey;
    String? lastDeliveredOutgoingKey;
    for (final m in messages) {
      if (!m.isFromMe) continue;
      lastOutgoingKey = m.dedupeKey;
      final state = deliveryStateFor(m);
      if (state == MessageDeliveryState.read) {
        lastReadOutgoingKey = m.dedupeKey;
      } else if (state == MessageDeliveryState.delivered) {
        lastDeliveredOutgoingKey = m.dedupeKey;
      }
    }
    bool showStatusFor(MessageModel m) {
      switch (prefs.deliveryLabels) {
        case DeliveryLabelMode.off:
          return false;
        case DeliveryLabelMode.compact:
          return m.dedupeKey == lastOutgoingKey ||
              m.dedupeKey == lastReadOutgoingKey ||
              m.dedupeKey == lastDeliveredOutgoingKey;
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

    // The newest renderable row anchors a footer timestamp at the bottom of the
    // thread (BlueBubbles shows a time on the last message); everything else is
    // grouped under date/time separators or revealed on tap.
    final lastRowKey = rows.isNotEmpty ? rows.last.message.dedupeKey : null;

    final items = <ThreadViewItem>[];
    DateTime? lastDay;
    int? lastTs;
    for (final row in rows) {
      final m = row.message;
      final ts = m.dateCreated;
      if (ts != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ts);
        final day = DateTime(dt.year, dt.month, dt.day);
        if (lastDay == null || day != lastDay) {
          items.add(DateSeparatorItem(dayLabel(day)));
          lastDay = day;
        } else if (shouldShowTimeSeparator(lastTs, ts)) {
          // Same day but a large gap since the previous message: a time chip.
          items.add(TimeSeparatorItem(timeOfDayLabel(dt), m.dedupeKey));
        }
        lastTs = ts;
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
          systemLabel: isSystem
              ? _systemLabel(row.kind, m, senderName: resolveName(m.handleId))
              : null,
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
          showTimestamp: !isSystem && m.dedupeKey == lastRowKey,
        ),
      );
    }

    if (loadingOlder) items.add(LoadingOlderItem());
    return items;
  }

  static String _systemLabel(
    MessageRenderableKind kind,
    MessageModel m, {
    String? senderName,
  }) {
    switch (kind) {
      case MessageRenderableKind.service:
        return serviceEventLabel(m);
      case MessageRenderableKind.retracted:
        // Covers genuine unsends and the unrecoverable attachment placeholders
        // (missing_attachment_rows / empty_edited_residue) that C26 routes here.
        return retractedLabel(m, senderName: senderName);
      case MessageRenderableKind.reaction:
        final t = tapbackFromCode(m.associatedMessageType);
        if (t == null) return 'Reacted to a message';
        final emoji = tapbackEmoji(t.kind);
        return t.isRemoval
            ? 'Removed a $emoji reaction'
            : '$emoji Reacted to a message';
      default:
        if (m.semanticKind == 'deleted') return 'Message deleted';
        if (m.semanticKind == 'unavailable') return 'Message unavailable';
        return 'Unsupported message';
    }
  }
}

/// C21u: the gap (since the previous message, same day) above which a centered
/// time chip is shown. BlueBubbles groups closely-spaced messages and only
/// surfaces a timestamp when the conversation pauses.
const Duration kTimeClusterGap = Duration(minutes: 60);

/// Whether a same-day time separator should precede a message sent at [ts],
/// given the previous message's timestamp [prevTs]. Pure + testable.
bool shouldShowTimeSeparator(
  int? prevTs,
  int? ts, {
  Duration gap = kTimeClusterGap,
}) {
  if (prevTs == null || ts == null) return false;
  return (ts - prevTs) >= gap.inMilliseconds;
}

/// 12-hour clock label, e.g. "3:45 PM".
String timeOfDayLabel(DateTime dt) {
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final ampm = dt.hour < 12 ? 'AM' : 'PM';
  return '$hour12:$minute $ampm';
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
