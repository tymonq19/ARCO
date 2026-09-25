/// End-to-end duel test (SPEC §6): boots a real server on a random port,
/// connects two WebSocket clients and plays a whole duel over the wire.
library;

import 'dart:async';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Result of the create/join handshake used by every test below.
class _Duel {
  _Duel(this.a, this.b, this.code, this.start);
  final TestClient a;
  final TestClient b;
  final String code;
  final StartMsg start;
}

Future<_Duel> _openDuel(ArcoServer server) async {
  final a = await TestClient.connect(server, name: 'Alice');
  final b = await TestClient.connect(server, name: 'Bob');

  a.send(const CreateRoomMsg());
  final created = await a.nextOf<RoomMsg>();
  expect(created.slot, 0);
  expect(created.code.length, roomCodeLength);
  expect(created.names, ['Alice', null]);

  b.send(JoinRoomMsg(code: created.code));
  final joined = await b.nextOf<RoomMsg>();
  expect(joined.code, created.code);
  expect(joined.slot, 1);
  expect(joined.names, ['Alice', 'Bob']);

  // The creator is told that the peer arrived.
  final updated = await a.nextOf<RoomMsg>();
  expect(updated.names, ['Alice', 'Bob']);

  final startA = await a.nextOf<StartMsg>();
  final startB = await b.nextOf<StartMsg>();
  expect(startA.seed, startB.seed);
  expect(startA.countdown, countdownTicks);
  expect(startA.names, ['Alice', 'Bob']);
  expect(startB.names, ['Alice', 'Bob']);
  return _Duel(a, b, created.code, startA);
}

