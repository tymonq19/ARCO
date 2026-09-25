import 'dart:async';

import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/game_theme.dart';
import '../app/settings.dart';
import '../app/strings.dart';
import '../game/controllers/solo_controller.dart';
import '../game/input/input_controller.dart';
import '../game/input/input_factory.dart';
import '../game/input/keyboard_input.dart';
import '../game/render/game_view.dart';
import '../services/ads_gateway.dart';
import '../services/ads_service.dart';
import '../services/api_client.dart';
import '../services/audio_service.dart';
import '../services/haptics.dart';
import '../services/player_identity.dart';
import '../services/score_submitter.dart';
import '../services/shop_service.dart';
import '../services/storage.dart';
import 'widgets/account_offer_card.dart';
import 'widgets/hearts_row.dart';
import 'widgets/multiplier_badge.dart';
import 'widgets/neon_button.dart';
import 'widgets/neon_panel.dart';
import 'widgets/nickname_dialog.dart';
import 'widgets/spark_balance.dart';

/// Endless solo survival: arena, HUD, pause and the game-over overlay with the
/// automatic leaderboard submission — and, on that overlay only, the optional
/// rewarded ad of SPEC §4.10.
///
/// The ad is offered **after** a run and never before one: no interstitial, no
/// ad on launch, nothing between a tap and a game. And it is drawn only when one is
/// already loaded, so the button is instant or it is not there.
class SoloScreen extends StatefulWidget {
  const SoloScreen({super.key});

  static const String route = '/solo';

  @override
  State<SoloScreen> createState() => _SoloScreenState();
}

class _SoloScreenState extends State<SoloScreen> with WidgetsBindingObserver {
  /// Vertical space the HUD reserves above the arena.
  static const double hudHeight = 96;

  late final SoloController _controller;
  late final ScoreSubmitter _submitter;
  bool _submitted = false;
  bool _submitting = false;
  String? _submitStatus;

  /// The nickname was refused by the filter of SPEC §4.7 and the replay is still
  /// stored: the overlay offers to change the name and send the same game again.
  bool _canRename = false;

  /// What a rewarded ad on this overlay came to (SPEC §4.10), or null when none
  /// has been watched. Shown under the buttons rather than as a snack bar: the
  /// overlay is the whole screen, and a toast over it would be covering the score.
  String? _adStatus;

  /// What this run paid into the shop wallet (SPEC §4.8), as the server reported
  /// it on the `201`. Null until a submission has been accepted — and null
  /// forever for a run that was never accepted, because then nothing was earned
  /// and "+0" would be a different claim from saying nothing.
  int? _earned;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final settings = context.read<Settings>();
    _controller = SoloController(
      settings: settings,
      audio: context.read<AudioService>(),
      haptics: context.read<Haptics>(),
      input: CompositeInput(<InputController>[
        KeyboardInput(),
        createInputController(settings),
      ]),
    )..addListener(_onControllerChanged);
    _submitter = ScoreSubmitter(
      api: context.read<ApiClient>(),
      storage: context.read<Storage>(),
      identity: context.read<PlayerIdentity>(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _retryPending());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller.pause();
  }

  void _onControllerChanged() {
    if (_controller.gameOver && !_submitted) {
      _submitted = true;
      _submit();
      // The run is over, so this is the moment to find out whether an optional
      // extra reward is available — not before, and never during a game
      // (SPEC §4.10). It asks the server for the allowance and preloads an ad; the
      // button appears only if both answer yes, so it is instant or absent.
      unawaited(context.read<AdsService>().refresh());
    }
    if (mounted) setState(() {});
  }

  /// Watches a rewarded ad for extra Sparks on the run just finished
  /// (SPEC §4.10).
  ///
  /// **This adds nothing.** The reward is credited by our server on Google's signed
  /// callback; this shows the ad and then repeats what the server says. Closing the
  /// ad early is silent.
  ///
  /// There is deliberately no consent form here: game over is not the moment for a
  /// privacy form, so this button exists only when an ad is already in hand
  /// ([AdsService.offeredAtGameOver]). The form is offered in the shop instead.
  Future<void> _watchAd() async {
    final s = Strings.read(context);
    final ads = context.read<AdsService>();
    context.read<AudioService>().play(Sfx.click);
    final report = await ads.watch(AdPlacementId.gameOver);
    if (!mounted) return;
    switch (report.kind) {
      case AdReportKind.credited:
        context.read<AudioService>().play(Sfx.star);
        setState(() {
          _adStatus = s.f('ads.credited', {
            'sparks': s.sparks(report.sparks),
            'balance': s.sparks(
              report.balance ?? context.read<ShopService>().balance,
            ),
          });
        });
      case AdReportKind.awaitingServer:
        setState(() => _adStatus = s.t('ads.waiting'));
      case AdReportKind.dismissed:
      case AdReportKind.consentRefused:
        break;
      case AdReportKind.unavailable:
        setState(() => _adStatus = s.t('ads.noAd'));
    }
  }

