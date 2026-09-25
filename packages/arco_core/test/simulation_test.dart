// Rule-by-rule tests of the deterministic step function (SPEC §2.3, §2.6).
import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Radius the ball is pulled back to after a paddle bounce.
const double contact = Simulation.paddleContactRadius;

/// Widest angular offset that still counts as a paddle hit.
const double maxHitOffset = paddleHalfWidth + Simulation.paddleAngularSlack;

/// Inward unit normal at the ball's position.
(double, double) inwardNormal(GameState s) {
  final r = ballDistance(s);
  return (-s.ball.x / r, -s.ball.y / r);
}

/// dot(ball direction, inward normal) — 1 when the ball flies straight back
/// to the center, negative when it flies outward.
double inwardDot(GameState s) {
  final (nx, ny) = inwardNormal(s);
  final speed = s.ball.speed;
  return (s.ball.vx * nx + s.ball.vy * ny) / speed;
}

/// Bounces the ball off the solo paddle after hitting it [offset] radians from
/// its center, with a radial approach unless [approachAngle] is given.
GameState bounceOffPaddle({
  double offset = 0,
  double speed = 0.6,
  int combo = 0,
  double? approachAngle,
  double radius = contact - 0.004,
}) {
  final s = playingState();
  s.players[0].paddle.angle = bottomCenterAngle;
  s.players[0].combo = combo;
  final hitAngle = bottomCenterAngle + offset;
  if (approachAngle == null) {
    launchRadial(s, hitAngle, speed, radius);
  } else {
    launchBall(
      s,
      math.cos(hitAngle) * radius,
      math.sin(hitAngle) * radius,
      approachAngle,
      speed,
    );
  }
  Simulation.step(s, noneInputs(s));
  return s;
}

