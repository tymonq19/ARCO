/// The one-time unlock in the shop (SPEC §4.9): one non-consumable purchase that
/// unlocks every cosmetic — the ones that exist and the ones added later — and
/// turns ads off, forever.
///
/// Four rules shape every pixel of this.
///
/// **The price is the store's.** The card shows the string StoreKit or Google Play
/// returned for the product — the player's currency, their market's tax rules,
/// their locale's separators — printed verbatim. Nothing here formats a price,
/// holds one, or falls back to one; a product the store gave no price for is shown
/// as unavailable rather than guessed at.
///
/// **It must not nag, and it must not read as a wall.** It sits *below* the
/// earning panel, so the screen reads earn-first and the unlock is plainly the
/// shortcut it is. No countdown, no struck-through "was", no "best value", no
/// bonus, and nothing anywhere else in the app that points at it. One line says
/// that everything it covers is also earned by playing, and then it stops talking.
/// What makes it prominent is the panel itself — one card, three plain sentences
/// about what it gives, one button — not repetition and not urgency.
///
/// **Once bought it stops selling.** The server stops advertising the product the
/// moment a player owns it, so the card becomes a quiet confirmation: what they
/// have, and nothing to do about it.
///
/// **Restore genuinely restores.** The product is a non-consumable, so the stores
/// themselves remember it: a reinstall or a second device really does recover it,
/// and the button says so without hedging. It stays visible when the player is
/// already premium, because a player looking for it has usually just switched
/// phones.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../services/purchase_service.dart';
import '../../services/shop_service.dart';
import 'neon_button.dart';
import 'neon_panel.dart';

/// The whole money section of the shop, or nothing at all.
///
/// Renders an empty box when the deployment takes no money, when this build has no
/// store keys, or when the platform has no store — see [PurchaseService.offered]
/// and [PurchaseService.premium]. That is deliberate: there is no hole to
/// apologise for, because every cosmetic the unlock covers is earnable by playing.
class UnlockSection extends StatelessWidget {
  const UnlockSection({
    super.key,
    required this.onBuy,
    required this.onRestore,
  });

