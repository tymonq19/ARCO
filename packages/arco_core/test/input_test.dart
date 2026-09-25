import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('PlayerInput', () {
    test('encode/decode round-trips every value', () {
      final seen = <int>{};
      for (var move = -inputMoveMax; move <= inputMoveMax; move++) {
        final input = PlayerInput(move: move);
        final v = input.encode();
        expect(v, inRange(0, 2 * inputMoveMax));
        expect(PlayerInput.decode(v), input);
        seen.add(v);
      }
      for (var aim = 0; aim < inputAimSteps; aim++) {
        final input = PlayerInput(aim: aim);
        final v = input.encode();
        expect(v, inRange(2 * inputMoveMax + 1, PlayerInput.maxEncoded));
        expect(PlayerInput.decode(v), input);
        seen.add(v);
      }
      expect(seen.length, PlayerInput.maxEncoded + 1);
      expect(PlayerInput.none.encode(), inputMoveMax);
      expect(PlayerInput.decode(-1), PlayerInput.none);
      expect(PlayerInput.decode(PlayerInput.maxEncoded + 1), PlayerInput.none);
      // Aim takes precedence over move when encoding.
      expect(PlayerInput(move: 5, aim: 10).encode(), 33 + 10);
    });

    test('aimAngle quantizes any angle into 0..4095', () {
      expect(PlayerInput.aimAngle(0).aim, 0);
      expect(PlayerInput.aimAngle(DetMath.tau).aim, 0);
      expect(PlayerInput.aimAngle(DetMath.tau - 1e-9).aim, inputAimSteps - 1);
      expect(PlayerInput.aimAngle(-1e-9).aim, inputAimSteps - 1);
      expect(PlayerInput.aimAngle(DetMath.pi).aim, inputAimSteps ~/ 2);
      final a = PlayerInput.aimAngle(1.234);
      expect(a.hasAim, isTrue);
      expect(a.targetAngle, closeTo(1.234, DetMath.tau / inputAimSteps));
    });

    test('factories clamp and equality works', () {
      expect(PlayerInput.moving(100).move, inputMoveMax);
      expect(PlayerInput.moving(-100).move, -inputMoveMax);
      expect(PlayerInput.aiming(7), const PlayerInput(aim: 7));
      expect(PlayerInput.none.hasAim, isFalse);
      expect(PlayerInput.none.hashCode, const PlayerInput().hashCode);
    });
  });

  group('InputLog', () {
    test('stores only changes (delta semantics)', () {
      final log = InputLog();
      expect(log.length, 0);
      expect(log.lastTick, -1);
      log.record(0, PlayerInput.none); // none before anything: not stored
      expect(log.length, 0);
      log.record(3, const PlayerInput(move: 4));
      log.record(4, const PlayerInput(move: 4)); // unchanged: skipped
      log.record(5, const PlayerInput(move: 4));
      expect(log.length, 1);
      log.record(9, const PlayerInput(aim: 100));
      log.record(20, PlayerInput.none);
      log.record(21, PlayerInput.none);
      expect(log.length, 3);
      expect(log.lastTick, 20);
      expect(log.toJson(), [
        [3, 20],
        [9, 133],
        [20, 16],
      ]);
    });

    test('inputAt returns the value in effect at a tick', () {
      final log = InputLog();
      log.record(3, const PlayerInput(move: 4));
      log.record(9, const PlayerInput(aim: 100));
      log.record(20, PlayerInput.none);
      expect(log.inputAt(0), PlayerInput.none);
      expect(log.inputAt(2), PlayerInput.none);
      expect(log.inputAt(3), const PlayerInput(move: 4));
      expect(log.inputAt(8), const PlayerInput(move: 4));
      expect(log.inputAt(9), const PlayerInput(aim: 100));
      expect(log.inputAt(19), const PlayerInput(aim: 100));
      expect(log.inputAt(20), PlayerInput.none);
      expect(log.inputAt(1000000), PlayerInput.none);
    });

    test('recording the same tick overwrites, non-monotonic throws', () {
      final log = InputLog();
      log.record(5, const PlayerInput(move: 1));
      log.record(5, const PlayerInput(move: 2));
      expect(log.toJson(), [
        [5, 18],
      ]);
      log.record(5, PlayerInput.none); // back to the previous value: removed
      expect(log.length, 0);
      log.record(7, const PlayerInput(move: 3));
      log.record(8, const PlayerInput(move: 4));
      log.record(8, const PlayerInput(move: 3)); // equals previous: dropped
      expect(log.length, 1);
      expect(() => log.record(6, PlayerInput.none), throwsArgumentError);
    });

    test('JSON round-trip', () {
      final log = InputLog();
      for (var t = 0; t < 500; t += 7) {
        log.record(t, PlayerInput.decode(t % (PlayerInput.maxEncoded + 1)));
      }
      final copy = InputLog.fromJson(log.toJson());
      expect(copy.toJson(), log.toJson());
      expect(copy.length, log.length);
      expect(copy.lastTick, log.lastTick);
      for (var t = 0; t < 520; t++) {
        expect(copy.inputAt(t), log.inputAt(t));
      }
    });
  });
}
