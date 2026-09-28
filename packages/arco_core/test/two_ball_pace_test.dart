// The pace of the two-ball game (SPEC §2.3): the staggered serve, the two-ball
// speeds and the speed curve that flattens.
//
// This file is about *playability*, which is a different question from the rules
// in multi_ball_test.dart. Three things were wrong with the two-ball game:
//
//  1. Both balls left the origin on the same tick. One paddle cannot be at two
//     arrival points at once, so the second ball was not a challenge but a
//     coin toss. Ball 1 now waits `twoBallServeStaggerTicks` (65 ticks, 1.083 s)
//     and is [Ball.queued] meanwhile — parked at the origin, out of play, but
//     already carrying the velocity it will leave with, so the player can see it
//     waiting and see where it will go.
//  2. It ran at the one-ball speeds, which is the wrong tempo for a game where
//     you track two balls. It has its own serve speed (0.42 against 0.55), its
//     own ramp and its own ceiling (0.72 against 1.6 / 1.5).
//  3. Every paddle hit multiplied the speed by a constant until it pinned at the
//     ceiling, so a long rally ended in arithmetic rather than play. A hit now
//     closes 9% of the gap that is left to the ceiling (floor 0.0025 u/s): steep
//     while the rally is young, then a plateau.
//
// The one-ball game is untouched — `golden_hash_test.dart` pins it — and the
// one-ball numbers are asserted here too, so a change that "fixed" the wrong
// mode fails twice.
import 'dart:convert';
import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Reaction time a player is allowed before the paddle starts moving, seconds.
/// Not a simulation constant — the yardstick the ceiling was chosen against.
const double _reaction = 0.25;

/// Mean chord a ball crosses between two paddle-ring visits: the rebound is at
/// `theta` from the inward radial with `cos(theta) >= paddleMinInwardDot`, so
/// the chord is `2 R cos(theta)` and its mean over the allowed range is
/// `2 R sin(t) / t` with `t = acos(paddleMinInwardDot)`.
double get _meanChord {
  final t = math.acos(paddleMinInwardDot);
  return 2 * paddleHitRadius * math.sin(t) / t;
}

/// Mean seconds between two moments the player of [config] has to be somewhere,
/// with every ball at [speed].
double _answerInterval(GameConfig config, double speed) =>
    _meanChord / (config.ballCount * speed);

/// The speed after [hits] paddle hits in [config], starting from its serve
/// speed.
double _afterHits(GameConfig config, int hits) {
  var speed = config.serveBaseSpeed;
  for (var i = 0; i < hits; i++) {
    speed = Simulation.speedAfterHit(config, speed);
  }
  return speed;
}

/// Bounces ball 0 off player 0's paddle once, from the contact radius, and
/// returns the speed it leaves with. The paddle does not move, so this is a
/// clean hit every time.
double _bounceOnce(GameState s) {
  final centre = s.players[0].paddle.angle;
  launchRadial(s, centre, s.balls[0].speed, paddleHitRadius - 0.001);
  Simulation.step(s, noneInputs(s));
  return s.balls[0].speed;
}

/// Plays [ticks] ticks and returns the tick of every `serve` event, split into
/// rally serves (`ball == -1`) and staggered launches (`ball >= 0`).
///
/// The bot dodges the ball and the lives are topped up after every step (a plain
/// assignment, so the rng is untouched), which turns the run into a long string
/// of rallies — the point being that the stagger is a property of every serve,
/// not of the first one.
(List<int>, List<int>) _serveTicks(
  GameConfig config, {
  int ticks = 3000,
  GameState? into,
  bool dodge = false,
}) {
  final s = into ?? GameState.initial(config);
  final inputs = List<PlayerInput>.filled(s.players.length, PlayerInput.none);
  final rally = <int>[];
  final launches = <int>[];
  for (var i = 0; i < ticks; i++) {
    for (var p = 0; p < inputs.length; p++) {
      inputs[p] = dodge
          ? ScriptedInput.avoidBall(s, p)
          : ScriptedInput.aimAtBall(s, p);
    }
    Simulation.step(s, inputs);
    for (final e in s.events) {
      if (e.type != GameEventType.serve) continue;
      (e.ball < 0 ? rally : launches).add(s.tick);
    }
    if (dodge) {
      for (final p in s.players) {
        p.lives = startLives;
      }
    }
  }
  return (rally, launches);
}

