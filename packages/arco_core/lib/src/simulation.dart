/// The deterministic step function. See SPEC.md §2.3.
///
/// Everything here obeys the determinism rules of SPEC §2.1: only basic
/// arithmetic, `sqrt`, [DetMath] trigonometry and the [Prng]. The step is
/// allocation-light: the only objects created are the (rare) events, spawned
/// walls and pickups.
library;

import 'dart:math' show sqrt;

import 'constants.dart';
import 'det_math.dart';
import 'input.dart';
import 'model.dart';

class Simulation {
  Simulation._();

  /// Radius at which the ball touches the paddle's inner face.
  static const double paddleContactRadius =
      paddleRing - paddleThickness / 2 - ballRadius;

  /// Angular slack added to the paddle half-width so the ball's edge counts.
  static const double paddleAngularSlack = ballRadius / paddleRing;

  /// Radians of deflection at the paddle edge ("english").
  static const double englishFactor = 0.55;

  /// Minimum dot(direction, inward normal) after a paddle bounce.
  static const double minInwardDot = 0.25;

  /// sqrt(1 - minInwardDot^2): sine of the maximum angle from the normal.
  static const double _minInwardSin = 0.9682458365518543;

  /// Wall capsule radius: half-thickness plus the ball radius.
  static const double wallCapsuleRadius = wallHalfThickness + ballRadius;
  static const double _wallCapsuleRadius2 =
      wallCapsuleRadius * wallCapsuleRadius;

  /// Squared distance below which the ball counts as sitting *on* a wall's
  /// center line. The vector from the closest point to the ball carries a few
  /// ulps of rounding residue **along** the segment, so normalizing it that
  /// close to the line would yield a "normal" parallel to the wall; the
  /// segment perpendicular is used instead.
  static const double _wallDegenerateD2 = 1e-18;

  static const double _substepLength = 0.02;
  static const int _maxSubsteps = 8;

  static const double _pickupCollectRadius = pickupRadius + ballRadius;
  static const double _pickupCollectRadius2 =
      _pickupCollectRadius * _pickupCollectRadius;
  static const double _escapeRadius2 = escapeRadius * escapeRadius;

  static const double _paddleStep = paddleSpeed * dt;

  /// Lower clamp of player [p]'s paddle center in duel.
  static double duelMinAngle(int p) =>
      p == 0 ? DetMath.pi + paddleHalfWidth : paddleHalfWidth;

  /// Upper clamp of player [p]'s paddle center in duel.
  static double duelMaxAngle(int p) =>
      p == 0 ? DetMath.tau - paddleHalfWidth : DetMath.pi - paddleHalfWidth;

  /// Maximum number of simultaneous walls after [tick] ticks.
  static int maxWalls(int tick) {
    if (tick < 20 * tickRate) return 1;
    if (tick < 60 * tickRate) return 2;
    return 3;
  }

  /// Advances [s] by exactly one tick (1/60 s) using [inputs] (one per player;
  /// missing entries count as [PlayerInput.none]). Clears and refills
  /// `s.events`. When the game is over this only clears the events.
  ///
  /// Order within a tick: paddles → serve timer / ball motion (each ball in
  /// index order, sub-stepped: walls, paddles, pickups, escape) → wall timers →
  /// pickup timers → `tick += 1` → solo survival point.
  static void step(GameState s, List<PlayerInput> inputs) {
    s.events.clear();
    if (s.phase == Phase.gameOver) return;
    final playerCount = s.players.length;
    for (var i = 0; i < playerCount; i++) {
      _updatePaddle(s, i, i < inputs.length ? inputs[i] : PlayerInput.none);
    }
    if (s.phase == Phase.serving) {
      s.serveTimer -= 1;
      if (s.serveTimer <= 0) _serve(s);
    } else {
      _moveBalls(s);
    }
    _updateWalls(s);
    _updatePickups(s);
    s.tick += 1;
    if (s.config.mode == GameMode.solo &&
        s.phase == Phase.playing &&
        s.tick % tickRate == 0) {
      s.players[0].score += 1;
    }
  }

  // ------------------------------------------------------------------ paddles

