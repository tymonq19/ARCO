/// The four collectable balls (SPEC §4.8), drawn in the current theme's palette.
///
/// A ball is about twelve logical pixels across on a phone and it is the fastest
/// thing on the screen, so the four are told apart by silhouette and by wake —
/// the things that stay legible in motion — and never by interior detail. Each
/// one fills exactly the collision radius the painter hands it: a tail, a fringe
/// or a spark may reach outside it, but the solid body never lies about where the
/// ball is.
library;

import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/painting.dart';

import '../../app/cosmetics.dart';
import '../../app/game_theme.dart';
import '../arena_geometry.dart';
import 'cosmetic_art.dart';
import 'fx_state.dart';

/// The art for [skin]. A fresh instance per painter: each one owns its paints,
/// its paths and its scratch buffer.
BallArt createBallArt(BallSkin skin) => switch (skin) {
  BallSkin.orb => OrbBallArt(),
  BallSkin.comet => CometBallArt(),
  BallSkin.prism => PrismBallArt(),
  BallSkin.ember => EmberBallArt(),
};

/// `ball.orb` — the glowing dot Arco has always drawn, and the free default.
///
/// Deliberately unchanged, down to the alpha ramps: it is the look the game was
/// designed around, and the wake follows the theme's own [TrailStyle] (an
/// additive comet in Neon and Glass, flat dots on Modernist's paper, nothing at
/// all in Classic, where the arcade original had none). It reads only the newest
/// [FxState.orbTrailSamples] of the path, so a longer history kept for the other
/// skins cannot lengthen it.
class OrbBallArt extends BallArt {
  @override
  BallSkin get skin => BallSkin.orb;

  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _additive = Paint()
    ..style = PaintingStyle.fill
    ..blendMode = BlendMode.plus;
  final Paint _bloom = Paint()..style = PaintingStyle.fill;

  @override
  void onPrepare() {
    _bloom.maskFilter = glowFilter(glowSigmaWide(scale, theme.glow));
  }

  @override
  void paintWake(Canvas canvas, ArenaGeometry geometry, FxState fx) {
    if (theme.trailStyle == TrailStyle.none) return;
    final n = math.min(fx.trailCount, FxState.orbTrailSamples);
    if (n < 2) return;
    // The window is the newest samples; index 0 of the buffer is the oldest.
    final first = fx.trailCount - n;
    final base = ballRadius * scale;
    if (theme.trailStyle == TrailStyle.comet) {
      for (var i = 0; i < n; i++) {
        final t = i / (n - 1);
        _additive.color = theme.trail.withValues(alpha: 0.05 + 0.30 * t * t);
        canvas.drawCircle(
          geometry.toScreen(fx.trailX(first + i), fx.trailY(first + i)),
          base * (0.25 + 0.65 * t),
          _additive,
        );
      }
      return;
    }
    // Dots: flat, evenly spaced marks, no blending — a geometric wake. Sized
    // and weighted to stay readable on a light background, where an additive
    // comet would vanish.
    _fill.maskFilter = null;
    for (var i = 0; i < n; i += 3) {
      final t = i / (n - 1);
      _fill.color = theme.trail.withValues(alpha: 0.12 + 0.46 * t);
      canvas.drawCircle(
        geometry.toScreen(fx.trailX(first + i), fx.trailY(first + i)),
        base * 0.30,
        _fill,
      );
    }
  }

  @override
  void paintBody(
    Canvas canvas,
    Offset center,
    double radius,
    double dirX,
    double dirY,
    FxState fx,
  ) {
    if (theme.hasGlow) {
      _bloom.color = theme.trail.withValues(alpha: 0.5 * theme.glow);
      canvas.drawCircle(center, radius * 1.6, _bloom);
    }
    _fill
      ..maskFilter = null
      ..color = theme.ball;
    canvas.drawCircle(center, radius, _fill);
    _fill.color = theme.ballCore;
    canvas.drawCircle(center, radius * 0.55, _fill);
  }
}

