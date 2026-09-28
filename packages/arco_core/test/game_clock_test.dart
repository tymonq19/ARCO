// The clock that ends every game (SPEC §2.3): `maxGameTicks`, one hour of play.
//
// This exists because of the speed ceiling. Before it, ball speed grew with
// every hit without limit, so every rally ended: sooner or later the ball moved
// faster than any player could answer. That was the complaint the ceiling fixed
// — a run you were always going to lose is not a game you get to play — but it
// was also, by accident, the thing that guaranteed a run ended at all.
//
// An endless run is an unscoreable run. A solo score only counts once it has
// been submitted and re-simulated, and the submission carries the whole input
// log, so a run with no end is a run with no score: too long to verify inside a
// request and too large to send. The clock turns that into a finish line. Play
// well enough and the hour, not the physics, is what stops you — and the score
// you earned is a score the server will take.
import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

/// Plays [config] with a bot that keeps the paddle on the ball nearest the rim
/// and stops when the game does. Good enough to survive the hour with one ball;
/// two balls still beat it.
GameState playUntilOver(GameConfig config) {
  final s = GameState.initial(config);
  final inputs = <PlayerInput>[
    for (var i = 0; i < s.players.length; i++) PlayerInput.none,
  ];
  while (s.phase != Phase.gameOver) {
    for (var p = 0; p < s.players.length; p++) {
      inputs[p] = ScriptedInput.aimAtBall(s, p);
    }
    Simulation.step(s, inputs);
  }
  return s;
}

