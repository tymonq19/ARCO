/// The Spark packs in the shop: buying Sparks with real money (SPEC §4.9).
///
/// Three rules shape every pixel of this.
///
/// **The price is the store's.** Each row shows the string StoreKit or Google
/// Play returned for that product — the player's currency, their market's tax
/// rules, their locale's separators — printed verbatim. Nothing here formats a
/// price, holds one, or falls back to one; a pack the store gave no price for is
/// shown as unavailable rather than guessed at.
///
/// **The section must not nag.** It sits *below* the earning panel, so the screen
/// reads earn-first and the packs are plainly the shortcut they are. No
/// countdown, no struck-through "was", no "best value" badge, no bonus percentage,
/// and nothing anywhere else in the app that points at it. One line says what the
/// packs are and that nothing in the game is behind a payment, and then it stops
/// talking.
///
/// **The balance is never touched here.** A completed payment asks the server and
/// shows what the server says; while the server has not credited it yet, the
/// screen says exactly that rather than inventing a number.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../services/purchase_service.dart';
import 'neon_panel.dart';
import 'spark_balance.dart';

/// The whole money section, or nothing at all.
///
/// Renders an empty box when the deployment sells no packs, when this build has
/// no store keys, or when the platform has no store — see
/// [PurchaseService.offered]. That is deliberate: there is no hole to apologise
/// for, because every Spark a pack sells is earnable by playing.
class SparkPacksSection extends StatelessWidget {
  const SparkPacksSection({
    super.key,
    required this.onBuy,
    required this.onRestore,
  });

  /// Called with a product identifier when a row is tapped.
  final void Function(SparkPackOffer offer) onBuy;

  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final purchases = context.watch<PurchaseService>();
    if (!purchases.offered) return const SizedBox.shrink();
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionLabel(s.t('shop.packsTitle')),
        NeonPanel(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Said once, quietly, before any price: these are a shortcut and
              // nothing is locked behind them.
              Text(
                s.t('shop.packsHint'),
                style: TextStyle(
                  color: theme.textDim,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              ..._rows(context, s, theme, purchases),
              const SizedBox(height: 14),
              _restore(context, s, theme, purchases),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _rows(
    BuildContext context,
    Strings s,
    GameTheme theme,
    PurchaseService purchases,
  ) {
    if (purchases.status == PurchaseStatus.loading) {
      return const [
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }
    if (purchases.status != PurchaseStatus.ready) {
      // The store did not answer. The prices are the store's, so there is
      // nothing honest to put here — and the game is entirely unaffected, which
      // the sentence says.
      return [
        Text(
          s.t('shop.packsStoreSilent'),
          style: TextStyle(color: theme.textDim, fontSize: 12, height: 1.35),
        ),
      ];
    }
    final rows = <Widget>[];
    for (final offer in purchases.offers) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 10));
      rows.add(
        _PackRow(
          offer: offer,
          enabled: !purchases.busy && offer.buyable,
          onTap: () => onBuy(offer),
        ),
      );
    }
    return rows;
  }

  /// The restore button and the sentence that tells the truth about it.
  ///
  /// The sentence is not fine print: a consumable does not restore, so a button
  /// labelled "restore purchases" would otherwise promise something it cannot
  /// do. It says where the Sparks actually live — on the Arco player, not the
  /// phone — and what the button really checks.
  Widget _restore(
    BuildContext context,
    Strings s,
    GameTheme theme,
    PurchaseService purchases,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.t('shop.restoreHint'),
          style: TextStyle(color: theme.textDim, fontSize: 11, height: 1.35),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: purchases.busy ? null : onRestore,
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

/// One pack: what it pays on the left, what the **store** charges on the right.
class _PackRow extends StatelessWidget {
  const _PackRow({
    required this.offer,
    required this.enabled,
    required this.onTap,
  });

  final SparkPackOffer offer;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final price = offer.priceString;
    final name = s.item(offer.pack.nameKey);
    return Semantics(
      button: price != null,
      enabled: enabled,
      // Read out as the whole deal: the name, what it pays, and the store's
      // price in the store's own words.
      label: price == null
          ? '$name, ${s.t('shop.packsPriceMissing')}'
          : '$name, ${s.sparks(offer.sparks)}, $price',
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(
                children: [
                  SparkIcon(size: 20, color: theme.star),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          // The server's number, in words, declined for Polish.
                          s.sparks(offer.sparks),
                          maxLines: 1,
                          style: TextStyle(color: theme.textDim, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // The store's own string, printed exactly as it came. There is
                  // deliberately no fallback that formats a number: an app that
                  // prints its own price prints the wrong one.
                  Text(
                    price ?? s.t('shop.packsPriceMissing'),
                    maxLines: 1,
                    style: TextStyle(
                      color: price == null ? theme.textDim : theme.star,
                      fontSize: price == null ? 12 : 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (price != null) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right, color: theme.star, size: 20),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
