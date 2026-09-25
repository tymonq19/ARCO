// Sign in with Apple / Google on a real device (SPEC §4.5).
//
//   flutter test integration_test/accounts_test.dart -d <device-id> \
//       --dart-define=SERVER_URL=http://localhost:18100
//
// Neither provider can run on a simulator without configured client ids, so the
// native sheets are faked here exactly as they are in the unit tests. What a
// fake cannot answer is checked instead:
//
// * the **platform keychain** really replaces both halves of the credential when
//   a link hands back a new one — the one step of this feature that loses a
//   player's scores if it silently fails;
// * the **live server** really answers the way the client parses: the provider
//   list on `/api/health`, `401 invalid_token` for a token that is not one, and
//   `DELETE /api/players/me`.
//
// The keychain half needs nothing but the device. The server half runs only when
// a dev server answers `/api/health`, and says so when it does not.
import 'package:arco/app/server_config.dart';
import 'package:arco/services/account_offer.dart';
import 'package:arco/services/account_service.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/native_sign_in.dart';
import 'package:arco/services/player_identity.dart';
import 'package:arco/services/secret_store.dart';
import 'package:arco/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Stands in for the native sheets, which cannot run here. The token is
/// deliberately not a JWT: the server has to refuse it, and that refusal is one
/// of the things being checked.
class _FakeSignIn implements NativeSignIn {
  bool cancel = false;

  @override
  Future<bool> isAvailable(SignInProvider provider) async => true;

  @override
  Future<String?> identityToken(SignInProvider provider) async =>
      cancel ? null : 'not.a.real.jwt';

  @override
  Future<void> forgetSession() async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the credential a link issues replaces the stored one, in the '
      'real keychain', (tester) async {
    final storage = await Storage.load();
    final api = ApiClient(baseUrl: () => ServerConfig.resolveBaseUrl(''));
    addTearDown(api.close);

    PlayerIdentity fresh() => PlayerIdentity(
      api: api,
      storage: storage,
      secrets: KeychainSecretStore(),
    );

    final identity = fresh();
    addTearDown(identity.forget);
    await identity.forget();

    const before = PlayerCredentials(
      id: '0123456789abcdef0123456789abcdef',
      secret: 'before-secret-before-secret-before-secret00',
    );
    // What a merge answers with: a different player id *and* a new secret.
    const after = PlayerCredentials(
      id: 'fedcba9876543210fedcba9876543210',
      secret: 'after-secret-after-secret-after-secret-aaa',
    );

    await identity.adopt(before);
    expect((await fresh().load())!.id, before.id);

    await identity.adopt(after);
    final reloaded = await fresh().load();
    expect(reloaded!.id, after.id, reason: 'the id half did not follow');
    expect(
      reloaded.secret,
      after.secret,
      reason: 'the secret half was left behind, which is a guaranteed 401',
    );

    await identity.forget();
    expect(await fresh().load(), isNull);
  });

  testWidgets('the live server answers the way the client reads it', (
    tester,
  ) async {
    final storage = await Storage.load();
    final api = ApiClient(baseUrl: () => ServerConfig.resolveBaseUrl(''));
    addTearDown(api.close);
    final identity = PlayerIdentity(
      api: api,
      storage: storage,
      secrets: KeychainSecretStore(),
    );
    addTearDown(identity.forget);
    await identity.forget();
    final native = _FakeSignIn();
    final accounts = AccountService(
      api: api,
      identity: identity,
      native: native,
      offer: AccountOffer(storage: storage),
      storage: storage,
    );

    final HealthInfo health;
    try {
      health = await api.health();
    } on ApiException catch (e) {
      // ignore: avoid_print
      print(
        'no dev server on ${api.baseUrl} ($e): the keychain half of this file '
        'still ran, the server half did not.',
      );
      return;
    }

    // Whatever the deployment advertises is exactly what would be offered.
    final offered = await accounts.providers();
    expect(offered.map((p) => p.name).toSet(), health.accounts.toSet());

    if (health.accounts.isEmpty) {
      // ignore: avoid_print
      print(
        'ACCOUNTS_ENABLED is off on ${api.baseUrl}: nothing is offered, which '
        'is the behaviour checked here. Start the server with '
        'ACCOUNTS_ENABLED=on plus APPLE_CLIENT_IDS / GOOGLE_CLIENT_IDS to '
        'exercise the refusal path too.',
      );
    } else {
      // A token that is not a JWT has to come back as the documented refusal,
      // and must leave this device exactly as anonymous as it was.
      final result = await accounts.signIn(offered.first);
      expect(result, isA<SignInFailed>());
      expect((result as SignInFailed).code, 'invalid_token');
      expect(identity.isIdentified, isFalse);

      // A cancel is silent even against a live server: nothing is sent at all.
      native.cancel = true;
      expect(await accounts.signIn(offered.first), isA<SignInCancelled>());
      native.cancel = false;
    }

    // Deletion is never gated on the account feature (SPEC §4.5), so it runs
    // either way: issue a player, delete it, and check the device forgot it.
    final issued = await identity.ensureIssued();
    expect(issued, isNotNull, reason: 'no identity was issued');
    final deleted = await accounts.deleteAccount();
    expect(deleted, isA<DeleteSucceeded>());
    expect(identity.isIdentified, isFalse);
    expect(await KeychainSecretStore().read(PlayerIdentity.secretKey), isNull);

    // ignore: avoid_print
    print(
      'accounts=${health.accounts} deleted player ${issued!.id} '
      '(scoresAnonymised=${(deleted as DeleteSucceeded).scoresAnonymised})',
    );
  });
}
