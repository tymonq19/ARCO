import 'dart:math' as math;
import 'dart:ui';

import 'package:arco_core/arco_core.dart';

/// Maps simulation coordinates (unit circle, y up, angles counter-clockwise)
/// to screen pixels. The renderer flips y; player 1 in a duel additionally
/// sees the board rotated by 180° so their own paddle is at the bottom.
class ArenaGeometry {
  const ArenaGeometry({
    required this.size,
    required this.center,
    required this.radius,
    required this.rotated,
  });

  /// Horizontal gutter on each side of the arena (SPEC: diameter ≤ width − 32).
  static const double sidePadding = 16;

  /// Vertical breathing room between the ring and the HUD.
  static const double verticalPadding = 12;

  final Size size;
  final Offset center;

  /// Arena radius in pixels; `scale` for everything drawn in sim units.
  final double radius;
  final bool rotated;

  /// Largest arena that fits [size] minus the HUD insets, centered in the
  /// remaining space.
  factory ArenaGeometry.fit(
    Size size, {
    double topInset = 0,
    double bottomInset = 0,
    bool rotated = false,
  }) {
    final availH = math.max(0.0, size.height - topInset - bottomInset);
    final diameter = math.max(
      10.0,
      math.min(size.width - 2 * sidePadding, availH - 2 * verticalPadding),
    );
    return ArenaGeometry(
      size: size,
      center: Offset(size.width / 2, topInset + availH / 2),
      radius: diameter / 2,
      rotated: rotated,
    );
  }

  double get scale => radius;

  Offset toScreen(double x, double y) => rotated
      ? Offset(center.dx - x * radius, center.dy + y * radius)
      : Offset(center.dx + x * radius, center.dy - y * radius);

  /// Sim-space x for a screen point.
  double simX(Offset p) =>
      rotated ? -(p.dx - center.dx) / radius : (p.dx - center.dx) / radius;

  /// Sim-space y for a screen point.
  double simY(Offset p) =>
      rotated ? (p.dy - center.dy) / radius : -(p.dy - center.dy) / radius;

  /// Math angle (radians, y up) of a screen point relative to the center.
  double angleAt(Offset p) => math.atan2(simY(p), simX(p));

  /// Canvas angle (radians, y down, clockwise) for a math angle.
  double canvasAngle(double mathAngle) =>
      rotated ? -(mathAngle + math.pi) : -mathAngle;

  @override
  bool operator ==(Object other) =>
      other is ArenaGeometry &&
      other.size == size &&
      other.center == center &&
      other.radius == radius &&
      other.rotated == rotated;

  @override
  int get hashCode => Object.hash(size, center, radius, rotated);
}

/// Wraps an angle into [0, tau).
double normalizeAngle(double a) {
  var r = a % (2 * math.pi);
  if (r < 0) r += 2 * math.pi;
  if (r >= 2 * math.pi) r = 0;
  return r;
}

/// Signed shortest difference `target - from` in (-pi, pi].
double angleDelta(double target, double from) {
  var d = (target - from) % (2 * math.pi);
  if (d > math.pi) d -= 2 * math.pi;
  if (d <= -math.pi) d += 2 * math.pi;
  return d;
}

/// Quantizes a math angle to the 0..4095 aim scale of [PlayerInput].
int quantizeAim(double angle) {
  final q = (normalizeAngle(angle) * inputAimSteps / (2 * math.pi)).floor();
  return q < 0 ? 0 : (q >= inputAimSteps ? 0 : q);
}
