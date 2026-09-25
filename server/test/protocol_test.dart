/// WebSocket protocol enforcement: hello-first, error codes, frame limits, the
/// bad-message budget, the room-creation rate limit and the per-socket message
/// budget (SPEC §3).
library;

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late ArcoServer server;

  setUp(() async {
    server = await bootServer();
  });

  group('hello handshake', () {
    test('any message before hello is a bad_message', () async {
      final c = await TestClient.connect(server);
      c.send(const CreateRoomMsg());
      final err = await c.nextOf<ErrorMsg>();
      expect(err.code, 'bad_message');
      expect(server.rooms.roomCount, 0);

      // The handshake still works afterwards.
      c.send(const HelloMsg(version: protocolVersion, name: 'Late'));
      expect((await c.nextOf<WelcomeMsg>()).version, protocolVersion);
    });

    test('a second hello is a violation', () async {
      final c = await TestClient.connect(server, name: 'Twice');
      c.send(const HelloMsg(version: protocolVersion, name: 'Twice'));
      expect((await c.nextOf<ErrorMsg>()).code, 'bad_message');
    });

    test('an unsupported protocol version closes the socket', () async {
      final c = await TestClient.connect(server);
      c.send(const HelloMsg(version: protocolVersion + 1, name: 'Old'));
      expect((await c.nextOf<ErrorMsg>()).code, 'bad_version');
      await c.closed.timeout(const Duration(seconds: 5));
      expect(c.closeCode, closeCodeProtocolError);
    });

    test('an invalid name is rejected without closing', () async {
      final c = await TestClient.connect(server);
      c.send(const HelloMsg(version: protocolVersion, name: 'x'));
      expect((await c.nextOf<ErrorMsg>()).code, 'bad_name');
      c.send(const HelloMsg(version: protocolVersion, name: 'bad!!name'));
      expect((await c.nextOf<ErrorMsg>()).code, 'bad_name');
      expect(c.isClosed, isFalse);
    });

    test('names are trimmed and inner whitespace collapsed', () async {
      final a = await TestClient.connect(server, name: '  Ty  mek  ');
      a.send(const CreateRoomMsg());
      expect((await a.nextOf<RoomMsg>()).names.first, 'Ty mek');
    });
  });

  group('room errors', () {
    test(
      'bad_code for a code outside the alphabet or of the wrong length',
      () async {
        final c = await TestClient.connect(server, name: 'Coder');
        for (final code in <String>['AB', 'ABCDE', 'AB0O', 'ab!?']) {
          c.send(JoinRoomMsg(code: code));
          expect(
            (await c.nextOf<ErrorMsg>()).code,
            'bad_code',
            reason: 'code "$code"',
          );
        }
        // Rejected codes are not protocol violations, so the socket stays open.
        expect(c.isClosed, isFalse);
      },
    );

    test('room_not_found for a well-formed but unknown code', () async {
      final c = await TestClient.connect(server, name: 'Seeker');
      c.send(const JoinRoomMsg(code: 'ZZZZ'));
      expect((await c.nextOf<ErrorMsg>()).code, 'room_not_found');
    });

    test('lower-case codes are normalized', () async {
      final a = await TestClient.connect(server, name: 'Host');
      a.send(const CreateRoomMsg());
      final room = await a.nextOf<RoomMsg>();
      final b = await TestClient.connect(server, name: 'Guest');
      b.send(JoinRoomMsg(code: room.code.toLowerCase()));
      expect((await b.nextOf<RoomMsg>()).code, room.code);
    });

    test('room_full for a third player', () async {
      final a = await TestClient.connect(server, name: 'One');
      a.send(const CreateRoomMsg());
      final room = await a.nextOf<RoomMsg>();
      final b = await TestClient.connect(server, name: 'Two');
      b.send(JoinRoomMsg(code: room.code));
      await b.nextOf<RoomMsg>();

      final c = await TestClient.connect(server, name: 'Three');
      c.send(JoinRoomMsg(code: room.code));
      expect((await c.nextOf<ErrorMsg>()).code, 'room_full');
    });

    test('not_in_room for input, rematch and leave outside a room', () async {
      final c = await TestClient.connect(server, name: 'Lonely');
      c.send(const InputMsg(tick: 0, input: 16));
      expect((await c.nextOf<ErrorMsg>()).code, 'not_in_room');
      c.send(const RematchMsg());
      expect((await c.nextOf<ErrorMsg>()).code, 'not_in_room');
      c.send(const LeaveMsg());
      expect((await c.nextOf<ErrorMsg>()).code, 'not_in_room');
      expect(c.isClosed, isFalse);
    });

    test('ping works before joining a room and reports tick -1', () async {
      final c = await TestClient.connect(server, name: 'Pinger');
      c.send(const PingMsg(clientMs: 7));
      final pong = await c.nextOf<PongMsg>();
      expect(pong.clientMs, 7);
      expect(pong.tick, -1);
    });
  });

  group('bad frames', () {
    test(
      'junk frames are reported and close the socket after 5 strikes',
      () async {
        final c = await TestClient.connect(server, name: 'Junker');
        for (var i = 0; i < maxBadMessages; i++) {
          c.sendRaw('this is not json');
          expect((await c.nextOf<ErrorMsg>()).code, 'bad_message');
        }
        await c.closed.timeout(const Duration(seconds: 5));
        expect(c.closeCode, closeCodePolicyViolation);
      },
    );

    test('valid JSON with an unknown type is a bad_message', () async {
      final c = await TestClient.connect(server, name: 'Weird');
      c.sendRaw('{"t":"nope"}');
      expect((await c.nextOf<ErrorMsg>()).code, 'bad_message');
      c.sendRaw('{"t":"input","tick":"five","i":1}');
      expect((await c.nextOf<ErrorMsg>()).code, 'bad_message');
      c.sendRaw('[1,2,3]');
      expect((await c.nextOf<ErrorMsg>()).code, 'bad_message');
    });

    test('frames beyond the 4 KB limit are rejected', () async {
      final c = await TestClient.connect(server);
      final huge =
          '{"t":"hello","v":1,"name":"${'A' * (maxClientFrameLength + 1)}"}';
      expect(huge.length, greaterThan(maxClientFrameLength));
      c.sendRaw(huge);
      expect((await c.nextOf<ErrorMsg>()).code, 'bad_message');
    });

    test('binary frames are rejected', () async {
      final c = await TestClient.connect(server, name: 'Binary');
      c.sendRaw(<int>[1, 2, 3, 4]);
      expect((await c.nextOf<ErrorMsg>()).code, 'bad_message');
    });
  });

  group('caps', () {
    test(
      'a fifth room created from the same IP within a minute is rate limited',
      () async {
        final c = await TestClient.connect(server, name: 'Spammer');
        for (var i = 0; i < roomsPerIpPerMinute; i++) {
          c.send(const CreateRoomMsg());
          final room = await c.nextOf<RoomMsg>();
          expect(room.slot, 0);
        }
        c.send(const CreateRoomMsg());
        expect((await c.nextOf<ErrorMsg>()).code, 'rate_limited');
        // The refused create left the previous room intact.
        expect(server.rooms.roomCount, 1);
      },
    );

    test('the room cap refuses further creates', () async {
      final small = await bootServer(maxRooms: 1);
      final a = await TestClient.connect(small, name: 'First');
      a.send(const CreateRoomMsg());
      await a.nextOf<RoomMsg>();
      final b = await TestClient.connect(small, name: 'Second');
      b.send(const CreateRoomMsg());
      expect((await b.nextOf<ErrorMsg>()).code, 'rate_limited');
      expect(small.rooms.roomCount, 1);
      expect(maxLiveRooms, 500, reason: 'SPEC §3');
    });

    test('the message bucket bursts then refills at its rate', () {
      var now = 0;
      final bucket = TokenBucket(
        ratePerSecond: maxMessagesPerSecond,
        burst: maxMessageBurst,
        clock: () => now,
      );
      for (var i = 0; i < maxMessageBurst; i++) {
        expect(bucket.take(), isTrue, reason: 'token ${i + 1}');
      }
      expect(bucket.take(), isFalse, reason: 'the burst is spent');

      now += 100;
      expect(bucket.available, maxMessagesPerSecond ~/ 10);
      for (var i = 0; i < maxMessagesPerSecond ~/ 10; i++) {
        expect(bucket.take(), isTrue);
      }
      expect(bucket.take(), isFalse);

      now += 10000;
      expect(bucket.available, maxMessageBurst, reason: 'capped at the burst');
      expect(
        maxMessagesPerSecond,
        greaterThanOrEqualTo(2 * tickRate),
        reason: 'SPEC §3: one input per tick (60 Hz) plus pings must fit',
      );
    });

    test('the create limiter allows exactly 4 rooms per minute per key', () {
      var now = 0;
      final limiter = RateLimiter(
        limit: roomsPerIpPerMinute,
        window: const Duration(minutes: 1),
        clock: () => now,
      );
      for (var i = 0; i < roomsPerIpPerMinute; i++) {
        expect(limiter.allow('1.2.3.4'), isTrue);
      }
      expect(limiter.allow('1.2.3.4'), isFalse);
      expect(
        limiter.allow('5.6.7.8'),
        isTrue,
        reason: 'other keys are independent',
      );
      now += const Duration(minutes: 1).inMilliseconds + 1;
      expect(limiter.allow('1.2.3.4'), isTrue, reason: 'the window slid');
      limiter.sweep();
      expect(limiter.count('5.6.7.8'), 0);
    });
  });

  group('flood control', () {
    test('a socket that outruns the message budget is closed', () async {
      final c = await TestClient.connect(server, name: 'Flooder');
      // `ping` is answered from the lobby and is not a protocol violation, so
      // before the fix this loop cost the socket nothing at all.
      const flood = 400;
      expect(flood, greaterThan(maxMessageBurst));
      for (var i = 0; i < flood; i++) {
        c.send(PingMsg(clientMs: i));
      }
      // nextOf skips the pongs the burst earned.
      expect((await c.nextOf<ErrorMsg>()).code, 'rate_limited');
      await c.closed.timeout(const Duration(seconds: 5));
      expect(c.closeCode, closeCodePolicyViolation);
      expect(
        c.pending,
        lessThan(flood),
        reason: 'the flood must not be answered in full',
      );
    });

    test('guessing room codes closes the socket', () async {
      final c = await TestClient.connect(server, name: 'Guesser');
      for (var i = 0; i < maxMissedJoins; i++) {
        c.send(JoinRoomMsg(code: 'ZZZ${roomCodeAlphabet[i]}'));
        expect(
          (await c.nextOf<ErrorMsg>()).code,
          'room_not_found',
          reason: 'guess ${i + 1}',
        );
      }
      await c.closed.timeout(const Duration(seconds: 5));
      expect(c.closeCode, closeCodePolicyViolation);
    });

    test('a malformed code also counts towards the guess budget', () async {
      final c = await TestClient.connect(server, name: 'Sloppy');
      for (var i = 0; i < maxMissedJoins; i++) {
        c.send(const JoinRoomMsg(code: 'AB0O'));
        expect((await c.nextOf<ErrorMsg>()).code, 'bad_code');
      }
      await c.closed.timeout(const Duration(seconds: 5));
      expect(c.closeCode, closeCodePolicyViolation);
    });

    test('retrying a code that does exist never costs a guess', () async {
      final a = await TestClient.connect(server, name: 'Host');
      a.send(const CreateRoomMsg());
      final room = await a.nextOf<RoomMsg>();
      final b = await TestClient.connect(server, name: 'Guest');
      b.send(JoinRoomMsg(code: room.code));
      await b.nextOf<RoomMsg>();

      // A third client hammering a real code gets room_full every time and
      // stays connected: only codes that are not in use are metered.
      final c = await TestClient.connect(server, name: 'Late');
      for (var i = 0; i < maxMissedJoins * 2; i++) {
        c.send(JoinRoomMsg(code: room.code));
        expect((await c.nextOf<ErrorMsg>()).code, 'room_full');
      }
      expect(c.isClosed, isFalse);
    });
  });
}
