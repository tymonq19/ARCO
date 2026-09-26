/// The drawing side of the cosmetic items (SPEC §4.8): the contract every ball
/// and paddle skin implements, plus the palette rules they share.
///
/// **The division of labour: the theme owns the palette, the item owns the shape
/// and the motion.** A comet in Modernist is a comet drawn in ink and vermilion
/// on paper, not a neon comet pasted onto a light background — so nothing in
/// here carries a colour of its own. Every colour is read from the current
/// [GameTheme], and every skin is expected to read at the real size (a ball is
/// about 12 logical pixels across on a phone) in all four themes, the light one
/// included.
///
/// **Nothing here can touch the simulation.** The painter hands the art the true
/// collision radius and the true angular sweep; decoration may reach outside
/// them (a tail, a bloom, a spark) but the solid silhouette never lies about
/// where the ball or the paddle actually is. That is what keeps a bought item
/// from being an advantage — and the server, which re-simulates every replay,
/// from having to care what anybody equipped.
///
/// **Frame time is the budget.** Shaders, mask filters, paths and scratch
/// buffers are built in [CosmeticArt.prepare], which the painter calls only when
/// the arena size or the theme changes; `paint` allocates nothing but a handful
/// of faded [Color]s and draws a bounded number of primitives.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import '../../app/cosmetics.dart';
import '../../app/game_theme.dart';
import '../arena_geometry.dart';
import 'fx_state.dart';

/// Blur radius of the medium glow pass, matching the arena's own.
double glowSigmaMedium(double scale, double glow) =>
    math.max(2.0, scale * 0.03 * glow);

/// Blur radius of the wide glow pass, matching the arena's own.
double glowSigmaWide(double scale, double glow) =>
    math.max(4.0, scale * 0.07 * glow);

/// Base of every skin's drawing code: holds the current palette and scale and
/// gives subclasses one place to build everything expensive.
abstract class CosmeticArt {
  GameTheme _theme = GameThemes.neon;
  double _scale = -1;
  Color _secondTint = GameThemes.neon.trail;

  /// The palette in force. Set by [prepare]; never chosen by the art itself.
  GameTheme get theme => _theme;

  /// Arena radius in logical pixels — the scale every sim unit multiplies by.
  double get scale => _scale;

  /// The colour ball [index]'s wake and coloured accents are drawn in
  /// (SPEC §2.3: a game has one or two balls).
  ///
  /// Ball 0 keeps the theme's own [GameTheme.trail], so the one-ball game looks
  /// exactly as it always has. Ball 1 gets a second hue derived from that one by
  /// [secondBallTint], computed once per palette in [prepare].
  ///
  /// This is the **only** thing a second ball changes about a skin: the
  /// silhouette, the radius and the body colour are identical, because the
  /// silhouette is the hitbox and it must not start lying about which ball is
  /// which.
  Color tintFor(int index) => index <= 0 ? _theme.trail : _secondTint;

  /// How long ball [index]'s wake is, as a fraction of the skin's own length.
  ///
  /// The second cue for telling two balls apart, and the one that survives a
  /// palette with only two colours in it (Modernist is ink on paper): the second
  /// ball's tail is visibly shorter, whatever the theme and whatever the skin.
  /// Hue alone is not enough, and neither is length alone.
  double wakeScale(int index) => index <= 0 ? 1.0 : 0.6;

  /// Installs a palette and a scale, rebuilding the cached objects when either
  /// changed.
  ///
  /// Cheap enough to call once per frame (two comparisons) and safe to call from
  /// the painter's hot path, which is exactly what it is for: a mask filter or a
  /// path built inside `paint` would be rebuilt sixty times a second.
  void prepare(GameTheme theme, double scale) {
    if (_scale == scale && identical(_theme, theme)) return;
    _theme = theme;
    _scale = scale;
    // Before onPrepare, so a skin that bakes a colour there (an ember's coal)
    // can build one per ball.
    _secondTint = secondBallTint(theme);
    onPrepare();
  }

  /// Rebuilds everything that depends on the palette or the scale. Called by
  /// [prepare] only, and only when something actually changed.
  void onPrepare() {}

  /// A blur filter, or null in a theme with no glow at all (which then records
  /// no blur passes — the flat themes must stay flat, and cheap).
  MaskFilter? glowFilter(double sigma) =>
      _theme.hasGlow ? MaskFilter.blur(BlurStyle.normal, sigma) : null;

