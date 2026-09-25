/// The four collectable paddles (SPEC §4.8), drawn in the current theme's
/// palette.
///
/// All four span the same `2 * paddleHalfWidth` radians at the same ring radius,
/// because that is the arc the simulation bounces off. What a skin owns is the
/// radial shape, the softness of its edges and how it reacts to a hit.
///
/// The shapes that are not arcs are built once as paths in pixel space (see
/// [CosmeticArt.prepare]) around the +x axis, and each frame the canvas is turned
/// to the paddle's angle and the path is drawn: a moving paddle costs one
/// rotation, not a rebuilt path.
library;

import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/painting.dart';

import '../../app/cosmetics.dart';
import 'cosmetic_art.dart';
import 'fx_state.dart';

/// The art for [skin]. A fresh instance per painter: each one owns its paints and
/// its paths.
PaddleArt createPaddleArt(PaddleSkin skin) => switch (skin) {
  PaddleSkin.arc => ArcPaddleArt(),
  PaddleSkin.blade => BladePaddleArt(),
  PaddleSkin.halo => HaloPaddleArt(),
  PaddleSkin.chevron => ChevronPaddleArt(),
};

/// Caches the bounding square that [Canvas.drawArc] needs, so an arc-based skin
/// allocates one [Rect] per arena size rather than one per frame.
mixin ArcRect {
  Offset _center = Offset.zero;
  double _radius = -1;
  Rect _rect = Rect.zero;

  Rect ringRect(Offset center, double radius) {
    if (center != _center || radius != _radius) {
      _center = center;
      _radius = radius;
      _rect = Rect.fromCircle(center: center, radius: paddleRing * radius);
    }
    return _rect;
  }
}

/// `paddle.arc` — the plain thick arc the renderer has always drawn, and the free
/// default.
///
/// Unchanged: the glow pass, the specular core line in the themes that have one
/// and, in the flat themes, a hit that reads as a brief thickening instead.
class ArcPaddleArt extends PaddleArt with ArcRect {
  @override
  PaddleSkin get skin => PaddleSkin.arc;

  static const double sweep = 2 * paddleHalfWidth;

  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Paint _bloom = Paint()..style = PaintingStyle.stroke;

  @override
  void onPrepare() {
    _bloom.maskFilter = glowFilter(glowSigmaWide(scale, theme.glow));
  }

  @override
  void paint(
    Canvas canvas,
    Offset center,
    double radius,
    double centerAngle,
    Color color,
    double flash,
    FxState fx,
  ) {
    final rect = ringRect(center, radius);
    final start = centerAngle - paddleHalfWidth;
    final width = paddleThickness * radius;
    final cap = theme.strokeCap;

    if (theme.hasGlow) {
      _bloom
        ..strokeCap = cap
        ..strokeWidth = width * 2.0
        ..color = color.withValues(alpha: (0.35 + 0.35 * flash) * theme.glow);
      canvas.drawArc(rect, start, sweep, false, _bloom);
    }

    _stroke
      ..maskFilter = null
      ..strokeCap = cap
      ..strokeWidth = width
      ..color = color;
    canvas.drawArc(rect, start, sweep, false, _stroke);

    if (theme.highlightOpacity > 0) {
      _stroke
        ..strokeWidth = width * 0.3
        ..color = theme.highlight.withValues(
          alpha: (theme.highlightOpacity + (1 - theme.highlightOpacity) * flash)
              .clamp(0.0, 1.0),
        );
      canvas.drawArc(rect, start, sweep, false, _stroke);
    } else if (flash > 0) {
      // No specular line in the flat themes: the hit reads as a brief
      // thickening of the paddle instead.
      _stroke
        ..strokeWidth = width * (1 + 0.5 * flash)
        ..color = color.withValues(alpha: 0.5 + 0.5 * flash);
      canvas.drawArc(rect, start, sweep, false, _stroke);
    }
  }
}

/// `paddle.blade` — thin through the middle and tapering to sharp points at both
/// tips.
///
/// The tips land exactly on the sweep's ends, so the paddle still shows its full
/// reach; what the skin gives up is radial bulk. A hit thickens the silhouette by
/// stroking the same outline, which keeps the sharpness of the tips.
class BladePaddleArt extends PaddleArt {
  @override
  PaddleSkin get skin => PaddleSkin.blade;

  /// Half thickness at the middle, in simulation units. Thinner than the arc's
  /// 0.02 but not so thin that the ball looks like it bounced off nothing.
  static const double halfThickness = 0.017;

  final Path _body = Path();
  final Path _spine = Path();
  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _bloom = Paint()..style = PaintingStyle.fill;
  final Paint _edge = Paint()..style = PaintingStyle.stroke;

  @override
  void onPrepare() {
    _bloom.maskFilter = glowFilter(glowSigmaWide(scale, theme.glow));
    _lens(_body, halfThickness * scale, paddleHalfWidth, 0.55);
    _lens(_spine, halfThickness * scale * 0.34, paddleHalfWidth * 0.82, 0.9);
    _edge.strokeCap = StrokeCap.round;
  }

