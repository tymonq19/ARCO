/// Session lifecycle: the hello deadline, the concurrent-session caps and the
/// WebSocket keep-alive ping that reclaims half-open sockets (SPEC §3).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Index just past the `\r\n\r\n` that ends the HTTP upgrade response, or -1.
int _endOfHeaders(List<int> bytes) {
  for (var i = 3; i < bytes.length; i++) {
    if (bytes[i] == 10 &&
        bytes[i - 1] == 13 &&
        bytes[i - 2] == 10 &&
        bytes[i - 3] == 13) {
      return i + 1;
    }
  }
  return -1;
}

void main() {
  group('hello deadline', () {
    test('a socket that never says hello is closed and forgotten', () async {
      final server = await bootServer(
        helloTimeout: const Duration(milliseconds: 100),
      );
      final a = await TestClient.connect(server);
      await pumpUntil(() => server.rooms.sessionCount == 1);

      await a.closed.timeout(const Duration(seconds: 5));
      expect(a.closeCode, closeCodeProtocolError);
      await pumpUntil(
        () => server.rooms.sessionCount == 0,
        reason: 'a silent socket must not stay registered forever',
      );
    });

    test('a successful hello cancels the deadline', () async {
      final server = await bootServer(
        helloTimeout: const Duration(milliseconds: 100),
      );
      final a = await TestClient.connect(server, name: 'Alice');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(a.isClosed, isFalse);
      expect(server.rooms.sessionCount, 1);

      // Still a working session.
      a.send(const CreateRoomMsg());
      await a.nextOf<RoomMsg>();
    });
  });

  group('session caps', () {
    test('the global cap refuses further sockets', () async {
      final server = await bootServer(maxSessions: 2);
      final a = await TestClient.connect(server, name: 'Alice');
      final b = await TestClient.connect(server, name: 'Bob');
      expect(server.rooms.sessionCount, 2);

      final c = await TestClient.connect(server);
      final refused = await c.next(timeout: const Duration(seconds: 5));
      expect(refused, isA<ErrorMsg>());
      expect((refused as ErrorMsg).code, 'rate_limited');
      await c.closed.timeout(const Duration(seconds: 5));
      expect(c.closeCode, closeCodePolicyViolation);

      expect(server.rooms.sessionCount, 2);
      expect(a.isClosed, isFalse);
      expect(b.isClosed, isFalse);
    });

    test('the per-IP cap refuses further sockets and frees on close', () async {
      final server = await bootServer(maxSessionsPerIp: 1);
      final a = await TestClient.connect(server, name: 'Alice');
      expect(server.rooms.sessionCount, 1);

      final b = await TestClient.connect(server);
      await b.closed.timeout(const Duration(seconds: 5));
      expect(b.closeCode, closeCodePolicyViolation);
      expect(server.rooms.sessionCount, 1);

      // The slot is given back when the first client goes away.
      await a.close();
      await pumpUntil(() => server.rooms.sessionCount == 0);
      final c = await TestClient.connect(server, name: 'Carol');
      expect(c.isClosed, isFalse);
      expect(server.rooms.sessionCount, 1);
    });
  });

  group('keep-alive ping', () {
    test('the server pings an idle socket', () async {
      final server = await bootServer(
        wsPingInterval: const Duration(milliseconds: 100),
        helloTimeout: const Duration(seconds: 30),
      );
      final socket = await Socket.connect(server.address, server.port);
      addTearDown(socket.destroy);

      final key = base64.encode(List<int>.generate(16, (i) => i * 7 + 1));
      socket.write(
        'GET /ws HTTP/1.1\r\n'
        'Host: ${server.address.address}:${server.port}\r\n'
        'Connection: Upgrade\r\n'
        'Upgrade: websocket\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: $key\r\n'
        '\r\n',
      );
      await socket.flush();

      // A peer that never answers: the socket stays open at the TCP level and
      // sends nothing at all, exactly like a phone that lost coverage.
      final bytes = <int>[];
      final sub = socket.listen(bytes.addAll, onError: (Object _) {});
      addTearDown(sub.cancel);

      await pumpUntil(
        () => _endOfHeaders(bytes) >= 0,
        reason: 'the upgrade must complete',
      );
      expect(
        utf8.decode(bytes.sublist(0, _endOfHeaders(bytes))),
        contains('101 Switching Protocols'),
      );

      // Server → client frames are unmasked; a ping is FIN + opcode 0x9 with
      // an empty payload, i.e. the two bytes 0x89 0x00.
      await pumpUntil(() {
        final start = _endOfHeaders(bytes);
        return start >= 0 && bytes.length > start && bytes[start] == 0x89;
      }, reason: 'an idle socket must be probed with a ping frame');
    });
  });
}
