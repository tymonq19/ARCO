/// Earning tokens (SPEC §4.8): the rate, the daily cap and replay
/// deduplication.
///
/// The rule the whole file exists to hold down: **tokens come from the score the
/// server computed**, never from a number the phone sent. Everything else here is
/// about the two ways that could still be farmed — playing the same recorded run
/// over and over, and playing all day — and the bounds that close them.
library;

import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('the rate', () {
    test('converts a verified score at the published rate', () {
      expect(TokenRate.scorePerToken, 100);
      expect(TokenRate.maxTokensPerRun, 50);
      expect(TokenRate.dailyCap, 200);

      expect(TokenRate.forScore(0), 0);
      expect(TokenRate.forScore(-5), 0, reason: 'nothing can pay a negative');
      expect(
        TokenRate.forScore(99),
        0,
        reason:
            'a run under a token is a run that ended before it started; a '
            'floor per submission would make dying on purpose the fastest way '
            'to earn',
      );
      expect(TokenRate.forScore(100), 1);
      expect(TokenRate.forScore(199), 1, reason: 'truncated, not rounded');
      expect(TokenRate.forScore(2218), 22, reason: 'a good 70-second run');
      expect(TokenRate.forScore(TokenRate.scoreAtRunCap), 50);
    });

    test('one run can never pay more than the run cap', () {
      // A player good enough to keep the rally alive runs into
      // ReplayVerifier.maxTicks at around a million points. Flattening the top
      // end is what makes a bot pointless: an hour of perfect play is worth
      // exactly what a strong four-minute run is worth.
      expect(TokenRate.forScore(TokenRate.scoreAtRunCap + 1), 50);
      expect(TokenRate.forScore(1000000), 50);
      expect(TokenRate.forScore(1 << 40), 50);
    });

    test('the daily cap clips a run rather than refusing it', () {
      expect(TokenRate.forScoreWithinDay(5000, alreadyEarnedToday: 0), 50);
      expect(
        TokenRate.forScoreWithinDay(5000, alreadyEarnedToday: 190),
        10,
        reason: 'the run that reaches the cap is paid what is left of it',
      );
      expect(
        TokenRate.forScoreWithinDay(
          5000,
          alreadyEarnedToday: TokenRate.dailyCap,
        ),
        0,
      );
      expect(
        TokenRate.forScoreWithinDay(5000, alreadyEarnedToday: 10000),
        0,
        reason: 'a ledger already over the cap cannot go further over it',
      );
      expect(TokenRate.forScoreWithinDay(50, alreadyEarnedToday: 0), 0);
    });

    test('the day is a UTC day, so no client can choose it', () {
      expect(utcDay(DateTime.utc(2026, 9, 24, 23, 59, 59)), '2026-09-24');
      expect(utcDay(DateTime.utc(2026, 9, 25)), '2026-09-25');
      expect(utcDay(DateTime.utc(2026, 1, 2, 3)), '2026-01-02');
      // A local time is converted, never taken at face value.
      expect(utcDay(DateTime.utc(2026, 9, 25, 1).toLocal()), '2026-09-25');
    });

    test('the whole paid catalogue is worth about a week of the cap', () {
      // The two numbers that make the shop a goal rather than a formality: the
      // first unlock lands on the first evening, and clearing the shelf takes
      // real time.
      final total = Catalogue.items.fold<int>(
        0,
        (sum, item) => sum + item.priceTokens,
      );
      expect(total, 1160);
      expect(total / TokenRate.dailyCap, closeTo(5.8, 0.1));
      final cheapest = [
        for (final item in Catalogue.items)
          if (!item.free) item.priceTokens,
      ].reduce((a, b) => a < b ? a : b);
      expect(cheapest, 80);
      expect(
        cheapest,
        lessThan(TokenRate.dailyCap),
        reason: 'something must be reachable on the first day of play',
      );
    });
  });

  group('the fingerprint', () {
    test('identifies the run and not the way it was encoded', () {
      final replay = recordScoringSoloReplay();
      final key = replayFingerprint(replay);
      expect(key, matches(r'^[0-9a-f]{64}$'));

      // Decoding and re-encoding the same replay is the same run.
      expect(replayFingerprint(Replay.fromJson(replay.toJson())), key);

      // And so is one whose input log has been padded with entries that change
      // nothing: `InputLog.record` folds them away, so a client cannot mint a
      // fresh fingerprint for a run it already submitted by rewriting the JSON.
      final padded = replay.toJson();
      final log = (padded['in'] as List<dynamic>)[0] as List<dynamic>;
      final firstEntry = (log.first as List<dynamic>).cast<int>();
      log.insert(1, <int>[firstEntry[0] + 1, firstEntry[1]]);
      final rebuilt = Replay.fromJson(padded);
      expect(replayFingerprint(rebuilt), key);
    });

    test('a different run has a different fingerprint', () {
      final a = recordScoringSoloReplay(seed: 20260923);
      final b = recordScoringSoloReplay(seed: 424242);
      expect(replayFingerprint(a), isNot(replayFingerprint(b)));
      // Even a single changed input is a different run, because it is one.
      final tweaked = a.toJson();
      final log = (tweaked['in'] as List<dynamic>)[0] as List<dynamic>;
      final entry = (log.first as List<dynamic>).cast<int>();
      log[0] = <int>[entry[0], entry[1] == 0 ? 1 : entry[1] - 1];
      expect(
        replayFingerprint(Replay.fromJson(tweaked)),
        isNot(replayFingerprint(a)),
      );
    });

    test('the ball count is part of the run', () {
      // The same seed and the same inputs played with one ball and with two are
      // two different games with two different scores. If they shared a ledger
      // row the second one submitted would be told it had already been paid.
      final oneBall = recordScoringSoloReplay(seed: 20260923);
      final asTwoBall = Replay(
        config: GameConfig(
          mode: oneBall.config.mode,
          seed: oneBall.config.seed,
          ballCount: 2,
        ),
        inputs: oneBall.inputs,
        finalTick: oneBall.finalTick,
        claimedScore: oneBall.claimedScore,
      );
      expect(
        replayFingerprint(asTwoBall),
        isNot(replayFingerprint(oneBall)),
        reason: 'only the ball count differs, and that is enough',
      );
    });

    test('a one-ball digest is unchanged by boards existing', () {
      // `token_awards` is keyed by this digest, so re-deriving it differently
      // would orphan every row already in that ledger — and every run ever
      // submitted could then be submitted again and paid again. The rule
      // therefore has to reproduce the pre-board canonical string **byte for
      // byte** for a one-ball run, which is what this rebuilds independently.
      String legacyFingerprint(Replay replay) {
        final canonical = StringBuffer()
          ..write('arco-run-v1|')
          ..write(replay.config.mode.index)
          ..write('|')
          ..write(replay.config.seed)
          ..write('|')
          ..write(replay.finalTick);
        for (final log in replay.inputs) {
          canonical.write('|');
          var first = true;
          for (final entry in log.toJson()) {
            if (!first) canonical.write(',');
            first = false;
            canonical
              ..write(entry[0])
              ..write(':')
              ..write(entry[1]);
          }
        }
        return sha256.convert(utf8.encode(canonical.toString())).toString();
      }

      for (final seed in [20260923, 424242, 7]) {
        final replay = recordScoringSoloReplay(seed: seed);
        expect(replay.config.ballCount, 1);
        expect(
          replayFingerprint(replay),
          legacyFingerprint(replay),
          reason:
              'seed $seed must keep the digest its ledger row was written '
              'under',
        );
      }

      // And a two-ball run is deliberately *not* in that namespace — it could
      // not have been played before, so it has no history to preserve.
      final twoBall = recordScoringSoloReplay(seed: 20260923, ballCount: 2);
      expect(
        replayFingerprint(twoBall),
        isNot(legacyFingerprint(twoBall)),
        reason: 'the two-ball namespace starts clean',
      );
    });
  });

  group('POST /api/scores', () {
    late ArcoServer server;
    late Replay scoring;

    setUpAll(() {
      scoring = recordScoringSoloReplay();
      final check = ReplayVerifier.verify(scoring);
      expect(check.ok, isTrue, reason: 'fixture must verify: ${check.reason}');
      expect(
        check.score,
        greaterThan(TokenRate.scorePerToken),
        reason: 'the fixture has to be worth at least one token',
      );
    });

    setUp(() async {
      server = await bootServer();
    });

    Uri api(String path) => Uri.parse('${server.baseUrl}$path');

    Map<String, dynamic> decode(http.Response r) =>
        jsonDecode(r.body) as Map<String, dynamic>;

    Future<http.Response> submit(
      Replay replay, {
      String? auth,
      String name = 'Tester',
      Map<String, dynamic>? body,
    }) => http.post(
      api('/api/scores'),
      headers: {'content-type': 'application/json', 'authorization': ?auth},
      body: jsonEncode(body ?? scoreBody(name, replay)),
    );

    test('a verified run pays the score the server computed', () async {
      final me = await issuePlayer(server, name: 'Tester');
      final r = await submit(scoring, auth: authOf(me));
      expect(r.statusCode, 201, reason: r.body);
      final body = decode(r);

      final score = body['score'] as int;
      expect(score, scoring.claimedScore);
      expect(
        body['tokens'],
        TokenRate.forScore(score),
        reason: 'the rate applied to the verified score, nothing else',
      );
      expect(body['tokenBalance'], body['tokens']);
      expect(
        await server.store.walletBalance(me['id'] as String),
        body['tokens'],
      );
      final inventory = await server.store.inventory(me['id'] as String);
      expect(inventory.earnedToday, body['tokens']);
      expect(inventory.earnedTotal, body['tokens']);
    });

    test('nothing a client sends can change what a run pays', () async {
      final me = await issuePlayer(server, name: 'Tester');
      // A body that claims a score, a token award and a balance of its own. The
      // claim is checked against the re-simulation (SPEC §4) and the other two
      // are read by nobody.
      final r = await submit(
        scoring,
        auth: authOf(me),
        body: {
          'name': 'Tester',
          'replay': scoring.toJson(),
          'tokens': 5000,
          'tokenBalance': 5000,
          'balance': 5000,
          'score': 999999,
        },
      );
      expect(r.statusCode, 201, reason: r.body);
      expect(decode(r)['score'], scoring.claimedScore);
      expect(decode(r)['tokens'], TokenRate.forScore(scoring.claimedScore));
      expect(
        await server.store.walletBalance(me['id'] as String),
        TokenRate.forScore(scoring.claimedScore),
      );
    });

    test('an inflated claim is refused and pays nothing', () async {
      final me = await issuePlayer(server, name: 'Tester');
      final lie = Replay(
        config: scoring.config,
        inputs: scoring.inputs,
        finalTick: scoring.finalTick,
        claimedScore: scoring.claimedScore + 100000,
      );
      final r = await submit(lie, auth: authOf(me));
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'replay_mismatch');
      expect(await server.store.walletBalance(me['id'] as String), 0);
      // Nothing was recorded either, so the honest version of the same run can
      // still be submitted and paid.
      final honest = await submit(scoring, auth: authOf(me));
      expect(honest.statusCode, 201, reason: honest.body);
      expect(decode(honest)['tokens'], greaterThan(0));
    });

    test('an anonymous submission earns nothing and says so', () async {
      final r = await submit(scoring);
      expect(r.statusCode, 201, reason: r.body);
      expect(
        r.body,
        isNot(contains('tokens')),
        reason: 'there is no wallet to pay into, which is the honest answer',
      );
      expect(decode(r).containsKey('tokenBalance'), isFalse);
      expect(decode(r).containsKey('playerId'), isFalse);
    });

    test('a low-scoring run is stored and ranked but pays nothing', () async {
      final me = await issuePlayer(server, name: 'Tester');
      // A seed whose idle run really does score under the earning threshold:
      // an unattended paddle survives a few seconds and takes whatever the
      // walls hand it, so some seeds cross 100 on wall bounces alone.
      final idle = recordSoloReplay(seed: 20260925);
      expect(idle.claimedScore, lessThan(TokenRate.scorePerToken));
      final r = await submit(idle, auth: authOf(me));
      expect(r.statusCode, 201, reason: r.body);
      expect(decode(r)['tokens'], 0);
      expect(decode(r)['rank'], 1, reason: 'the score still counts');
    });

    group('replay deduplication', () {
      test('the same run pays once, however often it is submitted', () async {
        final me = await issuePlayer(server, name: 'Tester');
        final first = await submit(scoring, auth: authOf(me));
        final paid = decode(first)['tokens'] as int;
        expect(paid, greaterThan(0));

        // A retry after a lost response reports the same number rather than a
        // sudden 0, and credits nothing.
        for (var attempt = 0; attempt < 3; attempt++) {
          final again = await submit(scoring, auth: authOf(me));
          expect(again.statusCode, 201, reason: again.body);
          expect(
            decode(again)['tokens'],
            paid,
            reason: 'the run is worth what it was worth, and only once',
          );
          expect(decode(again)['tokenBalance'], paid);
        }
        expect(await server.store.walletBalance(me['id'] as String), paid);
      });

      test('re-encoding the run does not mint a new award', () async {
        final me = await issuePlayer(server, name: 'Tester');
        final paid = decode(await submit(scoring, auth: authOf(me)))['tokens'];
        expect(paid, greaterThan(0));

        // The same run with the JSON rebuilt in another key order and the input
        // log padded with a no-op entry: the fingerprint is over the run as the
        // server parsed it, not over the bytes.
        final padded = scoring.toJson();
        final log = (padded['in'] as List<dynamic>)[0] as List<dynamic>;
        final entry = (log.first as List<dynamic>).cast<int>();
        log.insert(1, <int>[entry[0] + 1, entry[1]]);
        final reordered = <String, dynamic>{
          'replay': {
            'sc': padded['sc'],
            'ft': padded['ft'],
            'in': padded['in'],
            'cfg': padded['cfg'],
            'v': padded['v'],
          },
          'name': 'Tester',
        };
        final again = await http.post(
          api('/api/scores'),
          headers: {
            'content-type': 'application/json',
            'authorization': authOf(me),
          },
          body: jsonEncode(reordered),
        );
        expect(again.statusCode, 201, reason: again.body);
        expect(decode(again)['tokens'], paid);
        expect(await server.store.walletBalance(me['id'] as String), paid);
      });

      test('somebody else submitting your replay earns them nothing', () async {
        final mine = await issuePlayer(server, name: 'Tester');
        final thief = await issuePlayer(server, name: 'Thief');
        final paid = decode(
          await submit(scoring, auth: authOf(mine)),
        )['tokens'];
        expect(paid, greaterThan(0));

        // The ledger is keyed globally, so a replay that leaks is worth nothing
        // to whoever copies it. The score still stores — it verified, and a
        // verified run is a fact about the board.
        final stolen = await submit(
          scoring,
          auth: authOf(thief),
          name: 'Thief',
        );
        expect(stolen.statusCode, 201, reason: stolen.body);
        expect(decode(stolen)['tokens'], 0);
        expect(await server.store.walletBalance(thief['id'] as String), 0);
        expect(await server.store.walletBalance(mine['id'] as String), paid);
      });

      test('a run that paid nothing is still recorded', () async {
        // Otherwise a run submitted against a full daily cap would be worth
        // keeping and re-submitting tomorrow.
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final today = DateTime.now().toUtc();
        for (var run = 0; run < 4; run++) {
          await server.store.awardTokens(
            playerId: id,
            scoreId: 'filler-$run',
            score: TokenRate.scoreAtRunCap,
            replayKey: 'filler-$run',
            now: today,
          );
        }
        expect(await server.store.walletBalance(id), TokenRate.dailyCap);

        final capped = await server.store.awardTokens(
          playerId: id,
          scoreId: 'late-run',
          score: TokenRate.scoreAtRunCap,
          replayKey: 'late-run',
          now: today,
        );
        expect(capped.tokens, 0);
        expect(capped.cappedByDay, isTrue);

        final tomorrow = today.add(const Duration(days: 1));
        final retried = await server.store.awardTokens(
          playerId: id,
          scoreId: 'late-run',
          score: TokenRate.scoreAtRunCap,
          replayKey: 'late-run',
          now: tomorrow,
        );
        expect(retried.duplicate, isTrue);
        expect(
          retried.tokens,
          0,
          reason: 'a recorded run cannot be saved up for a fresh allowance',
        );
        expect(await server.store.walletBalance(id), TokenRate.dailyCap);
      });
    });

    group('a second board does not widen the economy', () {
      late Replay twoBall;

      setUpAll(() {
        twoBall = recordScoringSoloReplay(seed: 20260923, ballCount: 2);
        final check = ReplayVerifier.verify(twoBall);
        expect(
          check.ok,
          isTrue,
          reason: 'fixture must verify: ${check.reason}',
        );
        expect(check.score, greaterThan(TokenRate.scorePerToken));
      });

      test('a two-ball run pays at exactly the published rate', () async {
        // No per-mode rate: a Spark is a Spark, so the shop's prices mean the
        // same thing whichever game paid for them.
        final me = await issuePlayer(server);
        final r = await submit(twoBall, auth: authOf(me), name: 'Duo');
        expect(r.statusCode, 201, reason: r.body);
        expect(decode(r)['balls'], 2);
        expect(decode(r)['tokens'], TokenRate.forScore(twoBall.claimedScore));
        expect(
          decode(r)['tokenBalance'],
          TokenRate.forScore(twoBall.claimedScore),
        );
      });

      test('one wallet and one day\'s allowance cover both boards', () async {
        // The protection that actually matters: boards are a leaderboard
        // concept, not a wallet one. A player who has spent the day on one-ball
        // runs cannot start again on the two-ball board.
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final today = DateTime.now().toUtc();
        for (var run = 0; run < 4; run++) {
          await server.store.awardTokens(
            playerId: id,
            scoreId: 'one-ball-$run',
            score: TokenRate.scoreAtRunCap,
            replayKey: 'one-ball-$run',
            now: today,
          );
        }
        expect(await server.store.walletBalance(id), TokenRate.dailyCap);

        final r = await submit(twoBall, auth: authOf(me), name: 'Duo');
        expect(r.statusCode, 201, reason: r.body);
        expect(
          decode(r)['tokens'],
          0,
          reason: 'the day is spent, whichever board the run was on',
        );
        expect(decode(r)['tokenBalance'], TokenRate.dailyCap);
        expect(await server.store.walletBalance(id), TokenRate.dailyCap);
      });

      test('a two-ball run is still deduplicated', () async {
        final me = await issuePlayer(server);
        final first = await submit(twoBall, auth: authOf(me), name: 'Duo');
        final paid = decode(first)['tokens'] as int;
        expect(paid, greaterThan(0));
        final again = await submit(twoBall, auth: authOf(me), name: 'Duo');
        expect(again.statusCode, 201, reason: again.body);
        expect(
          decode(again)['tokens'],
          paid,
          reason: 'a retry reports the original award and credits nothing',
        );
        expect(await server.store.walletBalance(me['id'] as String), paid);

        // And somebody else's copy of it is worth nothing at all, exactly as on
        // the classic board.
        final thief = await issuePlayer(server);
        final stolen = await submit(
          twoBall,
          auth: authOf(thief),
          name: 'Thief',
        );
        expect(decode(stolen)['tokens'], 0);
        expect(await server.store.walletBalance(thief['id'] as String), 0);
      });

      test(
        'the same seed on both boards pays twice, because it is two runs',
        () async {
          final me = await issuePlayer(server);
          final oneBall = await submit(scoring, auth: authOf(me));
          expect(oneBall.statusCode, 201, reason: oneBall.body);
          final firstPayment = decode(oneBall)['tokens'] as int;
          expect(firstPayment, greaterThan(0));
          expect(decode(oneBall)['balls'], 1);

          final other = await submit(twoBall, auth: authOf(me), name: 'Duo');
          expect(other.statusCode, 201, reason: other.body);
          expect(
            decode(other)['tokens'],
            greaterThan(0),
            reason:
                'a different game with a different score is a different run',
          );
          expect(decode(other)['balls'], 2);
          expect(
            decode(other)['tokenBalance'],
            firstPayment + (decode(other)['tokens'] as int),
          );
        },
      );
    });

    group('the daily cap', () {
      test('bounds what one player can earn in a day', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final today = DateTime.now().toUtc();
        var credited = 0;
        // Ten capped runs: more than any honest player plays and, crucially,
        // exactly as cheap for a bot.
        for (var run = 0; run < 10; run++) {
          final award = await server.store.awardTokens(
            playerId: id,
            scoreId: 'run-$run',
            score: 1000000,
            replayKey: 'run-$run',
            now: today,
          );
          credited += award.tokens;
          expect(award.balance, credited);
          expect(award.earnedToday, credited);
          expect(credited, lessThanOrEqualTo(TokenRate.dailyCap));
        }
        expect(credited, TokenRate.dailyCap);
        expect(await server.store.walletBalance(id), TokenRate.dailyCap);
      });

      test('clips the run that reaches it', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final today = DateTime.now().toUtc();
        for (var run = 0; run < 3; run++) {
          await server.store.awardTokens(
            playerId: id,
            scoreId: 'run-$run',
            score: TokenRate.scoreAtRunCap,
            replayKey: 'run-$run',
            now: today,
          );
        }
        // 150 earned, 50 left, and a run worth 50 is worth 50.
        final onTheEdge = await server.store.awardTokens(
          playerId: id,
          scoreId: 'edge',
          score: 3000,
          replayKey: 'edge',
          now: today,
        );
        expect(onTheEdge.tokens, 30);
        expect(onTheEdge.cappedByDay, isFalse);
        final over = await server.store.awardTokens(
          playerId: id,
          scoreId: 'over',
          score: TokenRate.scoreAtRunCap,
          replayKey: 'over',
          now: today,
        );
        expect(over.tokens, 20, reason: 'paid what was left, not refused');
        expect(over.cappedByDay, isTrue);
        expect(await server.store.walletBalance(id), TokenRate.dailyCap);
      });

      test('a new UTC day is a new allowance', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final day = DateTime.utc(2026, 9, 24, 12);
        for (var run = 0; run < 6; run++) {
          await server.store.awardTokens(
            playerId: id,
            scoreId: 'a-$run',
            score: TokenRate.scoreAtRunCap,
            replayKey: 'a-$run',
            now: day,
          );
        }
        expect(await server.store.walletBalance(id), TokenRate.dailyCap);

        final next = await server.store.awardTokens(
          playerId: id,
          scoreId: 'b-0',
          score: TokenRate.scoreAtRunCap,
          replayKey: 'b-0',
          now: day.add(const Duration(days: 1)),
        );
        expect(next.tokens, TokenRate.maxTokensPerRun);
        expect(next.earnedToday, TokenRate.maxTokensPerRun);
        expect(
          await server.store.walletBalance(id),
          TokenRate.dailyCap + TokenRate.maxTokensPerRun,
        );
      });

      test('one player hitting the cap does not bound another', () async {
        final a = await issuePlayer(server);
        final b = await issuePlayer(server);
        final today = DateTime.now().toUtc();
        for (var run = 0; run < 5; run++) {
          await server.store.awardTokens(
            playerId: a['id'] as String,
            scoreId: 'a-$run',
            score: TokenRate.scoreAtRunCap,
            replayKey: 'a-$run',
            now: today,
          );
        }
        final other = await server.store.awardTokens(
          playerId: b['id'] as String,
          scoreId: 'b-0',
          score: TokenRate.scoreAtRunCap,
          replayKey: 'b-0',
          now: today,
        );
        expect(other.tokens, TokenRate.maxTokensPerRun);
      });

      test('the inventory says how much of the day is left', () async {
        final me = await issuePlayer(server, name: 'Tester');
        final submitted = await submit(scoring, auth: authOf(me));
        final paid = decode(submitted)['tokens'] as int;

        final r = await http.get(
          api('/api/shop/inventory'),
          headers: {'authorization': authOf(me)},
        );
        expect(r.statusCode, 200, reason: r.body);
        expect(decode(r)['earnedToday'], paid);
        expect(decode(r)['dailyCap'], TokenRate.dailyCap);
      });
    });

    test('tokens earned from play can buy an item', () async {
      // The whole loop, end to end: play, earn, buy, wear.
      final me = await issuePlayer(server, name: 'Tester');
      var balance = 0;
      for (final seed in <int>[20260923, 424242, 777001, 31337, 99001]) {
        final r = await submit(
          recordScoringSoloReplay(seed: seed),
          auth: authOf(me),
        );
        expect(r.statusCode, 201, reason: r.body);
        balance = decode(r)['tokenBalance'] as int;
      }
      expect(balance, greaterThanOrEqualTo(80));

      final bought = await http.post(
        api('/api/shop/buy'),
        headers: {
          'content-type': 'application/json',
          'authorization': authOf(me),
        },
        body: jsonEncode({'itemId': 'ball.comet'}),
      );
      expect(bought.statusCode, 200, reason: bought.body);
      expect(decode(bought)['charged'], 80);
      expect(decode(bought)['balance'], balance - 80);

      final equipped = await http.post(
        api('/api/shop/equip'),
        headers: {
          'content-type': 'application/json',
          'authorization': authOf(me),
        },
        body: jsonEncode({'ball': 'ball.comet'}),
      );
      expect(equipped.statusCode, 200, reason: equipped.body);
      expect((decode(equipped)['equipped'] as Map)['ball'], 'ball.comet');
    });
  });
}
