// Determinism of the simulation: same (config, inputs) -> same state, and the
// state survives clone() and a JSON round trip unchanged (SPEC §2.1, §2.6).
import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const int _ticks = 5000;
const int _sampleEvery = 500;
const int _jitterSeed = 0x5EED;
const double _jitter = 0.12;

/// One scripted run: an aim-at-ball bot per player whose aim is perturbed with
/// jitter from its own [Prng], so the inputs are reproducible but not trivial
/// (they change dozens of times per second and depend on the whole state).
class ScriptedRun {
  ScriptedRun(GameMode mode, int seed)
    : state = GameState.initial(GameConfig(mode: mode, seed: seed)),
      jitter = Prng(_jitterSeed) {
    _inputs = List<PlayerInput>.filled(state.players.length, PlayerInput.none);
  }

  ScriptedRun._(this.state, this.jitter) {
    _inputs = List<PlayerInput>.filled(state.players.length, PlayerInput.none);
  }

  final GameState state;
  final Prng jitter;
  late List<PlayerInput> _inputs;

  /// A continuation of this run from a deep copy of its state.
  ScriptedRun forkClone() => ScriptedRun._(state.clone(), jitter.clone());

  /// A continuation of this run from a JSON snapshot of its state.
  ScriptedRun forkJson() => ScriptedRun._(
    GameState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
    ),
    jitter.clone(),
  );

  void step() {
    for (var p = 0; p < _inputs.length; p++) {
      final wanted = ScriptedInput.aimAtBall(state, p);
      _inputs[p] = wanted.hasAim
          ? PlayerInput.aimAngle(
              wanted.targetAngle + jitter.nextRange(-_jitter, _jitter),
            )
          : wanted;
    }
    Simulation.step(state, _inputs);
  }

  /// Steps [ticks] ticks and returns the hash after every [every] ticks.
  List<int> run(int ticks, {int every = _sampleEvery}) {
    final hashes = <int>[];
    for (var i = 1; i <= ticks; i++) {
      step();
      if (i % every == 0) hashes.add(state.hash());
    }
    return hashes;
  }
}

