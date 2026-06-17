import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';

void main() {
  group('C21 delta cursor fetch', () {
    test('parses messages, chatGuids, cursor, hasMore', () async {
      late Uri captured;
      final mock = MockClient((req) async {
        captured = req.url;
        return http.Response(
          jsonEncode({
            'messages': [
              {'guid': 'm1', 'chatGuid': 'cA', 'text': 'hi', 'sourceRowId': 11},
              {'guid': 'm2', 'chatGuid': 'cB', 'text': 'yo', 'sourceRowId': 12},
            ],
            'chatGuids': ['cA', 'cB'],
            'cursor': 12,
            'hasMore': false,
          }),
          200,
        );
      });
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:3000',
        token: 'tok',
        httpClient: mock,
      );

      final delta = await api.fetchDelta(since: 10);
      expect(captured.path, '/api/messages/delta');
      expect(captured.queryParameters['since'], '10');
      expect(delta.messages.length, 2);
      expect(delta.messages.first.guid, 'm1');
      expect(delta.chatGuids, ['cA', 'cB']);
      expect(delta.cursor, 12);
      expect(delta.hasMore, isFalse);
    });

    test('seed (since=null) omits the since param', () async {
      late Uri captured;
      final mock = MockClient((req) async {
        captured = req.url;
        return http.Response(
          jsonEncode({'messages': [], 'chatGuids': [], 'cursor': 99, 'hasMore': false}),
          200,
        );
      });
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:3000',
        token: 'tok',
        httpClient: mock,
      );

      final delta = await api.fetchDelta();
      expect(captured.queryParameters.containsKey('since'), isFalse);
      expect(delta.cursor, 99);
      expect(delta.messages, isEmpty);
    });
  });
}
