/// Cross-platform determinism check (SPEC §2.1).
///
/// Prints a fingerprint of four scenarios and a combined total:
///
///     duel-1ball  hash=<h> score0=<s0> score1=<s1> tick=<t> walls=<a/b/c>
///     solo-2ball  hash=<h> …
///     duel-2ball  hash=<h> …
///     wallshapes  hash=<h> runs=<n>
///     total=<h>
///
/// The same lines must be printed by all three backends:
///
///     dart run tool/det_check.dart
///     dart compile exe tool/det_check.dart -o /tmp/det_check && /tmp/det_check
///     dart compile js  tool/det_check.dart -o /tmp/det_check.js && node /tmp/det_check.js
///
/// Any difference means the simulation escaped the arithmetic rules of §2.1
/// (typically 64-bit integer math that does not survive the JS number type, or
/// a `dart:math` transcendental that rounds differently per backend).
///
/// The scenarios exist to make sure the check actually covers the code it
/// claims to. The bots aim at the ball with deterministic jitter drawn from a
/// dedicated [Prng] (independent of the simulation's own rng, so they never
/// perturb the sim's random sequence), and the games are long enough to spawn
/// walls of all three shapes — `walls=a/b/c` counts the straight, bent and
/// curved ones, and a zero there would mean this check is not testing shapes.
/// `wallshapes` then drives the polyline collision directly over a grid of
/// every shape, orientation, length and shape parameter the game can spawn,
/// because a shape that only appears when the rng feels like it is a shape this
/// check cannot promise anything about.
library;

import 'package:arco_core/arco_core.dart';

const int _seed = 12345;
const int _jitterSeed = 0xC0FFEE;
const int _ticks = 20000;
const double _jitter = 0.15;

/// FNV-1a over the four little-endian bytes of [v], the same mixing
/// [GameState.hash] uses, so the combined total is 32-bit on every backend.
int _mix(int h, int v) {
  var x = v & 0xFFFFFFFF;
  var acc = h;
  for (var i = 0; i < 4; i++) {
    acc ^= x & 0xFF;
    acc = Prng.mul32(acc, 0x01000193);
    x >>= 8;
  }
  return acc;
}

/// One scripted game: aim-at-ball bots with jitter, played for [ticks] ticks.
/// Returns the fingerprint line and the state hash.
(String, int) _game(String label, GameConfig config, {int ticks = _ticks}) {
  final state = GameState.initial(config);
  final jitter = Prng(_jitterSeed);
  final inputs = List<PlayerInput>.filled(config.playerCount, PlayerInput.none);
  // How many walls of each shape the run actually spawned.
  final shapes = List<int>.filled(WallShape.values.length, 0);
  var lastWallId = 0;
  for (var i = 0; i < ticks; i++) {
    for (var p = 0; p < inputs.length; p++) {
      final wanted = ScriptedInput.aimAtBall(state, p);
      inputs[p] = wanted.hasAim
          ? PlayerInput.aimAngle(
              wanted.targetAngle + jitter.nextRange(-_jitter, _jitter),
            )
          : wanted;
    }
    Simulation.step(state, inputs);
    for (var w = 0; w < state.walls.length; w++) {
      final wall = state.walls[w];
      if (wall.id > lastWallId) {
        lastWallId = wall.id;
        shapes[wall.shape.index] += 1;
      }
    }
  }
  final hash = state.hash();
  final s0 = state.players[0].score;
  final s1 = state.players.length > 1 ? state.players[1].score : 0;
  final line =
      '$label  hash=$hash score0=$s0 score1=$s1 tick=${state.tick} '
      'walls=${shapes[0]}/${shapes[1]}/${shapes[2]}';
  return (line, hash);
}

/// A solo state already playing, with nothing scheduled to spawn (plain
/// assignments, so no randomness is consumed) and one ball at the origin
/// heading along [direction] at max speed.
GameState _shot(int seed, double direction) {
  final s = GameState.initial(GameConfig(mode: GameMode.solo, seed: seed));
  s.phase = Phase.playing;
  s.serveTimer = 0;
  s.nextWallIn = 1 << 30;
  s.nextPickupIn = 1 << 30;
  final b = s.balls[0];
  b.active = true;
  b.owner = 0;
  b.speed = maxSpeedSolo;
  b.x = 0;
  b.y = 0;
  b.vx = DetMath.cos(direction) * b.speed;
  b.vy = DetMath.sin(direction) * b.speed;
  return s;
}

/// Bounces a max-speed ball off every shape the game can spawn, over a grid of
/// orientations, lengths and shape parameters. Covers [Simulation.wallPoints]
/// (and so DetMath sin/cos across the whole circle) and the polyline collision,
/// neither of which the scripted games are guaranteed to reach.
(String, int) _wallShapes() {
  var h = 0x811C9DC5;
  var runs = 0;
  const angleSteps = 12;
  const grid = 3;
  for (var shapeIndex = 0; shapeIndex < WallShape.values.length; shapeIndex++) {
    final shape = WallShape.values[shapeIndex];
    for (var a = 0; a < angleSteps; a++) {
      final angle = a * DetMath.tau / angleSteps;
      for (var l = 0; l < grid; l++) {
        final length =
            wallMinLength + (wallMaxLength - wallMinLength) * l / (grid - 1);
        for (var p = 0; p < grid; p++) {
          final f = p / (grid - 1);
          final parameter = switch (shape) {
            WallShape.straight => 0.0,
            WallShape.bent =>
              wallBentMinAngle + (wallBentMaxAngle - wallBentMinAngle) * f,
            WallShape.curved =>
              wallCurveMinSweep + (wallCurveMaxSweep - wallCurveMinSweep) * f,
          };
          // Fire from the origin at a wall standing 0.3 out along +x, sweeping
          // the aim across it so joints, faces and caps are all hit.
          final direction = (a % 5 - 2) * 0.2;
          final s = _shot(1 + a * 31 + l * 7 + p, direction);
          s.walls.add(
            Wall(
              id: 1,
              shape: shape,
              points: Simulation.wallPoints(
                shape,
                0.3,
                0,
                angle,
                length,
                parameter,
              ),
              ttl: 1 << 20,
              age: wallFadeTicks,
            ),
          );
          final inputs = <PlayerInput>[PlayerInput.none];
          for (var t = 0; t < 150; t++) {
            Simulation.step(s, inputs);
          }
          h = _mix(h, s.hash());
          runs += 1;
        }
      }
    }
  }
  return ('wallshapes  hash=$h runs=$runs', h);
}

void main() {
  final results = <(String, int)>[
    _game('duel-1ball', const GameConfig(mode: GameMode.duel, seed: _seed)),
    _game(
      'solo-2ball',
      const GameConfig(mode: GameMode.solo, seed: 777, ballCount: 2),
    ),
    _game(
      'duel-2ball',
      const GameConfig(mode: GameMode.duel, seed: 4242, ballCount: 2),
    ),
    _wallShapes(),
  ];
  var total = 0x811C9DC5;
  for (var i = 0; i < results.length; i++) {
    print(results[i].$1);
    total = _mix(total, results[i].$2);
  }
  print('total=$total');
}
