import 'dart:math' as math;
import 'dart:typed_data';

import 'package:arco_core/arco_core.dart';
import 'package:flutter/painting.dart';

import '../../app/game_theme.dart';

/// One short-lived spark. Particles live in a fixed pool inside [FxState] and
/// are recycled round-robin, so the renderer never allocates them per frame.
class Particle {
  double x = 0;
  double y = 0;
  double vx = 0;
  double vy = 0;

  /// Remaining lifetime in seconds; `<= 0` means the slot is free.
  double life = 0;
  double maxLife = 1;

  /// Radius in simulation units.
  double size = 0.01;

  /// Velocity damping per second.
  double drag = 2.5;
  Color color = const Color(0xFFFFFFFF);

  bool get alive => life > 0;

  /// 1 at birth, 0 at death.
  double get fade => maxLife <= 0 ? 0 : (life / maxLife).clamp(0.0, 1.0);
}

/// A floating "+120" above the spot where the points were scored.
class ScorePopup {
  double x = 0;
  double y = 0;
  double life = 0;
  double maxLife = 1;
  String label = '';
  Color color = const Color(0xFFFFFFFF);

  /// Laid out lazily by the painter and kept until the slot is reused.
  TextPainter? cache;

  /// Quantized opacity the [cache] was laid out for; -1 = no cache.
  int cacheBucket = -1;

  bool get alive => life > 0;
  double get fade => maxLife <= 0 ? 0 : (life / maxLife).clamp(0.0, 1.0);
}

/// Everything the renderer keeps **per ball**: the position it is actually drawn
/// at and the path it has flown.
///
/// A game has one or two balls (SPEC §2.3, `GameConfig.ballCount`), and each one
/// needs its own history — a single shared trail would stitch the two paths into
/// one zig-zag that belongs to neither ball. The ring buffer is allocated once
/// per slot and reused for the whole session.
class BallFx {
  /// x, y interleaved, oldest first once unwrapped by [trailX] / [trailY].
  final Float32List _trail = Float32List(FxState.trailLength * 2);
  int _count = 0;
  int _head = 0;

  /// Rendered position in simulation units (smoothed; see [follow]).
  double x = 0;
  double y = 0;

  /// True while this ball is in play and has a position worth drawing.
  bool live = false;

  int get trailCount => _count;

  /// Trail sample [i], 0 = oldest.
  double trailX(int i) => _trail[_indexOf(i) * 2];
  double trailY(int i) => _trail[_indexOf(i) * 2 + 1];

  int _indexOf(int i) =>
      (_head - _count + i + FxState.trailLength * 2) % FxState.trailLength;

  /// Follows [ball], optionally smoothing the correction a duel snapshot
  /// introduces, and feeds the trail. [smoothing] is the fraction of the
  /// remaining error taken per frame.
  void follow(Ball ball, {required bool smooth, required double smoothing}) {
    if (!ball.active) {
      live = false;
      x = ball.x;
      y = ball.y;
      _count = 0;
      return;
    }
    final dx = ball.x - x;
    final dy = ball.y - y;
    final far = dx * dx + dy * dy > 0.0625; // > 0.25 units: a serve or a snap
    if (!live || far || !smooth) {
      x = ball.x;
      y = ball.y;
      if (!live || far) _count = 0;
      live = true;
    } else {
      final k = smoothing.clamp(0.05, 1.0);
      x += dx * k;
      y += dy * k;
    }
    _push(x, y);
  }

  void _push(double px, double py) {
    _trail[_head * 2] = px;
    _trail[_head * 2 + 1] = py;
    _head = (_head + 1) % FxState.trailLength;
    if (_count < FxState.trailLength) _count++;
  }

  /// Places the ball at ([px], [py]) and feeds the trail, with no [Ball] to
  /// follow and nothing to smooth — for a source that runs its own motion (the
  /// decorative ball behind the main menu).
  void followPoint(double px, double py) {
    live = true;
    x = px;
    y = py;
    _push(px, py);
  }

  /// Drops the path but keeps the position (a life lost, a snap).
  void clearTrail() => _count = 0;