/// `ball.comet` — a nucleus with a long tapering plume.
///
/// The plume is the ball's real path: the wake samples are walked back until a
/// fixed length of travel has been covered, so the tail is the same size whether
/// the ball is crawling off a serve or flying at full speed, and it curves
/// exactly the way the ball did. The head carries a bright leading spot, which is
/// what tells it apart from the orb at twelve pixels.
class CometBallArt extends BallArt {
  @override
  BallSkin get skin => BallSkin.comet;

  /// Length of the plume, in simulation units (about a fifth of the arena).
  static const double tailLength = 0.38;

  /// Half width of the plume where it meets the ball, in ball radii.
  static const double headHalfWidth = 0.9;

  final Path _plume = Path();
  final Path _spine = Path();
  final Paint _plumeFill = Paint()..style = PaintingStyle.fill;
  final Paint _plumeBloom = Paint()..style = PaintingStyle.fill;
  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _bloom = Paint()..style = PaintingStyle.fill;

  @override
  void onPrepare() {
    final filter = glowFilter(glowSigmaWide(scale, theme.glow));
    _bloom.maskFilter = filter;
    _plumeBloom
      ..maskFilter = filter
      ..blendMode = lightBlend;
    _plumeFill.blendMode = lightBlend;
  }

  @override
  void paintWake(Canvas canvas, ArenaGeometry geometry, FxState fx) {
    final n = collectWake(geometry, fx, maxLength: tailLength);
    if (n < 3) return;
    final head = ballRadius * scale * headHalfWidth;
    buildPlume(_plume, n, head);
    buildPlume(_spine, n, head * 0.42, ease: 1.6);
    if (theme.hasGlow) {
      _plumeBloom.color = theme.trail.withValues(alpha: 0.26 * theme.glow);
      canvas.drawPath(_plume, _plumeBloom);
    }
    _plumeFill.color = theme.trail.withValues(
      alpha: theme.hasGlow ? 0.34 : 0.40,
    );
    canvas.drawPath(_plume, _plumeFill);
    _plumeFill.color = (theme.hasGlow ? theme.ball : theme.trail).withValues(
      alpha: theme.hasGlow ? 0.55 : 0.85,
    );
    canvas.drawPath(_spine, _plumeFill);
  }

  @override
  void paintBody(
    Canvas canvas,
    Offset center,
    double radius,
    double dirX,
    double dirY,
    FxState fx,
  ) {
    if (theme.hasGlow) {
      _bloom.color = theme.trail.withValues(alpha: 0.55 * theme.glow);
      canvas.drawCircle(center, radius * 1.7, _bloom);
    }
    _fill
      ..maskFilter = null
      ..color = theme.ball;
    canvas.drawCircle(center, radius, _fill);
    // A coloured core behind the middle and a hot spot on the leading edge: the
    // nucleus reads as lit from the front, so the eye finds the direction of
    // travel before it finds the tail.
    _fill.color = theme.trail.withValues(alpha: 0.85);
    canvas.drawCircle(
      center.translate(-dirX * radius * 0.26, -dirY * radius * 0.26),
      radius * 0.5,
      _fill,
    );
    _fill.color = theme.highlight.withValues(alpha: 0.92);
    canvas.drawCircle(
      center.translate(dirX * radius * 0.3, dirY * radius * 0.3),
      radius * 0.44,
      _fill,
    );
  }
}

/// `ball.prism` — a turning facet that splits the palette into coloured edges.
///
/// Three copies of the facet, each in one of the theme's own colours (see
/// [prismEdges]) and each pushed a little way out from the middle, show as
/// coloured edges around a solid hexagon — additively in the themes that bloom,
/// plainly in the flat ones. The wake splits into the same three colours, three
/// tapered plumes side by side, which is what carries the idea at speed.
class PrismBallArt extends BallArt {
  @override
  BallSkin get skin => BallSkin.prism;

  /// Radians per second the facet turns.
  static const double spin = 0.85;

  /// How far each coloured copy sits from the middle, in ball radii.
  static const double split = 0.58;

  /// How much larger the coloured copies are than the body, so that their edges
  /// show all the way round instead of only where they stick out.
  static const double edgeScale = 1.1;

  /// Length of the split wake, in simulation units.
  static const double wakeLength = 0.19;