void main() {
  group('the staggered serve', () {
    test('ball 1 leaves the origin exactly the stagger after ball 0', () {
      for (final mode in GameMode.values) {
        final s = GameState.initial(
          GameConfig(mode: mode, seed: 11, ballCount: 2),
        );
        final inputs = List<PlayerInput>.filled(
          s.players.length,
          PlayerInput.none,
        );
        var served = -1;
        var launched = -1;
        for (var i = 0; i < serveTicks + twoBallServeStaggerTicks + 5; i++) {
          Simulation.step(s, inputs);
          for (final e in s.events) {
            if (e.type != GameEventType.serve) continue;
            if (e.ball < 0) {
              served = s.tick;
              expect(s.balls[0].active, isTrue);
              expect(s.balls[1].active, isFalse, reason: 'ball 1 waits');
            } else {
              expect(e.ball, 1, reason: 'the queued ball is ball 1');
              launched = s.tick;
            }
          }
        }
        expect(served, serveTicks);
        expect(launched - served, twoBallServeStaggerTicks);
        expect(s.balls.every((b) => b.active), isTrue);
        expect(s.serveTimer, 0, reason: 'nothing is queued any more');
      }
    });

    test('every serve staggers, not only the first of a game', () {
      final (rally, launches) = _serveTicks(
        const GameConfig(mode: GameMode.solo, seed: 4242, ballCount: 2),
        dodge: true,
      );
      expect(
        rally.length,
        greaterThan(3),
        reason: 'the run has to contain several rallies',
      );
      expect(launches.length, rally.length);
      for (var i = 0; i < rally.length; i++) {
        expect(
          launches[i] - rally[i],
          twoBallServeStaggerTicks,
          reason: 'serve ${i + 1} of ${rally.length}',
        );
      }
    });

    test('a one-ball serve has no stagger and no queued ball', () {
      for (final mode in GameMode.values) {
        final config = GameConfig(mode: mode, seed: 11);
        expect(config.serveStaggerTicks, 0);
        final s = GameState.initial(config);
        final (rally, launches) = _serveTicks(
          config,
          ticks: 1200,
          into: s,
          dodge: true,
        );
        expect(rally, isNotEmpty);
        expect(launches, isEmpty, reason: 'nothing is ever queued');
      }
      // And the serve timer is 0 for the whole of the playing phase, which is
      // what makes the reuse of that field invisible to the one-ball game.
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 3),
      );
      final inputs = <PlayerInput>[PlayerInput.none];
      for (var i = 0; i < 1200; i++) {
        inputs[0] = ScriptedInput.aimAtBall(s, 0);
        Simulation.step(s, inputs);
        if (s.phase == Phase.playing) expect(s.serveTimer, 0);
      }
    });

    test('the queued ball is aimed, visible and out of play', () {
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 5, ballCount: 2),
      );
      s.nextWallIn = 1 << 30;
      s.nextPickupIn = 1 << 30;
      for (var i = 0; i < serveTicks; i++) {
        Simulation.step(s, noneInputs(s));
      }
      final queued = s.balls[1];
      expect(queued.queued, isTrue);
      expect(queued.active, isFalse);
      expect(queued.x, 0);
      expect(queued.y, 0);
      expect(queued.owner, -1);
      // Aimed: the velocity it will leave with, consistent with its speed, so a
      // renderer can show where it is going.
      expect(
        math.sqrt(queued.vx * queued.vx + queued.vy * queued.vy),
        closeTo(queued.speed, 1e-12),
      );
      expect(queued.speed, s.balls[0].speed);
    });

    test('a queued ball moves, collects and escapes nothing', () {
      // Ball 0 pottering about far from the origin, ball 1 queued on top of a
      // star: the star survives the whole wait, and the queued ball never moves.
      final s = twoBallState();
      launchBall(s, 0, 0.3, math.pi / 2, 0.2, index: 0);
      final queued = s.balls[1];
      queued
        ..active = false
        ..x = 0
        ..y = 0
        ..speed = twoBallBaseSpeed
        ..vx = 0.3
        ..vy = 0.1;
      s.serveTimer = twoBallServeStaggerTicks;
      s.pickups.add(Pickup(id: 99, type: PickupType.star, x: 0, y: 0));
      for (var i = 0; i < twoBallServeStaggerTicks - 1; i++) {
        Simulation.step(s, noneInputs(s));
        expect(queued.queued, isTrue, reason: 'still waiting at tick $i');
        expect(queued.x, 0);
        expect(queued.y, 0);
      }
      expect(s.pickups, hasLength(1), reason: 'a parked ball collects nothing');
      expect(
        s.players[0].score,
        lessThan(starScore),
        reason: 'only the solo survival points, never the star',
      );
      expect(s.players[0].lives, startLives, reason: 'and it cannot escape');
      // The last tick of the stagger releases it, and now it plays — and now it
      // takes the star it was sitting on.
      Simulation.step(s, noneInputs(s));
      expect(queued.active, isTrue);
      expect(queued.queued, isFalse);
      expect(s.pickups, isEmpty);
    });

    test('a ball parked by the serve pause or by game over is not queued', () {
      // `queued` is what a renderer keys on, so it must not fire for the two
      // other ways a ball can be inactive.
      final s = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 5, ballCount: 2),
      );
      expect(s.phase, Phase.serving);
      expect(s.balls.any((b) => b.queued), isFalse);
      final over = twoBallState();
      over.players[0].lives = 1;
      launchRadial(over, awayFrom(over, 1.2), 0.6, escapeRadius + 0.02);
      over.balls[1].active = false;
      over.balls[1].vx = 0.3; // queued when the game ends
      over.balls[1].vy = 0.1;
      Simulation.step(over, noneInputs(over));
      expect(over.phase, Phase.gameOver);
      expect(over.balls.any((b) => b.queued), isFalse);
      expect(over.serveTimer, 0);
    });

    test('an escape recalls a ball that never launched', () {
      final s = twoBallState();
      // Ball 1 queued; ball 0 already past the escape radius, away from the
      // paddle.
      s.balls[1].active = false;
      s.balls[1].vx = 0.3;
      s.balls[1].vy = 0.1;
      s.serveTimer = 30;
      launchRadial(s, awayFrom(s, 1.2), 0.6, escapeRadius + 0.02);
      Simulation.step(s, noneInputs(s));
      expect(s.phase, Phase.serving);
      expect(s.serveTimer, serveTicks, reason: 'the stagger starts over');
      for (final b in s.balls) {
        expect(b.queued, isFalse);
        expect(b.active, isFalse);
        expect(b.vx, 0);
        expect(b.vy, 0);
      }
    });

    test('a stagger of 0 serves every ball at once, and strands none', () {
      // The guard that keeps a queued ball from waiting forever: with no gap to
      // wait out, the serve is the pre-stagger serve.
      final s = GameState.initial(_NoStagger(GameMode.solo, 5));
      expect(s.balls, hasLength(2));
      for (var i = 0; i < serveTicks; i++) {
        Simulation.step(s, noneInputs(s));
      }
      expect(s.balls.every((b) => b.active), isTrue);
      expect(s.balls.any((b) => b.queued), isFalse);
      expect(s.serveTimer, 0);
    });

    test('the gap is derived, not guessed', () {
      // The gap has to cover what the player does in it, and the binding part is
      // the first ball itself: struck at the contact ring it can return across a
      // chord no shorter than 2 R cos(theta) with cos(theta) >=
      // paddleMinInwardDot.
      final flight = paddleHitRadius / twoBallBaseSpeed; // 2.155 s
      final earliestReturn =
          2 *
          paddleHitRadius *
          paddleMinInwardDot /
          twoBallBaseSpeed; // 1.077 s
      expect(earliestReturn, closeTo(flight / 2, 1e-12));
      expect(twoBallServeStaggerTicks, (earliestReturn * tickRate).ceil());
      expect(twoBallServeStaggerTicks, 65);
      // It also covers reading the rebound, crossing the fan to the second
      // arrival point and settling back between the two.
      final work =
          _reaction + serveFan / paddleSpeed + (serveFan / 2) / paddleSpeed;
      expect(work, lessThan(twoBallServeStaggerTicks * dt));
      // And it is always shorter than a flight, at every speed the serve ramp
      // can reach — so the queued ball is out long before the first ball could
      // reach the paddle, let alone escape.
      expect(
        twoBallServeStaggerTicks * dt,
        lessThan(paddleHitRadius / twoBallMaxServeSpeed),
      );
      expect(
        twoBallServeStaggerTicks * dt,
        lessThan(escapeRadius / twoBallMaxServeSpeed),
      );
    });

    test('a staggered serve is deterministic', () {
      const config = GameConfig(mode: GameMode.duel, seed: 808, ballCount: 2);
      const window = serveTicks + twoBallServeStaggerTicks + 120;
      List<int> run(GameState s, int ticks) {
        final inputs = List<PlayerInput>.filled(2, PlayerInput.none);
        final hashes = <int>[];
        for (var i = 0; i < ticks; i++) {
          for (var p = 0; p < 2; p++) {
            inputs[p] = ScriptedInput.aimAtBall(s, p);
          }
          Simulation.step(s, inputs);
          hashes.add(s.hash());
        }
        return hashes;
      }

      final a = run(GameState.initial(config), window);
      final b = run(GameState.initial(config), window);
      expect(b, a);
      expect(a.toSet().length, window, reason: 'every tick moved the state');

      // Mid-stagger — one ball flying, one queued — the state survives a clone
      // and a JSON round trip, velocity of the queued ball included, and both
      // copies keep playing the same game.
      final mid = GameState.initial(config);
      final inputs = List<PlayerInput>.filled(2, PlayerInput.none);
      for (var i = 0; i < serveTicks + 20; i++) {
        Simulation.step(mid, inputs);
      }
      expect(mid.balls[1].queued, isTrue);
      expect(mid.serveTimer, twoBallServeStaggerTicks - 20);
      final cloned = mid.clone();
      final decoded = GameState.fromJson(
        jsonDecode(jsonEncode(mid.toJson())) as Map<String, dynamic>,
      );
      expect(cloned.hash(), mid.hash());
      expect(decoded.hash(), mid.hash());
      expect(decoded.balls[1].queued, isTrue);
      expect(decoded.serveTimer, mid.serveTimer);
      final tail = run(cloned, 400);
      expect(run(decoded, 400), tail);
      expect(run(mid, 400), tail);
    });
  });

  group('the two-ball pace', () {
    test('is slower than the one-ball pace at both ends', () {
      const one = GameConfig(mode: GameMode.solo, seed: 1);
      const oneDuel = GameConfig(mode: GameMode.duel, seed: 1);
      const two = GameConfig(mode: GameMode.solo, seed: 1, ballCount: 2);
      const twoDuel = GameConfig(mode: GameMode.duel, seed: 1, ballCount: 2);
      expect(two.twoBall, isTrue);
      expect(one.twoBall, isFalse);
      expect(two.serveBaseSpeed, twoBallBaseSpeed);
      expect(two.serveBaseSpeed, lessThan(one.serveBaseSpeed));
      expect(two.serveSpeedCap, lessThan(one.serveSpeedCap));
      expect(two.serveSpeedRamp, lessThan(one.serveSpeedRamp));
      expect(two.maxSpeed, twoBallMaxSpeed);
      expect(twoDuel.maxSpeed, twoBallMaxSpeed);
      expect(two.maxSpeed, lessThan(oneDuel.maxSpeed));
      // The one-ball values are exactly what they were.
      expect(one.serveBaseSpeed, baseSpeed);
      expect(one.serveSpeedRamp, serveRamp);
      expect(one.serveSpeedCap, maxServeSpeed);
      expect(one.maxSpeed, maxSpeedSolo);
      expect(oneDuel.maxSpeed, maxSpeedDuel);
    });

    test('the serve opens harder than one ball but its ceiling is gentler', () {
      const one = GameConfig(mode: GameMode.solo, seed: 1);
      const two = GameConfig(mode: GameMode.solo, seed: 1, ballCount: 2);
      // Two balls asking for something every 1.58 s against one ball's 2.42 s:
      // two balls are meant to be harder.
      expect(_answerInterval(two, two.serveBaseSpeed), closeTo(1.583, 0.005));
      expect(_answerInterval(one, one.serveBaseSpeed), closeTo(2.417, 0.005));
      // But the hardest the two-ball game ever gets is never tighter than the
      // hardest the one-ball game already gets, which the player survives.
      expect(_answerInterval(two, two.maxSpeed), closeTo(0.923, 0.005));
      expect(_answerInterval(one, one.maxSpeed), closeTo(0.831, 0.005));
      expect(
        _answerInterval(two, two.maxSpeed),
        greaterThan(_answerInterval(one, one.maxSpeed)),
      );
    });

    test('the ceiling is a speed every rebound can still be answered at', () {
      // A rebound at theta from the inward radial crosses 2 R cos(theta) and
      // lands (pi - 2 theta) away. Give the player _reaction before the paddle
      // moves: at the two-ball ceiling every theta in range still leaves time.
      final limit = math.acos(paddleMinInwardDot);
      var worst = double.infinity;
      for (var i = 0; i <= 200; i++) {
        final theta = limit * i / 200;
        final transit = 2 * paddleHitRadius * math.cos(theta) / twoBallMaxSpeed;
        final needed = _reaction + (math.pi - 2 * theta) / paddleSpeed;
        expect(needed, lessThan(transit), reason: 'theta = $theta');
        final margin = transit - needed;
        if (margin < worst) worst = margin;
      }
      expect(worst, closeTo(0.258, 0.005), reason: 'the grazing edge hit');
      // The same sum does not close at the one-ball ceiling: a grazing rebound
      // there is unreachable however well the player plays. The one-ball game is
      // not this file's to change — this is the arithmetic the two-ball ceiling
      // was picked to clear.
      final grazing = 1.25;
      expect(
        _reaction + (math.pi - 2 * grazing) / paddleSpeed,
        greaterThan(2 * paddleHitRadius * math.cos(grazing) / maxSpeedSolo),
      );
    });

    test('the serve ramp saturates at the two-ball serve cap', () {
      final s = playingState(ballCount: 2);
      s.phase = Phase.serving;
      s.serveTimer = 1;
      for (final b in s.balls) {
        b.active = false;
      }
      s.tick = 120 * tickRate; // 0.42 + 0.36 > 0.57
      Simulation.step(s, noneInputs(s));
      expect(s.balls[0].speed, twoBallMaxServeSpeed);
      expect(s.balls[1].speed, twoBallMaxServeSpeed);
      expect(twoBallMaxServeSpeed, lessThan(twoBallMaxSpeed));
      // 50 s of play to get there (0.15 / 0.003), against the one-ball 40 s.
      expect(
        (twoBallMaxServeSpeed - twoBallBaseSpeed) / twoBallServeRamp,
        closeTo(50, 0.001),
      );
    });
  });

  group('the speed curve', () {
    // The documented tables. Two balls: each hit closes 9% of the gap left to
    // the ceiling, floor 0.0025 u/s. One ball: × 1.035, unchanged.
    const twoBall = <int, double>{
      1: 0.4470,
      2: 0.4716,
      5: 0.5328,
      8: 0.5789,
      10: 0.6032,
      15: 0.6471,
      20: 0.6745,
      30: 0.7042,
      37: 0.7200,
      40: 0.7200,
      80: 0.7200,
    };
    const oneBall = <int, double>{
      5: 0.6532,
      10: 0.7758,
      20: 1.0944,
      40: 1.6000,
      80: 1.6000,
    };

    test('produces the documented two-ball numbers', () {
      const config = GameConfig(mode: GameMode.solo, seed: 1, ballCount: 2);
      twoBall.forEach((hits, speed) {
        expect(
          _afterHits(config, hits),
          closeTo(speed, 5e-5),
          reason: 'after $hits hits',
        );
      });
      // Same curve in a duel: two balls to track is the same job whoever else
      // is playing.
      const duel = GameConfig(mode: GameMode.duel, seed: 1, ballCount: 2);
      twoBall.forEach((hits, speed) {
        expect(_afterHits(duel, hits), closeTo(speed, 5e-5));
      });
    });

    test('leaves the one-ball numbers exactly where they were', () {
      const config = GameConfig(mode: GameMode.solo, seed: 1);
      oneBall.forEach((hits, speed) {
        expect(
          _afterHits(config, hits),
          closeTo(speed, 5e-5),
          reason: 'after $hits hits',
        );
      });
      // And it is still the flat geometric law, hit by hit.
      var speed = baseSpeed;
      for (var i = 0; i < 20; i++) {
        final next = Simulation.speedAfterHit(config, speed);
        expect(next, closeTo(speed * hitSpeedFactor, 1e-15));
        speed = next;
      }
    });

    test('rises fast, then flattens', () {
      const config = GameConfig(mode: GameMode.solo, seed: 1, ballCount: 2);
      final headroom = twoBallMaxSpeed - twoBallBaseSpeed;
      // Half the headroom is gone after 8 hits, 85% after 20 — the rally
      // quickens while it is young.
      expect(
        _afterHits(config, 8) - twoBallBaseSpeed,
        greaterThan(headroom / 2),
      );
      expect(_afterHits(config, 7) - twoBallBaseSpeed, lessThan(headroom / 2));
      expect(
        _afterHits(config, 20) - twoBallBaseSpeed,
        greaterThan(0.84 * headroom),
      );
      // Every step is smaller than the one before it (until the floor), and the
      // first step is bigger than the old flat law would have given.
      var speed = twoBallBaseSpeed;
      var previous = double.infinity;
      for (var i = 0; i < 25; i++) {
        final next = Simulation.speedAfterHit(config, speed);
        final step = next - speed;
        expect(step, lessThan(previous), reason: 'step $i did not shrink');
        expect(step, greaterThanOrEqualTo(twoBallHitMinGain));
        previous = step;
        speed = next;
      }
      expect(
        Simulation.speedAfterHit(config, twoBallBaseSpeed) - twoBallBaseSpeed,
        greaterThan(twoBallBaseSpeed * (hitSpeedFactor - 1)),
      );
    });

    test('reaches the ceiling after 37 hits and never passes it', () {
      const config = GameConfig(mode: GameMode.solo, seed: 1, ballCount: 2);
      var speed = twoBallBaseSpeed;
      var reached = -1;
      for (var hits = 1; hits <= 500; hits++) {
        speed = Simulation.speedAfterHit(config, speed);
        expect(speed, lessThanOrEqualTo(twoBallMaxSpeed));
        if (reached < 0 && speed >= twoBallMaxSpeed) reached = hits;
      }
      expect(reached, 37);
      expect(
        speed,
        twoBallMaxSpeed,
        reason: 'exactly the ceiling, not near it',
      );
      // A ball somehow above the ceiling is brought back to it.
      expect(
        Simulation.speedAfterHit(config, twoBallMaxSpeed + 0.5),
        twoBallMaxSpeed,
      );
    });

    test(
      'the simulation applies that curve, and the ceiling binds in play',
      () {
        final s = twoBallState();
        parkBall(s, 1);
        s.balls[0].speed = twoBallBaseSpeed;
        var expected = twoBallBaseSpeed;
        for (var hits = 1; hits <= 45; hits++) {
          expected = Simulation.speedAfterHit(s.config, expected);
          expect(
            _bounceOnce(s),
            closeTo(expected, 1e-12),
            reason: 'hit $hits in the simulation',
          );
        }
        expect(s.balls[0].speed, twoBallMaxSpeed);
        // Eight more hits at the ceiling change nothing.
        for (var i = 0; i < 8; i++) {
          expect(_bounceOnce(s), twoBallMaxSpeed);
        }
      },
    );
  });
}

