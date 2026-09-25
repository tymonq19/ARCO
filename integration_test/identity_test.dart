// Player identity on a real device (SPEC §4.4 / §4.6).
//
//   flutter test integration_test/identity_test.dart -d <device-id> \
//       --dart-define=SERVER_URL=http://localhost:18100
//
// Everything about the identity is unit-tested against fakes; the one thing a
// fake cannot answer is whether the **platform keychain** really keeps the
// secret and hands it back to the next launch. That is what this checks, on the
// device, together with the lazy issuance that puts it there.
//
// The keychain half needs nothing but the device. The server half runs only when
// a dev server answers `/api/health`, and says so when it does not, rather than
// failing a device check because nothing was listening.
import 'package:arco/app/server_config.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/device_country.dart';
import 'package:arco/services/player_identity.dart';
import 'package:arco/services/secret_store.dart';
import 'package:arco/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the keychain keeps a secret and gives it back', (tester) async {
    final store = KeychainSecretStore();
    const key = 'arco.test.secret';
    addTearDown(() => store.delete(key));

    await store.write(key, 'a-secret-value');
    expect(await store.read(key), 'a-secret-value');
    await store.delete(key);
    expect(await store.read(key), isNull);
  });

  testWidgets('an identity is issued once and survives a fresh start', (
    tester,
  ) async {
    final storage = await Storage.load();
    // The same URL the app itself would use, so `--dart-define=SERVER_URL`
    // points this at the dev server exactly as it points the tour.
    final api = ApiClient(baseUrl: () => ServerConfig.resolveBaseUrl(''));
    addTearDown(api.close);
    final identity = PlayerIdentity(
      api: api,
      storage: storage,
      secrets: KeychainSecretStore(),
    );
    addTearDown(identity.forget);

    // Whatever an earlier run of the tour left behind.
    await identity.forget();

    try {
      await api.health();
    } on ApiException catch (e) {
      // ignore: avoid_print
      print(
        'no dev server on ${api.baseUrl} ($e): the keychain half of this '
        'file still ran, the server half did not.',
      );
      return;
    }

    final issued = await identity.ensureIssued();
    expect(issued, isNotNull, reason: 'no identity was issued');
    expect(await identity.ensureIssued(), same(issued));

    // A second [PlayerIdentity] over its own keychain handle is what the next
    // launch is: it must find the same player without issuing another.
    final relaunched = PlayerIdentity(
      api: api,
      storage: storage,
      secrets: KeychainSecretStore(),
    );
    final loaded = await relaunched.load();
    expect(loaded, isNotNull, reason: 'the credential did not survive');
    expect(loaded!.id, issued!.id);

    final profile = await relaunched.refreshProfile();
    expect(profile, isNotNull, reason: 'GET /api/players/me was refused');
    expect(profile!.id, issued.id);

    // ignore: avoid_print
    print(
      'identity ${issued.id} games=${profile.games} rank=${profile.rank} '
      'country=${DeviceCountry.current()}',
    );
  });
}
