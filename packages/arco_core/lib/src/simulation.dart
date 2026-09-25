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
  /// Order within a tick: paddles → serve timer / ball motion (sub-stepped:
  /// walls, paddles, pickups, escape) → wall timers → pickup timers →
  /// `tick += 1` → solo survival point.
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
      _moveBall(s);
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

  static void _serve(GameState s) {
    final ball = s.ball;
    final rng = s.rng;
    final speed = baseSpeed + 0.01 * (s.tick / tickRate);
    ball.speed = speed > maxServeSpeed ? maxServeSpeed : speed;
    int receiver;
    double angle;
    if (s.config.mode == GameMode.duel) {
      // During the serving phase `ball.owner` carries the receiving player
      // (drawn in GameState.initial, then the loser of the previous point).
      receiver = ball.owner >= 0 ? ball.owner : 0;
      final center = receiver == 0 ? bottomCenterAngle : topCenterAngle;
      angle = center + rng.nextRange(-serveSpread, serveSpread);
    } else {
      receiver = 0;
      angle = rng.nextRange(0, DetMath.tau);
    }
    ball.x = 0;
    ball.y = 0;
    ball.vx = DetMath.cos(angle) * ball.speed;
    ball.vy = DetMath.sin(angle) * ball.speed;
    ball.owner = -1;
    ball.active = true;
    s.phase = Phase.playing;
    s.serveTimer = 0;
    s.events.add(GameEvent(GameEventType.serve, player: receiver));
  }

  // --------------------------------------------------------------------- ball

  static void _moveBall(GameState s) {
    final ball = s.ball;
    if (!ball.active) return;
    var n = (ball.speed * dt / _substepLength).ceil();
    if (n < 1) n = 1;
    if (n > _maxSubsteps) n = _maxSubsteps;
    final h = dt / n;
    var bounced = false;
    for (var i = 0; i < n; i++) {
      ball.x += ball.vx * h;
      ball.y += ball.vy * h;
      _collideWalls(s);
      if (!bounced && _collidePaddles(s)) bounced = true;
      _collectPickups(s);
      if (_checkEscape(s)) return;
    }
  }

  static void _setDirection(Ball ball, double dx, double dy) {
    final m = sqrt(dx * dx + dy * dy);
    if (m > 0) {
      ball.vx = dx / m * ball.speed;
      ball.vy = dy / m * ball.speed;
    }
  }

  static void _collideWalls(GameState s) {
    final ball = s.ball;
    final walls = s.walls;
    for (var i = 0; i < walls.length; i++) {
      final w = walls[i];
      if (!w.solid) continue;
      final ex = w.x2 - w.x1;
      final ey = w.y2 - w.y1;
      final len2 = ex * ex + ey * ey;
      var t = ((ball.x - w.x1) * ex + (ball.y - w.y1) * ey) / len2;
      if (t < 0) {
        t = 0;
      } else if (t > 1) {
        t = 1;
      }
      final cx = w.x1 + ex * t;
      final cy = w.y1 + ey * t;
      final dx = ball.x - cx;
      final dy = ball.y - cy;
      final d2 = dx * dx + dy * dy;
      if (d2 >= _wallCapsuleRadius2) continue;
      double nx;
      double ny;
      if (d2 > _wallDegenerateD2) {
        final d = sqrt(d2);
        nx = dx / d;
        ny = dy / d;
      } else {
        // Ball center on the segment (or within rounding noise of its center
        // line): use the side it came from.
        final len = sqrt(len2);
        nx = -ey / len;
        ny = ex / len;
        if (ball.vx * nx + ball.vy * ny > 0) {
          nx = -nx;
          ny = -ny;
        }
      }
      // Push out of penetration.
      ball.x = cx + nx * wallCapsuleRadius;
      ball.y = cy + ny * wallCapsuleRadius;
      final vn = ball.vx * nx + ball.vy * ny;
      if (vn < 0) {
        _setDirection(ball, ball.vx - 2 * vn * nx, ball.vy - 2 * vn * ny);
        s.events.add(
          GameEvent(
            GameEventType.wallHit,
            player: ball.owner,
            x: ball.x,
            y: ball.y,
          ),
        );
        if (ball.owner >= 0) {
          final p = s.players[ball.owner];
          p.score += 5 * p.multiplier;
        }
      }
    }
  }

  /// Returns true when a paddle bounced the ball.
  static bool _collidePaddles(GameState s) {
    final ball = s.ball;
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
        GameEvent(GameEventType.paddleHit, player: i, x: ball.x, y: ball.y),
      );
      return true;
    }
    return false;
  }

  static void _collectPickups(GameState s) {
    final ball = s.ball;
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
        ),
      );
      pickups.removeAt(i);
    }
  }

  /// Returns true when the ball escaped (the point is over).
  static bool _checkEscape(GameState s) {
    final ball = s.ball;
    if (ball.x * ball.x + ball.y * ball.y <= _escapeRadius2) return false;
    final duel = s.config.mode == GameMode.duel;
    // sin(angle) < 0  <=>  y < 0: bottom half belongs to player 0.
    final loser = duel ? (ball.y < 0 ? 0 : 1) : 0;
    final p = s.players[loser];
    p.lives -= 1;
    p.combo = 0;
    s.events.add(
      GameEvent(GameEventType.lifeLost, player: loser, x: ball.x, y: ball.y),
    );
    if (p.lives <= 0) {
      s.phase = Phase.gameOver;
      s.winner = duel ? 1 - loser : -1;
      ball.active = false;
      ball.x = 0;
      ball.y = 0;
      ball.vx = 0;
      ball.vy = 0;
      ball.speed = 0;
      ball.owner = -1;
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
          GameEvent(
            GameEventType.wallExpire,
            x: (w.x1 + w.x2) / 2,
            y: (w.y1 + w.y2) / 2,
          ),
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

  static void _spawnWall(GameState s) {
    final rng = s.rng;
    final ball = s.ball;
    for (var attempt = 0; attempt < maxSpawnAttempts; attempt++) {
      final radius = wallSpawnRadius * sqrt(rng.nextDouble());
      final theta = rng.nextRange(0, DetMath.tau);
      final cx = radius * DetMath.cos(theta);
      final cy = radius * DetMath.sin(theta);
      final phi = rng.nextRange(0, DetMath.tau);
      final half = rng.nextRange(wallMinLength, wallMaxLength) / 2;
      final hx = DetMath.cos(phi) * half;
      final hy = DetMath.sin(phi) * half;
      final x1 = cx - hx;
      final y1 = cy - hy;
      final x2 = cx + hx;
      final y2 = cy + hy;
      if (_segmentDist2(x1, y1, x2, y2, ball.x, ball.y) <
          wallMinDistFromBall * wallMinDistFromBall) {
        continue;
      }
      // The serve point counts too: every serve puts the ball back at the
      // origin, and a wall covering it would serve the ball from inside solid
      // geometry. Walls spawned during the serve pause are already kept clear
      // by the check above (the ball waits at the origin), so this only makes
      // the rule independent of the phase the wall spawned in.
      if (_segmentDist2(x1, y1, x2, y2, 0, 0) <
          wallMinDistFromServePoint * wallMinDistFromServePoint) {
        continue;
      }
      var ok = true;
      for (var i = 0; i < s.walls.length; i++) {
        final w = s.walls[i];
        final dx = (w.x1 + w.x2) / 2 - cx;
        final dy = (w.y1 + w.y2) / 2 - cy;
        if (dx * dx + dy * dy <
            wallMinDistBetweenCenters * wallMinDistBetweenCenters) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final ttl =
          wallMinLifetime + rng.nextInt(wallMaxLifetime - wallMinLifetime + 1);
      s.walls.add(Wall(id: s.nextId, x1: x1, y1: y1, x2: x2, y2: y2, ttl: ttl));
      s.nextId += 1;
      s.events.add(GameEvent(GameEventType.wallSpawn, x: cx, y: cy));
      return;
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
    final ball = s.ball;
    for (var attempt = 0; attempt < maxSpawnAttempts; attempt++) {
      final radius = pickupSpawnRadius * sqrt(rng.nextDouble());
      final theta = rng.nextRange(0, DetMath.tau);
      final x = radius * DetMath.cos(theta);
      final y = radius * DetMath.sin(theta);
      final bx = x - ball.x;
      final by = y - ball.y;
      if (bx * bx + by * by < pickupMinDistFromBall * pickupMinDistFromBall) {
        continue;
      }
      var ok = true;
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
        final w = s.walls[i];
        if (_segmentDist2(w.x1, w.y1, w.x2, w.y2, x, y) <
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
