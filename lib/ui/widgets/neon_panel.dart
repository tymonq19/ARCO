import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/game_theme.dart';

/// Rounded surface with a themed edge; the base of every overlay, HUD block and
/// list card.
///
/// The active [GameTheme] decides the fill, the edge, the corner shape
/// (superellipse for the glass look), whether a glow is cast and whether the
/// panel blurs what is behind it. Blur is opt-out per instance through [blur]:
/// the arena is never blurred, and neither are long scrolling lists.
class NeonPanel extends StatelessWidget {
  const NeonPanel({
    super.key,
    required this.child,
    this.color,
    this.padding,
    this.margin,
    this.radius,
    this.glow = true,
    this.opacity,
    this.blur = true,
  });

  final Widget child;

  /// Edge (and glow) tint; defaults to the theme's panel border.
  final Color? color;

  /// Defaults to 20 px scaled by the theme's spacing.
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// Corner radius; defaults to the theme's panel radius.
  final double? radius;

  /// Casts the theme's glow. Ignored by themes without one.
  final bool glow;

  /// Fill opacity; defaults to the theme's panel opacity.
  final double? opacity;

  /// Allows a translucent theme to blur the backdrop behind this panel. Set to
  /// false where the backdrop animates per frame or the panel is one row of
  /// many.
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final tint = color ?? theme.panelBorder;
    final r = radius ?? theme.cornerRadius;
    final shape = theme.border(
      r,
      color: tint.withValues(alpha: theme.panelBorderOpacity),
    );
    Widget body = Container(
      padding: padding ?? theme.pad(const EdgeInsets.all(20)),
      decoration: ShapeDecoration(
        color: theme.panelFill.withValues(alpha: opacity ?? theme.panelOpacity),
        shape: shape,
        shadows: glow && theme.hasGlow
            ? [
                BoxShadow(
                  color: tint.withValues(alpha: 0.18 * theme.glow),
                  blurRadius: 28,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: child,
    );
    if (theme.specularEdge) {
      body = CustomPaint(
        foregroundPainter: SpecularRim(shape: shape, color: theme.highlight),
        child: body,
      );
    }
    if (blur && theme.blurPanels) {
      body = ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: theme.panelBlur,
            sigmaY: theme.panelBlur,
          ),
          child: body,
        ),
      );
    }
    return margin == null ? body : Padding(padding: margin!, child: body);
  }
}

/// A small capitalised heading above a group of controls, in the theme's own
/// heading case and letter spacing. Shared so a section added to Settings — the
/// account block of SPEC 4.5 — is set exactly like the ones already there.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
      child: Text(
        theme.heading(title),
        style: TextStyle(
          color: theme.textDim,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: theme.headingCase == HeadingCase.upper ? 2 : 0.4,
        ),
      ),
    );
  }
}

/// The fine light rim along the top of a glass panel: the shape's own outline,
/// stroked with a vertical highlight → transparent gradient.
class SpecularRim extends CustomPainter {
  SpecularRim({required this.shape, required this.color});

  final ShapeBorder shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.55),
          color.withValues(alpha: 0.06),
          color.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.35, 1.0],
      ).createShader(rect);
    canvas.drawPath(shape.getOuterPath(rect), paint);
  }

  @override
  bool shouldRepaint(SpecularRim oldDelegate) =>
      oldDelegate.shape != shape || oldDelegate.color != color;
}

/// Title text with the theme's halo. Themes without a glow simply get solid
/// text, which is what the classic and modernist looks want.
class GlowText extends StatelessWidget {
  const GlowText(
    this.text, {
    super.key,
    this.color,
    this.style,
    this.textAlign,
  });

  final String text;

  /// Halo tint; defaults to the theme's accent.
  final Color? color;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final halo = color ?? theme.accent;
    final base = style ?? Theme.of(context).textTheme.headlineMedium;
    return Text(
      text,
      textAlign: textAlign,
      style: (base ?? const TextStyle()).copyWith(
        color: theme.textPrimary,
        shadows: theme.hasGlow
            ? [
                Shadow(
                  color: halo.withValues(alpha: 0.9 * theme.glow),
                  blurRadius: 18,
                ),
                Shadow(
                  color: halo.withValues(alpha: 0.45 * theme.glow),
                  blurRadius: 36,
                ),
              ]
            : null,
      ),
    );
  }
}

/// Full-screen themed backdrop: the arena's own gradient, plus its vignette and
/// CRT scanlines where the theme asks for them, so every menu matches the game
/// view.
class NeonBackground extends StatelessWidget {
  const NeonBackground({super.key, required this.child, this.backdrop});

  final Widget child;

  /// Something to animate between the gradient and the content — the drifting
  /// ball on the title screen (see `MenuBallBackdrop`). It is laid out over the
  /// whole screen, painted *under* the theme's grain so it is textured like the
  /// rest of the backdrop rather than pasted on top of it, and it never takes a
  /// pointer. Null on every screen the player is there to read.
  final Widget? backdrop;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    // Both the vignette and the scanlines texture the backdrop only, never the
    // content on top of it: a menu stays crisp, and a theme preview keeps
    // showing its own theme rather than the one the app happens to be in. The
    // arena draws its full-frame CRT mask itself (see [GamePainter]).
    Widget body = child;
    if (theme.scanlines || theme.vignette > 0) {
      body = CustomPaint(
        painter: ScreenGrain(
          scanlines: theme.scanlines,
          vignette: theme.vignette,
        ),
        child: body,
      );
    }
    if (backdrop != null) {
      body = Stack(
        // The content keeps exactly the constraints it had without a stack under
        // it: a backdrop must not be able to change a layout.
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(child: backdrop!),
          body,
        ],
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.background,
        gradient: RadialGradient(
          center: const Alignment(0, -0.35),
          radius: 1.1,
          colors: theme.backgroundGradient,
          stops: theme.backgroundStops,
        ),
      ),
      child: body,
    );
  }
}

/// Vignette plus scanlines over a menu screen. Static: it repaints only when
/// the flags or the size change, and it never absorbs a pointer.
class ScreenGrain extends CustomPainter {
  ScreenGrain({required this.scanlines, required this.vignette});

  /// Spacing of the scanlines in logical pixels.
  static const double spacing = 3;

  final bool scanlines;
  final double vignette;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    if (vignette > 0) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: Alignment.center,
            radius: 0.85,
            colors: [
              const Color(0x00000000),
              Colors.black.withValues(alpha: vignette * 0.4),
              Colors.black.withValues(alpha: vignette * 0.85),
            ],
            stops: const [0.5, 0.82, 1.0],
          ).createShader(rect),
      );
    }
    if (!scanlines) return;
    final path = Path();
    for (var y = 0.0; y < size.height; y += spacing) {
      path.moveTo(0, y);
      path.lineTo(size.width, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.22),
    );
  }

  @override
  bool shouldRepaint(ScreenGrain oldDelegate) =>
      oldDelegate.scanlines != scanlines || oldDelegate.vignette != vignette;
}
