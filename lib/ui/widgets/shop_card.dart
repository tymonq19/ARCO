/// One item in the shop (SPEC §4.8): its real preview, its name, and exactly what
/// the player can do with it.
///
/// The illustration is not artwork — it is the game. A look is drawn by
/// `ThemePreview` and a ball or a paddle by `CosmeticPreview`, both of which paint
/// with the real `GamePainter` over a real `GameState`, so a card cannot lie about
/// what is being bought.
///
/// Every number on a card comes from the server's catalogue and the server's
/// wallet. Nothing here decides a price, a balance or what is owned.
library;

import 'package:flutter/material.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../game/render/cosmetic_preview.dart';
import 'spark_balance.dart';
import 'theme_preview.dart';

/// What the player can do with an item right now — the four states a shop card
/// has to make unmistakable at a glance.
enum ShopCardState {
  /// Owned and currently worn.
  worn,

  /// Owned; one tap puts it on.
  owned,

  /// Not owned, and the wallet covers it.
  affordable,

  /// Not owned, and the wallet does not cover it yet.
  unaffordable,

  /// Not owned, and this screen does not know the price — a look in the Settings
  /// picker on a phone that has never reached the shop. It says where to go
  /// rather than inventing a figure.
  locked,
}

/// A shop card: the item drawn in the game's own renderer, its name, and its
/// state.
class ShopCard extends StatelessWidget {
  const ShopCard({
    super.key,
    required this.itemId,
    required this.label,
    required this.state,
    this.priceTokens,
    this.width = defaultWidth,
    this.onTap,
  });

  /// Card width; the illustration's height follows from the kind of item.
  static const double defaultWidth = 150;

  /// A look is a whole screen, so its card keeps `ThemePreview`'s tall
  /// proportion; a ball or a paddle is one shape in a ring and reads at
  /// `CosmeticPreview`'s wider one.
  static const double themeAspect =
      ThemePreview.defaultHeight / ThemePreview.defaultWidth;
  static const double itemAspect =
      CosmeticPreview.defaultHeight / CosmeticPreview.defaultWidth;

  /// The server's item id, verbatim.
  final String itemId;

  /// The translated name (`Strings.item(item.nameKey)`).
  final String label;

  final ShopCardState state;

  /// The catalogue price. Null when this screen has not been told one, which is
  /// the only reason a card is ever [ShopCardState.locked].
  final int? priceTokens;

  final double width;
  final VoidCallback? onTap;

  bool get _isTheme => GameThemes.byItemId(itemId) != null;

  double get _illustrationHeight =>
      width * (_isTheme ? themeAspect : itemAspect);

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final s = Strings.of(context);
    final look = GameThemes.byItemId(itemId);
    final selected = state == ShopCardState.worn;
    final dim =
        state == ShopCardState.unaffordable || state == ShopCardState.locked;
    final illustration = SizedBox(
      width: width,
      height: _illustrationHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // A card in the look it *is* (a theme) or in the look the app is
          // wearing (a ball, a paddle): a comet has to be shown against the
          // background it will actually fly over.
          if (look != null)
            ThemePreview(
              theme: look,
              width: width,
              height: _illustrationHeight,
              selected: selected,
            )
          else
            CosmeticPreview(
              itemId: itemId,
              theme: theme,
              width: width,
              height: _illustrationHeight,
              selected: selected,
            ),
          if (dim)
            // Not a grey veil over the picture — the item still has to be worth
            // wanting. A small lock in the corner says it is not yours yet.
            Positioned(top: 6, left: 6, child: LockBadge(size: 22)),
        ],
      ),
    );
    // The gesture stays *outside* the [Semantics], and the card's own text is
    // excluded inside it: a screen reader then announces one thing — "Comet, 80
    // sparks" — and can still activate it. Wrapping the gesture in a
    // `Semantics(excludeSemantics: true)` would read the same and do nothing.
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        button: onTap != null,
        selected: selected,
        label: '$label, ${_semanticState(s)}',
        child: ExcludeSemantics(
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                illustration,
                const SizedBox(height: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: dim ? theme.textDim : theme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                _status(theme, s),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The one line that says what this card is: worn, owned, or a price.
  Widget _status(GameTheme theme, Strings s) {
    switch (state) {
      case ShopCardState.worn:
        return Row(
          children: [
            Icon(Icons.check_circle, size: 14, color: theme.accent),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                theme.heading(s.t('shop.equipped')),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: theme.headingCase == HeadingCase.upper
                      ? 1.5
                      : 0,
                ),
              ),
            ),
          ],
        );
      case ShopCardState.owned:
        return Text(
          theme.heading(s.t('shop.wear')),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: theme.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: theme.headingCase == HeadingCase.upper ? 1.5 : 0,
          ),
        );
      case ShopCardState.affordable:
      case ShopCardState.unaffordable:
        return SparkAmount(
          amount: priceTokens ?? 0,
          fontSize: 14,
          dim: state == ShopCardState.unaffordable,
        );
      case ShopCardState.locked:
        return Text(
          s.t('shop.locked'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: theme.textDim, fontSize: 12),
        );
    }
  }

  String _semanticState(Strings s) => switch (state) {
    ShopCardState.worn => s.t('shop.equipped'),
    ShopCardState.owned => s.t('shop.owned'),
    ShopCardState.affordable ||
    ShopCardState.unaffordable => s.sparks(priceTokens ?? 0),
    ShopCardState.locked => s.t('shop.locked'),
  };
}

/// The small lock that marks a preview as something not owned yet.
///
/// Shared by the shop and by the pickers in Settings and on the welcome screen,
/// so "not yours yet" is one mark in three places rather than three.
class LockBadge extends StatelessWidget {
  const LockBadge({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: theme.background.withValues(alpha: 0.82),
        shape: theme.border(
          size / 2,
          color: theme.outline.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      child: Icon(Icons.lock_outline, size: size * 0.62, color: theme.textDim),
    );
  }
}
