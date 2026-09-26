import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';

import '../../app/game_theme.dart';
import '../../game/arena_geometry.dart';
import '../../game/render/fx_state.dart';
import '../../game/render/game_painter.dart';
import 'neon_panel.dart';

/// A small, static illustration of the arena in a given [GameTheme]: the ring,
/// the paddle, the ball with its wake, a star and a wall.
///
/// It paints with the real [GamePainter] over a real [GameState], so a preview
/// can never lie about what a theme looks like — every style flag (glow, trail
/// style, stroke caps, ring width, scanlines, vignette) is exercised by the same
/// code that draws the game. The pose is built once and shared by every
/// instance, nothing animates, and the whole thing sits behind a
/// [RepaintBoundary], so a preview costs one recorded picture.
///
/// The card itself is drawn in the previewed theme (background, corner shape,
/// specular rim, type face); only the selection ring uses the ambient theme, so
/// it stays visible whatever is being previewed.
class ThemePreview extends StatelessWidget {
  const ThemePreview({
    super.key,
    required this.theme,
    this.width = defaultWidth,
    this.height = defaultHeight,
    this.label,
    this.selected = false,
    this.onTap,
    this.labelHeight = defaultLabelHeight,
  });

  static const double defaultWidth = 150;
  static const double defaultHeight = 220;
  static const double defaultLabelHeight = 34;

  /// The size the illustration is designed for.
  static const Size defaultSize = Size(defaultWidth, defaultHeight);

  /// The look to illustrate. Unrelated to the theme the app is running in.
  final GameTheme theme;

  final double width;
  final double height;

  /// Caption inside the card, set in the previewed theme's own type. Null hides
  /// the strip and gives the whole card to the arena.
  final String? label;

  /// Marks this preview as the current choice (ring + check badge).
  final bool selected;

  /// Makes the whole card tappable; null renders a plain illustration.
  final VoidCallback? onTap;

  /// Height of the caption strip; ignored when [label] is null.
  final double labelHeight;

  @override
  Widget build(BuildContext context) {
    final ambient = GameTheme.of(context);
    final arenaHeight = label == null
        ? height
        : (height - labelHeight).clamp(0.0, height);
    final ring = selected
        ? ambient.accent
        : theme.panelBorder.withValues(alpha: theme.panelBorderOpacity);
    final shape = theme.border(theme.cornerRadius);
    Widget card = Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(color: theme.background, shape: shape),
      foregroundDecoration: ShapeDecoration(
        shape: theme.border(
          theme.cornerRadius,
          color: ring,
          width: selected ? 2.4 : 1.2,
        ),
      ),
      // The arena is painted across the whole card and the caption sits over
      // the empty band below the ring: the theme's background gradient then
      // runs edge to edge instead of meeting a differently tinted strip.
      child: Stack(
        fit: StackFit.expand,
        children: [
          ThemeArena(theme: theme, bottomInset: height - arenaHeight),
          if (label != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: labelHeight,
                child: Center(
                  child: Text(
                    theme.heading(label!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontFamily: theme.fontFamily,
                      fontFamilyFallback: theme.fontFamilyFallback,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: theme.headingCase == HeadingCase.upper
                          ? 2
                          : 0.2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (theme.specularEdge) {
      card = CustomPaint(
        foregroundPainter: SpecularRim(shape: shape, color: theme.highlight),
        child: card,
      );
    }
    if (selected) {
      card = Stack(
        clipBehavior: Clip.none,
        children: [
          card,
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: ambient.accent,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check, size: 15, color: ambient.background),
            ),
          ),
        ],
      );
    }
    card = RepaintBoundary(child: card);
    if (onTap == null) return card;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: card,
      ),
    );
  }
}

/// The bare arena illustration, without a card: fills whatever box it is given
/// and paints the shared pose with the real [GamePainter].
///
/// Useful where the illustration should be full-bleed (a first-launch chooser
/// hero, for instance); [ThemePreview] is the framed version.
class ThemeArena extends StatelessWidget {
  const ThemeArena({super.key, required this.theme, this.bottomInset = 0});

