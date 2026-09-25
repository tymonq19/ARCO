import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';

import '../app/game_theme.dart';
import '../app/strings.dart';
import '../game/controllers/duel_controller.dart';
import '../game/render/game_view.dart';
import 'widgets/hearts_row.dart';
import 'widgets/multiplier_badge.dart';
import 'widgets/neon_button.dart';
import 'widgets/neon_panel.dart';

/// The duel arena. Player 1 sees the board rotated by 180°, so both players
/// defend the bottom of their own screen.
class DuelScreen extends StatefulWidget {
  const DuelScreen({super.key, required this.controller});

  final DuelController controller;

  static const String route = '/duel/game';

  @override
  State<DuelScreen> createState() => _DuelScreenState();
}

class _DuelScreenState extends State<DuelScreen> {
  /// Vertical space each HUD strip reserves.
  static const double hudHeight = 74;

  DuelController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _leave() {
    _controller.leaveRoom();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final state = _controller.state;
    final padding = MediaQuery.paddingOf(context);
    _updateCountdownLabel(s, state);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          GameView(
            stateOf: () => _controller.state,
            fx: _controller.fx,
            onFrame: _controller.advance,
            input: _controller.input,
            rotated: _controller.rotated,
            ownPlayer: _controller.slot,
            topInset: hudHeight + padding.top,
            bottomInset: hudHeight + padding.bottom,
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: _hudStrip(
                player: _controller.opponent,
                name: _controller.opponentName.isEmpty
                    ? s.t('duel.opponent')
                    : _controller.opponentName,
                color: theme.opponentPaddle,
                own: false,
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: _hudStrip(
                player: _controller.me,
                name: _controller.ownName.isEmpty
                    ? s.t('duel.you')
                    : _controller.ownName,
                color: theme.ownPaddle,
                own: true,
              ),
            ),
          ),
          Positioned(
            top: padding.top + 6,
            right: 12,
            child: NeonIconButton(
              icon: Icons.close,
              color: theme.textDim,
              tooltip: s.t('duel.leave'),
              onPressed: _leave,
            ),
          ),
          if (_controller.peerLeft) _overlay(_peerLeftPanel(s)),
          if (_controller.over && !_controller.peerLeft)
            _overlay(_resultPanel(s)),
        ],
      ),
    );
  }

  /// The painter draws whatever label the screen puts into the fx state, so
  /// the countdown text stays localized.
  void _updateCountdownLabel(Strings s, GameState? state) {
    if (_controller.inCountdown) {
      _controller.fx.setCountdown('${_controller.countdownSeconds}');
    } else if (state != null &&
        state.tick < tickRate &&
        !_controller.over &&
        !_controller.peerLeft) {
      _controller.fx.setCountdown(s.t('duel.go'));
    } else {
      _controller.fx.setCountdown(null);
    }
  }

  Widget _overlay(Widget child) => Positioned.fill(
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: GameTheme.of(context).background.withValues(alpha: 0.75),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: child,
          ),
        ),
      ),
    ),
  );

  Widget _hudStrip({
    required Player? player,
    required String name,
    required Color color,
    required bool own,
  }) {
    final theme = GameTheme.of(context);
    final lives = player?.lives ?? startLives;
    final score = player?.score ?? 0;
    final combo = player?.combo ?? 0;
    final multiplier = player?.multiplier ?? 1;
    final children = <Widget>[
      // Flexible so a maximum-length nickname (`nameMaxLength`) gives way to
      // the score block and ellipsizes instead of overflowing the strip.
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w900,
                fontSize: 13,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            HeartsRow(lives: lives, size: 18, color: color),
          ],
        ),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$score',
            style: TextStyle(
              color: theme.textPrimary,
              fontWeight: FontWeight.w900,
              fontSize: 24,
            ),
          ),
          const SizedBox(height: 2),
          MultiplierBadge(multiplier: multiplier, combo: combo),
        ],
      ),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        own ? 4 : 8,
        own ? 16 : 56,
        own ? 10 : 4,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }

  Widget _resultPanel(Strings s) {
    final theme = GameTheme.of(context);
    final won = _controller.won;
    final scores = _controller.scores;
    final mine = _controller.slot < scores.length
        ? scores[_controller.slot]
        : 0;
    final theirs = scores.length > 1 ? scores[1 - _controller.slot] : 0;
    final accent = won ? theme.ownPaddle : theme.opponentPaddle;
    return NeonPanel(
      color: accent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlowText(
            won ? s.t('duel.win') : s.t('duel.lose'),
            color: accent,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: _scoreBlock(s.t('duel.you'), mine, theme.ownPaddle),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  '–',
                  style: TextStyle(color: theme.textDim, fontSize: 22),
                ),
              ),
              Flexible(
                child: _scoreBlock(
                  _controller.opponentName.isEmpty
                      ? s.t('duel.opponent')
                      : _controller.opponentName,
                  theirs,
                  theme.opponentPaddle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          if (_controller.rematchRequested)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                s.t('duel.waitingRematch'),
                style: TextStyle(color: theme.textDim, fontSize: 12),
              ),
            ),
          NeonButton(
            label: s.t('duel.rematch'),
            onPressed: _controller.rematchRequested
                ? null
                : _controller.rematch,
          ),
          const SizedBox(height: 10),
          NeonButton(
            label: s.t('duel.leave'),
            filled: false,
            color: theme.textDim,
            onPressed: _leave,
          ),
        ],
      ),
    );
  }

  Widget _scoreBlock(String label, int score, Color color) {
    final theme = GameTheme.of(context);
    return Column(
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '$score',
            maxLines: 1,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }

  Widget _peerLeftPanel(Strings s) {
    final theme = GameTheme.of(context);
    return NeonPanel(
      color: theme.danger,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_off, color: theme.danger, size: 40),
          const SizedBox(height: 14),
          Text(
            s.t('duel.peerLeft'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 20),
          NeonButton(label: s.t('duel.leave'), onPressed: _leave),
        ],
      ),
    );
  }
}
