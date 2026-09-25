/// The rewarded-ad row in the shop: watching an ad for Sparks (SPEC §4.10).
///
/// Four rules shape every pixel of this.
///
/// **It is an earning row, not an advertisement for advertising.** It sits
/// directly under the "earned today" panel, because that is what it is — the other
/// way to earn — and above the one-time unlock of SPEC §4.9, because it costs time
/// rather than money. One line says what an ad pays and that playing pays more, and
/// then it stops talking.
///
/// **It is absent whenever it would not work.** Not disabled, not a spinner, not
/// an apology: nothing. There is no button unless an ad is already loaded *and*
/// the server says it would pay — so it cannot be tapped into a failure, and it
/// never takes half a minute of somebody's attention for nothing. When the day's
/// allowance is spent or the cooldown is running, the row says which and why.
///
/// **The consent form is offered here and nowhere else.** A player in Europe who
/// has not chosen yet sees the same row, asking for that choice, because this is
/// the moment they are already reading about earning Sparks. Launch is not that
/// moment, and neither is game over.
///
/// **The balance is never touched here.** A watched ad asks the server and shows
/// what the server says; while the server has not credited it, the screen says
/// exactly that rather than inventing a number.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../services/ads_service.dart';
import 'neon_button.dart';
import 'neon_panel.dart';

/// The whole ad row, or nothing at all.
///
/// Renders an empty box when this deployment credits no ads, when this build has
/// no AdMob unit, when the platform has no ads, when the day's ads are gone and
/// there is nothing to say about it, when no ad is loaded, or when the player
/// bought the one-time unlock of SPEC §4.9 — see [AdsService.offeredInShop]. The
/// unlock buys **no ads**, not fewer, so the row is gone entirely rather than
/// explaining itself.
class SparkAdSection extends StatelessWidget {
  const SparkAdSection({super.key, required this.onWatch, this.onConsent});

  /// Called when the row is tapped and an ad is in hand.
  final VoidCallback onWatch;

  /// Called when the row is tapped and the consent form is what is being offered.
  /// Null falls back to [onWatch], which asks for consent itself.
  final VoidCallback? onConsent;

  @override
  Widget build(BuildContext context) {
    final ads = context.watch<AdsService>();
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final note = _note(s, ads);
    // Nothing to offer and nothing worth saying: no row at all.
    if (!ads.offeredInShop && note == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: NeonPanel(
        color: theme.star,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    theme.heading(s.t('ads.title')),
                    style: TextStyle(
                      color: theme.textDim,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: theme.headingCase == HeadingCase.upper
                          ? 1.5
                          : 0,
                    ),
                  ),
                ),
                // The server's own numbers, so "the button went away" always has a
                // visible reason.
                if (ads.offer.dailyCap > 0)
                  Text(
                    s.f('ads.today', {
                      'earned': ads.offer.earnedToday,
                      'cap': ads.offer.dailyCap,
                    }),
                    style: TextStyle(color: theme.textDim, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              note ?? _offerLine(s, ads),
              style: TextStyle(
                color: theme.textDim,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            if (ads.offeredInShop) ...[
              const SizedBox(height: 14),
              if (ads.needsConsent)
                // The ask, not the ad. A player who has not chosen about data yet
                // is offered the choice, with the line above already saying that
                // declining changes nothing about the game.
                NeonButton(
                  label: s.t('ads.consentButton'),
                  height: 48,
                  fontSize: 13,
                  filled: false,
                  color: theme.star,
                  onPressed: ads.busy ? null : (onConsent ?? onWatch),
                )
              else
                _WatchButton(
                  sparks: ads.offer.sparks,
                  enabled: !ads.busy,
                  onPressed: onWatch,
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// What to say when there is no button, or null when there is nothing to say and
  /// the row should not exist.
  ///
  /// The two cases worth a sentence are the two bounds: a row that was there this
  /// morning and is gone now reads as a bug, so the day's cap and the cooldown say
  /// which of them it is. Everything else — no ad filled, no AdMob configured, a
  /// deployment that credits no ads — is silence, because there is nothing a player
  /// could do with the information and nothing has been taken from them.
  String? _note(Strings s, AdsService ads) {
    if (ads.offeredInShop) return null;
    // A player who bought the unlock is owed no explanation for a row that is not
    // there: they bought its absence, and the confirmation card says so.
    if (ads.premium) return null;
    if (!ads.configured || ads.offer.dailyCap <= 0) return null;
    if (ads.offer.dayFull) return s.t('ads.dayFull');
    if (ads.offer.waitSeconds > 0) {
      return s.f('ads.cooldown', {
        // Rounded up, and never 0: "in about 0 min" is worse than no sentence.
        'minutes': (ads.offer.waitSeconds / 60).ceil(),
      });
    }
    return null;
  }

  String _offerLine(Strings s, AdsService ads) => ads.needsConsent
      ? s.t('ads.consentHint')
      : s.f('ads.hint', {'sparks': s.sparks(ads.offer.sparks)});
}

/// The button. Deliberately plain: what an ad pays is already in the sentence
/// above it, so the button has one job and says one thing.
class _WatchButton extends StatelessWidget {
  const _WatchButton({
    required this.sparks,
    required this.enabled,
    required this.onPressed,
  });

  final int sparks;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    return Semantics(
      button: true,
      enabled: enabled,
      // Read out as the whole deal: what it is, and what the **server** will pay.
      // A screen reader should not have to infer the amount from a sentence two
      // paragraphs up.
      label: '${s.t('ads.watch')}, ${s.sparks(sparks)}',
      child: ExcludeSemantics(
        child: NeonButton(
          label: s.t('ads.watch'),
          height: 48,
          fontSize: 13,
          color: theme.star,
          onPressed: enabled ? onPressed : null,
        ),
      ),
    );
  }
}