void main() {
  test('the hour is an hour of ticks', () {
    expect(maxGameTicks, 216000);
    expect(maxGameTicks, 60 * 60 * tickRate);
    expect(
      ReplayVerifier.maxTicks,
      maxGameTicks,
      reason: 'the longest replay accepted is the longest game producible',
    );
  });

  group('a player good enough not to lose', () {
    test('is stopped by the clock, on the tick, with lives to spare', () {
      final s = playUntilOver(const GameConfig(mode: GameMode.solo, seed: 4));
      expect(
        s.tick,
        maxGameTicks,
        reason: 'not one tick early and not one tick late',
      );
      expect(
        s.players[0].lives,
        greaterThan(0),
        reason: 'the clock ended this, not a miss',
      );
      expect(s.winner, -1, reason: 'solo has nobody to beat');
    });

    test('keeps the score, and is paid for the final second', () {
      // The survival point for second 3600 is awarded before the clock is read,
      // so the last second of the hour counts like every other one.
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 4),
      );
      final inputs = <PlayerInput>[PlayerInput.none];
      var scoreBefore = 0;
      while (s.phase != Phase.gameOver) {
        if (s.tick == maxGameTicks - 1) scoreBefore = s.players[0].score;
        inputs[0] = ScriptedInput.aimAtBall(s, 0);
        Simulation.step(s, inputs);
      }
      expect(
        s.players[0].score,
        scoreBefore + 1,
        reason: 'the 3600th survival second is paid',
      );
      expect(s.players[0].score, greaterThan(3600));
    });

    test(
      'hands the server a replay it accepts',
      () {
        final s = GameState.initial(
          const GameConfig(mode: GameMode.solo, seed: 4),
        );
        final log = InputLog();
        final inputs = <PlayerInput>[PlayerInput.none];
        while (s.phase != Phase.gameOver) {
          final input = ScriptedInput.aimAtBall(s, 0);
          log.record(s.tick, input);
          inputs[0] = input;
          Simulation.step(s, inputs);
        }
        final result = ReplayVerifier.verify(
          Replay(
            config: s.config,
            inputs: <InputLog>[log],
            finalTick: s.tick,
            claimedScore: s.players[0].score,
          ),
        );
        expect(
          result.ok,
          isTrue,
          reason: 'an hour of good play must be scoreable: ${result.reason}',
        );
        expect(result.score, s.players[0].score);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'the two-ball game is still lost the old-fashioned way',
      () {
        // The same bot, given two balls to meet, does not reach the hour: it
        // runs out of lives at about ten minutes. Worth pinning, because the
        // ceiling this clock exists to backstop was a playability change, and a
        // playability change that made the two-ball game unloseable would have
        // gone too far. Two balls are still the hard mode.
        final s = playUntilOver(
          const GameConfig(mode: GameMode.solo, seed: 4, ballCount: 2),
        );
        expect(s.players[0].lives, 0, reason: 'lost, not timed out');
        expect(s.tick, lessThan(maxGameTicks));
        expect(
          s.tick,
          greaterThan(5 * 60 * tickRate),
          reason: 'but not a short game either: a good player gets minutes',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('the clock stops a two-ball game as well', () {
      // Driven to the final tick rather than played to it, because this bot
      // loses first (above). The rule under test is that the clock does not care
      // how many balls are in the air.
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 4, ballCount: 2),
      );
      s.tick = maxGameTicks - 1;
      Simulation.step(s, const <PlayerInput>[PlayerInput.none]);
      expect(s.phase, Phase.gameOver);
      expect(s.tick, maxGameTicks);
      expect(s.players[0].lives, greaterThan(0));
    });
  });

  group('the last frame is a finished game', () {
    test('every ball is parked and still', () {
      // Whichever way the game ended -- this one ends on lives -- the last
      // frame reads as finished, so two games that ended the same way hash the
      // same.
      final s = playUntilOver(
        const GameConfig(mode: GameMode.solo, seed: 4, ballCount: 2),
      );
      expect(s.phase, Phase.gameOver);
      expect(s.balls, hasLength(2));
      for (final b in s.balls) {
        expect(b.active, isFalse);
        expect(b.queued, isFalse);
        expect(b.x, 0);
        expect(b.y, 0);
        expect(b.vx, 0);
        expect(b.vy, 0);
        expect(b.speed, 0);
        expect(b.owner, -1);
      }
      expect(s.serveTimer, 0, reason: 'nothing is waiting to launch');
    });

    test('it says game over exactly once', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 4),
      );
      final inputs = <PlayerInput>[PlayerInput.none];
      var overs = 0;
      while (s.phase != Phase.gameOver) {
        inputs[0] = ScriptedInput.aimAtBall(s, 0);
        Simulation.step(s, inputs);
        overs += s.events.where((e) => e.type == GameEventType.gameOver).length;
      }
      expect(overs, 1);
      // Stepping a finished game is a no-op, so no second announcement.
      Simulation.step(s, inputs);
      expect(s.tick, maxGameTicks);
      expect(s.events, isEmpty);
    });

    test('a life lost at the buzzer still ends it once', () {
      // The two endings cannot both fire: the life-loss path sets gameOver
      // during the tick, and the clock skips a game that is already over.
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 11),
      );
      final inputs = <PlayerInput>[PlayerInput.none];
      var overs = 0;
      while (s.phase != Phase.gameOver) {
        Simulation.step(s, inputs);
        overs += s.events.where((e) => e.type == GameEventType.gameOver).length;
      }
      expect(s.tick, lessThan(maxGameTicks), reason: 'a still paddle loses');
      expect(overs, 1);
      expect(s.players[0].lives, 0);
    });
  });

  group('a duel the clock stops', () {
    /// Steps a duel to the limit with [inputs] frozen, then reports the winner.
    int winnerWithScores(int scoreA, int scoreB, int livesA, int livesB) {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.duel, seed: 4),
      );
      // Drive the clock, not the rally: the players are placed where the test
      // needs them and the game is stepped to the final tick.
      s.tick = maxGameTicks - 1;
      s.players[0].score = scoreA;
      s.players[1].score = scoreB;
      s.players[0].lives = livesA;
      s.players[1].lives = livesB;
      Simulation.step(s, const <PlayerInput>[
        PlayerInput.none,
        PlayerInput.none,
      ]);
      expect(s.phase, Phase.gameOver);
      expect(s.tick, maxGameTicks);
      return s.winner;
    }

    test('the higher score wins', () {
      expect(winnerWithScores(40, 10, 3, 3), 0);
      expect(winnerWithScores(10, 40, 3, 3), 1);
    });

    test('level on score, the fuller life bar wins', () {
      expect(winnerWithScores(25, 25, 3, 1), 0);
      expect(winnerWithScores(25, 25, 1, 3), 1);
    });

    test('level on both is a draw, which is nobody', () {
      expect(
        winnerWithScores(25, 25, 2, 2),
        -1,
        reason: 'neither client may claim a win it did not earn',
      );
    });
  });
}
