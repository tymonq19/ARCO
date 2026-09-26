import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('GameState.initial', () {
    test('solo starts serving with one paddle at the bottom', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 9),
      );
      expect(s.tick, 0);
      expect(s.phase, Phase.serving);
      expect(s.serveTimer, serveTicks);
      expect(s.players.length, 1);
      expect(s.players[0].paddle.angle, bottomCenterAngle);
      expect(s.players[0].lives, startLives);
      expect(s.players[0].score, 0);
      expect(s.players[0].combo, 0);
      expect(s.balls[0].active, isFalse);
      expect(s.balls[0].x, 0);
      expect(s.balls[0].y, 0);
      expect(s.balls[0].owner, -1);
      expect(s.walls, isEmpty);
      expect(s.pickups, isEmpty);
      expect(s.nextId, 1);
      expect(s.winner, -1);
      expect(s.nextWallIn, inRange(7 * tickRate, 9 * tickRate));
      expect(s.nextPickupIn, inRange(3 * tickRate, 5 * tickRate));
      expect(s.events, isEmpty);
      expect(s.elapsedSeconds, 0);
    });

    test('duel starts with two paddles at 3pi/2 and pi/2', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.duel, seed: 9),
      );
      expect(s.players.length, 2);
      // The first serve is aimed at a randomly drawn player, carried in
      // `ball.owner` until the serve consumes it.
      expect(s.balls[0].owner, inRange(0, 1));
      expect(s.balls[0].vx, 0);
      expect(s.balls[0].vy, 0);
      expect(s.players[0].paddle.angle, bottomCenterAngle);
      expect(s.players[1].paddle.angle, topCenterAngle);
      expect(s.config.playerCount, 2);
      expect(s.config.maxSpeed, maxSpeedDuel);
    });

    test('is a pure function of the seed', () {
      final a = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 5),
      );
      final b = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 5),
      );
      final c = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 6),
      );
      expect(a.hash(), b.hash());
      expect(a.hash(), isNot(c.hash()));
    });
  });

  group('GameState.hash', () {
    test('is stable and sensitive to every hashed field', () {
      final s = playingState();
      final h = s.hash();
      expect(s.hash(), h);
      final c = s.clone();
      expect(c.hash(), h);
      c.tick += 1;
      expect(c.hash(), isNot(h));
      final c2 = s.clone()..players[0].score += 1;
      expect(c2.hash(), isNot(h));
      final c3 = s.clone()..balls[0].x += 1e-5;
      expect(c3.hash(), isNot(h));
      final c4 = s.clone()..balls[0].x += 1e-8; // below quantization
      expect(c4.hash(), h);
      final c5 = s.clone()..winner = 0;
      expect(c5.hash(), isNot(h));
      final c6 = s.clone()..rng.nextUint32();
      expect(c6.hash(), isNot(h));
      final c7 = s.clone()
        ..walls.add(
          Wall.segment(id: 1, x1: 0, y1: 0, x2: 0.3, y2: 0, ttl: 600),
        );
      expect(c7.hash(), isNot(h));
      final c8 = s.clone()
        ..pickups.add(Pickup(id: 1, type: PickupType.star, x: 0.1, y: 0.1));
      expect(c8.hash(), isNot(h));
      expect(h, greaterThanOrEqualTo(0));
      expect(h, lessThan(0x100000000));
    });

    test('handles negative values deterministically', () {
      final s = playingState();
      s.balls[0].x = -0.5;
      s.balls[0].vx = -0.25;
      s.balls[0].owner = -1;
      s.winner = -1;
      expect(s.hash(), s.clone().hash());
    });
  });

  group('GameState.clone', () {
    test('is a deep copy', () {
      final s = playingState();
      s.walls.add(Wall.segment(id: 1, x1: 0, y1: 0, x2: 0.3, y2: 0, ttl: 600));
      s.pickups.add(Pickup(id: 2, type: PickupType.heart, x: 0.1, y: 0.1));
      s.events.add(const GameEvent(GameEventType.serve));
      final c = s.clone();
      expect(c.hash(), s.hash());
      expect(c.events.length, 1);
      c.players[0].paddle.angle += 1;
      c.balls[0].x += 1;
      c.walls[0].age += 5;
      c.pickups[0].ttl -= 5;
      c.rng.nextUint32();
      c.walls.removeAt(0);
      expect(s.players[0].paddle.angle, bottomCenterAngle);
      expect(s.balls[0].x, 0);
      expect(s.walls.length, 1);
      expect(s.walls[0].age, 0);
      expect(s.pickups[0].ttl, pickupLifetime);
      expect(s.rng.toJson(), isNot(c.rng.toJson()));
    });
  });

  group('GameState JSON', () {
    test('uses the compact snapshot keys', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.duel, seed: 3),
      );
      final j = s.toJson();
      expect(j.keys.toSet(), {
        't',
        'ph',
        'st',
        'win',
        'b',
        'p',
        'w',
        'k',
        'nw',
        'np',
        'nid',
        'rng',
        'cfg',
      });
      expect(j['t'], 0);
      expect(j['ph'], Phase.serving.index);
      expect(j['st'], serveTicks);
      expect(j['win'], -1);
      // While serving, a duel state keeps the receiving player in `owner`
      // (see Ball.owner); seed 3 draws player 1 for the first serve.
      expect(s.balls[0].owner, 1);
      expect(j['b'], [
        [0.0, 0.0, 0.0, 0.0, baseSpeed, 1, 0],
      ]);
      expect(j['p'], [
        [bottomCenterAngle, 3, 0, 0],
        [topCenterAngle, 3, 0, 0],
      ]);
      expect(j['w'], isEmpty);
      expect(j['k'], isEmpty);
      expect(j['nid'], 1);
      expect(j['rng'], s.rng.toJson());
      expect(j['cfg'], {'m': GameMode.duel.index, 's': 3, 'n': 1});
    });

    test('round-trip through jsonEncode/jsonDecode preserves the hash', () {
      // Play long enough to have walls and pickups on the board.
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 11),
      );
      final inputs = <PlayerInput>[PlayerInput.none];
      for (var i = 0; i < 1500; i++) {
        inputs[0] = ScriptedInput.aimAtBall(s, 0);
        Simulation.step(s, inputs);
      }
      expect(s.walls, isNotEmpty);
      expect(s.pickups.length + s.players[0].score, greaterThan(0));
      final text = jsonEncode(s.toJson());
      final back = GameState.fromJson(jsonDecode(text) as Map<String, dynamic>);
      expect(back.hash(), s.hash());
      expect(back.toJson(), s.toJson());
      expect(back.events, isEmpty);
      // Both copies keep evolving identically.
      for (var i = 0; i < 600; i++) {
        inputs[0] = ScriptedInput.aimAtBall(s, 0);
        Simulation.step(s, inputs);
        Simulation.step(back, inputs);
        expect(back.hash(), s.hash());
      }
    });

    test('accepts whole doubles encoded as ints', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 1),
      );
      final j = s.toJson();
      j['b'] = [
        [0, 0, 0, 0, 1, -1, 0],
      ];
      j['p'] = [
        [4, 3, 0, 0],
      ];
      j['w'] = [
        [1, WallShape.straight.index, 0, 600, 0, 0, 1, 0],
      ];
      j['k'] = [
        [2, 1, 0, 0, 480],
      ];
      final back = GameState.fromJson(
        jsonDecode(jsonEncode(j)) as Map<String, dynamic>,
      );
      expect(back.balls[0].speed, 1.0);
      expect(back.players[0].paddle.angle, 4.0);
      expect(back.walls[0].pointX(1), 1.0);
      expect(back.pickups[0].type, PickupType.star);
      expect(back.hash(), back.clone().hash());
    });
  });

  group('entities', () {
    test('GameConfig JSON and equality', () {
      const c = GameConfig(mode: GameMode.duel, seed: 123456);
      expect(GameConfig.fromJson(c.toJson()), c);
      expect(c.playerCount, 2);
      expect(const GameConfig(mode: GameMode.solo, seed: 1).playerCount, 1);
    });

    test('Player.multiplier is 1 + combo ~/ 5 capped at 8', () {
      final p = Player(paddle: Paddle(0));
      expect(p.multiplier, 1);
      p.combo = 4;
      expect(p.multiplier, 1);
      p.combo = 5;
      expect(p.multiplier, 2);
      p.combo = 34;
      expect(p.multiplier, 7);
      p.combo = 35;
      expect(p.multiplier, 8);
      p.combo = 1000;
      expect(p.multiplier, 8);
    });

    test('Wall.solid and Wall.alpha follow the fade windows', () {
      final w = Wall.segment(id: 1, x1: 0, y1: 0, x2: 0.3, y2: 0, ttl: 600);
      expect(w.solid, isFalse);
      expect(w.alpha, 0);
      w.age = wallFadeTicks - 1;
      expect(w.solid, isFalse);
      expect(w.alpha, closeTo((wallFadeTicks - 1) / wallFadeTicks, 1e-12));
      w.age = wallFadeTicks;
      expect(w.solid, isTrue);
      expect(w.alpha, 1);
      w.age = 600 - wallFadeTicks - 1;
      expect(w.solid, isTrue);
      expect(w.alpha, 1);
      w.age = 600 - wallFadeTicks;
      expect(w.solid, isFalse);
      // The fade-out mirrors the fade-in, so the first transparent tick is also
      // the first tick that is not fully opaque: what looks solid is solid.
      expect(w.alpha, closeTo((wallFadeTicks - 1) / wallFadeTicks, 1e-12));
      w.age = 598;
      expect(w.alpha, closeTo(1 / wallFadeTicks, 1e-12));
      w.age = 599;
      expect(w.alpha, 0);
      w.age = 600;
      expect(w.alpha, 0);
    });

    test('Wall.alpha is 1 exactly while Wall.solid', () {
      for (final ttl in [wallMinLifetime, 600, wallMaxLifetime]) {
        final w = Wall.segment(id: 1, x1: 0, y1: 0, x2: 0.3, y2: 0, ttl: ttl);
        for (var age = 0; age <= ttl; age++) {
          w.age = age;
          expect(w.alpha == 1.0, w.solid, reason: 'ttl $ttl age $age');
          expect(w.alpha, inRange(0, 1));
        }
      }
    });

    test('GameEvent JSON round-trip', () {
      const e = GameEvent(
        GameEventType.pickup,
        player: 1,
        x: 0.25,
        y: -0.5,
        pickup: PickupType.heart,
      );
      final back = GameEvent.fromJson(
        jsonDecode(jsonEncode(e.toJson())) as List<dynamic>,
      );
      expect(back.type, e.type);
      expect(back.player, 1);
      expect(back.x, 0.25);
      expect(back.y, -0.5);
      expect(back.pickup, PickupType.heart);
      final none = GameEvent.fromJson(
        const GameEvent(GameEventType.serve).toJson(),
      );
      expect(none.pickup, isNull);
      expect(none.player, -1);
    });
  });
}
