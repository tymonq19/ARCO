import 'dart:convert';

import 'package:arco/services/api_client.dart';
import 'package:arco/services/score_submitter.dart';
import 'package:arco/services/storage.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_env.dart';

Replay replay({int score = 1234}) => Replay(
  config: const GameConfig(mode: GameMode.solo, seed: 99),
  inputs: <InputLog>[InputLog()..record(0, const PlayerInput(move: 4))],
  finalTick: 600,
  claimedScore: score,
);

void main() {
  group('lazy issuance', () {
    test('the first submission is what creates the player', () async {
      final env = await createTestEnv();
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );
      expect(env.api.createPlayerCalls, 0);

      final outcome = await submitter.submit('Tester', replay());

      expect(outcome, isA<SubmitAccepted>());
      expect(env.api.createPlayerCalls, 1);
      expect(env.api.submitCredentials.single!.id, testPlayerId(1));
      // ...and the run comes back attached to it.
      expect(env.identity.playerId, testPlayerId(1));
    });

    test('later submissions reuse it', () async {
      final env = await createTestEnv();
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );
      await submitter.submit('Tester', replay());
      await submitter.submit('Tester', replay(score: 99));

      expect(env.api.createPlayerCalls, 1);
      expect(env.api.submitCalls, 2);
      expect(env.api.submitCredentials.map((c) => c!.id).toSet(), {
        testPlayerId(1),
      });
    });

    test('a failed issuance still puts the score on the board', () async {
      final env = await createTestEnv();
      env.api.createPlayerFailure = const ApiException(
        ApiErrorKind.rateLimited,
        'rate_limited',
        statusCode: 429,
        retryAfter: Duration(seconds: 60),
      );
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      final outcome = await submitter.submit('Tester', replay());

      expect(outcome, isA<SubmitAccepted>());
      expect(
        env.api.submitCredentials.single,
        isNull,
        reason: 'the submission goes out anonymously rather than failing',
      );
      expect(env.storage.pendingReplay, isNull);
    });

    test('a device without a keychain submits anonymously', () async {
      final env = await createTestEnv(secrets: FakeSecretStore(failing: true));
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      expect(await submitter.submit('Tester', replay()), isA<SubmitAccepted>());
      expect(env.api.createPlayerCalls, 0);
      expect(env.api.submitCredentials.single, isNull);
    });
  });

  group('stale credentials (401)', () {
    test('trigger exactly one re-issue and a successful resubmit', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      env.api
        ..issued = testCredentials(9)
        ..submitResults.add(
          const SubmitResult.unauthorized(error: invalidCredentialsError),
        );
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      final outcome = await submitter.submit('Tester', replay());

      expect(outcome, isA<SubmitAccepted>(), reason: 'the score is not lost');
      expect(env.api.submitCalls, 2);
      expect(env.api.createPlayerCalls, 1);
      expect(env.api.submitCredentials.first!.id, testPlayerId(7));
      expect(env.api.submitCredentials.last!.id, testPlayerId(9));
      expect(env.identity.playerId, testPlayerId(9));
      expect(env.storage.pendingReplay, isNull);
    });

    test('a second 401 is not retried again, and the score is kept', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      env.api.submitResult = const SubmitResult.unauthorized(
        error: invalidCredentialsError,
      );
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      expect(await submitter.submit('Tester', replay()), isA<SubmitDeferred>());
      expect(env.api.submitCalls, 2, reason: 'one retry, not a loop');
      expect(env.api.createPlayerCalls, 1);
      expect(env.storage.pendingReplay, isNotNull);
    });

    test('a pending replay is re-issued the same way', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      await env.storage.setPendingReplay(
        PendingReplay(name: 'Tester', replay: replay()),
      );
      env.api
        ..issued = testCredentials(9)
        ..submitResults.add(
          const SubmitResult.unauthorized(error: invalidCredentialsError),
        );
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      expect(await submitter.retryPending(), isA<SubmitAccepted>());
      expect(env.api.submitCalls, 2);
      expect(env.storage.pendingReplay, isNull);
    });
  });

  group('country (SPEC 4.6)', () {
    test('is taken from the device locale and remembered', () async {
      final env = await createTestEnv(deviceCountry: 'PL');
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      final outcome =
          await submitter.submit('Tester', replay()) as SubmitAccepted;

      expect(env.api.submitCountries.single, 'PL');
      expect(outcome.country, 'PL');
      expect(outcome.countryRank, 2);
      expect(env.storage.playerCountry, 'PL');
      expect(env.identity.country, 'PL');
    });

    test('an unusable locale sends none', () async {
      final env = await createTestEnv();
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      await submitter.submit('Tester', replay());

      expect(env.api.submitCountries.single, isNull);
      expect(env.storage.playerCountry, isNull);
      expect(env.identity.country, isNull);
    });

    test('a country the server dropped is not remembered', () async {
      final env = await createTestEnv(deviceCountry: 'ZZ');
      // SPEC 4.6: an unusable hint is dropped and the run is stored anyway, so
      // the 201 carries no country at all.
      env.api.submitResult = const SubmitResult.accepted(
        id: 'id-1',
        score: 1234,
        rank: 7,
      );
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      await submitter.submit('Tester', replay());

      expect(env.api.submitCountries.single, 'ZZ');
      expect(env.storage.playerCountry, isNull);
    });
  });

  group('offensive nickname (SPEC 4.7)', () {
    test('keeps the score and asks for another name', () async {
      final env = await createTestEnv();
      env.api.submitResults.add(
        const SubmitResult.rejected(error: offensiveNameError, statusCode: 400),
      );
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      final outcome = await submitter.submit('Rude', replay());

      expect(outcome, isA<SubmitRejected>());
      final rejection = outcome as SubmitRejected;
      expect(rejection.error, offensiveNameError);
      expect(rejection.canRetryUnderNewName, isTrue);
      expect(
        env.storage.pendingReplay,
        isNotNull,
        reason: 'the run was verified; only the name was refused',
      );

      // Renaming is enough to put the same game on the board.
      final resent = await submitter.retryPendingAs('Polite');
      expect(resent, isA<SubmitAccepted>());
      expect(env.storage.pendingReplay, isNull);
      expect(env.storage.isOwnScore(name: 'Polite', score: 1234), isTrue);
    });

    test('a pending replay refused for its name stays pending', () async {
      final env = await createTestEnv();
      await env.storage.setPendingReplay(
        PendingReplay(name: 'Rude', replay: replay()),
      );
      env.api.submitResult = const SubmitResult.rejected(
        error: offensiveNameError,
        statusCode: 400,
      );
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );

      final outcome = await submitter.retryPending();

      expect((outcome as SubmitRejected).canRetryUnderNewName, isTrue);
      expect(env.storage.pendingReplay!.name, 'Rude');
    });
  });

  // The wire format itself: the header SPEC 4.4 specifies, the optional country
  // of 4.6, and the 401 that must not be read as a verdict on the replay.
  group('on the wire', () {
    test(
      'the Authorization header and the country go out as specified',
      () async {
        http.Request? sent;
        final api = ApiClient(
          baseUrl: () => 'http://fake.local',
          client: MockClient((request) async {
            sent = request;
            return http.Response(
              jsonEncode({
                'ok': true,
                'id': 'row-1',
                'score': 1234,
                'rank': 7,
                'playerId': testPlayerId(7),
                'country': 'PL',
                'countryRank': 2,
              }),
              201,
            );
          }),
        );

        final result = await api.submitScore(
          'Tester',
          replay(),
          credentials: testCredentials(7),
          country: 'PL',
        );

        expect(
          sent!.headers['authorization'],
          'Arco ${testPlayerId(7)}:${testPlayerSecret(7)}',
        );
        final body = jsonDecode(sent!.body) as Map<String, dynamic>;
        expect(body['country'], 'PL');
        expect(body['name'], 'Tester');
        expect(result.playerId, testPlayerId(7));
        expect(result.country, 'PL');
        expect(result.countryRank, 2);
      },
    );

    test('no credentials means no Authorization header at all', () async {
      http.Request? sent;
      final api = ApiClient(
        baseUrl: () => 'http://fake.local',
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            '{"ok":true,"id":"row-1","score":1,"rank":1}',
            201,
          );
        }),
      );

      await api.submitScore('Tester', replay());

      expect(sent!.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(sent!.body), isNot(contains('country')));
    });

    test('401 invalid_credentials is not a verdict on the replay', () async {
      final api = ApiClient(
        baseUrl: () => 'http://fake.local',
        client: MockClient(
          (_) async =>
              http.Response('{"ok":false,"error":"invalid_credentials"}', 401),
        ),
      );

      final result = await api.submitScore(
        'Tester',
        replay(),
        credentials: testCredentials(7),
      );

      expect(result.isUnauthorized, isTrue);
      expect(result.ok, isFalse);
      expect(
        result.shouldRetryLater,
        isTrue,
        reason: 'nothing was stored, so the score must survive',
      );
    });

    test('a bare 401 from a proxy stays indeterminate', () async {
      final api = ApiClient(
        baseUrl: () => 'http://fake.local',
        client: MockClient(
          (_) async => http.Response('Proxy Authentication Required', 401),
        ),
      );

      final result = await api.submitScore('Tester', replay());

      expect(result.isUnauthorized, isFalse);
      expect(result.shouldRetryLater, isTrue);
    });

    test(
      'POST /api/players reads the issued credential and honours 429',
      () async {
        var calls = 0;
        final api = ApiClient(
          baseUrl: () => 'http://fake.local',
          client: MockClient((request) async {
            calls++;
            if (calls == 1) {
              return http.Response(
                jsonEncode({
                  'ok': true,
                  'id': testPlayerId(5),
                  'secret': testPlayerSecret(5),
                  'name': null,
                }),
                201,
              );
            }
            return http.Response(
              '{"ok":false,"error":"rate_limited"}',
              429,
              headers: {'retry-after': '42'},
            );
          }),
        );

        final issued = await api.createPlayer();
        expect(issued.id, testPlayerId(5));
        expect(issued.header, 'Arco ${testPlayerId(5)}:${testPlayerSecret(5)}');

        await expectLater(
          api.createPlayer(),
          throwsA(
            isA<ApiException>()
                .having((e) => e.kind, 'kind', ApiErrorKind.rateLimited)
                .having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 42),
                ),
          ),
        );
      },
    );

    test('GET /api/players/me reads the standing and the 401', () async {
      var calls = 0;
      final api = ApiClient(
        baseUrl: () => 'http://fake.local',
        client: MockClient((request) async {
          calls++;
          expect(
            request.headers['authorization'],
            'Arco ${testPlayerId(7)}:${testPlayerSecret(7)}',
          );
          if (calls == 1) {
            return http.Response(
              jsonEncode({
                'ok': true,
                'id': testPlayerId(7),
                'name': 'Tester',
                'bestScore': 900,
                'rank': 12,
                'games': 3,
                'country': 'PL',
                'countryBestScore': 900,
                'countryRank': 2,
                'createdAt': '2026-09-22T12:00:00Z',
              }),
              200,
            );
          }
          return http.Response(
            '{"ok":false,"error":"invalid_credentials"}',
            401,
          );
        }),
      );

      final profile = await api.playerMe(testCredentials(7));
      expect(profile.rank, 12);
      expect(profile.countryRank, 2);
      expect(profile.country, 'PL');
      expect(profile.games, 3);
      expect(profile.hasAccount, isFalse);

      await expectLater(
        api.playerMe(testCredentials(7)),
        throwsA(
          isA<ApiException>().having(
            (e) => e.isUnauthorized,
            'isUnauthorized',
            isTrue,
          ),
        ),
      );
    });

    test(
      'a national board is asked for by country and refuses a bad one',
      () async {
        final requested = <Uri>[];
        final api = ApiClient(
          baseUrl: () => 'http://fake.local',
          client: MockClient((request) async {
            requested.add(request.url);
            if (request.url.queryParameters['country'] == 'ZZ') {
              return http.Response(
                '{"ok":false,"error":"invalid_country","detail":"country must be '
                'an ISO 3166-1 alpha-2 code"}',
                400,
              );
            }
            return http.Response(
              jsonEncode({
                'entries': [
                  {
                    'rank': 1,
                    'name': 'Ada',
                    'score': 9000,
                    'seconds': 300,
                    'createdAt': '2026-09-01T00:00:00Z',
                    'playerId': testPlayerId(7),
                    'country': 'PL',
                  },
                ],
              }),
              200,
            );
          }),
        );

        final entries = await api.leaderboard(
          LeaderboardPeriod.week,
          country: 'PL',
        );
        expect(entries.single.playerId, testPlayerId(7));
        expect(entries.single.country, 'PL');
        expect(requested.single.queryParameters['period'], 'week');
        expect(requested.single.queryParameters['country'], 'PL');

        await expectLater(
          api.leaderboard(LeaderboardPeriod.all, country: 'ZZ'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.errorCode,
              'errorCode',
              'invalid_country',
            ),
          ),
        );
      },
    );
  });
}
