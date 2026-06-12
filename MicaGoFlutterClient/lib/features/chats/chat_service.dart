/// The single client-side mapping from server-provided service fields to a
/// display/behavior category. The server is authoritative: it sends
/// `serviceCategory` ("imessage" | "sms" | "rcs" | "unknown") and the raw
/// `service`/`serviceName` string on chats and messages.
///
/// Deliberately takes ONLY server service fields — never a chat GUID, handle,
/// phone number, or display name — so the client cannot "guess" SMS from a
/// phone-shaped sender or a `any;-;` GUID. If the server doesn't provide a
/// usable value the result is [ChatService.unknown], not SMS.
enum ChatService { imessage, sms, rcs, unknown }

ChatService chatServiceFromServer({String? category, String? rawService}) {
  switch (category?.trim().toLowerCase()) {
    case 'imessage':
      return ChatService.imessage;
    case 'sms':
      return ChatService.sms;
    case 'rcs':
      return ChatService.rcs;
  }
  // Older server without serviceCategory: normalize the raw service string
  // with the same table the server uses (relaydb.ServiceCategory). This is
  // string normalization of a server value, not a heuristic.
  switch (rawService?.trim().toLowerCase()) {
    case 'imessage':
    case 'imessagelite':
      return ChatService.imessage;
    case 'sms':
    case 'text':
    case 'plain':
      return ChatService.sms;
    case 'rcs':
      return ChatService.rcs;
  }
  return ChatService.unknown;
}

extension ChatServiceDisplay on ChatService {
  String get label => switch (this) {
    ChatService.imessage => 'iMessage',
    ChatService.sms => 'SMS',
    ChatService.rcs => 'RCS',
    ChatService.unknown => 'Unknown',
  };

  /// Sending goes through the server's iMessage (AppleScript) pipeline only.
  /// SMS/RCS/unknown conversations are readable but read-only until the server
  /// explicitly supports sending there.
  bool get canSend => this == ChatService.imessage;
}
