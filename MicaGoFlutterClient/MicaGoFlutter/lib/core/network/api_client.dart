import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/server_urls.dart';
import 'endpoint_utils.dart';

/// A structured error from a MicaGo REST call. [code] is the stable
/// machine-readable string from the server error envelope (`{"error":{...}}`)
/// or a client-side code (`network_error`, `timeout`, `bad_response`).
class ApiException implements Exception {
  final String code;
  final String message;
  final int? statusCode;

  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  @override
  String toString() => 'ApiException($code'
      '${statusCode != null ? ' [$statusCode]' : ''}): $message';
}

/// Minimal REST client for the MicaGo server.
///
/// Only the endpoints needed for the C0 foundation are implemented:
/// `GET /api/health`, `POST /api/auth/check`, `GET /api/server/urls`.
/// The bearer token is attached to every authenticated call; it is never
/// logged.
class ApiClient {
  final String baseUrl;
  final String token;
  final http.Client _http;
  final Duration timeout;

  ApiClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 12),
  }) : _http = httpClient ?? http.Client();

  Uri _uri(String path) => Uri.parse('${normalizeBaseUrl(baseUrl)}$path');

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      };

  /// `GET /api/health` — no auth. Returns true when the server reports `ok`.
  Future<bool> health() async {
    final res = await _send(() => _http
        .get(_uri('/api/health'), headers: const {'Accept': 'application/json'})
        .timeout(timeout));
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final body = _decodeObject(res);
    return body['ok'] == true;
  }

  /// `POST /api/auth/check` — verifies the bearer token. Throws [ApiException]
  /// (`code: unauthorized`) on 401, or another code on failure.
  Future<void> authCheck() async {
    final res = await _send(() => _http
        .post(_uri('/api/auth/check'), headers: _authHeaders)
        .timeout(timeout));
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
  }

  /// `GET /api/server/urls` — aggregated connection endpoints (v0.11).
  Future<ServerUrls> getServerUrls() async {
    final res = await _send(() => _http
        .get(_uri('/api/server/urls'), headers: _authHeaders)
        .timeout(timeout));
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    return ServerUrls.fromJson(_decodeObject(res));
  }

  void close() => _http.close();

  // --- internals -------------------------------------------------------------

  Future<http.Response> _send(Future<http.Response> Function() run) async {
    try {
      return await run();
    } on TimeoutException {
      throw const ApiException(
        code: 'timeout',
        message: 'The server did not respond in time.',
      );
    } catch (e) {
      throw ApiException(
        code: 'network_error',
        message: 'Could not reach the server: $e',
      );
    }
  }

  Map<String, dynamic> _decodeObject(http.Response res) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException('expected a JSON object');
    } catch (_) {
      throw ApiException(
        code: 'bad_response',
        message: 'The server returned an unexpected response.',
        statusCode: res.statusCode,
      );
    }
  }

  /// Builds an [ApiException] from a non-2xx response, parsing the standard
  /// `{"error":{"code","message"}}` envelope when present.
  ApiException _errorFrom(http.Response res) {
    String code = 'http_${res.statusCode}';
    String message = 'Request failed (HTTP ${res.statusCode}).';
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic> &&
          decoded['error'] is Map<String, dynamic>) {
        final err = decoded['error'] as Map<String, dynamic>;
        code = (err['code'] as String?) ?? code;
        message = (err['message'] as String?) ?? message;
      }
    } catch (_) {
      // Non-JSON body; keep the generic HTTP message.
    }
    return ApiException(code: code, message: message, statusCode: res.statusCode);
  }
}
