import 'dart:convert';

import 'package:arco/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_env.dart';

/// `POST /api/account/link` and `DELETE /api/players/me` at the wire (SPEC §4.5):
/// what goes out, and what each documented answer becomes.
void main() {
  ApiClient clientFor(
    Future<http.Response> Function(http.Request request) handler,
  ) => ApiClient(
    baseUrl: () => 'http://fake.local',
    client: MockClient(handler),
  );

  const linkBody = {
    'ok': true,
    'id': '463f45aa00000000000000000000beef',
    'secret': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'name': 'Ada',
    'provider': 'apple',
    'outcome': 'merged',
    'linkedAt': '2026-09-21T10:00:00Z',
    'createdAt': '2026-09-01T08:00:00Z',
    'movedScores': 12,
    'bestScore': 4321,
    'rank': 7,
    'games': 9,
    'country': 'PL',
    'countryBestScore': 4321,
    'countryRank': 2,
  };

  test('a link posts the provider and the token, and parses the whole '
      'answer', () async {
    late http.Request sent;
    final api = clientFor((request) async {
      sent = request;
      return http.Response(jsonEncode(linkBody), 200);
    });

    final link = await api.linkAccount(
      provider: 'apple',
      idToken: 'header.payload.signature',
      credentials: testCredentials(1),
    );

    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/account/link');
    expect(sent.headers['authorization'], testCredentials(1).header);
    expect(jsonDecode(sent.body), {
      'provider': 'apple',
      'idToken': 'header.payload.signature',
    });
    expect(link.credentials.id, '463f45aa00000000000000000000beef');
    expect(link.credentials.secret.length, 43);
    expect(link.provider, 'apple');
    expect(link.outcome, AccountLinkOutcome.merged);
    expect(link.movedScores, 12);
    expect(link.name, 'Ada');
    expect(link.bestScore, 4321);
    expect(link.rank, 7);
    expect(link.games, 9);
    expect(link.country, 'PL');
    expect(link.countryRank, 2);
    expect(link.linkedAt, DateTime.utc(2026, 9, 21, 10));
    expect(link.createdAt, DateTime.utc(2026, 9, 1, 8));
  });

  test('the answer carries the standing a merge just changed', () async {
    final api = clientFor(
      (_) async => http.Response(jsonEncode(linkBody), 200),
    );
    final profile = (await api.linkAccount(
      provider: 'apple',
      idToken: 'jwt',
    )).toProfile();

    expect(profile.id, '463f45aa00000000000000000000beef');
    expect(profile.hasAccount, isTrue);
    expect(profile.provider, 'apple');
    expect(profile.rank, 7);
    expect(profile.countryRank, 2);
    expect(profile.games, 9);
  });

  test('a link without credentials sends no Authorization header', () async {
    late http.Request sent;
    final api = clientFor((request) async {
      sent = request;
      return http.Response(jsonEncode(linkBody), 200);
    });

    await api.linkAccount(provider: 'google', idToken: 'jwt');

    expect(sent.headers.containsKey('authorization'), isFalse);
  });

  test('an unknown outcome string is still a success', () {
    final link = AccountLink.fromJson({
      ...linkBody,
      'outcome': 'transubstantiated',
    });
    expect(link, isNotNull);
    expect(link!.outcome, AccountLinkOutcome.unknown);
  });

  test('a 200 without a usable credential is a bad response', () async {
    final api = clientFor(
      (_) async => http.Response(
        jsonEncode({'ok': true, 'provider': 'apple', 'outcome': 'created'}),
        200,
      ),
    );
    await expectLater(
      api.linkAccount(provider: 'apple', idToken: 'jwt'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.kind,
          'kind',
          ApiErrorKind.badResponse,
        ),
      ),
    );
  });

  // SPEC §4.5 answers 404 with the feature switched off — not 403 — and the
  // client acts on the error code rather than on the status either way.
  test('accounts switched off is the documented 404 error code', () async {
    final api = clientFor(
      (_) async => http.Response(
        jsonEncode({'ok': false, 'error': 'accounts_disabled'}),
        404,
      ),
    );
    await expectLater(
      api.linkAccount(provider: 'apple', idToken: 'jwt'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.errorCode,
          'errorCode',
          'accounts_disabled',
        ),
      ),
    );
  });

  test(
    'a refused token carries its reason, and a 401 is unauthorized',
    () async {
      final api = clientFor(
        (_) async => http.Response(
          jsonEncode({
            'ok': false,
            'error': 'invalid_token',
            'reason': 'expired_token',
          }),
          401,
        ),
      );
      await expectLater(
        api.linkAccount(provider: 'apple', idToken: 'jwt'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.errorCode, 'errorCode', 'invalid_token')
              .having((e) => e.detail, 'detail', 'expired_token')
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
    },
  );

  test('409 already_linked names the provider it is linked with', () async {
    final api = clientFor(
      (_) async => http.Response(
        jsonEncode({
          'ok': false,
          'error': 'already_linked',
          'provider': 'google',
        }),
        409,
      ),
    );
    await expectLater(
      api.linkAccount(provider: 'apple', idToken: 'jwt'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.errorCode, 'errorCode', 'already_linked')
            .having((e) => e.detail, 'detail', 'google'),
      ),
    );
  });

  test('429 carries the server retry-after', () async {
    final api = clientFor(
      (_) async => http.Response(
        jsonEncode({'ok': false, 'error': 'rate_limited'}),
        429,
        headers: {'retry-after': '60'},
      ),
    );
    await expectLater(
      api.linkAccount(provider: 'apple', idToken: 'jwt'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.rateLimited)
            .having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(minutes: 1),
            ),
      ),
    );
  });

  test('503 keys_unavailable is ours to retry, not a bad token', () async {
    final api = clientFor(
      (_) async => http.Response(
        jsonEncode({'ok': false, 'error': 'keys_unavailable'}),
        503,
      ),
    );
    await expectLater(
      api.linkAccount(provider: 'apple', idToken: 'jwt'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.server)
            .having((e) => e.errorCode, 'errorCode', 'keys_unavailable'),
      ),
    );
  });

  test('a deletion authenticates and reports the anonymised runs', () async {
    late http.Request sent;
    final api = clientFor((request) async {
      sent = request;
      return http.Response(
        jsonEncode({'ok': true, 'deleted': true, 'scoresAnonymised': 4}),
        200,
      );
    });

    expect(await api.deletePlayer(testCredentials(3)), 4);
    expect(sent.method, 'DELETE');
    expect(sent.url.path, '/api/players/me');
    expect(sent.headers['authorization'], testCredentials(3).header);
  });

  test('a deletion with a refused credential is unauthorized', () async {
    final api = clientFor(
      (_) async => http.Response(
        jsonEncode({'ok': false, 'error': 'invalid_credentials'}),
        401,
      ),
    );
    await expectLater(
      api.deletePlayer(testCredentials(3)),
      throwsA(
        isA<ApiException>().having(
          (e) => e.isUnauthorized,
          'isUnauthorized',
          isTrue,
        ),
      ),
    );
  });

  test('health reports the providers the deployment accepts', () async {
    final api = clientFor(
      (_) async => http.Response(
        jsonEncode({
          'ok': true,
          'version': '1.0.0',
          'rooms': 0,
          'accounts': ['apple', 'google'],
        }),
        200,
      ),
    );
    expect((await api.health()).accounts, ['apple', 'google']);
  });
}
