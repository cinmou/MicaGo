import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../features/chats/models/chat_summary.dart';
import '../../features/chats/models/message_model.dart';
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

  /// A plain-language explanation suitable for the UI. Never contains the token.
  /// Cloudflare 5xx (520–530) are mapped to tunnel/origin guidance.
  String get friendly {
    final s = statusCode;
    if (s == 530) {
      return 'Cloudflare reached the hostname but could not resolve/connect to '
          'the configured origin (530). Check the selected endpoint, tunnel '
          'route, and Public URL — the tunnel may not be running.';
    }
    if (s == 502 || s == 504) {
      return 'The remote endpoint was reached, but the server behind it did not '
          'respond ($s). Make sure MicaGo is running and the tunnel forwards to '
          'its port.';
    }
    if (s != null && s >= 520 && s <= 527) {
      return 'Cloudflare could not reach the origin server ($s). Check the '
          'tunnel and that MicaGo is running.';
    }
    switch (code) {
      case 'unauthorized':
        return 'The bearer token was rejected (401). Re-pair with the server.';
      case 'timeout':
        return 'The server did not respond in time.';
      case 'network_error':
        return 'Could not reach the server. Check the URL and your network.';
      case 'bad_response':
        return 'Unexpected response — is this a MicaGo server?';
      default:
        return s != null ? '$message ($s)' : message;
    }
  }
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

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse('${normalizeBaseUrl(baseUrl)}$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: {...base.queryParameters, ...query});
  }

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      };

  /// The exact URLs the diagnostics view probes (no token in the URL).
  String get healthUrl => _uri('/api/health').toString();
  String get authCheckUrl => _uri('/api/auth/check').toString();

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

  /// `GET /api/chats` — the chat list. Returns the `data` array decoded into
  /// [ChatSummary]. The optional `service`/`withArchived` query params default
  /// to the server's behaviour (iMessage, non-archived) unless provided.
  Future<List<ChatSummary>> getChats({
    String? service,
    bool? withArchived,
    int? limit,
  }) async {
    final query = <String, String>{};
    if (service != null) query['service'] = service;
    if (withArchived != null) query['withArchived'] = '$withArchived';
    if (limit != null) query['limit'] = '$limit';
    final res = await _send(() => _http
        .get(_uri('/api/chats', query), headers: _authHeaders)
        .timeout(timeout));
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final body = _decodeObject(res);
    final data = body['data'];
    if (data is! List) {
      throw const ApiException(
        code: 'bad_response',
        message: 'Chat list response was not in the expected format.',
      );
    }
    return data
        .whereType<Map<String, dynamic>>()
        .map(ChatSummary.fromJson)
        .toList(growable: false);
  }

  /// `GET /api/chats/{guid}/messages` — message history for one chat. The
  /// server returns newest-first; callers reverse to chronological order.
  Future<List<MessageModel>> getMessages(
    String chatGuid, {
    int limit = 50,
    int offset = 0,
    bool includeEmpty = false,
  }) async {
    final res = await _send(() => _http
        .get(
          _uri('/api/chats/${Uri.encodeComponent(chatGuid)}/messages', {
            'limit': '$limit',
            'offset': '$offset',
            'includeEmpty': '$includeEmpty',
          }),
          headers: _authHeaders,
        )
        .timeout(timeout));
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final data = _decodeObject(res)['data'];
    if (data is! List) {
      throw const ApiException(
        code: 'bad_response',
        message: 'Message list response was not in the expected format.',
      );
    }
    return data
        .whereType<Map<String, dynamic>>()
        .map(MessageModel.fromJson)
        .toList(growable: false);
  }

  /// `POST /api/chats/{guid}/send` — send plain text. Synchronous: the server
  /// waits until it confirms the outgoing row (or times out). Returns the
  /// confirmed [MessageModel]. [tempGuid] is the client correlation id.
  Future<MessageModel> sendText({
    required String chatGuid,
    required String tempGuid,
    required String message,
  }) async {
    final res = await _send(() => _http
        .post(
          _uri('/api/chats/${Uri.encodeComponent(chatGuid)}/send'),
          headers: {..._authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode({'tempGuid': tempGuid, 'message': message}),
        )
        // Send confirmation can take up to ~15s server-side.
        .timeout(const Duration(seconds: 20)));
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    return MessageModel.fromJson(_decodeObject(res));
  }

  /// `GET /api/attachments/{guid}` — raw attachment bytes (authenticated).
  Future<Uint8List> getAttachmentBytes(String attachmentGuid) async {
    final res = await _send(() => _http
        .get(
          _uri('/api/attachments/${Uri.encodeComponent(attachmentGuid)}'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 30)));
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    return res.bodyBytes;
  }

  /// Absolute URL for an attachment, for media players that stream by URL.
  /// Pair it with [mediaAuthHeaders] so the token travels in the header, not
  /// the URL.
  String attachmentUrl(String attachmentGuid) =>
      _uri('/api/attachments/${Uri.encodeComponent(attachmentGuid)}').toString();

  /// Authorization headers for streaming media (e.g. just_audio). Kept out of
  /// the URL so the token isn't logged by proxies.
  Map<String, String> get mediaAuthHeaders => {'Authorization': 'Bearer $token'};

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
