import 'package:arco/game/controllers/solo_controller.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// One simulated frame at the fixed rate.
const double frame = 1 / 60;

void main() {
  test('plays a full game and produces a replay the verifier accepts', () async {
    final env = await createTestEnv();
    late SoloController controller;
    var frames = 0;
    // A deterministic bot: keep the ball alive for 15 s, then run away from it
    // so the game ends within a few serves.
    controller = SoloController(
      settings: env.settings,
      audio: env.audio,
      haptics: env.haptics,
      input: FakeInput(() {
        final state = controller.state;
        return frames < 900
            ? ScriptedInput.aimAtBall(state, 0)
            : ScriptedInput.avoidBall(state, 0);
      }),
      seedSource: () => 20260923,
    );
    controller.start();
    while (!controller.gameOver && frames < 20000) {
      controller.advance(frame);
      frames++;
    }

    expect(controller.gameOver, isTrue, reason: 'the game never ended');
    expect(controller.score, greaterThan(0));
    final replay = controller.replay;
    expect(replay, isNotNull);
    expect(replay!.finalTick, controller.state.tick);
    expect(replay.claimedScore, controller.score);
    expect(replay.inputs, hasLength(1));

    final result = ReplayVerifier.verify(replay);
    expect(result.ok, isTrue, reason: 'verify failed: ${result.reason}');
    expect(result.score, controller.score);
    expect(result.ticks, controller.state.tick);

    // The replay must survive the JSON round trip the server receives.
    final decoded = Replay.decode(replay.encode());
    final again = ReplayVerifier.verify(decoded);
    expect(again.ok, isTrue);
    expect(again.hash, result.hash);

    // A tampered claim must be rejected.
    final tampered = Replay(
      config: replay.config,
      inputs: replay.inputs,
      finalTick: replay.finalTick,
      claimedScore: replay.claimedScore + 1000,
    );
    expect(ReplayVerifier.verify(tampered).ok, isFalse);

    controller.dispose();
  });

  test('steps deterministically: the same inputs give the same hash', () async {
    final env = await createTestEnv();
    int hashOf(int seed) {
      late SoloController controller;
      var frames = 0;
      controller = SoloController(
        settings: env.settings,
        audio: env.audio,
        haptics: env.haptics,
        input: FakeInput(() {
          final state = controller.state;
          return frames < 400
              ? ScriptedInput.aimAtBall(state, 0)
              : PlayerInput.none;
        }),
        seedSource: () => seed,
      );
      controller.start();
      while (frames < 600) {
        controller.advance(frame);
        frames++;
      }
      final hash = controller.state.hash();
      controller.dispose();
      return hash;
    }

    expect(hashOf(7), hashOf(7));
    expect(hashOf(7), isNot(hashOf(8)));
  });

  test('never catches up more than five steps in one frame', () async {
    final env = await createTestEnv();
    final controller = SoloController(
      settings: env.settings,
      audio: env.audio,
      haptics: env.haptics,
      input: FakeInput(),
      seedSource: () => 5,
    );
    controller.start();
    controller.advance(1.0); // a one second stall
    expect(controller.state.tick, SoloController.maxCatchUpSteps);
    controller.advance(frame);
    expect(controller.state.tick, SoloController.maxCatchUpSteps + 1);
    controller.dispose();
  });

  test('does not step before the first tap and resets on retry', () async {
    final env = await createTestEnv();
    var seed = 100;
    final controller = SoloController(
      settings: env.settings,
      audio: env.audio,
      haptics: env.haptics,
      input: FakeInput(() => const PlayerInput(move: 16)),
      seedSource: () => seed++,
    );
    expect(controller.state.config.seed, 100);
    controller.advance(frame);
    expect(controller.state.tick, 0);

    controller.start();
    controller.advance(frame);
    expect(controller.state.tick, 1);
    expect(controller.inputLog.length, 1);

    controller.pause();
    controller.advance(frame);
    expect(controller.state.tick, 1, reason: 'paused games do not step');
    controller.resume();

    controller.retry();
    expect(controller.state.tick, 0);
    expect(controller.started, isFalse);
    expect(controller.inputLog.length, 0);
    expect(controller.state.config.seed, 101);
    controller.dispose();
  });

  test('records the personal best', () async {
    final env = await createTestEnv();
    late SoloController controller;
    var frames = 0;
    controller = SoloController(
      settings: env.settings,
      audio: env.audio,
      haptics: env.haptics,
      input: FakeInput(() {
        final state = controller.state;
        return frames < 600
            ? ScriptedInput.aimAtBall(state, 0)
            : ScriptedInput.avoidBall(state, 0);
      }),
      seedSource: () => 31337,
    );
    controller.start();
    while (!controller.gameOver && frames < 20000) {
      controller.advance(frame);
      frames++;
    }
    expect(controller.gameOver, isTrue);
    expect(env.settings.bestScore, controller.score);
    expect(controller.newBest, isTrue);
    controller.dispose();
  });
}