void main() {
  group('paddle bounce', () {
    test('reflects the ball inward and speeds it up by hitSpeedFactor', () {
      final s = bounceOffPaddle();
      expect(s.events.map((e) => e.type), contains(GameEventType.paddleHit));
      final hit = s.events.firstWhere((e) => e.type == GameEventType.paddleHit);
      expect(hit.player, 0);
      expect(s.ball.speed, closeTo(0.6 * hitSpeedFactor, 1e-12));
      expect(s.ball.vy, greaterThan(0)); // paddle sits at the bottom
      expect(inwardDot(s), closeTo(1, 1e-6));
      expect(ballDistance(s), closeTo(contact, 1e-9));
      expect(s.ball.owner, 0);
      expect(s.players[0].combo, 1);
      expect(s.players[0].score, paddleHitScore);
      // The velocity vector stays consistent with `speed`.
      expect(
        math.sqrt(s.ball.vx * s.ball.vx + s.ball.vy * s.ball.vy),
        closeTo(s.ball.speed, 1e-12),
      );
    });

    test('caps the speed at maxSpeed (solo 1.6, duel 1.5)', () {
      final solo = bounceOffPaddle(speed: maxSpeedSolo);
      expect(solo.ball.speed, maxSpeedSolo);

      final duel = playingState(mode: GameMode.duel);
      duel.players[0].paddle.angle = bottomCenterAngle;
      launchRadial(duel, bottomCenterAngle, maxSpeedDuel, contact - 0.004);
      Simulation.step(duel, noneInputs(duel));
      expect(duel.events.map((e) => e.type), contains(GameEventType.paddleHit));
      expect(duel.ball.speed, maxSpeedDuel);
    });

    test('applies english of -(offset / halfWidth) * 0.55 radians', () {
      for (final offset in [-0.3, -0.2, -0.05, 0.0, 0.05, 0.2, 0.3]) {
        final s = bounceOffPaddle(offset: offset);
        final hitAngle = bottomCenterAngle + offset;
        final outgoing = math.atan2(s.ball.vy, s.ball.vx);
        // A purely radial approach reflects onto the inward normal, so the
        // whole deviation from it is the english.
        final deviation = DetMath.angleDiff(outgoing, hitAngle + DetMath.pi);
        expect(
          deviation,
          closeTo(-(offset / paddleHalfWidth) * paddleEnglish, 1e-6),
          reason: 'offset $offset',
        );
      }
    });

    test('english pushes the ball away from the paddle center', () {
      // Counter-clockwise tangent at the impact point; a hit on the
      // counter-clockwise side must leave with a counter-clockwise component.
      for (final offset in [0.25, -0.25]) {
        final s = bounceOffPaddle(offset: offset);
        final hitAngle = bottomCenterAngle + offset;
        final tx = -math.sin(hitAngle);
        final ty = math.cos(hitAngle);
        final tangential = s.ball.vx * tx + s.ball.vy * ty;
        expect(tangential.sign, offset.sign, reason: 'offset $offset');
      }
    });

    test('hits inside the angular slack and misses outside it', () {
      final hit = bounceOffPaddle(offset: maxHitOffset - 0.001);
      expect(hit.events.map((e) => e.type), contains(GameEventType.paddleHit));

      final miss = bounceOffPaddle(offset: maxHitOffset + 0.001);
      expect(
        miss.events.map((e) => e.type),
        isNot(contains(GameEventType.paddleHit)),
      );
      // The missed ball keeps flying outward and costs a life.
      final events = runCollecting(miss, 60);
      expect(events.map((e) => e.type), contains(GameEventType.lifeLost));
    });

    test('ignores a ball that is already moving inward', () {
      final s = playingState();
      s.players[0].paddle.angle = bottomCenterAngle;
      launchBall(
        s,
        0,
        -(contact + 0.01),
        DetMath.halfPi, // straight up = inward
        0.6,
      );
      Simulation.step(s, noneInputs(s));
      expect(
        s.events.map((e) => e.type),
        isNot(contains(GameEventType.paddleHit)),
      );
      expect(s.players[0].score, 0);
    });

    test('guarantees a minimum inward component on grazing hits', () {
      // Approach almost tangentially: the mirror reflection alone would leave
      // the ball skimming the ring, so the sim rotates it toward the normal.
      final tangent = bottomCenterAngle + DetMath.halfPi;
      final s = bounceOffPaddle(
        approachAngle: tangent - 0.14, // slightly outward
        speed: 0.6,
        radius: contact + 0.001,
      );
      expect(s.events.map((e) => e.type), contains(GameEventType.paddleHit));
      expect(inwardDot(s), closeTo(Simulation.minInwardDot, 1e-6));
      // The corrected direction is still exactly a unit vector times speed
      // (the rotation uses a precomputed sine that must match minInwardDot).
      expect(
        math.sqrt(s.ball.vx * s.ball.vx + s.ball.vy * s.ball.vy),
        closeTo(s.ball.speed, 1e-15),
      );
    });

    test('never bounces off two paddles in the same tick', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.duel, seed: 8),
      );
      final inputs = <PlayerInput>[PlayerInput.none, PlayerInput.none];
      for (var i = 0; i < 20000; i++) {
        for (var p = 0; p < 2; p++) {
          inputs[p] = ScriptedInput.aimAtBall(s, p);
        }
        Simulation.step(s, inputs);
        final hits = s.events
            .where((e) => e.type == GameEventType.paddleHit)
            .length;
        expect(hits, lessThanOrEqualTo(1));
      }
      expect(s.players[0].score, greaterThan(0));
      expect(s.players[1].score, greaterThan(0));
    });
  });

  group('escape, serve and game over', () {
    test('a ball into the gap costs a life, clears the combo and serves', () {
      final s = playingState();
      s.players[0].paddle.angle = topCenterAngle; // gap at the bottom
      s.players[0].combo = 7;
      launchBall(s, 0, -0.5, -DetMath.halfPi, 0.9);
      final ticks = stepUntil(s, GameEventType.lifeLost, maxTicks: 120);
      expect(ticks, greaterThan(0));
      final lost = s.events.firstWhere((e) => e.type == GameEventType.lifeLost);
      expect(lost.player, 0);
      expect(lost.y, lessThan(-escapeRadius + 0.05));
      expect(s.players[0].lives, startLives - 1);
      expect(s.players[0].combo, 0);
      expect(s.phase, Phase.serving);
      expect(s.serveTimer, serveTicks);
      expect(s.ball.active, isFalse);
      expect(s.ball.x, 0);
      expect(s.ball.y, 0);
      expect(s.ball.vx, 0);
      expect(s.ball.vy, 0);
    });

    test('the serve fires after serveTicks with the SPEC speed ramp', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 5),
      );
      s.nextWallIn = 1 << 30;
      s.nextPickupIn = 1 << 30;
      final ticks = stepUntil(s, GameEventType.serve, maxTicks: serveTicks + 5);
      expect(ticks, serveTicks);
      expect(s.phase, Phase.playing);
      expect(s.ball.active, isTrue);
      expect(s.ball.owner, -1);
      final launchTick = s.tick - 1;
      final expected = math.min(
        baseSpeed + 0.01 * (launchTick / tickRate),
        maxServeSpeed,
      );
      expect(s.ball.speed, closeTo(expected, 1e-12));
      expect(
        math.sqrt(s.ball.vx * s.ball.vx + s.ball.vy * s.ball.vy),
        closeTo(s.ball.speed, 1e-9),
      );
      // Solo serves point anywhere on the circle.
      final angles = <double>{};
      for (var seed = 0; seed < 25; seed++) {
        final g = GameState.initial(
          GameConfig(mode: GameMode.solo, seed: seed),
        );
        stepUntil(g, GameEventType.serve, maxTicks: serveTicks + 1);
        angles.add(math.atan2(g.ball.vy, g.ball.vx));
      }
      expect(angles.length, greaterThan(20));
    });

    test('the serve speed ramp saturates at maxServeSpeed', () {
      final s = playingState();
      s.phase = Phase.serving;
      s.serveTimer = 1;
      s.tick = 60 * tickRate; // 60 s in: 0.55 + 0.6 > 0.95
      Simulation.step(s, noneInputs(s));
      expect(s.ball.speed, maxServeSpeed);
    });

    test('losing the last life ends the game and freezes the state', () {
      final s = playingState();
      s.players[0].paddle.angle = topCenterAngle;
      s.players[0].lives = 1;
      launchBall(s, 0, -0.5, -DetMath.halfPi, 0.9);
      final ticks = stepUntil(s, GameEventType.gameOver, maxTicks: 120);
      expect(ticks, greaterThan(0));
      expect(s.phase, Phase.gameOver);
      expect(s.players[0].lives, 0);
      expect(s.winner, -1); // solo has no winner
      expect(
        s.events.map((e) => e.type),
        containsAll([GameEventType.lifeLost, GameEventType.gameOver]),
      );

      // step() is a no-op afterwards: it only clears the events.
      final frozen = s.hash();
      final tick = s.tick;
      for (var i = 0; i < 10; i++) {
        Simulation.step(s, [const PlayerInput(move: inputMoveMax)]);
        expect(s.events, isEmpty);
      }
      expect(s.hash(), frozen);
      expect(s.tick, tick);
    });
  });

  group('duel halves', () {
    /// Parks both paddles at the far end of their range so the ball can leave
    /// through [throughBottom]'s half.
    GameState duelWithGap({required bool throughBottom}) {
      final s = playingState(mode: GameMode.duel);
      s.players[0].paddle.angle = Simulation.duelMinAngle(0);
      s.players[1].paddle.angle = Simulation.duelMinAngle(1);
      launchBall(
        s,
        0,
        throughBottom ? -0.5 : 0.5,
        throughBottom ? -DetMath.halfPi : DetMath.halfPi,
        0.9,
      );
      return s;
    }

    test('the half containing the escape angle loses the life', () {
      for (final bottom in [true, false]) {
        final s = duelWithGap(throughBottom: bottom);
        s.players[0].combo = 7;
        s.players[1].combo = 7;
        expect(
          stepUntil(s, GameEventType.lifeLost, maxTicks: 120),
          greaterThan(0),
        );
        final loser = bottom ? 0 : 1;
        final other = 1 - loser;
        final event = s.events.firstWhere(
          (e) => e.type == GameEventType.lifeLost,
        );
        expect(event.player, loser);
        expect(s.players[loser].lives, startLives - 1);
        expect(s.players[loser].combo, 0);
        expect(s.players[other].lives, startLives);
        expect(s.players[other].combo, 7, reason: 'only the loser resets');
      }
    });

    test('the next serve is aimed at the half of the player who lost', () {
      for (final bottom in [true, false]) {
        final s = duelWithGap(throughBottom: bottom);
        stepUntil(s, GameEventType.lifeLost, maxTicks: 120);
        final loser = bottom ? 0 : 1;
        expect(s.ball.owner, loser, reason: 'receiver carried while serving');
        expect(
          stepUntil(s, GameEventType.serve, maxTicks: serveTicks + 1),
          serveTicks,
        );
        final serve = s.events.firstWhere((e) => e.type == GameEventType.serve);
        expect(serve.player, loser);
        expect(s.ball.owner, -1);
        final direction = math.atan2(s.ball.vy, s.ball.vx);
        final center = loser == 0 ? bottomCenterAngle : topCenterAngle;
        expect(
          DetMath.angleDiff(direction, center).abs(),
          lessThanOrEqualTo(serveSpread),
        );
        // The serve always heads into the receiver's own half.
        expect(math.sin(direction) < 0, loser == 0);
      }
    });

    test('the last life ends the duel and the opponent wins', () {
      final s = duelWithGap(throughBottom: true);
      s.players[0].lives = 1;
      expect(
        stepUntil(s, GameEventType.gameOver, maxTicks: 120),
        greaterThan(0),
      );
      expect(s.phase, Phase.gameOver);
      expect(s.winner, 1);
      final over = s.events.firstWhere((e) => e.type == GameEventType.gameOver);
      expect(over.player, 1);
    });

    test('paddles stay clamped to their own half', () {
      final s = playingState(mode: GameMode.duel);
      // Both players aim at the other half and then push with raw move input.
      final crossed = <PlayerInput>[
        PlayerInput.aimAngle(topCenterAngle),
        PlayerInput.aimAngle(bottomCenterAngle),
      ];
      for (var i = 0; i < 200; i++) {
        Simulation.step(s, crossed);
        for (var p = 0; p < 2; p++) {
          expect(
            s.players[p].paddle.angle,
            inRange(Simulation.duelMinAngle(p), Simulation.duelMaxAngle(p)),
          );
        }
      }
      for (final dir in [inputMoveMax, -inputMoveMax]) {
        final m = playingState(mode: GameMode.duel);
        final push = <PlayerInput>[
          PlayerInput(move: dir),
          PlayerInput(move: dir),
        ];
        for (var i = 0; i < 300; i++) {
          Simulation.step(m, push);
        }
        for (var p = 0; p < 2; p++) {
          expect(
            m.players[p].paddle.angle,
            dir > 0 ? Simulation.duelMaxAngle(p) : Simulation.duelMinAngle(p),
          );
        }
      }
    });

    test('an aim target outside the half snaps to the nearest end', () {
      final s = playingState(mode: GameMode.duel);
      // Just above the +x axis: the nearest end of player 0's range is its
      // upper bound, not the numerically closer lower bound.
      final inputs = <PlayerInput>[
        PlayerInput.aimAngle(0.1),
        PlayerInput.aimAngle(0.1),
      ];
      for (var i = 0; i < 200; i++) {
        Simulation.step(s, inputs);
      }
      expect(s.players[0].paddle.angle, Simulation.duelMaxAngle(0));
      expect(s.players[1].paddle.angle, Simulation.duelMinAngle(1));
    });
  });

  group('paddle input', () {
    test('aim moves at paddleSpeed and stops on the target', () {
      final s = playingState();
      final target = PlayerInput.aimAngle(bottomCenterAngle + 1.0);
      final start = s.players[0].paddle.angle;
      Simulation.step(s, [target]);
      expect(
        s.players[0].paddle.angle - start,
        closeTo(paddleSpeed * dt, 1e-12),
      );
      for (var i = 0; i < 200; i++) {
        Simulation.step(s, [target]);
      }
      expect(
        DetMath.angleDiff(s.players[0].paddle.angle, target.targetAngle).abs(),
        lessThan(1e-9),
      );
    });

    test('move drives the paddle at move / 16 * paddleSpeed', () {
      for (final move in [16, 8, -16, -4]) {
        final s = playingState();
        final start = s.players[0].paddle.angle;
        Simulation.step(s, [PlayerInput(move: move)]);
        expect(
          DetMath.angleDiff(s.players[0].paddle.angle, start),
          closeTo(move / inputMoveMax * paddleSpeed * dt, 1e-12),
          reason: 'move $move',
        );
      }
    });

    test('the solo paddle roams the whole circle, normalized to [0, tau)', () {
      final s = playingState();
      const push = [PlayerInput(move: inputMoveMax)];
      final seenQuadrants = <int>{};
      for (var i = 0; i < 1000; i++) {
        Simulation.step(s, push);
        final a = s.players[0].paddle.angle;
        expect(a, greaterThanOrEqualTo(0));
        expect(a, lessThan(DetMath.tau));
        seenQuadrants.add((a / DetMath.halfPi).floor());
      }
      expect(seenQuadrants, {0, 1, 2, 3});
    });
  });

  group('walls', () {
    /// A vertical wall at x = 0.2 crossing the path of a ball fired along +x.
    Wall barrier({required int age, int ttl = 600}) =>
        Wall(id: 1, x1: 0.2, y1: -0.3, x2: 0.2, y2: 0.3, ttl: ttl, age: age);

    test('a solid wall bounces the ball and credits its owner', () {
      final s = playingState();
      s.walls.add(barrier(age: wallFadeTicks));
      s.players[0].combo = 5; // multiplier 2
      s.ball.owner = 0;
      launchBall(s, 0, 0, 0, 0.6);
      final ticks = stepUntil(s, GameEventType.wallHit, maxTicks: 40);
      expect(ticks, 15);
      expect(s.ball.vx, lessThan(0));
      expect(s.ball.speed, closeTo(0.6, 1e-12)); // walls do not change speed
      expect(
        segmentDistance(0.2, -0.3, 0.2, 0.3, s.ball.x, s.ball.y),
        closeTo(Simulation.wallCapsuleRadius, 1e-9),
      );
      expect(s.players[0].score, wallHitScore * 2);
      final hit = s.events.firstWhere((e) => e.type == GameEventType.wallHit);
      expect(hit.player, 0);
    });

    test('an unowned wall bounce scores nothing', () {
      final s = playingState();
      s.walls.add(barrier(age: wallFadeTicks));
      launchBall(s, 0, 0, 0, 0.6);
      expect(stepUntil(s, GameEventType.wallHit, maxTicks: 40), 15);
      expect(s.players[0].score, 0);
    });

    test('a wall younger than wallFadeTicks does not collide', () {
      final s = playingState();
      s.walls.add(barrier(age: 0));
      launchBall(s, 0, 0, 0, 0.6);
      final events = runCollecting(s, 35);
      expect(events.map((e) => e.type), isNot(contains(GameEventType.wallHit)));
      expect(s.ball.x, greaterThan(0.3)); // flew straight through
      expect(s.walls.single.age, 35);
    });

    test('a wall inside its fade-out window does not collide', () {
      final s = playingState();
      s.walls.add(barrier(age: 600 - wallFadeTicks - 2));
      launchBall(s, 0, 0, 0, 0.6);
      final events = runCollecting(s, 35);
      expect(events.map((e) => e.type), isNot(contains(GameEventType.wallHit)));
      expect(events.map((e) => e.type), contains(GameEventType.wallExpire));
      expect(s.walls, isEmpty);
      expect(s.ball.x, greaterThan(0.3));
    });

    test('the ball never tunnels through a wall at maxSpeed (1000 shots)', () {
      final rnd = math.Random(20260923);
      var bounces = 0;
      for (var shot = 0; shot < 1000; shot++) {
        final s = playingState();
        // Random solid wall inside the spawn area.
        final cr = wallSpawnRadius * math.sqrt(rnd.nextDouble());
        final ct = rnd.nextDouble() * DetMath.tau;
        final cx = cr * math.cos(ct);
        final cy = cr * math.sin(ct);
        final phi = rnd.nextDouble() * DetMath.tau;
        final half =
            (wallMinLength +
                rnd.nextDouble() * (wallMaxLength - wallMinLength)) /
            2;
        final x1 = cx - math.cos(phi) * half;
        final y1 = cy - math.sin(phi) * half;
        final x2 = cx + math.cos(phi) * half;
        final y2 = cy + math.sin(phi) * half;
        s.walls.add(
          Wall(
            id: 1,
            x1: x1,
            y1: y1,
            x2: x2,
            y2: y2,
            ttl: 1 << 20,
            age: wallFadeTicks,
          ),
        );
        // Random start outside the capsule, fired at a random point of the
        // wall (plus jitter) so that most shots really meet it, at max speed.
        double bx, by;
        do {
          final br = 0.85 * math.sqrt(rnd.nextDouble());
          final bt = rnd.nextDouble() * DetMath.tau;
          bx = br * math.cos(bt);
          by = br * math.sin(bt);
        } while (segmentDistance(x1, y1, x2, y2, bx, by) <
            Simulation.wallCapsuleRadius + 0.01);
        final aim = rnd.nextDouble();
        final target = math.atan2(
          y1 + (y2 - y1) * aim - by,
          x1 + (x2 - x1) * aim - bx,
        );
        launchBall(
          s,
          bx,
          by,
          target + (rnd.nextDouble() - 0.5) * 0.3,
          maxSpeedSolo,
        );

        double sideOf(double px, double py) =>
            (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1);
        var prevX = s.ball.x;
        var prevY = s.ball.y;
        var prevSide = sideOf(prevX, prevY);
        for (var t = 0; t < 200; t++) {
          Simulation.step(s, noneInputs(s));
          if (s.phase != Phase.playing || !s.ball.active) break;
          final x = s.ball.x;
          final y = s.ball.y;
          expect(
            segmentDistance(x1, y1, x2, y2, x, y),
            greaterThanOrEqualTo(Simulation.wallCapsuleRadius - 1e-9),
            reason: 'shot $shot tick $t ended inside the wall capsule',
          );
          final side = sideOf(x, y);
          if (prevSide != 0 && side != 0 && (side < 0) != (prevSide < 0)) {
            // The straight path crossed the wall's line: that is only legal
            // beyond the ends of the segment.
            final f = prevSide / (prevSide - side);
            final px = prevX + (x - prevX) * f;
            final py = prevY + (y - prevY) * f;
            final ex = x2 - x1;
            final ey = y2 - y1;
            final u = ((px - x1) * ex + (py - y1) * ey) / (ex * ex + ey * ey);
            expect(
              u < 0 || u > 1,
              isTrue,
              reason: 'shot $shot tick $t tunnelled through the wall at u=$u',
            );
          }
          if (s.events.any((e) => e.type == GameEventType.wallHit)) bounces++;
          prevX = x;
          prevY = y;
          prevSide = side;
        }
      }
      // Sanity: the shots really do hit the walls.
      expect(bounces, greaterThan(800));
    });

    test(
      'a ball on a wall center line is pushed out, not launched along it',
      () {
        // The closest point on the segment carries a few ulps of rounding
        // residue ALONG the wall, so a ball on the center line used to get a
        // "normal" parallel to the segment: the push-out then displaced it by
        // wallCapsuleRadius per substep down the wall instead of out of it.
        final s = playingState();
        s.walls.add(
          Wall(
            id: 1,
            x1: -0.2,
            y1: 0,
            x2: 0.2,
            y2: 0,
            ttl: 1 << 20,
            age: wallFadeTicks,
          ),
        );
        launchBall(s, 0, 0, 0, 0.6); // exactly on the segment, moving along it
        const perTick = 0.6 * dt;
        for (var i = 1; i <= 10; i++) {
          final xBefore = s.ball.x;
          Simulation.step(s, noneInputs(s));
          expect(
            s.ball.x - xBefore,
            closeTo(perTick, 1e-9),
            reason: 'tick $i moved the ball by more than speed * dt',
          );
          expect(
            segmentDistance(-0.2, 0, 0.2, 0, s.ball.x, s.ball.y),
            greaterThanOrEqualTo(Simulation.wallCapsuleRadius - 1e-9),
            reason: 'tick $i left the ball inside the wall capsule',
          );
          expect(s.ball.speed, closeTo(0.6, 1e-12));
        }
        // It came out perpendicular to the wall, onto the capsule surface.
        expect(s.ball.y.abs(), closeTo(Simulation.wallCapsuleRadius, 1e-9));
      },
    );

    test('spawn limits, placement and intervals follow the SPEC', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 17),
      );
      final inputs = <PlayerInput>[PlayerInput.none];
      final known = <int>{};
      var spawns = 0;
      var previousNextWallIn = s.nextWallIn;
      for (var i = 0; i < 40000; i++) {
        final tickBefore = s.tick;
        inputs[0] = ScriptedInput.aimAtBall(s, 0);
        Simulation.step(s, inputs);
        expect(
          s.walls.length,
          lessThanOrEqualTo(Simulation.maxWalls(tickBefore)),
        );
        if (s.nextWallIn > previousNextWallIn) {
          // A fresh interval was drawn this tick.
          expect(
            s.nextWallIn,
            tickBefore < 30 * tickRate
                ? inRange(7 * tickRate, 9 * tickRate)
                : inRange(4 * tickRate, 6 * tickRate),
          );
        }
        previousNextWallIn = s.nextWallIn;
        for (final w in s.walls) {
          if (!known.add(w.id)) continue;
          spawns++;
          expect(w.age, 0);
          expect(w.ttl, inRange(wallMinLifetime, wallMaxLifetime));
          final length = dist(w.x1, w.y1, w.x2, w.y2);
          expect(length, inRange(wallMinLength - 1e-9, wallMaxLength + 1e-9));
          expect(
            dist(0, 0, w.centerX, w.centerY),
            lessThanOrEqualTo(wallSpawnRadius + 1e-9),
          );
          expect(
            segmentDistance(w.x1, w.y1, w.x2, w.y2, s.ball.x, s.ball.y),
            greaterThanOrEqualTo(wallMinDistFromBall - 1e-9),
          );
          for (final other in s.walls) {
            if (identical(other, w)) continue;
            expect(
              dist(w.centerX, w.centerY, other.centerX, other.centerY),
              greaterThanOrEqualTo(wallMinDistBetweenCenters - 1e-9),
            );
          }
        }
      }
      expect(spawns, greaterThan(50));
      expect(Simulation.maxWalls(0), 1);
      expect(Simulation.maxWalls(20 * tickRate), 2);
      expect(Simulation.maxWalls(60 * tickRate), 3);
    });

    test('walls expire exactly at their ttl and emit wallExpire', () {
      final s = playingState();
      s.walls.add(barrier(age: 595, ttl: 600));
      final events = runCollecting(s, 5);
      expect(s.walls, isEmpty);
      final expire = events
          .where((e) => e.type == GameEventType.wallExpire)
          .toList();
      expect(expire.length, 1);
      expect(expire.single.x, closeTo(0.2, 1e-12));
      expect(s.tick, 5); // aged 595 -> 600 on the fifth step
    });

    test(
      'walls keep clear of the serve point, so no serve starts inside one',
      () {
        // Every serve puts the ball at (0, 0), so a wall whose capsule covers
        // the origin would serve the ball from inside solid geometry: the next
        // tick teleports it out of penetration and can reflect it away from the
        // direction the serve drew (SPEC 2.3, serve direction).
        const clearance = Simulation.wallCapsuleRadius + ballRadius;
        var spawned = 0;
        var serves = 0;
        for (final mode in [GameMode.solo, GameMode.duel]) {
          for (var seed = 1; seed <= 30; seed++) {
            final s = GameState.initial(GameConfig(mode: mode, seed: seed));
            final inputs = List<PlayerInput>.filled(
              s.players.length,
              PlayerInput.none,
            );
            final known = <int>{};
            final where = 'mode $mode, seed $seed';
            var justServed = false;
            while (s.phase != Phase.gameOver && s.tick < 90 * tickRate) {
              for (var p = 0; p < inputs.length; p++) {
                inputs[p] = s.tick < 40 * tickRate
                    ? ScriptedInput.aimAtBall(s, p)
                    : ScriptedInput.avoidBall(s, p);
              }
              Simulation.step(s, inputs);
              for (final w in s.walls) {
                if (!known.add(w.id)) continue;
                spawned++;
                expect(
                  segmentDistance(w.x1, w.y1, w.x2, w.y2, 0, 0),
                  greaterThanOrEqualTo(clearance - 1e-9),
                  reason:
                      'wall ${w.id} spawned across the serve point ($where)',
                );
              }
              if (justServed) {
                justServed = false;
                // The first tick of a serve is free flight from the origin: no
                // push-out of a wall, no bounce out of nowhere.
                expect(
                  ballDistance(s),
                  closeTo(s.ball.speed * dt, 1e-12),
                  reason: 'the serve was displaced by a wall ($where)',
                );
                expect(
                  s.events.where((e) => e.type == GameEventType.wallHit),
                  isEmpty,
                  reason: 'the serve bounced on its first tick ($where)',
                );
              }
              if (s.events.any((e) => e.type == GameEventType.serve)) {
                serves++;
                justServed = true;
                for (final w in s.walls) {
                  if (!w.solid) continue;
                  expect(
                    segmentDistance(w.x1, w.y1, w.x2, w.y2, 0, 0),
                    greaterThanOrEqualTo(Simulation.wallCapsuleRadius - 1e-9),
                    reason: 'served inside wall ${w.id} ($where)',
                  );
                }
              }
            }
          }
        }
        expect(spawned, greaterThan(50));
        expect(serves, greaterThan(100));
      },
    );
  });

  group('pickups', () {
    test('a star is collected by the owner and scores 100 x multiplier', () {
      final s = playingState();
      s.players[0].combo = 5; // multiplier 2
      s.pickups.add(Pickup(id: 1, type: PickupType.star, x: 0.2, y: 0));
      launchBall(s, 0, 0, 0, 0.6);
      expect(stepUntil(s, GameEventType.pickup, maxTicks: 30), 10);
      final event = s.events.firstWhere((e) => e.type == GameEventType.pickup);
      expect(event.player, 0);
      expect(event.pickup, PickupType.star);
      expect(event.x, closeTo(0.2, 1e-12));
      expect(s.players[0].score, starScore * 2);
      expect(s.pickups, isEmpty);
    });

    test('a heart adds a life but never above maxLives', () {
      final below = playingState();
      below.pickups.add(Pickup(id: 1, type: PickupType.heart, x: 0.2, y: 0));
      launchBall(below, 0, 0, 0, 0.6);
      expect(stepUntil(below, GameEventType.pickup, maxTicks: 30), 10);
      expect(below.players[0].lives, startLives + 1);
      expect(below.players[0].score, 0);

      final full = playingState();
      full.players[0].lives = maxLives;
      full.pickups.add(Pickup(id: 1, type: PickupType.heart, x: 0.2, y: 0));
      launchBall(full, 0, 0, 0, 0.6);
      expect(stepUntil(full, GameEventType.pickup, maxTicks: 30), 10);
      expect(full.players[0].lives, maxLives);
      expect(full.pickups, isEmpty);
    });

    test('solo credits player 0 even before the first paddle hit', () {
      final s = playingState();
      expect(s.ball.owner, -1);
      s.pickups.add(Pickup(id: 1, type: PickupType.star, x: 0.2, y: 0));
      launchBall(s, 0, 0, 0, 0.6);
      stepUntil(s, GameEventType.pickup, maxTicks: 30);
      expect(s.players[0].score, starScore);
    });

    test('a duel pickup with no owner is removed without credit', () {
      final s = playingState(mode: GameMode.duel);
      s.ball.owner = -1;
      s.pickups.add(Pickup(id: 1, type: PickupType.star, x: 0.2, y: 0));
      launchBall(s, 0, 0, 0, 0.6);
      stepUntil(s, GameEventType.pickup, maxTicks: 30);
      final event = s.events.firstWhere((e) => e.type == GameEventType.pickup);
      expect(event.player, -1);
      expect(s.pickups, isEmpty);
      expect(s.players[0].score, 0);
      expect(s.players[1].score, 0);
    });

    test('a duel pickup is credited to the last hitter', () {
      final s = playingState(mode: GameMode.duel);
      s.ball.owner = 1;
      s.players[1].combo = 10; // multiplier 3
      s.pickups.add(Pickup(id: 1, type: PickupType.star, x: 0.2, y: 0));
      launchBall(s, 0, 0, 0, 0.6);
      stepUntil(s, GameEventType.pickup, maxTicks: 30);
      expect(s.players[1].score, starScore * 3);
      expect(s.players[0].score, 0);
    });

    test('pickups expire and emit pickupExpire', () {
      final s = playingState();
      s.pickups.add(
        Pickup(id: 1, type: PickupType.heart, x: 0.5, y: 0.5, ttl: 3),
      );
      final events = runCollecting(s, 3);
      final expire = events.where((e) => e.type == GameEventType.pickupExpire);
      expect(expire.length, 1);
      expect(expire.single.pickup, PickupType.heart);
      expect(expire.single.x, 0.5);
      expect(s.pickups, isEmpty);
    });

    test('spawn placement, cap and intervals follow the SPEC', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 23),
      );
      final inputs = <PlayerInput>[PlayerInput.none];
      final known = <int>{};
      var spawns = 0;
      var previousNextPickupIn = s.nextPickupIn;
      for (var i = 0; i < 40000; i++) {
        inputs[0] = ScriptedInput.aimAtBall(s, 0);
        Simulation.step(s, inputs);
        expect(s.pickups.length, lessThanOrEqualTo(maxPickups));
        if (s.nextPickupIn > previousNextPickupIn) {
          expect(s.nextPickupIn, inRange(5 * tickRate, 8 * tickRate));
        }
        previousNextPickupIn = s.nextPickupIn;
        for (final k in s.pickups) {
          if (!known.add(k.id)) continue;
          spawns++;
          expect(k.ttl, pickupLifetime);
          expect(
            dist(0, 0, k.x, k.y),
            lessThanOrEqualTo(pickupSpawnRadius + 1e-9),
          );
          expect(
            dist(k.x, k.y, s.ball.x, s.ball.y),
            greaterThanOrEqualTo(pickupMinDistFromBall - 1e-9),
          );
          for (final other in s.pickups) {
            if (identical(other, k)) continue;
            expect(
              dist(k.x, k.y, other.x, other.y),
              greaterThanOrEqualTo(pickupMinDistBetweenPickups - 1e-9),
            );
          }
          for (final w in s.walls) {
            expect(
              segmentDistance(w.x1, w.y1, w.x2, w.y2, k.x, k.y),
              greaterThanOrEqualTo(pickupMinDistFromWall - 1e-9),
            );
          }
        }
      }
      expect(spawns, greaterThan(50));
    });

    test('hearts only spawn while a player is below maxLives', () {
      final capped = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 3),
      );
      final inputs = <PlayerInput>[PlayerInput.none];
      final seen = <int>{};
      var stars = 0;
      for (var i = 0; i < 20000; i++) {
        capped.players[0].lives = maxLives;
        inputs[0] = ScriptedInput.aimAtBall(capped, 0);
        Simulation.step(capped, inputs);
        for (final k in capped.pickups) {
          if (!seen.add(k.id)) continue;
          expect(k.type, PickupType.star);
          stars++;
        }
      }
      expect(stars, greaterThan(20));

      // With lives to spare, hearts do appear.
      final normal = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 3),
      );
      var hearts = 0;
      final seen2 = <int>{};
      for (var i = 0; i < 20000; i++) {
        normal.players[0].lives = 1;
        inputs[0] = ScriptedInput.aimAtBall(normal, 0);
        Simulation.step(normal, inputs);
        for (final k in normal.pickups) {
          if (seen2.add(k.id) && k.type == PickupType.heart) hearts++;
        }
      }
      expect(hearts, greaterThan(0));
    });
  });

  group('scoring', () {
    test('a paddle hit increments the combo first, then scores 10 x mult', () {
      for (final combo in [0, 4, 9, 34, 100]) {
        final s = bounceOffPaddle(combo: combo);
        // The combo is incremented first, so the multiplier already includes
        // this hit.
        final expected =
            paddleHitScore * math.min(1 + (combo + 1) ~/ 5, maxMultiplier);
        expect(s.players[0].combo, combo + 1);
        expect(s.players[0].score, expected, reason: 'combo $combo');
      }
    });

    test('multiplier is 1 + combo ~/ 5 capped at 8', () {
      final p = Player(paddle: Paddle(0));
      for (final combo in [0, 4, 5, 9, 10, 34, 35, 40, 1000]) {
        p.combo = combo;
        expect(p.multiplier, math.min(1 + combo ~/ 5, maxMultiplier));
      }
    });

    test('solo scores one point per 60 ticks while playing', () {
      final s = playingState();
      for (var i = 1; i <= 181; i++) {
        Simulation.step(s, noneInputs(s));
        expect(s.players[0].score, i ~/ tickRate);
      }
    });

    test('no survival points while serving or in a duel', () {
      final serving = playingState();
      serving.phase = Phase.serving;
      serving.serveTimer = 1000;
      for (var i = 0; i < 180; i++) {
        Simulation.step(serving, noneInputs(serving));
      }
      expect(serving.players[0].score, 0);

      final duel = playingState(mode: GameMode.duel);
      for (var i = 0; i < 180; i++) {
        Simulation.step(duel, noneInputs(duel));
      }
      expect(duel.players[0].score, 0);
      expect(duel.players[1].score, 0);
    });
  });

  group('events', () {
    test('a full solo game emits every event type', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 7),
      );
      final seen = <GameEventType>{};
      var ticks = 0;
      final inputs = <PlayerInput>[PlayerInput.none];
      while (s.phase != Phase.gameOver && ticks < 20000) {
        inputs[0] = scriptedInput(s, 0, 1200);
        Simulation.step(s, inputs);
        seen.addAll(s.events.map((e) => e.type));
        ticks++;
      }
      expect(s.phase, Phase.gameOver);
      expect(
        seen,
        GameEventType.values.toSet()..remove(GameEventType.tick),
        reason: 'GameEventType.tick is reserved for clients',
      );
    });

    test('every event carries a sane player index and position', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.duel, seed: 31),
      );
      final events = runCollecting(
        s,
        5000,
        bot: (state, player) => ScriptedInput.aimAtBall(state, player),
      );
      expect(events, isNotEmpty);
      for (final e in events) {
        expect(e.player, inRange(-1, s.players.length - 1));
        expect(e.x.abs(), lessThan(2));
        expect(e.y.abs(), lessThan(2));
        expect(
          e.pickup != null,
          e.type == GameEventType.pickup ||
              e.type == GameEventType.pickupExpire,
        );
      }
    });
  });

  group('constants', () {
    test('match the table in SPEC section 2.2', () {
      expect(tickRate, 60);
      expect(dt, 1.0 / 60.0);
      expect(arenaRadius, 1.0);
      expect(ballRadius, 0.035);
      expect(paddleRing, 0.96);
      expect(paddleThickness, 0.04); // drawn from 0.94 to 0.98
      expect(paddleHalfWidth, 0.34);
      expect(paddleSpeed, 4.2);
      expect(baseSpeed, 0.55);
      expect(maxSpeedSolo, 1.6);
      expect(maxSpeedDuel, 1.5);
      expect(hitSpeedFactor, 1.035);
      expect(escapeRadius, 1.06);
      expect(serveTicks, 60);
      expect(startLives, 3);
      expect(maxLives, 5);
      expect(wallHalfThickness, 0.02);
      expect(wallMinLength, 0.25);
      expect(wallMaxLength, 0.45);
      expect(wallMinLifetime, 9 * tickRate);
      expect(wallMaxLifetime, 14 * tickRate);
      expect(wallFadeTicks, 30);
      expect(pickupRadius, 0.07);
      expect(pickupLifetime, 480);
      expect(pickupBlinkTicks, 120);
      expect(maxPickups, 2);
      expect(maxServeSpeed, 0.95);
      expect(maxMultiplier, 8);
      expect(bottomCenterAngle, closeTo(3 * DetMath.pi / 2, 1e-15));
      expect(topCenterAngle, DetMath.halfPi);
      expect(serveSpread, 0.9);
    });

    test('derived simulation values agree with the formulas', () {
      expect(
        Simulation.paddleContactRadius,
        paddleRing - paddleThickness / 2 - ballRadius,
      );
      expect(Simulation.paddleAngularSlack, ballRadius / paddleRing);
      expect(Simulation.wallCapsuleRadius, wallHalfThickness + ballRadius);
      expect(Simulation.englishFactor, paddleEnglish);
      expect(Simulation.minInwardDot, paddleMinInwardDot);
      expect(paddleHitRadius, Simulation.paddleContactRadius);
      expect(paddleAngularSlack, maxHitOffset);
      expect(wallCollisionRadius, Simulation.wallCapsuleRadius);
      expect(pickupCollectRadius, pickupRadius + ballRadius);
      // Substepping keeps every step shorter than the collision radius, which
      // is what makes tunnelling impossible.
      final maxSubstep =
          maxSpeedSolo * dt / (maxSpeedSolo * dt / substepDistance).ceil();
      expect(maxSubstep, lessThan(Simulation.wallCapsuleRadius));
      expect(maxSubsteps, 8);
      expect(substepDistance, 0.02);
    });
  });
}