  /// A lens along the paddle ring: [half] pixels thick in the middle, pinched to
  /// nothing at ±[span] radians. [ease] shapes the taper — lower is more needle.
  void _lens(Path into, double half, double span, double ease) {
    const steps = 22;
    final ring = paddleRing * scale;
    into.reset();
    for (var j = 0; j <= steps; j++) {
      final t = -1 + 2 * j / steps;
      final a = t * span;
      final th = half * math.pow(1 - t * t, ease).toDouble();
      final r = ring + th;
      final x = math.cos(a) * r;
      final y = math.sin(a) * r;
      if (j == 0) {
        into.moveTo(x, y);
      } else {
        into.lineTo(x, y);
      }
    }
    for (var j = steps; j >= 0; j--) {
      final t = -1 + 2 * j / steps;
      final a = t * span;
      final th = half * math.pow(1 - t * t, ease).toDouble();
      final r = ring - th;
      into.lineTo(math.cos(a) * r, math.sin(a) * r);
    }
    into.close();
  }

  @override
  void paint(
    Canvas canvas,
    Offset center,
    double radius,
    double centerAngle,
    Color color,
    double flash,
    FxState fx,
  ) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(centerAngle);
    if (theme.hasGlow) {
      _bloom.color = color.withValues(
        alpha: (0.40 + 0.35 * flash) * theme.glow,
      );
      canvas.drawPath(_body, _bloom);
    }
    _fill.color = color;
    canvas.drawPath(_body, _fill);
    if (flash > 0) {
      _edge
        ..strokeWidth = radius * 0.012 * flash
        ..color = color.withValues(alpha: 0.9);
      canvas.drawPath(_body, _edge);
    }
    _fill.color = theme.highlightOpacity > 0
        ? theme.highlight.withValues(
            alpha: (0.45 + 0.55 * theme.highlightOpacity).clamp(0.0, 1.0),
          )
        // Flat themes have no specular line, so the spine is the background
        // showing through: a hairline that makes the blade read as two edges.
        : theme.background.withValues(alpha: 0.5);
    canvas.drawPath(_spine, _fill);
    canvas.restore();
  }
}

/// `paddle.halo` — a slim core inside a soft outer bloom.
///
/// Where the theme blooms, the bloom is two cached blur passes; where it does
/// not, it is four layered translucent arcs, which is a halo that Modernist's
/// paper can carry without turning into a smudge. The bloom covers the paddle's
/// full radial thickness, so the slim core is a look rather than a smaller
/// paddle.
class HaloPaddleArt extends PaddleArt with ArcRect {
  @override
  PaddleSkin get skin => PaddleSkin.halo;

  static const double sweep = 2 * paddleHalfWidth;

  /// Widths of the flat-theme bloom layers, in paddle thicknesses.
  static const List<double> layerWidths = [3.4, 2.5, 1.7, 1.15];
  static const List<double> layerAlphas = [0.07, 0.11, 0.17, 0.30];

  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Paint _soft = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _wide = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  @override
  void onPrepare() {
    _soft.maskFilter = glowFilter(glowSigmaMedium(scale, theme.glow));
    _wide.maskFilter = glowFilter(glowSigmaWide(scale, theme.glow));
  }

  /// One layer of the bloom, [strokeWidth] wide.
  ///
  /// Its round caps are what make the halo soft, and they reach half a stroke
  /// beyond the arc they are drawn on — so the arc is shortened by exactly that,
  /// and the aura ends where the paddle ends instead of promising reach the
  /// paddle has not got.
  void _aura(
    Canvas canvas,
    Rect rect,
    double centerAngle,
    double radius,
    double strokeWidth,
    Paint paint,
    Color color,
  ) {
    final inset = math.min(
      paddleHalfWidth - 0.04,
      strokeWidth / 2 / (paddleRing * radius),
    );
    paint
      ..strokeWidth = strokeWidth
      ..color = color;
    canvas.drawArc(
      rect,
      centerAngle - paddleHalfWidth + inset,
      2 * (paddleHalfWidth - inset),
      false,
      paint,
    );
  }