  static void _updatePaddle(GameState s, int i, PlayerInput input) {
    final paddle = s.players[i].paddle;
    final duel = s.config.mode == GameMode.duel;
    var angle = paddle.angle;
    if (input.aim >= 0) {
      var target = input.targetAngle;
      if (duel) target = _clampTargetToHalf(target, i);
      final d = DetMath.angleDiff(target, angle);
      if (d > _paddleStep) {
        angle += _paddleStep;
      } else if (d < -_paddleStep) {
        angle -= _paddleStep;
      } else {
        angle += d;
      }
    } else if (input.move != 0) {
      angle += input.move / inputMoveMax * paddleSpeed * dt;
    }
    if (duel) {
      final lo = duelMinAngle(i);
      final hi = duelMaxAngle(i);
      if (angle < lo) {
        angle = lo;
      } else if (angle > hi) {
        angle = hi;
      }
    } else {
      angle = DetMath.normAngle(angle);
    }
    paddle.angle = angle;
  }

  /// Clamps an aim target into player [p]'s half. A target outside the range
  /// snaps to the angularly nearest end of the range (a plain numeric clamp
  /// would send a finger near angle 0 to the far left end for player 0).
  static double _clampTargetToHalf(double target, int p) {
    final lo = duelMinAngle(p);
    final hi = duelMaxAngle(p);
    if (target >= lo && target <= hi) return target;
    final dLo = DetMath.angleDiff(lo, target).abs();
    final dHi = DetMath.angleDiff(hi, target).abs();
    return dLo <= dHi ? lo : hi;
  }

  // -------------------------------------------------------------------- serve

  /// Launches every ball from the origin. One serve direction is drawn (solo:
  /// anywhere on the circle; duel: into the receiver's half), and the balls are
  /// fanned symmetrically around it by [serveFan] per gap, so with one ball the
  /// direction is exactly the drawn angle and with two they leave 0.7 rad apart.
  /// One `serve` event covers the whole rally.
  static void _serve(GameState s) {
    final balls = s.balls;
    final rng = s.rng;
    final ramp = baseSpeed + 0.01 * (s.tick / tickRate);
    final speed = ramp > maxServeSpeed ? maxServeSpeed : ramp;
    int receiver;
    double angle;
    if (s.config.mode == GameMode.duel) {
      // During the serving phase `ball.owner` carries the receiving player
      // (drawn in GameState.initial, then the loser of the previous point).
      final owner = balls[0].owner;
      receiver = owner >= 0 ? owner : 0;
      final center = receiver == 0 ? bottomCenterAngle : topCenterAngle;
      angle = center + rng.nextRange(-serveSpread, serveSpread);
    } else {
      receiver = 0;
      angle = rng.nextRange(0, DetMath.tau);
    }
    final n = balls.length;
    for (var i = 0; i < n; i++) {
      final ball = balls[i];
      final direction = n == 1
          ? angle
          : angle + (2 * i - (n - 1)) * (serveFan * 0.5);
      ball.speed = speed;
      ball.x = 0;
      ball.y = 0;
      ball.vx = DetMath.cos(direction) * speed;
      ball.vy = DetMath.sin(direction) * speed;
      ball.owner = -1;
      ball.active = true;
    }
    s.phase = Phase.playing;
    s.serveTimer = 0;
    s.events.add(GameEvent(GameEventType.serve, player: receiver));
  }

  // --------------------------------------------------------------------- ball

  /// Moves every ball, in index order. A ball that escapes ends the rally for
  /// all of them (SPEC §2.3), so the loop stops as soon as the phase changes:
  /// two balls can never cost two lives in one tick.
  static void _moveBalls(GameState s) {
    final balls = s.balls;
    for (var i = 0; i < balls.length; i++) {
      _moveBall(s, balls[i], i);
      if (s.phase != Phase.playing) return;
    }
  }

  static void _moveBall(GameState s, Ball ball, int index) {
    if (!ball.active) return;
    var n = (ball.speed * dt / _substepLength).ceil();
    if (n < 1) n = 1;
    if (n > _maxSubsteps) n = _maxSubsteps;
    final h = dt / n;
    var bounced = false;
    for (var i = 0; i < n; i++) {
      ball.x += ball.vx * h;
      ball.y += ball.vy * h;
      _collideWalls(s, ball, index);
      if (!bounced && _collidePaddles(s, ball, index)) bounced = true;
      _collectPickups(s, ball, index);
      if (_checkEscape(s, ball, index)) return;
    }
  }