/// A playing two-ball solo state whose paddle cannot reach either ball, with no
/// spawns scheduled.
GameState twoBallState({int seed = 1}) =>
    playingState(seed: seed, ballCount: 2);

/// An angle [away] radians from player 0's paddle — outside it, so a ball there
/// is not saved before the escape check runs.
double awayFrom(GameState s, double away) => s.players[0].paddle.angle + away;

/// A two-ball config with the stagger switched off, to reach the guard in the
/// serve (and, in a probe, to replay the game as it was served before).
class _NoStagger implements GameConfig {
  _NoStagger(this.mode, this.seed);

  @override
  final GameMode mode;

  @override
  final int seed;

  @override
  int get ballCount => 2;

  @override
  int get playerCount => mode == GameMode.duel ? 2 : 1;

  @override
  bool get twoBall => true;

  @override
  double get maxSpeed => twoBallMaxSpeed;

  @override
  double get serveBaseSpeed => twoBallBaseSpeed;

  @override
  double get serveSpeedRamp => twoBallServeRamp;

  @override
  double get serveSpeedCap => twoBallMaxServeSpeed;

  @override
  int get serveStaggerTicks => 0;

  @override
  Map<String, dynamic> toJson() => {'m': mode.index, 's': seed, 'n': 2};
}
