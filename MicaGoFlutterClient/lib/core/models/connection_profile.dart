import '../network/endpoint_utils.dart';

enum ConnectionMode { auto, lanOnly, publicOnly, lanFirst }

ConnectionMode connectionModeFromWire(String? value) {
  switch (value) {
    case 'lan_only':
      return ConnectionMode.lanOnly;
    case 'public_only':
      return ConnectionMode.publicOnly;
    case 'lan_first':
      return ConnectionMode.lanFirst;
    default:
      return ConnectionMode.auto;
  }
}

String connectionModeToWire(ConnectionMode mode) {
  switch (mode) {
    case ConnectionMode.lanOnly:
      return 'lan_only';
    case ConnectionMode.publicOnly:
      return 'public_only';
    case ConnectionMode.lanFirst:
      return 'lan_first';
    case ConnectionMode.auto:
      return 'auto';
  }
}

/// A saved MicaGo server connection. Persisted locally (token in secure
/// storage). The token is never included in `toString()` to avoid leaking it
/// into logs.
class ConnectionProfile {
  /// Normalised http(s) base URL, e.g. `https://mica.example.com`.
  final String baseUrl;

  /// Shared bearer token.
  final String token;

  /// Optional explicit WebSocket URL. When null/empty, [effectiveWsUrl] derives
  /// it from [baseUrl].
  final String? wsUrlOverride;
  final String? lanBaseUrl;
  final String? lanWsUrl;
  final String? publicBaseUrl;
  final String? publicWsUrl;
  final ConnectionMode mode;

  /// C23: the server connection-config revision this profile was last synced to.
  /// Used to detect when the server's LAN/Public candidates change so the client
  /// can refresh them without rescanning a QR.
  final String configRevision;

  const ConnectionProfile({
    required this.baseUrl,
    required this.token,
    this.wsUrlOverride,
    this.lanBaseUrl,
    this.lanWsUrl,
    this.publicBaseUrl,
    this.publicWsUrl,
    this.mode = ConnectionMode.auto,
    this.configRevision = '',
  });

  String get effectiveBaseUrl {
    switch (mode) {
      case ConnectionMode.lanOnly:
        return _nonEmpty(lanBaseUrl) ?? baseUrl;
      case ConnectionMode.publicOnly:
        return _nonEmpty(publicBaseUrl) ?? baseUrl;
      case ConnectionMode.lanFirst:
      case ConnectionMode.auto:
        return _nonEmpty(lanBaseUrl) ?? _nonEmpty(publicBaseUrl) ?? baseUrl;
    }
  }

  /// The WebSocket URL to connect to: the explicit override when present,
  /// otherwise derived from [baseUrl].
  String get effectiveWsUrl {
    final override = wsUrlOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    switch (mode) {
      case ConnectionMode.lanOnly:
        return _nonEmpty(lanWsUrl) ?? deriveWebSocketUrl(effectiveBaseUrl);
      case ConnectionMode.publicOnly:
        return _nonEmpty(publicWsUrl) ?? deriveWebSocketUrl(effectiveBaseUrl);
      case ConnectionMode.lanFirst:
      case ConnectionMode.auto:
        return _nonEmpty(lanWsUrl) ??
            _nonEmpty(publicWsUrl) ??
            deriveWebSocketUrl(effectiveBaseUrl);
    }
  }

  bool get isComplete => effectiveBaseUrl.isNotEmpty && token.isNotEmpty;

  ConnectionProfile copyWith({
    String? baseUrl,
    String? token,
    String? wsUrlOverride,
    String? lanBaseUrl,
    String? lanWsUrl,
    String? publicBaseUrl,
    String? publicWsUrl,
    ConnectionMode? mode,
    String? configRevision,
  }) {
    return ConnectionProfile(
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      wsUrlOverride: wsUrlOverride ?? this.wsUrlOverride,
      lanBaseUrl: lanBaseUrl ?? this.lanBaseUrl,
      lanWsUrl: lanWsUrl ?? this.lanWsUrl,
      publicBaseUrl: publicBaseUrl ?? this.publicBaseUrl,
      publicWsUrl: publicWsUrl ?? this.publicWsUrl,
      mode: mode ?? this.mode,
      configRevision: configRevision ?? this.configRevision,
    );
  }

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'token': token,
    'wsUrlOverride': wsUrlOverride,
    'lanBaseUrl': lanBaseUrl,
    'lanWsUrl': lanWsUrl,
    'publicBaseUrl': publicBaseUrl,
    'publicWsUrl': publicWsUrl,
    'mode': connectionModeToWire(mode),
    'configRevision': configRevision,
  };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    return ConnectionProfile(
      baseUrl: (json['baseUrl'] as String?) ?? '',
      token: (json['token'] as String?) ?? '',
      wsUrlOverride: json['wsUrlOverride'] as String?,
      lanBaseUrl: json['lanBaseUrl'] as String?,
      lanWsUrl: json['lanWsUrl'] as String?,
      publicBaseUrl: json['publicBaseUrl'] as String?,
      publicWsUrl: json['publicWsUrl'] as String?,
      mode: connectionModeFromWire(json['mode'] as String?),
      configRevision: (json['configRevision'] as String?) ?? '',
    );
  }

  /// Redacted description — never prints the token.
  @override
  String toString() =>
      'ConnectionProfile(baseUrl: $baseUrl, token: <redacted>, '
      'wsUrlOverride: $wsUrlOverride, mode: ${connectionModeToWire(mode)})';
}

String? _nonEmpty(String? value) {
  final v = value?.trim() ?? '';
  return v.isEmpty ? null : v;
}
