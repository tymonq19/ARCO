/// Anonymous player identity (SPEC §4.4): issuing a player, authenticating
/// with it, owning a submitted score and reporting what it owns.
///
/// The product rule under test throughout: identity is optional plumbing. Every
/// path that worked before a player existed still works without one, and a
/// credential that is present but wrong fails closed rather than degrading to
/// anonymous.
library;

import 'dart:convert';

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

  Uri api(String path) => Uri.parse('${server.baseUrl}$path');

  Map<String, dynamic> decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Future<http.Response> postPlayer({Object? body, String? authorization}) =>
      http.post(
        api('/api/players'),
        headers: {
          'content-type': 'application/json',
          'authorization': ?authorization,
        },
        body: body == null ? null : (body is String ? body : jsonEncode(body)),
      );

  Future<http.Response> getMe(String? authorization) => http.get(
    api('/api/players/me'),
    headers: {'authorization': ?authorization},
  );

  Future<http.Response> submit(
    Replay r, {
    String? authorization,
    String name = 'Tester',
  }) => http.post(
    api('/api/scores'),
    headers: {
      'content-type': 'application/json',
      'authorization': ?authorization,
    },
    body: jsonEncode(scoreBody(name, r)),
  );

  Future<List<Map<String, dynamic>>> leaderboard() async {
    final r = await http.get(api('/api/leaderboard'));
    expect(r.statusCode, 200, reason: r.body);
    return (decode(r)['entries'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// A stored score row, written straight to the database so a specific score
  /// and owner can be set without playing a game per case.
  Future<void> seedScore(
    String id,
    int score, {
    String? playerId,
    String name = 'Seeded',
  }) => server.store.insert(
    ScoreRow(
      id: id,
      name: name,
      score: score,
      ticks: score * 6,
      seed: 1,
      createdAt: Db.formatTimestamp(DateTime.now().toUtc()),
      ipHash: LeaderboardService.hashIp('10.0.0.1'),
      hash: 0,
      playerId: playerId,
    ),
  );

  group('POST /api/players', () {
    test('issues an id and a secret, and stores the secret hashed', () async {
      final r = await postPlayer();
      expect(r.statusCode, 201, reason: r.body);
      final body = decode(r);
      expect(body['ok'], isTrue);
      expect(body['name'], isNull, reason: 'no display name was asked for');

      final id = body['id'] as String;
      final secret = body['secret'] as String;
      expect(id, matches(r'^[0-9a-f]{32}$'));
      // 256 bits, base64url without padding: no ':' (the header separator) and
      // nothing that needs escaping in a header.
      expect(secret, matches(r'^[A-Za-z0-9_-]{43}$'));

      final stored = await server.store.playerWithSecrets(id);
      expect(stored, isNotNull);
      // One credential at issue time; signing in to an account adds more
      // without revoking this one (SPEC §4.5).
      expect(stored!.secretHashes, hasLength(1));
      final hash = stored.secretHashes.single;
      expect(
        hash,
        isNot(contains(secret)),
        reason: 'the secret itself must never be stored',
      );
      expect(hash, startsWith('$playerSecretHashVersion\$'));
      expect(verifyPlayerSecret(secret, hash), isTrue);
      expect(verifyPlayerSecret('$secret-x', hash), isFalse);
      expect(stored.player.name, isNull);
      expect(
        stored.player.createdAt,
        matches(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'),
      );
      // Nothing is linked yet: a freshly issued player is anonymous.
      expect(stored.player.accountProvider, isNull);
      expect(stored.player.accountSubject, isNull);
      expect(stored.player.accountLinkedAt, isNull);
      expect(stored.player.hasAccount, isFalse);
    });

    test('two players never share an id or a secret', () async {
      final a = await issuePlayer(server);
      final b = await issuePlayer(server);
      expect(a['id'], isNot(b['id']));
      expect(a['secret'], isNot(b['secret']));
      expect(await server.store.playerCount(), 2);
    });

    test('an optional display name is validated and kept', () async {
      final named = await issuePlayer(server, name: '  Ada   Lovelace ');
      expect(named['name'], 'Ada Lovelace', reason: 'normalized like §4.2');

      final bad = await postPlayer(body: {'name': 'x'});
      expect(bad.statusCode, 400, reason: bad.body);
      expect(decode(bad)['error'], 'invalid_name');

      final notAString = await postPlayer(body: {'name': 42});
      expect(notAString.statusCode, 400);
      expect(decode(notAString)['error'], 'invalid_name');

      final malformed = await postPlayer(body: '{not json');
      expect(malformed.statusCode, 400);
      expect(decode(malformed)['error'], 'invalid_json');

      final notAnObject = await postPlayer(body: '[1,2]');
      expect(notAnObject.statusCode, 400);
      expect(decode(notAnObject)['error'], 'invalid_json');
    });

    test('an oversized body is rejected with 413', () async {
      final r = await postPlayer(
        body: '{"name":"${'a' * (maxPlayerBodyBytes + 64)}"}',
      );
      expect(r.statusCode, 413);
      expect(decode(r)['error'], 'payload_too_large');
      expect(decode(r)['limit'], maxPlayerBodyBytes);
    });

    test('the eleventh issue within a minute is rate limited', () async {
      for (var i = 0; i < playerIssuesPerMinute; i++) {
        expect((await postPlayer()).statusCode, 201, reason: 'issue $i');
      }
      final limited = await postPlayer();
      expect(limited.statusCode, 429);
      expect(decode(limited)['error'], 'rate_limited');
      expect(limited.headers['retry-after'], '60');
      expect(
        await server.store.playerCount(),
        playerIssuesPerMinute,
        reason: 'a refused issue must not create a row',
      );
    });

    test('expired player-limiter keys are swept', () async {
      var now = 0;
      final limiter = RateLimiter(
        limit: playerIssuesPerMinute,
        window: const Duration(minutes: 1),
        clock: () => now,
      );
      final swept = await bootServer(
        playerLimiter: limiter,
        apiSweepInterval: const Duration(milliseconds: 10),
      );
      final r = await http.post(Uri.parse('${swept.baseUrl}/api/players'));
      expect(r.statusCode, 201, reason: r.body);
      expect(limiter.keyCount, 1);
      now += const Duration(minutes: 1).inMilliseconds + 1;
      await pumpUntil(
        () => limiter.keyCount == 0,
        reason: 'the player limiter is never swept',
      );
    });
  });

  group('authentication', () {
    test('GET /api/players/me needs credentials', () async {
      final none = await getMe(null);
      expect(none.statusCode, 401, reason: none.body);
      expect(decode(none)['error'], missingCredentialsError);

      final blank = await getMe('   ');
      expect(blank.statusCode, 401);
      expect(decode(blank)['error'], missingCredentialsError);
    });

    test('a wrong secret is refused', () async {
      final issued = await issuePlayer(server);
      final id = issued['id'] as String;
      final secret = issued['secret'] as String;

      // Same length, one flipped character: nothing about the answer may
      // distinguish it from an unknown player.
      final flipped = secret.replaceRange(
        0,
        1,
        secret.startsWith('A') ? 'B' : 'A',
      );
      final wrong = await getMe(playerAuth(id, flipped));
      expect(wrong.statusCode, 401, reason: wrong.body);
      expect(decode(wrong)['error'], invalidCredentialsError);

      final unknown = await getMe(playerAuth('0' * 32, secret));
      expect(unknown.statusCode, 401);
      expect(decode(unknown)['error'], invalidCredentialsError);
      expect(
        decode(unknown),
        decode(wrong),
        reason: 'an unknown id and a wrong secret answer identically',
      );

      // The real credentials still work, so nothing was invalidated.
      expect((await getMe(authOf(issued))).statusCode, 200);
    });

    test('malformed credentials are refused, not ignored', () async {
      final issued = await issuePlayer(server);
      final id = issued['id'] as String;
      final secret = issued['secret'] as String;

      for (final header in <String>[
        secret, // no scheme
        'Bearer $id:$secret', // wrong scheme
        'Arco $id', // no separator
        'Arco :$secret', // no id
        'Arco $id:', // no secret
        'Arco ${id.toUpperCase()}:$secret', // ids are lowercase hex
        'Arco ${id}x:$secret', // id too long
        'Arco $id:short', // secret below the minimum length
        'Arco $id:$secret${'a' * 200}', // secret past the maximum length
        'Arco $id:se cret', // space is not in the secret alphabet
      ]) {
        final r = await getMe(header);
        expect(r.statusCode, 401, reason: 'header "$header" -> ${r.body}');
        expect(
          decode(r)['error'],
          invalidCredentialsError,
          reason: 'header "$header"',
        );
      }
    });

    test('the scheme is case-insensitive, as HTTP requires', () async {
      final issued = await issuePlayer(server);
      final r = await getMe('arco ${issued['id']}:${issued['secret']}');
      expect(r.statusCode, 200, reason: r.body);
    });

    test('CORS lets a browser send the Authorization header', () async {
      final request = http.Request('OPTIONS', api('/api/players/me'))
        ..headers['origin'] = 'https://example.com'
        ..headers['access-control-request-method'] = 'GET'
        ..headers['access-control-request-headers'] = 'authorization';
      final response = await request.send();
      expect(response.statusCode, 204);
      expect(
        response.headers['access-control-allow-headers']?.toLowerCase(),
        contains('authorization'),
      );
    });
  });

  group('score ownership', () {
    test(
      'an authenticated submission is attached and shown as owned',
      () async {
        final issued = await issuePlayer(server);
        final id = issued['id'] as String;

        final r = await submit(
          replay,
          authorization: authOf(issued),
          name: 'Ada',
        );
        expect(r.statusCode, 201, reason: r.body);
        expect(decode(r)['playerId'], id);

        final entries = await leaderboard();
        expect(entries, hasLength(1));
        expect(
          entries.single['playerId'],
          id,
          reason: 'the client highlights its own entries with this',
        );
        expect(entries.single['name'], 'Ada');

        final me = await getMe(authOf(issued));
        expect(me.statusCode, 200, reason: me.body);
        expect(decode(me), {
          'ok': true,
          'id': id,
          'name': 'Ada',
          'bestScore': replay.claimedScore,
          'rank': 1,
          'games': 1,
          // The run carried no country, so there is no national standing
          // (SPEC §4.6) — null rather than absent, like bestScore and rank.
          'country': null,
          'countryBestScore': null,
          'countryRank': null,
          // One board, because one game was played on one board (SPEC §4.6).
          'boards': [
            {
              'balls': 1,
              'games': 1,
              'bestScore': replay.claimedScore,
              'rank': 1,
              'countryBestScore': null,
              'countryRank': null,
            },
          ],
          'createdAt': decode(me)['createdAt'],
        });
        expect(
          decode(me)['createdAt'],
          matches(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'),
        );
      },
    );

    test('an anonymous submission still works and owns nothing', () async {
      final r = await submit(replay, name: 'Nobody');
      expect(r.statusCode, 201, reason: r.body);
      expect(
        decode(r).containsKey('playerId'),
        isFalse,
        reason: 'no owner, no key',
      );

      final entries = await leaderboard();
      expect(entries.single['name'], 'Nobody');
      expect(entries.single.containsKey('playerId'), isFalse);
    });

    test('a wrong secret fails the submission closed', () async {
      final issued = await issuePlayer(server);
      final r = await submit(
        replay,
        authorization: playerAuth(issued['id'] as String, 'a' * 43),
      );
      expect(r.statusCode, 401, reason: r.body);
      expect(decode(r)['error'], invalidCredentialsError);
      expect(
        await leaderboard(),
        isEmpty,
        reason: 'a bad credential must not degrade to an anonymous store',
      );
      expect(await server.store.count(), 0);
    });

    test('a rejected replay attaches nothing to the player', () async {
      final issued = await issuePlayer(server);
      final tampered = Replay(
        config: replay.config,
        inputs: replay.inputs,
        finalTick: replay.finalTick,
        claimedScore: replay.claimedScore + 1000,
      );
      final r = await submit(tampered, authorization: authOf(issued));
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'replay_mismatch');

      final me = decode(await getMe(authOf(issued)));
      expect(me['games'], 0);
      expect(me['bestScore'], isNull);
      expect(me['rank'], isNull);
    });

    test('rows with no player keep working and keep being listed', () async {
      // The shape of every row the database already holds: a name, a score and
      // no owner. It must stay on the leaderboard next to owned rows.
      await seedScore('legacy-1', 900, name: 'Legacy');
      final issued = await issuePlayer(server);
      await seedScore(
        'owned-1',
        400,
        playerId: issued['id'] as String,
        name: 'Owner',
      );

      final entries = await leaderboard();
      expect([for (final e in entries) e['name']], ['Legacy', 'Owner']);
      expect(entries[0].containsKey('playerId'), isFalse);
      expect(entries[1]['playerId'], issued['id']);

      // The legacy row still counts for everyone's rank.
      final me = decode(await getMe(authOf(issued)));
      expect(me['rank'], 2);
      expect(me['games'], 1);
    });
  });

  group('GET /api/players/me', () {
    test('a player who has submitted nothing has no rank', () async {
      final issued = await issuePlayer(server, name: 'Fresh');
      final me = decode(await getMe(authOf(issued)));
      expect(me['name'], 'Fresh');
      expect(me['games'], 0);
      expect(me['bestScore'], isNull);
      expect(me['rank'], isNull);
    });

    test('best score and games count only that player runs', () async {
      final mine = await issuePlayer(server);
      final other = await issuePlayer(server);
      await seedScore('a', 100, playerId: mine['id'] as String);
      await seedScore('b', 700, playerId: mine['id'] as String);
      await seedScore('c', 300, playerId: mine['id'] as String);
      await seedScore('d', 900, playerId: other['id'] as String);
      await seedScore('e', 50);

      final me = decode(await getMe(authOf(mine)));
      expect(me['games'], 3);
      expect(me['bestScore'], 700);
      expect(me['rank'], 2, reason: 'only the 900 is better');
    });

    test('tied bests share a rank and push the next one down', () async {
      final first = await issuePlayer(server);
      final second = await issuePlayer(server);
      final third = await issuePlayer(server);
      await seedScore('t1', 500, playerId: first['id'] as String);
      await seedScore('t2', 500, playerId: second['id'] as String);
      await seedScore('t3', 300, playerId: third['id'] as String);

      expect(decode(await getMe(authOf(first)))['rank'], 1);
      expect(
        decode(await getMe(authOf(second)))['rank'],
        1,
        reason: 'an equal score is not a better score',
      );
      expect(
        decode(await getMe(authOf(third)))['rank'],
        3,
        reason: 'two rows are strictly better, so the tie costs a place',
      );

      // A player whose own second-best ties the leader is still rank 1.
      await seedScore('t4', 500, playerId: first['id'] as String);
      expect(decode(await getMe(authOf(first)))['rank'], 1);
      expect(decode(await getMe(authOf(first)))['games'], 2);
    });
  });

  group('secrets', () {
    test('every secret is fresh, long and header-safe', () {
      final secrets = {for (var i = 0; i < 64; i++) newPlayerSecret()};
      expect(secrets, hasLength(64), reason: 'no repeats from Random.secure');
      for (final secret in secrets) {
        expect(secret, matches(r'^[A-Za-z0-9_-]{43}$'));
        expect(secret, isNot(contains(':')));
      }
    });

    test('the digest is salted, so equal secrets hash differently', () {
      final a = hashPlayerSecret('same-secret');
      final b = hashPlayerSecret('same-secret');
      expect(a, isNot(b));
      expect(verifyPlayerSecret('same-secret', a), isTrue);
      expect(verifyPlayerSecret('same-secret', b), isTrue);
      expect(verifyPlayerSecret('other', a), isFalse);
    });

    test('an unreadable stored digest verifies nothing', () {
      for (final stored in <String>[
        '',
        'plain-secret',
        'v1\$deadbeef',
        'v2\$aa\$bb',
        'v1\$zz\$aa',
        'v1\$aa\$zz',
        'v1\$aa\$',
      ]) {
        expect(
          verifyPlayerSecret('secret', stored),
          isFalse,
          reason: 'stored "$stored"',
        );
      }
    });

    test('constantTimeEquals compares content, not prefixes', () {
      expect(constantTimeEquals(<int>[], <int>[]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
      expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
    });

    test('credentials round-trip through the header form', () {
      final issued = IssuedPlayer(
        id: 'a' * 32,
        secret: newPlayerSecret(),
        name: 'Ada',
      );
      final parsed = PlayerCredentials.parse(issued.authorizationHeader);
      expect(parsed, isNotNull);
      expect(parsed!.id, issued.id);
      expect(parsed.secret, issued.secret);
      expect(issued.authorizationHeader, startsWith('$playerAuthScheme '));
      expect(PlayerCredentials.parse(null), isNull);
    });
  });

  group('last_seen_at', () {
    test(
      'is written once per resolution window, not once per request',
      () async {
        final store = server.store;
        final issued = await issuePlayer(server);
        final id = issued['id'] as String;
        final created = (await store.playerById(id))!.lastSeenAt;

        // A read right after issuing is inside the window: no write.
        expect(await store.touchPlayer(id, DateTime.now().toUtc()), isFalse);
        expect((await store.playerById(id))!.lastSeenAt, created);

        final later = DateTime.now().toUtc().add(Db.lastSeenResolution * 2);
        expect(await store.touchPlayer(id, later), isTrue);
        expect(
          (await store.playerById(id))!.lastSeenAt,
          Db.formatTimestamp(later),
        );
      },
    );
  });
}