  /// Uploads the finished game once. Offline submissions are kept in prefs and
  /// retried the next time this screen or the leaderboard opens.
  Future<void> _submit() async {
    final replay = _controller.replay;
    if (replay == null) return;
    final s = Strings.read(context);
    final name = normalizeName(context.read<Settings>().playerName);
    if (name == null) {
      setState(() => _submitStatus = s.t('solo.invalidName'));
      return;
    }
    setState(() {
      _submitting = true;
      _submitStatus = s.t('solo.submitting');
    });
    final outcome = await _submitter.submit(name, replay);
    if (!mounted) return;
    _applyOutcome(s, outcome);
  }

  /// Shows what became of the upload, and whether a new nickname would fix it.
  void _applyOutcome(Strings s, SubmitOutcome? outcome) {
    setState(() {
      _submitting = false;
      _canRename = outcome is SubmitRejected && outcome.canRetryUnderNewName;
      _submitStatus = _statusFor(s, outcome);
      if (outcome is SubmitAccepted) _earned = outcome.tokens;
    });
    // The wallet the server reported, plus the day's allowance, which only the
    // inventory endpoint carries (SPEC §4.8) — and which is the difference
    // between "that run paid nothing" and "you have earned today's 200".
    if (outcome is SubmitAccepted && outcome.tokens != null) {
      context.read<ShopService>().noteRun(
        tokens: outcome.tokens,
        balance: outcome.tokenBalance,
      );
    }
  }

  /// A null [outcome] is a retry that found the server still unreachable: the
  /// replay is stored, which is exactly what "saved locally" says.
  String _statusFor(Strings s, SubmitOutcome? outcome) => switch (outcome) {
    SubmitAccepted(
      rank: final rank,
      country: final code?,
      countryRank: final countryRank?,
    )
        when rank > 0 =>
      s.f('solo.rankCountry', {
        'rank': rank,
        'countryRank': countryRank,
        'country': s.country(code),
      }),
    SubmitAccepted(rank: final rank) when rank > 0 => s.f('solo.rank', {
      'rank': rank,
    }),
    SubmitAccepted() => s.t('common.ok'),
    SubmitDeferred() => s.t('solo.savedLocally'),
    SubmitRejected(error: final code) => s.submitError(code),
    null => s.t('solo.savedLocally'),
  };

  /// Picks a new nickname and sends the stored game again under it (SPEC §4.7).
  Future<void> _changeName() async {
    final s = Strings.read(context);
    final settings = context.read<Settings>();
    final name = await showNicknameDialog(
      context,
      initial: settings.playerName,
      message: s.t('error.offensive_name'),
    );
    if (name == null || !mounted) return;
    settings.playerName = name;
    setState(() {
      _canRename = false;
      _submitting = true;
      _submitStatus = s.t('solo.submitting');
    });
    final outcome = await _submitter.retryPendingAs(name);
    if (!mounted) return;
    _applyOutcome(s, outcome);
  }

