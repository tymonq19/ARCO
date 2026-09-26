import 'dart:async';

import 'package:arco/game/controllers/duel_controller.dart';
import 'package:arco/game/input/input_controller.dart';
import 'package:arco/game/input/tilt_input.dart';
import 'package:arco/services/audio_service.dart';
import 'package:arco/services/duel_client.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../helpers/test_env.dart';

const double frame = 1 / 60;
const int seed = 424242;

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Muted [AudioService] that records what the controller asked to play
/// instead of touching the audio plugin.
class SpyAudio extends AudioService {
  SpyAudio() : super(muted: true);

  final List<Sfx> played = <Sfx>[];

  @override
  void play(Sfx sfx, {double volume = 1.0}) => played.add(sfx);

  int count(Sfx sfx) => played.where((s) => s == sfx).length;
}

Future<DuelController> connectedController(
  TestEnv env,
  FakeDuelServer server, {
  PlayerInput Function()? input,
  AudioService? audio,
  int ballCount = minBallCount,
}) async {
  final client = DuelClient(
    wsUri: () => Uri.parse('ws://fake.local/ws'),
    connector: server.connect,
  );
  final controller = DuelController(
    client: client,
    settings: env.settings,
    audio: audio ?? env.audio,
    haptics: env.haptics,
    input: FakeInput(input),
  );
  await controller.createRoom('Tester', ballCount: ballCount);
  await settle();
  return controller;
}

