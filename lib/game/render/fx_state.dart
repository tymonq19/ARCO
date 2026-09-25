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

/// Client-only visual state that rides along with a [GameState]: ball trail,
/// particles, screen shake, hit flashes, floating score popups and the
/// countdown label. Fed by [GameEvent]s (see [applyEvent]) and advanced once
/// per rendered frame by [update].
///
/// Everything is pre-allocated: particles are capped at [maxParticles] and the
/// trail is a ring buffer, so a frame never grows the heap.
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

  final Float32List _trail = Float32List(trailLength * 2);
  int _trailCount = 0;
  int _trailHead = 0;

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

  /// Rendered ball position in simulation units (smoothed, see [trackBall]).
  double ballX = 0;
  double ballY = 0;
  bool hasBall = false;

  /// Fraction of the remaining error corrected per frame: 1 = no smoothing
  /// (solo), ~0.4 smooths snapshot corrections over about three frames (duel).
  double ballSmoothing = 1;

  /// Localized countdown text ("3", "GO!"), or null when no countdown runs.
  String? countdownLabel;

  /// Seconds since [countdownLabel] last changed; drives the pop-in animation.
  double countdownPhase = 0;

  int _particleCursor = 0;
  int _popupCursor = 0;

  int get trailCount => _trailCount;

  /// Trail sample [i], 0 = oldest.
  double trailX(int i) => _trail[_trailIndex(i) * 2];
  double trailY(int i) => _trail[_trailIndex(i) * 2 + 1];

  int _trailIndex(int i) =>
      (_trailHead - _trailCount + i + trailLength * 2) % trailLength;

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

  /// Follows the simulated ball, optionally smoothing the correction that a
  /// duel snapshot introduces. Also feeds the trail.
  void trackBall(Ball ball, {bool smooth = true}) {
    if (!ball.active) {
      hasBall = false;
      ballX = ball.x;
      ballY = ball.y;
      _trailCount = 0;
      return;
    }
    final dx = ball.x - ballX;
    final dy = ball.y - ballY;
    final far = dx * dx + dy * dy > 0.0625; // > 0.25 units: a serve or a snap
    if (!hasBall || far || !smooth) {
      ballX = ball.x;
      ballY = ball.y;
      if (!hasBall || far) _trailCount = 0;
      hasBall = true;
    } else {
      final k = ballSmoothing.clamp(0.05, 1.0);
      ballX += dx * k;
      ballY += dy * k;
    }
    _pushTrail(ballX, ballY);
  }

  void _pushTrail(double x, double y) {
    _trail[_trailHead * 2] = x;
    _trail[_trailHead * 2 + 1] = y;
    _trailHead = (_trailHead + 1) % trailLength;
    if (_trailCount < trailLength) _trailCount++;
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
        hasBall = false;
        _trailCount = 0;
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
    hasBall = false;
    ballX = 0;
    ballY = 0;
    _trailCount = 0;
    _trailHead = 0;
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
