/// What the player has equipped, and the ids the server's catalogue sells
/// (SPEC §4.8, `server/lib/src/catalogue.dart`).
///
/// **Everything here is purely cosmetic.** A skin picks a shape and a motion,
/// never a number: not a paddle width, not a ball speed, not a life. The server
/// re-simulates every submitted solo replay to verify it, so an item that
/// touched the simulation would make *honest* runs fail verification — and a
/// leaderboard where money buys rank is worth nothing. That is why this file
/// holds ids and nothing else, why `packages/arco_core` never sees it, and why
/// the drawing code is handed the true collision radius rather than a radius of
/// its own.
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

/// The collectable ball skins, in catalogue order.
///
/// [id] is the server's item id, verbatim — the same string the shop endpoints
/// take and return. `test/game/cosmetic_ids_test.dart` pins these against
/// `server/lib/src/catalogue.dart`, so renaming one breaks the build instead of
/// quietly breaking the shop.
enum BallSkin {
  /// The glowing dot the game has always drawn. Free, and the default.
  orb('ball.orb'),

  /// A nucleus with a long tapering plume.
  comet('ball.comet'),

  /// A turning facet that splits the palette into coloured edges.
  prism('ball.prism'),

  /// A flickering cinder that sheds sparks along its path.
  ember('ball.ember');

  const BallSkin(this.id);

  /// The server's catalogue id.
  final String id;

  /// What a player has before they ever choose, and what an unknown id resolves
  /// to. Matches `Catalogue.defaultFor(CosmeticKind.ball)`: the first free item.
  static const BallSkin fallback = orb;

  /// The ball with exactly this catalogue id, or null when this build has no such
  /// item — which is what a `paddle.*` id, a `theme.*` id and an item the server
  /// added after this build shipped all are.
  static BallSkin? lookup(String? id) {
    for (final skin in values) {
      if (skin.id == id) return skin;
    }
    return null;
  }

  /// Resolves a catalogue id; anything this build does not know — an item added
  /// to the server after it shipped, a corrupt preference — resolves to
  /// [fallback] rather than throwing. A shop card must not be able to crash the
  /// arena.
  static BallSkin parse(String? id) => lookup(id) ?? fallback;
}

/// The collectable paddle skins, in catalogue order.
///
/// Every one of them spans exactly `2 * paddleHalfWidth` radians, because that
/// is the dimension the simulation bounces off: a skin may be thinner, softer or
/// segmented, but it may never look narrower than the paddle really is.
enum PaddleSkin {
  /// The plain arc the renderer has always drawn. Free, and the default.
  arc('paddle.arc'),

  /// Thin, tapering to sharp points at both tips.
  blade('paddle.blade'),

  /// A slim core inside a soft outer bloom.
  halo('paddle.halo'),

  /// Angled segments over a continuous spine.
  chevron('paddle.chevron');

  const PaddleSkin(this.id);

  final String id;

  static const PaddleSkin fallback = arc;

  /// The paddle with exactly this catalogue id, or null when this build has no
  /// such item.
  static PaddleSkin? lookup(String? id) {
    for (final skin in values) {
      if (skin.id == id) return skin;
    }
    return null;
  }

  static PaddleSkin parse(String? id) => lookup(id) ?? fallback;
}

/// Whether this build knows how to draw [itemId].
///
/// True for the `ball.*` and `paddle.*` ids of this build's catalogue, false for
/// a `theme.*` id (those are [GameThemes]' business) and for anything a newer
/// server has added — which is what lets a shop screen say "update the app to
/// wear this" instead of selling something that would come out as the default.
bool canRenderItem(String? itemId) =>
    BallSkin.lookup(itemId) != null || PaddleSkin.lookup(itemId) != null;

/// The one ball and the one paddle currently worn.
///
/// Immutable and cheap to compare, so it is provided above the navigator exactly
/// like [GameTheme] is and a change repaints the arena on the next frame.
@immutable
class Equipped {
  const Equipped({this.ball = BallSkin.orb, this.paddle = PaddleSkin.arc});

  /// Reads the `equipped` map of `GET /api/shop/inventory` (`{"ball":"ball.orb",
  /// "paddle":"paddle.arc", ...}`). Unknown ids and missing slots fall back to
  /// the free defaults, so a client that is behind the server still renders.
  factory Equipped.fromWire(Map<String, dynamic>? equipped) {
    if (equipped == null) return defaults;
    return Equipped(
      ball: BallSkin.parse(equipped['ball'] as String?),
      paddle: PaddleSkin.parse(equipped['paddle'] as String?),
    );
  }

  /// The free items every player owns without buying anything.
  static const Equipped defaults = Equipped();

  final BallSkin ball;
  final PaddleSkin paddle;

  Equipped copyWith({BallSkin? ball, PaddleSkin? paddle}) =>
      Equipped(ball: ball ?? this.ball, paddle: paddle ?? this.paddle);

  /// The body of `POST /api/shop/equip` for these two slots.
  Map<String, String> toWire() => {'ball': ball.id, 'paddle': paddle.id};

  /// What the arena should draw in: the value provided above this widget, or the
  /// free defaults when nothing provides one (a bare widget test, a preview, a
  /// build where the shop has not been wired yet).
  ///
  /// The nullable type argument is deliberate, and the same trick
  /// [GameTheme.of] uses: `provider` only throws for a non-nullable request, so
  /// this resolves to null instead of blowing up in a tree with no shell above
  /// it.
  static Equipped of(BuildContext context) =>
      Provider.of<Equipped?>(context) ?? defaults;

  /// Same as [of] but without subscribing; for callbacks and async code.
  static Equipped read(BuildContext context) =>
      Provider.of<Equipped?>(context, listen: false) ?? defaults;

  @override
  bool operator ==(Object other) =>
      other is Equipped && other.ball == ball && other.paddle == paddle;

  @override
  int get hashCode => Object.hash(ball, paddle);

  @override
  String toString() => 'Equipped(${ball.id}, ${paddle.id})';
}
