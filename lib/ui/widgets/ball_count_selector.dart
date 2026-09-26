import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';

/// How many balls the next game is played with (SPEC §2.3, `GameConfig.ballCount`).
///
/// **Not a setting.** It goes into the config the replay is verified against and
/// it decides which leaderboard a run lands on, so it is offered where a game is
/// about to begin — the solo start overlay and the duel room — and never in
/// Settings next to the sound switch. The note under it says what changes, because
/// "2 balls" on its own does not tell a player that either ball escaping costs a
/// life.
///
/// Reads at 320 pt and a 1.6 text scale: the two segments share the width, their
/// height grows with the text and each label is one line that shrinks rather than
/// wraps.
class BallCountSelector extends StatelessWidget {
  const BallCountSelector({
    super.key,
    required this.value,
    this.onChanged,
    this.showNote = true,
    this.footnote,
  });

  /// The count currently chosen, [minBallCount]..[maxBallCount].
  final int value;

  /// Called with the new count; null renders the choice read-only, which is what
  /// the joiner of a duel sees (the creator picked it).
  final ValueChanged<int>? onChanged;

  /// Whether to explain what two balls change.
  final bool showNote;

  /// An extra line under the note, e.g. who gets to choose in a duel.
  final String? footnote;

  bool get _enabled => onChanged != null;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          theme.heading(s.t('game.balls')),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: theme.textDim,
            fontSize: 11,
            letterSpacing: 2,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var n = minBallCount; n <= maxBallCount; n++)
              _segment(theme, s, n),
          ],
        ),
        if (showNote) ...[
          const SizedBox(height: 8),
          Text(
            s.t('game.ballsNote'),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.textDim, fontSize: 11, height: 1.35),
          ),
        ],
        if (footnote case final line?) ...[
          const SizedBox(height: 6),
          Text(
            line,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.textDim, fontSize: 11, height: 1.35),
          ),
        ],
      ],
    );
  }

  Widget _segment(GameTheme theme, Strings s, int n) {
    final selected = n == value;
    final label = theme.heading(s.balls(n));
    return Expanded(
      child: Semantics(
        button: _enabled,
        inMutuallyExclusiveGroup: true,
        selected: selected,
        label: label,
        child: ExcludeSemantics(
          child: GestureDetector(
            onTap: _enabled && !selected ? () => onChanged!(n) : null,
            behavior: HitTestBehavior.opaque,
            child: Container(
              // A minimum rather than a fixed height: the label is allowed to
              // push the control taller at a large text scale instead of being
              // clipped by it.
              constraints: const BoxConstraints(minHeight: 46),
              alignment: Alignment.center,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              decoration: ShapeDecoration(
                color: selected
                    ? theme.accent.withValues(alpha: _enabled ? 0.2 : 0.12)
                    : Colors.transparent,
                shape: theme.border(
                  theme.radius(0.55),
                  color: selected
                      ? theme.accent.withValues(alpha: _enabled ? 1 : 0.6)
                      : theme.outline,
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: selected ? theme.textPrimary : theme.textDim,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
