import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../services/account_service.dart';
import '../../services/api_client.dart';
import '../../services/native_sign_in.dart';
import '../../services/player_identity.dart';
import 'neon_button.dart';
import 'neon_panel.dart';
import 'sign_in_buttons.dart';

/// The offer to keep a score safe by signing in (SPEC §4.5).
///
/// Where it appears is the whole design: beside a score the player has just
/// beaten their own record with, and on the leaderboard once they are on it.
/// Both are moments where the player has already decided the score matters — so
/// "keep it" answers a question they are asking, instead of interrupting them
/// with one. It is never on the first-launch screen, never a gate, and never
/// shown at all when the deployment accepts no sign-in (`GET /api/health`) or
/// when the player has already said no (see [AccountOffer]).
///
/// It renders as **nothing at all** — zero size, no padding — whenever it has
/// nothing to offer, so the screens around it can place it unconditionally.
class AccountOfferCard extends StatefulWidget {
  const AccountOfferCard({
    super.key,
    this.margin,
    this.bodyKey = 'account.offerBody',
  });

  /// Applied only when the card is actually visible.
  final EdgeInsetsGeometry? margin;

  /// Which sentence explains the offer; the leaderboard says it about the board.
  final String bodyKey;

  @override
  State<AccountOfferCard> createState() => _AccountOfferCardState();
}

class _AccountOfferCardState extends State<AccountOfferCard> {
  List<SignInProvider>? _providers;
  bool _busy = false;
  bool _dismissed = false;

  /// The last attempt worth showing: a success (which the card keeps showing, so
  /// the player is told what happened) or a failure. A cancel is never here.
  SignInResult? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Asks the server which sign-ins it accepts — but only when the offer could
  /// be shown at all, so a player who has said no costs no request.
  Future<void> _load() async {
    if (!mounted) return;
    final service = context.read<AccountService>();
    if (service.offer.silenced) return;
    if (context.read<PlayerIdentity>().profile?.hasAccount ?? false) return;
    final providers = await service.providers();
    if (!mounted) return;
    setState(() => _providers = providers);
  }

  Future<void> _signIn(SignInProvider provider) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final result = await context.read<AccountService>().signIn(provider);
    if (!mounted) return;
    setState(() {
      _busy = false;
      // A cancelled sign-in is silent: no message, no dismissal, the card stays
      // exactly as it was.
      if (result is! SignInCancelled) _result = result;
    });
    // The attempt is the only thing that can establish that a provider cannot
    // run here at all; when it does, the list is re-read so the button that
    // cannot work stops being offered.
    if (result is SignInFailed && result.code == 'unavailable') await _load();
  }

  Future<void> _dismiss() async {
    await context.read<AccountService>().offer.dismiss();
    if (!mounted) return;
    setState(() => _dismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final identity = context.watch<PlayerIdentity>();
    final result = _result;

    // Checked before everything else: signing in silences the offer and sets an
    // account on the profile, and neither must be allowed to swallow the one
    // message that says what just happened.
    if (result is SignInSucceeded) {
      return _panel(theme, <Widget>[
        _title(theme, s.t('account.offerTitle')),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.check_circle_outline, color: theme.success, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _successMessage(s, result),
                style: TextStyle(color: theme.textPrimary, fontSize: 13),
              ),
            ),
          ],
        ),
      ]);
    }

    if (_dismissed) return const SizedBox.shrink();
    if (identity.profile?.hasAccount ?? false) return const SizedBox.shrink();
    if (context.read<AccountService>().offer.silenced) {
      return const SizedBox.shrink();
    }
    final providers = _providers;
    // Unknown (the health check has not answered, or failed) and empty are the
    // same thing here: no button is shown that cannot work.
    if (providers == null || providers.isEmpty) return const SizedBox.shrink();

    return _panel(theme, <Widget>[
      _title(theme, s.t('account.offerTitle')),
      const SizedBox(height: 8),
      Text(
        s.t(widget.bodyKey),
        style: TextStyle(color: theme.textDim, fontSize: 13, height: 1.35),
      ),
      const SizedBox(height: 14),
      for (final provider in providers) ...[
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
            children: [
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
      else if (result is SignInFailed)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            s.accountError(result.code, provider: result.detail),
            style: TextStyle(color: theme.danger, fontSize: 12, height: 1.3),
          ),
        ),
      const SizedBox(height: 6),
      NeonButton(
        label: s.t('account.notNow'),
        height: 42,
        fontSize: 12,
        filled: false,
        color: theme.textDim,
        onPressed: _busy ? null : _dismiss,
      ),
    ]);
  }

  /// The card itself. `blur: false` because it can sit inside another panel (the
  /// solo game-over overlay), and two backdrop blurs over one another is a smear
  /// rather than glass.
  Widget _panel(GameTheme theme, List<Widget> children) => NeonPanel(
    margin: widget.margin,
    color: theme.accent,
    blur: false,
    padding: theme.pad(const EdgeInsets.all(16)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _title(GameTheme theme, String text) => Text(
    theme.heading(text),
    style: TextStyle(
      color: theme.textPrimary,
      fontSize: 14,
      fontWeight: FontWeight.w800,
      letterSpacing: theme.headingCase == HeadingCase.upper ? 1.5 : 0.2,
    ),
  );

  String _successMessage(
    Strings s,
    SignInSucceeded result,
  ) => switch (result.outcome) {
    AccountLinkOutcome.created => s.t('account.outcome.created'),
    AccountLinkOutcome.restored => s.t('account.outcome.restored'),
    AccountLinkOutcome.retried => s.t('account.outcome.retried'),
    // A merge is the one outcome with a number in it: two sets of scores are
    // one set now, and how many moved is the proof.
    AccountLinkOutcome.merged when result.movedScores > 0 => s.f(
      'account.outcome.merged',
      {'count': result.movedScores},
    ),
    AccountLinkOutcome.merged => s.t('account.outcome.linked'),
    AccountLinkOutcome.linked => s.t('account.outcome.linked'),
    AccountLinkOutcome.unknown => s.t('account.outcome.linked'),
  };
}
