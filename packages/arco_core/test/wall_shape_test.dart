// Wall shapes: geometry, readability, collision and spawn rules (SPEC §2.3).
//
// A wall is an open polyline collided as one capsule per consecutive pair of
// vertices. Three places in such a chain could leak a ball at full speed — the
// joint between two segments, the concave side of a joint, and the inside of a
// curve — and each gets its own hammering below, on top of the arithmetic proof
// that no substep is long enough to cross any capsule at all.
import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// The shape parameter range that goes with [shape] (nothing, for a straight
/// wall); the samplers draw uniformly inside it.
(double, double) parameterRange(WallShape shape) => switch (shape) {
  WallShape.straight => (0, 0),
  WallShape.bent => (wallBentMinAngle, wallBentMaxAngle),
  WallShape.curved => (wallCurveMinSweep, wallCurveMaxSweep),
};

/// Every (length, parameter) pair a shape can be spawned with, on a grid.
Iterable<(double, double)> shapeGrid(WallShape shape, {int steps = 12}) sync* {
  final (lo, hi) = parameterRange(shape);
  for (var i = 0; i <= steps; i++) {
    final length = wallMinLength + (wallMaxLength - wallMinLength) * i / steps;
    for (var j = 0; j <= steps; j++) {
      yield (length, lo + (hi - lo) * j / steps);
    }
  }
}

/// A random wall of [shape] somewhere near the middle of the arena, with a
/// length and shape parameter drawn from the spawnable ranges.
Wall randomWall(WallShape shape, math.Random rnd, {double spread = 0.6}) {
  final (lo, hi) = parameterRange(shape);
  return shapedWall(
    shape: shape,
    cx: (rnd.nextDouble() - 0.5) * spread,
    cy: (rnd.nextDouble() - 0.5) * spread,
    angle: rnd.nextDouble() * DetMath.tau,
    length: wallMinLength + rnd.nextDouble() * (wallMaxLength - wallMinLength),
    parameter: lo + rnd.nextDouble() * (hi - lo),
  );
}

/// Signed area of the triangle (a, b, c); its sign says which side of a-b the
/// point c is on.
double side(double ax, double ay, double bx, double by, double cx, double cy) =>
    (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);

/// True when the segment p→q crosses the interior of segment a→b — the only
/// way a ball can get from one side of a wall to the other.
bool crossesSegment(
  double px,
  double py,
  double qx,
  double qy,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final d1 = side(ax, ay, bx, by, px, py);
  final d2 = side(ax, ay, bx, by, qx, qy);
  final d3 = side(px, py, qx, qy, ax, ay);
  final d4 = side(px, py, qx, qy, bx, by);
  return (d1 > 0) != (d2 > 0) && (d3 > 0) != (d4 > 0);
}

/// Unit vector from the joint (or arc midpoint) of [w] into its concave side —
/// the inside of the V or of the cup. Zero for a straight wall.
(double, double) concaveDirection(Wall w) {
  if (w.shape == WallShape.straight) return (0, 0);
  final mid = w.pointCount >> 1;
  if (w.shape == WallShape.bent) {
    // The bisector of the two arms points into the wedge.
    final ax = w.pointX(0) - w.pointX(mid);
    final ay = w.pointY(0) - w.pointY(mid);
    final bx = w.pointX(2) - w.pointX(mid);
    final by = w.pointY(2) - w.pointY(mid);
    final dx = ax + bx;
    final dy = ay + by;
    final m = math.sqrt(dx * dx + dy * dy);
    return (dx / m, dy / m);
  }
  // A curve is concave toward its center of curvature, which from the midpoint
  // lies in the direction of the chord joining the arc's two ends.
  final dx = (w.pointX(0) + w.pointX(w.pointCount - 1)) * 0.5 - w.pointX(mid);
  final dy = (w.pointY(0) + w.pointY(w.pointCount - 1)) * 0.5 - w.pointY(mid);
  final m = math.sqrt(dx * dx + dy * dy);
  return (dx / m, dy / m);
}

/// The sweep a curved wall was built with, recovered from its vertices.
double sweepOf(Wall w) {
  final n = w.pointCount - 1;
  var total = 0.0;
  for (var i = 0; i < n - 1; i++) {
    final a = math.atan2(
      w.pointY(i + 1) - w.pointY(i),
      w.pointX(i + 1) - w.pointX(i),
    );
    final b = math.atan2(
      w.pointY(i + 2) - w.pointY(i + 1),
      w.pointX(i + 2) - w.pointX(i + 1),
    );
    total += DetMath.angleDiff(b, a).abs();
  }
  return total * n / (n - 1);
}

/// Where a hammering shot starts and what it aims at.
enum ShotOrigin {
  /// Anywhere in the arena, aimed at a random vertex: the everyday case.
  anywhere,

  /// Close to an interior vertex and aimed straight at it: a hit exactly on a
  /// joint, where two capsules meet.
  atJoint,

  /// Inside the wedge or the cup, aimed back at the joint: the concave side,
  /// where pushing out of one segment can push into its neighbour.
  concaveSide,

  /// Near a curve's center of curvature, fired in every direction: the inside
  /// of the arc, the only pocket the game can spawn.
  insideCurve,
}

/// What a hammering run observed.
class HammerReport {
  int shots = 0;
  int bounces = 0;
  int tunnels = 0;

  /// Draws whose start point could not be placed clear of the wall, and which
  /// were therefore not fired. A ball never starts inside a wall in a real game
  /// — a wall is never spawned on a ball and the collision never lets one in —
  /// so firing from inside would only measure how the push-out recovers from a
  /// state the simulation cannot reach.
  int skipped = 0;

  /// Deepest a ball was ever found inside a wall's capsule (<= 0 = never in).
  double worstPenetration = 0;