  static void _setDirection(Ball ball, double dx, double dy) {
    final m = sqrt(dx * dx + dy * dy);
    if (m > 0) {
      ball.vx = dx / m * ball.speed;
      ball.vy = dy / m * ball.speed;
    }
  }

  /// Resolves [ball] against every solid wall.
  ///
  /// A wall is a chain of capsules, one per consecutive pair of vertices. The
  /// closest point over the **whole** polyline is what the ball is pushed out
  /// of, so a hit exactly on a joint bounces off the shared vertex like the cap
  /// of a capsule instead of picking one of the two segments.
  ///
  /// A straight wall is resolved in one pass — the push-out onto the capsule
  /// surface is exact, as it always was. A shaped wall gets up to
  /// [wallResolvePasses]: on the concave side of a joint, leaving the nearest
  /// segment can put the ball inside its neighbour, and the extra passes walk it
  /// out of the corner. Only the first pass can bounce the ball (and score);
  /// the rest only correct the position, so no ball is ever reflected twice by
  /// one wall in one substep.
  static void _collideWalls(GameState s, Ball ball, int index) {
    final walls = s.walls;
    for (var i = 0; i < walls.length; i++) {
      final w = walls[i];
      if (!w.solid) continue;
      final points = w.points;
      final segments = (points.length >> 1) - 1;
      final passes = segments > 1 ? wallResolvePasses : 1;
      var reflected = false;
      for (var pass = 0; pass < passes; pass++) {
        // Closest point of the polyline, segment by segment.
        var bestD2 = -1.0;
        var bestX = 0.0;
        var bestY = 0.0;
        var bestEx = 0.0;
        var bestEy = 0.0;
        var bestLen2 = 0.0;
        for (var seg = 0; seg < segments; seg++) {
          final k = seg << 1;
          final ax = points[k];
          final ay = points[k + 1];
          final ex = points[k + 2] - ax;
          final ey = points[k + 3] - ay;
          final len2 = ex * ex + ey * ey;
          var t = ((ball.x - ax) * ex + (ball.y - ay) * ey) / len2;
          if (t < 0) {
            t = 0;
          } else if (t > 1) {
            t = 1;
          }
          final cx = ax + ex * t;
          final cy = ay + ey * t;
          final dx = ball.x - cx;
          final dy = ball.y - cy;
          final d2 = dx * dx + dy * dy;
          if (bestD2 < 0 || d2 < bestD2) {
            bestD2 = d2;
            bestX = cx;
            bestY = cy;
            bestEx = ex;
            bestEy = ey;
            bestLen2 = len2;
          }
        }
        if (bestD2 >= _wallCapsuleRadius2) break;
        double nx;
        double ny;
        if (bestD2 > _wallDegenerateD2) {
          final d = sqrt(bestD2);
          nx = (ball.x - bestX) / d;
          ny = (ball.y - bestY) / d;
        } else {
          // Ball center on the segment (or within rounding noise of its center
          // line): use the side it came from.
          final len = sqrt(bestLen2);
          nx = -bestEy / len;
          ny = bestEx / len;
          if (ball.vx * nx + ball.vy * ny > 0) {
            nx = -nx;
            ny = -ny;
          }
        }
        // Push out of penetration.
        ball.x = bestX + nx * wallCapsuleRadius;
        ball.y = bestY + ny * wallCapsuleRadius;
        if (reflected) continue;
        final vn = ball.vx * nx + ball.vy * ny;
        if (vn < 0) {
          _setDirection(ball, ball.vx - 2 * vn * nx, ball.vy - 2 * vn * ny);
          s.events.add(
            GameEvent(
              GameEventType.wallHit,
              player: ball.owner,
              x: ball.x,
              y: ball.y,
              ball: index,
            ),
          );
          if (ball.owner >= 0) {
            final p = s.players[ball.owner];
            p.score += 5 * p.multiplier;
          }
          reflected = true;
        }
      }
    }
  }