void main() {
  // SPEC 2.3 / 3: the creator picks the game, the server tells both clients, and
  // the prediction has to run the same simulation the server is running — a
  // prediction with the wrong number of balls disagrees on every tick between
  // snapshots.
  group('two balls', () {
    test('the creator\'s choice travels with the room and reaches both '
        'sides', () async {
      final env = await createTestEnv();
      final server = FakeDuelServer();
      final controller = await connectedController(env, server, ballCount: 2);

      // The choice went up on the `create` frame.
      final create = server.frames.firstWhere((f) => f['t'] == 'create');
      expect(create['n'], 2);
      // And came back on `room`, which is what the joiner reads before the
      // first serve.
      expect(server.ballCount, 2);
      expect(controller.ballCount, 2);

      server.start(countdown: 0);
      await settle();
      expect(controller.state!.config.ballCount, 2);
      expect(controller.state!.balls, hasLength(2));
      controller.dispose();
    });

    test('the joiner is told what the room already is', () async {
      final env = await createTestEnv();
      // The room exists and the creator chose two balls; this client joins it.
      final server = FakeDuelServer(slot: 1)..ballCount = 2;
      final client = DuelClient(
        wsUri: () => Uri.parse('ws://fake.local/ws'),
        connector: server.connect,
      );
      final controller = DuelController(
        client: client,
        settings: env.settings,
        audio: env.audio,
        haptics: env.haptics,
        input: FakeInput(),
      );
      await controller.joinRoom('Tester', 'KX7Q');
      await settle();
      // Before the match starts, and without having chosen anything.
      expect(controller.hasMatch, isFalse);
      expect(controller.ballCount, 2);
      expect(env.settings.ballCount, minBallCount);

      server.start(countdown: 180);
      await settle();
      expect(controller.inCountdown, isTrue);
      expect(controller.state!.balls, hasLength(2));
      controller.dispose();
    });

    test('a server that says nothing about ball counts plays one', () async {
      final env = await createTestEnv();
      final server = FakeDuelServer();
      final controller = await connectedController(env, server, ballCount: 2);
      server.startWithoutBalls(countdown: 0);
      await settle();
      expect(controller.state!.balls, hasLength(1));
      controller.dispose();
    });

    test('prediction keeps the own paddle and reconciles both balls', () async {
      final env = await createTestEnv();
      final server = FakeDuelServer();
      final controller = await connectedController(
        env,
        server,
        input: () => const PlayerInput(move: inputMoveMax),
        ballCount: 2,
      );
      server.start(countdown: 0);
      await settle();
      for (var i = 0; i < 40; i++) {
        controller.advance(frame);
      }
      final predicted = controller.state!.players[0].paddle.angle;
      expect(predicted, greaterThan(DetMath.threeHalfPi));
      expect(controller.state!.balls, hasLength(2));

      // An authoritative two-ball snapshot, both balls somewhere else entirely
      // and the own paddle within tolerance of the prediction.
      final authoritative = GameState.initial(
        const GameConfig(mode: GameMode.duel, seed: seed, ballCount: 2),
      );
      authoritative.phase = Phase.playing;
      authoritative.serveTimer = 0;
      authoritative.players[0].paddle.angle = predicted + 0.1;
      authoritative.players[1].paddle.angle = DetMath.halfPi - 0.3;
      authoritative.balls[0]
        ..active = true
        ..x = 0.4
        ..y = 0.1
        ..vx = 0.5
        ..vy = 0.2;
      authoritative.balls[1]
        ..active = true
        ..x = -0.45
        ..y = -0.2
        ..vx = -0.3
        ..vy = 0.4;
      server.snap(authoritative);
      await settle();

      // The own paddle is still the predicted one — that is what keeps it
      // responsive — and everything else is the server's.
      expect(
        controller.state!.players[0].paddle.angle,
        closeTo(predicted, 1e-9),
      );
      expect(
        controller.state!.players[1].paddle.angle,
        closeTo(DetMath.halfPi - 0.3, 1e-9),
      );
      expect(controller.state!.balls, hasLength(2));
      expect(controller.state!.balls[0].x, closeTo(0.4, 1e-9));
      expect(controller.state!.balls[1].x, closeTo(-0.45, 1e-9));

      // Both balls are then followed, each with a trail of its own.
      for (var i = 0; i < 20; i++) {
        controller.advance(frame);
      }
      final fx = controller.fx;
      expect(fx.ballCount, 2);
      expect(fx.ball(0).live, isTrue);
      expect(fx.ball(1).live, isTrue);
      expect(fx.ball(0).trailCount, greaterThan(1));
      expect(fx.ball(1).trailCount, greaterThan(1));
      // Two paths, not one zig-zag shared between them.
      expect(
        fx.ball(0).trailX(fx.ball(0).trailCount - 1),
        isNot(closeTo(fx.ball(1).trailX(fx.ball(1).trailCount - 1), 0.05)),
      );
      controller.dispose();
    });

    test('an undecodable snapshot is dropped, not half-applied', () async {
      final env = await createTestEnv();
      final server = FakeDuelServer();
      final controller = await connectedController(env, server, ballCount: 2);
      server.start(countdown: 0);
      await settle();
      for (var i = 0; i < 10; i++) {
        controller.advance(frame);
      }
      final tick = controller.state!.tick;

      // A snapshot whose ball list disagrees with its own config: the core
      // refuses it (SPEC 2.5) and the prediction carries on.
      final bad = GameState.initial(
        const GameConfig(mode: GameMode.duel, seed: seed, ballCount: 2),
      ).toJson();
      (bad['b'] as List<dynamic>).removeLast();
      server.emit(SnapMsg(tick: 999, state: bad, events: const []));
      await settle();

      expect(controller.state!.balls, hasLength(2));
      expect(controller.state!.tick, tick);
      controller.advance(frame);
      expect(controller.state!.tick, tick + 1);
      controller.dispose();
    });
  });

  test('starts a match from StartMsg and counts down', () async {
    final env = await createTestEnv();
    final server = FakeDuelServer();
    final controller = await connectedController(env, server);
    expect(controller.roomCode, 'KX7Q');
    expect(controller.slot, 0);
    expect(controller.hasMatch, isFalse);

    server.start(countdown: 120);
    await settle();
    expect(controller.hasMatch, isTrue);
    expect(controller.inCountdown, isTrue);
    expect(controller.countdownSeconds, 2);

    // The simulation must not advance while the countdown runs.
    for (var i = 0; i < 60; i++) {
      controller.advance(frame);
    }
    expect(controller.state!.tick, 0);
    expect(controller.countdownSeconds, 1);
    for (var i = 0; i < 60; i++) {
      controller.advance(frame);
    }
    expect(controller.inCountdown, isFalse);
    controller.advance(frame);
    expect(controller.state!.tick, 1);

    controller.dispose();
  });

  test(
    'keeps the predicted own paddle unless the server disagrees a lot',
    () async {
      final env = await createTestEnv();
      final server = FakeDuelServer();
      final controller = await connectedController(
        env,
        server,
        input: () => const PlayerInput(move: inputMoveMax),
      );
      server.start(countdown: 0);
      await settle();
      for (var i = 0; i < 10; i++) {
        controller.advance(frame);
      }
      final predicted = controller.state!.players[0].paddle.angle;
      expect(predicted, greaterThan(DetMath.threeHalfPi));

      // Within tolerance: the prediction wins, no visible snap.
      final close = GameState.initial(
        GameConfig(mode: GameMode.duel, seed: seed),
      );
      close.players[0].paddle.angle = predicted + 0.1;
      close.players[1].paddle.angle = DetMath.halfPi - 0.2;
      server.snap(close);
      await settle();
      expect(
        controller.state!.players[0].paddle.angle,
        closeTo(predicted, 1e-9),
      );
      expect(
        controller.state!.players[1].paddle.angle,
        closeTo(DetMath.halfPi - 0.2, 1e-9),
        reason: 'the opponent paddle always comes from the server',
      );

      // Beyond tolerance: snap to the authoritative angle.
      final far = GameState.initial(
        GameConfig(mode: GameMode.duel, seed: seed),
      );
      far.players[0].paddle.angle = predicted + 0.5;
      server.snap(far);
      await settle();
      expect(
        controller.state!.players[0].paddle.angle,
        closeTo(predicted + 0.5, 1e-9),
      );

      controller.dispose();
    },
  );

  test('sends inputs on change and as a keep-alive', () async {
    final env = await createTestEnv();
    final server = FakeDuelServer();
    var move = 0;
    final controller = await connectedController(
      env,
      server,
      input: () => PlayerInput(move: move),
    );
    server.start(countdown: 0);
    await settle();
    for (var i = 0; i < 12; i++) {
      controller.advance(frame);
    }
    var inputs = server.received.whereType<InputMsg>().toList();
    expect(inputs, hasLength(2), reason: 'first send plus one keep-alive');
    move = -8;
    controller.advance(frame);
    inputs = server.received.whereType<InputMsg>().toList();
    expect(inputs, hasLength(3));
    expect(inputs.last.input, const PlayerInput(move: -8).encode());
    controller.dispose();
  });

  test('never sends an input tick older than one already sent', () async {
    final env = await createTestEnv();
    final server = FakeDuelServer();
    var move = 0;
    final controller = await connectedController(
      env,
      server,
      input: () => PlayerInput(move: move),
    );
    server.start(countdown: 0);
    await settle();

    // The client predicts ahead of the server: local tick reaches 8 and the
    // inputs sent so far carry the ticks 0..7.
    for (var i = 0; i < 8; i++) {
      move = i;
      controller.advance(frame);
    }
    expect(controller.state!.tick, 8);

    // Network jitter: the snapshot taken at server tick 5 only arrives now, so
    // replacing the local state rewinds the local tick (SPEC section 3).
    final snapshot = GameState.initial(
      GameConfig(mode: GameMode.duel, seed: seed),
    );
    snapshot.tick = 5;
    server.snap(snapshot);
    await settle();
    expect(controller.state!.tick, 5);

    // The player flicks to full right right after the snapshot.
    move = inputMoveMax;
    controller.advance(frame);

    final sent = server.received.whereType<InputMsg>().toList();
    final ticks = [for (final m in sent) m.tick];
    for (var i = 1; i < ticks.length; i++) {
      expect(
        ticks[i],
        greaterThanOrEqualTo(ticks[i - 1]),
        reason: 'ticks must not go backwards, got $ticks',
      );
    }

    // Replay the server rule (server/lib/src/room.dart applyInput): an input
    // older than the last accepted tick is dropped.
    var lastAccepted = -1;
    var applied = PlayerInput.none;
    for (final m in sent) {
      if (m.tick < lastAccepted) continue;
      lastAccepted = m.tick;
      applied = PlayerInput.decode(m.input);
    }
    expect(
      applied,
      const PlayerInput(move: inputMoveMax),
      reason:
          'the flick after the snapshot must reach the server, ticks $ticks',
    );

    controller.dispose();
  });

  test('reports the result and the peer leaving', () async {
    final env = await createTestEnv();
    final server = FakeDuelServer();
    final controller = await connectedController(env, server);
    server.start(countdown: 0);
    await settle();
    server.over(winner: 0, scores: const [120, 40]);
    await settle();
    expect(controller.over, isTrue);
    expect(controller.won, isTrue);
    expect(controller.scores, const [120, 40]);

    controller.rematch();
    expect(controller.rematchRequested, isTrue);
    expect(server.received.whereType<RematchMsg>(), hasLength(1));

    server.peerLeft();
    await settle();
    expect(controller.peerLeft, isTrue);
    controller.dispose();
  });

  test('keeps the joiner side, HUD and result when the peer leaves', () async {
    final env = await createTestEnv();
    final server = FakeDuelServer(slot: 1, peerName: 'Host');
    final controller = DuelController(
      client: DuelClient(
        wsUri: () => Uri.parse('ws://fake.local/ws'),
        connector: server.connect,
      ),
      settings: env.settings,
      audio: env.audio,
      haptics: env.haptics,
      input: FakeInput(),
    );
    await controller.joinRoom('Tester', 'KX7Q');
    await settle();
    expect(controller.slot, 1);
    expect(controller.rotated, isTrue);

    server.start(countdown: 0);
    await settle();
    for (var i = 0; i < 10; i++) {
      controller.advance(frame);
    }
    server.over(winner: 1, scores: const [40, 120]);
    await settle();
    expect(controller.won, isTrue);
    final myAngle = controller.me!.paddle.angle;

    // The loser leaves while the winner is still on the result screen: the
    // room is gone, but the rendered side of the match must not change.
    server.peerLeft();
    await settle();
    expect(controller.peerLeft, isTrue);
    expect(controller.slot, 1, reason: 'the own slot is fixed for the match');
    expect(
      controller.rotated,
      isTrue,
      reason: 'the board must not flip by 180 degrees',
    );
    expect(
      controller.me!.paddle.angle,
      myAngle,
      reason: 'the bottom HUD must keep showing our own player',
    );
    expect(controller.ownName, 'Tester');
    expect(controller.opponentName, 'Host');
    expect(controller.won, isTrue, reason: 'the winner stays the winner');

    controller.dispose();
  });

  test('plays snapshot events once and drives the effects', () async {
    final env = await createTestEnv();
    final server = FakeDuelServer();
    final controller = await connectedController(env, server);
    server.start(countdown: 0);
    await settle();
    final state = GameState.initial(
      GameConfig(mode: GameMode.duel, seed: seed),
    );
    state.tick = 30;
    server.snap(
      state,
      events: const [
        GameEvent(GameEventType.paddleHit, player: 0, x: 0.1, y: -0.9),
      ],
    );
    await settle();
    expect(controller.fx.shake, greaterThan(0));
    expect(
      controller.fx.particles.where((p) => p.alive).length,
      greaterThan(0),
    );
    controller.dispose();
  });

  test(
    'coalesces a burst of queued snapshots into one round of feedback',
    () async {
      final env = await createTestEnv();
      final audio = SpyAudio();
      final server = FakeDuelServer();
      final controller = await connectedController(env, server, audio: audio);
      server.start(countdown: 0);
      await settle();
      for (var i = 0; i < 30; i++) {
        controller.advance(frame);
      }
      audio.played.clear();

      // A 500 ms stall of the UI thread queues ten 20 Hz snapshots; they all
      // arrive before the next frame runs. Only the newest state survives, so
      // the feedback for the nine superseded ones must not be played on top.
      for (var i = 0; i < 10; i++) {
        final s = GameState.initial(
          GameConfig(mode: GameMode.duel, seed: seed),
        );
        s.tick = 33 + i * 3;
        server.snap(
          s,
          events: const [
            GameEvent(GameEventType.paddleHit, player: 0, x: 0.1, y: -0.9),
          ],
        );
      }
      await settle();

      expect(controller.state!.tick, 60, reason: 'the newest snapshot wins');
      expect(
        audio.count(Sfx.hit),
        1,
        reason: 'one hit sound, not a burst of ten',
      );
      expect(
        controller.fx.shake,
        closeTo(0.12, 1e-9),
        reason:
            'one paddle-hit shake, not ten stacked into a full-strength one',
      );

      // The next rendered frame opens the budget again.
      controller.advance(frame);
      final later = GameState.initial(
        GameConfig(mode: GameMode.duel, seed: seed),
      );
      later.tick = 63;
      server.snap(
        later,
        events: const [
          GameEvent(GameEventType.paddleHit, player: 1, x: -0.1, y: 0.9),
        ],
      );
      await settle();
      expect(audio.count(Sfx.hit), 2);

      controller.dispose();
    },
  );

  test('surfaces server errors', () async {
    final env = await createTestEnv();
    final server = FakeDuelServer();
    final controller = await connectedController(env, server);
    server.emit(const ErrorMsg(code: 'room_not_found'));
    await settle();
    expect(controller.error, 'room_not_found');
    controller.clearError();
    expect(controller.error, isNull);
    controller.dispose();
  });

  test('opens the accelerometer only while a match is live', () async {
    final env = await createTestEnv();
    final server = FakeDuelServer();
    // A broadcast controller stands in for the sensor stream, so the same
    // source can be listened to again after it was released.
    final accelerometer = StreamController<AccelerometerEvent>.broadcast();
    addTearDown(accelerometer.close);
    final tilt = TiltInput(
      settings: env.settings,
      source: accelerometer.stream,
    );
    final controller = DuelController(
      client: DuelClient(
        wsUri: () => Uri.parse('ws://fake.local/ws'),
        connector: server.connect,
      ),
      settings: env.settings,
      audio: env.audio,
      haptics: env.haptics,
      input: CompositeInput(<InputController>[tilt]),
    );

    // Lobby and waiting room: there is no paddle to steer yet.
    expect(accelerometer.hasListener, isFalse);
    await controller.createRoom('Tester');
    await settle();
    expect(controller.hasMatch, isFalse);
    expect(
      accelerometer.hasListener,
      isFalse,
      reason: 'the waiting room must not sample the accelerometer',
    );

    server.start(countdown: 0);
    await settle();
    expect(
      accelerometer.hasListener,
      isTrue,
      reason: 'a live match must be steerable',
    );

    // Result overlay: nothing left to move.
    server.over(winner: 0);
    await settle();
    expect(accelerometer.hasListener, isFalse);

    // A rematch re-arms the sensor; the peer leaving releases it again.
    server.start(countdown: 0);
    await settle();
    expect(accelerometer.hasListener, isTrue);
    server.peerLeft();
    await settle();
    expect(accelerometer.hasListener, isFalse);

    // Leaving the room goes back to the lobby, which samples nothing.
    server.start(countdown: 0);
    await settle();
    controller.leaveRoom();
    expect(
      accelerometer.hasListener,
      isFalse,
      reason: 'back in the lobby the sensor must be released',
    );

    controller.dispose();
  });
}