void main() {
  group('duel end to end', () {
    late ArcoServer server;

    // 30x speed: a full duel (a few thousand sim ticks) plays in ~2 s.
    setUp(() async {
      server = await bootServer(tickMultiplier: 30);
    });

    test('handshake, snapshots and applied inputs', () async {
      final duel = await _openDuel(server);
      expect(server.rooms.roomCount, 1);
      expect(server.rooms.roomByCode(duel.code)!.isFull, isTrue);

      // Player 0 drives its paddle counter-clockwise, player 1 clockwise.
      duel.a.send(
        InputMsg(tick: 0, input: const PlayerInput(move: 16).encode()),
      );
      duel.b.send(
        InputMsg(tick: 0, input: const PlayerInput(move: -16).encode()),
      );

      final ticks = <int>[];
      GameState? last;
      for (var i = 0; i < 8; i++) {
        final snap = await duel.a.nextOf<SnapMsg>(
          timeout: const Duration(seconds: 30),
        );
        final state = GameState.fromJson(snap.state);
        expect(
          state.tick,
          snap.tick,
          reason: 'snapshot tick must match its state',
        );
        expect(state.config.mode, GameMode.duel);
        expect(state.config.seed, duel.start.seed);
        expect(state.players, hasLength(2));
        expect(
          snap.tick % snapshotInterval,
          0,
          reason: 'snapshots are sent every $snapshotInterval ticks',
        );
        ticks.add(snap.tick);
        last = state;
      }
      for (var i = 1; i < ticks.length; i++) {
        expect(ticks[i], greaterThan(ticks[i - 1]));
      }

      // The inputs were applied server side: both paddles left their start angle.
      expect(
        last!.players[0].paddle.angle,
        isNot(closeTo(bottomCenterAngle, 1e-9)),
      );
      expect(
        last.players[1].paddle.angle,
        isNot(closeTo(topCenterAngle, 1e-9)),
      );
      // Player 0 owns the bottom half, player 1 the top half (SPEC §2.3).
      expect(
        last.players[0].paddle.angle,
        inInclusiveRange(DetMath.pi, DetMath.tau),
      );
      expect(last.players[1].paddle.angle, inInclusiveRange(0, DetMath.pi));

      // The second client sees the same game.
      final snapB = await duel.b.nextOf<SnapMsg>(
        timeout: const Duration(seconds: 30),
      );
      expect(GameState.fromJson(snapB.state).config.seed, duel.start.seed);
    });

    test('ping is answered with the room tick', () async {
      final duel = await _openDuel(server);
      duel.a.send(const PingMsg(clientMs: 4242));
      final pong = await duel.a.next(timeout: const Duration(seconds: 30));
      // A snapshot may arrive first; drain until the pong shows up.
      var msg = pong;
      while (msg is! PongMsg) {
        msg = await duel.a.next(timeout: const Duration(seconds: 30));
      }
      expect(msg.clientMs, 4242);
      expect(msg.tick, greaterThanOrEqualTo(-1));
    });

    test(
      'without inputs the ball escapes until both players get over, then rematch restarts',
      () async {
        final duel = await _openDuel(server);

        final overA = await duel.a.nextOf<OverMsg>(
          timeout: const Duration(minutes: 2),
        );
        final overB = await duel.b.nextOf<OverMsg>(
          timeout: const Duration(minutes: 2),
        );
        expect(overA.winner, anyOf(0, 1));
        expect(overB.winner, overA.winner);
        expect(overA.scores, hasLength(2));
        expect(overB.scores, overA.scores);

        final room = server.rooms.roomByCode(duel.code)!;
        expect(room.state, RoomState.over);
        final loser = 1 - overA.winner;
        expect(room.game!.players[loser].lives, 0);

        // Both players vote for a rematch: a new game with a new seed starts.
        duel.a.send(const RematchMsg());
        duel.b.send(const RematchMsg());
        final restartA = await duel.a.nextOf<StartMsg>(
          timeout: const Duration(seconds: 30),
        );
        final restartB = await duel.b.nextOf<StartMsg>(
          timeout: const Duration(seconds: 30),
        );
        expect(restartA.seed, restartB.seed);
        expect(restartA.seed, isNot(duel.start.seed));
        expect(restartA.countdown, countdownTicks);
        expect(server.rooms.roomByCode(duel.code)!.state, RoomState.countdown);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'one player rematching alone does not restart the game',
      () async {
        final duel = await _openDuel(server);
        await duel.a.nextOf<OverMsg>(timeout: const Duration(minutes: 2));
        await duel.b.nextOf<OverMsg>(timeout: const Duration(minutes: 2));

        duel.a.send(const RematchMsg());
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final room = server.rooms.roomByCode(duel.code)!;
        expect(room.state, RoomState.over);
        expect(room.rematchVotes, [true, false]);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'a disconnect sends peer_left to the other player and destroys the room',
      () async {
        final duel = await _openDuel(server);
        await duel.a.close();
        await duel.b.nextOf<PeerLeftMsg>(timeout: const Duration(seconds: 30));
        await pumpUntil(
          () => server.rooms.roomCount == 0,
          reason: 'room must be destroyed',
        );
        expect(server.rooms.roomByCode(duel.code), isNull);

        // The survivor is back in the lobby and can open a fresh room.
        duel.b.send(const CreateRoomMsg());
        final fresh = await duel.b.nextOf<RoomMsg>();
        expect(fresh.slot, 0);
        expect(fresh.code, isNot(duel.code));
      },
    );

    test('an explicit leave also tears the room down', () async {
      final duel = await _openDuel(server);
      duel.a.send(const LeaveMsg());
      await duel.b.nextOf<PeerLeftMsg>(timeout: const Duration(seconds: 30));
      await pumpUntil(() => server.rooms.roomCount == 0);
    });
  });

  group('room lifecycle details', () {
    test('a waiting room is destroyed after the idle timeout', () async {
      final server = await bootServer(
        roomIdleTimeout: const Duration(milliseconds: 1),
        roomSweepInterval: const Duration(milliseconds: 20),
      );
      final a = await TestClient.connect(server, name: 'Alone');
      a.send(const CreateRoomMsg());
      await a.nextOf<RoomMsg>();
      expect(server.rooms.roomCount, 1);
      await pumpUntil(
        () => server.rooms.roomCount == 0,
        reason: 'idle room must be swept',
      );
      await a.closed.timeout(const Duration(seconds: 5));
      expect(a.closeCode, closeCodeIdleTimeout);
    });

    test('input does not refresh the idle clock outside a running game', () {
      final created = DateTime.utc(2026);
      final room = Room('ABCD', now: created);
      final later = created.add(const Duration(minutes: 5));
      final input = InputMsg(
        tick: 1,
        input: const PlayerInput(move: 7).encode(),
      );

      // Waiting for a friend: a stream of inputs must not keep the room alive,
      // otherwise the 10 min idle sweep (SPEC §3) never fires.
      room.applyInput(0, input, later);
      expect(room.inputs[0], const PlayerInput(move: 7));
      expect(
        room.lastActivity,
        created,
        reason: 'a waiting room stays idle however much input arrives',
      );

      // While a game runs, input is genuine activity.
      room.begin(99, created);
      for (var i = 0; i < countdownTicks; i++) {
        room.tick();
      }
      expect(room.state, RoomState.playing);
      room.applyInput(0, InputMsg(tick: 2, input: input.input), later);
      expect(room.lastActivity, later);

      // Finished and waiting for a rematch vote: idle again.
      room.state = RoomState.over;
      final evenLater = later.add(const Duration(minutes: 5));
      room.applyInput(0, InputMsg(tick: 3, input: input.input), evenLater);
      expect(
        room.lastActivity,
        later,
        reason: 'an over room stays idle however much input arrives',
      );
    });

    test('an input keep-alive cannot pin a waiting room forever', () async {
      final server = await bootServer(
        roomIdleTimeout: const Duration(milliseconds: 50),
        roomSweepInterval: const Duration(milliseconds: 20),
      );
      final a = await TestClient.connect(server, name: 'Pinner');
      a.send(const CreateRoomMsg());
      await a.nextOf<RoomMsg>();
      expect(server.rooms.roomCount, 1);

      // One input frame every 5 ms, far more often than the idle timeout.
      var tick = 0;
      final spam = Timer.periodic(const Duration(milliseconds: 5), (timer) {
        if (a.isClosed) {
          timer.cancel();
          return;
        }
        try {
          a.send(InputMsg(tick: tick++, input: PlayerInput.none.encode()));
        } catch (_) {
          timer.cancel();
        }
      });
      addTearDown(spam.cancel);

      await pumpUntil(
        () => server.rooms.roomCount == 0,
        reason: 'a keep-alive must not hold the room slot',
      );
      spam.cancel();
      await a.closed.timeout(const Duration(seconds: 5));
      expect(a.closeCode, closeCodeIdleTimeout);
    });

    test('Room ignores inputs older than the last accepted tick', () {
      final room = Room('ABCD', now: DateTime.utc(2026));
      final moving = const PlayerInput(move: 7);
      room.applyInput(
        0,
        InputMsg(tick: 10, input: moving.encode()),
        DateTime.utc(2026),
      );
      expect(room.inputs[0], moving);
      room.applyInput(
        0,
        InputMsg(tick: 4, input: PlayerInput.none.encode()),
        DateTime.utc(2026),
      );
      expect(room.inputs[0], moving, reason: 'stale tick must be ignored');
      room.applyInput(
        0,
        InputMsg(tick: 11, input: PlayerInput.none.encode()),
        DateTime.utc(2026),
      );
      expect(room.inputs[0], PlayerInput.none);
    });

    test('Room ignores an input tick far ahead of the running game', () {
      final now = DateTime.utc(2026);
      final room = Room('ABCD', now: now);
      room.begin(99, now);
      for (var i = 0; i < countdownTicks; i++) {
        room.tick();
      }
      expect(room.state, RoomState.playing);

      final moving = const PlayerInput(move: 7);
      room.applyInput(
        0,
        InputMsg(tick: room.currentTick, input: moving.encode()),
        now,
      );
      expect(room.inputs[0], moving);

      // A bogus far-future tick (client bug, duplicated frame, hostile peer)
      // must not become the ordering watermark, or every later input from
      // this slot is dropped and the paddle freezes for the rest of the game.
      final poison = InputMsg(
        tick: 9007199254740992,
        input: PlayerInput.none.encode(),
      );
      room.applyInput(0, poison, now);
      expect(
        room.lastInputTick[0],
        lessThanOrEqualTo(room.currentTick + maxInputTickLead),
        reason: 'the accepted tick must stay near the live sim tick',
      );

      // The next honest input still wins.
      final other = const PlayerInput(move: -7);
      room.applyInput(
        0,
        InputMsg(tick: room.currentTick + 1, input: other.encode()),
        now,
      );
      expect(
        room.inputs[0],
        other,
        reason: 'a poisoned tick must not disable the slot',
      );
    });

    test(
      'a room only counts as running while it is counting down or playing',
      () {
        final room = Room('ABCD', now: DateTime.utc(2026));
        expect(room.state, RoomState.waiting);
        expect(room.isRunning, isFalse);
        room.begin(99, DateTime.utc(2026));
        expect(room.state, RoomState.countdown);
        expect(room.isRunning, isTrue);
        for (var i = 0; i < countdownTicks; i++) {
          room.tick();
        }
        expect(room.state, RoomState.playing);
        expect(
          room.game!.tick,
          1,
          reason: 'the first sim step runs on the tick the countdown ends',
        );
        expect(room.currentTick, 1);
      },
    );
  });
}
