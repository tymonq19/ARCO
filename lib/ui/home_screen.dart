import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/game_theme.dart';
import '../app/settings.dart';
import '../app/strings.dart';
import '../services/audio_service.dart';
import '../services/player_identity.dart';
import '../services/shop_service.dart';
import 'duel_lobby_screen.dart';
import 'leaderboard_screen.dart';
import 'settings_screen.dart';
import 'shop_screen.dart';
import 'solo_screen.dart';
import 'widgets/neon_button.dart';
import 'widgets/neon_panel.dart';
import 'widgets/spark_balance.dart';

/// Title screen: nickname, the four entry points and the personal best.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static const String route = '/';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: context.read<Settings>().playerName);
    // The player's standing, if they have one. Cached and never polled: this
    // asks once when the title screen appears and again when it is come back
    // to, and asks nothing at all while the player is anonymous (SPEC §4.4).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PlayerIdentity>().refreshProfile();
      // The wallet (SPEC 4.8), for the shop row below. `issue: false`: a balance
      // on the title screen is not worth creating a player for, so a phone that
      // has never submitted a run asks nothing and shows no figure — opening the
      // shop is what issues an identity.
      context.read<ShopService>().refresh();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// A label and its value on one line — or on two, when the value does not fit
  /// next to the label (the long empty-state sentence, a narrow phone, a long
  /// translation), which is why this is a [Wrap] and not a [Row].
  Widget _statLine(
    GameTheme theme,
    String label,
    String value, {
    bool dim = false,
  }) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 6,
      children: [
        Text(
          label,
          style: TextStyle(
            color: theme.textDim,
            fontSize: 13,
            letterSpacing: 1,
          ),
        ),
        Text(
          value,
          textAlign: TextAlign.end,
          style: TextStyle(
            color: dim ? theme.accentLeaderboard : theme.textPrimary,
            fontSize: dim ? 15 : 18,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }

  void _onNameChanged(String value) {
    context.read<Settings>().playerName = value;
    setState(() {});
  }

  Future<void> _go(String route) async {
    context.read<AudioService>().play(Sfx.click);
    await Navigator.of(context).pushNamed(route);
    if (!mounted) return;
    // Coming back from a game whose score was accepted: the rank moved, and
    // [PlayerIdentity] dropped the cached one, so this re-reads it. Any other
    // return is inside the cache window and costs nothing.
    context.read<PlayerIdentity>().refreshProfile();
    // Same for the wallet: a finished run has paid into it, and coming back from
    // the shop has spent from it.
    context.read<ShopService>().refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final settings = context.watch<Settings>();
    final profile = context.watch<PlayerIdentity>().profile;
    final nameValid = normalizeName(_name.text) != null;
    return Scaffold(
      body: NeonBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 40,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 18),
                    // The wordmark: one short word, so it is set large and
                    // must never break. The FittedBox lays it out unconstrained
                    // and scales it down only if it would not fit (narrow
                    // phone, large accessibility text scale), which keeps it on
                    // a single line at every size. Flutter's line width already
                    // excludes the letter-space after the last glyph, so the
                    // centred box is the centred wordmark - no nudge needed.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: GlowText(
                        s.t('app.title'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      s.t('home.tagline'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.textDim,
                        fontSize: 14,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 28),
                    TextField(
                      controller: _name,
                      onChanged: _onNameChanged,
                      textAlign: TextAlign.center,
                      maxLength: nameMaxLength,
                      textInputAction: TextInputAction.done,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                      decoration: InputDecoration(
                        labelText: s.t('home.nickname'),
                        helperText: nameValid ? null : s.t('home.nicknameHint'),
                        helperMaxLines: 2,
                        errorText: nameValid ? null : s.t('error.bad_name'),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 20),
                    NeonButton(
                      label: s.t('home.solo'),
                      icon: Icons.sports_esports,
                      color: theme.accentSolo,
                      onPressed: () => _go(SoloScreen.route),
                    ),
                    const SizedBox(height: 12),
                    NeonButton(
                      label: s.t('home.duel'),
                      icon: Icons.bolt,
                      color: theme.accentDuel,
                      onPressed: () => _go(DuelLobbyScreen.route),
                    ),
                    const SizedBox(height: 12),
                    NeonButton(
                      label: s.t('home.leaderboard'),
                      icon: Icons.leaderboard,
                      color: theme.accentLeaderboard,
                      filled: false,
                      onPressed: () => _go(LeaderboardScreen.route),
                    ),
                    const SizedBox(height: 12),
                    NeonButton(
                      label: s.t('home.settings'),
                      icon: Icons.tune,
                      color: theme.accentSettings,
                      filled: false,
                      onPressed: () => _go(SettingsScreen.route),
                    ),
                    const SizedBox(height: 20),
                    // The wallet and the way into the shop (SPEC 4.8), as one
                    // quiet row rather than a fifth button: the balance is
                    // something to glance at, not something to be shouted at.
                    ShopEntryCard(onTap: () => _go(ShopScreen.route)),
                    const SizedBox(height: 12),
                    NeonPanel(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      color: theme.accentLeaderboard,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // The record on the board the player's chosen game
                          // counts for (SPEC §2.3, §4.6). The label names that
                          // game as soon as it is not the classic one: the
                          // figure changes with the ball count, and a number
                          // that moves without saying why reads as a bug.
                          _statLine(
                            theme,
                            settings.ballCount == minBallCount
                                ? s.t('home.best')
                                : s.f('home.bestOf', {
                                    'balls': s.balls(settings.ballCount),
                                  }),
                            settings.bestScoreFor(settings.ballCount) > 0
                                ? '${settings.bestScoreFor(settings.ballCount)}'
                                : s.t('home.noBest'),
                          ),
                          // The standing comes from `GET /api/players/me`
                          // (SPEC §4.4 / §4.6) and appears only once the
                          // player has one: nothing here ever asks them to
                          // sign in, or hints that they should. A rank of
                          // null means no verified run has landed yet, which
                          // is worth saying rather than hiding once the
                          // player is asking about their standing at all.
                          if (profile case final profile?) ...[
                            const SizedBox(height: 8),
                            _statLine(
                              theme,
                              s.t('home.rank'),
                              profile.rank == null
                                  ? s.t('home.rankUnranked')
                                  : s.f('common.rankValue', {
                                      'rank': profile.rank!,
                                    }),
                              dim: true,
                            ),
                          ],
                          if (profile?.countryRank case final rank?)
                            if (profile?.country case final code?) ...[
                              const SizedBox(height: 6),
                              _statLine(
                                theme,
                                s.f('home.countryRank', {
                                  'country': s.country(code),
                                }),
                                s.f('common.rankValue', {'rank': rank}),
                                dim: true,
                              ),
                            ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