  /// Returns true when a paddle bounced [ball].
  ///
  /// Each ball is resolved on its own, so a paddle can bounce two balls in the
  /// same tick — a paddle the second ball would pass through is not a paddle —
  /// while each ball still bounces at most once per tick and off at most one
  /// paddle. Both bounces score, and both raise the same player's combo.
  static bool _collidePaddles(GameState s, Ball ball, int index) {
    final x = ball.x;
    final y = ball.y;
    if (x * ball.vx + y * ball.vy <= 0) return false; // moving inward
    final r2 = x * x + y * y;
    if (r2 < paddleContactRadius * paddleContactRadius) return false;
    final ballAngle = DetMath.atan2(y, x);
    for (var i = 0; i < s.players.length; i++) {
      final player = s.players[i];
      final offset = DetMath.angleDiff(ballAngle, player.paddle.angle);
      if (offset.abs() > paddleHalfWidth + paddleAngularSlack) continue;
      final r = sqrt(r2);
      final nx = -x / r; // inward normal
      final ny = -y / r;
      // Reflect about the inward normal.
      final vn = ball.vx * nx + ball.vy * ny;
      final rx = ball.vx - 2 * vn * nx;
      final ry = ball.vy - 2 * vn * ny;
      // English: rotate by -(offset / halfWidth) * englishFactor, so a hit
      // near an edge deflects the ball sideways like a convex paddle.
      final rot = -(offset / paddleHalfWidth) * englishFactor;
      final c = DetMath.cos(rot);
      final sn = DetMath.sin(rot);
      final dx = rx * c - ry * sn;
      final dy = rx * sn + ry * c;
      final m = sqrt(dx * dx + dy * dy);
      var ux = dx / m;
      var uy = dy / m;
      // Inward guarantee: rotate toward the normal until dot >= minInwardDot.
      if (ux * nx + uy * ny < minInwardDot) {
        final cross = nx * uy - ny * ux;
        final px = -ny; // counter-clockwise perpendicular of the normal
        final py = nx;
        if (cross >= 0) {
          ux = nx * minInwardDot + px * _minInwardSin;
          uy = ny * minInwardDot + py * _minInwardSin;
        } else {
          ux = nx * minInwardDot - px * _minInwardSin;
          uy = ny * minInwardDot - py * _minInwardSin;
        }
      }
      // Pull the ball back onto the contact radius.
      ball.x = x / r * paddleContactRadius;
      ball.y = y / r * paddleContactRadius;
      var speed = ball.speed * hitSpeedFactor;
      final cap = s.config.maxSpeed;
      if (speed > cap) speed = cap;
      ball.speed = speed;
      ball.vx = ux * speed;
      ball.vy = uy * speed;
      ball.owner = i;
      player.combo += 1;
      player.score += 10 * player.multiplier;
      s.events.add(
        GameEvent(
          GameEventType.paddleHit,
          player: i,
          x: ball.x,
          y: ball.y,
          ball: index,
        ),
      );
      return true;
    }
    return false;
  }

  /// Collects the pickups [ball] touches. A pickup belongs to the ball that
  /// reaches it, credited to that ball's owner (solo: always player 0), and it
  /// is removed on the first contact, so it can never pay twice. Balls are
  /// resolved in index order, so ball 0 takes a pickup both balls reach in the
  /// same substep.
  static void _collectPickups(GameState s, Ball ball, int index) {
    final pickups = s.pickups;
    var i = 0;
    while (i < pickups.length) {
      final k = pickups[i];
      final dx = k.x - ball.x;
      final dy = k.y - ball.y;
      if (dx * dx + dy * dy >= _pickupCollectRadius2) {
        i++;
        continue;
      }
      final owner = s.config.mode == GameMode.solo ? 0 : ball.owner;
      if (owner >= 0) {
        final p = s.players[owner];
        if (k.type == PickupType.heart) {
          if (p.lives < maxLives) p.lives += 1;
        } else {
          p.score += 100 * p.multiplier;
        }
      }
      s.events.add(
        GameEvent(
          GameEventType.pickup,
          player: owner,
          x: k.x,
          y: k.y,
          pickup: k.type,
          ball: index,
        ),
      );
      pickups.removeAt(i);
    }
  }

