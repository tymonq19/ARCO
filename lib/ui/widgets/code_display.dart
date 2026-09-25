import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/game_theme.dart';

/// The four room-code letters, each in its own glowing tile.
///
/// Tiles are [tileSize] wide where there is room for them and shrink to fit
/// narrower viewports (a 320-pt phone leaves ~229 px inside the lobby panel,
/// less than the 264 px four full-size tiles need), so the code is never
/// clipped — it is the only actionable content on the waiting screen.
class CodeDisplay extends StatelessWidget {
  const CodeDisplay({
    super.key,
    required this.code,
    this.color,
    this.tileSize = 56,
  });

  /// Horizontal margin on each side of a tile.
  static const double _gap = 5;

  final String code;

  /// Tile tint; defaults to the theme's duel accent.
  final Color? color;
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final tint = color ?? theme.accentDuel;
    final chars = code.split('');
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _tileSizeFor(constraints.maxWidth, chars.length);
        // Sharp themes keep the tiles nearly square.
        final radius = math.min(size * 0.25, theme.cornerRadius * 0.8);
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in chars)
              Container(
                width: size,
                height: size * 1.2,
                margin: const EdgeInsets.symmetric(horizontal: _gap),
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: tint.withValues(alpha: 0.12),
                  shape: theme.border(
                    radius,
                    color: tint.withValues(alpha: 0.75),
                    width: 1.6,
                  ),
                  shadows: theme.hasGlow
                      ? [
                          BoxShadow(
                            color: tint.withValues(alpha: 0.25 * theme.glow),
                            blurRadius: 20,
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  c,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: size * 0.55,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                    shadows: theme.hasGlow
                        ? [
                            Shadow(
                              color: tint.withValues(alpha: 0.9 * theme.glow),
                              blurRadius: 16,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The largest tile edge that keeps [count] tiles (plus their margins) inside
  /// [maxWidth], capped at [tileSize]. Unbounded width keeps the full size.
  double _tileSizeFor(double maxWidth, int count) {
    if (count <= 0 || !maxWidth.isFinite) return tileSize;
    final fit = maxWidth / count - 2 * _gap;
    return math.max(0, math.min(tileSize, fit));
  }
}
