/// Deterministic scripted inputs ("bots") for tests, tools and end-to-end
/// checks. Pure (only [DetMath] and `sqrt`) so the same inputs are produced
/// on every platform.
library;

import 'dart:math' show sqrt;

import 'constants.dart';
import 'det_math.dart';
import 'input.dart';
import 'model.dart';

class ScriptedInput {
  ScriptedInput._();

  /// Angle at which [b], continuing in a straight line, crosses the paddle
  /// ring; [b]'s current angle when it is already outside the ring or moving
  /// away from it; null while it is inactive.
  static double? ballCrossingAngle(Ball b) {
    if (!b.active) return null;
    final a = b.vx * b.vx + b.vy * b.vy;
    if (a <= 0) return DetMath.atan2(b.y, b.x);
    final half = b.x * b.vx + b.y * b.vy; // b / 2 of the quadratic
    final c = b.x * b.x + b.y * b.y - paddleRing * paddleRing;
    final disc = half * half - a * c;
    if (disc < 0) return DetMath.atan2(b.y, b.x);
    final t = (-half + sqrt(disc)) / a;
    if (t < 0) return DetMath.atan2(b.y, b.x);
    return DetMath.atan2(b.y + b.vy * t, b.x + b.vx * t);
  }

  /// Ticks until [b] reaches the paddle ring, or a large value when it is not
  /// heading there (already outside, or moving away): how urgent the ball is.
  static double ballTimeToRing(Ball b) {
    final a = b.vx * b.vx + b.vy * b.vy;
    if (a <= 0) return _never;
    final half = b.x * b.vx + b.y * b.vy;
    final c = b.x * b.x + b.y * b.y - paddleRing * paddleRing;
    final disc = half * half - a * c;
    if (disc < 0) return _never;
    final t = (-half + sqrt(disc)) / a;
    return t < 0 ? _never : t;
  }

  /// Time stamp of a ball that is not on its way to the ring; far beyond any
  /// real crossing time (a ball crosses the unit arena in well under 4 s).
  static const double _never = 1000.0;

  /// The ball [player] should worry about first: of the active balls whose
  /// crossing falls in this player's half (every ball, in solo), the one that
  /// reaches the ring soonest; ties go to the lower index. Null when no ball is
  /// active, and — in a duel — the soonest ball overall when none is this
  /// player's problem, so the caller can still park sensibly.
  static Ball? urgentBall(GameState s, int player) {
    final balls = s.balls;
    if (balls.length == 1) return balls[0].active ? balls[0] : null;
    final duel = s.config.mode == GameMode.duel;
    Ball? best;
    var bestTime = 0.0;
    var bestMine = false;
    for (var i = 0; i < balls.length; i++) {
      final b = balls[i];
      if (!b.active) continue;
      final time = ballTimeToRing(b);
      var mine = true;
      if (duel) {
        final angle = ballCrossingAngle(b);
        final bottom = angle != null && DetMath.sin(angle) < 0;
        mine = player == 0 ? bottom : !bottom;
      }
      if (best == null ||
          (mine && !bestMine) ||
          (mine == bestMine && time < bestTime)) {
        best = b;
        bestTime = time;
        bestMine = mine;
      }
    }
    return best;
  }

  /// Angle at which the ball [player] must deal with crosses the paddle ring;
  /// null while no ball is active. With one ball this is that ball's crossing.
  static double? predictedCrossingAngle(GameState s, [int player = 0]) {
    final ball = urgentBall(s, player);
    return ball == null ? null : ballCrossingAngle(ball);
  }

  /// Steers [player]'s paddle toward the predicted crossing point. In duel
  /// the paddle returns to the center of its own half while the ball heads
  /// for the opponent's half. [PlayerInput.none] while no ball is active.
  static PlayerInput aimAtBall(GameState s, int player) {
    final angle = predictedCrossingAngle(s, player);
    if (angle == null) return PlayerInput.none;
    if (s.config.mode == GameMode.duel) {
      final bottom = DetMath.sin(angle) < 0;
      final mine = player == 0 ? bottom : !bottom;
      if (!mine) {
        return PlayerInput.aimAngle(
          player == 0 ? bottomCenterAngle : topCenterAngle,
        );
      }
    }
    return PlayerInput.aimAngle(angle);
  }

  /// Moves the paddle to the point opposite the predicted crossing so the
  /// ball escapes as soon as possible (useful to end a game quickly).
  static PlayerInput avoidBall(GameState s, int player) {
    final angle = predictedCrossingAngle(s, player);
    if (angle == null) return PlayerInput.none;
    if (s.config.mode == GameMode.duel) {
      final lo = player == 0 ? DetMath.pi + paddleHalfWidth : paddleHalfWidth;
      final hi = player == 0
          ? DetMath.tau - paddleHalfWidth
          : DetMath.pi - paddleHalfWidth;
      // Go to whichever end of the range is farther from the crossing.
      final dLo = DetMath.angleDiff(lo, angle).abs();
      final dHi = DetMath.angleDiff(hi, angle).abs();
      return PlayerInput.aimAngle(dLo >= dHi ? lo : hi);
    }
    return PlayerInput.aimAngle(angle + DetMath.pi);
  }
}
