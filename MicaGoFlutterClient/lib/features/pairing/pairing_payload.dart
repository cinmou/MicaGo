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

/// The kind of a pairing endpoint candidate. `local`/loopback is accepted for
/// back-compat but is never surfaced as a user-facing pairing option.
enum EndpointKind { lan, public, local }

EndpointKind endpointKindFromWire(String? v) {
  switch (v) {
    case 'lan':
      return EndpointKind.lan;
    case 'public':
      return EndpointKind.public;
    default:
      return EndpointKind.local;
  }
}

/// One candidate endpoint from a v2 pairing payload.
class PairingEndpoint {
  final EndpointKind kind;
  final String baseUrl;
  final String? wsUrl;
  final int priority; // lower = tried first

  const PairingEndpoint({
    required this.kind,
    required this.baseUrl,
    this.wsUrl,
    this.priority = 1,
  });

  String get effectiveWsUrl => (wsUrl?.trim().isNotEmpty ?? false)
      ? wsUrl!.trim()
      : deriveWebSocketUrl(baseUrl);
}

/// A parsed MicaGo pairing payload. Supports both the legacy v1 shape
/// (`{baseUrl, websocketUrl?, token}`) and the C10 v2 shape:
/// ```json
/// { "version": 2, "mode": "lanFirst", "token": "...",
///   "serverName": "Mac mini",
///   "endpoints": [
///     {"kind":"lan","baseUrl":"http://192.168.1.23:3000","priority":1},
///     {"kind":"public","baseUrl":"https://micago.example.com","priority":2}
///   ] }
/// ```
class PairingPayload {
  final int version;
  final ConnectionMode mode;
  final String token;
  final String? serverName;
  final List<PairingEndpoint> endpoints;

  const PairingPayload({
    required this.version,
    required this.mode,
    required this.token,
    required this.endpoints,
    this.serverName,
  });

  PairingEndpoint? get _primary => endpoints.isEmpty ? null : endpoints.first;

  PairingEndpoint? get lan =>
      endpoints.where((e) => e.kind == EndpointKind.lan).firstOrNull;
  PairingEndpoint? get public =>
      endpoints.where((e) => e.kind == EndpointKind.public).firstOrNull;

  /// Back-compat: the primary base URL (LAN first, else whatever leads).
  String get baseUrl => (lan ?? _primary)?.baseUrl ?? '';
  String? get websocketUrl => (lan ?? _primary)?.wsUrl;
  String get effectiveWsUrl =>
      (lan ?? _primary)?.effectiveWsUrl ?? deriveWebSocketUrl(baseUrl);

  /// Builds the saved connection profile, populating LAN/Public URLs + mode so
  /// the runtime endpoint selector can fall back correctly.
  ConnectionProfile toProfile() {
    final lanE = lan;
    final publicE = public;
    final primary = lanE ?? _primary;
    return ConnectionProfile(
      baseUrl: normalizeBaseUrl(primary?.baseUrl ?? ''),
      token: token,
      wsUrlOverride: (primary?.wsUrl?.trim().isNotEmpty ?? false)
          ? primary!.wsUrl!.trim()
          : null,
      lanBaseUrl: lanE == null ? null : normalizeBaseUrl(lanE.baseUrl),
      lanWsUrl: lanE?.wsUrl,
      publicBaseUrl: publicE == null ? null : normalizeBaseUrl(publicE.baseUrl),
      publicWsUrl: publicE?.wsUrl,
      mode: mode,
    );
  }

  @override
  String toString() =>
      'PairingPayload(v$version, mode: $mode, endpoints: ${endpoints.length}, token: <redacted>)';
}

/// Parses and validates a scanned QR string (v1 or v2). Throws
/// [PairingParseException] with a user-readable message. Pure + unit-testable.
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
      "This QR code isn't a MicaGo pairing code.",
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw const PairingParseException(
      "This QR code isn't a MicaGo pairing code.",
    );
  }

  final token = (decoded['token'] as String?)?.trim() ?? '';
  if (token.isEmpty) {
    throw const PairingParseException('The pairing code is missing the token.');
  }

  final version = (decoded['version'] as num?)?.toInt() ?? 1;
  if (version >= 2 && decoded['endpoints'] is List) {
    return _parseV2(decoded, token);
  }
  return _parseV1(decoded, token);
}

PairingPayload _parseV1(Map<String, dynamic> decoded, String token) {
  final baseUrl = (decoded['baseUrl'] as String?)?.trim() ?? '';
  final wsRaw = (decoded['websocketUrl'] as String?)?.trim();
  if (baseUrl.isEmpty) {
    throw const PairingParseException(
      'The pairing code is missing the server URL.',
    );
  }
  if (!isValidHttpUrl(baseUrl)) {
    throw const PairingParseException('The server URL must be http or https.');
  }
  _validateWs(wsRaw);
  return PairingPayload(
    version: 1,
    mode: ConnectionMode.auto,
    token: token,
    endpoints: [
      PairingEndpoint(
        kind: EndpointKind.lan,
        baseUrl: baseUrl,
        wsUrl: (wsRaw?.isNotEmpty ?? false) ? wsRaw : null,
        priority: 1,
      ),
    ],
  );
}

PairingPayload _parseV2(Map<String, dynamic> decoded, String token) {
  final mode = connectionModeFromWire(decoded['mode'] as String?);
  final rawEndpoints = (decoded['endpoints'] as List)
      .whereType<Map<String, dynamic>>()
      .toList(growable: false);

  final parsed = <PairingEndpoint>[];
  for (final e in rawEndpoints) {
    final baseUrl = (e['baseUrl'] as String?)?.trim() ?? '';
    if (baseUrl.isEmpty || !isValidHttpUrl(baseUrl)) continue;
    final ws = (e['wsUrl'] as String?)?.trim();
    _validateWs(ws);
    parsed.add(
      PairingEndpoint(
        kind: endpointKindFromWire(e['kind'] as String?),
        baseUrl: baseUrl,
        wsUrl: (ws?.isNotEmpty ?? false) ? ws : null,
        priority: (e['priority'] as num?)?.toInt() ?? 1,
      ),
    );
  }

  // Drop loopback/local from the user-facing candidate set; sort by priority.
  final usable = parsed.where((e) => e.kind != EndpointKind.local).toList()
    ..sort((a, b) => a.priority.compareTo(b.priority));
  if (usable.isEmpty) {
    throw const PairingParseException(
      'The pairing code has no usable LAN or public endpoint.',
    );
  }

  // LAN-only must never carry a public endpoint.
  final endpoints = mode == ConnectionMode.lanOnly
      ? usable.where((e) => e.kind == EndpointKind.lan).toList()
      : usable;
  if (endpoints.isEmpty) {
    throw const PairingParseException(
      'The pairing code is LAN-only but has no LAN endpoint.',
    );
  }

  return PairingPayload(
    version: 2,
    mode: mode == ConnectionMode.auto ? ConnectionMode.lanFirst : mode,
    token: token,
    serverName: (decoded['serverName'] as String?)?.trim(),
    endpoints: endpoints,
  );
}

void _validateWs(String? wsRaw) {
  if (wsRaw == null || wsRaw.isEmpty) return;
  final ws = Uri.tryParse(wsRaw);
  if (ws == null || (ws.scheme != 'ws' && ws.scheme != 'wss')) {
    throw const PairingParseException('The WebSocket URL must be ws or wss.');
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
