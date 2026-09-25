/// The shop currency on screen (SPEC §4.8): its glyph, an amount, and the title
/// screen's way into the shop.
///
/// The currency is **Sparks** (PL *Iskry*): the game is a ring of light where
/// every paddle hit throws a shower of them, so the word is on screen before it
/// is ever a number — and "coins" would belong to any game at all. The name lives
/// in `Strings` (`currency.*`), declined for Polish by `Strings.sparks`, so it is
/// one word everywhere in both languages.
///
/// Nothing here computes anything. A balance is whatever the server last said
/// (`ShopService.balanceKnown` is false until it has said something), and a price
/// is the catalogue's.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../services/shop_service.dart';
import 'neon_panel.dart';

/// The spark glyph. Small, four-pointed, and the same mark everywhere a number of
/// sparks appears, so the number never needs the word beside it.
class SparkIcon extends StatelessWidget {
  const SparkIcon({super.key, this.size = 16, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final tint = color ?? theme.star;
    return Icon(
      Icons.auto_awesome,
      size: size,
      color: tint,
      // Read out as the currency's name, so a screen reader says "240 sparks"
      // rather than "240".
      semanticLabel: Strings.of(context).t('currency.name'),
    );
  }
}

/// An amount of sparks: the glyph and the figure, on one line.
///
/// [prefix] carries the `+` of a reward. The semantic label is the declined,
/// spelled-out amount, which is the one place the word itself is always said.
class SparkAmount extends StatelessWidget {
  const SparkAmount({
    super.key,
    required this.amount,
    this.fontSize = 15,
    this.color,
    this.iconColor,
    this.prefix = '',
    this.dim = false,
  });

  final int amount;
  final double fontSize;
  final Color? color;
  final Color? iconColor;
  final String prefix;

  /// Draws it as an unreachable price rather than as a figure to read.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final s = Strings.of(context);
    final ink = color ?? (dim ? theme.textDim : theme.textPrimary);
    return Semantics(
      label: '$prefix${s.sparks(amount)}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SparkIcon(
            size: fontSize + 2,
            color: iconColor ?? (dim ? theme.textDim : theme.star),
          ),
          const SizedBox(width: 4),
          Text(
            '$prefix$amount',
            maxLines: 1,
            style: TextStyle(
              color: ink,
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Everything unlocked": what a player who bought the one-time unlock (SPEC §4.9)
/// sees where the wallet used to be.
///
/// It replaces the figure rather than sitting next to it. A balance is a question
/// — *how close am I to the next look* — and that question has no answer once every
/// look is owned, so the number is not merely redundant, it invites a question the
/// app cannot answer. The wallet is untouched underneath: the server keeps
/// crediting every run, so if a refund ever revoked the unlock the balance comes
/// back with everything it earned in the meantime.
class PremiumBadge extends StatelessWidget {
  const PremiumBadge({super.key, this.fontSize = 13});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final s = Strings.of(context);
    return Semantics(
      label: s.t('shop.premiumBadge'),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: fontSize + 3, color: theme.success),
          const SizedBox(width: 5),
          Text(
            s.t('shop.premiumBadge'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

/// The wallet as the shop's app bar shows it: the glyph, the figure, and nothing
/// else.
///
/// Renders a dash while the balance is unknown — a wallet nobody has asked the
/// server about is not a wallet holding zero, and printing "0" would be a claim
/// this app is not entitled to make. Renders [PremiumBadge] instead of any figure
/// once the player has bought the unlock (SPEC §4.9), because the figure then has
/// nothing left to buy.
class SparkBalance extends StatelessWidget {
  const SparkBalance({super.key, this.fontSize = 16});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final shop = context.watch<ShopService>();
    final theme = GameTheme.of(context);
    if (!shop.snapshot.showsBalance) {
      return PremiumBadge(fontSize: fontSize - 3);
    }
    if (!shop.balanceKnown) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SparkIcon(size: fontSize + 2, color: theme.textDim),
          const SizedBox(width: 4),
          Text(
            '—',
            style: TextStyle(
              color: theme.textDim,
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      );
    }
    return SparkAmount(amount: shop.balance, fontSize: fontSize);
  }
}

/// The title screen's shop row: the balance on the left, the way in on the right.
///
/// One quiet panel rather than a fifth big button — the balance has to be visible
/// without shouting, and a number nobody is asked to act on does not need a
/// button's worth of screen.
class ShopEntryCard extends StatelessWidget {
  const ShopEntryCard({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    final s = Strings.of(context);
    final shop = context.watch<ShopService>();
    // A player who bought the unlock (SPEC §4.9) is shown what they have rather
    // than a wallet with nothing to spend on: the same rule the shop's own app bar
    // follows, so the two never disagree.
    final premium = !shop.snapshot.showsBalance;
    // The gesture outside, the row's own text excluded inside: one announcement
    // ("Shop, 240 sparks") that can still be activated.
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        button: true,
        label: premium
            ? '${s.t('shop.title')}, ${s.t('shop.premiumBadge')}'
            : shop.balanceKnown
            ? '${s.t('shop.title')}, ${s.sparks(shop.balance)}'
            : s.t('shop.title'),
        child: ExcludeSemantics(
          child: NeonPanel(
            color: premium ? theme.success : theme.star,
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                if (premium)
                  Icon(Icons.check_circle, size: 22, color: theme.success)
                else
                  SparkIcon(size: 22, color: theme.star),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The figure leads: it is what the player came to glance at.
                      // Unless there is nothing left to buy, and then what they
                      // have leads instead.
                      Text(
                        premium
                            ? s.t('shop.premiumBadge')
                            : shop.balanceKnown
                            ? s.sparks(shop.balance)
                            : s.t('currency.name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        premium || shop.balanceKnown
                            ? s.t('shop.tagline')
                            : s.t('shop.balanceUnknown'),
                        maxLines: 2,
                        style: TextStyle(color: theme.textDim, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  theme.heading(s.t('shop.open')),
                  style: TextStyle(
                    color: premium ? theme.success : theme.star,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: theme.headingCase == HeadingCase.upper
                        ? 2
                        : 0,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: premium ? theme.success : theme.star,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
