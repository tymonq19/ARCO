/// The board dimension of the leaderboard (SPEC §4.3, §4.6): every stored score
/// carries the ball count it was played with, and every query names a board.
///
/// The product rule under test: a two-ball game scores at a different rate, so
/// one board holding both would make the one-ball board — the classic one, and
/// the only one that ever existed — read as if it had been overtaken by runs
/// that were not playing the same game. There is therefore no combined board at
/// all, and the board a request gets when it names none is the one-ball board.
library;

import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late ArcoServer server;
  late Replay oneBall;
  late Replay twoBall;

  setUpAll(() {
    oneBall = recordScoringSoloReplay(seed: 20260923);
    twoBall = recordScoringSoloReplay(seed: 20260923, ballCount: 2);
    for (final (label, replay) in [
      ('one-ball', oneBall),
      ('two-ball', twoBall),
    ]) {
      final check = ReplayVerifier.verify(replay);
      expect(
        check.ok,
        isTrue,
        reason: 'the $label fixture must verify: ${check.reason}',
      );
    }
    expect(oneBall.config.ballCount, 1);
    expect(twoBall.config.ballCount, 2);
    expect(
      twoBall.claimedScore,
      greaterThan(TokenRate.scorePerToken),
      reason: 'the two-ball fixture has to be a real run, not a quick death',
    );
  });

  setUp(() async {
    server = await bootServer();
  });

  Uri api(String path, [Map<String, String>? query]) =>
      Uri.parse('${server.baseUrl}$path').replace(queryParameters: query);

  Map<String, dynamic> decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Future<http.Response> submit(
    Replay replay, {
    String name = 'Tester',
    String? country,
    String? authorization,
  }) => http.post(
    api('/api/scores'),
    headers: {
      'content-type': 'application/json',
      'authorization': ?authorization,
    },
    body: jsonEncode({
      'name': name,
      'replay': replay.toJson(),
      'country': ?country,
    }),
  );

  Future<Map<String, dynamic>> board([Map<String, String>? query]) async {
    final r = await http.get(api('/api/leaderboard', query));
    expect(r.statusCode, 200, reason: r.body);
    return decode(r);
  }

  List<String> namesOf(Map<String, dynamic> body) => [
    for (final e in body['entries'] as List<dynamic>)
      (e as Map<String, dynamic>)['name'] as String,
  ];

  /// A stored row with an exact score on an exact board, so the ranking maths
  /// can be checked without playing a game per case.
  Future<void> seed(
    String id,
    int score, {
    int balls = 1,
    String? country,
    String? playerId,
    String name = 'Seeded',
    DateTime? at,
  }) => server.store.insert(
    ScoreRow(
      id: id,
      name: name,
      score: score,
      ticks: score * 6,
      seed: 1,
      createdAt: Db.formatTimestamp(at ?? DateTime.now().toUtc()),
      ipHash: LeaderboardService.hashIp('10.0.0.1'),
      hash: 0,
      playerId: playerId,
      country: country,
      balls: balls,
    ),
  );

  group('POST /api/scores files the run on the board it was played on', () {
    test('a one-ball run lands on board one and says so', () async {
      final r = await submit(oneBall, name: 'Solo');
      expect(r.statusCode, 201, reason: r.body);
      expect(decode(r)['balls'], 1);
      expect(namesOf(await board({'balls': '1'})), ['Solo']);
      expect(namesOf(await board({'balls': '2'})), isEmpty);
    });

    test('a two-ball run lands on board two and says so', () async {
      final r = await submit(twoBall, name: 'Duo');
      expect(r.statusCode, 201, reason: r.body);
      expect(
        decode(r)['balls'],
        2,
        reason: 'taken from the replay the server verified, not from a request',
      );
      expect(namesOf(await board({'balls': '2'})), ['Duo']);
      expect(
        namesOf(await board({'balls': '1'})),
        isEmpty,
        reason: 'a two-ball run must never appear on the classic board',
      );
    });

    test('the ball count cannot be claimed, only played', () async {
      // There is no `balls` field on a submission; a body that invents one is
      // ignored, because the board comes from the verified replay.
      final r = await http.post(
        api('/api/scores'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'name': 'Liar',
          'balls': 2,
          'replay': oneBall.toJson(),
        }),
      );
      expect(r.statusCode, 201, reason: r.body);
      expect(decode(r)['balls'], 1);
      expect(namesOf(await board({'balls': '2'})), isEmpty);
    });

    test('the rank in the reply is the rank on that run\'s board', () async {
      // Better scores on the *other* board must not push this run down.
      await seed('big-1', 999999, balls: 1);
      final r = await submit(twoBall, name: 'Duo');
      expect(r.statusCode, 201, reason: r.body);
      expect(
        decode(r)['rank'],
        1,
        reason:
            'a million-point one-ball run is not ahead of it, it is elsewhere',
      );
    });
  });

  group('GET /api/leaderboard', () {
    setUp(() async {
      await seed('a1', 500, balls: 1, name: 'OneHigh');
      await seed('a2', 100, balls: 1, name: 'OneLow');
      await seed('b1', 300, balls: 2, name: 'TwoHigh');
      await seed('b2', 50, balls: 2, name: 'TwoLow');
    });

    test('naming no board answers the one-ball board', () async {
      final implicit = await board();
      expect(implicit['balls'], 1);
      expect(namesOf(implicit), ['OneHigh', 'OneLow']);
      expect(
        implicit,
        await board({'balls': '1'}),
        reason: 'the default board and board one are the same answer',
      );
    });

    test('an empty parameter is the default board, not an error', () async {
      final r = await http.get(api('/api/leaderboard?balls='));
      expect(r.statusCode, 200, reason: r.body);
      expect(decode(r)['balls'], 1);
      expect(namesOf(decode(r)), ['OneHigh', 'OneLow']);
    });

    test('each board is numbered 1..N of its own', () async {
      final one = await board({'balls': '1'});
      final two = await board({'balls': '2'});
      expect(
        [for (final e in one['entries'] as List<dynamic>) e['rank']],
        [1, 2],
      );
      expect(
        [for (final e in two['entries'] as List<dynamic>) e['rank']],
        [1, 2],
      );
      expect(two['balls'], 2);
      expect(namesOf(two), ['TwoHigh', 'TwoLow']);
    });

    test(
      'a board this server cannot serve is refused, not substituted',
      () async {
        for (final raw in ['0', '3', '-1', 'two', '1.5', '99']) {
          final r = await http.get(api('/api/leaderboard', {'balls': raw}));
          expect(r.statusCode, 400, reason: 'balls=$raw gave ${r.body}');
          expect(decode(r)['error'], invalidBallCountError);
          expect(decode(r)['ok'], isFalse);
        }
      },
    );

    test('the board composes with the period and the country', () async {
      final lastMonth = DateTime.now().toUtc().subtract(
        const Duration(days: 30),
      );
      await seed('old-2', 900, balls: 2, name: 'TwoStale', at: lastMonth);
      await seed('pl-2', 200, balls: 2, name: 'TwoPole', country: 'PL');
      await seed('pl-1', 800, balls: 1, name: 'OnePole', country: 'PL');

      // All three filters at once: this week, in Poland, with two balls.
      final slice = await board({
        'period': 'week',
        'country': 'PL',
        'balls': '2',
      });
      expect(slice['balls'], 2);
      expect(namesOf(slice), ['TwoPole']);

      // Drop one filter at a time and the answer changes in exactly one way.
      expect(
        namesOf(await board({'period': 'all', 'country': 'PL', 'balls': '2'})),
        ['TwoPole'],
      );
      expect(namesOf(await board({'period': 'week', 'balls': '2'})), [
        'TwoHigh',
        'TwoPole',
        'TwoLow',
      ]);
      expect(
        namesOf(await board({'period': 'week', 'country': 'PL', 'balls': '1'})),
        ['OnePole'],
      );
      expect(namesOf(await board({'period': 'all', 'balls': '2'})), [
        'TwoStale',
        'TwoHigh',
        'TwoPole',
        'TwoLow',
      ]);
    });

    test('limit applies within the board', () async {
      await seed('b3', 250, balls: 2, name: 'TwoMid');
      final two = await board({'balls': '2', 'limit': '2'});
      expect(namesOf(two), ['TwoHigh', 'TwoMid']);
    });
  });

  group('GET /api/leaderboard/rank', () {
    setUp(() async {
      await seed('a1', 500, balls: 1);
      await seed('a2', 400, balls: 1);
      await seed('b1', 300, balls: 2);
    });

    test('counts only the named board', () async {
      Future<Map<String, dynamic>> rank(String query) async {
        final r = await http.get(api('/api/leaderboard/rank?$query'));
        expect(r.statusCode, 200, reason: r.body);
        return decode(r);
      }

      expect(await rank('score=450'), {'rank': 2, 'balls': 1});
      expect(await rank('score=450&balls=1'), {'rank': 2, 'balls': 1});
      expect(
        await rank('score=450&balls=2'),
        {'rank': 1, 'balls': 2},
        reason: 'nothing on the two-ball board beats 450',
      );
      expect(await rank('score=250&balls=2'), {'rank': 2, 'balls': 2});
    });

    test('refuses a board it cannot serve', () async {
      final r = await http.get(api('/api/leaderboard/rank?score=1&balls=7'));
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], invalidBallCountError);
    });
  });

  group('the protections do not care which board it is', () {
    test('one submission budget covers both boards', () async {
      // The per-IP budget is keyed by the submitter, not by the board, so a
      // second board is not a second allowance to flood from.
      final limiter = RateLimiter(limit: 2, window: const Duration(minutes: 1));
      final metered = await bootServer(submitLimiter: limiter);
      Future<int> post(Replay replay, String name) async {
        final r = await http.post(
          Uri.parse('${metered.baseUrl}/api/scores'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(scoreBody(name, replay)),
        );
        return r.statusCode;
      }

      expect(await post(oneBall, 'One'), 201);
      expect(await post(twoBall, 'Two'), 201);
      final refused = await http.post(
        Uri.parse('${metered.baseUrl}/api/scores'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(scoreBody('Three', twoBall)),
      );
      expect(
        refused.statusCode,
        429,
        reason: 'the third submission is over the budget on either board',
      );
      expect(refused.headers['retry-after'], '60');
    });

    test('the nickname filter runs on a two-ball submission too', () async {
      final r = await submit(twoBall, name: 'kurwa');
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], offensiveNameError);
      expect(
        await server.store.count(),
        0,
        reason: 'a refused name stores nothing, on any board',
      );
    });

    test('an unusable country is still dropped, not refused', () async {
      final r = await submit(twoBall, name: 'Duo', country: 'pl_PL');
      expect(r.statusCode, 201, reason: r.body);
      expect(decode(r)['balls'], 2);
      expect(decode(r).containsKey('country'), isFalse);
      expect((await server.store.topScores(balls: 2)).single.country, isNull);
    });
  });

  group('GET /api/players/me', () {
    Future<Map<String, dynamic>> me(String auth) async {
      final r = await http.get(
        api('/api/players/me'),
        headers: {'authorization': auth},
      );
      expect(r.statusCode, 200, reason: r.body);
      return decode(r);
    }

    test('reports one entry per board actually played', () async {
      final player = await issuePlayer(server, name: 'Ada');
      final auth = authOf(player);
      expect(
        (await submit(oneBall, name: 'Ada', authorization: auth)).statusCode,
        201,
      );
      expect(
        (await submit(twoBall, name: 'Ada', authorization: auth)).statusCode,
        201,
      );

      final body = await me(auth);
      final boards = (body['boards'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect([for (final b in boards) b['balls']], [1, 2]);
      expect([for (final b in boards) b['games']], [1, 1]);
      expect(boards[0]['bestScore'], oneBall.claimedScore);
      expect(boards[1]['bestScore'], twoBall.claimedScore);
      expect([for (final b in boards) b['rank']], [1, 1]);

      // The top-level numbers are the classic board, which is what they always
      // described; `games` is every run on either board.
      expect(body['bestScore'], oneBall.claimedScore);
      expect(body['rank'], 1);
      expect(body['games'], 2);
    });

    test('a player who only plays two balls has no classic standing', () async {
      final player = await issuePlayer(server, name: 'Duo');
      final auth = authOf(player);
      expect(
        (await submit(twoBall, name: 'Duo', authorization: auth)).statusCode,
        201,
      );

      final body = await me(auth);
      expect(
        body['bestScore'],
        isNull,
        reason: 'a two-ball best must not be reported as a classic best',
      );
      expect(body['rank'], isNull);
      expect(body['games'], 1);
      final boards = (body['boards'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(boards, hasLength(1));
      expect(boards.single['balls'], 2);
      expect(boards.single['bestScore'], twoBall.claimedScore);
    });

    test('a player who has played nothing has no boards at all', () async {
      final player = await issuePlayer(server, name: 'Fresh');
      final body = await me(authOf(player));
      expect(body['boards'], isEmpty);
      expect(body['bestScore'], isNull);
      expect(body['games'], 0);
    });

    test('the national standing is per board, the country is not', () async {
      final player = await issuePlayer(server, name: 'Pole');
      final auth = authOf(player);
      final id = player['id'] as String;
      // Somebody else is ahead in Poland on the classic board only.
      await seed('pl-rival', 999999, balls: 1, country: 'PL', name: 'Rival');
      expect(
        (await submit(
          oneBall,
          name: 'Pole',
          country: 'PL',
          authorization: auth,
        )).statusCode,
        201,
      );
      expect(
        (await submit(
          twoBall,
          name: 'Pole',
          country: 'PL',
          authorization: auth,
        )).statusCode,
        201,
      );

      final body = await me(auth);
      expect(
        body['country'],
        'PL',
        reason: 'a country is a fact about a person',
      );
      final boards = (body['boards'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(boards[0]['countryRank'], 2, reason: 'behind Rival on board one');
      expect(boards[1]['countryRank'], 1, reason: 'alone on board two');
      expect(boards[0]['countryBestScore'], oneBall.claimedScore);
      expect(boards[1]['countryBestScore'], twoBall.claimedScore);
      expect(body['countryRank'], 2, reason: 'the classic board, as ever');
      // And the stored rows agree with what was reported.
      expect((await server.store.playerBoards(id)).length, 2);
    });
  });
}
