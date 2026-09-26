// Two balls: the rules the one-ball game never had to answer (SPEC §2.3).
//
// `GameConfig.ballCount` puts 1 or 2 balls in play. One ball is the classic game
// and must behave exactly as it always did — that is what golden_hash_test.dart
// pins — so everything here is about what a second ball adds, and every answer
// below is a rule the app and the server have to agree on:
//
//  * **The serve.** One direction is drawn and the balls are fanned
//    symmetrically around it by `serveFan` per gap. All of them leave the origin
//    on the same tick at the same speed, and one `serve` event covers the rally.
//    A two-ball serve therefore costs exactly the randomness a one-ball serve
//    costs, and with one ball the fan offset is 0 — the serve is unchanged.
//  * **An escape while the other ball is live.** The first ball to leave the
//    arena costs one life and ends the rally for every ball: they are all
//    recalled to the origin and the next serve launches them together. Two balls
//    can never cost two lives in one tick, and a two-ball game never degrades
//    into a one-ball game halfway through a life.
//  * **Resolution order.** Ball 0 moves and collides first, then ball 1. That is
//    what decides a contested pickup and which escape ends the rally.
//  * **One paddle, two balls, one tick.** Each ball is resolved on its own, so a
//    paddle can bounce both in the same tick — a paddle the second ball would
//    pass through is not a paddle. Each ball still bounces at most once per tick
//    and off at most one paddle.
//  * **Pickup ownership.** A pickup belongs to the ball that reaches it and is
//    credited to *that* ball's owner (solo: always player 0; duel: the last
//    paddle to hit that ball, and nobody if it has not been hit). It is removed
//    on first contact, so it can never pay twice.
//  * **Combo and multiplier.** Both are per player, never per ball. Two hits in
//    one tick raise the same combo twice and each is scored with the multiplier
//    as it stands after its own increment. A life loss resets the combo however
//    many balls contributed to it.
import 'dart:convert';
import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Angle of ball [i]'s velocity.
double velocityAngle(GameState s, int i) =>
    math.atan2(s.balls[i].vy, s.balls[i].vx);

/// Runs [s] until the serve fires, returning the serve event.
GameEvent stepToServe(GameState s) {
  final inputs = noneInputs(s);
  for (var i = 0; i < serveTicks + 2; i++) {
    Simulation.step(s, inputs);
    final serve = s.events.where((e) => e.type == GameEventType.serve);
    if (serve.isNotEmpty) return serve.single;
  }
  fail('the serve never fired');
}

/// An angle [away] radians from player [p]'s paddle center — outside the paddle,
/// so a ball there is not saved before the escape check runs.
double awayFromPaddle(int p, double away) =>
    (p == 0 ? bottomCenterAngle : topCenterAngle) + away;

/// A playing two-ball state whose paddles cannot reach either ball.
GameState twoBallState({GameMode mode = GameMode.solo, int seed = 1}) =>
    playingState(mode: mode, seed: seed, ballCount: 2);

