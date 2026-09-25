import 'dart:math' as math;
import 'dart:ui';

/// WCAG 2.1 relative luminance of an opaque colour.
double relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2.1 contrast ratio between [fg] (composited over [bg] when it is
/// translucent) and [bg]. Body text needs 4.5:1, large text 3:1, and a UI
/// component or graphical object 3:1 (WCAG 1.4.11).
double contrastRatio(Color fg, Color bg) {
  final a = relativeLuminance(Color.alphaBlend(fg, bg));
  final b = relativeLuminance(bg);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}