  final Path _facet = Path();
  final Path _light = Path();
  final Path _plume = Path();
  final Paint _edge = Paint()..style = PaintingStyle.fill;
  final Paint _body = Paint()..style = PaintingStyle.fill;
  final Paint _rim = Paint()..style = PaintingStyle.stroke;
  final Paint _wake = Paint()..style = PaintingStyle.fill;

  @override
  void onPrepare() {
    final r = ballRadius * scale;
    _facet.reset();
    _light.reset();
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final x = math.cos(a) * r;
      final y = math.sin(a) * r;
      if (i == 0) {
        _facet.moveTo(x, y);
      } else {
        _facet.lineTo(x, y);
      }
      // Half the hexagon, as the face that catches the light.
      if (i <= 3) {
        if (i == 0) {
          _light.moveTo(x, y);
        } else {
          _light.lineTo(x, y);
        }
      }
    }
    _facet.close();
    _light.close();
    _edge.blendMode = lightBlend;
    _wake.blendMode = lightBlend;
    _rim.strokeWidth = r * 0.13;
  }

  @override
  void paintWake(Canvas canvas, ArenaGeometry geometry, FxState fx) {
    final n = collectWake(geometry, fx, maxLength: wakeLength, maxPoints: 16);
    if (n < 3) return;
    final r = ballRadius * scale;
    final edges = prismEdges(theme);
    for (var i = 0; i < edges.length; i++) {
      // The three colours leave the ball together and fan apart behind it.
      buildPlume(_plume, n, r * 0.34, ease: 0.9, spread: (i - 1) * r * 1.25);
      _wake.color = edges[i].withValues(alpha: theme.hasGlow ? 0.5 : 0.34);
      canvas.drawPath(_plume, _wake);
    }
  }

  @override
  void paintBody(
    Canvas canvas,
    Offset center,
    double radius,
    double dirX,
    double dirY,
    FxState fx,
  ) {
    final edges = prismEdges(theme);
    final off = radius * split;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(fx.time * spin);
    for (var i = 0; i < edges.length; i++) {
      final a = i * 2 * math.pi / 3;
      _edge.color = edges[i].withValues(alpha: theme.hasGlow ? 0.85 : 0.6);
      canvas.save();
      canvas.translate(math.cos(a) * off, math.sin(a) * off);
      canvas.scale(edgeScale);
      canvas.drawPath(_facet, _edge);
      canvas.restore();
    }
    _body.color = theme.ball.withValues(alpha: 0.95);
    canvas.drawPath(_facet, _body);
    // One lit face, not three: enough to read as cut glass, too little to read
    // as a box.
    _body.color = theme.highlight.withValues(alpha: 0.22);
    canvas.drawPath(_light, _body);
    _rim.color = theme.highlight.withValues(
      alpha: theme.highlightOpacity > 0 ? 0.7 : 0.35,
    );
    canvas.drawPath(_facet, _rim);
    canvas.restore();
  }
}

/// `ball.ember` — a flickering cinder that sheds sparks along its path.
///
/// The sparks are not particles: each one is a pure function of the frame
/// counter, so there is no pool to allocate, nothing to leak, a hard bound of
/// [sparkCount] draws, and a still preview shows a full shower instead of an
/// empty one. A spark is anchored to the point of the ball's own path it was shed
/// from — which stays put in the world only because the index into that path
/// advances exactly one per frame (see [FxState.frames]).
class EmberBallArt extends BallArt {
  @override
  BallSkin get skin => BallSkin.ember;

  /// A spark is shed every this many frames.
  static const int sparkPeriodFrames = 3;

  /// How long a spark lives, in frames.
  static const int sparkLifeFrames = 30;

  /// Live sparks, and therefore the exact number of circles the shower costs.
  static const int sparkCount = sparkLifeFrames ~/ sparkPeriodFrames;

  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _spark = Paint()..style = PaintingStyle.fill;
  final Paint _bloom = Paint()..style = PaintingStyle.fill;

  /// The body colour: the palette's hottest colour pulled a third of the way
  /// towards its warmest, so a cinder is never the same colour as the star
  /// pickup it would otherwise be mistaken for at twelve pixels.
  Color _coal = const Color(0xFFFFFFFF);

  @override
  void onPrepare() {
    _bloom.maskFilter = glowFilter(glowSigmaWide(scale, theme.glow));
    _spark.blendMode = lightBlend;
    _coal = Color.lerp(emberHot(theme), theme.heart, 0.35)!;
  }

