import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';

import '../../app/cosmetics.dart';
import '../../app/game_theme.dart';
import '../arena_geometry.dart';
import 'ball_art.dart';
import 'cosmetic_art.dart';
import 'fx_state.dart';
import 'paddle_art.dart';

/// Draws the arena, the entities and every client-side effect (SPEC §5.3),
/// entirely in the colours and the style of a [GameTheme], with the ball and the
/// paddle the player has [equipped] (SPEC §4.8).
///
/// Performance notes: all [Paint] objects, [Path]s, shaders and mask filters
/// are created once (and rebuilt only when the arena size or the theme
/// changes), particles are capped by [FxState.maxParticles] and score popups
/// keep their laid-out [TextPainter]. A theme with `glow == 0` records no blur
/// passes at all, and no theme ever puts a [BackdropFilter] in the arena: the
/// glass look blurs the HUD and the overlays only.
class GamePainter extends CustomPainter {
  GamePainter({
    required this.stateOf,
    required this.fx,
    required this.geometry,
    required this.theme,
    this.equipped = Equipped.defaults,
    this.ownPlayer = 0,
    super.repaint,
  });

  /// Latest simulation state, or null before a duel starts.
  final GameState? Function() stateOf;
  final FxState fx;
  final ArenaGeometry geometry;

  /// The look to draw in; purely visual, never read by the simulation.
  final GameTheme theme;

  /// The ball and paddle skins the player wears. Purely cosmetic: the art is
  /// handed the true collision radius and the true angular sweep, so what is
  /// equipped cannot change a bounce (SPEC §4.8).
  final Equipped equipped;

  /// Player index whose paddle is drawn in the "own" colour.
  final int ownPlayer;

  /// Spacing of the CRT scanline overlay, in logical pixels.
  static const double scanlineSpacing = 3;

  static final Path _heartPath = _buildHeart();
  static final Path _starPath = _buildStar();

  /// Scratch path for one wall's center line, rebuilt per wall per frame and
  /// never handed out (see [_buildWallPath]).
  final Path _wallPath = Path();

  late final BallArt _ballArt = createBallArt(equipped.ball);
  late final PaddleArt _ownPaddleArt = createPaddleArt(equipped.paddle);

  /// The opponent's paddle is always the free arc: a duel does not carry what the
  /// other player owns (protocol v1 syncs no cosmetics), and drawing them in a
  /// skin they may not own would be a claim this client cannot make. It also
  /// makes "which one is mine" unmistakable.
  late final PaddleArt _opponentPaddleArt = createPaddleArt(PaddleSkin.arc);

  final Paint _bg = Paint();
  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Paint _glowStroke = Paint()..style = PaintingStyle.stroke;
  final Paint _glowFill = Paint()..style = PaintingStyle.fill;
  final Paint _additive = Paint()
    ..style = PaintingStyle.fill
    ..blendMode = BlendMode.plus;

  Size _bgSize = Size.zero;
  double _filterScale = -1;
  MaskFilter? _mediumGlow;
  MaskFilter? _wideGlow;
  Path? _scanlines;
  Paint? _vignette;
  TextPainter? _countdownCache;
  String? _countdownKey;

  /// Glow blur radii; null (and skipped entirely) when the theme has no glow.
  void _ensureScale(double scale) {
    if (_filterScale == scale) return;
    _filterScale = scale;
    if (!theme.hasGlow) {
      _mediumGlow = null;
      _wideGlow = null;
      return;
    }
    _mediumGlow = MaskFilter.blur(
      BlurStyle.normal,
      glowSigmaMedium(scale, theme.glow),
    );
    _wideGlow = MaskFilter.blur(
      BlurStyle.normal,
      glowSigmaWide(scale, theme.glow),
    );
  }

