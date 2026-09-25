/// Cross-platform determinism check (SPEC §2.1).
///
/// Runs a fixed duel of [_ticks] ticks in which both players are aim-at-ball
/// bots with deterministic jitter drawn from a dedicated [Prng] (independent of
/// the simulation's own rng, so the bots never perturb the sim's random
/// sequence), then prints the state fingerprint:
///
///     hash=<h> score0=<s0> score1=<s1> tick=<t>
///
/// The same line must be printed by all three backends:
///
///     dart run tool/det_check.dart
///     dart compile exe tool/det_check.dart -o /tmp/det_check && /tmp/det_check
///     dart compile js  tool/det_check.dart -o /tmp/det_check.js && node /tmp/det_check.js
///
/// Any difference means the simulation escaped the arithmetic rules of §2.1
/// (typically 64-bit integer math that does not survive the JS number type).
library;

import 'package:arco_core/arco_core.dart';

const int _seed = 12345;
const int _jitterSeed = 0xC0FFEE;
const int _ticks = 20000;
const double _jitter = 0.15;

void main() {
  final state = GameState.initial(
    const GameConfig(mode: GameMode.duel, seed: _seed),
  );
  final jitter = Prng(_jitterSeed);
  final inputs = <PlayerInput>[PlayerInput.none, PlayerInput.none];
  for (var i = 0; i < _ticks; i++) {
    for (var p = 0; p < inputs.length; p++) {
      final wanted = ScriptedInput.aimAtBall(state, p);
      inputs[p] = wanted.hasAim
          ? PlayerInput.aimAngle(
              wanted.targetAngle + jitter.nextRange(-_jitter, _jitter),
            )
          : wanted;
    }
    Simulation.step(state, inputs);
  }
  final s0 = state.players[0].score;
  final s1 = state.players[1].score;
  print('hash=${state.hash()} score0=$s0 score1=$s1 tick=${state.tick}');
}
