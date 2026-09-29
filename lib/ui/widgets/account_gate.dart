/// The one place in the app where signing in is required rather than offered
/// (SPEC §4.5, §4.9): in front of the payment sheet.
///
/// The reason is not engagement, it is that the thing being sold cannot be
/// delivered twice. What the unlock buys is recorded against a player, and a
/// player with no account lives only in this phone's keychain — so a reinstall,
/// a wipe or a new phone would leave somebody who genuinely paid holding
/// nothing, with "Restore purchases" truthfully reporting that there is nothing
/// to restore. An account is what turns the purchase into something the store
/// and our server can both find again.
///
/// It gates **only** the purchase. Playing, the shop, Sparks, cosmetics and the
/// leaderboard all stay open to a player who never signs in; the board asks with
/// [AccountOfferCard], which can always be answered with "not now".
///
/// Three rules keep it from becoming a wall in front of a till:
///
///  * **Already have an account: no sheet at all.** One account covers both the
///    board and the purchase, so somebody who signed in to post a score is never
///    asked again here, and vice versa.
///  * **No sign-in on offer: no sheet either.** When the deployment advertises no
///    providers (`GET /api/health`), or the health check has not answered, the
///    purchase proceeds exactly as it did before. A gate nobody can pass is not
///    a gate, it is a shop that cannot take money — and the gate switches itself
///    on the moment sign-in is configured.
///  * **Cancelling is free.** No dismissal is recorded, nothing is remembered,
///    and the next tap on BUY asks again. The player has lost nothing but a tap.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../services/api_client.dart';
import '../../services/account_service.dart';
import '../../services/native_sign_in.dart';
import '../../services/player_identity.dart';
import 'neon_button.dart';
import 'neon_panel.dart';
import 'sign_in_buttons.dart';

/// Asks for an account if the purchase needs one, and reports whether the
/// payment sheet may now be opened.
///
/// Returns true when the caller should go ahead: the player already has an
/// account, there is no sign-in to ask for, or they have just signed in.
/// Returns false only when they were asked and said no.
Future<bool> requireAccountToBuy(BuildContext context) async {
  if (context.read<PlayerIdentity>().profile?.hasAccount ?? false) return true;

  final service = context.read<AccountService>();
  final providers = await service.providers();
  if (!context.mounted) return false;
  // Nothing to offer: the purchase is not held up over a button that cannot be
  // drawn. This is also today's behaviour, with accounts switched off.
  if (providers.isEmpty) return true;

  return await showAccountSignIn(
        context,
        providers: providers,
        titleKey: 'account.gateTitle',
        bodyKey: 'account.gateBody',
      ) !=
      null;
}

/// The sign-in sheet, raised by something the player just tapped.
///
/// Returns the outcome when they signed in, and null when they backed out. It is
/// only ever opened by a tap: nothing in the app raises it by itself, which is
/// the difference between offering an account and interrupting a game with one.
Future<SignInSucceeded?> showAccountSignIn(
  BuildContext context, {
  required List<SignInProvider> providers,
  required String titleKey,
  required String bodyKey,
}) => showModalBottomSheet<SignInSucceeded>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (_) => _AccountGateSheet(
    providers: providers,
    titleKey: titleKey,
    bodyKey: bodyKey,
  ),
);

/// What to tell the player after a successful sign-in, per outcome (SPEC §4.5).
///
/// Shared by every surface that can sign somebody in, so the five outcomes are
/// worded once. A merge is the one with a number in it: two sets of runs are one
/// set now, and how many moved is the proof.
String accountOutcomeMessage(Strings s, SignInSucceeded result) =>
    switch (result.outcome) {
      AccountLinkOutcome.created => s.t('account.outcome.created'),
      AccountLinkOutcome.restored => s.t('account.outcome.restored'),
      AccountLinkOutcome.retried => s.t('account.outcome.retried'),
      AccountLinkOutcome.merged when result.movedScores > 0 => s.f(
        'account.outcome.merged',
        {'count': result.movedScores},
      ),
      AccountLinkOutcome.merged => s.t('account.outcome.linked'),
      AccountLinkOutcome.linked => s.t('account.outcome.linked'),
      AccountLinkOutcome.unknown => s.t('account.outcome.linked'),
    };

class _AccountGateSheet extends StatefulWidget {
  const _AccountGateSheet({
    required this.providers,
    required this.titleKey,
    required this.bodyKey,
  });

  final List<SignInProvider> providers;
  final String titleKey;
  final String bodyKey;

  @override
  State<_AccountGateSheet> createState() => _AccountGateSheetState();
}

class _AccountGateSheetState extends State<_AccountGateSheet> {
  late List<SignInProvider> _providers = widget.providers;
  bool _busy = false;
  SignInFailed? _failure;

  Future<void> _signIn(SignInProvider provider) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    final service = context.read<AccountService>();
    final result = await service.signIn(provider);
    if (!mounted) return;
    switch (result) {
      case SignInSucceeded():
        // Straight back to the caller, which decides what to say. At the till
        // that is the payment sheet, with no congratulation screen in the way of
        // a person who is trying to pay.
        Navigator.of(context).pop(result);
      case SignInCancelled():
        // Cancelling the provider's own sheet is not cancelling the purchase:
        // the gate stays up so another provider can be tried.
        setState(() => _busy = false);
      case SignInFailed():
        setState(() {
          _busy = false;
          _failure = result;
        });
        // Only an attempt can prove a provider cannot run on this device; when
        // one says so, stop offering the button that cannot work.
        if (result.code == 'unavailable') {
          final providers = await service.providers(force: true);
          if (!mounted) return;
          setState(() => _providers = providers);
          if (providers.isEmpty && mounted) {
            // Every provider turned out to be unavailable, so there is nothing
            // left to ask for. Closing empty-handed is the only honest answer,
            // and the purchase gate reads that as "no sign-in on offer" and lets
            // the sale through.
            Navigator.of(context).pop();
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final failure = _failure;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: NeonPanel(
          color: theme.accent,
          padding: theme.pad(const EdgeInsets.all(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                theme.heading(s.t(widget.titleKey)),
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: theme.headingCase == HeadingCase.upper
                      ? 1.5
                      : 0.2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                s.t(widget.bodyKey),
                style: TextStyle(
                  color: theme.textDim,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 16),
              for (final provider in _providers) ...[
                SignInButton(
                  provider: provider,
                  onPressed: _busy ? null : () => _signIn(provider),
                ),
                const SizedBox(height: 8),
              ],
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        height: 14,
                        width: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        s.t('account.working'),
                        style: TextStyle(color: theme.textDim, fontSize: 12),
                      ),
                    ],
                  ),
                )
              else if (failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    s.accountError(failure.code, provider: failure.detail),
                    style: TextStyle(
                      color: theme.danger,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              NeonButton(
                label: s.t('account.notNow'),
                height: 42,
                fontSize: 12,
                filled: false,
                color: theme.textDim,
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