  void reset() {
    live = false;
    x = 0;
    y = 0;
    _count = 0;
    _head = 0;
  }
}

/// Client-only visual state that rides along with a [GameState]: one trail per
/// ball, particles, screen shake, hit flashes, floating score popups and the
/// countdown label. Fed by [GameEvent]s (see [applyEvent]) and advanced once
/// per rendered frame by [update].
///
/// Everything is pre-allocated: particles are capped at [maxParticles] and every
/// ball's trail is a ring buffer, so a frame never grows the heap.
class FxState {
  FxState();

  /// Palette the effects are spawned in. Set by the view every build, so a
  /// theme switch takes effect on the next burst without touching the
  /// simulation.
  GameTheme theme = GameThemes.neon;

  static const int maxParticles = 200;
  static const int maxPopups = 12;

  /// Samples of the ball's path kept for the wakes, i.e. 0.8 s at 60 Hz.
  ///
  /// Long enough for the longest tail a ball skin draws (`ball.comet` walks back
  /// until it has covered a fixed path length, see `ball_art.dart`) and for an
  /// ember's oldest live spark to still find the point it was shed from.
  /// `ball.orb` deliberately reads only the newest [orbTrailSamples] of it, so
  /// the default ball's wake is exactly the length it has always been.
  static const int trailLength = 48;

  /// How much of the path the free `ball.orb` wake covers.
  static const int orbTrailSamples = 16;

  final List<Particle> particles = List<Particle>.generate(
    maxParticles,
    (_) => Particle(),
    growable: false,
  );
  final List<ScorePopup> popups = List<ScorePopup>.generate(
    maxPopups,
    (_) => ScorePopup(),
    growable: false,
  );

  /// Slots for every ball the simulation can have (SPEC §2.2,
  /// `maxBallCount`), allocated once. [ballCount] says how many of them are in
  /// play right now.
  static const int maxBalls = maxBallCount;

  final List<BallFx> balls = List<BallFx>.generate(
    maxBalls,
    (_) => BallFx(),
    growable: false,
  );

  /// Balls currently in play, 1..[maxBalls]; set by [trackBalls].
  int ballCount = 1;

  /// The effects of ball [index], clamped so a stale index from a snapshot that
  /// arrived a frame late can never read off the end.
  BallFx ball(int index) =>
      balls[index < 0 ? 0 : (index >= maxBalls ? maxBalls - 1 : index)];

  /// Seconds since [reset]; drives spins and pulses.
  double time = 0;

  /// Rendered frames since [reset].
  ///
  /// Effects that have to stay put in the world while the ball flies on count in
  /// frames rather than seconds: a point of the ball's path keeps its world
  /// position only while the index into [trailX] advances exactly one per frame,
  /// which is what an ember's sparks are anchored to.
  int frames = 0;

  /// Screen shake strength, 0..1, decaying.
  double shake = 0;

  /// Arena ring flash (life lost), 0..1.
  double ringFlash = 0;

  /// Per-player paddle flash (paddle hit), 0..1.
  final Float64List paddleFlash = Float64List(2);

  /// Fraction of the remaining error corrected per frame: 1 = no smoothing
  /// (solo), ~0.4 smooths snapshot corrections over about three frames (duel).
  double ballSmoothing = 1;

  /// Ball 0's rendered position and path, for the callers that only ever have
  /// one ball (both previews, and every test written before ball counts).
  double get ballX => balls[0].x;
  double get ballY => balls[0].y;
  bool get hasBall => balls[0].live;

  /// Localized countdown text ("3", "GO!"), or null when no countdown runs.
  String? countdownLabel;

  /// Seconds since [countdownLabel] last changed; drives the pop-in animation.
  double countdownPhase = 0;

  int _particleCursor = 0;
  int _popupCursor = 0;

  /// Ball 0's trail length, for the same callers as [ballX].
  int get trailCount => balls[0].trailCount;

  /// Ball 0's trail sample [i], 0 = oldest.
  double trailX(int i) => balls[0].trailX(i);
  double trailY(int i) => balls[0].trailY(i);

