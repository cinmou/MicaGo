import '../network/endpoint_utils.dart';

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

  const ConnectionProfile({
    required this.baseUrl,
    required this.token,
    this.wsUrlOverride,
  });

  /// The WebSocket URL to connect to: the explicit override when present,
  /// otherwise derived from [baseUrl].
  String get effectiveWsUrl {
    final override = wsUrlOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    return deriveWebSocketUrl(baseUrl);
  }

  bool get isComplete => baseUrl.isNotEmpty && token.isNotEmpty;

  ConnectionProfile copyWith({
    String? baseUrl,
    String? token,
    String? wsUrlOverride,
  }) {
    return ConnectionProfile(
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      wsUrlOverride: wsUrlOverride ?? this.wsUrlOverride,
    );
  }

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'token': token,
        'wsUrlOverride': wsUrlOverride,
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    return ConnectionProfile(
      baseUrl: (json['baseUrl'] as String?) ?? '',
      token: (json['token'] as String?) ?? '',
      wsUrlOverride: json['wsUrlOverride'] as String?,
    );
  }

  /// Redacted description — never prints the token.
  @override
  String toString() =>
      'ConnectionProfile(baseUrl: $baseUrl, token: <redacted>, '
      'wsUrlOverride: $wsUrlOverride)';
}