  @override
  String toString() =>
      'shots=$shots skipped=$skipped bounces=$bounces tunnels=$tunnels '
      'worstPenetration=$worstPenetration';
}

/// Fires [shots] balls at walls from [makeWall] at max speed and checks, every
/// tick, that the ball stayed outside the wall's capsule and never got to the
/// other side of any of its segments.
HammerReport hammer(
  Wall Function() makeWall,
  math.Random rnd, {
  int shots = 400,
  int ticks = 200,
  ShotOrigin origin = ShotOrigin.anywhere,
  double aimSpread = 0.25,
}) {
  final report = HammerReport();
  for (var shot = 0; shot < shots; shot++) {
    final wall = makeWall();
    final draw = _shot(wall, rnd, origin, aimSpread);
    if (draw == null) {
      report.skipped++;
      continue;
    }
    final (bx, by, aim) = draw;
    final s = playingState();
    s.walls.add(wall);
    launchBall(s, bx, by, aim, maxSpeedSolo);
    report.shots++;
    var prevX = s.balls[0].x;
    var prevY = s.balls[0].y;
    for (var t = 0; t < ticks; t++) {
      Simulation.step(s, noneInputs(s));
      if (s.phase != Phase.playing || !s.balls[0].active) break;
      final x = s.balls[0].x;
      final y = s.balls[0].y;
      final depth =
          Simulation.wallCapsuleRadius - wallDistance(wall, x, y) - 1e-9;
      if (depth > report.worstPenetration) report.worstPenetration = depth;
      expect(
        depth,
        lessThanOrEqualTo(0),
        reason:
            'shot $shot tick $t ended $depth inside the ${wall.shape.name} '
            'wall ${wall.points}',
      );
      for (var seg = 0; seg < wall.segmentCount; seg++) {
        if (crossesSegment(
          prevX,
          prevY,
          x,
          y,
          wall.pointX(seg),
          wall.pointY(seg),
          wall.pointX(seg + 1),
          wall.pointY(seg + 1),
        )) {
          report.tunnels++;
          fail(
            'shot $shot tick $t tunnelled through segment $seg of the '
            '${wall.shape.name} wall ${wall.points}: '
            '($prevX, $prevY) -> ($x, $y)',
          );
        }
      }
      if (s.events.any((e) => e.type == GameEventType.wallHit)) {
        report.bounces++;
      }
      prevX = x;
      prevY = y;
    }
  }
  return report;
}

/// Start point and aim angle of one hammering shot, or null when no start point
/// clear of the **whole** polyline could be drawn within [tries].
///
/// Clearing the whole polyline matters for a curve: an arc sweeping 149° curls
/// round far enough that a point comfortably clear of one joint can sit inside
/// the capsule of a segment three vertices away.
(double, double, double)? _shot(
  Wall wall,
  math.Random rnd,
  ShotOrigin origin,
  double aimSpread, {
  int tries = 100,
}) {
  final clear = Simulation.wallCapsuleRadius + 0.01;
  for (var attempt = 0; attempt < tries; attempt++) {
    double bx;
    double by;
    double targetX;
    double targetY;
    switch (origin) {
      case ShotOrigin.anywhere:
        final br = 0.85 * math.sqrt(rnd.nextDouble());
        final bt = rnd.nextDouble() * DetMath.tau;
        bx = br * math.cos(bt);
        by = br * math.sin(bt);
        final target = rnd.nextInt(wall.pointCount);
        targetX = wall.pointX(target);
        targetY = wall.pointY(target);
      case ShotOrigin.atJoint:
        // An interior vertex: the shared cap of two capsules.
        final joint = 1 + rnd.nextInt(wall.pointCount - 2);
        targetX = wall.pointX(joint);
        targetY = wall.pointY(joint);
        final a = rnd.nextDouble() * DetMath.tau;
        final r = clear + 0.02 + 0.25 * rnd.nextDouble();
        bx = targetX + r * math.cos(a);
        by = targetY + r * math.sin(a);
      case ShotOrigin.concaveSide:
        final mid = wall.pointCount >> 1;
        final (nx, ny) = concaveDirection(wall);
        targetX = wall.pointX(mid);
        targetY = wall.pointY(mid);
        final depth = clear + 0.005 + 0.2 * rnd.nextDouble();
        final sway = (rnd.nextDouble() - 0.5) * 0.12;
        bx = targetX + nx * depth - ny * sway;
        by = targetY + ny * depth + nx * sway;
      case ShotOrigin.insideCurve:
        // Around the center of curvature: the deepest point of the cup.
        final mid = wall.pointCount >> 1;
        final (nx, ny) = concaveDirection(wall);
        final radius = wallLength(wall) / sweepOf(wall);
        targetX = wall.pointX(mid);
        targetY = wall.pointY(mid);
        final f = 0.25 + 0.75 * rnd.nextDouble();
        final a = rnd.nextDouble() * DetMath.tau;
        final r = 0.1 * rnd.nextDouble();
        bx = targetX + nx * radius * f + r * math.cos(a);
        by = targetY + ny * radius * f + r * math.sin(a);
    }
    if (wallDistance(wall, bx, by) < clear) continue;
    final base = math.atan2(targetY - by, targetX - bx);
    return (bx, by, base + (rnd.nextDouble() - 0.5) * aimSpread);
  }
  return null;
}

/// A wall of [shape] at (0.3, 0) whose convex side faces the arena center, so a
/// ball fired outward along the x axis meets it head on.
Wall headOnWall(
  WallShape shape, {
  double parameter = 2.0,
  double length = 0.4,
  int ttl = 1 << 20,
  int age = wallFadeTicks,
}) => shapedWall(
  shape: shape,
  cx: 0.3,
  cy: 0,
  // The orientation that turns each shape's convex side inward: a straight wall
  // across the path, a bent wall opening away from the center, and a curve whose
  // center of curvature is behind it (a curve bends to the left of its angle).
  angle: headOnAngle(shape),
  length: length,
  parameter: shape == WallShape.straight ? 0 : parameter,
  ttl: ttl,
  age: age,
);

