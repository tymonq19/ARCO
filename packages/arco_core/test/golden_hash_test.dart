// The one-ball golden hashes: the invariant that survived the shaped-wall and
// multi-ball rewrite (SPEC §2.1, §2.3).
//
// A one-ball game with wall spawning suppressed must hash bit-identically to
// the build from before walls had shapes and games could have two balls. The
// eight numbers below — two modes × four seeds, each hashed after 12000 ticks —
// were captured from that build and are pinned here as literals: everything
// they cover — ball motion, sub-stepping, the paddle bounce and its
// english, the serve and its speed ramp, pickup spawning and collection,
// escapes, lives, scoring, combos and the exact order in which the simulation
// draws from its rng — is behaviour the rewrite was not allowed to move. If one
// of these changes, a replay recorded by an older client stops verifying and
// the leaderboard starts rejecting honest runs (or accepting dishonest ones),
// so a failure here is never "update the constant".
//
// Why the runs suppress wall spawning. A shaped wall is a polyline, and drawing
// one costs the rng a shape roll plus (for a bent or curved wall) one shape
// parameter that a straight wall never drew. Both the geometry and the draw
// sequence therefore differ from the old build **by design**, so a run that
// spawns walls cannot hash the same however careful the rewrite is. The
// wall-bearing hashes of the old build are recorded in the scratchpad next to
// these, and deliberately not pinned: pinning them would pin the old
// single-segment wall, which is exactly the thing that was replaced. What keeps
// walls honest instead is wall_shape_test.dart (geometry, no-tunnelling, spawn
// rules) plus the three-way determinism check in tool/det_check.dart, which
// does exercise shaped walls.
//
// Suppression is a plain assignment to `nextWallIn`, re-applied after every
// step. An assignment consumes no randomness, so the rng stays exactly where
// `GameState.initial` left it and the run is the game the old build played with
// its walls unlucky enough never to spawn.
import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

/// Ticks per golden run (200 s of play: dozens of serves, escapes and pickups).
const int _ticks = 12000;

/// Seeds the golden runs use.
const List<int> _seeds = [1, 7, 12345, 99991];

/// Hashes of a one-ball game with wall spawning suppressed, after [_ticks]
/// ticks of aim-at-ball play, captured from the build before wall shapes and
/// ball counts existed (git 82f9775).
const Map<GameMode, Map<int, int>> _goldenWallsOff = {
  GameMode.solo: {
    1: 2121979818,
    7: 855192513,
    12345: 290196780,
    99991: 1715839284,
  },
  GameMode.duel: {
    1: 1792545572,
    7: 1309718978,
    12345: 3954175050,
    99991: 2564360939,
  },
};

/// A value so large that `nextWallIn` can never count down to a spawn.
const int _never = 1 << 30;

/// Runs a one-ball game of [ticks] ticks with aim-at-ball bots and no wall
/// spawns, and returns the final state.
GameState _run(int seed, GameMode mode, {int ticks = _ticks}) {
  final state = GameState.initial(GameConfig(mode: mode, seed: seed));
  state.nextWallIn = _never;
  final inputs = List<PlayerInput>.filled(
    state.config.playerCount,
    PlayerInput.none,
  );
  for (var t = 0; t < ticks; t++) {
    for (var p = 0; p < state.config.playerCount; p++) {
      inputs[p] = ScriptedInput.aimAtBall(state, p);
    }
    Simulation.step(state, inputs);
    state.nextWallIn = _never;
  }
  return state;
}

void main() {
  group('one-ball golden hash', () {
    for (final mode in GameMode.values) {
      for (final seed in _seeds) {
        test('$_ticks ticks of ${mode.name} seed $seed', () {
          final state = _run(seed, mode);
          expect(
            state.hash(),
            _goldenWallsOff[mode]![seed],
            reason:
                'the one-ball simulation moved: a ${mode.name} game on seed '
                '$seed no longer plays out the way it did before wall shapes '
                'and ball counts existed',
          );
        });
      }
    }

    test('the golden runs really played a game', () {
      // A hash over a state that never moved would match trivially, so check
      // that these runs are the busy games they are meant to be.
      final state = _run(12345, GameMode.solo);
      expect(state.tick, _ticks);
      expect(state.walls, isEmpty, reason: 'wall spawning was suppressed');
      expect(state.nextWallIn, _never);
      expect(
        state.players[0].score,
        greaterThan(1000),
        reason: 'the bot kept the ball alive and collected pickups',
      );
      expect(
        state.nextId,
        greaterThan(10),
        reason: 'pickups were spawned, so the rng was drawn from all game',
      );
    });

    test('suppressing wall spawning consumes no randomness', () {
      // The whole reference method rests on this: setting nextWallIn is a plain
      // assignment, so the rng is untouched and the run is the old build's game.
      final a = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 4242),
      );
      final before = a.rng.toJson();
      a.nextWallIn = _never;
      expect(a.rng.toJson(), before);
      expect(a.hash(), isNot(0));
    });

    test('a one-ball state hashes exactly what it hashed before', () {
      // `config` is not part of the hash and one ball mixes its seven values
      // where the single ball used to, so a default GameConfig and an explicit
      // ballCount: 1 are the same state to hash() and to the verifier.
      final implicit = _run(7, GameMode.solo, ticks: 600);
      final explicit = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 7, ballCount: 1),
      );
      explicit.nextWallIn = _never;
      final inputs = <PlayerInput>[PlayerInput.none];
      for (var t = 0; t < 600; t++) {
        inputs[0] = ScriptedInput.aimAtBall(explicit, 0);
        Simulation.step(explicit, inputs);
        explicit.nextWallIn = _never;
      }
      expect(explicit.hash(), implicit.hash());
    });
  });
}
