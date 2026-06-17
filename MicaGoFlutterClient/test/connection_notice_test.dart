import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/connection_candidate.dart';
import 'package:mica_go/core/network/connection_notice.dart';
import 'package:mica_go/core/network/websocket_client.dart';

ConnectionSnapshot snap(
  WsStatus ws, {
  ConnectionCandidateKind? kind = ConnectionCandidateKind.lan,
  bool reachable = true,
}) =>
    ConnectionSnapshot(ws: ws, activeKind: kind, serverReachable: reachable);

void main() {
  group('connection notice derivation (transitions only, de-duped)', () {
    test('first connect is announced; steady connected says nothing', () {
      final first = connectionNoticeFor(
        snap(WsStatus.idle),
        snap(WsStatus.connected),
      );
      expect(first, ConnectionNotice.connected);

      final steady = connectionNoticeFor(
        snap(WsStatus.connected),
        snap(WsStatus.connected),
      );
      expect(steady, isNull, reason: 'no repeated alerts on steady state');
    });

    test('connected → failed while reachable = WebSocket lost', () {
      final n = connectionNoticeFor(
        snap(WsStatus.connected),
        snap(WsStatus.failed),
      );
      expect(n, ConnectionNotice.webSocketLost);
    });

    test('recovery after a non-idle drop = WebSocket recovered', () {
      final n = connectionNoticeFor(
        snap(WsStatus.failed),
        snap(WsStatus.connected),
      );
      expect(n, ConnectionNotice.webSocketRecovered);
    });

    test('reachable → unreachable = server unavailable (offline dominates)', () {
      final n = connectionNoticeFor(
        snap(WsStatus.connected),
        snap(WsStatus.failed, reachable: false),
      );
      expect(n, ConnectionNotice.serverUnavailable);

      final n2 = connectionNoticeFor(
        snap(WsStatus.connecting),
        snap(WsStatus.connecting, reachable: false),
      );
      expect(n2, ConnectionNotice.serverUnavailable);
    });

    test('clean WS close while still reachable = disconnected', () {
      final n = connectionNoticeFor(
        snap(WsStatus.connected),
        snap(WsStatus.disconnected),
      );
      expect(n, ConnectionNotice.disconnected);
    });

    test('LAN → Public switch is announced', () {
      final n = connectionNoticeFor(
        snap(WsStatus.connected, kind: ConnectionCandidateKind.lan),
        snap(WsStatus.connected, kind: ConnectionCandidateKind.public),
      );
      expect(n, ConnectionNotice.switchedToPublic);
    });

    test('Public → LAN switch is announced', () {
      final n = connectionNoticeFor(
        snap(WsStatus.connected, kind: ConnectionCandidateKind.public),
        snap(WsStatus.connected, kind: ConnectionCandidateKind.lan),
      );
      expect(n, ConnectionNotice.switchedToLan);
    });

    test('reconnecting is announced once on the connecting transition', () {
      final n = connectionNoticeFor(
        snap(WsStatus.failed),
        snap(WsStatus.connecting),
      );
      expect(n, ConnectionNotice.reconnecting);

      final steady = connectionNoticeFor(
        snap(WsStatus.connecting),
        snap(WsStatus.connecting),
      );
      expect(steady, isNull);
    });

    test('no baseline only announces a clearly-bad initial state', () {
      expect(connectionNoticeFor(null, snap(WsStatus.idle)), isNull);
      expect(
        connectionNoticeFor(null, snap(WsStatus.idle, reachable: false)),
        ConnectionNotice.serverUnavailable,
      );
    });

    test('display metadata: problems are sticky, recoveries are transient', () {
      expect(ConnectionNotice.serverUnavailable.isProblem, isTrue);
      expect(ConnectionNotice.switchedToPublic.isProblem, isTrue);
      expect(ConnectionNotice.connected.isTransient, isTrue);
      expect(ConnectionNotice.webSocketRecovered.isTransient, isTrue);
      expect(ConnectionNotice.switchedToLan.isTransient, isTrue);
    });
  });
}