  /// Returns true when [ball] escaped (the rally is over).
  ///
  /// An escape costs a life and ends the rally for **every** ball: they are all
  /// recalled to the origin and the next serve launches them together. Two
  /// balls therefore cost exactly what one ball costs — one life per escape —
  /// and a two-ball game never degrades into a one-ball game halfway through a
  /// life. It also keeps the state machine of the one-ball game untouched: one
  /// escape, one life, one serve.
  static bool _checkEscape(GameState s, Ball ball, int index) {
    if (ball.x * ball.x + ball.y * ball.y <= _escapeRadius2) return false;
    final duel = s.config.mode == GameMode.duel;
    // sin(angle) < 0  <=>  y < 0: bottom half belongs to player 0.
    final loser = duel ? (ball.y < 0 ? 0 : 1) : 0;
    final p = s.players[loser];
    p.lives -= 1;
    p.combo = 0;
    s.events.add(
      GameEvent(
        GameEventType.lifeLost,
        player: loser,
        x: ball.x,
        y: ball.y,
        ball: index,
      ),
    );
    if (p.lives <= 0) {
      s.phase = Phase.gameOver;
      s.winner = duel ? 1 - loser : -1;
      for (var i = 0; i < s.balls.length; i++) {
        final b = s.balls[i];
        b.active = false;
        b.x = 0;
        b.y = 0;
        b.vx = 0;
        b.vy = 0;
        b.speed = 0;
        b.owner = -1;
      }
      s.events.add(GameEvent(GameEventType.gameOver, player: s.winner));
    } else {
      // Duel: the next serve goes toward the player who lost the point.
      s.prepareServe(loser);
    }
    return true;
  }

  // -------------------------------------------------------------------- walls

  static void _updateWalls(GameState s) {
    final walls = s.walls;
    var i = 0;
    while (i < walls.length) {
      final w = walls[i];
      w.age += 1;
      if (w.age >= w.ttl) {
        s.events.add(
          GameEvent(GameEventType.wallExpire, x: w.centerX, y: w.centerY),
        );
        walls.removeAt(i);
      } else {
        i++;
      }
    }
    s.nextWallIn -= 1;
    if (s.nextWallIn <= 0) {
      if (walls.length < maxWalls(s.tick)) _spawnWall(s);
      final seconds = s.tick < 30 * tickRate
          ? s.rng.nextRange(7, 9)
          : s.rng.nextRange(4, 6);
      s.nextWallIn = (seconds * tickRate).round();
    }
  }

