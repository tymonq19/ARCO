import 'package:flutter/material.dart';

import '../../app/game_theme.dart';

/// "×3" badge; brighter and larger the higher the combo multiplier is. The four
/// tiers map onto theme accents, so the badge stays legible in every look.
class MultiplierBadge extends StatelessWidget {
  const MultiplierBadge({super.key, required this.multiplier, this.combo = 0});

  final int multiplier;
  final int combo;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final hot = multiplier > 1;
    final color = switch (multiplier) {
      >= 6 => theme.accentDuel,
      >= 3 => theme.accentSettings,
      >= 2 => theme.star,
      _ => theme.textDim,
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: hot ? 0.22 : 0.10),
        shape: theme.border(
          theme.radius(0.55),
          color: color.withValues(alpha: hot ? 0.9 : 0.35),
        ),
        shadows: hot && theme.hasGlow
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.35 * theme.glow),
                  blurRadius: 14,
                ),
              ]
            : null,
      ),
      child: Text(
        '×$multiplier',
        style: TextStyle(
          color: hot ? theme.textPrimary : theme.textDim,
          fontWeight: FontWeight.w900,
          fontSize: 15,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
