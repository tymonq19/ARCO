/// Shop-card illustrations of a single collectable ball or paddle (SPEC §4.8).
///
/// The same idea as `lib/ui/widgets/theme_preview.dart`, one step narrower: that
/// one shows a whole theme, this one shows one item inside a theme. Both paint
/// with the real [GamePainter] over a real [GameState], so a card cannot lie
/// about what the player is buying — every skin here goes through exactly the
/// code the arena runs, the theme's own palette included.
///
/// The one liberty a card takes is scale, and it takes it openly: a ball is about
/// twelve logical pixels across in play, so [CosmeticArena.magnification]
/// enlarges the *whole arena* (never the ball alone) and defaults to about twice
/// life size for a ball. Pass `magnification: 1` for a true-size card. A paddle
/// card is life size already.
///
/// Nothing animates and the poses are built once and shared, so a grid of cards
/// costs one recorded picture each.
library;

import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';

import '../../app/cosmetics.dart';
import '../../app/game_theme.dart';
import '../../ui/widgets/neon_panel.dart';
import '../arena_geometry.dart';
import 'fx_state.dart';
import 'game_painter.dart';

/// Which of the two poses a card uses.
enum CosmeticCard {
  /// The ball mid-flight with its wake, the arena enlarged around it.
  ball,

  /// The player's own paddle on the bottom of the ring, at the size it is played
  /// at.
  paddle;

  /// The pose for a catalogue id: `ball.*` shows a ball, `paddle.*` a paddle.
  /// Anything else — a `theme.*` id, an item newer than this build — falls back
  /// to [ball] with the free default, so a shop grid degrades instead of
  /// throwing. Use `ThemePreview` for themes.
  static CosmeticCard forItem(String itemId) =>
      PaddleSkin.lookup(itemId) != null ? paddle : ball;
}

/// A framed card showing one item, in the look of [theme].
///
/// ```dart
/// CosmeticPreview(
///   itemId: 'ball.comet',          // the server's item id, verbatim
///   theme: GameTheme.of(context),  // or the theme being previewed
///   label: strings['ball.comet'],  // optional caption, in the theme's type
///   selected: equipped.ball.id == 'ball.comet',
///   onTap: () => equip('ball.comet'),
/// )
/// ```
class CosmeticPreview extends StatelessWidget {
  const CosmeticPreview({
    super.key,
    required this.itemId,
    required this.theme,
    this.width = defaultWidth,
    this.height = defaultHeight,
    this.label,
    this.selected = false,
    this.onTap,
    this.labelHeight = defaultLabelHeight,
    this.magnification,
  });

  static const double defaultWidth = 150;
  static const double defaultHeight = 124;
  static const double defaultLabelHeight = 30;

  /// The size a card is designed for.
  static const Size defaultSize = Size(defaultWidth, defaultHeight);

  /// The catalogue id of the item to draw, e.g. `ball.comet`, `paddle.halo`.
  final String itemId;

  /// The look to draw it in. Unrelated to the theme the app is running in — a
  /// shop screen normally passes the equipped theme.
  final GameTheme theme;

  final double width;
  final double height;

  /// Caption inside the card, set in the previewed theme's own type. Null hides
  /// the strip and gives the whole card to the arena.
  final String? label;

  /// Marks this item as the equipped one (ring + check badge).
  final bool selected;

  /// Makes the whole card tappable; null renders a plain illustration.
  final VoidCallback? onTap;

  /// Height of the caption strip; ignored when [label] is null.
  final double labelHeight;

