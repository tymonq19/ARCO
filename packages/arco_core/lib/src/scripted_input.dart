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

  /// Angle at which the ball, continuing in a straight line, crosses the
  /// paddle ring; the ball's current angle when it is already outside the
  /// ring or moving away from it; null while the ball is inactive.
  static double? predictedCrossingAngle(GameState s) {
    final b = s.ball;
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

  /// Steers [player]'s paddle toward the predicted crossing point. In duel
  /// the paddle returns to the center of its own half while the ball heads
  /// for the opponent's half. [PlayerInput.none] while the ball is inactive.
  static PlayerInput aimAtBall(GameState s, int player) {
    final angle = predictedCrossingAngle(s);
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
    final angle = predictedCrossingAngle(s);
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
