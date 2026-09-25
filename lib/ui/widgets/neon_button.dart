import 'package:flutter/material.dart';

import '../../app/game_theme.dart';

/// Big, finger-friendly button (minimum height 56 px), drawn in the active
/// [GameTheme]: tinted body and bright label when [filled], otherwise a ghost
/// body with a themed outline. The glow, the corner shape and the label colour
/// all come from the theme, so the same button reads as neon, as arcade, as
/// print or as glass.
class NeonButton extends StatefulWidget {
  const NeonButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color,
    this.filled = true,
    this.icon,
    this.height = 58,
    this.fontSize = 17,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Accent; defaults to the theme's primary accent.
  final Color? color;
  final bool filled;
  final IconData? icon;
  final double height;
  final double fontSize;

  @override
  State<NeonButton> createState() => _NeonButtonState();
}

class _NeonButtonState extends State<NeonButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final enabled = widget.onPressed != null;
    final color = enabled ? (widget.color ?? theme.accent) : theme.textDim;
    final body = widget.filled
        ? color.withValues(alpha: _down ? 0.38 : 0.20)
        : theme.panelFill.withValues(alpha: _down ? 0.9 : 0.55);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        // The body is a decorated Container, which is not hit-testable on its
        // own: without this the button would only react on the glyphs.
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _down ? 0.97 : 1,
          duration: const Duration(milliseconds: 90),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: widget.height,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: ShapeDecoration(
              color: body,
              shape: theme.border(
                theme.radius(0.82),
                color: color.withValues(alpha: enabled ? 0.85 : 0.35),
                width: 1.8,
              ),
              shadows: enabled && theme.hasGlow
                  ? [
                      BoxShadow(
                        color: color.withValues(
                          alpha: (_down ? 0.45 : 0.28) * theme.glow,
                        ),
                        blurRadius: _down ? 26 : 18,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, color: color, size: widget.fontSize + 5),
                  const SizedBox(width: 10),
                ],
                // Scale a label down rather than clipping it: the Polish
                // strings are longer than the English ones they were sized
                // for, and a half-width button ("UDOSTĘPNIJ" next to
                // "KOPIUJ KOD") used to end in an ellipsis mid-word. Labels
                // that already fit are laid out at their natural size, so
                // nothing else changes.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: enabled ? theme.textPrimary : theme.textDim,
                        fontSize: widget.fontSize,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small round icon button used for pause / back / close inside the arena.
class NeonIconButton extends StatelessWidget {
  const NeonIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.color,
    this.tooltip,
    this.size = 46,
  });

  final IconData icon;
  final VoidCallback onPressed;

  /// Icon and outline colour; defaults to the theme's primary accent.
  final Color? color;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final tint = color ?? theme.accent;
    return Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.panelFill.withValues(alpha: 0.75),
            shape: BoxShape.circle,
            border: Border.all(color: tint.withValues(alpha: 0.6), width: 1.4),
          ),
          child: Icon(icon, color: tint, size: size * 0.5),
        ),
      ),
    );
  }
}
