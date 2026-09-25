/// Shared helpers for the core tests (tests may use dart:math freely; only the
/// simulation itself is restricted to deterministic arithmetic).
library;

import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

/// Matches a number in the inclusive range [min, max].
Matcher inRange(num min, num max) =>
    allOf(greaterThanOrEqualTo(min), lessThanOrEqualTo(max));

/// A state already in the playing phase with the ball active at the origin
/// and no wall/pickup spawns scheduled for a very long time.
GameState playingState({GameMode mode = GameMode.solo, int seed = 1}) {
  final s = GameState.initial(GameConfig(mode: mode, seed: seed));
  s.phase = Phase.playing;
  s.serveTimer = 0;
  s.nextWallIn = 1 << 30;
  s.nextPickupIn = 1 << 30;
  s.ball.active = true;
  return s;
}

/// Places the ball at (x, y) moving along [angle] (radians) at [speed].
void launchBall(GameState s, double x, double y, double angle, double speed) {
  final b = s.ball;
  b.x = x;
  b.y = y;
  b.speed = speed;
  b.vx = math.cos(angle) * speed;
  b.vy = math.sin(angle) * speed;
  b.active = true;
}

List<PlayerInput> noneInputs(GameState s) =>
    List<PlayerInput>.filled(s.players.length, PlayerInput.none);

/// Steps [s] until an event of [type] is emitted. Returns the number of steps
/// taken (including the one that produced the event) or -1 after [maxTicks].
int stepUntil(
  GameState s,
  GameEventType type, {
  int maxTicks = 600,
  List<PlayerInput>? inputs,
}) {
  final ins = inputs ?? noneInputs(s);
  for (var i = 1; i <= maxTicks; i++) {
    Simulation.step(s, ins);
    if (s.events.any((e) => e.type == type)) return i;
  }
  return -1;
}

/// Scripted bot: plays well for [playTicks] ticks, then keeps the paddle away
/// from the ball so the game ends quickly.
PlayerInput scriptedInput(GameState s, int player, int playTicks) =>
    s.tick < playTicks
    ? ScriptedInput.aimAtBall(s, player)
    : ScriptedInput.avoidBall(s, player);

/// Runs a whole solo game with [scriptedInput] and returns the final state
/// together with the recorded input log.
(GameState, InputLog) playRecordedSolo({
  required int seed,
  required int playTicks,
  int maxTicks = ReplayVerifier.maxTicks,
}) {
  final s = GameState.initial(GameConfig(mode: GameMode.solo, seed: seed));
  final log = InputLog();
  final inputs = <PlayerInput>[PlayerInput.none];
  while (s.phase != Phase.gameOver && s.tick < maxTicks) {
    final input = scriptedInput(s, 0, playTicks);
    log.record(s.tick, input);
    inputs[0] = input;
    Simulation.step(s, inputs);
  }
  return (s, log);
}

double dist(double x1, double y1, double x2, double y2) {
  final dx = x2 - x1;
  final dy = y2 - y1;
  return math.sqrt(dx * dx + dy * dy);
}

/// Distance from point (px, py) to segment (x1, y1)-(x2, y2).
double segmentDistance(
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
  var t = ((px - x1) * ex + (py - y1) * ey) / len2;
  t = t.clamp(0.0, 1.0);
  return dist(px, py, x1 + ex * t, y1 + ey * t);
}

/// Steps [s] for [ticks] ticks and returns every event emitted on the way.
/// [bot] supplies the input for each player when given.
List<GameEvent> runCollecting(
  GameState s,
  int ticks, {
  PlayerInput Function(GameState state, int player)? bot,
}) {
  final out = <GameEvent>[];
  final ins = List<PlayerInput>.filled(s.players.length, PlayerInput.none);
  for (var i = 0; i < ticks; i++) {
    if (bot != null) {
      for (var p = 0; p < ins.length; p++) {
        ins[p] = bot(s, p);
      }
    }
    Simulation.step(s, ins);
    out.addAll(s.events);
  }
  return out;
}

/// Distance of the ball from the arena center.
double ballDistance(GameState s) => dist(0, 0, s.ball.x, s.ball.y);

/// Places the ball on the ring [radius] at [angle], moving straight outward
/// (so its angle does not change before it reaches the paddle).
void launchRadial(GameState s, double angle, double speed, double radius) {
  launchBall(
    s,
    math.cos(angle) * radius,
    math.sin(angle) * radius,
    angle,
    speed,
  );
}
