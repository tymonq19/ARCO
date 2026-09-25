/// National leaderboard (SPEC §4.6): an optional country on a submission, a
/// country filter that composes with the period, and the player's national rank.
///
/// The product rule under test: a global top 100 is unreachable, so the number
/// that matters is the national one — and the country it is computed from is a
/// *hint* from the device locale. An unusable hint is dropped, never a reason to
/// refuse a verified run.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late ArcoServer server;
  late Replay replay;

  setUpAll(() {
    replay = recordSoloReplay(seed: 20260923);
    final check = ReplayVerifier.verify(replay);
    expect(check.ok, isTrue, reason: 'fixture must verify: ${check.reason}');
  });

  setUp(() async {
    server = await bootServer();
  });

  Uri api(String path, [Map<String, String>? query]) =>
      Uri.parse('${server.baseUrl}$path').replace(queryParameters: query);

  Map<String, dynamic> decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Future<http.Response> submit({
    String name = 'Tester',
    Object? country,
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

  Future<List<Map<String, dynamic>>> board([Map<String, String>? query]) async {
    final r = await http.get(api('/api/leaderboard', query));
    expect(r.statusCode, 200, reason: r.body);
    return (decode(r)['entries'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// A stored row with an exact score, country and timestamp, so the ranking
  /// maths can be checked without playing a game per case.
  Future<void> seed(
    String id,
    int score, {
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
    ),
  );

  group('POST /api/scores country', () {
    test('a valid code is stored, echoed and ranked nationally', () async {
      final r = await submit(country: 'PL');
      expect(r.statusCode, 201, reason: r.body);
      final body = decode(r);
      expect(body['country'], 'PL');
      expect(
        body['countryRank'],
        1,
        reason: 'the first run in a country leads it',
      );

      expect((await board()).single['country'], 'PL');
      expect((await board({'country': 'PL'})), hasLength(1));
      expect((await board({'country': 'DE'})), isEmpty);
    });

    test('a lowercase or padded code is normalized', () async {
      expect(decode(await submit(country: 'pl'))['country'], 'PL');
      expect(decode(await submit(country: ' de '))['country'], 'DE');
      final codes = [for (final e in await board()) e['country']];
      expect(codes, containsAll(<String>['PL', 'DE']));
    });

    test('no country submits exactly as before', () async {
      final r = await submit();
      expect(r.statusCode, 201, reason: r.body);
      expect(decode(r).containsKey('country'), isFalse, reason: 'no key');
      expect(decode(r).containsKey('countryRank'), isFalse);
      expect(decode(r)['rank'], 1, reason: 'the global board is unchanged');
      expect((await board()).single.containsKey('country'), isFalse);
    });

    test('an unusable code is ignored, not refused', () async {
      // A stale device locale or a client bug must not cost somebody a verified
      // score, so the hint is dropped and the run is stored anyway.
      for (final bad in <Object>['XX', 'pl_PL', 'PLX', 42]) {
        final r = await submit(country: bad, name: 'Ignored');
        expect(r.statusCode, 201, reason: 'rejected $bad: ${r.body}');
        expect(
          decode(r).containsKey('country'),
          isFalse,
          reason: 'an ignored hint must not be echoed back: $bad',
        );
        expect(decode(r).containsKey('countryRank'), isFalse);
      }

      final entries = await board();
      expect(entries, hasLength(4), reason: 'every run was stored');
      expect(
        entries.every((e) => !e.containsKey('country')),
        isTrue,
        reason: 'stored without a country',
      );
      expect(await board({'country': 'PL'}), isEmpty);
    });

    test('every shape of unusable code is dropped at the parse', () {
      // The whole list at the level that decides it, so it costs no rate-limit
      // budget: `checkSubmission` is the pure function the isolate runs.
      Uint8List body(Object? country) => Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'name': 'Tester',
            'replay': replay.toJson(),
            'country': ?country,
          }),
        ),
      );

      for (final bad in <Object>[
        'XX', // not assigned
        'ZZ', // user-assigned range
        'QQ',
        'AN', // withdrawn (Netherlands Antilles)
        'CS',
        'YU',
        'P', // too short
        'PLX', // too long
        'pl_PL', // a whole locale tag, not a region subtag
        'en-GB',
        '12',
        'P1',
        '',
        '  ',
        '\u0000\u0000',
        42,
        true,
        <String>['PL'],
        {'code': 'PL'},
      ]) {
        final checked = checkSubmission(body(bad), verifyReplays: false);
        expect(checked.ok, isTrue, reason: 'refused $bad');
        expect(checked.country, isNull, reason: 'kept $bad');
      }

      // And the ones that must survive, including case and padding.
      for (final good in ['PL', 'pl', ' PL ', 'de', 'GB', 'US', 'AQ', 'tw']) {
        final checked = checkSubmission(body(good), verifyReplays: false);
        expect(checked.country, good.trim().toUpperCase(), reason: good);
      }
    });
  });

  group('GET /api/leaderboard?country', () {
    test('composes with the period', () async {
      final now = DateTime.now().toUtc();
      await seed('pl-today', 100, country: 'PL', at: now);
      await seed(
        'pl-3days',
        900,
        country: 'PL',
        at: now.subtract(const Duration(days: 3)),
      );
      await seed(
        'pl-old',
        999,
        country: 'PL',
        at: now.subtract(const Duration(days: 30)),
      );
      await seed('de-today', 500, country: 'DE', at: now);
      await seed('none-today', 700, at: now);

      Future<List<String>> ids(Map<String, String> query) async => [
        for (final e in await board(query)) e['name'] as String,
      ];

      // The filters are independent and both applied.
      expect(await ids({'country': 'PL', 'period': 'day'}), ['Seeded']);
      expect(
        (await board({'country': 'PL', 'period': 'day'})).single['score'],
        100,
      );
      expect(
        [
          for (final e in await board({'country': 'PL', 'period': 'week'}))
            e['score'],
        ],
        [900, 100],
        reason: 'the 30-day-old PL row is outside the week',
      );
      expect(
        [
          for (final e in await board({'country': 'PL', 'period': 'all'}))
            e['score'],
        ],
        [999, 900, 100],
      );
      expect(
        [
          for (final e in await board({'period': 'day'})) e['score'],
        ],
        [700, 500, 100],
        reason: 'without a country the whole world is in scope',
      );
      expect(
        [
          for (final e in await board({'country': 'DE', 'period': 'all'}))
            e['score'],
        ],
        [500],
      );
    });

    test('the national board is numbered 1..N of its own', () async {
      await seed('de-1', 1000, country: 'DE');
      await seed('de-2', 800, country: 'DE');
      await seed('pl-1', 900, country: 'PL');
      await seed('pl-2', 500, country: 'PL');
      await seed('pl-3', 100, country: 'PL');

      expect(
        [
          for (final e in await board({'country': 'PL'})) e['rank'],
        ],
        [1, 2, 3],
      );
      expect(
        [
          for (final e in await board({'country': 'PL'})) e['score'],
        ],
        [900, 500, 100],
      );
      expect(
        [for (final e in await board()) e['rank']],
        [1, 2, 3, 4, 5],
        reason: 'the global board is unaffected by the existence of the other',
      );
    });

    test('a country nobody has played from is an empty board', () async {
      await seed('pl-1', 900, country: 'PL');
      expect(await board({'country': 'AQ'}), isEmpty);
    });

    test('an empty country parameter is the global board', () async {
      await seed('pl-1', 900, country: 'PL');
      await seed('none', 100);
      expect(await board({'country': ''}), hasLength(2));
    });

    test(
      'an unusable country is refused here, unlike on a submission',
      () async {
        for (final bad in ['XX', 'P', 'PLX', 'pl_PL', '12', 'ZZ']) {
          final r = await http.get(api('/api/leaderboard', {'country': bad}));
          expect(r.statusCode, 400, reason: 'accepted $bad: ${r.body}');
          expect(decode(r)['error'], invalidCountryError);
          expect(decode(r)['ok'], isFalse);
        }
        // Answering with the whole world's board would be a wrong answer to the
        // question asked, not a lenient one.
        final good = await http.get(api('/api/leaderboard', {'country': 'pl'}));
        expect(good.statusCode, 200, reason: good.body);
      },
    );

    test('limit still clamps inside one country', () async {
      for (var i = 0; i < 5; i++) {
        await seed('pl-$i', 100 + i, country: 'PL');
      }
      expect(await board({'country': 'PL', 'limit': '2'}), hasLength(2));
      expect(
        (await board({'country': 'PL', 'limit': '2'})).first['score'],
        104,
      );
    });
  });

  group('GET /api/leaderboard/rank?country', () {
    setUp(() async {
      await seed('de-1', 1000, country: 'DE');
      await seed('de-2', 800, country: 'DE');
      await seed('pl-1', 900, country: 'PL');
      await seed('pl-2', 500, country: 'PL');
      await seed('pl-3', 500, country: 'PL');
      await seed('pl-4', 100, country: 'PL');
      await seed('nowhere', 950);
    });

    Future<int> rankOf(Map<String, String> query) async {
      final r = await http.get(api('/api/leaderboard/rank', query));
      expect(r.statusCode, 200, reason: r.body);
      return decode(r)['rank'] as int;
    }

    test('counts only that country, with ties sharing a rank', () async {
      expect(
        await rankOf({'score': '500'}),
        5,
        reason: '1000, 950, 900 and 800 are better globally',
      );
      expect(
        await rankOf({'score': '500', 'country': 'PL'}),
        2,
        reason: 'only the 900 is better in PL; the tie is not',
      );
      expect(
        await rankOf({'score': '100', 'country': 'PL'}),
        4,
        reason: 'three PL rows are strictly better, so the tie costs a place',
      );
      expect(await rankOf({'score': '2000', 'country': 'PL'}), 1);
      expect(
        await rankOf({'score': '500', 'country': 'AQ'}),
        1,
        reason: 'first in an empty country',
      );
    });

    test('a run with no country counts for no country', () async {
      expect(
        await rankOf({'score': '900', 'country': 'PL'}),
        1,
        reason: 'the unowned 950 is not a PL row',
      );
      expect(await rankOf({'score': '900'}), 3);
    });

    test('composes with the period', () async {
      await seed(
        'pl-ancient',
        5000,
        country: 'PL',
        at: DateTime.now().toUtc().subtract(const Duration(days: 30)),
      );
      expect(await rankOf({'score': '900', 'country': 'PL'}), 2);
      expect(
        await rankOf({'score': '900', 'country': 'PL', 'period': 'week'}),
        1,
        reason: 'the ancient 5000 is outside the week',
      );
    });

    test('an unusable country is refused', () async {
      final r = await http.get(
        api('/api/leaderboard/rank', {'score': '100', 'country': 'XX'}),
      );
      expect(r.statusCode, 400);
      expect(decode(r)['error'], invalidCountryError);
    });
  });

  group('GET /api/players/me national standing', () {
    test(
      'reports the country, the national best and the national rank',
      () async {
        final mine = await issuePlayer(server);
        final id = mine['id'] as String;
        await seed('de-1', 1000, country: 'DE');
        await seed('de-2', 800, country: 'DE');
        await seed('pl-top', 900, country: 'PL');
        await seed('pl-mine', 500, country: 'PL', playerId: id);
        await seed('pl-tie', 500, country: 'PL');
        await seed('pl-low', 100, country: 'PL');

        final r = await http.get(
          api('/api/players/me'),
          headers: {'authorization': authOf(mine)},
        );
        expect(r.statusCode, 200, reason: r.body);
        final me = decode(r);
        expect(me['country'], 'PL');
        expect(me['bestScore'], 500);
        expect(me['countryBestScore'], 500);
        expect(me['rank'], 4, reason: '1000, 900 and 800 are better globally');
        expect(
          me['countryRank'],
          2,
          reason: 'only the 900 is better in PL — this is the winnable number',
        );
      },
    );

    test(
      'a player who never sent a country has no national standing',
      () async {
        final mine = await issuePlayer(server);
        await seed('mine', 500, playerId: mine['id'] as String);
        final me = decode(
          await http.get(
            api('/api/players/me'),
            headers: {'authorization': authOf(mine)},
          ),
        );
        expect(me['rank'], 1);
        expect(me['country'], isNull);
        expect(me['countryBestScore'], isNull);
        expect(me['countryRank'], isNull);
      },
    );

    test('a player who submitted nothing has neither rank', () async {
      final mine = await issuePlayer(server, name: 'Fresh');
      final me = decode(
        await http.get(
          api('/api/players/me'),
          headers: {'authorization': authOf(mine)},
        ),
      );
      expect(me['games'], 0);
      expect(me['rank'], isNull);
      expect(me['country'], isNull);
      expect(me['countryRank'], isNull);
    });

    test('the country follows the newest run that carried one', () async {
      final mine = await issuePlayer(server);
      final id = mine['id'] as String;
      final now = DateTime.now().toUtc();
      // Played in Germany, then moved to Poland and played worse there. The
      // national standing has to be the one the PL board actually shows, not
      // the global best filed under another country.
      await seed(
        'de-mine',
        900,
        country: 'DE',
        playerId: id,
        at: now.subtract(const Duration(days: 2)),
      );
      await seed(
        'pl-mine',
        300,
        country: 'PL',
        playerId: id,
        at: now.subtract(const Duration(days: 1)),
      );
      // A later run with no country at all must not erase where they play.
      await seed('anon-mine', 400, playerId: id, at: now);
      await seed('pl-better', 500, country: 'PL');

      final me = decode(
        await http.get(
          api('/api/players/me'),
          headers: {'authorization': authOf(mine)},
        ),
      );
      expect(me['country'], 'PL');
      expect(me['bestScore'], 900);
      expect(
        me['countryBestScore'],
        300,
        reason: 'the best run that counts for PL, not the best run',
      );
      expect(
        me['countryRank'],
        2,
        reason: 'ranked where the PL board actually puts them',
      );
    });

    test('an authenticated submission carries its country through', () async {
      final mine = await issuePlayer(server);
      final r = await submit(
        country: 'pl',
        name: 'Ada',
        authorization: authOf(mine),
      );
      expect(r.statusCode, 201, reason: r.body);
      expect(decode(r)['playerId'], mine['id']);
      expect(decode(r)['country'], 'PL');

      final me = decode(
        await http.get(
          api('/api/players/me'),
          headers: {'authorization': authOf(mine)},
        ),
      );
      expect(me['country'], 'PL');
      expect(me['countryBestScore'], replay.claimedScore);
      expect(me['countryRank'], 1);
      expect((await board({'country': 'PL'})).single['playerId'], mine['id']);
    });
  });
}