  /// Arena magnification; null takes the sensible default for the item's pose.
  final double? magnification;

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
      child: Stack(
        fit: StackFit.expand,
        children: [
          CosmeticArena(
            itemId: itemId,
            theme: theme,
            bottomInset: height - arenaHeight,
            magnification: magnification,
          ),
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

/// The bare illustration, without a card: fills whatever box it is given and
/// paints one item with the real [GamePainter].
///
/// Useful where the illustration should be full-bleed (a wide "equipped" strip,
/// a hero); [CosmeticPreview] is the framed version.
class CosmeticArena extends StatelessWidget {
  const CosmeticArena({
    super.key,
    required this.itemId,
    required this.theme,
    this.bottomInset = 0,
    this.magnification,
  });

  /// The arena radius a phone gives the game, in logical pixels: the size every
  /// skin is designed to read at (a ball is 2 × 0.035 × 175 ≈ 12 px across).
  /// Magnification 1 means exactly this.
  static const double lifeSizeRadius = 175;

  /// What a ball card magnifies by unless told otherwise: enough to see a facet
  /// or a spark (a ball radius of about 11 px) while the wake still fits.
  static const double defaultBallMagnification = 1.8;

  /// Arena radius of a paddle card, in card widths. At 1.22 a 150 px card is life
  /// size, and the paddle's chord crosses about four fifths of it.
  static const double paddleCardRadius = 1.22;

  final String itemId;
  final GameTheme theme;

  /// Space at the bottom the illustration must stay clear of (a caption, say).
  /// The background still covers it.
  final double bottomInset;

  /// Multiplies the arena radius the pose would otherwise use. 1 is life size.
  final double? magnification;

  @override
  Widget build(BuildContext context) {
    final card = CosmeticCard.forItem(itemId);
    final equipped = Equipped(
      ball: BallSkin.parse(itemId),
      paddle: PaddleSkin.parse(itemId),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.hasBoundedWidth
              ? constraints.maxWidth
              : CosmeticPreview.defaultWidth,
          constraints.hasBoundedHeight
              ? constraints.maxHeight
              : CosmeticPreview.defaultHeight,
        );
        final usableHeight = math.max(1.0, size.height - bottomInset);
        final zoom =
            magnification ??
            (card == CosmeticCard.ball ? defaultBallMagnification : 1.0);
        final geometry = card == CosmeticCard.ball
            ? _ballGeometry(size, usableHeight, zoom)
            : _paddleGeometry(size, usableHeight, zoom);
        return CustomPaint(
          size: size,
          painter: GamePainter(
            stateOf: card == CosmeticCard.ball ? ballPose : paddlePose,
            fx: card == CosmeticCard.ball ? ballPoseFx() : paddlePoseFx(),
            geometry: geometry,
            theme: theme,
            equipped: equipped,
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }

  /// A window on the arena with the ball a little above and right of the middle,
  /// so its wake crosses the card from the lower left.
  ///
  /// The pose puts the ball at the arena's centre point, which is why the centre
  /// of the projection *is* where the ball lands.
  ArenaGeometry _ballGeometry(Size size, double usableHeight, double zoom) {
    final radius = lifeSizeRadius * zoom;
    return ArenaGeometry(
      size: size,
      center: Offset(size.width * 0.6, usableHeight * 0.44),
      radius: radius,
      rotated: false,
    );
  }

  /// The bottom of the ring, with the player's own paddle on it at the size it is
  /// played at: the arena's centre sits above the card.
  ArenaGeometry _paddleGeometry(Size size, double usableHeight, double zoom) {
    final radius = math.max(48.0, size.width * paddleCardRadius * zoom);
    return ArenaGeometry(
      size: size,
      center: Offset(size.width / 2, usableHeight * 0.74 - paddleRing * radius),
      radius: radius,
      rotated: false,
    );
  }
}

GameState? _ballPose;
GameState? _paddlePose;
FxState? _ballFx;
FxState? _paddleFx;

/// The shared ball pose: the ball at the arena's centre point, flying up and to
/// the right, nothing else on the board.
GameState ballPose() => _ballPose ??= _buildBallPose();

/// The effect state that goes with [ballPose]: a wake seeded from the ball's own
/// velocity and a fixed clock, so the illustration holds still.
FxState ballPoseFx() => _ballFx ??= _buildBallFx(ballPose());

/// The shared paddle pose: the player's paddle at the bottom of the ring, no ball
/// on the board.
GameState paddlePose() => _paddlePose ??= _buildPaddlePose();

/// The (empty) effect state that goes with [paddlePose].
FxState paddlePoseFx() => _paddleFx ??= FxState();

GameState _buildBallPose() {
  final state = GameState.initial(
    const GameConfig(mode: GameMode.solo, seed: 11),
  );
  state.phase = Phase.playing;
  state.serveTimer = 0;
  state.ball
    ..active = true
    ..x = 0
    ..y = 0
    ..vx = 0.78
    ..vy = 0.54
    ..speed = 0.95
    ..owner = 0;
  // Out of the card: a ball card is about the ball.
  state.players[0].paddle.angle = bottomCenterAngle;
  return state;
}

GameState _buildPaddlePose() {
  final state = GameState.initial(
    const GameConfig(mode: GameMode.solo, seed: 12),
  );
  state.phase = Phase.playing;
  state.serveTimer = 0;
  // No ball: the painter draws none and the wake stays empty, so the card shows
  // the paddle at rest, which is how it is seen almost all of the time.
  state.ball.active = false;
  state.players[0].paddle.angle = bottomCenterAngle;
  return state;
}

FxState _buildBallFx(GameState state) {
  final fx = FxState();
  // A clock that leaves the prism turned to a pleasing angle and the ember near
  // the top of a flicker; nothing advances it afterwards.
  fx.time = 0.62;
  // Far enough in that every spark of an ember's shower has a point of the path
  // to have been shed from. The counter is what anchors them (see FxState).
  fx.frames = 600;
  final ball = state.ball;
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