double headOnAngle(WallShape shape) => switch (shape) {
  WallShape.straight => DetMath.halfPi,
  WallShape.bent => 0.0,
  WallShape.curved => -DetMath.halfPi,
};

void main() {
  group('wall geometry', () {
    test('a straight wall is the two-point segment it always was', () {
      for (final (length, _) in shapeGrid(WallShape.straight)) {
        for (final angle in [0.0, 0.7, 2.5, 4.9]) {
          final points = Simulation.wallPoints(
            WallShape.straight,
            0.1,
            -0.2,
            angle,
            length,
            0,
          );
          // Bit for bit the pre-shape formula: center ± dir(angle) * length / 2.
          final half = length / 2;
          final hx = DetMath.cos(angle) * half;
          final hy = DetMath.sin(angle) * half;
          expect(points, [0.1 - hx, -0.2 - hy, 0.1 + hx, -0.2 + hy]);
        }
      }
    });

    test('a bent wall is two arms meeting at the center', () {
      for (final (length, parameter) in shapeGrid(WallShape.bent)) {
        final w = shapedWall(
          shape: WallShape.bent,
          cx: -0.1,
          cy: 0.2,
          angle: 1.3,
          length: length,
          parameter: parameter,
        );
        expect(w.pointCount, 3);
        expect(w.segmentCount, 2);
        // The joint is the middle vertex and the wall's center.
        expect(w.pointX(1), closeTo(-0.1, 1e-15));
        expect(w.pointY(1), closeTo(0.2, 1e-15));
        expect(w.centerX, w.pointX(1));
        expect(w.centerY, w.pointY(1));
        final a = dist(w.pointX(0), w.pointY(0), w.pointX(1), w.pointY(1));
        final b = dist(w.pointX(1), w.pointY(1), w.pointX(2), w.pointY(2));
        expect(a, closeTo(length / 2, 1e-6));
        expect(b, closeTo(length / 2, 1e-6));
        expect(wallLength(w), closeTo(length, 1e-6));
        // The interior angle at the joint is the drawn parameter.
        final toA = math.atan2(
          w.pointY(0) - w.pointY(1),
          w.pointX(0) - w.pointX(1),
        );
        final toB = math.atan2(
          w.pointY(2) - w.pointY(1),
          w.pointX(2) - w.pointX(1),
        );
        expect(DetMath.angleDiff(toA, toB).abs(), closeTo(parameter, 1e-6));
      }
    });

    test('a bent joint is never within 30 degrees of straight', () {
      // A bend the player cannot see is worse than no bend: the widest joint
      // still deviates from a straight line by more than half a radian.
      expect(DetMath.pi - wallBentMaxAngle, greaterThan(0.52));
      // And never sharp enough to trap a ball: a wedge of at least 90 degrees
      // always lets it back out.
      expect(wallBentMinAngle, greaterThan(DetMath.halfPi));
    });

    test('a curved wall sits on a circular arc of the drawn sweep', () {
      for (final (length, sweep) in shapeGrid(WallShape.curved)) {
        final w = shapedWall(
          shape: WallShape.curved,
          cx: 0.05,
          cy: 0.15,
          angle: -0.6,
          length: length,
          parameter: sweep,
        );
        expect(w.pointCount, wallCurveSegments + 1);
        expect(w.pointCount.isOdd, isTrue, reason: 'so a middle vertex exists');
        // The middle vertex is the arc midpoint and the wall's center.
        expect(w.pointX(wallCurveSegments ~/ 2), 0.05);
        expect(w.pointY(wallCurveSegments ~/ 2), 0.15);
        expect(w.centerX, 0.05);
        expect(w.centerY, 0.15);
        // Every vertex is the same distance (the radius) from one center of
        // curvature, one radius along the left normal of the midpoint tangent.
        final radius = length / sweep;
        final ox = 0.05 + radius * -math.sin(-0.6);
        final oy = 0.15 + radius * math.cos(-0.6);
        for (var i = 0; i < w.pointCount; i++) {
          expect(
            dist(ox, oy, w.pointX(i), w.pointY(i)),
            closeTo(radius, 1e-6),
            reason: 'vertex $i is off the arc',
          );
        }
        // The total turn along the polyline is the drawn sweep.
        expect(sweepOf(w), closeTo(sweep, 1e-5));
        // Arc length: the chords are a hair shorter than the true arc.
        expect(wallLength(w), lessThanOrEqualTo(length + 1e-9));
        expect(wallLength(w), greaterThan(length * 0.995));
      }
    });

    test('no shape reaches farther from its center than length / 2', () {
      for (final shape in WallShape.values) {
        for (final (length, parameter) in shapeGrid(shape)) {
          for (final angle in [0.0, 1.1, 3.3, 5.5]) {
            final w = shapedWall(
              shape: shape,
              cx: 0.2,
              cy: -0.1,
              angle: angle,
              length: length,
              parameter: parameter,
            );
            expect(
              wallFootprint(w),
              lessThanOrEqualTo(length / 2 + 1e-9),
              reason: '${shape.name} reaches too far',
            );
          }
        }
      }
    });

    test('$wallCurveSegments segments is the smallest count that is enough', () {
      // Two things have to hold for a segment count to be enough, and neither is
      // a matter of taste.
      //
      // 1. The chord polyline must not visibly sag below the arc it stands for.
      //    The budget is a fifth of the wall's half-thickness: below that the
      //    flattening is thinner than the line the renderer draws, so the player
      //    sees a curve rather than a chain of straight pieces.
      // 2. A ball must bounce off it roughly the way it would bounce off the
      //    true arc. A chord's normal is off the arc's normal by at most half the
      //    turn per segment, and a reflection doubles that, so the worst
      //    direction error is `sweep / segments`.
      //
      // Both are checked here against the whole spawnable (length, sweep) grid,
      // and both are shown to fail at half the segment count — which is what
      // makes 8 a derived number rather than a guess.
      final budget = wallHalfThickness / 5;
      var sag = 0.0;
      var sagAtHalf = 0.0;
      var directionError = 0.0;
      for (final (length, sweep) in shapeGrid(WallShape.curved, steps: 40)) {
        final radius = length / sweep;
        sag = math.max(
          sag,
          radius * (1 - math.cos(sweep / (2 * wallCurveSegments))),
        );
        sagAtHalf = math.max(
          sagAtHalf,
          radius * (1 - math.cos(sweep / (2 * (wallCurveSegments ~/ 2)))),
        );
        directionError = math.max(directionError, sweep / wallCurveSegments);
      }
      expect(sag, lessThan(budget), reason: 'worst sagitta $sag');
      expect(sag, lessThan(0.0025), reason: 'the documented 0.0023 bound');
      expect(
        sagAtHalf,
        greaterThan(budget),
        reason:
            'half as many segments would sag $sagAtHalf, over the $budget '
            'budget — the count is not arbitrary',
      );
      // 18.6 degrees at worst on the outgoing direction, and half the segments
      // would double it.
      expect(directionError, lessThan(0.33));
      expect(directionError * 2, greaterThan(0.33));
    });
  });

  group('no wall can leak', () {
    test('no substep is long enough to cross any capsule', () {
      // This is the whole no-tunnelling guarantee, and it holds for every shape
      // and every segment count at once.
      //
      // Lemma. Take a straight path p→q that crosses a wall's polyline at a
      // point c. Since c lies on the polyline, dist(p, c) >= dist(p, polyline),
      // and likewise for q. So if both endpoints are farther than the capsule
      // radius r from the polyline, both are farther than r from c, and the path
      // — which passes through c — is longer than 2r.
      //
      // Contrapositive: a path shorter than 2r either ends inside the capsule,
      // where the collision resolves it, or never reaches the other side. A
      // ball's substep is exactly such a path, so it is enough that the longest
      // substep the simulation can take is shorter than 2r.
      final worstTickDistance = maxSpeedSolo * dt;
      final substeps = math.min(
        maxSubsteps,
        math.max(1, (worstTickDistance / substepDistance).ceil()),
      );
      final worstSubstep = worstTickDistance / substeps;
      expect(worstSubstep, closeTo(0.013333, 1e-5));
      expect(
        worstSubstep,
        lessThan(2 * wallCollisionRadius),
        reason: 'a substep must be shorter than the capsule is thick',
      );
      // With room to spare: eight times over, so the guarantee survives a
      // faster ball or a thinner wall without being re-derived.
      expect(2 * wallCollisionRadius / worstSubstep, greaterThan(8));
      // The duel cap is lower still.
      expect(maxSpeedDuel, lessThan(maxSpeedSolo));
    });

    test('nothing else ever teleports a ball across a wall', () {
      // Two things move a ball other than its substep, and neither can carry it
      // through a wall.
      //
      // The wall push-out moves the ball along the outward normal from the
      // closest point of the polyline, which is the side the ball is already on,
      // so it never changes sides — the penetration checks in the hammering
      // tests below would catch it if it did.
      //
      // The paddle bounce pulls the ball back to the contact radius, and no wall
      // can be spawned close enough to the paddle ring to be in the way: a
      // wall's farthest possible surface stays well inside it.
      final farthestWallSurface =
          wallSpawnRadius + wallMaxLength / 2 + wallCollisionRadius;
      expect(farthestWallSurface, closeTo(0.83, 1e-9));
      expect(farthestWallSurface, lessThan(paddleHitRadius));
    });

    for (final shape in WallShape.values) {
      test('a ${shape.name} wall leaks nothing at maxSpeed (400 shots)', () {
        final rnd = math.Random(20260923 + shape.index);
        final report = hammer(() => randomWall(shape, rnd), rnd);
        expect(report.tunnels, 0);
        expect(report.worstPenetration, lessThanOrEqualTo(0));
        expect(
          report.bounces,
          greaterThan(250),
          reason: '${shape.name}: the shots must actually hit the wall',
        );
      });
    }

    for (final shape in [WallShape.bent, WallShape.curved]) {
      test('a hit on a ${shape.name} joint leaks nothing (400 shots)', () {
        // The first of the three places a chain of capsules could leak: the
        // shared vertex, where the ball is resolved against a cap rather than a
        // face and both neighbouring capsules claim it.
        final rnd = math.Random(70001 + shape.index);
        final report = hammer(
          () => randomWall(shape, rnd),
          rnd,
          origin: ShotOrigin.atJoint,
          aimSpread: 0.05,
        );
        expect(report.tunnels, 0);
        expect(report.worstPenetration, lessThanOrEqualTo(0));
        expect(report.bounces, greaterThan(300), reason: report.toString());
      });

      test('the concave side of a ${shape.name} joint leaks nothing', () {
        // The second place: inside the corner, where pushing out of the nearest
        // segment can move the ball into its neighbour's capsule. This is what
        // wallResolvePasses exists for.
        final rnd = math.Random(80001 + shape.index);
        final report = hammer(
          () => randomWall(shape, rnd),
          rnd,
          origin: ShotOrigin.concaveSide,
          aimSpread: 1.2,
        );
        expect(report.tunnels, 0);
        expect(report.worstPenetration, lessThanOrEqualTo(0));
        expect(report.bounces, greaterThan(200), reason: report.toString());
      });
    }

    test('the inside of a curve leaks nothing at maxSpeed (600 shots)', () {
      // The third place: the deepest pocket the game can spawn, fired at from
      // its own center of curvature in every direction.
      final rnd = math.Random(4242);
      final report = hammer(
        () => randomWall(WallShape.curved, rnd, spread: 0.4),
        rnd,
        shots: 600,
        origin: ShotOrigin.insideCurve,
        aimSpread: DetMath.tau,
      );
      expect(report.tunnels, 0);
      expect(report.worstPenetration, lessThanOrEqualTo(0));
      expect(report.bounces, greaterThan(200), reason: report.toString());
    });

    test('one resolve pass would not be enough on a concave joint', () {
      // Why wallResolvePasses is 3 and not 1: deep in the sharpest bend a point
      // lies inside both arms' capsules at once, so leaving the nearer one puts
      // the ball inside the other and a single pass would leave it embedded. One
      // step of the simulation must come out clean anyway.
      expect(wallResolvePasses, greaterThan(1));
      final w = shapedWall(
        shape: WallShape.bent,
        cx: 0,
        cy: 0,
        angle: DetMath.halfPi,
        length: wallMaxLength,
        parameter: wallBentMinAngle,
      );
      final (nx, ny) = concaveDirection(w);
      final px = nx * 0.03;
      final py = ny * 0.03;
      var inside = 0;
      for (var seg = 0; seg < w.segmentCount; seg++) {
        final d = segmentDistance(
          w.pointX(seg),
          w.pointY(seg),
          w.pointX(seg + 1),
          w.pointY(seg + 1),
          px,
          py,
        );
        if (d < Simulation.wallCapsuleRadius) inside++;
      }
      expect(inside, 2, reason: 'the probe point must overlap both arms');
      final s = playingState();
      s.walls.add(w);
      launchBall(s, px, py, math.atan2(-ny, -nx), maxSpeedSolo);
      Simulation.step(s, noneInputs(s));
      expect(
        wallDistance(w, s.balls[0].x, s.balls[0].y),
        greaterThanOrEqualTo(Simulation.wallCapsuleRadius - 1e-9),
        reason: 'one step must leave the ball outside both capsules',
      );
    });
  });

  group('shaped wall collision', () {
    test('every shape bounces a head-on ball straight back', () {
      for (final shape in WallShape.values) {
        final s = playingState();
        final w = headOnWall(shape);
        s.walls.add(w);
        s.balls[0].owner = 0;
        launchBall(s, 0, 0, 0, 0.6);
        final ticks = stepUntil(s, GameEventType.wallHit, maxTicks: 60);
        expect(ticks, greaterThan(0), reason: '${shape.name} did not bounce');
        // The convex side faces the center, so the closest feature is the
        // shape's apex and the ball returns the way it came.
        expect(s.balls[0].vx, closeTo(-0.6, 1e-9), reason: shape.name);
        expect(s.balls[0].vy, closeTo(0, 1e-9), reason: shape.name);
        // A wall bounce never changes the speed.
        expect(s.balls[0].speed, closeTo(0.6, 1e-12));
        expect(
          wallDistance(w, s.balls[0].x, s.balls[0].y),
          greaterThanOrEqualTo(Simulation.wallCapsuleRadius - 1e-9),
        );
        expect(s.players[0].score, wallHitScore);
        final hit = s.events.firstWhere((e) => e.type == GameEventType.wallHit);
        expect(hit.ball, 0);
        expect(hit.player, 0);
      }
    });

    test('a glancing hit on a bent arm deflects along the arm', () {
      // The same wall turned the other way round: the ball meets the outer face
      // of the near arm instead of the joint, and leaves forward and sideways
      // rather than straight back. This is the bounce the shape exists for.
      final w = shapedWall(
        shape: WallShape.bent,
        cx: 0.3,
        cy: 0,
        angle: DetMath.halfPi, // both arms sweep toward +y
        length: 0.4,
        parameter: 2.0,
      );
      final s = playingState();
      s.walls.add(w);
      launchBall(s, 0, 0, 0, 0.6);
      expect(stepUntil(s, GameEventType.wallHit, maxTicks: 60), greaterThan(0));
      expect(s.balls[0].vx, greaterThan(0), reason: 'deflected, not reversed');
      expect(s.balls[0].vy, lessThan(-0.4), reason: 'pushed away from the arm');
      expect(s.balls[0].speed, closeTo(0.6, 1e-12));
      expect(
        wallDistance(w, s.balls[0].x, s.balls[0].y),
        greaterThanOrEqualTo(Simulation.wallCapsuleRadius - 1e-9),
      );
    });

    test('a hit straight on a bent joint bounces off the joint', () {
      // Head-on into the joint from the convex side: the closest feature is the
      // shared vertex, so the ball comes back the way it came whatever angle the
      // two arms make.
      for (final parameter in [wallBentMinAngle, 1.9, 2.3, wallBentMaxAngle]) {
        final w = headOnWall(WallShape.bent, parameter: parameter);
        final s = playingState();
        s.walls.add(w);
        launchBall(s, 0, 0, 0, 0.9);
        expect(
          stepUntil(s, GameEventType.wallHit, maxTicks: 60),
          greaterThan(0),
          reason: 'parameter $parameter',
        );
        // The joint is the middle vertex, and it is what was hit.
        expect(
          dist(w.pointX(1), w.pointY(1), s.balls[0].x, s.balls[0].y),
          closeTo(Simulation.wallCapsuleRadius, 1e-9),
        );
        expect(s.balls[0].vx, closeTo(-0.9, 1e-9));
        expect(s.balls[0].vy.abs(), lessThan(1e-9), reason: 'straight back');
      }
    });

    test('a ball inside the concave side of a joint always gets out', () {
      // The corner the ball could get stuck in: fired into the inside of the
      // sharpest bend from close range, it must leave the wedge and stay out of
      // the wall while doing it.
      final rnd = math.Random(20260925);
      for (var trial = 0; trial < 120; trial++) {
        final w = shapedWall(
          shape: WallShape.bent,
          cx: 0,
          cy: 0,
          angle: DetMath.halfPi,
          length: wallMaxLength,
          parameter: wallBentMinAngle,
        );
        final s = playingState();
        s.walls.add(w);
        // Start on the bisector (inside the V) and aim back at the joint.
        final f = 0.06 + 0.18 * rnd.nextDouble();
        final aim =
            -DetMath.halfPi + (rnd.nextDouble() - 0.5) * wallBentMinAngle * 0.8;
        launchBall(s, 0, f, aim, maxSpeedSolo);
        var left = false;
        for (var t = 0; t < 180; t++) {
          Simulation.step(s, noneInputs(s));
          if (s.phase != Phase.playing || !s.balls[0].active) {
            left = true;
            break;
          }
          expect(
            wallDistance(w, s.balls[0].x, s.balls[0].y),
            greaterThanOrEqualTo(Simulation.wallCapsuleRadius - 1e-9),
            reason: 'trial $trial tick $t stuck inside the joint',
          );
          if (s.balls[0].y < -0.05 || ballDistance(s) > 0.6) {
            left = true;
            break;
          }
        }
        expect(left, isTrue, reason: 'trial $trial never left the wedge');
      }
    });

    test('a ball inside a curve bounces out of the cup', () {
      // The inside of a 149-degree arc is the deepest pocket the game can
      // spawn. The ball must bounce off it and leave through the mouth.
      final w = shapedWall(
        shape: WallShape.curved,
        cx: 0,
        cy: 0,
        angle: 0,
        length: wallMaxLength,
        parameter: wallCurveMaxSweep,
      );
      final s = playingState();
      s.walls.add(w);
      final radius = wallMaxLength / wallCurveMaxSweep;
      // Start at the center of curvature, fired at the arc.
      launchBall(s, 0, radius, -DetMath.halfPi + 0.2, maxSpeedSolo);
      var bounces = 0;
      var escapedCup = false;
      for (var t = 0; t < 600; t++) {
        Simulation.step(s, noneInputs(s));
        if (s.phase != Phase.playing || !s.balls[0].active) break;
        expect(
          wallDistance(w, s.balls[0].x, s.balls[0].y),
          greaterThanOrEqualTo(Simulation.wallCapsuleRadius - 1e-9),
          reason: 'tick $t inside the curve',
        );
        bounces += s.events
            .where((e) => e.type == GameEventType.wallHit)
            .length;
        if (dist(0, radius, s.balls[0].x, s.balls[0].y) > radius * 1.5) {
          escapedCup = true;
          break;
        }
      }
      expect(bounces, greaterThan(0));
      expect(escapedCup, isTrue, reason: 'the cup trapped the ball');
    });

    test('the mouth of the deepest curve is far wider than the ball', () {
      // Why no cup can trap anything: its opening is the chord
      // 2 R sin(sweep / 2), and even for the shortest, most strongly curved wall
      // the game can spawn that is several ball diameters across.
      final radius = wallMinLength / wallCurveMaxSweep;
      final mouth = 2 * radius * math.sin(wallCurveMaxSweep / 2);
      expect(mouth, greaterThan(4 * ballRadius));
    });

    test('a shaped wall does not collide anywhere inside a fade window', () {
      // 29 ticks at maxSpeed carry the ball from x = -0.3 clear past the far
      // side of the wall, and 29 is one tick short of wallFadeTicks, so a wall
      // that starts a fade window on the first of those ticks is still
      // transparent on the last one.
      const travelTicks = wallFadeTicks - 1;
      const ttl = 600;
      for (final shape in WallShape.values) {
        for (final (label, age) in [
          ('fading in', 0),
          ('fading out', ttl - wallFadeTicks),
        ]) {
          final s = playingState();
          final w = headOnWall(shape, ttl: ttl, age: age);
          s.walls.add(w);
          expect(w.solid, isFalse, reason: '${shape.name} $label');
          launchBall(s, -0.3, 0, 0, maxSpeedSolo);
          final seen = runCollecting(s, travelTicks).map((e) => e.type);
          expect(
            seen,
            isNot(contains(GameEventType.wallHit)),
            reason: '${shape.name} $label collided while transparent',
          );
          // The ball really did pass through where the wall stands.
          expect(s.balls[0].x, greaterThan(0.45));
          expect(s.walls.single.age, age + travelTicks);
          expect(s.walls.single.solid, isFalse);
        }
      }
    });

    test('a fade window opens and closes on the exact tick', () {
      // A ball parked inside the capsule and moving into it, so the only thing
      // deciding whether it bounces is Wall.solid.
      const ttl = 600;
      for (final (label, age, solidNow) in [
        ('last transparent tick of the fade-in', wallFadeTicks - 1, false),
        ('first solid tick', wallFadeTicks, true),
        ('last solid tick', ttl - wallFadeTicks - 1, true),
        ('first transparent tick of the fade-out', ttl - wallFadeTicks, false),
      ]) {
        final s = playingState();
        final w = headOnWall(WallShape.bent, ttl: ttl, age: age);
        s.walls.add(w);
        expect(w.solid, solidNow, reason: label);
        // 0.03 in front of the joint: inside the 0.055 capsule, moving into it.
        launchBall(s, 0.3 - 0.03, 0, 0, 0.6);
        Simulation.step(s, noneInputs(s));
        expect(
          s.events.any((e) => e.type == GameEventType.wallHit),
          solidNow,
          reason: label,
        );
        expect(w.age, age + 1);
      }
    });

    test('a wall is opaque exactly while it collides', () {
      final w = headOnWall(WallShape.curved, ttl: 600, age: 0);
      for (var age = 0; age < 600; age++) {
        w.age = age;
        expect(w.alpha == 1.0, w.solid, reason: "age $age");
        expect(w.alpha, inRange(0, 1));
      }
    });
  });

  group('shaped wall spawns', () {
    test('all three shapes spawn, in the designed mix', () {
      final counts = <WallShape, int>{
        for (final shape in WallShape.values) shape: 0,
      };
      var total = 0;
      for (var seed = 1; seed <= 12; seed++) {
        final s = GameState.initial(
          GameConfig(mode: GameMode.solo, seed: seed),
        );
        final inputs = <PlayerInput>[PlayerInput.none];
        final known = <int>{};
        for (var i = 0; i < 20000; i++) {
          inputs[0] = ScriptedInput.aimAtBall(s, 0);
          Simulation.step(s, inputs);
          for (final w in s.walls) {
            if (!known.add(w.id)) continue;
            counts[w.shape] = counts[w.shape]! + 1;
            total++;
          }
        }
      }
      expect(total, greaterThan(400));
      final straight = counts[WallShape.straight]! / total;
      final bent = counts[WallShape.bent]! / total;
      final curved = counts[WallShape.curved]! / total;
      expect(straight, closeTo(wallStraightChance, 0.05));
      expect(bent, closeTo(wallBentChance, 0.05));
      expect(curved, closeTo(1 - wallStraightChance - wallBentChance, 0.05));
    });

    test('every spawned wall obeys the placement rules along its length', () {
      // The chords of a curve are a hair shorter than the drawn arc length, so
      // the path length can undershoot wallMinLength by that much (0.42 %).
      final chordRatio =
          2 *
          wallCurveSegments *
          math.sin(wallCurveMaxSweep / (2 * wallCurveSegments)) /
          wallCurveMaxSweep;
      var spawns = 0;
      final shapesSeen = <WallShape>{};
      for (final mode in GameMode.values) {
        for (
          var ballCount = minBallCount;
          ballCount <= maxBallCount;
          ballCount++
        ) {
          for (var seed = 1; seed <= 4; seed++) {
            final s = GameState.initial(
              GameConfig(mode: mode, seed: seed, ballCount: ballCount),
            );
            final inputs = List<PlayerInput>.filled(
              s.players.length,
              PlayerInput.none,
            );
            final known = <int>{};
            for (var i = 0; i < 12000; i++) {
              for (var p = 0; p < inputs.length; p++) {
                inputs[p] = ScriptedInput.aimAtBall(s, p);
              }
              Simulation.step(s, inputs);
              for (final w in s.walls) {
                if (!known.add(w.id)) continue;
                spawns++;
                shapesSeen.add(w.shape);
                final where =
                    'wall ${w.id} (${w.shape.name}, $mode/$seed/$ballCount)';
                expect(w.age, 0, reason: where);
                expect(w.ttl, inRange(wallMinLifetime, wallMaxLifetime));
                expect(w.pointCount, switch (w.shape) {
                  WallShape.straight => 2,
                  WallShape.bent => 3,
                  WallShape.curved => wallCurveSegments + 1,
                }, reason: where);
                expect(
                  wallLength(w),
                  inRange(
                    wallMinLength * chordRatio - 1e-9,
                    wallMaxLength + 1e-9,
                  ),
                  reason: where,
                );
                // The shape parameter is inside the range it is drawn from.
                if (w.shape == WallShape.bent) {
                  final toA = math.atan2(
                    w.pointY(0) - w.pointY(1),
                    w.pointX(0) - w.pointX(1),
                  );
                  final toB = math.atan2(
                    w.pointY(2) - w.pointY(1),
                    w.pointX(2) - w.pointX(1),
                  );
                  expect(
                    DetMath.angleDiff(toA, toB).abs(),
                    inRange(wallBentMinAngle - 1e-6, wallBentMaxAngle + 1e-6),
                    reason: where,
                  );
                } else if (w.shape == WallShape.curved) {
                  expect(
                    sweepOf(w),
                    inRange(wallCurveMinSweep - 1e-4, wallCurveMaxSweep + 1e-4),
                    reason: where,
                  );
                }
                expect(
                  wallFootprint(w),
                  lessThanOrEqualTo(wallMaxLength / 2 + 1e-9),
                );
                expect(
                  dist(0, 0, w.centerX, w.centerY),
                  lessThanOrEqualTo(wallSpawnRadius + 1e-9),
                  reason: where,
                );
                // Every ball, not just the first one.
                for (final b in s.balls) {
                  expect(
                    wallDistance(w, b.x, b.y),
                    greaterThanOrEqualTo(wallMinDistFromBall - 1e-9),
                    reason: where,
                  );
                }
                expect(
                  wallDistance(w, 0, 0),
                  greaterThanOrEqualTo(wallMinDistFromServePoint - 1e-9),
                  reason: '$where covers the serve point',
                );
                for (final other in s.walls) {
                  if (identical(other, w)) continue;
                  expect(
                    dist(w.centerX, w.centerY, other.centerX, other.centerY),
                    greaterThanOrEqualTo(wallMinDistBetweenCenters - 1e-9),
                    reason: where,
                  );
                  expect(
                    wallGap(w, other),
                    greaterThanOrEqualTo(wallMinGap - 1e-9),
                    reason: '$where is tangled with wall ${other.id}',
                  );
                }
              }
            }
          }
        }
      }
      expect(spawns, greaterThan(300));
      expect(shapesSeen, WallShape.values.toSet());
    });

    test('two walls never leave a crack the ball cannot pass', () {
      // wallMinGap is measured between center lines, so the free corridor
      // between two walls' surfaces is exactly the ball's diameter: every gap
      // the player can see is a gap the ball can take, and none is narrower.
      expect(wallMinGap, 2 * wallCollisionRadius);
      expect(
        wallMinGap - 2 * wallHalfThickness,
        closeTo(2 * ballRadius, 1e-15),
      );
    });

    test('a wall that would tangle with an existing one is not placed', () {
      // The rule shapes made worth enforcing: two crossing straight lines still
      // read as two walls, two crossing curves do not.
      final s = playingState();
      final existing = <Wall>[
        for (var i = 0; i < 2; i++)
          shapedWall(
            shape: WallShape.curved,
            cx: 0.1,
            cy: 0.1,
            angle: i * DetMath.pi,
            length: wallMaxLength,
            parameter: wallCurveMaxSweep,
            id: 200 + i,
          ),
      ];
      var placed = 0;
      for (var round = 0; round < 400; round++) {
        s.walls
          ..clear()
          ..addAll(existing);
        s.tick = 60 * tickRate + round; // maxWalls == 3
        s.nextWallIn = 1;
        Simulation.step(s, noneInputs(s));
        for (final w in s.walls) {
          if (existing.any((e) => e.id == w.id)) continue;
          placed++;
          for (final e in existing) {
            expect(
              wallGap(w, e),
              greaterThanOrEqualTo(wallMinGap - 1e-9),
              reason: 'wall ${w.id} tangled with ${e.id}',
            );
          }
        }
      }
      expect(placed, greaterThan(0), reason: 'nothing was ever placed');
    });

    test('a spawn that cannot be placed is skipped, not forced', () {
      // A board crowded with walls that leave no room: the sampler tries
      // maxSpawnAttempts times, gives up, and still redraws its interval, so a
      // skipped spawn costs the game nothing but the wall.
      final s = playingState();
      for (var i = 0; i < 3; i++) {
        s.walls.add(
          shapedWall(
            shape: WallShape.straight,
            cx: 0,
            cy: 0,
            angle: i * DetMath.pi / 3,
            length: wallMaxLength,
            id: 100 + i,
          ),
        );
      }
      // The ball sits at the origin, so nothing can spawn near the center
      // either.
      s.nextWallIn = 1;
      final before = s.walls.length;
      final rngBefore = s.rng.toJson();
      Simulation.step(s, noneInputs(s));
      expect(s.walls.length, before, reason: 'no wall should fit');
      expect(s.nextWallIn, greaterThan(0), reason: 'the interval was redrawn');
      expect(s.rng.toJson(), isNot(rngBefore), reason: 'it did draw');
      expect(s.events.where((e) => e.type == GameEventType.wallSpawn), isEmpty);
    });

    test('a wall never covers the serve point', () {
      // Every serve puts the balls back at the origin, so a wall there would
      // serve them from inside solid geometry. The clearance is the capsule plus
      // a ball radius of margin, checked against the whole polyline.
      expect(
        wallMinDistFromServePoint,
        greaterThan(Simulation.wallCapsuleRadius),
      );
      final s = playingState();
      // The ball is parked far away, so only the serve-point rule can keep a
      // wall clear of the origin.
      launchBall(s, 0.85, 0, DetMath.halfPi, 0.6);
      var placed = 0;
      for (var round = 0; round < 600; round++) {
        s.walls.clear();
        s.nextWallIn = 1;
        Simulation.step(s, noneInputs(s));
        for (final w in s.walls) {
          placed++;
          expect(
            wallDistance(w, 0, 0),
            greaterThanOrEqualTo(wallMinDistFromServePoint - 1e-9),
            reason: 'wall ${w.id} (${w.shape.name}) covers the serve point',
          );
        }
      }
      expect(placed, greaterThan(300));
    });
  });

  group('wall serialization', () {
    test('a shaped wall round-trips through JSON', () {
      for (final shape in WallShape.values) {
        final w = shapedWall(
          shape: shape,
          cx: 0.1,
          cy: -0.2,
          angle: 2.2,
          length: 0.37,
          parameter: 2.1,
          id: 9,
          ttl: 700,
          age: 123,
        );
        final back = Wall.fromJson(w.toJson());
        expect(back.id, 9);
        expect(back.shape, shape);
        expect(back.ttl, 700);
        expect(back.age, 123);
        expect(back.points, w.points);
        expect(back.pointCount, w.pointCount);
        expect(back.segmentCount, w.segmentCount);
        expect(back.centerX, w.centerX);
        expect(back.centerY, w.centerY);
        expect(back.solid, w.solid);
        // The snapshot is the id, the shape, the two timers and the vertices.
        expect(w.toJson().length, 4 + w.points.length);
        expect(w.toJson().take(4), [9, shape.index, 123, 700]);
      }
    });

    test('a straight wall costs the same four numbers it always did', () {
      final w = Wall.segment(id: 1, x1: 0, y1: 0, x2: 0.3, y2: 0, ttl: 600);
      expect(w.shape, WallShape.straight);
      expect(w.pointCount, 2);
      expect(w.toJson(), [1, 0, 0, 600, 0.0, 0.0, 0.3, 0.0]);
      expect(w.centerX, closeTo(0.15, 1e-15));
      expect(w.centerY, 0);
    });

    test('the hash sees the shape and every vertex', () {
      final s = playingState();
      s.walls.add(shapedWall(shape: WallShape.bent, parameter: 2.0, id: 4));
      final base = s.hash();
      // Same vertices, different shape label: a renderer would draw it wrong,
      // so the hash has to notice.
      final relabelled = Wall(
        id: 4,
        shape: WallShape.curved,
        points: List<double>.of(s.walls[0].points),
        ttl: s.walls[0].ttl,
        age: s.walls[0].age,
      );
      s.walls[0] = relabelled;
      expect(s.hash(), isNot(base));
      // And every coordinate matters.
      final withShape = s.hash();
      for (var i = 0; i < relabelled.points.length; i++) {
        final saved = relabelled.points[i];
        relabelled.points[i] = saved + 1e-4;
        expect(s.hash(), isNot(withShape), reason: 'coordinate $i not hashed');
        relabelled.points[i] = saved;
      }
    });
  });
}