  /// Draws one wall (SPEC §2.3). Per attempt, in this order: center radius,
  /// center angle, orientation, path length, shape and — for a bent or curved
  /// wall — its one shape parameter. The placement rules are then checked
  /// against the finished polyline, so a shaped wall has to clear the balls, the
  /// serve point and its neighbours along its whole length, not just along a
  /// chord, and no two walls may come within [wallMinGap] of each other.
  static void _spawnWall(GameState s) {
    final rng = s.rng;
    for (var attempt = 0; attempt < maxSpawnAttempts; attempt++) {
      final radius = wallSpawnRadius * sqrt(rng.nextDouble());
      final theta = rng.nextRange(0, DetMath.tau);
      final cx = radius * DetMath.cos(theta);
      final cy = radius * DetMath.sin(theta);
      final phi = rng.nextRange(0, DetMath.tau);
      final length = rng.nextRange(wallMinLength, wallMaxLength);
      final roll = rng.nextDouble();
      final WallShape shape;
      double parameter = 0;
      if (roll < wallStraightChance) {
        shape = WallShape.straight;
      } else if (roll < wallStraightChance + wallBentChance) {
        shape = WallShape.bent;
        parameter = rng.nextRange(wallBentMinAngle, wallBentMaxAngle);
      } else {
        shape = WallShape.curved;
        parameter = rng.nextRange(wallCurveMinSweep, wallCurveMaxSweep);
      }
      final points = wallPoints(shape, cx, cy, phi, length, parameter);
      var ok = true;
      for (var i = 0; i < s.balls.length; i++) {
        final ball = s.balls[i];
        if (_polylineDist2(points, ball.x, ball.y) <
            wallMinDistFromBall * wallMinDistFromBall) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      // The serve point counts too: every serve puts the balls back at the
      // origin, and a wall covering it would serve them from inside solid
      // geometry. Walls spawned during the serve pause are already kept clear
      // by the check above (the balls wait at the origin), so this only makes
      // the rule independent of the phase the wall spawned in.
      if (_polylineDist2(points, 0, 0) <
          wallMinDistFromServePoint * wallMinDistFromServePoint) {
        continue;
      }
      for (var i = 0; i < s.walls.length; i++) {
        final w = s.walls[i];
        final dx = w.centerX - cx;
        final dy = w.centerY - cy;
        if (dx * dx + dy * dy <
            wallMinDistBetweenCenters * wallMinDistBetweenCenters) {
          ok = false;
          break;
        }
        if (!_polylinesApart(points, w.points, wallMinGap)) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final ttl =
          wallMinLifetime + rng.nextInt(wallMaxLifetime - wallMinLifetime + 1);
      s.walls.add(Wall(id: s.nextId, shape: shape, points: points, ttl: ttl));
      s.nextId += 1;
      s.events.add(GameEvent(GameEventType.wallSpawn, x: cx, y: cy));
      return;
    }
  }

  /// The vertices of a wall shape, as a flat `[x0, y0, x1, y1, …]` list.
  ///
  /// [length] is the path length for every shape, and every vertex lands within
  /// `length / 2` of ([cx], [cy]) — so no shape reaches farther from its center
  /// than the straight wall of the same length always did, and the spawn
  /// distances keep the clearance they were chosen for.
  ///
  /// [angle] orients the wall: the direction of a straight wall, the bisector a
  /// bent wall opens toward, the tangent at the midpoint of a curve. Curves
  /// always bend to the left of [angle]; since [angle] is drawn uniformly, that
  /// is the same family of shapes as bending either way.
  ///
  /// [parameter] is the interior angle of a bent wall's joint or the angle a
  /// curve sweeps; [WallShape.straight] ignores it.
  static List<double> wallPoints(
    WallShape shape,
    double cx,
    double cy,
    double angle,
    double length,
    double parameter,
  ) {
    final half = length * 0.5;
    switch (shape) {
      case WallShape.straight:
        final hx = DetMath.cos(angle) * half;
        final hy = DetMath.sin(angle) * half;
        return <double>[cx - hx, cy - hy, cx + hx, cy + hy];
      case WallShape.bent:
        // Two arms of length/2 from the joint, `parameter` radians apart.
        final a1 = angle + parameter * 0.5;
        final a2 = angle - parameter * 0.5;
        return <double>[
          cx + DetMath.cos(a1) * half,
          cy + DetMath.sin(a1) * half,
          cx,
          cy,
          cx + DetMath.cos(a2) * half,
          cy + DetMath.sin(a2) * half,
        ];
      case WallShape.curved:
        // Arc of radius length / sweep, centered on (cx, cy) along its own
        // length: vertex i sits at the arc angle (i / n - 1/2) * sweep from the
        // midpoint, so the middle vertex is exactly (cx, cy).
        final radius = length / parameter;
        final sinAngle = DetMath.sin(angle);
        final cosAngle = DetMath.cos(angle);
        final points = List<double>.filled((wallCurveSegments + 1) << 1, 0);
        for (var i = 0; i <= wallCurveSegments; i++) {
          final a = angle + (i / wallCurveSegments - 0.5) * parameter;
          final k = i << 1;
          points[k] = cx + radius * (DetMath.sin(a) - sinAngle);
          points[k + 1] = cy + radius * (cosAngle - DetMath.cos(a));
        }
        return points;
    }
  }

  /// Squared distance from point (px, py) to segment (x1, y1)-(x2, y2).
  static double _segmentDist2(
    double x1,
    double y1,
    double x2,
    double y2,
    double px,
    double py,
  ) {
    final ex = x2 - x1;
    final ey = y2 - y1;
    final len2 = ex * ex + ey * ey;
    var t = len2 > 0 ? ((px - x1) * ex + (py - y1) * ey) / len2 : 0.0;
    if (t < 0) {
      t = 0;
    } else if (t > 1) {
      t = 1;
    }
    final dx = px - (x1 + ex * t);
    final dy = py - (y1 + ey * t);
    return dx * dx + dy * dy;
  }

  /// Squared distance from point (px, py) to a flat vertex list — the smallest
  /// over its segments.
  static double _polylineDist2(List<double> points, double px, double py) {
    var best = -1.0;
    for (var k = 0; k + 3 < points.length; k += 2) {
      final d2 = _segmentDist2(
        points[k],
        points[k + 1],
        points[k + 2],
        points[k + 3],
        px,
        py,
      );
      if (best < 0 || d2 < best) best = d2;
    }
    return best;
  }

  /// Squared distance from point (px, py) to [wall]'s polyline.
  static double wallDist2(Wall wall, double px, double py) =>
      _polylineDist2(wall.points, px, py);

  /// True when no point of polyline [a] comes within [min] of polyline [b].
  ///
  /// In 2D the closest pair of two segments that do not cross always includes an
  /// endpoint of one of them, so four point-to-segment distances plus a crossing
  /// test are exact — and, being squared, need no `sqrt`.
  static bool _polylinesApart(List<double> a, List<double> b, double min) {
    final min2 = min * min;
    for (var i = 0; i + 3 < a.length; i += 2) {
      final ax = a[i];
      final ay = a[i + 1];
      final bx = a[i + 2];
      final by = a[i + 3];
      for (var j = 0; j + 3 < b.length; j += 2) {
        final cx = b[j];
        final cy = b[j + 1];
        final dx = b[j + 2];
        final dy = b[j + 3];
        if (_segmentsCross(ax, ay, bx, by, cx, cy, dx, dy)) return false;
        if (_segmentDist2(ax, ay, bx, by, cx, cy) < min2) return false;
        if (_segmentDist2(ax, ay, bx, by, dx, dy) < min2) return false;
        if (_segmentDist2(cx, cy, dx, dy, ax, ay) < min2) return false;
        if (_segmentDist2(cx, cy, dx, dy, bx, by) < min2) return false;
      }
    }
    return true;
  }

  /// Sign of the cross product (b - a) × (c - a).
  static double _cross(
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
  ) => (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);

  /// True when segments a-b and c-d properly cross. Touching and collinear
  /// cases return false and are caught by the endpoint distances instead.
  static bool _segmentsCross(
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
    double dx,
    double dy,
  ) {
    final c1 = _cross(ax, ay, bx, by, cx, cy);
    final c2 = _cross(ax, ay, bx, by, dx, dy);
    final c3 = _cross(cx, cy, dx, dy, ax, ay);
    final c4 = _cross(cx, cy, dx, dy, bx, by);
    return (c1 > 0) != (c2 > 0) && (c3 > 0) != (c4 > 0);
  }

  // ------------------------------------------------------------------ pickups

  static void _updatePickups(GameState s) {
    final pickups = s.pickups;
    var i = 0;
    while (i < pickups.length) {
      final k = pickups[i];
      k.ttl -= 1;
      if (k.ttl <= 0) {
        s.events.add(
          GameEvent(GameEventType.pickupExpire, x: k.x, y: k.y, pickup: k.type),
        );
        pickups.removeAt(i);
      } else {
        i++;
      }
    }
    s.nextPickupIn -= 1;
    if (s.nextPickupIn <= 0) {
      if (pickups.length < maxPickups) _spawnPickup(s);
      s.nextPickupIn = (s.rng.nextRange(5, 8) * tickRate).round();
    }
  }

  static void _spawnPickup(GameState s) {
    final rng = s.rng;
    for (var attempt = 0; attempt < maxSpawnAttempts; attempt++) {
      final radius = pickupSpawnRadius * sqrt(rng.nextDouble());
      final theta = rng.nextRange(0, DetMath.tau);
      final x = radius * DetMath.cos(theta);
      final y = radius * DetMath.sin(theta);
      var ok = true;
      for (var i = 0; i < s.balls.length; i++) {
        final ball = s.balls[i];
        final bx = x - ball.x;
        final by = y - ball.y;
        if (bx * bx + by * by < pickupMinDistFromBall * pickupMinDistFromBall) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      for (var i = 0; i < s.pickups.length; i++) {
        final k = s.pickups[i];
        final dx = k.x - x;
        final dy = k.y - y;
        if (dx * dx + dy * dy <
            pickupMinDistBetweenPickups * pickupMinDistBetweenPickups) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      for (var i = 0; i < s.walls.length; i++) {
        if (_polylineDist2(s.walls[i].points, x, y) <
            pickupMinDistFromWall * pickupMinDistFromWall) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      var needsHeart = false;
      for (var i = 0; i < s.players.length; i++) {
        if (s.players[i].lives < maxLives) {
          needsHeart = true;
          break;
        }
      }
      final type = needsHeart && rng.nextDouble() < 0.25
          ? PickupType.heart
          : PickupType.star;
      s.pickups.add(Pickup(id: s.nextId, type: type, x: x, y: y));
      s.nextId += 1;
      return;
    }
  }
}