  @override
  void paint(
    Canvas canvas,
    Offset center,
    double radius,
    double centerAngle,
    Color color,
    double flash,
    FxState fx,
  ) {
    final rect = ringRect(center, radius);
    final start = centerAngle - paddleHalfWidth;
    final width = paddleThickness * radius;

    if (theme.hasGlow) {
      _aura(
        canvas,
        rect,
        centerAngle,
        radius,
        width * 3.6,
        _wide,
        color.withValues(alpha: (0.26 + 0.22 * flash) * theme.glow),
      );
      _aura(
        canvas,
        rect,
        centerAngle,
        radius,
        width * 1.9,
        _soft,
        color.withValues(alpha: (0.38 + 0.30 * flash) * theme.glow),
      );
    } else {
      _soft.maskFilter = null;
      for (var i = 0; i < layerWidths.length; i++) {
        _aura(
          canvas,
          rect,
          centerAngle,
          radius,
          width * layerWidths[i],
          _soft,
          color.withValues(
            alpha: (layerAlphas[i] * (1 + 0.8 * flash)).clamp(0.0, 1.0),
          ),
        );
      }
    }

    _stroke
      ..maskFilter = null
      ..strokeCap = theme.strokeCap
      ..strokeWidth = width * 0.5
      ..color = color;
    canvas.drawArc(rect, start, sweep, false, _stroke);

    if (theme.highlightOpacity > 0) {
      _stroke
        ..strokeWidth = width * 0.2
        ..color = theme.highlight.withValues(
          alpha: (0.5 * theme.highlightOpacity + 0.5 * flash).clamp(0.0, 1.0),
        );
      canvas.drawArc(rect, start, sweep, false, _stroke);
    }
  }
}

/// `paddle.chevron` — angled segments over a continuous spine.
///
/// Five parallelograms, each leaning across the ring, with hairline gaps between
/// them; the spine under them is what says the paddle has no holes in it, because
/// it has none. A hit splays the segments: the same path drawn twice more, a
/// hundredth of a radian either way.
class ChevronPaddleArt extends PaddleArt {
  @override
  PaddleSkin get skin => PaddleSkin.chevron;

  static const int segments = 5;

  /// Gap between two segments, in radians.
  static const double gap = 0.013;

  /// How far the outer edge of a segment leans ahead of its inner edge.
  static const double shear = 0.034;

  final Path _pieces = Path();
  final Path _spine = Path();
  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _bloom = Paint()..style = PaintingStyle.fill;

  @override
  void onPrepare() {
    _bloom.maskFilter = glowFilter(glowSigmaWide(scale, theme.glow));
    final ring = paddleRing * scale;
    final half = paddleThickness * scale / 2;
    final inner = ring - half;
    final outer = ring + half;
    // The lean is symmetric and the row is inset by half of it, so the outermost
    // corner of the outermost segment lands exactly on the paddle's own end: the
    // skin leans without ever claiming reach the paddle does not have.
    final reach = paddleHalfWidth - shear / 2;
    final span = (2 * reach - (segments - 1) * gap) / segments;
    _pieces.reset();
    for (var i = 0; i < segments; i++) {
      final a0 = -reach + i * (span + gap);
      final a1 = a0 + span;
      _pieces.moveTo(
        math.cos(a0 - shear / 2) * inner,
        math.sin(a0 - shear / 2) * inner,
      );
      _pieces.lineTo(
        math.cos(a1 - shear / 2) * inner,
        math.sin(a1 - shear / 2) * inner,
      );
      _pieces.lineTo(
        math.cos(a1 + shear / 2) * outer,
        math.sin(a1 + shear / 2) * outer,
      );
      _pieces.lineTo(
        math.cos(a0 + shear / 2) * outer,
        math.sin(a0 + shear / 2) * outer,
      );
      _pieces.close();
    }
    // The spine: a hairline band along the whole sweep, sampled finely enough
    // that it follows the ring rather than cutting across it.
    const steps = 16;
    final thin = half * 0.45;
    _spine.reset();
    for (var j = 0; j <= steps; j++) {
      final a = -paddleHalfWidth + 2 * paddleHalfWidth * j / steps;
      final r = ring + thin;
      final x = math.cos(a) * r;
      final y = math.sin(a) * r;
      if (j == 0) {
        _spine.moveTo(x, y);
      } else {
        _spine.lineTo(x, y);
      }
    }
    for (var j = steps; j >= 0; j--) {
      final a = -paddleHalfWidth + 2 * paddleHalfWidth * j / steps;
      final r = ring - thin;
      _spine.lineTo(math.cos(a) * r, math.sin(a) * r);
    }
    _spine.close();
  }

  @override
  void paint(
    Canvas canvas,
    Offset center,
    double radius,
    double centerAngle,
    Color color,
    double flash,
    FxState fx,
  ) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(centerAngle);
    if (theme.hasGlow) {
      _bloom.color = color.withValues(
        alpha: (0.35 + 0.35 * flash) * theme.glow,
      );
      canvas.drawPath(_pieces, _bloom);
    }
    _fill.color = color.withValues(alpha: theme.hasGlow ? 0.85 : 0.7);
    canvas.drawPath(_spine, _fill);
    _fill.color = color;
    canvas.drawPath(_pieces, _fill);
    if (theme.highlightOpacity > 0) {
      _fill.color = theme.highlight.withValues(
        alpha: (theme.highlightOpacity * 0.7).clamp(0.0, 1.0),
      );
      canvas.drawPath(_spine, _fill);
    }
    if (flash > 0) {
      _fill.color = color.withValues(alpha: 0.45 * flash);
      for (final lean in const [-0.012, 0.012]) {
        canvas.save();
        canvas.rotate(lean);
        canvas.drawPath(_pieces, _fill);
        canvas.restore();
      }
    }
    canvas.restore();
  }
}