  /// [BlendMode.plus] where the theme blooms, ordinary compositing where it does
  /// not: additive drawing over Modernist's paper washes out to white instead of
  /// darkening it.
  BlendMode get lightBlend =>
      _theme.hasGlow ? BlendMode.plus : BlendMode.srcOver;
}

/// How one ball skin is drawn.
///
/// Two calls per frame **per ball**, in the painter's own order: the wake goes
/// down first (under the paddles, like the trail always has), then the body.
/// One instance draws every ball, so nothing may be cached per ball between
/// calls; the ball being drawn is named by the `index` argument, which is its
/// index into `GameState.balls`.
abstract class BallArt extends CosmeticArt {
  /// The catalogue item this draws.
  BallSkin get skin;

  /// The wake behind ball [index], in screen space. Called once per frame before
  /// the body, and only while that ball is live.
  void paintWake(
    Canvas canvas,
    ArenaGeometry geometry,
    FxState fx,
    int index,
  ) {}

  /// Ball [index] itself.
  ///
  /// [radius] is the true collision radius in pixels: the solid part of the
  /// silhouette must fill it and must not exceed it, whatever decoration reaches
  /// further. [dirX], [dirY] is the unit direction of travel **in screen
  /// space** (already flipped, and rotated for duel player 1).
  void paintBody(
    Canvas canvas,
    Offset center,
    double radius,
    double dirX,
    double dirY,
    FxState fx,
    int index,
  );

  // ---------------------------------------------------------------- wake tools

  /// Scratch buffer for [collectWake]: x, y interleaved, newest first.
  late final Float32List _wake = Float32List(FxState.trailLength * 2);

  /// Screen-space wake points of ball [index], newest first, walking back along
  /// that ball's real path until [maxLength] simulation units of it have been
  /// covered.
  ///
  /// Returns the number of points written to [wakeX]/[wakeY]. Capping by path
  /// length rather than by sample count keeps a tail the same size at every ball
  /// speed, and the projection is inlined so that walking 48 samples allocates
  /// nothing at all. [maxLength] is scaled by [wakeScale], which is the second
  /// ball's shorter tail — so every skin gets that cue for free.
  int collectWake(
    ArenaGeometry geometry,
    FxState fx,
    int index, {
    required double maxLength,
    int maxPoints = FxState.trailLength,
  }) {
    final trail = fx.ball(index);
    final n = trail.trailCount;
    if (n < 2) return 0;
    final scale = wakeScale(index);
    final limit = math.min((maxPoints * scale).ceil(), n);
    final budget = maxLength * scale;
    final cx = geometry.center.dx;
    final cy = geometry.center.dy;
    final r = geometry.radius;
    final flip = geometry.rotated;
    var covered = 0.0;
    var px = 0.0;
    var py = 0.0;
    var count = 0;
    for (var i = n - 1; i >= 0 && count < limit; i--) {
      final x = trail.trailX(i);
      final y = trail.trailY(i);
      if (count > 0) {
        final dx = x - px;
        final dy = y - py;
        covered += math.sqrt(dx * dx + dy * dy);
        if (covered > budget) break;
      }
      _wake[count * 2] = flip ? cx - x * r : cx + x * r;
      _wake[count * 2 + 1] = flip ? cy + y * r : cy - y * r;
      px = x;
      py = y;
      count++;
    }
    return count;
  }

  /// x of wake point [i] (0 = the ball's own position), valid after
  /// [collectWake].
  double wakeX(int i) => _wake[i * 2];

  /// y of wake point [i], valid after [collectWake].
  double wakeY(int i) => _wake[i * 2 + 1];

  /// Fills [into] with a plume along the [count] points [collectWake] wrote:
  /// [halfWidth] pixels wide where it meets the ball and pinched to a point at
  /// the far end, following the curve the ball actually flew. [ease] shapes the
  /// taper — higher is more needle.
  ///
  /// The [Path] is passed in and reset rather than returned, so a tail that is
  /// rebuilt every frame still allocates nothing.
  /// [spread] fans the plume sideways as it goes: 0 at the ball, [spread] pixels
  /// off the path at the tip. Three plumes with different spreads leave one point
  /// and separate, which is what refraction looks like.
  void buildPlume(
    Path into,
    int count,
    double halfWidth, {
    double ease = 1.25,
    double spread = 0,
  }) {
    into.reset();
    if (count < 3) return;
    final last = count - 1;
    for (var i = 0; i < count; i++) {
      final t = i / last;
      final w = halfWidth * math.pow(1 - t, ease).toDouble();
      final (nx, ny) = wakeNormal(i, count);
      final off = spread * t;
      final x = wakeX(i) + nx * (w + off);
      final y = wakeY(i) + ny * (w + off);
      if (i == 0) {
        into.moveTo(x, y);
      } else {
        into.lineTo(x, y);
      }
    }
    for (var i = last; i >= 0; i--) {
      final t = i / last;
      final w = halfWidth * math.pow(1 - t, ease).toDouble();
      final (nx, ny) = wakeNormal(i, count);
      final off = spread * t;
      into.lineTo(wakeX(i) - nx * (w - off), wakeY(i) - ny * (w - off));
    }
    into.close();
  }