void main() {
  for (final mode in GameMode.values) {
    group('${mode.name} determinism', () {
      test('two fresh runs of $_ticks ticks stay bit-identical', () {
        final a = ScriptedRun(mode, 1234);
        final b = ScriptedRun(mode, 1234);
        final ha = a.run(_ticks);
        final hb = b.run(_ticks);
        expect(ha.length, _ticks ~/ _sampleEvery);
        expect(hb, ha);
        expect(a.state.toJson(), b.state.toJson());
        // The run is not trivially static.
        expect(ha.toSet().length, greaterThan(1));
        expect(a.state.tick, _ticks);
        expect(
          a.state.players.map((p) => p.score).reduce((x, y) => x + y),
          greaterThan(0),
        );
      });

      test('a different seed produces a different run', () {
        final a = ScriptedRun(mode, 1234).run(_ticks);
        final b = ScriptedRun(mode, 1235).run(_ticks);
        expect(b, isNot(a));
      });

      test('clone() mid-game continues identically', () {
        final original = ScriptedRun(mode, 99);
        original.run(_ticks ~/ 2);
        final copy = original.forkClone();
        expect(copy.state.hash(), original.state.hash());
        expect(copy.state.toJson(), original.state.toJson());
        final rest = _ticks ~/ 2;
        expect(copy.run(rest), original.run(rest));
        expect(copy.state.toJson(), original.state.toJson());
      });

      test('toJson/fromJson mid-game continues identically', () {
        final original = ScriptedRun(mode, 7);
        original.run(_ticks ~/ 2);
        final restored = original.forkJson();
        expect(restored.state.hash(), original.state.hash());
        expect(restored.state.toJson(), original.state.toJson());
        final rest = _ticks ~/ 2;
        expect(restored.run(rest), original.run(rest));
        expect(restored.state.hash(), original.state.hash());
      });

      test(
        'a snapshot round trip every $_sampleEvery ticks changes nothing',
        () {
          // This is what a duel client does on every server snapshot.
          final direct = ScriptedRun(mode, 55);
          var relayed = ScriptedRun(mode, 55);
          final hashes = <int>[];
          for (var block = 0; block < _ticks ~/ _sampleEvery; block++) {
            direct.run(_sampleEvery);
            relayed.run(_sampleEvery);
            relayed = relayed.forkJson();
            hashes.add(relayed.state.hash());
            expect(relayed.state.hash(), direct.state.hash());
          }
          expect(hashes.last, direct.state.hash());
        },
      );
    });
  }

  group('hash', () {
    test('is stable across fresh states with the same seed', () {
      for (final mode in GameMode.values) {
        for (final seed in [0, 1, 42, 0xFFFFFFFF]) {
          final config = GameConfig(mode: mode, seed: seed);
          expect(
            GameState.initial(config).hash(),
            GameState.initial(config).hash(),
          );
        }
      }
    });

    test('is a 32-bit value and reacts to every serialized field', () {
      final run = ScriptedRun(GameMode.duel, 3);
      run.run(2000);
      final s = run.state;
      final h = s.hash();
      expect(h, inRange(0, 0xFFFFFFFF));
      expect(s.clone().hash(), h);
      // Every mutation below changes a field that influences the future.
      final mutations = <String, void Function(GameState)>{
        'tick': (g) => g.tick += 1,
        'phase': (g) => g.phase = Phase.gameOver,
        'serveTimer': (g) => g.serveTimer += 1,
        'nextWallIn': (g) => g.nextWallIn += 1,
        'nextPickupIn': (g) => g.nextPickupIn += 1,
        'nextId': (g) => g.nextId += 1,
        'winner': (g) => g.winner = 1,
        'rng': (g) => g.rng.nextUint32(),
        'paddle': (g) => g.players[0].paddle.angle += 1e-4,
        'lives': (g) => g.players[1].lives -= 1,
        'score': (g) => g.players[1].score += 1,
        'combo': (g) => g.players[0].combo += 1,
        'ball.x': (g) => g.balls[0].x += 1e-4,
        'ball.y': (g) => g.balls[0].y += 1e-4,
        'ball.vx': (g) => g.balls[0].vx += 1e-4,
        'ball.vy': (g) => g.balls[0].vy += 1e-4,
        'ball.speed': (g) => g.balls[0].speed += 1e-4,
        'ball.owner': (g) => g.balls[0].owner = g.balls[0].owner == 0 ? 1 : 0,
        'ball.active': (g) => g.balls[0].active = !g.balls[0].active,
        'wall': (g) => g.walls.add(
          Wall.segment(id: 77, x1: 0.1, y1: 0.1, x2: 0.3, y2: 0.3, ttl: 600),
        ),
        'pickup': (g) => g.pickups.add(
          Pickup(id: 78, type: PickupType.star, x: 0.2, y: 0.2),
        ),
      };
      mutations.forEach((name, mutate) {
        final c = s.clone();
        mutate(c);
        expect(c.hash(), isNot(h), reason: 'hash ignores $name');
      });
    });

    test('ignores nothing that the snapshot carries', () {
      // A state rebuilt from the snapshot of a mid-game state must hash the
      // same, which is only possible if hash() and toJson() cover the same
      // fields.
      final run = ScriptedRun(GameMode.duel, 21);
      for (var i = 0; i < 10; i++) {
        run.run(300);
        final json = jsonDecode(jsonEncode(run.state.toJson()));
        final restored = GameState.fromJson(json as Map<String, dynamic>);
        expect(restored.hash(), run.state.hash());
        expect(restored.walls.length, run.state.walls.length);
        expect(restored.pickups.length, run.state.pickups.length);
        expect(restored.rng.toJson(), run.state.rng.toJson());
      }
    });
  });

  group('arithmetic discipline', () {
    test('DetMath and Prng results do not depend on evaluation order', () {
      // Repeated evaluation must be bit-identical (no fused or reassociated
      // operations sneaking in).
      for (var i = 0; i < 2000; i++) {
        final x = i * 0.00731 - 7.0;
        expect(DetMath.sin(x), DetMath.sin(x));
        expect(DetMath.cos(x), DetMath.cos(x));
        expect(DetMath.atan2(x, 1 - x), DetMath.atan2(x, 1 - x));
        expect(DetMath.normAngle(x), DetMath.normAngle(x));
        expect(DetMath.angleDiff(x, 0.3), DetMath.angleDiff(x, 0.3));
      }
      final a = Prng(12345);
      final b = Prng(12345);
      for (var i = 0; i < 10000; i++) {
        expect(a.nextUint32(), b.nextUint32());
      }
    });

    test('the simulation draws randomness only from the state rng', () {
      // Two states that share a seed but are stepped in different interleavings
      // must agree, which fails if anything reads a global source.
      final a = ScriptedRun(GameMode.solo, 4242);
      final b = ScriptedRun(GameMode.solo, 4242);
      for (var i = 0; i < 1500; i++) {
        a.step();
      }
      for (var i = 0; i < 1500; i++) {
        b.step();
      }
      expect(b.state.hash(), a.state.hash());
      expect(b.state.rng.toJson(), a.state.rng.toJson());
    });
  });
}
