import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';

import '../../app/game_theme.dart';

/// Row of hearts showing the remaining lives; [slots] hearts are drawn and the
/// first [lives] of them are filled. The colour and the halo follow the theme.
class HeartsRow extends StatelessWidget {
  const HeartsRow({
    super.key,
    required this.lives,
    this.slots = maxLives,
    this.size = 20,
    this.color,
  });

  final int lives;
  final int slots;
  final double size;

  /// Filled-heart colour; defaults to the theme's heart colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final tint = color ?? theme.heart;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < slots; i++)
          Padding(
            padding: EdgeInsets.only(right: i == slots - 1 ? 0 : 3),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 180),
              scale: i < lives ? 1.0 : 0.78,
              child: Icon(
                i < lives ? Icons.favorite : Icons.favorite_border,
                size: size,
                color: i < lives ? tint : theme.textDim.withValues(alpha: 0.45),
                shadows: i < lives && theme.hasGlow
                    ? [
                        Shadow(
                          color: tint.withValues(alpha: 0.8 * theme.glow),
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}