  /// Unit normal of the wake at point [i], from a central difference.
  (double, double) wakeNormal(int i, int count) {
    final a = i == 0 ? 0 : i - 1;
    final b = i == count - 1 ? i : i + 1;
    final dx = wakeX(a) - wakeX(b);
    final dy = wakeY(a) - wakeY(b);
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.0001) return (0, 0);
    return (-dy / len, dx / len);
  }
}

/// How one paddle skin is drawn.
///
/// Every skin spans the same angle, because the simulation bounces the ball off
/// an arc of `2 * paddleHalfWidth`: a skin that looked narrower would be a lie
/// the player pays for, and one that looked wider would promise a save it cannot
/// make. Radial thickness is free — nothing collides with it.
abstract class PaddleArt extends CosmeticArt {
  /// The catalogue item this draws.
  PaddleSkin get skin;

  /// Draws one paddle.
  ///
  /// [centerAngle] is the canvas angle (y down, clockwise, already rotated for
  /// duel player 1) of the middle of the paddle; the skin spans
  /// `2 * paddleHalfWidth` radians around it — every skin, always. [color] is
  /// the player's own palette colour and [flash] the 0..1 hit flash.
  void paint(
    Canvas canvas,
    Offset center,
    double radius,
    double centerAngle,
    Color color,
    double flash,
    FxState fx,
  );
}

// ------------------------------------------------------------------- palettes

/// The second ball's colour, derived from the theme rather than picked
/// (SPEC §2.3).
///
/// A game can have two balls, and two identical streaks are two things the eye
/// has to keep apart by position alone. So the second one gets its own hue — but
/// a hue *the theme already contains*, because a hard-coded colour would be the
/// one thing in the arena that does not belong to the look.
///
/// Two cases, and between them they cover the four themes:
/// * a chromatic trail (Neon's cyan, Glass's sky blue) is rotated 150° around
///   the wheel at the same saturation and lightness, which lands well clear of
///   it without leaving the palette's own brightness;
/// * a neutral trail (Classic's white, Modernist's ink) has no hue to rotate, so
///   it is pulled most of the way towards [GameTheme.heart] instead — the second
///   entity colour every palette has, and in Modernist the vermilion the whole
///   look is built around.
///
/// It is never mistaken for the wake of ball 0, and (together with
/// [CosmeticArt.wakeScale]) it is what makes two balls followable.
Color secondBallTint(GameTheme theme) {
  final hsl = HSLColor.fromColor(theme.trail);
  if (hsl.saturation > 0.25) {
    return hsl.withHue((hsl.hue + 150) % 360).toColor();
  }
  return Color.lerp(theme.trail, theme.heart, 0.72)!;
}

/// The three colours a prism splits the palette into, for ball [index].
///
/// Chosen so that the triple is distinct in all four themes: cyan / rose /
/// violet in Neon, white / red / grey in Classic, ink / vermilion / slate on
/// Modernist's paper, and cyan / pink / steel in Glass. The second ball leads
/// with its own tint and takes the remaining two in the other order, so the two
/// prisms are never the same three colours in the same places.
List<Color> prismEdges(GameTheme theme, [int index = 0]) => index <= 0
    ? <Color>[theme.trail, theme.heart, theme.wall]
    : <Color>[secondBallTint(theme), theme.wall, theme.star];

/// The hottest colour the palette has, for an ember's core and halo: the star
/// colour in the dark themes (amber, gold, yellow) and the accent in a light one
/// (Modernist's star is ink, its accent is vermilion).
///
/// The second ball burns in its own tint instead, so two cinders on the board are
/// two different fires.
Color emberHot(GameTheme theme, [int index = 0]) => index > 0
    ? secondBallTint(theme)
    : (theme.isDark ? theme.star : theme.accent);

/// The colour an ember's sparks fly in.
Color emberSpark(GameTheme theme, [int index = 0]) =>
    index > 0 ? theme.star : theme.heart;