  /// Gutter around the ring, as a fraction of the shorter edge.
  ///
  /// [ArenaGeometry.fit] reserves a fixed 16 px gutter, which is right on a
  /// phone but eats a quarter of a 124 px card, so the illustration scales its
  /// own gutter instead. Everything else — the projection, the y flip, the
  /// angles — is the arena's real geometry.
  static const double insetFraction = 0.06;

  final GameTheme theme;

  /// Space at the bottom the ring must stay clear of (a caption, say). The
  /// background still covers it.
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.hasBoundedWidth
              ? constraints.maxWidth
              : ThemePreview.defaultWidth,
          constraints.hasBoundedHeight
              ? constraints.maxHeight
              : ThemePreview.defaultHeight,
        );
        final usableHeight = math.max(1.0, size.height - bottomInset);
        final short = math.min(size.width, usableHeight);
        final inset = (short * insetFraction).clamp(4.0, 16.0);
        return CustomPaint(
          size: size,
          painter: GamePainter(
            stateOf: previewState,
            fx: previewFx(),
            geometry: ArenaGeometry(
              size: size,
              center: Offset(size.width / 2, usableHeight / 2),
              radius: math.max(8.0, short / 2 - inset),
              rotated: false,
            ),
            theme: theme,
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

GameState? _state;
FxState? _fx;

/// The shared, frozen pose every preview draws: a paddle at the lower right, the
/// ball mid-flight with a wake behind it, one wall and one star.
GameState previewState() => _state ??= _buildPreviewState();

/// The frozen effect state that goes with [previewState]: a seeded ball wake and
/// a fixed clock, so the spinning star holds still.
FxState previewFx() => _fx ??= _buildPreviewFx(previewState());

/// `wallCurveSegments + 1` vertices on an arc, the way the simulation builds a
/// curved wall: centre (-0.19, -0.28), radius 0.26, swept 1.75 rad.
List<double> _previewArc() {
  const cx = -0.19;
  const cy = -0.28;
  const radius = 0.26;
  const start = -0.35;
  const sweep = 1.75;
  final points = <double>[];
  for (var i = 0; i <= wallCurveSegments; i++) {
    final a = start + sweep * i / wallCurveSegments;
    points.add(cx + radius * math.cos(a));
    points.add(cy + radius * math.sin(a));
  }
  return points;
}

GameState _buildPreviewState() {
  final state = GameState.initial(
    const GameConfig(mode: GameMode.solo, seed: 7),
  );
  state.phase = Phase.playing;
  state.serveTimer = 0;
  state.balls[0]
    ..active = true
    ..x = -0.10
    ..y = 0.22
    ..vx = -0.42
    ..vy = 0.52
    ..speed = 0.67
    ..owner = 0;
  // Lower right, so the paddle reads as "mine" without covering the wall.
  state.players[0].paddle.angle = 5.15;
  // A curved wall rather than a straight one (SPEC §2.3): the shaped walls are
  // the thing each theme now has to draw well, so the card that sells a theme
  // shows one. Eight chords on an arc of about 100°, which is what the
  // simulation spawns.
  state.walls.add(
    Wall(
      id: 1,
      shape: WallShape.curved,
      points: _previewArc(),
      ttl: 600,
      age: 120,
    ),
  );
  state.pickups.add(
    Pickup(id: 2, type: PickupType.star, x: 0.34, y: 0.30, ttl: 400),
  );
  return state;
}

FxState _buildPreviewFx(GameState state) {
  final fx = FxState();
  // A clock value that leaves the star at a pleasing angle; nothing advances it
  // afterwards, so the illustration is completely static.
  fx.time = 0.62;
  final ball = state.balls[0];
  final x = ball.x;
  final y = ball.y;
  // Walk the ball back along its velocity and feed the trail forwards, which is
  // exactly what a live frame does — the wake is real, not drawn by hand.
  const dt = 1 / 60;
  for (var i = FxState.trailLength - 1; i >= 0; i--) {
    ball
      ..x = x - ball.vx * dt * i
      ..y = y - ball.vy * dt * i;
    fx.trackBall(ball, smooth: false);
  }
  ball
    ..x = x
    ..y = y;
  return fx;
}
