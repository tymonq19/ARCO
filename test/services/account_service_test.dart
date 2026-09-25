import 'package:arco/services/account_offer.dart';
import 'package:arco/services/account_service.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/native_sign_in.dart';
import 'package:arco/services/player_identity.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// Signing in with Apple or Google (SPEC §4.5), without a device: which buttons
/// exist, what the credential swap does, and what each documented refusal turns
/// into.
void main() {
  group('which providers are offered', () {
    test('a deployment that advertises none is offered none', () async {
      final env = await createTestEnv();
      expect(env.api.accounts, isEmpty);
      expect(await env.accounts.providers(), isEmpty);
      expect(env.accounts.knownUnavailable, isTrue);
      // Nothing was asked of the providers themselves.
      expect(env.native.calls, isEmpty);
    });

    test('only the advertised ones are offered', () async {
      final env = await createTestEnv();
      env.api.accounts = const ['google'];
      expect(await env.accounts.providers(), [SignInProvider.google]);
    });

    test('Apple comes first on an Apple platform', () async {
      final env = await createTestEnv(platform: TargetPlatform.iOS);
      // Advertised the other way round on purpose: the order is ours, not the
      // server's — App Store review wants Sign in with Apple beside Google.
      env.api.accounts = const ['google', 'apple'];
      expect(await env.accounts.providers(), [
        SignInProvider.apple,
        SignInProvider.google,
      ]);
    });

    test('Google comes first elsewhere', () async {
      final env = await createTestEnv(platform: TargetPlatform.android);
      env.api.accounts = const ['apple', 'google'];
      expect(await env.accounts.providers(), [
        SignInProvider.google,
        SignInProvider.apple,
      ]);
    });

    test('a provider this device cannot run is not offered', () async {
      final env = await createTestEnv(
        native: FakeNativeSignIn(available: {SignInProvider.google}),
      );
      env.api.accounts = const ['apple', 'google'];
      expect(await env.accounts.providers(), [SignInProvider.google]);
    });

    test('a provider name this build has never heard of is ignored', () async {
      final env = await createTestEnv();
      env.api.accounts = const ['facebook', 'apple'];
      expect(await env.accounts.providers(), [SignInProvider.apple]);
    });

    test('a device with nowhere to keep a secret is offered nothing, and '
        'is not even asked about', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore(failing: true),
        api: FakeApiClient()..accounts = const ['apple'],
      );
      expect(await env.accounts.providers(), isEmpty);
      expect(env.api.healthCalls, 0);
    });

    test(
      'an unreachable server leaves the answer unknown, not empty',
      () async {
        final env = await createTestEnv(api: FakeApiClient(offline: true));
        expect(await env.accounts.providers(), isEmpty);
        expect(env.accounts.cachedProviders, isNull);
        expect(env.accounts.knownUnavailable, isFalse);
      },
    );

    test('the list is read once and reused', () async {
      final env = await createTestEnv();
      env.api.accounts = const ['apple'];
      await env.accounts.providers();
      await env.accounts.providers();
      expect(env.api.healthCalls, 1);

      await env.accounts.providers(force: true);
      expect(env.api.healthCalls, 2);
    });

    test('concurrent readers share one health call', () async {
      final env = await createTestEnv();
      env.api.accounts = const ['apple'];
      await Future.wait([
        env.accounts.providers(),
        env.accounts.providers(),
        env.accounts.providers(),
      ]);
      expect(env.api.healthCalls, 1);
    });
  });

  group('signing in', () {
    test('an anonymous device creates the account and stores the credential '
        'it was handed', () async {
      final env = await createTestEnv();
      env.api.accounts = const ['apple'];

      final result = await env.accounts.signIn(SignInProvider.apple);

      expect(result, isA<SignInSucceeded>());
      expect((result as SignInSucceeded).outcome, AccountLinkOutcome.created);
      expect(env.api.linkProviders, ['apple']);
      expect(env.api.linkTokens, ['header.payload.signature']);
      // No credential existed, so none was sent — and none was issued first.
      expect(env.api.linkCredentials, [null]);
      expect(env.api.createPlayerCalls, 0);
      // Both halves of the credential are the ones the link issued.
      expect(env.identity.playerId, testCredentials(2).id);
      expect(env.secrets.values[PlayerIdentity.idKey], testCredentials(2).id);
      expect(
        env.secrets.values[PlayerIdentity.secretKey],
        testCredentials(2).secret,
      );
    });

    test('a device that already has a credential sends it and swaps it for '
        'the new one', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.accounts = const ['apple'];

      final result = await env.accounts.signIn(SignInProvider.apple);

      expect((result as SignInSucceeded).outcome, AccountLinkOutcome.linked);
      expect(env.api.linkCredentials.single?.id, testCredentials(1).id);
      expect(env.identity.playerId, testCredentials(2).id);
      expect(
        env.secrets.values[PlayerIdentity.secretKey],
        testCredentials(2).secret,
      );
    });

    test('a merge reports how many runs moved, and the standing it came '
        'with', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.linkResult = AccountLink(
        credentials: testCredentials(9),
        provider: 'google',
        outcome: AccountLinkOutcome.merged,
        movedScores: 12,
        bestScore: 4321,
        rank: 7,
        games: 20,
        country: 'PL',
        countryRank: 2,
        linkedAt: DateTime.utc(2026, 9, 21),
      );

      final result =
          await env.accounts.signIn(SignInProvider.google) as SignInSucceeded;

      expect(result.outcome, AccountLinkOutcome.merged);
      expect(result.movedScores, 12);
      expect(result.provider, 'google');
      // A merge changes the standing, so the answer's own figures are cached
      // rather than a second `GET /api/players/me` being spent on them.
      expect(env.api.profileCalls, 0);
      expect(env.identity.profile?.rank, 7);
      expect(env.identity.profile?.countryRank, 2);
      expect(env.identity.profile?.hasAccount, isTrue);
      expect(env.identity.country, 'PL');
    });

    test('a cancel is silent: nothing is linked and the offer is '
        'untouched', () async {
      final env = await createTestEnv(
        native: FakeNativeSignIn()..cancel = true,
      );

      final result = await env.accounts.signIn(SignInProvider.apple);

      expect(result, isA<SignInCancelled>());
      expect(env.api.linkCalls, 0);
      expect(env.offer.dismissals, 0);
      expect(env.offer.silenced, isFalse);
      expect(env.identity.isIdentified, isFalse);
    });

    test('a signed-in player is never offered it again', () async {
      final env = await createTestEnv();
      await env.accounts.signIn(SignInProvider.apple);
      expect(env.offer.silenced, isTrue);
    });

    test('a provider that cannot run here says so', () async {
      final env = await createTestEnv(
        native: FakeNativeSignIn()..unavailable = true,
      );
      final result = await env.accounts.signIn(SignInProvider.apple);
      expect((result as SignInFailed).code, 'unavailable');
      expect(env.api.linkCalls, 0);
    });

    test(
      'and stops being offered, because only the attempt could tell',
      () async {
        // Neither SDK can be asked up front whether the build is configured for
        // it: on iOS `google_sign_in` accepts a build with no client id at all
        // and only the sheet says `No active configuration`. So the attempt is
        // what establishes it, and the cached list has to be thrown away or the
        // player is left tapping a button that can never work.
        final native = FakeNativeSignIn();
        final env = await createTestEnv(native: native);
        env.api.accounts = const ['apple', 'google'];
        expect(await env.accounts.providers(), hasLength(2));
        expect(env.api.healthCalls, 1);

        native.unavailable = true;
        native.available = {SignInProvider.apple};
        final result = await env.accounts.signIn(SignInProvider.google);
        expect((result as SignInFailed).code, 'unavailable');
        expect(
          env.accounts.cachedProviders,
          isNull,
          reason: 'the list that still offers it was kept',
        );

        native.unavailable = false;
        expect(await env.accounts.providers(), [SignInProvider.apple]);
        expect(env.api.healthCalls, 2, reason: 'the list was not re-read');
      },
    );

    test('a provider that returns no token says so', () async {
      final env = await createTestEnv(
        native: FakeNativeSignIn()..failure = 'no_token',
      );
      final result = await env.accounts.signIn(SignInProvider.google);
      expect((result as SignInFailed).code, 'no_token');
      expect(env.api.linkCalls, 0);
    });

    test('no network is its own message, not a failed sign-in', () async {
      final env = await createTestEnv(api: FakeApiClient(offline: true));
      final result = await env.accounts.signIn(SignInProvider.apple);
      expect((result as SignInFailed).code, 'offline');
      expect(env.identity.isIdentified, isFalse);
    });

    // Every refusal SPEC §4.5 documents, mapped to the key the UI shows.
    for (final (int status, String code, ApiErrorKind kind) in const [
      (404, 'accounts_disabled', ApiErrorKind.badResponse),
      (401, 'invalid_token', ApiErrorKind.unauthorized),
      (400, 'invalid_provider', ApiErrorKind.badResponse),
      (409, 'already_linked', ApiErrorKind.badResponse),
      (503, 'keys_unavailable', ApiErrorKind.server),
      (429, 'rate_limited', ApiErrorKind.rateLimited),
    ]) {
      test('$status $code maps to its own message', () async {
        final env = await createTestEnv();
        env.api.linkFailure = ApiException(
          kind,
          code,
          statusCode: status,
          errorCode: code,
          detail: code == 'already_linked' ? 'google' : null,
        );

        final result =
            await env.accounts.signIn(SignInProvider.apple) as SignInFailed;

        expect(result.code, code);
        if (code == 'already_linked') expect(result.detail, 'google');
        expect(env.identity.isIdentified, isFalse);
      });
    }

    test('a 500 the spec does not document is the honest "did not '
        'finish"', () async {
      final env = await createTestEnv();
      env.api.linkFailure = const ApiException(
        ApiErrorKind.server,
        'HTTP 500',
        statusCode: 500,
      );
      final result =
          await env.accounts.signIn(SignInProvider.apple) as SignInFailed;
      expect(result.code, 'unknown');
    });

    test('a stale stored credential is dropped and the same token presented '
        'again', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.linkFailureOnce = const ApiException(
        ApiErrorKind.unauthorized,
        'invalid_credentials',
        statusCode: 401,
        errorCode: 'invalid_credentials',
      );

      final result = await env.accounts.signIn(SignInProvider.apple);

      expect(result, isA<SignInSucceeded>());
      expect(env.api.linkCalls, 2);
      // The first attempt carried the stale credential, the second none at all.
      expect(env.api.linkCredentials.first?.id, testCredentials(1).id);
      expect(env.api.linkCredentials.last, isNull);
      expect(env.native.calls.length, 1, reason: 'the player signs in once');
      expect(env.identity.playerId, testCredentials(2).id);
    });

    test('a second 401 gives up rather than looping', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.linkFailure = const ApiException(
        ApiErrorKind.unauthorized,
        'invalid_credentials',
        statusCode: 401,
        errorCode: 'invalid_credentials',
      );

      final result =
          await env.accounts.signIn(SignInProvider.apple) as SignInFailed;

      expect(result.code, 'invalid_credentials');
      expect(env.api.linkCalls, 2);
      expect(env.identity.isIdentified, isFalse);
    });
  });

  group('signing out on this device', () {
    test('forgets the credential here and leaves the account alone', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.identity.load();
      expect(env.identity.isIdentified, isTrue);

      await env.accounts.signOutOnThisDevice();

      expect(env.identity.isIdentified, isFalse);
      expect(env.identity.profile, isNull);
      expect(env.secrets.values, isEmpty);
      // Nothing was detached server side: the player's other phone keeps the
      // account it is still using (SPEC §4.5).
      expect(env.api.linkCalls, 0);
      expect(env.native.forgetCalls, 1);
      // A deliberate sign-out is the clearest no there is.
      expect(env.offer.silenced, isTrue);
    });

    test('the scores this device remembers submitting are kept', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.storage.addOwnScore(id: 'id-1', name: 'Tester', score: 10);

      await env.accounts.signOutOnThisDevice();

      expect(env.storage.isOwnScore(name: 'Tester', score: 10), isTrue);
    });
  });

  group('deleting the account', () {
    test('calls the server and clears everything local', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.scoresAnonymised = 4;
      await env.storage.addOwnScore(id: 'id-1', name: 'Tester', score: 10);

      final result = await env.accounts.deleteAccount();

      expect((result as DeleteSucceeded).scoresAnonymised, 4);
      expect(env.api.deletePlayerCalls, 1);
      expect(env.identity.isIdentified, isFalse);
      expect(env.secrets.values, isEmpty);
      // The rows stay on the board; this phone stops claiming them.
      expect(env.storage.isOwnScore(name: 'Tester', score: 10), isFalse);
      expect(env.offer.silenced, isTrue);
    });

    test('a player that never had an identity needs no request', () async {
      final env = await createTestEnv();
      final result = await env.accounts.deleteAccount();
      expect(result, isA<DeleteSucceeded>());
      expect(env.api.deletePlayerCalls, 0);
    });

    test('a credential the server no longer knows counts as deleted', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.deleteFailure = const ApiException(
        ApiErrorKind.unauthorized,
        'invalid_credentials',
        statusCode: 401,
        errorCode: 'invalid_credentials',
      );

      final result = await env.accounts.deleteAccount();

      expect(result, isA<DeleteSucceeded>());
      expect(env.identity.isIdentified, isFalse);
    });

    test('an unreachable server keeps the account and says so', () async {
      final env = await createTestEnv(
        api: FakeApiClient(offline: true),
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );

      final result = await env.accounts.deleteAccount();

      expect((result as DeleteFailed).code, 'offline');
      // Nothing was thrown away on a failure we cannot confirm.
      expect(env.identity.isIdentified, isTrue);
      expect(env.secrets.values, isNotEmpty);
    });
  });

  test('the offer is silenced the moment an account exists', () async {
    final env = await createTestEnv();
    final offer = AccountOffer(storage: env.storage);
    expect(offer.silenced, isFalse);
    await env.accounts.signIn(SignInProvider.apple);
    expect(offer.silenced, isTrue);
  });
}
