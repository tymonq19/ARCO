import 'package:flutter/material.dart';

/// Google's four-colour "G", drawn from the official 48 x 48 artwork.
///
/// A provider's mark is not ours to redraw: Google's sign-in branding asks for
/// this exact glyph, so the four outlines below are the published path data,
/// scaled into whatever box the button gives them. Drawing it means no asset to
/// ship, no image to scale badly and no colour that drifts from the brand — and
/// it stays the same glyph under all four of the app's themes, which is the
/// point of a logo.
class GoogleGPainter extends CustomPainter {
  const GoogleGPainter();

  /// The artwork's own coordinate system; the paths below are in these units.
  static const double viewBox = 48;

  /// Blue, green, yellow, red — the four arcs of the mark, as published.
  static const List<(Color, String)> outlines = <(Color, String)>[
    (
      Color(0xFF4285F4),
      'M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 '
          '5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z',
    ),
    (
      Color(0xFF34A853),
      'M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 '
          '2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z',
    ),
    (
      Color(0xFFFBBC05),
      'M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 '
          '16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z',
    ),
    (
      Color(0xFFEA4335),
      'M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 '
          '0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z',
    ),
  ];

  /// The four outlines as paths, parsed once. `Path` is mutable, so callers must
  /// not keep one — [paint] only reads them.
  static final List<(Color, Path)> _paths = <(Color, Path)>[
    for (final (color, data) in outlines) (color, parseSvgPath(data)),
  ];

  /// The mark's arcs in the artwork's own 48 x 48 units; a copy per call, so the
  /// caller can transform it freely.
  static List<(Color, Path)> arcs() => <(Color, Path)>[
    for (final (color, path) in _paths) (color, Path.from(path)),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Uniform, centred: the mark is square and must never be stretched.
    final scale = (size.shortestSide / viewBox);
    canvas.save();
    canvas.translate(
      (size.width - viewBox * scale) / 2,
      (size.height - viewBox * scale) / 2,
    );
    canvas.scale(scale);
    for (final (color, path) in _paths) {
      canvas.drawPath(path, Paint()..color = color);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(GoogleGPainter oldDelegate) => false;
}

/// Parses the subset of SVG path data the logos above use: `M m L l H h V v
/// C c S s Z z`, with implicit command repetition and the usual sloppy number
/// formats (`-.38`, `.5`, `4.55`).
///
/// Not a general SVG implementation — there are no arcs, no quadratics and no
/// error recovery beyond stopping. It exists so a brand mark can be a handful of
/// path strings instead of a binary asset, and it is small enough to read in one
/// sitting.
Path parseSvgPath(String d) {
  final path = Path();
  var i = 0;
  var cx = 0.0, cy = 0.0; // current point
  var sx = 0.0, sy = 0.0; // start of the current subpath
  var rx = 0.0, ry = 0.0; // reflection of the last cubic's second control
  var command = '';

  bool isDigitStart(String c) =>
      (c.codeUnitAt(0) ^ 0x30) <= 9 || c == '-' || c == '+' || c == '.';

  void skipSeparators() {
    while (i < d.length) {
      final c = d[i];
      if (c == ' ' || c == ',' || c == '\n' || c == '\r' || c == '\t') {
        i++;
      } else {
        break;
      }
    }
  }

  double number() {
    skipSeparators();
    final start = i;
    if (i < d.length && (d[i] == '-' || d[i] == '+')) i++;
    while (i < d.length) {
      final c = d[i];
      if ((c.codeUnitAt(0) ^ 0x30) <= 9) {
        i++;
      } else if (c == '.') {
        // A second dot starts the next number (`1.5.5` is 1.5 then .5).
        if (d.substring(start, i).contains('.')) break;
        i++;
      } else if ((c == 'e' || c == 'E') && i + 1 < d.length) {
        i++;
        if (d[i] == '-' || d[i] == '+') i++;
      } else {
        break;
      }
    }
    return double.tryParse(d.substring(start, i)) ?? 0;
  }

  while (i < d.length) {
    skipSeparators();
    if (i >= d.length) break;
    final c = d[i];
    if (!isDigitStart(c)) {
      command = c;
      i++;
    } else if (command.isEmpty) {
      break; // numbers before any command: nothing to do with them
    }
    switch (command) {
      case 'M':
      case 'm':
        final relative = command == 'm';
        final x = number(), y = number();
        cx = relative ? cx + x : x;
        cy = relative ? cy + y : y;
        path.moveTo(cx, cy);
        sx = cx;
        sy = cy;
        rx = cx;
        ry = cy;
        // Further coordinate pairs after a moveto are implicit linetos.
        command = relative ? 'l' : 'L';
      case 'L':
      case 'l':
        final relative = command == 'l';
        final x = number(), y = number();
        cx = relative ? cx + x : x;
        cy = relative ? cy + y : y;
        path.lineTo(cx, cy);
        rx = cx;
        ry = cy;
      case 'H':
      case 'h':
        final x = number();
        cx = command == 'h' ? cx + x : x;
        path.lineTo(cx, cy);
        rx = cx;
        ry = cy;
      case 'V':
      case 'v':
        final y = number();
        cy = command == 'v' ? cy + y : y;
        path.lineTo(cx, cy);
        rx = cx;
        ry = cy;
      case 'C':
      case 'c':
        final relative = command == 'c';
        final ox = relative ? cx : 0.0, oy = relative ? cy : 0.0;
        final x1 = ox + number(), y1 = oy + number();
        final x2 = ox + number(), y2 = oy + number();
        final x = ox + number(), y = oy + number();
        path.cubicTo(x1, y1, x2, y2, x, y);
        rx = 2 * x - x2;
        ry = 2 * y - y2;
        cx = x;
        cy = y;
      case 'S':
      case 's':
        final relative = command == 's';
        final ox = relative ? cx : 0.0, oy = relative ? cy : 0.0;
        final x2 = ox + number(), y2 = oy + number();
        final x = ox + number(), y = oy + number();
        path.cubicTo(rx, ry, x2, y2, x, y);
        rx = 2 * x - x2;
        ry = 2 * y - y2;
        cx = x;
        cy = y;
      case 'Z':
      case 'z':
        path.close();
        cx = sx;
        cy = sy;
        rx = cx;
        ry = cy;
      default:
        // An unsupported command would otherwise spin forever on its arguments.
        return path;
    }
  }
  return path;
}
