// Replay recording, encoding and server-side verification (SPEC §2.5, §2.6).
import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// A real solo game played by the scripted bot: it defends for [playTicks]
/// ticks and then dodges the ball until it runs out of lives.
({Replay replay, GameState state, InputLog log}) recordGame({
  int seed = 7,
  int playTicks = 1200,
}) {
  final (state, log) = playRecordedSolo(seed: seed, playTicks: playTicks);
  expect(state.phase, Phase.gameOver, reason: 'the bot must finish the game');
  final replay = Replay(
    config: GameConfig(mode: GameMode.solo, seed: seed),
    inputs: [log],
    finalTick: state.tick,
    claimedScore: state.players[0].score,
  );
  return (replay: replay, state: state, log: log);
}

/// A copy of [log] that can be extended without touching the original.
InputLog copyOf(InputLog log) => InputLog.fromJson(log.toJson());

Replay withInputs(Replay r, List<InputLog> inputs) => Replay(
  config: r.config,
  inputs: inputs,
  finalTick: r.finalTick,
  claimedScore: r.claimedScore,
  formatVersion: r.formatVersion,
);

void main() {
  group('Replay JSON', () {
    test('round-trips through toJson/fromJson and encode/decode', () {
      final recorded = recordGame();
      final r = recorded.replay;
      expect(r.formatVersion, Replay.version);

      final viaJson = Replay.fromJson(r.toJson());
      expect(viaJson.toJson(), r.toJson());

      final text = r.encode();
      final decoded = Replay.decode(text);
      expect(decoded.config, r.config);
      expect(decoded.finalTick, r.finalTick);
      expect(decoded.claimedScore, r.claimedScore);
      expect(decoded.formatVersion, Replay.version);
      expect(decoded.inputs.length, 1);
      expect(decoded.inputs[0].toJson(), r.inputs[0].toJson());
      // The encoding is plain JSON with the documented keys.
      final map = jsonDecode(text) as Map<String, dynamic>;
      expect(map.keys.toSet(), {'v', 'cfg', 'in', 'ft', 'sc'});
      // A decoded replay verifies exactly like the original.
      final a = ReplayVerifier.verify(r);
      final b = ReplayVerifier.verify(decoded);
      expect(b.ok, a.ok);
      expect(b.score, a.score);
      expect(b.hash, a.hash);
      expect(b.ticks, a.ticks);
    });

    test('an empty input log round-trips', () {
      final r = Replay(
        config: const GameConfig(mode: GameMode.solo, seed: 1),
        inputs: [InputLog()],
        finalTick: 10,
        claimedScore: 0,
      );
      final back = Replay.decode(r.encode());
      expect(back.inputs[0].length, 0);
      expect(back.toJson(), r.toJson());
    });
  });

  group('ReplayVerifier', () {
    test('accepts a real recorded game and reproduces its state', () {
      final recorded = recordGame();
      final result = ReplayVerifier.verify(recorded.replay);
      expect(result.ok, isTrue, reason: 'reason: ${result.reason}');
      expect(result.reason, isNull);
      expect(result.score, recorded.state.players[0].score);
      expect(result.ticks, recorded.state.tick);
      expect(result.hash, recorded.state.hash());
      expect(result.lives, 0);
      expect(result.score, greaterThan(0));
    });

    test('accepts games recorded from several seeds', () {
      for (final seed in [1, 3, 11, 2024, 0x7FFFFFFF]) {
        final recorded = recordGame(seed: seed, playTicks: 900);
        final result = ReplayVerifier.verify(recorded.replay);
        expect(result.ok, isTrue, reason: 'seed $seed: ${result.reason}');
        expect(result.score, recorded.state.players[0].score);
      }
    });

    test('rejects a tampered score', () {
      final r = recordGame().replay;
      for (final delta in [1, -1, 1000]) {
        final tampered = Replay(
          config: r.config,
          inputs: r.inputs,
          finalTick: r.finalTick,
          claimedScore: r.claimedScore + delta,
        );
        final result = ReplayVerifier.verify(tampered);
        expect(result.ok, isFalse);
        expect(result.reason, 'score_mismatch');
        // The verification still reports the score it actually simulated.
        expect(result.score, r.claimedScore);
      }
    });

    test('rejects a replay that never reaches gameOver', () {
      final r = recordGame().replay;
      final short = Replay(
        config: r.config,
        inputs: r.inputs,
        finalTick: r.finalTick - 60,
        claimedScore: r.claimedScore,
      );
      final result = ReplayVerifier.verify(short);
      expect(result.ok, isFalse);
      expect(result.reason, 'not_finished');
      expect(result.ticks, r.finalTick - 60);
      expect(result.lives, greaterThan(0));

      // finalTick 0 cannot contain a finished game either.
      expect(
        ReplayVerifier.verify(
          Replay(
            config: r.config,
            inputs: r.inputs,
            finalTick: 0,
            claimedScore: 0,
          ),
        ).reason,
        'not_finished',
      );
    });

    test('rejects a finalTick past the real game over', () {
      final r = recordGame().replay;
      for (final extra in [1, 2, 600]) {
        final late = Replay(
          config: r.config,
          inputs: r.inputs,
          finalTick: r.finalTick + extra,
          claimedScore: r.claimedScore,
        );
        final result = ReplayVerifier.verify(late);
        expect(result.ok, isFalse);
        expect(result.reason, 'early_finish');
        expect(result.ticks, r.finalTick);
      }
    });

    test('rejects too many ticks before simulating anything', () {
      final r = recordGame().replay;
      final tooLong = Replay(
        config: r.config,
        inputs: r.inputs,
        finalTick: ReplayVerifier.maxTicks + 1,
        claimedScore: r.claimedScore,
      );
      final result = ReplayVerifier.verify(tooLong);
      expect(result.ok, isFalse);
      expect(result.reason, 'too_long');
      expect(result.ticks, 0, reason: 'rejected without re-simulating');
    });

    test('rejects a duel replay', () {
      final r = recordGame().replay;
      final duel = Replay(
        config: GameConfig(mode: GameMode.duel, seed: r.config.seed),
        inputs: [r.inputs[0], InputLog()],
        finalTick: r.finalTick,
        claimedScore: r.claimedScore,
      );
      final result = ReplayVerifier.verify(duel);
      expect(result.ok, isFalse);
      expect(result.reason, 'wrong_mode');
    });

    test('rejects an unsupported format version', () {
      final r = recordGame().replay;
      for (final version in [0, 1, Replay.version + 1, 99]) {
        final other = Replay(
          config: r.config,
          inputs: r.inputs,
          finalTick: r.finalTick,
          claimedScore: r.claimedScore,
          formatVersion: version,
        );
        final result = ReplayVerifier.verify(other);
        expect(result.ok, isFalse);
        expect(result.reason, 'unsupported_version');
      }
    });

    test('rejects a wrong number of input logs', () {
      final r = recordGame().replay;
      for (final logs in [
        <InputLog>[],
        [r.inputs[0], InputLog()],
      ]) {
        final result = ReplayVerifier.verify(withInputs(r, logs));
        expect(result.ok, isFalse);
        expect(result.reason, 'bad_inputs');
      }
    });

    test('inputs after finalTick cannot change the outcome', () {
      final recorded = recordGame();
      final accepted = ReplayVerifier.verify(recorded.replay);
      expect(accepted.ok, isTrue);

      final padded = copyOf(recorded.log);
      padded.record(recorded.replay.finalTick, const PlayerInput(move: -9));
      padded.record(recorded.replay.finalTick + 1, const PlayerInput(move: 9));
      padded.record(recorded.replay.finalTick + 5000, PlayerInput.none);
      expect(padded.length, greaterThan(recorded.log.length));

      final result = ReplayVerifier.verify(
        withInputs(recorded.replay, [padded]),
      );
      expect(result.ok, isTrue, reason: 'reason: ${result.reason}');
      expect(result.hash, accepted.hash);
      expect(result.score, accepted.score);
      expect(result.ticks, accepted.ticks);
    });

    test('a changed input before finalTick changes the outcome', () {
      final recorded = recordGame();
      // One different input halfway through the game is enough to diverge.
      // Ticks must stay ordered, so the entry is spliced into the JSON.
      final half = recorded.replay.finalTick ~/ 2;
      final entries = recorded.log.toJson();
      final tweaked = InputLog.fromJson([
        for (final e in entries)
          if (e[0] < half) e,
        [half, const PlayerInput(move: 3).encode()],
        for (final e in entries)
          if (e[0] > half) e,
      ]);
      final result = ReplayVerifier.verify(
        withInputs(recorded.replay, [tweaked]),
      );
      expect(result.ok, isFalse);
      expect(result.hash, isNot(ReplayVerifier.verify(recorded.replay).hash));
    });

    test('verification is repeatable and free of side effects', () {
      final r = recordGame().replay;
      final first = ReplayVerifier.verify(r);
      final second = ReplayVerifier.verify(r);
      expect(second.ok, first.ok);
      expect(second.hash, first.hash);
      expect(second.score, first.score);
      expect(second.ticks, first.ticks);
      expect(
        r.inputs[0].toJson(),
        Replay.decode(r.encode()).inputs[0].toJson(),
      );
    });

    test(
      'verifies a maximum-length replay well under the time budget',
      () {
        // The aim-at-ball bot survives indefinitely, so this drives the verifier
        // through the full maxTicks loop (the longest run the server can face).
        final s = GameState.initial(
          const GameConfig(mode: GameMode.solo, seed: 4),
        );
        final log = InputLog();
        final inputs = <PlayerInput>[PlayerInput.none];
        while (s.tick < ReplayVerifier.maxTicks) {
          final input = ScriptedInput.aimAtBall(s, 0);
          log.record(s.tick, input);
          inputs[0] = input;
          Simulation.step(s, inputs);
        }
        final replay = Replay(
          config: const GameConfig(mode: GameMode.solo, seed: 4),
          inputs: [log],
          finalTick: ReplayVerifier.maxTicks,
          claimedScore: s.players[0].score,
        );
        final watch = Stopwatch()..start();
        final result = ReplayVerifier.verify(replay);
        watch.stop();
        expect(result.ticks, ReplayVerifier.maxTicks);
        expect(result.reason, 'not_finished');
        expect(result.hash, s.hash());
        expect(
          watch.elapsedMilliseconds,
          lessThan(2000),
          reason:
              'verifying one hour of play took ${watch.elapsedMilliseconds} ms',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
