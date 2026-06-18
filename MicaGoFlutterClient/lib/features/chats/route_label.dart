import 'chat_service.dart';
import 'models/chat_summary.dart';

/// C24: builds a route label that includes the concrete handle/address, so
/// multiple routes with the **same** service (e.g. two iMessage chats on
/// different numbers/emails) are distinguishable. Pure + unit-testable.
///
/// Examples: "iMessage · +44 7700 900123", "iMessage · a@icloud.com",
/// "SMS · +86 180 0000 0000", "Unknown · some-handle". A resolved contact
/// [name] is appended when it adds information beyond the handle.
String routeLabel(ChatSummary route, {String? name}) {
  final service = route.service.label;
  final handle = _handleOf(route);
  if (handle.isEmpty) {
    // No handle (e.g. a group) — fall back to the title or just the service.
    final title = route.title.trim();
    return title.isEmpty ? service : '$service · $title';
  }
  final trimmedName = name?.trim() ?? '';
  if (trimmedName.isNotEmpty && trimmedName != handle) {
    return '$service · $trimmedName ($handle)';
  }
  return '$service · $handle';
}

/// The concrete phone/email/handle for a route, or empty when unavailable.
String routeHandle(ChatSummary route) => _handleOf(route);

String _handleOf(ChatSummary route) {
  if (route.isGroup) return '';
  return route.chatIdentifier?.trim() ?? '';
}

/// Short sendability hint for the route detail row. Server-authoritative — never
/// inferred from the handle/GUID shape.
String routeSendabilityLabel(ChatSummary route, {required bool allowSmsSend}) {
  return route.canSendText(allowSmsSend: allowSmsSend) ? 'Can send' : 'Read only';
}