  /// Flicker, 0.24 … 1: two incommensurable sines, so it never finds a pulse.
  double _flicker(double time) =>
      (0.62 + 0.38 * math.sin(time * 21.7) * math.sin(time * 13.1 + 1.7)).clamp(
        0.0,
        1.0,
      );

  @override
  void paintWake(Canvas canvas, ArenaGeometry geometry, FxState fx) {
    final n = collectWake(
      geometry,
      fx,
      maxLength: 4,
      maxPoints: sparkLifeFrames + 1,
    );
    if (n < 4) return;
    final r = ballRadius * scale;
    final hot = emberHot(theme);
    final cool = emberSpark(theme);
    final phase = fx.frames % sparkPeriodFrames;
    for (var k = 0; k < sparkCount; k++) {
      final age = phase + k * sparkPeriodFrames;
      if (age >= sparkLifeFrames || age >= n) continue;
      // Stable identity: the frame this spark was shed on. Its direction, its
      // size and its colour are drawn from it, so they stay with it for life.
      final born = fx.frames - age;
      final t = age / sparkLifeFrames;
      final h = (born * 2654435761) % 1013 / 1013.0;
      final g = (born * 40503) % 397 / 397.0;
      final a = h * 2 * math.pi;
      final (nx, ny) = wakeNormal(age, n);
      final drift = r * (1.1 + 1.6 * g) * math.pow(t, 0.55).toDouble();
      _spark.color = (born % 3 == 0 ? cool : hot).withValues(
        alpha: 0.9 * (1 - t) * (1 - t),
      );
      canvas.drawCircle(
        // Mostly sideways off the path, a little along it: a shower rather than
        // a dotted line.
        Offset(
          wakeX(age) + (math.cos(a) * 0.45 + nx * 0.8) * drift,
          wakeY(age) + (math.sin(a) * 0.45 + ny * 0.8) * drift,
        ),
        r * (0.16 + 0.18 * g) * (1 - 0.45 * t),
        _spark,
      );
    }
  }

  @override
  void paintBody(
    Canvas canvas,
    Offset center,
    double radius,
    double dirX,
    double dirY,
    FxState fx,
  ) {
    final f = _flicker(fx.time);
    final hot = emberHot(theme);
    if (theme.hasGlow) {
      _bloom.color = hot.withValues(alpha: (0.35 + 0.30 * f) * theme.glow);
      canvas.drawCircle(center, radius * (1.7 + 0.5 * f), _bloom);
    } else {
      // No blur in the flat themes: two faint discs instead, which is a halo a
      // light theme can carry without turning into a smudge.
      _fill
        ..maskFilter = null
        ..color = hot.withValues(alpha: 0.07 + 0.06 * f);
      canvas.drawCircle(center, radius * 1.55, _fill);
      _fill.color = hot.withValues(alpha: 0.12 + 0.10 * f);
      canvas.drawCircle(center, radius * 1.22, _fill);
    }
    // A coal: hot all the way to the silhouette, with two patches of crust and
    // one white-hot spot on the leading edge. Only the brightness breathes —
    // the silhouette never does, because the silhouette is the hitbox.
    _fill
      ..maskFilter = null
      ..color = _coal.withValues(alpha: 0.75 + 0.25 * f);
    canvas.drawCircle(center, radius, _fill);
    _fill.color = theme.background.withValues(alpha: 0.42 + 0.18 * (1 - f));
    canvas.drawCircle(
      center.translate(-dirX * radius * 0.42, -dirY * radius * 0.42),
      radius * 0.42,
      _fill,
    );
    canvas.drawCircle(
      center.translate(
        (-dirX * 0.26 + dirY * 0.42) * radius,
        (-dirY * 0.26 - dirX * 0.42) * radius,
      ),
      radius * 0.3,
      _fill,
    );
    _fill.color = theme.highlight.withValues(alpha: 0.4 + 0.45 * f);
    canvas.drawCircle(
      center.translate(dirX * radius * 0.26, dirY * radius * 0.26),
      radius * (0.26 + 0.1 * f),
      _fill,
    );
  }
}
