/// Shared helpers for the core tests (tests may use dart:math freely; only the
/// simulation itself is restricted to deterministic arithmetic).
library;

import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

/// Matches a number in the inclusive range [min, max].
Matcher inRange(num min, num max) =>
    allOf(greaterThanOrEqualTo(min), lessThanOrEqualTo(max));

/// A state already in the playing phase with every ball active at the origin
/// and no wall/pickup spawns scheduled for a very long time.
GameState playingState({
  GameMode mode = GameMode.solo,
  int seed = 1,
  int ballCount = 1,
}) {
  final s = GameState.initial(
    GameConfig(mode: mode, seed: seed, ballCount: ballCount),
  );
  s.phase = Phase.playing;
  s.serveTimer = 0;
  s.nextWallIn = 1 << 30;
  s.nextPickupIn = 1 << 30;
  for (final b in s.balls) {
    b.active = true;
  }
  return s;
}

/// Places ball [index] at (x, y) moving along [angle] (radians) at [speed].
void launchBall(
  GameState s,
  double x,
  double y,
  double angle,
  double speed, {
  int index = 0,
}) {
  final b = s.balls[index];
  b.x = x;
  b.y = y;
  b.speed = speed;
  b.vx = math.cos(angle) * speed;
  b.vy = math.sin(angle) * speed;
  b.active = true;
}

/// Parks ball [index] at the origin, inactive, so a two-ball test can look at
/// one ball at a time.
void parkBall(GameState s, int index) {
  final b = s.balls[index];
  b.x = 0;
  b.y = 0;
  b.vx = 0;
  b.vy = 0;
  b.active = false;
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

/// Distance of ball [index] from the arena center.
double ballDistance(GameState s, [int index = 0]) =>
    dist(0, 0, s.balls[index].x, s.balls[index].y);

/// Distance from (px, py) to [w]'s polyline — the smallest over its segments.
double wallDistance(Wall w, double px, double py) {
  var best = double.infinity;
  for (var i = 0; i < w.segmentCount; i++) {
    final d = segmentDistance(
      w.pointX(i),
      w.pointY(i),
      w.pointX(i + 1),
      w.pointY(i + 1),
      px,
      py,
    );
    if (d < best) best = d;
  }
  return best;
}

/// Total path length of [w] (the sum of its segment lengths).
double wallLength(Wall w) {
  var total = 0.0;
  for (var i = 0; i < w.segmentCount; i++) {
    total += dist(w.pointX(i), w.pointY(i), w.pointX(i + 1), w.pointY(i + 1));
  }
  return total;
}

/// Farthest any vertex of [w] sits from its center.
double wallFootprint(Wall w) {
  var best = 0.0;
  for (var i = 0; i < w.pointCount; i++) {
    final d = dist(w.centerX, w.centerY, w.pointX(i), w.pointY(i));
    if (d > best) best = d;
  }
  return best;
}

/// Smallest distance between the polylines of [a] and [b] (0 when they cross),
/// sampled finely enough for an assertion about wall separation.
double wallGap(Wall a, Wall b) {
  var best = double.infinity;
  for (final pair in [
    [a, b],
    [b, a],
  ]) {
    final u = pair[0];
    final v = pair[1];
    for (var i = 0; i < u.segmentCount; i++) {
      for (var step = 0; step <= 16; step++) {
        final f = step / 16;
        final x = u.pointX(i) + (u.pointX(i + 1) - u.pointX(i)) * f;
        final y = u.pointY(i) + (u.pointY(i + 1) - u.pointY(i)) * f;
        final d = wallDistance(v, x, y);
        if (d < best) best = d;
      }
    }
  }
  return best;
}

/// A solid wall of [shape] built by the simulation's own shape builder.
Wall shapedWall({
  required WallShape shape,
  double cx = 0,
  double cy = 0,
  double angle = 0,
  double length = 0.4,
  double parameter = 0,
  int id = 1,
  int ttl = 1 << 20,
  int age = wallFadeTicks,
}) => Wall(
  id: id,
  shape: shape,
  points: Simulation.wallPoints(shape, cx, cy, angle, length, parameter),
  ttl: ttl,
  age: age,
);

/// Places ball [index] on the ring [radius] at [angle], moving straight outward
/// (so its angle does not change before it reaches the paddle).
void launchRadial(
  GameState s,
  double angle,
  double speed,
  double radius, {
  int index = 0,
}) {
  launchBall(
    s,
    math.cos(angle) * radius,
    math.sin(angle) * radius,
    angle,
    speed,
    index: index,
  );
}
