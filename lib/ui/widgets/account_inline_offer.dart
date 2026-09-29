/// The account offer as one line of the score screen (SPEC §4.5).
///
/// This is the offer that appears after **every** finished run, and the shape is
/// the whole point of it. It is a single line of text in the same typography as
/// the "best" line and the submission status above it — part of the result, not a
/// panel laid over it and not a dialog that has to be dismissed before the player
/// can press RETRY. Nothing is raised by itself: tapping the line is what opens
/// the sign-in sheet.
///
/// That shape is what lets it be permanent. The heavier [AccountOfferCard] has to
/// be silenced after a few refusals, because a panel with two large buttons and a
/// dismiss, shown after every game, is nagging. A line the player's eye passes
/// over on the way to RETRY is not, so this one keeps its word: every run, the
/// chance is there, and ignoring it costs nothing and is not even recorded.
///
/// It renders as **nothing at all** — zero height, no padding — when the player
/// already has an account or the deployment advertises no sign-in, so the screen
/// around it can place it unconditionally.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../services/account_service.dart';
import '../../services/native_sign_in.dart';
import '../../services/player_identity.dart';
import 'account_gate.dart';

class AccountInlineOffer extends StatefulWidget {
  const AccountInlineOffer({super.key, this.padding});

  /// Applied only when the line is actually visible, so a build with no sign-in
  /// leaves no gap behind.
  final EdgeInsetsGeometry? padding;

  @override
  State<AccountInlineOffer> createState() => _AccountInlineOfferState();
}

class _AccountInlineOfferState extends State<AccountInlineOffer> {
  List<SignInProvider>? _providers;

  /// Set once the player has signed in from here, so the line becomes the one
  /// sentence saying what happened instead of vanishing without a word.
  SignInSucceeded? _done;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Asks the server which sign-ins it accepts, but only when the line could be
  /// shown at all — a player who already has an account costs no request.
  Future<void> _load() async {
    if (!mounted) return;
    if (context.read<PlayerIdentity>().profile?.hasAccount ?? false) return;
    final providers = await context.read<AccountService>().providers();
    if (!mounted) return;
    setState(() => _providers = providers);
  }

  Future<void> _open(List<SignInProvider> providers) async {
    final result = await showAccountSignIn(
      context,
      providers: providers,
      titleKey: 'account.offerTitle',
      bodyKey: 'account.offerBody',
    );
    if (!mounted || result == null) return;
    setState(() => _done = result);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final done = _done;

    if (done != null) {
      return _wrap(_message(theme, accountOutcomeMessage(s, done)));
    }

    // Watched, so signing in anywhere else on this screen takes the line away.
    if (context.watch<PlayerIdentity>().profile?.hasAccount ?? false) {
      return const SizedBox.shrink();
    }
    final providers = _providers;
    // Unknown (the health check has not answered, or failed) and empty are the
    // same thing here: no offer is made that cannot be honoured.
    if (providers == null || providers.isEmpty) return const SizedBox.shrink();

    return _wrap(
      // A whole-line tap target rather than an inline link: at this size a word
      // is too small to hit reliably, and the line has nothing else on it.
      InkWell(
        onTap: () => _open(providers),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Text(
            s.t('account.inlineOffer'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.accentLeaderboard,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationColor: theme.accentLeaderboard.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  Widget _message(GameTheme theme, String text) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(color: theme.textDim, fontSize: 12, height: 1.3),
  );

  Widget _wrap(Widget child) => widget.padding == null
      ? child
      : Padding(padding: widget.padding!, child: child);
}
