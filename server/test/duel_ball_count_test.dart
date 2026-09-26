/// The duel ball count (SPEC §3): the creator of a room chooses how many balls
/// the room plays with, the joining player is told before the countdown, and the
/// server simulates that and nothing else.
///
/// The product rule under test: a duel is two people playing **one** simulation.
/// If the two ends disagree about the ball count they are not playing the same
/// game at all, so the count travels on the three frames that describe a room —
/// `create`, `room` and `start` — and the config the server steps is the only
/// authority.
library;

import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The create/join handshake, with the creator asking for [balls] balls (or
/// asking for nothing at all when it is null).
Future<({TestClient a, TestClient b, String code, StartMsg start})> openDuel(
  ArcoServer server, {
  int? balls,
}) async {
  final a = await TestClient.connect(server, name: 'Alice');
  final b = await TestClient.connect(server, name: 'Bob');

  a.createRoom(balls: balls);
  final created = await a.nextOf<RoomMsg>();
  b.send(JoinRoomMsg(code: created.code));
  final joined = await b.nextOf<RoomMsg>();
  expect(joined.code, created.code);
  await a.nextOf<RoomMsg>();
  final startA = await a.nextOf<StartMsg>();
  final startB = await b.nextOf<StartMsg>();
  expect(startA.seed, startB.seed);
  return (a: a, b: b, code: created.code, start: startA);
}

void main() {
  late ArcoServer server;

  // 30x speed: a duel plays out in a couple of seconds.
  setUp(() async {
    server = await bootServer(tickMultiplier: 30);
  });

  /// The first snapshot each client receives, decoded.
  Future<GameState> firstSnapshot(TestClient client) async {
    final snap = await client.nextOf<SnapMsg>(
      timeout: const Duration(seconds: 30),
    );
    return GameState.fromJson(snap.state);
  }

  group('the creator chooses and both players are told', () {
    test('a create that says nothing is the classic one-ball game', () async {
      final duel = await openDuel(server);
      expect(server.rooms.roomByCode(duel.code)!.ballCount, 1);
      // Told anyway, so a client can tell this server knows about ball counts.
      expect(duel.a.jsonOf('room')[ballCountField], 1);
      expect(duel.b.jsonOf('room')[ballCountField], 1);
      expect(duel.a.jsonOf('start')[ballCountField], 1);

      final state = await firstSnapshot(duel.a);
      expect(state.config.ballCount, 1);
      expect(state.balls, hasLength(1));
    });

    test('a create asking for two balls gets a two-ball room', () async {
      final duel = await openDuel(server, balls: 2);
      expect(server.rooms.roomByCode(duel.code)!.ballCount, 2);
      expect(duel.a.jsonOf('room')[ballCountField], 2);
      expect(duel.b.jsonOf('room')[ballCountField], 2);
      expect(duel.a.jsonOf('start')[ballCountField], 2);
      expect(duel.b.jsonOf('start')[ballCountField], 2);

      final state = await firstSnapshot(duel.a);
      expect(state.config.mode, GameMode.duel);
      expect(state.config.ballCount, 2);
      expect(state.balls, hasLength(2));

      // Both balls leave the origin on the same tick and are recalled together
      // (SPEC §2.3), so a snapshot never catches one in play and one parked.
      var sawFlight = false;
      for (var i = 0; i < 40 && !sawFlight; i++) {
        final live = await firstSnapshot(duel.a);
        expect(live.balls, hasLength(2));
        final active = live.balls.where((b) => b.active).length;
        expect(
          active,
          anyOf(0, 2),
          reason: 'balls are served and recalled as a set, never one at a time',
        );
        sawFlight = active == 2;
      }
      expect(sawFlight, isTrue, reason: 'the serve has to happen');
    });

    test('the joining player learns it before the countdown starts', () async {
      final a = await TestClient.connect(server, name: 'Alice');
      final b = await TestClient.connect(server, name: 'Bob');
      a.createRoom(balls: 2);
      final created = await a.nextOf<RoomMsg>();

      b.send(JoinRoomMsg(code: created.code));
      final joined = await b.nextOf<RoomMsg>();
      expect(joined.slot, 1);
      expect(
        b.jsonOf('room')[ballCountField],
        2,
        reason: 'the joiner is told what they joined, not what they got',
      );

      await b.nextOf<StartMsg>();
      final types = [for (final f in b.jsonFrames) f['t']];
      expect(
        types.indexOf('room'),
        lessThan(types.indexOf('start')),
        reason: 'the room message carrying the count arrives first',
      );
    });

    test('both clients see the same two-ball game', () async {
      final duel = await openDuel(server, balls: 2);
      final fromA = await firstSnapshot(duel.a);
      final fromB = await firstSnapshot(duel.b);
      expect(fromA.config.ballCount, 2);
      expect(fromB.config.ballCount, 2);
      expect(fromA.config.seed, duel.start.seed);
      expect(fromB.config.seed, duel.start.seed);
      expect(fromB.hash(), fromA.hash());
    });

    test('a rematch keeps the room\'s ball count', () async {
      final duel = await openDuel(server, balls: 2);
      // Nobody moves, so the balls escape until both players are out of lives.
      await duel.a.nextOf<OverMsg>(timeout: const Duration(seconds: 60));
      await duel.b.nextOf<OverMsg>(timeout: const Duration(seconds: 60));

      duel.a.send(const RematchMsg());
      duel.b.send(const RematchMsg());
      final again = await duel.a.nextOf<StartMsg>(
        timeout: const Duration(seconds: 30),
      );
      expect(
        again.seed,
        isNot(duel.start.seed),
        reason: 'a new game, new seed',
      );
      expect(
        duel.a.jsonOf('start')[ballCountField],
        2,
        reason:
            'the count is what the joiner agreed to; a new one is a new room',
      );
      expect(server.rooms.roomByCode(duel.code)!.ballCount, 2);
      expect((await firstSnapshot(duel.a)).balls, hasLength(2));
    });

    test('a second create makes a new room with the new count', () async {
      final a = await TestClient.connect(server, name: 'Alice');
      a.createRoom(balls: 2);
      final first = await a.nextOf<RoomMsg>();
      expect(server.rooms.roomByCode(first.code)!.ballCount, 2);

      a.createRoom();
      final second = await a.nextOf<RoomMsg>();
      expect(second.code, isNot(first.code));
      expect(server.rooms.roomByCode(second.code)!.ballCount, 1);
      expect(
        server.rooms.roomByCode(first.code),
        isNull,
        reason: 'the abandoned room is gone, not left holding a stale count',
      );
    });
  });

  group('a ball count this build cannot run', () {
    test('is refused and no room is created', () async {
      // A fresh socket per value: each refusal spends a slice of the same
      // bad-message budget, and that budget has its own test below.
      for (final bad in <Object>[0, 3, 99, -1, '2', 2.0, true]) {
        final a = await TestClient.connect(server, name: 'Alice');
        a.sendRaw(jsonEncode({'t': 'create', ballCountField: bad}));
        final error = await a.nextOf<ErrorMsg>();
        expect(
          error.code,
          anyOf(badBallCountError, 'bad_message'),
          reason: 'create with n=$bad',
        );
        expect(
          server.rooms.roomCount,
          0,
          reason: 'n=$bad must not open a room the creator did not ask for',
        );
        await a.dispose();
      }
    });

    test('an out-of-range integer says exactly what is wrong', () async {
      final a = await TestClient.connect(server, name: 'Alice');
      a.sendRaw(jsonEncode({'t': 'create', ballCountField: maxBallCount + 1}));
      final error = await a.nextOf<ErrorMsg>();
      expect(error.code, badBallCountError);
      expect(a.isClosed, isFalse, reason: 'one bad frame is not a disconnect');
    });

    test('spends the bad-message budget like any other violation', () async {
      final a = await TestClient.connect(server, name: 'Alice');
      for (var i = 0; i < maxBadMessages; i++) {
        a.sendRaw(jsonEncode({'t': 'create', ballCountField: 5}));
        expect((await a.nextOf<ErrorMsg>()).code, badBallCountError);
      }
      await a.closed;
      expect(a.closeCode, closeCodePolicyViolation);
      expect(server.rooms.roomCount, 0);
    });
  });

  group('the field is additive', () {
    test('a frame carrying it still parses as the core message', () async {
      final duel = await openDuel(server, balls: 2);
      // `RoomMsg` / `StartMsg` came back from `ServerMsg.parse` with every
      // documented field intact, which is what lets an older client keep
      // working against this server.
      final room = duel.b.jsonOf('room');
      expect(ServerMsg.parse(room), isA<RoomMsg>());
      expect(room['code'], duel.code);
      expect(room['slot'], 1);
      expect(room['names'], ['Alice', 'Bob']);
      final start = duel.b.jsonOf('start');
      expect(ServerMsg.parse(start), isA<StartMsg>());
      expect(start['seed'], duel.start.seed);
      expect(start['countdown'], countdownTicks);
      expect(start['names'], ['Alice', 'Bob']);
    });

    test('a client that ignores it still converges on the snapshot', () async {
      // The config is inside every snapshot, so `n` on `start` only saves the
      // countdown from being drawn with the wrong ball count.
      final duel = await openDuel(server, balls: 2);
      final snap = await duel.a.nextOf<SnapMsg>(
        timeout: const Duration(seconds: 30),
      );
      final cfg = snap.state['cfg'] as Map<String, dynamic>;
      expect(cfg['n'], 2);
      expect(GameConfig.fromJson(cfg).ballCount, 2);
    });
  });
}