  void _ensureSurfaces(Size size) {
    if (_bgSize == size) return;
    _bgSize = size;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    _bg.shader = RadialGradient(
      center: Alignment.center,
      radius: 0.85,
      colors: theme.backgroundGradient,
      stops: theme.backgroundStops,
    ).createShader(rect);
    _scanlines = theme.scanlines ? _buildScanlines(size) : null;
    _vignette = theme.vignette > 0
        ? (Paint()
            ..shader = RadialGradient(
              center: Alignment.center,
              radius: 0.78,
              colors: [
                const Color(0x00000000),
                Colors.black.withValues(alpha: theme.vignette * 0.45),
                Colors.black.withValues(alpha: theme.vignette),
              ],
              stops: const [0.45, 0.8, 1.0],
            ).createShader(rect))
        : null;
  }

  static Path _buildScanlines(Size size) {
    final path = Path();
    for (var y = 0.0; y < size.height; y += scanlineSpacing) {
      path.moveTo(0, y);
      path.lineTo(size.width, y);
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _ensureScale(geometry.scale);
    _ballArt.prepare(theme, geometry.scale);
    _ensureSurfaces(size);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), _bg);

    final state = stateOf();
    canvas.save();
    if (fx.shake > 0) {
      final amp = fx.shake * fx.shake * geometry.scale * 0.05;
      canvas.translate(
        math.sin(fx.time * 57) * amp,
        math.cos(fx.time * 43) * amp,
      );
    }
    _drawArena(canvas, state);
    if (state != null) {
      _drawWalls(canvas, state);
      _drawPickups(canvas, state);
      _drawWake(canvas, state);
      _drawBalls(canvas, state);
      _drawPaddles(canvas, state);
    }
    _drawParticles(canvas);
    _drawPopups(canvas);
    canvas.restore();
    _drawCountdown(canvas, size);
    _drawOverlays(canvas, size);
  }

  // ------------------------------------------------------------------- arena

  void _drawArena(Canvas canvas, GameState? state) {
    final center = geometry.center;
    final r = geometry.scale;

    _fill
      ..maskFilter = null
      ..color = theme.arenaFill;
    canvas.drawCircle(center, r * 0.995, _fill);

    if (theme.hasGlow) {
      _glowStroke
        ..maskFilter = _wideGlow
        ..strokeWidth = math.max(2.0, r * 0.022)
        ..color = theme.ring.withValues(alpha: 0.35 * theme.glow);
      canvas.drawCircle(center, r, _glowStroke);
    }

    _stroke
      ..maskFilter = null
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = math.max(1.2, r * theme.ringWidth)
      ..color = theme.ring.withValues(alpha: 0.9);
    canvas.drawCircle(center, r, _stroke);

    _stroke
      ..strokeWidth = math.max(1.0, r * 0.004)
      ..color = theme.ring.withValues(alpha: 0.12);
    canvas.drawCircle(center, r * 0.5, _stroke);

    if (state != null && state.config.mode == GameMode.duel) {
      _stroke
        ..strokeWidth = math.max(1.0, r * 0.005)
        ..color = theme.textPrimary.withValues(alpha: 0.10);
      canvas.drawLine(
        geometry.toScreen(-1, 0),
        geometry.toScreen(1, 0),
        _stroke,
      );
    }

    if (fx.ringFlash > 0) {
      if (theme.hasGlow) {
        _glowStroke
          ..maskFilter = _mediumGlow
          ..strokeWidth = math.max(2.0, r * 0.03)
          ..color = theme.danger.withValues(
            alpha: 0.55 * fx.ringFlash * theme.glow,
          );
        canvas.drawCircle(center, r, _glowStroke);
      } else {
        _stroke
          ..maskFilter = null
          ..strokeWidth = math.max(2.0, r * theme.ringWidth * 2.4)
          ..color = theme.danger.withValues(alpha: 0.85 * fx.ringFlash);
        canvas.drawCircle(center, r, _stroke);
      }
    }
  }

  // ------------------------------------------------------------------- walls

  /// The walls, each one a polyline of two, three or `wallCurveSegments + 1`
  /// vertices (SPEC §2.3).
  ///
  /// Every shape is drawn as **one stroked [Path]** rather than a sequence of
  /// lines. That is what keeps the width even and the joints clean: separate
  /// `drawLine` calls with round caps bulge at every joint and with butt caps
  /// leave a notch in the outside of the bend, and either way a curve reads as a
  /// chain of sticks. A single path is stroked with a round join, so a bent
  /// wall's corner is a clean arc of the wall's own half-thickness, and a curved
  /// wall's chords are smoothed into a real curve by [_buildWallPath].
  ///
  /// The fade is the player's only warning that a wall is about to become solid,
  /// so it is drawn on **two** channels: opacity, and width. A wall fading in
  /// grows from a little over half thickness to full as it brightens, so it
  /// visibly thickens into existence — and because the core now guarantees
  /// `alpha == 1` exactly while `solid` (see `Wall.alpha`), a wall at full width
  /// and full opacity is always a wall that collides, and one that is thin and
  /// faint never is.
  void _drawWalls(Canvas canvas, GameState state) {
    if (state.walls.isEmpty) return;
    final full = wallHalfThickness * 2 * geometry.scale;
    final cap = theme.strokeCap;
    for (final w in state.walls) {
      final a = w.alpha.clamp(0.0, 1.0);
      if (a <= 0.01) continue;
      final width = full * (0.55 + 0.45 * a);
      final path = _buildWallPath(w);
      if (theme.hasGlow) {
        _glowStroke
          ..maskFilter = _mediumGlow
          ..strokeCap = cap
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = width * 2.1
          ..color = theme.wall.withValues(alpha: 0.4 * a * theme.glow);
        canvas.drawPath(path, _glowStroke);
      }
      _stroke
        ..maskFilter = null
        ..strokeCap = cap
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = width
        ..color = theme.wall.withValues(alpha: 0.95 * a);
      canvas.drawPath(path, _stroke);
      if (theme.highlightOpacity > 0) {
        _stroke
          ..strokeWidth = width * 0.35
          ..color = theme.highlight.withValues(
            alpha: theme.highlightOpacity * 1.45 * a,
          );
        canvas.drawPath(path, _stroke);
      }
    }
  }

  /// [wall]'s center line in screen space.
  ///
  /// Straight and bent walls are drawn exactly as the simulation sees them — a
  /// bend is a bend, and rounding it away would turn every bent wall into a
  /// vague arc that reads like a failed straight one. A curved wall is the one
  /// shape whose vertices are a *sampling* of something smooth, so its chords
  /// are replaced by quadratics through their midpoints: the outline has no
  /// corners at all, and it stays within the chords' own sag of the ideal arc
  /// (under 0.0025 units, a fraction of a pixel on a phone — see
  /// `wallCurveSegments`).
  ///
  /// Reuses one [Path]: at most `maxWalls` of these are built per frame and the
  /// object is never handed out.
  Path _buildWallPath(Wall wall) {
    final path = _wallPath..reset();
    final n = wall.pointCount;
    var p = geometry.toScreen(wall.pointX(0), wall.pointY(0));
    path.moveTo(p.dx, p.dy);
    if (wall.shape != WallShape.curved || n < 3) {
      for (var i = 1; i < n; i++) {
        p = geometry.toScreen(wall.pointX(i), wall.pointY(i));
        path.lineTo(p.dx, p.dy);
      }
      return path;
    }
    var control = geometry.toScreen(wall.pointX(1), wall.pointY(1));
    for (var i = 2; i < n; i++) {
      final next = geometry.toScreen(wall.pointX(i), wall.pointY(i));
      path.quadraticBezierTo(
        control.dx,
        control.dy,
        (control.dx + next.dx) / 2,
        (control.dy + next.dy) / 2,
      );
      control = next;
    }
    path.lineTo(control.dx, control.dy);
    return path;
  }

  // ----------------------------------------------------------------- pickups

  void _drawPickups(Canvas canvas, GameState state) {
    if (state.pickups.isEmpty) return;
    final radius = pickupRadius * geometry.scale;
    for (final k in state.pickups) {
      // Blink over the last two seconds of the pickup's life.
      final blink = k.ttl < pickupBlinkTicks
          ? 0.45 + 0.55 * (0.5 + 0.5 * math.sin(fx.time * 16))
          : 1.0;
      final heart = k.type == PickupType.heart;
      final color = heart ? theme.heart : theme.star;
      final pos = geometry.toScreen(k.x, k.y);

      if (theme.hasGlow) {
        _glowFill
          ..maskFilter = _wideGlow
          ..color = color.withValues(alpha: 0.35 * blink * theme.glow);
        canvas.drawCircle(pos, radius * 0.95, _glowFill);
      }

      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      if (heart) {
        final pulse = 1 + 0.12 * math.sin(fx.time * 6);
        canvas.scale(radius * 0.85 * pulse);
      } else {
        canvas.rotate(fx.time * 1.7);
        canvas.scale(radius * 0.95);
      }
      _fill
        ..maskFilter = null
        ..color = color.withValues(alpha: blink);
      canvas.drawPath(heart ? _heartPath : _starPath, _fill);
      if (theme.highlightOpacity > 0) {
        _stroke
          ..maskFilter = null
          ..strokeCap = StrokeCap.butt
          ..strokeWidth = 0.1
          ..color = theme.highlight.withValues(
            alpha: theme.highlightOpacity * 1.35 * blink,
          );
        canvas.drawPath(heart ? _heartPath : _starPath, _stroke);
      }
      canvas.restore();
    }
  }

  // -------------------------------------------------------------------- ball

  /// Every live ball's wake, drawn under the balls and the paddles. Which wake it
  /// is belongs to the equipped skin: `ball.orb` follows the theme's own
  /// [TrailStyle], the others carry a wake of their own (drawn in the theme's
  /// colours).
  ///
  /// Drawn in index order and **all of them before any body**, so a ball is never
  /// buried under the other one's tail: the wakes make one layer and the balls
  /// make the layer above it.
  void _drawWake(Canvas canvas, GameState state) {
    for (var i = 0; i < state.balls.length && i < FxState.maxBalls; i++) {
      if (!state.balls[i].active) continue;
      _ballArt.paintWake(canvas, geometry, fx, i);
    }
  }

  void _drawBalls(Canvas canvas, GameState state) {
    for (var i = 0; i < state.balls.length && i < FxState.maxBalls; i++) {
      _drawBall(canvas, state.balls[i], i);
    }
  }

  void _drawBall(Canvas canvas, Ball ball, int index) {
    if (!ball.active) return;
    final trail = fx.ball(index);
    final pos = trail.live
        ? geometry.toScreen(trail.x, trail.y)
        : geometry.toScreen(ball.x, ball.y);
    // The true collision radius, and the direction of travel in screen space
    // (y flipped, and turned around for duel player 1). A skin may decorate
    // outside the radius but never draw a body that disagrees with it.
    final r = ballRadius * geometry.scale;
    final vx = ball.vx;
    final vy = ball.vy;
    final speed = math.sqrt(vx * vx + vy * vy);
    var dx = 0.0;
    var dy = -1.0;
    if (speed > 1e-6) {
      dx = (geometry.rotated ? -vx : vx) / speed;
      dy = (geometry.rotated ? vy : -vy) / speed;
    }
    _ballArt.paintBody(canvas, pos, r, dx, dy, fx, index);
  }

  // ----------------------------------------------------------------- paddles

  void _drawPaddles(Canvas canvas, GameState state) {
    final r = geometry.scale;
    for (var i = 0; i < state.players.length; i++) {
      final own = i == ownPlayer;
      final art = own ? _ownPaddleArt : _opponentPaddleArt;
      // A guarded no-op once the size and the palette have settled.
      art.prepare(theme, r);
      art.paint(
        canvas,
        geometry.center,
        r,
        geometry.canvasAngle(state.players[i].paddle.angle),
        own ? theme.ownPaddle : theme.opponentPaddle,
        i < fx.paddleFlash.length ? fx.paddleFlash[i] : 0.0,
        fx,
      );
    }
  }

  // --------------------------------------------------------------- particles

  void _drawParticles(Canvas canvas) {
    final paint = theme.hasGlow ? _additive : _fill;
    paint.maskFilter = null;
    for (final p in fx.particles) {
      if (!p.alive) continue;
      final fade = p.fade;
      // One small Color per live particle: unavoidable to fade the alpha, and
      // bounded by FxState.maxParticles.
      paint.color = p.color.withValues(alpha: 0.9 * fade);
      canvas.drawCircle(
        geometry.toScreen(p.x, p.y),
        p.size * geometry.scale * (0.4 + 0.6 * fade),
        paint,
      );
    }
  }

  void _drawPopups(Canvas canvas) {
    for (final p in fx.popups) {
      if (!p.alive) continue;
      final fade = p.fade;
      final bucket = (fade * 8).ceil().clamp(1, 8);
      var tp = p.cache;
      if (tp == null || p.cacheBucket != bucket) {
        tp = TextPainter(
          text: TextSpan(
            text: p.label,
            style: TextStyle(
              color: p.color.withValues(alpha: bucket / 8),
              fontFamily: theme.fontFamily,
              fontFamilyFallback: theme.fontFamilyFallback,
              fontSize: math.max(12.0, geometry.scale * 0.11),
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        p.cache = tp;
        p.cacheBucket = bucket;
      }
      final pos = geometry.toScreen(p.x, p.y);
      tp.paint(
        canvas,
        Offset(
          pos.dx - tp.width / 2,
          pos.dy - tp.height / 2 - (1 - fade) * geometry.scale * 0.12,
        ),
      );
    }
  }

  void _drawCountdown(Canvas canvas, Size size) {
    final label = fx.countdownLabel;
    if (label == null || label.isEmpty) return;
    var tp = _countdownCache;
    if (tp == null || _countdownKey != label) {
      tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: theme.textPrimary,
            fontFamily: theme.fontFamily,
            fontFamilyFallback: theme.fontFamilyFallback,
            fontSize: math.max(48.0, geometry.scale * 0.62),
            fontWeight: FontWeight.w900,
            letterSpacing: 4,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      _countdownCache = tp;
      _countdownKey = label;
    }
    final pop = (1.0 - (fx.countdownPhase * 4).clamp(0.0, 1.0));
    final scale = 1.0 + 0.35 * pop;
    canvas.save();
    canvas.translate(geometry.center.dx, geometry.center.dy);
    canvas.scale(scale);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  /// Vignette and CRT scanlines: two cached draws over the finished frame.
  void _drawOverlays(Canvas canvas, Size size) {
    final vignette = _vignette;
    if (vignette != null) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), vignette);
    }
    final scanlines = _scanlines;
    if (scanlines != null) {
      _stroke
        ..maskFilter = null
        ..strokeCap = StrokeCap.butt
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.22);
      canvas.drawPath(scanlines, _stroke);
    }
  }

  @override
  bool shouldRepaint(GamePainter oldDelegate) => true;

  // -------------------------------------------------------------------- paths

  /// Heart in a unit box (canvas space, y down), roughly spanning [-1, 1].
  static Path _buildHeart() {
    final p = Path();
    p.moveTo(0, 0.85);
    p.cubicTo(-1.35, -0.25, -0.62, -1.2, 0, -0.42);
    p.cubicTo(0.62, -1.2, 1.35, -0.25, 0, 0.85);
    p.close();
    return p;
  }

  /// Five-pointed star with outer radius 1 (canvas space).
  static Path _buildStar() {
    final p = Path();
    for (var i = 0; i < 10; i++) {
      final r = i.isEven ? 1.0 : 0.45;
      final a = -math.pi / 2 + i * math.pi / 5;
      final x = math.cos(a) * r;
      final y = math.sin(a) * r;
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    p.close();
    return p;
  }
}
