import 'dart:convert';

import '../../core/models/connection_profile.dart';
import '../../core/network/endpoint_utils.dart';

/// Thrown when a scanned QR code is not a valid MicaGo pairing payload.
class PairingParseException implements Exception {
  final String message;
  const PairingParseException(this.message);
  @override
  String toString() => 'PairingParseException: $message';
}

/// A parsed MicaGo pairing payload (the JSON encoded in the server's QR code):
/// ```json
/// { "baseUrl": "https://micago.example.com",
///   "websocketUrl": "wss://micago.example.com/ws",
///   "token": "..." }
/// ```
class PairingPayload {
  final String baseUrl;
  final String? websocketUrl;
  final String token;

  const PairingPayload({
    required this.baseUrl,
    required this.token,
    this.websocketUrl,
  });

  /// The effective WebSocket URL: the explicit one if present, else derived.
  String get effectiveWsUrl =>
      (websocketUrl?.trim().isNotEmpty ?? false)
          ? websocketUrl!.trim()
          : deriveWebSocketUrl(baseUrl);

  ConnectionProfile toProfile() => ConnectionProfile(
        baseUrl: normalizeBaseUrl(baseUrl),
        token: token,
        wsUrlOverride:
            (websocketUrl?.trim().isNotEmpty ?? false) ? websocketUrl!.trim() : null,
      );

  /// Redacted — never prints the token.
  @override
  String toString() => 'PairingPayload(baseUrl: $baseUrl, '
      'websocketUrl: $websocketUrl, token: <redacted>)';
}

/// Parses and validates a scanned QR string. Throws [PairingParseException]
/// with a user-readable message on any problem. Pure function — unit-testable
/// without a camera.
PairingPayload parsePairingPayload(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const PairingParseException('The QR code was empty.');
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    throw const PairingParseException(
        "This QR code isn't a MicaGo pairing code.");
  }
  if (decoded is! Map<String, dynamic>) {
    throw const PairingParseException(
        "This QR code isn't a MicaGo pairing code.");
  }

  final baseUrl = (decoded['baseUrl'] as String?)?.trim() ?? '';
  final token = (decoded['token'] as String?)?.trim() ?? '';
  final wsRaw = (decoded['websocketUrl'] as String?)?.trim();

  if (baseUrl.isEmpty) {
    throw const PairingParseException('The pairing code is missing the server URL.');
  }
  if (!isValidHttpUrl(baseUrl)) {
    throw const PairingParseException('The server URL must be http or https.');
  }
  if (token.isEmpty) {
    throw const PairingParseException('The pairing code is missing the token.');
  }
  if (wsRaw != null && wsRaw.isNotEmpty) {
    final ws = Uri.tryParse(wsRaw);
    if (ws == null || (ws.scheme != 'ws' && ws.scheme != 'wss')) {
      throw const PairingParseException(
          'The WebSocket URL must be ws or wss.');
    }
  }

  return PairingPayload(
    baseUrl: baseUrl,
    token: token,
    websocketUrl: (wsRaw?.isNotEmpty ?? false) ? wsRaw : null,
  );
}