  /// Called with the store product identifier when the button is tapped.
  final void Function(UnlockOffer offer) onBuy;

  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final purchases = context.watch<PurchaseService>();
    // Watched rather than read: premium arrives from the server a moment after the
    // shop opens, and the card has to change under the player's hands. It is also
    // what [PurchaseService.canRestore] below reads, and that service does not
    // notify when this one changes.
    final premium = context.watch<ShopService>().premium;
    if (!purchases.canRestore) return const SizedBox.shrink();
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionLabel(
            s.t(premium ? 'shop.unlockedTitle' : 'shop.unlockTitle'),
          ),
          NeonPanel(
            // Green once it is owned: the panel itself says "settled" before a
            // word is read.
            color: premium ? theme.success : theme.star,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (premium)
                  _Owned(s: s, theme: theme)
                else
                  ..._offer(s, theme, purchases),
                const SizedBox(height: 16),
                _Restore(
                  busy: purchases.busy,
                  onRestore: onRestore,
                  s: s,
                  theme: theme,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The offer: what it gives, what the store charges, one button.
  List<Widget> _offer(Strings s, GameTheme theme, PurchaseService purchases) {
    if (purchases.status == PurchaseStatus.loading ||
        purchases.status == PurchaseStatus.idle) {
      // `idle` is the frame or two between the catalogue arriving and the store
      // being asked. A spinner there, not a sentence about a price we have not
      // asked for yet.
      return const [
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }
    final offer = purchases.offer;
    final price = offer?.priceString;
    return <Widget>[
      Row(
        children: [
          Icon(Icons.auto_awesome_motion, size: 22, color: theme.star),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              // The server's name key for the product, translated. Never a string
              // this widget invents about something somebody is about to pay for.
              s.item(offer?.nameKey ?? 'unlock.full'),
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      // What it gives, in three plain lines. No adjectives, no comparison, no
      // second tier to compare it against.
      for (final key in const [
        'shop.unlockPerk.now',
        'shop.unlockPerk.later',
        'shop.unlockPerk.ads',
      ]) ...[_Perk(text: s.t(key), theme: theme), const SizedBox(height: 6)],
      const SizedBox(height: 6),
      if (price == null)
        // The store did not answer, or does not sell this in this market. There is
        // nothing honest to put in place of a price — no fallback figure, no
        // disabled button — and the game is entirely unaffected, which the sentence
        // says.
        Text(
          s.t('shop.unlockStoreSilent'),
          style: TextStyle(color: theme.textDim, fontSize: 12, height: 1.35),
        )
      else
        _BuyButton(
          label: s.t('shop.unlockButton'),
          price: price,
          enabled: !purchases.busy,
          onPressed: () => onBuy(offer!),
        ),
      const SizedBox(height: 12),
      // Said once, quietly, after the price rather than before it: this is a
      // shortcut, and nothing is locked behind it.
      Text(
        s.t('shop.unlockFree'),
        style: TextStyle(color: theme.textDim, fontSize: 12, height: 1.35),
      ),
    ];
  }
}

/// One thing the unlock gives.
class _Perk extends StatelessWidget {
  const _Perk({required this.text, required this.theme});

  final String text;
  final GameTheme theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.check, size: 15, color: theme.star),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// The quiet confirmation a player who has paid sees instead of an offer.
class _Owned extends StatelessWidget {
  const _Owned({required this.s, required this.theme});

  final Strings s;
  final GameTheme theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, size: 22, color: theme.success),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s.t('shop.unlockedHeading'),
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          s.t('shop.unlockedBody'),
          style: TextStyle(color: theme.textDim, fontSize: 12, height: 1.35),
        ),
      ],
    );
  }
}

/// The store's price, then one button.
///
/// The price sits on its own line, at its own size, and the button says one short
/// word. Both halves of that are deliberate: a price is the thing a player reads
/// twice, so it is not squeezed into a label beside an icon; and a label that stays
/// short survives Polish at 1.6 text scale on a 320 pt phone without being scaled
/// down to nothing.
class _BuyButton extends StatelessWidget {
  const _BuyButton({
    required this.label,
    required this.price,
    required this.enabled,
    required this.onPressed,
  });

  final String label;

  /// The store's own string, printed exactly as it came. There is deliberately no
  /// fallback that formats a number: an app that prints its own price prints the
  /// wrong one.
  final String price;

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    return Semantics(
      button: true,
      enabled: enabled,
      // Read out as the whole deal: what it does, and the store's price in the
      // store's own words.
      label: '$label, $price',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              price,
              maxLines: 1,
              style: TextStyle(
                color: theme.star,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            NeonButton(
              label: label,
              height: 52,
              fontSize: 14,
              icon: Icons.lock_open,
              color: theme.star,
              onPressed: enabled ? onPressed : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Restore Purchases, and the sentence that says what it really does.
///
/// It is a real action now: the product is a non-consumable, so the store's own
/// record of it is what gets read back. The sentence is short because it no longer
/// has to explain away a limitation — it only has to say when to tap it.
class _Restore extends StatelessWidget {
  const _Restore({
    required this.busy,
    required this.onRestore,
    required this.s,
    required this.theme,
  });

  final bool busy;
  final VoidCallback onRestore;
  final Strings s;
  final GameTheme theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.t('shop.restoreHint'),
          style: TextStyle(color: theme.textDim, fontSize: 11, height: 1.35),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: busy ? null : onRestore,
            style: TextButton.styleFrom(
              foregroundColor: theme.textDim,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              minimumSize: const Size(0, 44),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              theme.heading(s.t('shop.restore')),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: theme.headingCase == HeadingCase.upper ? 1.4 : 0,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