  Future<void> _retryPending() async {
    if (context.read<Storage>().pendingReplay == null) return;
    final s = Strings.read(context);
    final outcome = await _submitter.retryPending();
    if (!mounted) return;
    if (outcome is SubmitAccepted) {
      // A replay that finally landed paid into the wallet too (SPEC §4.8).
      if (outcome.tokens != null) {
        context.read<ShopService>().noteRun(
          tokens: outcome.tokens,
          balance: outcome.tokenBalance,
        );
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.f('solo.pendingSent', {'rank': outcome.rank})),
        ),
      );
    } else if (outcome is SubmitRejected && outcome.canRetryUnderNewName) {
      // The stored game is fine and still stored; the name on it is not.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.submitError(outcome.error)),
          action: SnackBarAction(
            label: s.t('solo.changeName'),
            onPressed: _changeName,
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  void _retry() {
    setState(() {
      _submitted = false;
      _submitting = false;
      _submitStatus = null;
      _canRename = false;
      _earned = null;
    });
    _controller.retry();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final settings = context.watch<Settings>();
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          GameView(
            stateOf: () => _controller.state,
            fx: _controller.fx,
            onFrame: _controller.advance,
            input: _controller.input,
            topInset: hudHeight + padding.top,
            bottomInset: 24 + padding.bottom,
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(bottom: false, child: _buildHud(s, settings)),
          ),
          if (!_controller.started && !_controller.gameOver)
            _overlay(_buildStartPanel(s, settings), onTap: _controller.start),
          if (_controller.paused && !_controller.gameOver)
            _overlay(_buildPausePanel(s)),
          if (_controller.gameOver) _overlay(_buildGameOverPanel(s, settings)),
        ],
      ),
    );
  }

  /// Dimmed, tap-absorbing layer above the arena.
  Widget _overlay(Widget child, {VoidCallback? onTap}) => Positioned.fill(
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: GameTheme.of(context).background.withValues(alpha: 0.72),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: child,
          ),
        ),
      ),
    ),
  );

  Widget _buildHud(Strings s, Settings settings) {
    final theme = GameTheme.of(context);
    final seconds = _controller.elapsedSeconds.floor();
    final time =
        '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Column(
        children: [
          Row(
            children: [
              NeonIconButton(
                icon: _controller.paused ? Icons.play_arrow : Icons.pause,
                tooltip: s.t('solo.paused'),
                onPressed: _controller.started
                    ? _controller.togglePause
                    : () => Navigator.of(context).maybePop(),
              ),
              const Spacer(),
              HeartsRow(lives: _controller.lives, size: 22),
              const Spacer(),
              // A minimum width keeps the hearts from shifting as the digits
              // change; the clock grows past it (instead of wrapping) when the
              // text scale or the font makes it wider.
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 54),
                child: Text(
                  time,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _stat(theme, s.t('hud.score'), '${_controller.score}', big: true),
              const Spacer(),
              MultiplierBadge(
                multiplier: _controller.multiplier,
                combo: _controller.player.combo,
              ),
              const Spacer(),
              _stat(theme, s.t('hud.best'), '${settings.bestScore}', end: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(
    GameTheme theme,
    String label,
    String value, {
    bool big = false,
    bool end = false,
  }) {
    return Column(
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          theme.heading(label),
          style: TextStyle(
            color: theme.textDim,
            fontSize: 10,
            letterSpacing: 2,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: theme.textPrimary,
            fontSize: big ? 28 : 16,
            fontWeight: FontWeight.w900,
            shadows: big && theme.hasGlow
                ? [
                    Shadow(
                      color: theme.accent.withValues(alpha: 0.6 * theme.glow),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildStartPanel(Strings s, Settings settings) {
    final theme = GameTheme.of(context);
    final hint = switch (settings.controlMode) {
      ControlMode.joystick => s.t('solo.controlsHint.joystick'),
      ControlMode.tilt => s.t('solo.controlsHint.tilt'),
      ControlMode.follow => s.t('solo.controlsHint.follow'),
    };
    return NeonPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlowText(
            s.t('solo.tapToStart'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.textDim, fontSize: 13),
          ),
          const SizedBox(height: 18),
          NeonButton(
            label: s.t('solo.tapToStart'),
            height: 52,
            fontSize: 14,
            onPressed: _controller.start,
          ),
        ],
      ),
    );
  }

  Widget _buildPausePanel(Strings s) {
    final theme = GameTheme.of(context);
    return NeonPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlowText(
            s.t('solo.paused'),
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 20),
          NeonButton(label: s.t('solo.resume'), onPressed: _controller.resume),
          const SizedBox(height: 10),
          NeonButton(
            label: s.t('common.home'),
            filled: false,
            color: theme.textDim,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  /// The sparks a run paid, as a chip beside the score.
  Widget _earnedChip(GameTheme theme, int earned) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: ShapeDecoration(
      color: theme.star.withValues(alpha: 0.16),
      shape: theme.border(
        theme.radius(0.5),
        color: theme.star.withValues(alpha: 0.5),
        width: 1,
      ),
    ),
    child: SparkAmount(
      amount: earned,
      prefix: '+',
      fontSize: 20,
      color: theme.star,
    ),
  );

  /// The rewarded-ad offer: one line saying what it pays, and one button.
  ///
  /// Quiet on purpose. No badge, no countdown, no "double your sparks!" — an ad is
  /// half a minute the player is giving us, and the honest way to ask is to say
  /// what it pays and leave it alone.
  Widget _adOffer(Strings s, GameTheme theme) {
    final ads = context.watch<AdsService>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.f('ads.hint', {'sparks': s.sparks(ads.offer.sparks)}),
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.textDim, fontSize: 12, height: 1.35),
        ),
        const SizedBox(height: 10),
        Semantics(
          button: true,
          enabled: !ads.busy,
          label: '${s.t('ads.watch')}, ${s.sparks(ads.offer.sparks)}',
          child: ExcludeSemantics(
            child: NeonButton(
              label: s.t('ads.watch'),
              height: 48,
              fontSize: 13,
              filled: false,
              color: theme.star,
              onPressed: ads.busy ? null : _watchAd,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGameOverPanel(Strings s, Settings settings) {
    final theme = GameTheme.of(context);
    final shop = context.watch<ShopService>();
    final accent = _controller.newBest ? theme.accentLeaderboard : theme.accent;
    return NeonPanel(
      color: accent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlowText(
            _controller.newBest ? s.t('solo.newBest') : s.t('solo.gameOver'),
            color: accent,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 16),
          // The score and what it paid, side by side: the sparks a run earned are
          // part of the result, not a popup on top of it. A [Wrap] so the reward
          // drops under the score instead of overflowing at a large text scale.
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 14,
            children: [
              Text(
                '${_controller.score}',
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.w900,
                  color: theme.textPrimary,
                ),
              ),
              // What the run paid — and only for a player who still has something
              // to spend it on. One rule across the app (SPEC §4.9): a Spark
              // figure appears where it can be acted on, and a player who bought
              // the unlock owns everything it could have bought. The server keeps
              // crediting the run either way, so nothing is lost and a revoked
              // entitlement brings the figure back.
              if (_earned case final earned?
                  when earned > 0 && shop.snapshot.showsBalance)
                _earnedChip(theme, earned),
            ],
          ),
          Text(
            '${s.t('hud.best')}: ${settings.bestScore}',
            style: TextStyle(color: theme.textDim, fontSize: 13),
          ),
          // The day's allowance is spent, so this run paid less than it was worth
          // (or nothing at all). Said plainly — a good game that quietly earns
          // zero reads as a bug (SPEC §4.8).
          if (_earned != null &&
              shop.snapshot.showsBalance &&
              shop.snapshot.dailyCapReached) ...[
            const SizedBox(height: 8),
            Text(
              s.f('shop.capReached', {'cap': s.sparks(shop.snapshot.dailyCap)}),
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textDim, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          if (_submitting)
            const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (_submitStatus != null)
            Text(
              _submitStatus!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textDim, fontSize: 12),
            ),
          if (_canRename && !_submitting) ...[
            const SizedBox(height: 12),
            NeonButton(
              label: s.t('solo.changeName'),
              height: 46,
              fontSize: 13,
              filled: false,
              color: theme.accentLeaderboard,
              onPressed: _changeName,
            ),
          ],
          // The moment the account offer belongs to (SPEC 4.5): right under a
          // score the player has just beaten their own record with, where
          // "keep this" answers something they are already thinking. Only
          // after a personal best, never after an ordinary game, and it draws
          // nothing at all when there is no sign-in to offer or the player has
          // already said no.
          if (_controller.newBest) ...[
            const SizedBox(height: 16),
            const AccountOfferCard(),
          ],
          // An optional extra on the run just finished (SPEC §4.10): under the
          // result and above Retry, so it reads as something offered rather than
          // something in the way. It is drawn only when an ad is already loaded and
          // the server says it would pay — never a spinner, never a dead button,
          // and never before a game.
          if (context.watch<AdsService>().offeredAtGameOver) ...[
            const SizedBox(height: 16),
            _adOffer(s, theme),
          ],
          if (_adStatus case final status?) ...[
            const SizedBox(height: 10),
            Text(
              status,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textDim, fontSize: 12),
            ),
          ],
          const SizedBox(height: 18),
          NeonButton(label: s.t('solo.retry'), onPressed: _retry),
          const SizedBox(height: 10),
          NeonButton(
            label: s.t('common.home'),
            filled: false,
            color: theme.textDim,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}