  /// Advances every effect by [dtSeconds] (clamped, so a stalled frame cannot
  /// teleport particles).
  void update(double dtSeconds) {
    final d = dtSeconds.clamp(0.0, 0.1);
    time += d;
    frames++;
    countdownPhase += d;
    shake = math.max(0, shake - d * 2.6);
    ringFlash = math.max(0, ringFlash - d * 3.0);
    for (var i = 0; i < paddleFlash.length; i++) {
      paddleFlash[i] = math.max(0, paddleFlash[i] - d * 4.0);
    }
    for (final p in particles) {
      if (!p.alive) continue;
      p.life -= d;
      p.x += p.vx * d;
      p.y += p.vy * d;
      final damp = math.max(0.0, 1 - p.drag * d);
      p.vx *= damp;
      p.vy *= damp;
    }
    for (final p in popups) {
      if (!p.alive) continue;
      p.life -= d;
      p.y += 0.22 * d;
    }
  }

  /// Follows every ball of the game, each with its own trail, optionally
  /// smoothing the correction that a duel snapshot introduces.
  ///
  /// [balls] is `GameState.balls`, in index order — the same order the
  /// simulation resolves them in and the order the tints and the HUD use, so
  /// ball 0 is always ball 0 on screen. Slots past the end are released, which
  /// is what stops a two-ball game's second trail from hanging in the air after
  /// a one-ball game starts.
  void trackBalls(List<Ball> balls, {bool smooth = true}) {
    final n = balls.length < maxBalls ? balls.length : maxBalls;
    ballCount = n < 1 ? 1 : n;
    for (var i = 0; i < maxBalls; i++) {
      if (i < n) {
        this.balls[i].follow(
          balls[i],
          smooth: smooth,
          smoothing: ballSmoothing,
        );
      } else {
        this.balls[i].reset();
      }
    }
  }

  /// Follows a single ball as ball 0 and releases the rest; for the previews and
  /// for callers that hold one [Ball] rather than a state.
  void trackBall(Ball ball, {bool smooth = true}) {
    ballCount = 1;
    balls[0].follow(ball, smooth: smooth, smoothing: ballSmoothing);
    for (var i = 1; i < maxBalls; i++) {
      balls[i].reset();
    }
  }

  /// Follows a bare point as ball 0 and releases the rest, for a caller that has
  /// no [Ball] at all: the decorative ball behind the main menu runs its own
  /// handful of lines of physics and never touches the simulation, but it still
  /// wants the real [BallArt] — which reads its wake from here — to draw it.
  void trackPoint(double x, double y) {
    ballCount = 1;
    balls[0].followPoint(x, y);
    for (var i = 1; i < maxBalls; i++) {
      balls[i].reset();
    }
  }

  /// Spawns [count] sparks around ([x], [y]) in a ring of [speed] units/s.
  void emitBurst(
    double x,
    double y, {
    required Color color,
    int count = 10,
    double speed = 1,
    double life = 0.4,
    double size = 0.012,
    double drag = 2.5,
  }) {
    for (var i = 0; i < count; i++) {
      final p = particles[_particleCursor];
      _particleCursor = (_particleCursor + 1) % maxParticles;
      // Deterministic-enough spread: golden-angle fan plus a time offset so
      // consecutive bursts do not overlap.
      final a = (i * 2.39996 + time * 7.13) % (2 * math.pi);
      final v = speed * (0.45 + 0.55 * ((i * 7 % 11) / 10));
      p.x = x;
      p.y = y;
      p.vx = math.cos(a) * v;
      p.vy = math.sin(a) * v;
      p.life = life * (0.7 + 0.3 * ((i * 5 % 7) / 6));
      p.maxLife = p.life;
      p.size = size;
      p.drag = drag;
      p.color = color;
    }
  }

  void addPopup(String label, double x, double y, Color color) {
    final p = popups[_popupCursor];
    _popupCursor = (_popupCursor + 1) % maxPopups;
    p.label = label;
    p.x = x;
    p.y = y;
    p.color = color;
    p.life = 0.9;
    p.maxLife = 0.9;
    p.cache = null;
    p.cacheBucket = -1;
  }

