import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// C31 — the single place that defines how a message notification looks and is
/// identified. Every path that shows one (the FCM background isolate, the
/// keep-alive local path, and the foreground init) goes through here so they are
/// visually identical and, crucially, **dedupe** against each other.

/// High-importance channel (heads-up) for new message notifications.
const String messageChannelId = 'micago_messages';
const String messageChannelName = 'Messages';
const String messageChannelDescription = 'New message notifications';

/// All message notifications share this group so the OS bundles them
/// (BlueBubbles parity).
const String messageGroupKey = 'micago.messages';

/// Direct-reply (Android RemoteInput) action + input identifiers. Replying from
/// the notification sends the text straight to the chat via the backend.
const String notificationReplyActionId = 'micago_reply';
const String notificationReplyInputId = 'micago_reply_text';

/// The Android channel created at init time. High importance so messages can
/// surface as heads-up notifications.
const AndroidNotificationChannel messageNotificationChannel =
    AndroidNotificationChannel(
  messageChannelId,
  messageChannelName,
  description: messageChannelDescription,
  importance: Importance.high,
);

/// Stable notification id for a message GUID. Using the **same** id from every
/// path means an FCM push and a keep-alive local notification for the same
/// message collapse into ONE notification (the second `show` replaces the first)
/// instead of stacking duplicates — this is the cross-path dedup (C31).
int notificationIdForMessage(String? messageGuid) =>
    (messageGuid ?? '').hashCode;

/// Builds the Android details (channel, grouping, optional inline reply).
/// [canReply] adds a RemoteInput "Reply" action when we know the target chat.
AndroidNotificationDetails messageAndroidDetails({required bool canReply}) {
  return AndroidNotificationDetails(
    messageChannelId,
    messageChannelName,
    channelDescription: messageChannelDescription,
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.message,
    groupKey: messageGroupKey,
    actions: canReply
        ? const <AndroidNotificationAction>[
            AndroidNotificationAction(
              notificationReplyActionId,
              'Reply',
              inputs: <AndroidNotificationActionInput>[
                AndroidNotificationActionInput(label: 'Reply'),
              ],
              // Send in the background without opening the app.
              showsUserInterface: false,
              cancelNotification: true,
            ),
          ]
        : null,
  );
}

/// Whether the OS currently allows notifications (Android 13+ POST_NOTIFICATIONS).
/// Returns null on platforms without the concept. Cheap — does not require the
/// plugin to be initialized first.
Future<bool?> systemNotificationsEnabled() async {
  return FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.areNotificationsEnabled();
}

/// Prompts for the Android 13+ POST_NOTIFICATIONS permission (no-op below 13 or
/// when already granted). Returns the resulting grant state, or null off-Android.
Future<bool?> requestSystemNotificationPermission() async {
  return FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

/// Shows a message notification via [plugin]. [title]/[body] must already be
/// formatted (contact name resolved, preview applied). [chatGuid] is the tap +
/// reply payload; [messageGuid] is the dedup id.
Future<void> showMessageNotification(
  FlutterLocalNotificationsPlugin plugin, {
  required String title,
  String? body,
  required String? chatGuid,
  required String? messageGuid,
}) async {
  final canReply = chatGuid != null && chatGuid.isNotEmpty;
  await plugin.show(
    notificationIdForMessage(messageGuid),
    title,
    body,
    NotificationDetails(android: messageAndroidDetails(canReply: canReply)),
    payload: chatGuid,
  );
}
