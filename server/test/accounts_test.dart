/// Sign in with Apple and Google, end to end (SPEC §4.5).
///
/// The product flow under test: the player plays anonymously, is offered "keep
/// your scores and play on any device", signs in natively, and the app posts the
/// resulting token here. From then on the runs belong to an account, a second
/// device can restore it, and neither device is signed out by the other.
///
/// Every token is signed by a local fixture key and every key document comes
/// from a loopback [FakeKeyServer], so nothing here reaches Apple or Google.
library;

import 'dart:convert';
import 'dart:io';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'id_token_support.dart';
import 'support.dart';

/// Accounts on, both providers configured — what a full deployment looks like.
const AccountsConfig bothProviders = AccountsConfig(
  enabled: true,
  appleClientIds: {appleAudience},
  googleClientIds: {googleAudience},
);

void main() {
  late FakeKeyServer keyServer;
  late Replay replay;
  var tokenCounter = 0;

  setUpAll(() {
    replay = recordSoloReplay(seed: 20260923);
    final check = ReplayVerifier.verify(replay);
    expect(check.ok, isTrue, reason: 'fixture must verify: ${check.reason}');
  });

  setUp(() async {
    keyServer = await FakeKeyServer.start();
  });

  Future<ArcoServer> boot({
    AccountsConfig accounts = bothProviders,
    RateLimiter? accountLimiter,
    String dbPath = ':memory:',
  }) => bootServer(
    accounts: accounts,
    dbPath: dbPath,
    accountLimiter: accountLimiter,
    appleJwksUri: keyServer.uri,
    googleJwksUri: keyServer.uri,
  );

  /// A distinct, valid Apple token. Distinct because two tokens with identical
  /// claims are the *same* token, and the replay ledger treats a second
  /// presentation of one as a retry — which is the behaviour of its own tests,
  /// not something every other case should trip over.
  String appleToken({String subject = 'apple.000123.abcdef'}) => signIdToken(
    key: providerKey,
    claims: appleClaims(
      subject: subject,
      extra: {'nonce': 'n${tokenCounter++}'},
    ),
  );

  String googleToken({String subject = '107123456789012345678'}) => signIdToken(
    key: providerKey,
    claims: googleClaims(
      subject: subject,
      extra: {'nonce': 'n${tokenCounter++}'},
    ),
  );

  Map<String, dynamic> decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Future<http.Response> link(
    ArcoServer server, {
    required String idToken,
    String provider = appleProviderName,
    String? authorization,
    Object? body,
  }) => http.post(
    Uri.parse('${server.baseUrl}/api/account/link'),
    headers: {
      'content-type': 'application/json',
      'authorization': ?authorization,
    },
    body: jsonEncode(body ?? {'provider': provider, 'idToken': idToken}),
  );

  Future<http.Response> unlink(ArcoServer server, String? authorization) =>
      http.post(
        Uri.parse('${server.baseUrl}/api/account/unlink'),
        headers: {'authorization': ?authorization},
      );

  Future<http.Response> deleteMe(ArcoServer server, String? authorization) =>
      http.delete(
        Uri.parse('${server.baseUrl}/api/players/me'),
        headers: {'authorization': ?authorization},
      );

  Future<http.Response> getMe(ArcoServer server, String? authorization) =>
      http.get(
        Uri.parse('${server.baseUrl}/api/players/me'),
        headers: {'authorization': ?authorization},
      );

  Future<http.Response> submit(
    ArcoServer server, {
    String? authorization,
    String name = 'Tester',
  }) => http.post(
    Uri.parse('${server.baseUrl}/api/scores'),
    headers: {
      'content-type': 'application/json',
      'authorization': ?authorization,
    },
    body: jsonEncode(scoreBody(name, replay)),
  );

  Future<List<Map<String, dynamic>>> leaderboard(ArcoServer server) async {
    final r = await http.get(Uri.parse('${server.baseUrl}/api/leaderboard'));
    expect(r.statusCode, 200, reason: r.body);
    return (decode(r)['entries'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// A stored score row, written straight to storage so a specific score and
  /// owner can be set without playing a game per case.
  Future<void> seedScore(
    ArcoServer server,
    String id,
    int score, {
    String? playerId,
    String name = 'Seeded',
    DateTime? at,
  }) => server.store.insert(
    ScoreRow(
      id: id,
      name: name,
      score: score,
      ticks: score * 60,
      seed: 1,
      createdAt: Db.formatTimestamp(at ?? DateTime.utc(2026, 9, 1)),
      ipHash: 'seeded',
      hash: 0,
      playerId: playerId,
    ),
  );

  group('the feature switch', () {
    test('is off by default, and the account routes say so', () async {
      final server = await boot(accounts: const AccountsConfig());
      final health = await http.get(Uri.parse('${server.baseUrl}/api/health'));
      expect(decode(health)['accounts'], isEmpty);

      final r = await link(server, idToken: appleToken());
      expect(r.statusCode, 404);
      expect(decode(r)['error'], accountsDisabledError);

      final issued = await issuePlayer(server);
      expect((await unlink(server, authOf(issued))).statusCode, 404);
      // Nothing was contacted: the token was never even looked at.
      expect(keyServer.requests, 0);
    });

    test('advertises exactly the providers that are configured', () async {
      final server = await boot(
        accounts: const AccountsConfig(
          enabled: true,
          appleClientIds: {appleAudience},
        ),
      );
      final health = await http.get(Uri.parse('${server.baseUrl}/api/health'));
      expect(decode(health)['accounts'], ['apple']);

      // Google is not configured, so it is not a provider of this server.
      final r = await link(
        server,
        provider: googleProviderName,
        idToken: googleToken(),
      );
      expect(r.statusCode, 400);
      expect(decode(r)['error'], invalidProviderError);
      expect(decode(r)['providers'], ['apple']);
    });

    test('refuses to start enabled with no client id', () {
      expect(
        () => AccountsConfig.fromEnvironment(
          (k) => k == 'ACCOUNTS_ENABLED' ? 'on' : null,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('needs APPLE_CLIENT_IDS'),
          ),
        ),
      );
      // Off with none is the default and perfectly fine.
      expect(AccountsConfig.fromEnvironment((_) => null).enabled, isFalse);
    });

    test('parses the client id lists', () {
      final env = {
        'ACCOUNTS_ENABLED': 'on',
        'APPLE_CLIENT_IDS': ' com.arco.game , com.arco.game.web ,',
        'GOOGLE_CLIENT_IDS': googleAudience,
      };
      final config = AccountsConfig.fromEnvironment((k) => env[k]);
      expect(config.appleClientIds, {'com.arco.game', 'com.arco.game.web'});
      expect(config.googleClientIds, {googleAudience});
      expect(config.providers, ['apple', 'google']);
      expect(config.audiencesFor('apple'), hasLength(2));
      expect(config.audiencesFor('nope'), isEmpty);
      expect(config.hasUnusedClientIds, isFalse);
    });

    test('rejects nonsense configuration instead of starting', () {
      for (final env in [
        {'ACCOUNTS_ENABLED': 'yes'},
        {'ACCOUNTS_ENABLED': 'on', 'APPLE_CLIENT_IDS': 'a b'},
        {'ACCOUNTS_ENABLED': 'on', 'APPLE_CLIENT_IDS': 'a' * 300},
        {
          'ACCOUNTS_ENABLED': 'on',
          'APPLE_CLIENT_IDS': [for (var i = 0; i < 9; i++) 'id$i'].join(','),
        },
      ]) {
        expect(
          () => AccountsConfig.fromEnvironment((k) => env[k]),
          throwsA(isA<FormatException>()),
          reason: '$env',
        );
      }
    });

    test('notices client ids configured with the feature off', () {
      final env = {'APPLE_CLIENT_IDS': appleAudience};
      final config = AccountsConfig.fromEnvironment((k) => env[k]);
      expect(config.enabled, isFalse);
      expect(config.providers, isEmpty);
      expect(
        config.hasUnusedClientIds,
        isTrue,
        reason: 'the server warns about this at startup',
      );
    });
  });

  group('linking an anonymous player', () {
    test(
      'attaches the account and leaves the old credential working',
      () async {
        final server = await boot();
        final issued = await issuePlayer(server, name: 'Ada');
        // Submitted under 'Ada', because the display name follows the name the
        // player last actually played under (SPEC §4.4).
        final before = await submit(
          server,
          authorization: authOf(issued),
          name: 'Ada',
        );
        expect(before.statusCode, 201, reason: before.body);

        final r = await link(
          server,
          idToken: appleToken(),
          authorization: authOf(issued),
        );
        expect(r.statusCode, 200, reason: r.body);
        final body = decode(r);
        expect(body['ok'], isTrue);
        expect(body['outcome'], 'linked');
        expect(body['id'], issued['id'], reason: 'the same player, now owned');
        expect(body['provider'], 'apple');
        expect(body['name'], 'Ada');
        expect(body['movedScores'], 0);
        expect(body['games'], 1);
        expect(body['bestScore'], replay.claimedScore);
        expect(body['rank'], 1);
        expect(body['boards'], [
          {
            'balls': 1,
            'games': 1,
            'bestScore': replay.claimedScore,
            'rank': 1,
            'countryBestScore': null,
            'countryRank': null,
          },
        ]);
        expect(
          body['linkedAt'],
          matches(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'),
        );

        // A new credential, and the one the device already had still works: the
        // player is not signed out of their own phone by signing in on it.
        final fresh = body['secret'] as String;
        expect(fresh, isNot(issued['secret']));
        expect(fresh, matches(r'^[A-Za-z0-9_-]{43}$'));
        expect((await getMe(server, authOf(body))).statusCode, 200);
        expect((await getMe(server, authOf(issued))).statusCode, 200);
        expect(await server.store.secretCount(issued['id'] as String), 2);

        // /me now reports the account, so the client can offer sign-out.
        final me = decode(await getMe(server, authOf(body)));
        expect(me['provider'], 'apple');
        expect(me['linkedAt'], body['linkedAt']);
      },
    );

    test('with no credentials creates the account it signs in to', () async {
      final server = await boot();
      final r = await link(server, idToken: appleToken(subject: 'brand.new'));
      expect(r.statusCode, 200, reason: r.body);
      final body = decode(r);
      expect(body['outcome'], 'created');
      expect(body['id'], matches(r'^[0-9a-f]{32}$'));
      expect(body['name'], isNull);
      expect(body['games'], 0);
      expect(body['bestScore'], isNull);
      expect(body['rank'], isNull);
      expect(await server.store.playerCount(), 1);

      // The credential works, and the account is found again next time.
      expect((await getMe(server, authOf(body))).statusCode, 200);
      final owner = await server.store.playerByAccount('apple', 'brand.new');
      expect(owner!.id, body['id']);
    });

    test(
      'stores the provider and subject and nothing else about the person',
      () async {
        final dir = Directory.systemTemp.createTempSync('arco_accounts');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/arco.db';
        final server = await boot(dbPath: path);

        // The token carries an email, a private-relay flag and a real name.
        final claims = appleClaims(subject: 'privacy.1');
        expect(claims['email'], contains('privaterelay'));
        expect(claims['name'], 'Ada Lovelace');
        final r = await link(
          server,
          idToken: signIdToken(key: providerKey, claims: claims),
        );
        expect(r.statusCode, 200, reason: r.body);
        await server.stop();

        final raw = sqlite3.open(path);
        addTearDown(raw.close);
        // There is nowhere to put an address: the column the identity layer had
        // reserved for one was dropped in schema v2 (SPEC §4.5).
        final columns = [
          for (final c in raw.select('PRAGMA table_info(players)'))
            c['name'] as String,
        ];
        expect(columns, isNot(contains('account_email')));
        expect(
          columns,
          containsAll(<String>[
            'account_provider',
            'account_subject',
            'account_linked_at',
          ]),
        );

        final row = raw.select('SELECT * FROM players').single;
        expect(row['account_provider'], 'apple');
        expect(row['account_subject'], 'privacy.1');
        expect(row['account_linked_at'], isNotNull);
        expect(
          row['name'],
          isNull,
          reason: 'the token name is not a display name',
        );
        // Nothing anywhere in the row resembles the address or the real name.
        final dumped = row.values.map((v) => '$v').join('\u0000');
        expect(dumped, isNot(contains('privaterelay')));
        expect(dumped, isNot(contains('Lovelace')));
        expect(dumped, isNot(contains('@')));
        // And the raw token is not kept either — only its digest.
        final ledger = raw.select('SELECT * FROM id_token_uses').single;
        expect(ledger['token_hash'], matches(r'^[0-9a-f]{64}$'));
        expect('${ledger['subject']}', 'privacy.1');
        expect(
          raw
              .select(
                "SELECT COUNT(*) AS c FROM id_token_uses WHERE token_hash LIKE 'eyJ%'",
              )
              .single['c'],
          0,
        );
      },
    );
  });

  group('a token that fails any check links nothing', () {
    late ArcoServer server;
    setUp(() async => server = await boot());

    Future<void> expectRefused(
      String token, {
      required int status,
      String? reason,
      String? authorization,
    }) async {
      final playersBefore = await server.store.playerCount();
      final r = await link(
        server,
        idToken: token,
        authorization: authorization,
      );
      expect(r.statusCode, status, reason: r.body);
      if (reason != null) {
        expect(decode(r)['error'], invalidTokenError);
        expect(decode(r)['reason'], reason);
      }
      expect(decode(r)['ok'], isFalse);
      expect(decode(r).containsKey('secret'), isFalse);
      expect(
        await server.store.playerCount(),
        playersBefore,
        reason: 'a refused token must not create a player',
      );
      expect(await server.store.tokenUseCount(), 0);
    }

    test('a signature from the wrong key', () async {
      await expectRefused(
        signIdToken(
          key: strangerKey,
          kid: providerKey.kid,
          claims: appleClaims(),
        ),
        status: 401,
        reason: 'bad_signature',
      );
    });

    test('alg none and the HS256 confusion attack', () async {
      for (final alg in ['none', 'HS256']) {
        await expectRefused(
          signIdToken(key: providerKey, claims: appleClaims(), alg: alg),
          status: 401,
          reason: 'unsupported_algorithm',
        );
      }
    });

    test('a token for another app', () async {
      await expectRefused(
        signIdToken(
          key: providerKey,
          claims: appleClaims(audience: 'com.somebody.else'),
        ),
        status: 401,
        reason: 'wrong_audience',
      );
    });

    test('a token from another issuer', () async {
      await expectRefused(
        signIdToken(
          key: providerKey,
          claims: appleClaims(issuer: 'https://evil.example'),
        ),
        status: 401,
        reason: 'wrong_issuer',
      );
    });

    test('an expired token', () async {
      await expectRefused(
        signIdToken(
          key: providerKey,
          claims: appleClaims(
            now: DateTime.utc(2020),
            life: const Duration(minutes: 10),
          ),
        ),
        status: 401,
        reason: 'expired_token',
      );
    });

    test('a Google token presented as an Apple one', () async {
      await expectRefused(
        signIdToken(key: providerKey, claims: googleClaims()),
        status: 401,
        reason: 'wrong_issuer',
      );
    });

    test('wrong player credentials, even with a perfect token', () async {
      final issued = await issuePlayer(server);
      final r = await link(
        server,
        idToken: appleToken(),
        authorization: playerAuth(issued['id'] as String, 'A' * 43),
      );
      expect(r.statusCode, 401);
      expect(decode(r)['error'], invalidCredentialsError);
      expect(await server.store.tokenUseCount(), 0);
      final me = decode(await getMe(server, authOf(issued)));
      expect(
        me.containsKey('provider'),
        isFalse,
        reason: 'nothing may be linked when the caller is not authenticated',
      );
    });

    test('an unreachable key server is a 503, not a rejected token', () async {
      keyServer.status = HttpStatus.internalServerError;
      final r = await link(server, idToken: appleToken());
      expect(r.statusCode, 503);
      expect(decode(r)['error'], IdTokenException.keysUnavailableCode);
      expect(await server.store.playerCount(), 0);
    });

    test('a malformed body', () async {
      final bad = await http.post(
        Uri.parse('${server.baseUrl}/api/account/link'),
        headers: {'content-type': 'application/json'},
        body: '{not json',
      );
      expect(bad.statusCode, 400);
      expect(decode(bad)['error'], 'invalid_json');

      for (final body in <Map<String, dynamic>>[
        {},
        {'provider': 'apple'},
        {'provider': 'apple', 'idToken': ''},
        {'provider': 'apple', 'idToken': 42},
      ]) {
        final r = await link(server, idToken: '', body: body);
        expect(r.statusCode, 400, reason: '$body');
      }
      for (final body in <Map<String, dynamic>>[
        {'idToken': 'x'},
        {'provider': 'facebook', 'idToken': 'x'},
        {'provider': 7, 'idToken': 'x'},
      ]) {
        final r = await link(server, idToken: '', body: body);
        expect(r.statusCode, 400, reason: '$body');
        expect(decode(r)['error'], invalidProviderError, reason: '$body');
      }
    });

    test('a body over the cap', () async {
      final r = await http.post(
        Uri.parse('${server.baseUrl}/api/account/link'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'provider': 'apple',
          'idToken': 'x' * (maxAccountBodyBytes + 100),
        }),
      );
      expect(r.statusCode, 413);
      expect(decode(r)['limit'], maxAccountBodyBytes);
    });
  });

  group('merging two players', () {
    test('keeps one player, every run, and the better best score', () async {
      final server = await boot();

      // The account already exists on another phone, with one run.
      final first = decode(
        await link(server, idToken: appleToken(subject: 'merge.me')),
      );
      final accountId = first['id'] as String;
      await seedScore(server, 'old-run', 300, playerId: accountId, name: 'Ada');

      // This phone has been playing anonymously, with two runs, one better.
      final local = await issuePlayer(server, name: 'Ada');
      final localId = local['id'] as String;
      await seedScore(server, 'local-low', 100, playerId: localId, name: 'Ada');
      await seedScore(
        server,
        'local-high',
        900,
        playerId: localId,
        name: 'Adagio',
        at: DateTime.utc(2026, 9, 5),
      );
      expect(await server.store.playerCount(), 2);

      final r = await link(
        server,
        idToken: appleToken(subject: 'merge.me'),
        authorization: authOf(local),
      );
      expect(r.statusCode, 200, reason: r.body);
      final body = decode(r);
      expect(body['outcome'], 'merged');
      expect(
        body['id'],
        accountId,
        reason: 'the account survives; the local anonymous player is absorbed',
      );
      expect(body['movedScores'], 2);
      expect(body['games'], 3, reason: 'every run came across');
      expect(
        body['bestScore'],
        900,
        reason: 'nothing is chosen between the bests because no row is dropped',
      );
      expect(body['rank'], 1);

      // One player left, holding all three runs.
      expect(await server.store.playerCount(), 1);
      expect(await server.store.playerById(localId), isNull);
      final stats = await server.store.playerScores(accountId);
      expect(stats.games, 3);
      expect(stats.bestScore, 900);
      // The display name follows the newest run, as SPEC §4.4 already said.
      expect(body['name'], 'Adagio');

      // The leaderboard shows three owned rows, all the survivor's.
      final entries = await leaderboard(server);
      expect(entries, hasLength(3));
      expect(entries.map((e) => e['playerId']).toSet(), {accountId});

      // Both the returned credential and the absorbed player's old one work,
      // and both now mean the merged account.
      for (final auth in [authOf(body), authOf(local), authOf(first)]) {
        final me = decode(await getMe(server, auth));
        expect(me['id'], accountId);
        expect(me['games'], 3);
      }
    });

    test('is safe to retry with the very same token', () async {
      final server = await boot();
      final accountId =
          decode(
                await link(server, idToken: appleToken(subject: 'retry.me')),
              )['id']
              as String;
      await seedScore(server, 'acct-run', 500, playerId: accountId);

      final local = await issuePlayer(server);
      final localId = local['id'] as String;
      await seedScore(server, 'local-run', 200, playerId: localId);

      // One token, presented twice — the phone lost the first response.
      final token = appleToken(subject: 'retry.me');
      final first = decode(
        await link(server, idToken: token, authorization: authOf(local)),
      );
      expect(first['outcome'], 'merged');
      expect(first['movedScores'], 1);

      final second = await link(
        server,
        idToken: token,
        authorization: authOf(local),
      );
      expect(second.statusCode, 200, reason: second.body);
      final body = decode(second);
      expect(body['outcome'], 'retried');
      expect(body['id'], accountId, reason: 'the recorded outcome, replayed');
      expect(body['games'], 2, reason: 'nothing was merged twice');
      expect(await server.store.playerCount(), 1);
      // The retry rotates the credential the first call issued rather than
      // stacking another one on top.
      expect((await getMe(server, authOf(body))).statusCode, 200);
      expect((await getMe(server, authOf(first))).statusCode, 401);

      // A third presentation is the same answer again.
      final third = decode(await link(server, idToken: token));
      expect(third['outcome'], 'retried');
      expect(third['id'], accountId);
      expect(await server.store.playerCount(), 1);
    });

    test('a replayed token cannot drag a stranger into the account', () async {
      final server = await boot();
      final victim = await issuePlayer(server, name: 'Victim');
      await seedScore(
        server,
        'victim-run',
        700,
        playerId: victim['id'] as String,
      );

      // The victim signs in; the token is captured in transit.
      final token = appleToken(subject: 'victim.sub');
      final linked = decode(
        await link(server, idToken: token, authorization: authOf(victim)),
      );
      expect(linked['outcome'], 'linked');

      // The attacker replays it with their own anonymous player's credentials,
      // hoping to have their runs adopted by — and to gain a credential for —
      // the victim's account.
      final attacker = await issuePlayer(server, name: 'Attacker');
      await seedScore(
        server,
        'attacker-run',
        1,
        playerId: attacker['id'] as String,
      );
      final replayed = decode(
        await link(server, idToken: token, authorization: authOf(attacker)),
      );

      // The ledger pins the outcome to the first call, so the attacker's player
      // is neither merged in nor deleted: the answer is about the victim's
      // account and nothing about the attacker's changed.
      expect(replayed['outcome'], 'retried');
      expect(replayed['id'], victim['id']);
      expect(
        replayed['games'],
        1,
        reason: "the attacker's run was not adopted",
      );
      final attackerMe = decode(await getMe(server, authOf(attacker)));
      expect(attackerMe['id'], attacker['id']);
      expect(attackerMe['games'], 1);
      expect(await server.store.playerCount(), 2);
    });

    test(
      'refuses rather than detaching an account the caller already has',
      () async {
        final server = await boot();
        final apple = decode(
          await link(server, idToken: appleToken(subject: 'has.apple')),
        );

        // The same player now presents a Google token. Silently moving the link
        // would strand the Apple account, so this is a conflict the client has
        // to resolve.
        final r = await link(
          server,
          provider: googleProviderName,
          idToken: googleToken(subject: 'other.google'),
          authorization: authOf(apple),
        );
        expect(r.statusCode, 409, reason: r.body);
        expect(decode(r)['error'], AccountLinkResult.alreadyLinkedError);
        expect(
          decode(r)['provider'],
          'apple',
          reason: 'the client can say which sign-in to use',
        );

        // A second Apple account is refused the same way.
        final other = await link(
          server,
          idToken: appleToken(subject: 'second.apple'),
          authorization: authOf(apple),
        );
        expect(other.statusCode, 409);

        // And the original link is untouched.
        final me = decode(await getMe(server, authOf(apple)));
        expect(me['provider'], 'apple');
        expect(await server.store.playerCount(), 1);
      },
    );

    test('signing in again on the same account just restores it', () async {
      final server = await boot();
      final first = decode(
        await link(server, idToken: appleToken(subject: 'same.one')),
      );
      final again = decode(
        await link(
          server,
          idToken: appleToken(subject: 'same.one'),
          authorization: authOf(first),
        ),
      );
      expect(again['outcome'], 'restored');
      expect(again['id'], first['id']);
      expect(again['movedScores'], 0);
      expect(await server.store.playerCount(), 1);
    });
  });

  group('a second device', () {
    test('restores the account without signing the first one out', () async {
      final server = await boot();

      // Phone one: anonymous player, one run, then signs in.
      final phoneOne = await issuePlayer(server, name: 'Ada');
      expect(
        (await submit(
          server,
          authorization: authOf(phoneOne),
          name: 'Ada',
        )).statusCode,
        201,
      );
      final linked = decode(
        await link(
          server,
          idToken: appleToken(subject: 'two.devices'),
          authorization: authOf(phoneOne),
        ),
      );
      final accountId = linked['id'] as String;

      // Phone two: a fresh install with no credentials at all.
      final phoneTwo = decode(
        await link(server, idToken: appleToken(subject: 'two.devices')),
      );
      expect(phoneTwo['outcome'], 'restored');
      expect(phoneTwo['id'], accountId, reason: 'the same account');
      expect(phoneTwo['games'], 1, reason: 'the run from phone one is there');
      expect(phoneTwo['bestScore'], replay.claimedScore);
      expect(
        phoneTwo['secret'],
        isNot(linked['secret']),
        reason: "phone one's secret is never disclosed to phone two",
      );
      expect(await server.store.playerCount(), 1);

      // Both phones still authenticate, so both can keep playing as the same
      // person — the point of the whole feature.
      for (final auth in [authOf(linked), authOf(phoneTwo), authOf(phoneOne)]) {
        expect((await getMe(server, auth)).statusCode, 200, reason: auth);
      }

      // And a run submitted from either phone lands on the one account.
      expect(
        (await submit(
          server,
          authorization: authOf(phoneTwo),
          name: 'Ada',
        )).statusCode,
        201,
      );
      expect(
        (await submit(
          server,
          authorization: authOf(phoneOne),
          name: 'Ada',
        )).statusCode,
        201,
      );
      final me = decode(await getMe(server, authOf(phoneTwo)));
      expect(me['games'], 3);
      final entries = await leaderboard(server);
      expect(entries, hasLength(3));
      expect(entries.every((e) => e['playerId'] == accountId), isTrue);
    });

    test('credentials are capped, evicting the least recently added', () async {
      // More sign-ins than the per-IP budget allows, so it is widened here;
      // the budget itself is measured in its own group.
      final server = await boot(
        accountLimiter: RateLimiter(
          limit: 100,
          window: const Duration(minutes: 1),
        ),
      );
      final creds = <Map<String, dynamic>>[];
      for (var i = 0; i <= Db.maxPlayerSecrets; i++) {
        final r = await link(
          server,
          idToken: appleToken(subject: 'many.devices'),
        );
        expect(r.statusCode, 200, reason: r.body);
        creds.add(decode(r));
      }
      final id = creds.first['id'] as String;
      expect(creds.every((c) => c['id'] == id), isTrue);
      expect(await server.store.secretCount(id), Db.maxPlayerSecrets);

      // The oldest credential is gone; the newest ones still work.
      expect((await getMe(server, authOf(creds.first))).statusCode, 401);
      expect((await getMe(server, authOf(creds.last))).statusCode, 200);
    });
  });

  group('unlinking', () {
    test('detaches the account and keeps the player and its runs', () async {
      final server = await boot();
      final issued = await issuePlayer(server, name: 'Ada');
      await submit(server, authorization: authOf(issued), name: 'Ada');
      final linked = decode(
        await link(
          server,
          idToken: appleToken(subject: 'to.unlink'),
          authorization: authOf(issued),
        ),
      );

      final r = await unlink(server, authOf(linked));
      expect(r.statusCode, 200, reason: r.body);
      expect(decode(r)['unlinked'], isTrue);
      expect(decode(r)['provider'], 'apple');

      // Still the same player, still its runs, just anonymous again.
      final me = decode(await getMe(server, authOf(linked)));
      expect(me['id'], linked['id']);
      expect(me['games'], 1);
      expect(me.containsKey('provider'), isFalse);
      expect(await server.store.playerByAccount('apple', 'to.unlink'), isNull);
      // Every device keeps its credential.
      expect((await getMe(server, authOf(issued))).statusCode, 200);
    });

    test('is idempotent, and signing in again relinks', () async {
      final server = await boot();
      final linked = decode(
        await link(server, idToken: appleToken(subject: 'again.and.again')),
      );
      expect(decode(await unlink(server, authOf(linked)))['unlinked'], isTrue);
      final second = await unlink(server, authOf(linked));
      expect(second.statusCode, 200);
      expect(decode(second)['unlinked'], isFalse);

      final relinked = decode(
        await link(
          server,
          idToken: appleToken(subject: 'again.and.again'),
          authorization: authOf(linked),
        ),
      );
      expect(relinked['outcome'], 'linked');
      expect(relinked['id'], linked['id']);
    });

    test('needs credentials', () async {
      final server = await boot();
      expect((await unlink(server, null)).statusCode, 401);
      expect(
        decode(await unlink(server, null))['error'],
        missingCredentialsError,
      );
      expect((await unlink(server, 'Arco nonsense')).statusCode, 401);
    });
  });

  group('deleting the account', () {
    test('removes the person and leaves the verified runs anonymous', () async {
      final server = await boot();
      final issued = await issuePlayer(server, name: 'Ada');
      await submit(server, authorization: authOf(issued), name: 'Ada');
      await seedScore(server, 'other-player', 5000, name: 'Somebody');
      final linked = decode(
        await link(
          server,
          idToken: appleToken(subject: 'to.delete'),
          authorization: authOf(issued),
        ),
      );
      final boardBefore = await leaderboard(server);

      final r = await deleteMe(server, authOf(linked));
      expect(r.statusCode, 200, reason: r.body);
      expect(decode(r)['deleted'], isTrue);
      expect(decode(r)['scoresAnonymised'], 1);

      // The player, its account and every credential are gone.
      expect(await server.store.playerCount(), 0);
      expect(await server.store.playerById(linked['id'] as String), isNull);
      expect(await server.store.playerByAccount('apple', 'to.delete'), isNull);
      expect(await server.store.tokenUseCount(), 0);
      for (final auth in [authOf(linked), authOf(issued)]) {
        expect((await getMe(server, auth)).statusCode, 401, reason: auth);
      }

      // The runs stay on the board, unowned: deleting them would restate
      // everyone else's rank.
      final boardAfter = await leaderboard(server);
      expect(boardAfter, hasLength(boardBefore.length));
      expect(boardAfter.every((e) => !e.containsKey('playerId')), isTrue);
      expect(
        boardAfter.map((e) => e['score']),
        boardBefore.map((e) => e['score']),
      );

      // And signing in with the same provider again is a clean slate.
      final after = decode(
        await link(server, idToken: appleToken(subject: 'to.delete')),
      );
      expect(after['outcome'], 'created');
      expect(after['games'], 0);
      expect(after['id'], isNot(linked['id']));
    });

    test(
      'works for an anonymous player, even with accounts switched off',
      () async {
        final server = await boot(accounts: const AccountsConfig());
        final issued = await issuePlayer(server);
        await submit(server, authorization: authOf(issued));
        final r = await deleteMe(server, authOf(issued));
        expect(
          r.statusCode,
          200,
          reason: 'Apple requires deletion; it is never switchable off',
        );
        expect(decode(r)['scoresAnonymised'], 1);
        expect(await server.store.playerCount(), 0);
      },
    );

    test('needs credentials', () async {
      final server = await boot();
      expect(
        decode(await deleteMe(server, null))['error'],
        missingCredentialsError,
      );
      final issued = await issuePlayer(server);
      final wrong = await deleteMe(
        server,
        playerAuth(issued['id'] as String, 'B' * 43),
      );
      expect(wrong.statusCode, 401);
      expect(decode(wrong)['error'], invalidCredentialsError);
      expect(await server.store.playerCount(), 1);
    });
  });

  group('the account endpoints are metered', () {
    test('over the per-IP budget they answer 429 before any crypto', () async {
      final server = await boot(
        accountLimiter: RateLimiter(
          limit: 2,
          window: const Duration(minutes: 1),
        ),
      );
      expect((await link(server, idToken: appleToken())).statusCode, 200);
      expect((await link(server, idToken: appleToken())).statusCode, 200);
      final refused = await link(server, idToken: appleToken());
      expect(refused.statusCode, 429);
      expect(decode(refused)['error'], 'rate_limited');
      expect(refused.headers['retry-after'], '60');

      // The budget is shared by every account call, delete included.
      expect((await deleteMe(server, null)).statusCode, 429);
    });
  });

  group('the replay ledger', () {
    test('drops rows once the tokens they describe have expired', () {
      // Driven straight against storage, with an explicit clock: through HTTP a
      // token cannot be both linkable and expired, because the verifier allows a
      // minute of clock skew either way.
      final db = Db.open(':memory:');
      addTearDown(db.close);

      AccountLinkResult use(String token, DateTime expiresAt, DateTime now) =>
          db.linkAccount(
            AccountLinkRequest(
              provider: appleProviderName,
              subject: 'sub-$token',
              callerPlayerId: null,
              tokenHash: token,
              tokenExpiresAt: expiresAt,
              newPlayerId: token.padRight(32, '0'),
              credentialId: 'cred-$token'.padRight(32, '0'),
              secretHash: hashPlayerSecret('secret-$token'),
              now: now,
            ),
          );

      final noon = DateTime.utc(2026, 9, 23, 12);
      final expiresAt = noon.add(const Duration(minutes: 10));
      expect(use('a', expiresAt, noon).ok, isTrue);
      expect(db.tokenUseCount, 1);

      // Just past its own exp, token a is still inside the verifier's clock
      // skew, so it can still be presented — and its row must therefore still
      // be there. Pruning on `expires_at < now` would have dropped it here.
      final justAfterExpiry = expiresAt.add(const Duration(seconds: 30));
      expect(use('b', expiresAt, justAfterExpiry).ok, isTrue);
      expect(
        db.tokenUseCount,
        2,
        reason: 'a token inside the skew window keeps its ledger row',
      );
      expect(
        use('a', expiresAt, justAfterExpiry).kind,
        AccountLinkKind.retried,
        reason: 'so a replay in that window is still pinned to its outcome',
      );

      // Well past exp plus the retention margin, the row is dropped: the token
      // is refused from then on, so it can never be needed again.
      final longAfter = expiresAt.add(
        Db.tokenUseRetention + const Duration(minutes: 1),
      );
      expect(
        use('c', longAfter.add(const Duration(minutes: 10)), longAfter).ok,
        isTrue,
      );
      expect(
        db.tokenUseCount,
        1,
        reason: "a's and b's rows were pruned when c was recorded",
      );
      expect(db.playerCount, 3, reason: 'a, b and c');
    });

    test('retention outlives the window in which a token is still accepted', () {
      expect(
        Db.tokenUseRetention,
        greaterThan(idTokenClockSkew),
        reason:
            'a token is accepted until exp + skew, so its row must survive at '
            'least that long or a replay stops being pinned',
      );
    });
  });

  group('a merged-away player id', () {
    test(
      'keeps resolving to the survivor, so a stored credential survives',
      () async {
        final server = await boot();
        final account = decode(
          await link(server, idToken: appleToken(subject: 'alias.me')),
        );
        final local = await issuePlayer(server, name: 'Local');
        final localId = local['id'] as String;

        final merged = decode(
          await link(
            server,
            idToken: appleToken(subject: 'alias.me'),
            authorization: authOf(local),
          ),
        );
        expect(merged['outcome'], 'merged');
        expect(merged['id'], account['id']);

        // The absorbed player row is gone, but its id now names the survivor.
        expect(await server.store.playerById(localId), isNull);
        expect(await server.store.canonicalPlayerId(localId), account['id']);

        // So the calling device, which stored `<localId>:<secret>`, goes on
        // working — and is told the canonical id to store instead.
        final me = await getMe(server, authOf(local));
        expect(me.statusCode, 200, reason: me.body);
        expect(
          decode(me)['id'],
          account['id'],
          reason: 'the client should replace its stored id with this',
        );

        // A run submitted with the old credential lands on the surviving account.
        final submitted = await submit(
          server,
          authorization: authOf(local),
          name: 'Local',
        );
        expect(submitted.statusCode, 201, reason: submitted.body);
        expect(decode(submitted)['playerId'], account['id']);

        // Deleting the account clears the alias with it.
        expect((await deleteMe(server, authOf(merged))).statusCode, 200);
        expect(await server.store.canonicalPlayerId(localId), localId);
        expect((await getMe(server, authOf(local))).statusCode, 401);
      },
    );
  });
}