  void setCountdown(String? label) {
    if (label == countdownLabel) return;
    countdownLabel = label;
    countdownPhase = 0;
  }

  /// Turns one simulation event into visual feedback. [ownPlayer] decides
  /// which paddle colour a hit uses, taken from [theme].
  void applyEvent(GameEvent e, GameState state, {int ownPlayer = 0}) {
    switch (e.type) {
      case GameEventType.serve:
        emitBurst(
          0,
          0,
          color: theme.particle,
          count: 10,
          speed: 0.7,
          life: 0.3,
          size: 0.008,
        );
      case GameEventType.paddleHit:
        final color = e.player == ownPlayer
            ? theme.ownPaddle
            : theme.opponentPaddle;
        emitBurst(
          e.x,
          e.y,
          color: color,
          count: 12,
          speed: 1.1,
          life: 0.45,
          size: 0.011,
        );
        if (e.player >= 0 && e.player < paddleFlash.length) {
          paddleFlash[e.player] = 1;
        }
        shake = math.min(1, shake + 0.12);
        if (e.player >= 0 && e.player < state.players.length) {
          final points = paddleHitScore * state.players[e.player].multiplier;
          addPopup('+$points', e.x, e.y, color);
        }
      case GameEventType.wallHit:
        emitBurst(
          e.x,
          e.y,
          color: theme.wall,
          count: 8,
          speed: 0.9,
          life: 0.35,
          size: 0.009,
        );
        shake = math.min(1, shake + 0.06);
        if (e.player >= 0 && e.player < state.players.length) {
          final points = wallHitScore * state.players[e.player].multiplier;
          addPopup('+$points', e.x, e.y, theme.wall);
        }
      case GameEventType.pickup:
        final heart = e.pickup == PickupType.heart;
        final color = heart ? theme.heart : theme.star;
        emitBurst(
          e.x,
          e.y,
          color: color,
          count: 18,
          speed: 1.3,
          life: 0.55,
          size: 0.012,
        );
        shake = math.min(1, shake + 0.1);
        if (heart) {
          addPopup('+1', e.x, e.y, color);
        } else if (e.player >= 0 && e.player < state.players.length) {
          final points = starScore * state.players[e.player].multiplier;
          addPopup('+$points', e.x, e.y, color);
        }
      case GameEventType.pickupExpire:
        emitBurst(
          e.x,
          e.y,
          color: theme.textDim,
          count: 6,
          speed: 0.35,
          life: 0.3,
          size: 0.007,
        );
      case GameEventType.wallSpawn:
        emitBurst(
          e.x,
          e.y,
          color: theme.wall,
          count: 6,
          speed: 0.4,
          life: 0.35,
          size: 0.007,
        );
      case GameEventType.wallExpire:
        emitBurst(
          e.x,
          e.y,
          color: theme.wall,
          count: 5,
          speed: 0.3,
          life: 0.3,
          size: 0.006,
        );
      case GameEventType.lifeLost:
        emitBurst(
          e.x,
          e.y,
          color: theme.danger,
          count: 26,
          speed: 1.6,
          life: 0.7,
          size: 0.014,
        );
        shake = 1;
        ringFlash = 1;
        // One ball escaping ends the rally for every ball (SPEC §2.3): they are
        // all recalled to the origin, so every trail is stale, not just the one
        // that belongs to `e.ball`.
        for (final b in balls) {
          b.live = false;
          b.clearTrail();
        }
      case GameEventType.gameOver:
        shake = 1;
        ringFlash = 1;
      default:
        // Purely informational event types (e.g. per-tick markers) need no fx.
        break;
    }
  }

  /// Drops every effect; called when a new game starts.
  void reset() {
    time = 0;
    frames = 0;
    shake = 0;
    ringFlash = 0;
    countdownLabel = null;
    countdownPhase = 0;
    ballCount = 1;
    for (final b in balls) {
      b.reset();
    }
    for (var i = 0; i < paddleFlash.length; i++) {
      paddleFlash[i] = 0;
    }
    for (final p in particles) {
      p.life = 0;
    }
    for (final p in popups) {
      p.life = 0;
      p.cache = null;
      p.cacheBucket = -1;
    }
  }
}
