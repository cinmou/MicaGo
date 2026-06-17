/// C22 — pure push decision rules, kept free of any Firebase import so they can
/// be unit-tested and reasoned about in isolation. [PushService] composes these.
library;

/// BlueBubbles dedup rule: a foreground FCM message only needs a catch-up when
/// the realtime socket is NOT connected — if the socket is live it already
/// delivered the event, so the push is ignored (no duplicate work/bubbles).
bool pushShouldCatchUp({required bool realtimeConnected}) => !realtimeConnected;

/// The chat GUID a push routes to (notification tap → open this chat), or null.
String? pushChatGuid(Map<String, dynamic> data) {
  final guid = data['chatGuid'];
  return (guid is String && guid.isNotEmpty) ? guid : null;
}

/// Whether a push has anything worth showing as a local notification. Test
/// pushes and preview-disabled (empty title+body) pushes are skipped so we don't
/// raise an empty/noisy notification.
bool pushShouldNotify(Map<String, dynamic> data) {
  if ((data['type'] ?? '') == 'test') return false;
  final title = (data['title'] as String?)?.trim() ?? '';
  final body = (data['body'] as String?)?.trim() ?? '';
  return title.isNotEmpty || body.isNotEmpty;
}
