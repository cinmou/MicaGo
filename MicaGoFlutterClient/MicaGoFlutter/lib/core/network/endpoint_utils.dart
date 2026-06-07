/// URL helpers shared by the REST and WebSocket clients.
///
/// MicaGo serves REST under `/api` and a plain WebSocket at `/ws`. These helpers
/// normalise user-entered base URLs and derive the matching ws/wss URL.
library;

/// Normalises a user-entered server base URL:
/// - trims surrounding whitespace,
/// - defaults to `http://` when no scheme is present,
/// - removes any trailing slash.
///
/// Returns an empty string for empty input. It does not validate reachability.
String normalizeBaseUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  if (!value.contains('://')) {
    value = 'http://$value';
  }
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// Derives the WebSocket URL for the `/ws` endpoint from an http(s) base URL:
/// `http` → `ws`, `https` → `wss`, then appends `/ws` (unless the base already
/// ends in `/ws`).
///
/// Falls back to returning the input unchanged if it cannot be parsed.
String deriveWebSocketUrl(String baseUrl) {
  final normalized = normalizeBaseUrl(baseUrl);
  if (normalized.isEmpty) return '';

  final uri = Uri.tryParse(normalized);
  if (uri == null) return normalized;

  final scheme = switch (uri.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    'wss' => 'wss',
    'ws' => 'ws',
    _ => 'ws',
  };

  var path = uri.path;
  if (!path.endsWith('/ws')) {
    if (path.endsWith('/')) {
      path = '${path}ws';
    } else {
      path = '$path/ws';
    }
  }

  return uri.replace(scheme: scheme, path: path).toString();
}

/// Returns true when [value] parses to an absolute http(s) URL with a host.
bool isValidHttpUrl(String value) {
  final uri = Uri.tryParse(normalizeBaseUrl(value));
  if (uri == null) return false;
  return uri.hasScheme &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}