void main() {
  group('ball count', () {
    test('defaults to one and is bounded by the supported range', () {
      expect(minBallCount, 1);
      expect(maxBallCount, 2);
      const one = GameConfig(mode: GameMode.solo, seed: 1);
      expect(one.ballCount, minBallCount);
      expect(one.toJson(), {'m': 0, 's': 1, 'n': 1});
      const two = GameConfig(mode: GameMode.solo, seed: 1, ballCount: 2);
      expect(two.toJson(), {'m': 0, 's': 1, 'n': 2});
      expect(two, isNot(one), reason: 'the ball count is part of the identity');
      expect(two.hashCode, isNot(one.hashCode));
    });

    test('GameState.initial builds exactly that many balls, all parked', () {
      for (var n = minBallCount; n <= maxBallCount; n++) {
        for (final mode in GameMode.values) {
          final s = GameState.initial(
            GameConfig(mode: mode, seed: 3, ballCount: n),
          );
          expect(s.balls.length, n);
          for (final b in s.balls) {
            expect(b.active, isFalse);
            expect(b.x, 0);
            expect(b.y, 0);
            expect(b.vx, 0);
            expect(b.vy, 0);
            expect(b.speed, baseSpeed);
          }
          // While serving in a duel every ball carries the receiver.
          expect(
            s.balls.map((b) => b.owner).toSet().length,
            1,
            reason: 'every ball waits on the same serve',
          );
        }
      }
    });

    test('the second ball costs no randomness at all', () {
      // The rng is the shared clock of client and server; a ball count that
      // moved it would make the two ball counts two different simulations even
      // before the first tick. Both draw exactly the same values in initial(),
      // in the serve, and for every spawn interval.
      for (final mode in GameMode.values) {
        final one = GameState.initial(GameConfig(mode: mode, seed: 77));
        final two = GameState.initial(
          GameConfig(mode: mode, seed: 77, ballCount: 2),
        );
        expect(two.rng.toJson(), one.rng.toJson());
        expect(two.nextWallIn, one.nextWallIn);
        expect(two.nextPickupIn, one.nextPickupIn);
        expect(two.balls[0].owner, one.balls[0].owner);
        // And through the serve, which is where the fan is applied.
        stepToServe(one);
        stepToServe(two);
        expect(two.rng.toJson(), one.rng.toJson());
      }
    });
  });

  group('the serve', () {
    test('fans both balls symmetrically around the one drawn direction', () {
      for (final mode in GameMode.values) {
        final one = GameState.initial(GameConfig(mode: mode, seed: 5));
        final two = GameState.initial(
          GameConfig(mode: mode, seed: 5, ballCount: 2),
        );
        final drawn = stepToServe(one);
        final serve = stepToServe(two);
        final centre = velocityAngle(one, 0);
        final a0 = velocityAngle(two, 0);
        final a1 = velocityAngle(two, 1);
        // The drawn direction is the bisector, and the gap is serveFan.
        expect(DetMath.angleDiff(a1, a0), closeTo(serveFan, 1e-12));
        expect(DetMath.angleDiff(centre, a0), closeTo(serveFan / 2, 1e-12));
        expect(DetMath.angleDiff(a1, centre), closeTo(serveFan / 2, 1e-12));
        // Same tick, same speed, both live, neither owned.
        expect(two.tick, one.tick);
        expect(two.balls[0].speed, one.balls[0].speed);
        expect(two.balls[1].speed, one.balls[0].speed);
        for (final b in two.balls) {
          expect(b.active, isTrue);
          expect(b.owner, -1);
          expect(b.x, 0);
          expect(b.y, 0);
          expect(math.sqrt(b.vx * b.vx + b.vy * b.vy), closeTo(b.speed, 1e-12));
        }
        // One event for the whole rally, belonging to no single ball.
        expect(
          two.events.where((e) => e.type == GameEventType.serve).length,
          1,
        );
        expect(serve.ball, -1);
        expect(serve.player, drawn.player);
      }
    });

    test('a one-ball serve has no fan offset at all', () {
      // The `n == 1` branch is what keeps the classic serve bit-identical: the
      // drawn angle is used as-is, with no arithmetic in front of it. Reproduce
      // the draw from a fresh rng — GameState.initial takes the first wall and
      // pickup intervals and nothing else in solo — and the ball must be flying
      // along exactly that angle.
      final one = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 5),
      );
      stepToServe(one);
      final rng = Prng(5);
      rng.nextRange(7, 9);
      rng.nextRange(3, 5);
      final angle = rng.nextRange(0, DetMath.tau);
      expect(DetMath.normAngle(velocityAngle(one, 0)), closeTo(angle, 1e-12));
      expect(
        one.balls[0].vx,
        closeTo(DetMath.cos(angle) * one.balls[0].speed, 1e-15),
      );
      expect(
        one.balls[0].vy,
        closeTo(DetMath.sin(angle) * one.balls[0].speed, 1e-15),
      );
    });

    test('the fan is wider than the paddle, so both balls are a decision', () {
      // 0.7 rad between the balls against a paddle 0.68 rad wide: one paddle
      // cannot simply sit still and take both.
      expect(serveFan, greaterThan(2 * paddleHalfWidth));
      // But not so wide that one paddle cannot reach both in time: at
      // paddleSpeed the paddle crosses the fan in well under the serve pause.
      expect(serveFan / paddleSpeed, lessThan(serveTicks * dt));
    });

    test('a duel serve aims the whole fan into the receiver half', () {
      for (var receiver = 0; receiver < 2; receiver++) {
        final s = GameState.initial(
          const GameConfig(mode: GameMode.duel, seed: 8, ballCount: 2),
        );
        // prepareServe carries the receiver in ball.owner (SPEC §2.3).
        s.prepareServe(receiver);
        final serve = stepToServe(s);
        expect(serve.player, receiver);
        final centre = receiver == 0 ? bottomCenterAngle : topCenterAngle;
        for (var i = 0; i < 2; i++) {
          final off = DetMath.angleDiff(velocityAngle(s, i), centre).abs();
          expect(off, lessThanOrEqualTo(serveSpread + serveFan / 2 + 1e-12));
        }
      }
    });
  });

  group('each ball plays on its own', () {
    test('one paddle bounces both balls in the same tick', () {
      // A paddle the second ball would pass through is not a paddle.
      final s = twoBallState();
      final centre = s.players[0].paddle.angle;
      launchRadial(s, centre - 0.12, 0.6, paddleHitRadius - 0.005, index: 0);
      launchRadial(s, centre + 0.12, 0.6, paddleHitRadius - 0.005, index: 1);
      Simulation.step(s, noneInputs(s));
      final hits = s.events
          .where((e) => e.type == GameEventType.paddleHit)
          .toList();
      expect(hits.length, 2);
      expect(hits.map((e) => e.ball), [0, 1], reason: 'in index order');
      expect(hits.every((e) => e.player == 0), isTrue);
      // Both balls were turned inward and sped up.
      for (final b in s.balls) {
        expect(b.x * b.vx + b.y * b.vy, lessThan(0));
        expect(b.speed, closeTo(0.6 * hitSpeedFactor, 1e-12));
        expect(b.owner, 0);
      }
      // Both bounces scored, on one combo.
      expect(s.players[0].combo, 2);
      expect(s.players[0].score, 2 * paddleHitScore);
    });

    test('a ball still bounces at most once per tick', () {
      // The per-ball guard: a ball wedged against the paddle for several
      // substeps is reflected once, as it always was.
      final s = twoBallState();
      parkBall(s, 1);
      final centre = s.players[0].paddle.angle;
      launchRadial(s, centre, maxSpeedSolo, paddleHitRadius - 0.001);
      Simulation.step(s, noneInputs(s));
      expect(
        s.events.where((e) => e.type == GameEventType.paddleHit).length,
        1,
      );
    });

    test('in a duel each ball can be owned by a different player', () {
      final s = twoBallState(mode: GameMode.duel);
      launchRadial(
        s,
        bottomCenterAngle,
        0.6,
        paddleHitRadius - 0.005,
        index: 0,
      );
      launchRadial(s, topCenterAngle, 0.6, paddleHitRadius - 0.005, index: 1);
      Simulation.step(s, noneInputs(s));
      final hits = s.events
          .where((e) => e.type == GameEventType.paddleHit)
          .toList();
      expect(hits.length, 2);
      expect(hits[0].player, 0);
      expect(hits[1].player, 1);
      expect(s.balls[0].owner, 0);
      expect(s.balls[1].owner, 1);
      expect(s.players[0].combo, 1);
      expect(s.players[1].combo, 1);
    });

    test(
      'each ball bounces off walls on its own and is named in the event',
      () {
        final s = twoBallState();
        // One wall on each side of the origin; the balls fly apart into them.
        s.walls.add(
          shapedWall(
            shape: WallShape.bent,
            cx: 0.3,
            cy: 0,
            angle: 0,
            length: 0.4,
            parameter: 2.0,
            id: 1,
          ),
        );
        s.walls.add(
          shapedWall(
            shape: WallShape.curved,
            cx: -0.3,
            cy: 0,
            angle: DetMath.halfPi,
            length: 0.4,
            parameter: 2.0,
            id: 2,
          ),
        );
        s.balls[0].owner = 0;
        s.balls[1].owner = 0;
        launchBall(s, 0, 0, 0, 0.6, index: 0);
        launchBall(s, 0, 0, DetMath.pi, 0.6, index: 1);
        final hits = <GameEvent>[];
        for (var t = 0; t < 80; t++) {
          Simulation.step(s, noneInputs(s));
          hits.addAll(s.events.where((e) => e.type == GameEventType.wallHit));
          if (hits.map((e) => e.ball).toSet().length == 2) break;
        }
        expect(hits.map((e) => e.ball).toSet(), {0, 1});
        // Both bounces paid their owner.
        expect(s.players[0].score, greaterThanOrEqualTo(2 * wallHitScore));
      },
    );

    test('each ball is sub-stepped by its own speed', () {
      // A slow ball and a fast one in the same tick: neither borrows the
      // other's sub-stepping, so a fast ball cannot tunnel because a slow one
      // shares the tick.
      final s = twoBallState();
      s.walls.add(
        shapedWall(
          shape: WallShape.straight,
          cx: 0.3,
          cy: 0,
          angle: DetMath.halfPi,
          length: 0.4,
          id: 1,
        ),
      );
      launchBall(s, 0.1, 0, 0, maxSpeedSolo, index: 0);
      launchBall(s, -0.9, 0, 0, 0.05, index: 1);
      for (var t = 0; t < 120; t++) {
        Simulation.step(s, noneInputs(s));
        if (s.phase != Phase.playing) break;
        for (final b in s.balls) {
          expect(
            wallDistance(s.walls.first, b.x, b.y),
            greaterThanOrEqualTo(Simulation.wallCapsuleRadius - 1e-9),
          );
        }
      }
    });
  });

  group('escape', () {
    test('one ball escaping ends the rally for both', () {
      final s = twoBallState();
      // Ball 0 outside the arena away from the paddle; ball 1 mid-flight.
      final angle = awayFromPaddle(0, 1.2);
      launchRadial(s, angle, 0.6, escapeRadius + 0.02, index: 0);
      launchBall(s, 0.2, 0.1, 0.4, 0.8, index: 1);
      s.balls[1].owner = 0;
      Simulation.step(s, noneInputs(s));
      final lost = s.events
          .where((e) => e.type == GameEventType.lifeLost)
          .toList();
      expect(lost.length, 1, reason: 'one escape, one life');
      expect(lost.single.ball, 0);
      expect(lost.single.player, 0);
      expect(s.players[0].lives, startLives - 1);
      expect(s.phase, Phase.serving);
      expect(s.serveTimer, serveTicks);
      // Every ball is recalled, not just the one that escaped.
      for (final b in s.balls) {
        expect(b.active, isFalse);
        expect(b.x, 0);
        expect(b.y, 0);
        expect(b.vx, 0);
        expect(b.vy, 0);
        expect(b.speed, baseSpeed);
        expect(b.owner, -1);
      }
    });

    test('the next serve brings both balls back', () {
      final s = twoBallState();
      launchRadial(s, awayFromPaddle(0, 1.2), 0.6, escapeRadius + 0.02);
      Simulation.step(s, noneInputs(s));
      expect(s.phase, Phase.serving);
      stepToServe(s);
      expect(s.phase, Phase.playing);
      expect(s.balls.length, 2);
      expect(s.balls.every((b) => b.active), isTrue);
      expect(
        DetMath.angleDiff(velocityAngle(s, 1), velocityAngle(s, 0)),
        closeTo(serveFan, 1e-12),
      );
    });

    test('two balls outside the arena in one tick still cost one life', () {
      for (final mode in GameMode.values) {
        final s = twoBallState(mode: mode);
        // Both past the escape radius, both clear of every paddle.
        launchRadial(
          s,
          awayFromPaddle(0, 0.9),
          0.6,
          escapeRadius + 0.02,
          index: 0,
        );
        launchRadial(
          s,
          awayFromPaddle(1, 0.9),
          0.6,
          escapeRadius + 0.02,
          index: 1,
        );
        Simulation.step(s, noneInputs(s));
        expect(
          s.events.where((e) => e.type == GameEventType.lifeLost).length,
          1,
          reason: '$mode lost more than one life in a tick',
        );
        final lives = s.players.map((p) => p.lives).toList();
        expect(
          lives.reduce((a, b) => a + b),
          s.players.length * startLives - 1,
          reason: '$mode',
        );
        // Ball 0 is resolved first, so ball 0's escape is the one that counts.
        expect(s.events.first.ball, 0);
      }
    });

    test('the escaping ball decides which duel half pays', () {
      // Ball 1 is in the top half and ball 0, the one that escapes, in the
      // bottom: the bottom player pays, whatever the other ball is doing.
      final s = twoBallState(mode: GameMode.duel);
      launchRadial(
        s,
        awayFromPaddle(0, 0.9),
        0.6,
        escapeRadius + 0.02,
        index: 0,
      );
      launchBall(s, 0.1, 0.5, 1.0, 0.8, index: 1);
      Simulation.step(s, noneInputs(s));
      final lost = s.events.single;
      expect(lost.type, GameEventType.lifeLost);
      expect(lost.player, 0);
      expect(s.players[0].lives, startLives - 1);
      expect(s.players[1].lives, startLives);
      // And the serve goes back to the player who lost the point.
      expect(s.balls.every((b) => b.owner == 0), isTrue);
      final serve = stepToServe(s);
      expect(serve.player, 0);
    });

    test('the last life ends the game and freezes every ball', () {
      for (final mode in GameMode.values) {
        final s = twoBallState(mode: mode);
        s.players[0].lives = 1;
        launchRadial(
          s,
          awayFromPaddle(0, 0.9),
          0.6,
          escapeRadius + 0.02,
          index: 0,
        );
        launchBall(s, 0.2, -0.1, 2.0, 0.9, index: 1);
        Simulation.step(s, noneInputs(s));
        expect(s.phase, Phase.gameOver);
        expect(s.winner, mode == GameMode.duel ? 1 : -1);
        expect(
          s.events.map((e) => e.type),
          containsAllInOrder([GameEventType.lifeLost, GameEventType.gameOver]),
        );
        for (final b in s.balls) {
          expect(b.active, isFalse);
          expect(b.x, 0);
          expect(b.y, 0);
          expect(b.vx, 0);
          expect(b.vy, 0);
          expect(b.speed, 0);
          expect(b.owner, -1);
        }
        // A finished game does not move again.
        final frozen = s.hash();
        Simulation.step(s, noneInputs(s));
        expect(s.hash(), frozen);
        expect(s.events, isEmpty);
      }
    });
  });

  group('pickups', () {
    test('a contested pickup goes to ball 0 and pays exactly once', () {
      final s = twoBallState(mode: GameMode.duel);
      s.pickups.add(Pickup(id: 7, type: PickupType.star, x: 0.3, y: 0));
      s.balls[0].owner = 1;
      s.balls[1].owner = 0;
      launchBall(s, 0.3 - 0.02, 0, 0, 0.6, index: 0);
      launchBall(s, 0.3 + 0.02, 0, DetMath.pi, 0.6, index: 1);
      Simulation.step(s, noneInputs(s));
      final taken = s.events
          .where((e) => e.type == GameEventType.pickup)
          .toList();
      expect(taken.length, 1, reason: 'a pickup can never pay twice');
      expect(taken.single.ball, 0);
      expect(taken.single.player, 1, reason: "ball 0's owner");
      expect(s.pickups, isEmpty);
      expect(s.players[1].score, starScore);
      expect(s.players[0].score, 0);
    });

    test('each ball collects for its own owner', () {
      final s = twoBallState(mode: GameMode.duel);
      s.pickups.add(Pickup(id: 1, type: PickupType.star, x: 0.3, y: 0));
      s.pickups.add(Pickup(id: 2, type: PickupType.star, x: -0.3, y: 0));
      s.balls[0].owner = 0;
      s.balls[1].owner = 1;
      launchBall(s, 0.3 - 0.02, 0, 0, 0.6, index: 0);
      launchBall(s, -0.3 + 0.02, 0, DetMath.pi, 0.6, index: 1);
      Simulation.step(s, noneInputs(s));
      final taken = s.events
          .where((e) => e.type == GameEventType.pickup)
          .toList();
      expect(taken.length, 2);
      expect(taken.map((e) => e.ball), [0, 1]);
      expect(taken.map((e) => e.player), [0, 1]);
      expect(s.players[0].score, starScore);
      expect(s.players[1].score, starScore);
      expect(s.pickups, isEmpty);
    });

    test('a duel pickup taken by an unowned ball credits nobody', () {
      // Even when the *other* ball has an owner: ownership follows the ball
      // that reached the pickup, not the rally.
      final s = twoBallState(mode: GameMode.duel);
      s.pickups.add(Pickup(id: 1, type: PickupType.star, x: 0.3, y: 0));
      s.balls[0].owner = -1;
      s.balls[1].owner = 1;
      launchBall(s, 0.3 - 0.02, 0, 0, 0.6, index: 0);
      parkBall(s, 1);
      Simulation.step(s, noneInputs(s));
      final taken = s.events.single;
      expect(taken.type, GameEventType.pickup);
      expect(taken.ball, 0);
      expect(taken.player, -1);
      expect(s.pickups, isEmpty);
      expect(s.players.every((p) => p.score == 0), isTrue);
    });

    test('solo credits player 0 whichever ball collects', () {
      final s = twoBallState();
      s.pickups.add(Pickup(id: 1, type: PickupType.heart, x: -0.3, y: 0));
      s.players[0].lives = 2;
      parkBall(s, 0);
      launchBall(s, -0.3 + 0.02, 0, DetMath.pi, 0.6, index: 1);
      Simulation.step(s, noneInputs(s));
      final taken = s.events.single;
      expect(taken.ball, 1);
      expect(taken.player, 0);
      expect(s.players[0].lives, 3);
    });

    test('a spawning pickup keeps clear of every ball', () {
      final s = twoBallState();
      launchBall(s, 0.2, 0.1, 0.3, 0.7, index: 0);
      launchBall(s, -0.25, 0.2, 2.6, 0.7, index: 1);
      var spawned = 0;
      for (var round = 0; round < 400; round++) {
        s.pickups.clear();
        s.nextPickupIn = 1;
        Simulation.step(s, noneInputs(s));
        for (final k in s.pickups) {
          spawned++;
          for (var i = 0; i < s.balls.length; i++) {
            expect(
              dist(k.x, k.y, s.balls[i].x, s.balls[i].y),
              greaterThanOrEqualTo(pickupMinDistFromBall - 1e-9),
              reason: 'pickup ${k.id} spawned on ball $i',
            );
          }
        }
      }
      expect(spawned, greaterThan(300));
    });

    test('a spawning wall keeps clear of every ball', () {
      final s = twoBallState();
      launchBall(s, 0.2, 0.1, 0.3, 0.7, index: 0);
      launchBall(s, -0.25, 0.2, 2.6, 0.7, index: 1);
      var spawned = 0;
      for (var round = 0; round < 400; round++) {
        s.walls.clear();
        s.nextWallIn = 1;
        Simulation.step(s, noneInputs(s));
        for (final w in s.walls) {
          spawned++;
          for (var i = 0; i < s.balls.length; i++) {
            expect(
              wallDistance(w, s.balls[i].x, s.balls[i].y),
              greaterThanOrEqualTo(wallMinDistFromBall - 1e-9),
              reason: 'wall ${w.id} spawned on ball $i',
            );
          }
        }
      }
      expect(spawned, greaterThan(300));
    });
  });

  group('combo and multiplier', () {
    test('two hits in one tick raise one combo twice, scored as they land', () {
      final s = twoBallState();
      // combo 8 -> multiplier 2; the hits take it to 9 and 10, and 10 is the
      // first combo worth multiplier 3.
      s.players[0].combo = 8;
      expect(s.players[0].multiplier, 2);
      final centre = s.players[0].paddle.angle;
      launchRadial(s, centre - 0.12, 0.6, paddleHitRadius - 0.005, index: 0);
      launchRadial(s, centre + 0.12, 0.6, paddleHitRadius - 0.005, index: 1);
      Simulation.step(s, noneInputs(s));
      expect(s.players[0].combo, 10);
      expect(s.players[0].multiplier, 3);
      // 9 -> multiplier 2, then 10 -> multiplier 3: the second hit is worth more
      // because the first one raised the combo.
      expect(s.players[0].score, paddleHitScore * 2 + paddleHitScore * 3);
    });

    test('a life lost clears the combo both balls built', () {
      final s = twoBallState();
      final centre = s.players[0].paddle.angle;
      launchRadial(s, centre - 0.12, 0.6, paddleHitRadius - 0.005, index: 0);
      launchRadial(s, centre + 0.12, 0.6, paddleHitRadius - 0.005, index: 1);
      Simulation.step(s, noneInputs(s));
      expect(s.players[0].combo, 2);
      launchRadial(s, awayFromPaddle(0, 1.2), 0.6, escapeRadius + 0.02);
      Simulation.step(s, noneInputs(s));
      expect(s.players[0].combo, 0);
    });

    test('a wall bounce uses the hitting ball owner multiplier', () {
      final s = twoBallState(mode: GameMode.duel);
      s.players[0].combo = 20; // multiplier 5
      s.players[1].combo = 0; // multiplier 1
      expect(s.players[0].multiplier, 5);
      expect(s.players[1].multiplier, 1);
      s.walls.add(
        shapedWall(
          shape: WallShape.straight,
          cx: 0.3,
          cy: 0,
          angle: DetMath.halfPi,
          length: 0.4,
          id: 1,
        ),
      );
      s.balls[0].owner = 1;
      parkBall(s, 1);
      launchBall(s, 0, 0, 0, 0.6, index: 0);
      expect(stepUntil(s, GameEventType.wallHit, maxTicks: 60), greaterThan(0));
      // Ball 0 belongs to player 1, so player 1 is paid at player 1's
      // multiplier — the other player's larger combo is irrelevant.
      expect(s.players[1].score, wallHitScore * 1);
      expect(s.players[0].score, 0);
    });

    test('a star pays the collecting ball owner multiplier', () {
      final s = twoBallState(mode: GameMode.duel);
      s.players[1].combo = 20; // multiplier 5
      s.pickups.add(Pickup(id: 1, type: PickupType.star, x: 0.3, y: 0));
      s.balls[0].owner = 1;
      parkBall(s, 1);
      launchBall(s, 0.3 - 0.02, 0, 0, 0.6, index: 0);
      Simulation.step(s, noneInputs(s));
      expect(s.players[1].score, starScore * 5);
      expect(s.players[0].score, 0);
    });
  });

  group('serialization', () {
    test('a two-ball snapshot carries both balls in order', () {
      final s = twoBallState(mode: GameMode.duel, seed: 4);
      launchBall(s, 0.11, -0.22, 0.5, 0.7, index: 0);
      launchBall(s, -0.33, 0.44, 2.5, 0.9, index: 1);
      s.balls[1].owner = 1;
      s.walls.add(shapedWall(shape: WallShape.curved, parameter: 2.0, id: 3));
      final j = s.toJson();
      expect(j['cfg'], {'m': GameMode.duel.index, 's': 4, 'n': 2});
      expect((j['b'] as List).length, 2);
      expect(j['b'], [s.balls[0].toJson(), s.balls[1].toJson()]);
      final back = GameState.fromJson(
        jsonDecode(jsonEncode(j)) as Map<String, dynamic>,
      );
      expect(back.config.ballCount, 2);
      expect(back.balls.length, 2);
      expect(back.hash(), s.hash());
      expect(back.toJson(), s.toJson());
      expect(back.walls.single.shape, WallShape.curved);
      expect(back.walls.single.points, s.walls.single.points);
    });

    test('a two-ball snapshot decoded into a state continues identically', () {
      // This is exactly what a duel client does on every server snapshot.
      final direct = GameState.initial(
        const GameConfig(mode: GameMode.duel, seed: 21, ballCount: 2),
      );
      final inputs = List<PlayerInput>.filled(2, PlayerInput.none);
      for (var i = 0; i < 900; i++) {
        for (var p = 0; p < 2; p++) {
          inputs[p] = ScriptedInput.aimAtBall(direct, p);
        }
        Simulation.step(direct, inputs);
      }
      expect(direct.walls, isNotEmpty, reason: 'shaped walls are on the board');
      var relayed = GameState.fromJson(
        jsonDecode(jsonEncode(direct.toJson())) as Map<String, dynamic>,
      );
      expect(relayed.hash(), direct.hash());
      for (var block = 0; block < 12; block++) {
        for (var i = 0; i < snapshotInterval; i++) {
          for (var p = 0; p < 2; p++) {
            inputs[p] = ScriptedInput.aimAtBall(direct, p);
          }
          Simulation.step(direct, inputs);
          Simulation.step(relayed, inputs);
        }
        expect(relayed.hash(), direct.hash(), reason: 'block $block');
        relayed = GameState.fromJson(
          jsonDecode(jsonEncode(relayed.toJson())) as Map<String, dynamic>,
        );
        expect(relayed.hash(), direct.hash());
      }
    });

    test('the hash sees every ball', () {
      final s = twoBallState();
      final h = s.hash();
      final c = s.clone()..balls[1].x += 1e-5;
      expect(c.hash(), isNot(h), reason: 'ball 1 position is not hashed');
      final c2 = s.clone()..balls[1].owner = 0;
      expect(c2.hash(), isNot(h));
      final c3 = s.clone()..balls[1].active = !s.balls[1].active;
      expect(c3.hash(), isNot(h));
      // Swapping two balls is a different state: the order is part of the rules.
      final c4 = s.clone();
      launchBall(c4, 0.1, 0.2, 0.3, 0.6, index: 0);
      final swapped = c4.clone();
      launchBall(swapped, 0.1, 0.2, 0.3, 0.6, index: 1);
      launchBall(swapped, 0, 0, 0, baseSpeed, index: 0);
      expect(swapped.hash(), isNot(c4.hash()));
    });

    test('GameConfig.fromJson rejects a ball count it cannot honour', () {
      for (final n in [0, -1, maxBallCount + 1, 99]) {
        expect(
          () => GameConfig.fromJson({'m': 0, 's': 1, 'n': n}),
          throwsA(isA<FormatException>()),
          reason: 'ballCount $n must be refused',
        );
      }
      // A snapshot written before ball counts existed means one ball.
      expect(GameConfig.fromJson({'m': 0, 's': 1}).ballCount, minBallCount);
      // And an unknown mode is refused the same way.
      expect(
        () => GameConfig.fromJson({'m': 7, 's': 1, 'n': 1}),
        throwsA(isA<FormatException>()),
      );
    });

    test('GameState.fromJson rejects a ball list the config disowns', () {
      final two = twoBallState();
      final j = two.toJson();
      // Two balls, config says one.
      final tooMany = Map<String, dynamic>.of(j)
        ..['cfg'] = {'m': 0, 's': 1, 'n': 1};
      expect(
        () => GameState.fromJson(tooMany),
        throwsA(isA<FormatException>()),
      );
      // One ball, config says two.
      final tooFew = Map<String, dynamic>.of(j)
        ..['b'] = [two.balls[0].toJson()];
      expect(() => GameState.fromJson(tooFew), throwsA(isA<FormatException>()));
      // And a ball count outside the range is refused before the count check.
      final unsupported = Map<String, dynamic>.of(j)
        ..['cfg'] = {'m': 0, 's': 1, 'n': 3};
      expect(
        () => GameState.fromJson(unsupported),
        throwsA(isA<FormatException>()),
      );
    });

    test('a replay carries the ball count and verifies against it', () {
      // The server has to re-simulate the game that was played, so the ball
      // count travels in the config and therefore in the replay.
      const config = GameConfig(mode: GameMode.solo, seed: 31, ballCount: 2);
      final s = GameState.initial(config);
      final log = InputLog();
      final inputs = <PlayerInput>[PlayerInput.none];
      final shapesPlayed = <WallShape>{};
      var lastWallId = 0;
      while (s.phase != Phase.gameOver && s.tick < 20000) {
        final input = s.tick < 1200
            ? ScriptedInput.aimAtBall(s, 0)
            : ScriptedInput.avoidBall(s, 0);
        log.record(s.tick, input);
        inputs[0] = input;
        Simulation.step(s, inputs);
        for (final w in s.walls) {
          if (w.id <= lastWallId) continue;
          lastWallId = w.id;
          shapesPlayed.add(w.shape);
        }
      }
      expect(s.phase, Phase.gameOver);
      // The claim below is only worth anything if the recorded game really had
      // shaped walls in it: a verifier that agrees about a board of straight
      // segments proves nothing about polylines.
      expect(
        shapesPlayed.where((sh) => sh != WallShape.straight),
        isNotEmpty,
        reason: 'the recorded game never spawned a shaped wall',
      );
      final replay = Replay(
        config: config,
        inputs: [log],
        finalTick: s.tick,
        claimedScore: s.players[0].score,
      );
      final back = Replay.decode(replay.encode());
      expect(back.config.ballCount, 2);
      expect(back.config, config);
      final result = ReplayVerifier.verify(back);
      expect(result.ok, isTrue, reason: result.toString());
      expect(result.hash, s.hash());
      expect(result.score, s.players[0].score);
      expect(result.ticks, s.tick);
      // The same replay claiming one ball is a different game and must fail.
      final lied = Replay(
        config: const GameConfig(mode: GameMode.solo, seed: 31),
        inputs: [log],
        finalTick: replay.finalTick,
        claimedScore: replay.claimedScore,
      );
      final lie = ReplayVerifier.verify(lied);
      expect(lie.ok, isFalse);
      expect(lie.hash, isNot(result.hash));
    });

    test('the verifier refuses a ball count this build cannot run', () {
      // A config built in process can hold anything; the decoder catches the
      // rest. Either way nothing is simulated.
      final bad = Replay(
        config: _UnsupportedConfig(maxBallCount + 1),
        inputs: [InputLog()],
        finalTick: 100,
        claimedScore: 0,
      );
      final result = ReplayVerifier.verify(bad);
      expect(result.ok, isFalse);
      expect(result.reason, 'bad_config');
      expect(result.ticks, 0, reason: 'refused before simulating');
    });
  });

  group('determinism', () {
    for (final mode in GameMode.values) {
      test('a long two-ball $mode game is reproducible', () {
        const ticks = 6000;
        List<int> run(GameState s, {int from = 0}) {
          final jitter = Prng(0xB0A1 + from);
          final inputs = List<PlayerInput>.filled(
            s.players.length,
            PlayerInput.none,
          );
          final hashes = <int>[];
          for (var i = 1; i <= ticks - from; i++) {
            for (var p = 0; p < inputs.length; p++) {
              final wanted = ScriptedInput.aimAtBall(s, p);
              inputs[p] = wanted.hasAim
                  ? PlayerInput.aimAngle(
                      wanted.targetAngle + jitter.nextRange(-0.12, 0.12),
                    )
                  : wanted;
            }
            Simulation.step(s, inputs);
            if (i % 500 == 0) hashes.add(s.hash());
          }
          return hashes;
        }

        final config = GameConfig(mode: mode, seed: 1234, ballCount: 2);
        final a = run(GameState.initial(config));
        final b = run(GameState.initial(config));
        expect(b, a);
        expect(a.toSet().length, greaterThan(1), reason: 'not a static run');
        // A different ball count is a different game.
        final one = run(GameState.initial(GameConfig(mode: mode, seed: 1234)));
        expect(one, isNot(a));
      });
    }

    test('a two-ball game mid-flight survives clone and JSON', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.duel, seed: 99, ballCount: 2),
      );
      final inputs = List<PlayerInput>.filled(2, PlayerInput.none);
      void advance(GameState g, int ticks) {
        for (var i = 0; i < ticks; i++) {
          for (var p = 0; p < 2; p++) {
            inputs[p] = ScriptedInput.aimAtBall(g, p);
          }
          Simulation.step(g, inputs);
        }
      }

      advance(s, 2500);
      expect(s.walls, isNotEmpty);
      final cloned = s.clone();
      final decoded = GameState.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(cloned.hash(), s.hash());
      expect(decoded.hash(), s.hash());
      for (var i = 0; i < 2500; i++) {
        for (var p = 0; p < 2; p++) {
          inputs[p] = ScriptedInput.aimAtBall(s, p);
        }
        Simulation.step(s, inputs);
        Simulation.step(cloned, inputs);
        Simulation.step(decoded, inputs);
        expect(cloned.hash(), s.hash(), reason: 'clone diverged at tick $i');
        expect(decoded.hash(), s.hash(), reason: 'json diverged at tick $i');
      }
    });
  });
}

/// A config whose ball count the simulation cannot run, to reach the verifier's
/// `bad_config` branch without going through the decoder (which refuses it
/// first). The assert in [GameConfig] only fires in debug mode, so the verifier
/// keeps its own check.
class _UnsupportedConfig implements GameConfig {
  _UnsupportedConfig(this.ballCount);

  @override
  final int ballCount;

  @override
  GameMode get mode => GameMode.solo;

  @override
  int get seed => 1;

  @override
  int get playerCount => 1;

  @override
  double get maxSpeed => maxSpeedSolo;

  @override
  Map<String, dynamic> toJson() => {'m': 0, 's': 1, 'n': ballCount};
}
