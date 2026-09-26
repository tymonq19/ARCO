import 'dart:async';
import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:arco/app/cosmetics.dart';
import 'package:arco/app/game_theme.dart';
import 'package:arco/app/settings.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/game/input/input_controller.dart';
import 'package:arco/app/theme.dart';
import 'package:arco/services/account_offer.dart';
import 'package:arco/services/account_service.dart';
import 'package:arco/services/ads_gateway.dart';
import 'package:arco/services/ads_service.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/audio_service.dart';
import 'package:arco/services/duel_client.dart';
import 'package:arco/services/haptics.dart';
import 'package:arco/services/native_sign_in.dart';
import 'package:arco/services/player_identity.dart';
import 'package:arco/services/purchase_gateway.dart';
import 'package:arco/services/purchase_service.dart';
import 'package:arco/services/secret_store.dart';
import 'package:arco/services/shop_service.dart';
import 'package:arco/services/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Services every screen needs, backed by in-memory fakes: mocked
/// shared_preferences, a muted [AudioService] that is never initialized (so no
/// audio plugin is touched), haptics off and a scripted [ApiClient].
class TestEnv {
  TestEnv({
    required this.storage,
    required this.settings,
    required this.audio,
    required this.haptics,
    required this.api,
    required this.identity,
    required this.secrets,
    required this.accounts,
    required this.native,
    required this.shop,
    required this.purchases,
    required this.store,
    required this.ads,
    required this.adsGateway,
  });

  final Storage storage;
  final Settings settings;
  final AudioService audio;
  final Haptics haptics;
  final FakeApiClient api;

  /// Player identity (SPEC 4.4) over [secrets]; issues lazily through [api].
  final PlayerIdentity identity;

  /// The keychain stand-in behind [identity].
  final FakeSecretStore secrets;

  /// Sign in with Apple / Google (SPEC 4.5) over [native] and [api].
  final AccountService accounts;

  /// The provider stand-in behind [accounts].
  final FakeNativeSignIn native;

  /// The cosmetic shop (SPEC 4.8) over [api]: the wallet, the catalogue, what is
  /// owned and what is worn.
  final ShopService shop;

  /// The one-time unlock (SPEC 4.9) over [store] and [api].
  final PurchaseService purchases;

  /// The store stand-in behind [purchases]. StoreKit and Google Play Billing
  /// cannot run in a test, which is the whole reason [PurchaseGateway] is an
  /// interface: every outcome a real player meets — cancelled, pending, already
  /// owned, store down, no network, a purchase that lands while the app is
  /// backgrounded — is reachable from here without a device.
  final FakePurchaseGateway store;

  /// Rewarded ads that pay Sparks (SPEC 4.10) over [adsGateway] and [api].
  final AdsService ads;

  /// The ads stand-in behind [ads]. Neither the Mobile Ads SDK nor Google's UMP
  /// SDK can run in a test, which is the whole reason [AdsGateway] is an
  /// interface: every state a real player meets — no ad filled, an ad closed
  /// early, a consent form declined, a region that needs no form — is reachable
  /// from here without a device and without an AdMob account.
  final FakeAdsGateway adsGateway;

  /// When the offer may be shown, and the memory of it being waved away.
  AccountOffer get offer => accounts.offer;
}

/// A 32-hex-character player id, as `POST /api/players` issues them.
String testPlayerId(int n) => n.toRadixString(16).padLeft(32, '0');

/// A base64url secret of the length the server issues (43 characters).
String testPlayerSecret(int n) =>
    n.toRadixString(16).padLeft(3, '0').padRight(43, 'x');

PlayerCredentials testCredentials(int n) =>
    PlayerCredentials(id: testPlayerId(n), secret: testPlayerSecret(n));

/// [playerName] set to null stores no nickname at all, which is what a genuine
/// first launch looks like: [Settings] then generates one and reports
/// `onboarded == false`, so the app opens on the welcome screen.
Future<TestEnv> createTestEnv({
  Map<String, Object> prefs = const {},
  FakeApiClient? api,
  bool haptics = false,
  bool menuMotion = false,
  ThemeId? theme,
  String? playerName = 'Tester',
  FakeSecretStore? secrets,
  String? deviceCountry,
  DateTime Function()? now,
  FakeNativeSignIn? native,
  TargetPlatform platform = TargetPlatform.iOS,
  Set<String> owned = const <String>{},
  int balance = 0,
  FakePurchaseGateway? store,
  bool sellsUnlock = false,
  bool premium = false,
  FakeAdsGateway? adsGateway,
  AdOffer? adOffer,
}) async {
  // Items this player has bought (SPEC 4.8), seeded into the fake server *and*
  // into this device's shop cache — which is what a device that has synced once
  // looks like, and what a device running a paid look must look like: a phone
  // wearing Glass owns Glass, or the next sync honestly takes it back.
  final ownedItems = <String>{
    ...owned,
    if (theme != null) 'theme.${theme.name}',
  };
  SharedPreferences.setMockInitialValues({
    'playerName': ?playerName,
    'haptics': haptics,
    // Off by default, like the haptics above: the title screen's living
    // background is a [Ticker] that never stops, so with it on `pumpAndSettle`
    // on any screen that has the menu underneath it can never settle. The tests
    // that are *about* it ask for it (`menuMotion: true`) and drive frames by
    // hand; see `test/widget/menu_ball_backdrop_test.dart`.
    'menuMotion': menuMotion,
    if (theme != null) 'theme': theme.name,
    if (ownedItems.isNotEmpty || balance > 0 || premium)
      'shopCache': jsonEncode(
        ShopSnapshot(
          // A premium device has certainly synced at least once, so its cache
          // carries the catalogue — which is what makes a restart with no network
          // a shop rather than a "needs a connection" panel (SPEC 4.9).
          items: premium
              ? FakeApiClient.defaultCatalogue()
              : const <ShopItem>[],
          owned: ownedItems,
          // A device that has synced since the purchase (SPEC 4.9): the phone
          // knows it is premium before any request finishes, which is what makes
          // a restart with no network keep working.
          premium: premium,
          equipped: {if (theme != null) 'theme': 'theme.${theme.name}'},
          balance: balance,
          dailyCap: 200,
          latestVersion: 1,
          knownAt: (now ?? DateTime.now)(),
        ).toJson(),
      ),
    ...prefs,
  });
  final storage = await Storage.load();
  final settings = Settings(storage);
  final client = api ?? FakeApiClient();
  client.shopOwned.addAll(ownedItems);
  client.shopBalance = balance;
  // A deployment that takes money (SPEC 4.9) is the exception, not the default:
  // with no product the shop draws no money section at all, which is what every
  // test that predates this feature must keep seeing. A premium player implies
  // one, because somebody had to sell it to them.
  if (sellsUnlock || premium) client.shopUnlock = testUnlock();
  if (premium) client.shopPremium = true;
  if (theme != null) client.shopEquipped['theme'] = 'theme.${theme.name}';
  final secretStore = secrets ?? FakeSecretStore();
  final sheets = native ?? FakeNativeSignIn();
  // No country by default: a device that names none is the quiet case, so a
  // test only sees the national board when it asks for it.
  final identity = PlayerIdentity(
    api: client,
    storage: storage,
    secrets: secretStore,
    deviceCountry: () => deviceCountry,
    now: now,
  );
  final gateway = store ?? FakePurchaseGateway();
  // A deployment that credits rewarded ads (SPEC 4.10) is the exception, not the
  // default: with no offer the server answers `ads_disabled`, no screen draws an
  // ad button, and every test that predates this feature is unaffected.
  final ads = adsGateway ?? FakeAdsGateway(available: adOffer != null);
  if (adOffer != null) client.adOffer = adOffer;
  final shop = ShopService(
    api: client,
    identity: identity,
    storage: storage,
    settings: settings,
    now: now,
  );
  return TestEnv(
    storage: storage,
    settings: settings,
    audio: AudioService(muted: true),
    haptics: Haptics(settings),
    api: client,
    secrets: secretStore,
    identity: identity,
    native: sheets,
    shop: shop,
    store: gateway,
    purchases: PurchaseService(
      gateway: gateway,
      api: client,
      identity: identity,
      shop: shop,
    ),
    adsGateway: ads,
    ads: AdsService(
      gateway: ads,
      api: client,
      identity: identity,
      shop: shop,
      // A widget test drives frames by hand, so the poll for the server's credit
      // has to finish inside a handful of pumps rather than a handful of seconds.
      pollAttempts: 3,
      pollDelay: const Duration(milliseconds: 10),
    ),
    // iOS by default, which is where Apple has to come first (SPEC 4.5); a test
    // about the Android order passes the platform in.
    accounts: AccountService(
      api: client,
      identity: identity,
      native: sheets,
      offer: AccountOffer(storage: storage, now: now),
      storage: storage,
      now: now,
      platform: () => platform,
    ),
  );
}

/// Wraps [home] in the providers and theme the app installs in `main()`.
/// [routes] makes named navigation available (it must not contain `/`).
Widget wrapApp(TestEnv env, Widget home, {Map<String, WidgetBuilder>? routes}) {
  return MultiProvider(
    providers: [
      Provider<Storage>.value(value: env.storage),
      ChangeNotifierProvider<Settings>.value(value: env.settings),
      Provider<AudioService>.value(value: env.audio),
      Provider<Haptics>.value(value: env.haptics),
      Provider<ApiClient>.value(value: env.api),
      ChangeNotifierProvider<PlayerIdentity>.value(value: env.identity),
      Provider<AccountService>.value(value: env.accounts),
      ChangeNotifierProvider<ShopService>.value(value: env.shop),
      ChangeNotifierProvider<PurchaseService>.value(value: env.purchases),
      ChangeNotifierProvider<AdsService>.value(value: env.ads),
    ],
    // Mirrors the shell in `main()`: the same localization delegates, the same
    // Settings-driven locale and the same Settings-driven [GameTheme] provided
    // above the navigator, so a test sees what a device sees.
    child: Selector<Settings, (AppLanguage, GameTheme)>(
      selector: (_, settings) => (settings.language, settings.theme),
      builder: (context, value, _) {
        final (language, theme) = value;
        return Provider<GameTheme>.value(
          value: theme,
          // The equipped ball and paddle (SPEC 4.8), provided above the
          // navigator exactly as `main()` does it, so a test sees the skins a
          // device would.
          child: Selector<ShopService, Equipped>(
            selector: (_, shop) => shop.equipped,
            builder: (context, equipped, child) =>
                Provider<Equipped?>.value(value: equipped, child: child!),
            child: MaterialApp(
              theme: buildAppTheme(theme),
              // The GameTheme provided above switches instantly, so Material must
              // not cross-fade its own colours behind it: half a second of a navy
              // scaffold under off-white panels reads as a glitch.
              themeAnimationDuration: Duration.zero,
              supportedLocales: const [Locale('en'), Locale('pl')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              locale: Strings.localeFor(language),
              routes: routes ?? const <String, WidgetBuilder>{},
              home: home,
            ),
          ),
        );
      },
    ),
  );
}

/// iPhone SE (1st/2nd gen) logical size: 375 x 667.
void useIPhoneSe(WidgetTester tester) {
  tester.view.physicalSize = const Size(750, 1334);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// iPhone SE (1st gen) / iPhone 5s logical size: 320 x 568 — the narrowest
/// phone the app supports.
void useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(640, 1136);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// iPhone 11 / 12 logical size: 375 x 812. Used where a test needs a taller
/// viewport than the iPhone SE to reach a control without scrolling.
void useTallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(750, 1624);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Pumps [frames] simulated 60 Hz frames.
Future<void> pumpFrames(
  WidgetTester tester,
  int frames, {
  Duration frame = const Duration(milliseconds: 16),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(frame);
  }
}

/// In-memory stand-in for the platform keychain.
///
/// [failing] turns every call into a throw, which is what a device without
/// secure storage looks like (the web build, a missing plugin): the app has to
/// keep playing and submit anonymously rather than show anybody an error.
class FakeSecretStore implements SecretStore {
  FakeSecretStore({Map<String, String>? initial, this.failing = false})
    : values = {...?initial};

  /// Seeded with a credential, the way a device that has submitted before
  /// starts up.
  factory FakeSecretStore.withCredentials(PlayerCredentials credentials) =>
      FakeSecretStore(
        initial: {
          PlayerIdentity.idKey: credentials.id,
          PlayerIdentity.secretKey: credentials.secret,
        },
      );

  final Map<String, String> values;
  bool failing;

  int reads = 0;
  int writes = 0;
  int deletes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    if (failing) throw UnsupportedError('no keychain');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (failing) throw UnsupportedError('no keychain');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    if (failing) throw UnsupportedError('no keychain');
    values.remove(key);
  }
}

/// [ApiClient] that never touches the network.
class FakeApiClient extends ApiClient {
  FakeApiClient({
    this.entries = const <LeaderboardEntry>[],
    this.offline = false,
    this.submitResult,
    this.profile,
  }) : super(baseUrl: () => 'http://fake.local');

  List<LeaderboardEntry> entries;

  /// Entries per country code for `GET /api/leaderboard?country=…`; the global
  /// [entries] are answered for a request without one.
  Map<String, List<LeaderboardEntry>> countryEntries =
      <String, List<LeaderboardEntry>>{};

  /// Entries for the two-ball board (SPEC 2.3 / 4.6); null answers an empty
  /// board, which is what a deployment nobody has played two balls on looks
  /// like.
  List<LeaderboardEntry>? twoBallEntries;

  bool offline;

  /// Answered by every submission unless [submitResults] still has one queued.
  SubmitResult? submitResult;

  /// Consumed in order, one per submission: lets a test script "401 first, then
  /// accepted".
  final List<SubmitResult> submitResults = <SubmitResult>[];

  /// What `GET /api/players/me` answers; null makes it fail as unauthorized.
  PlayerProfile? profile;

  /// What `POST /api/players` issues, unless [createPlayerFailure] is set.
  PlayerCredentials issued = testCredentials(1);
  ApiException? createPlayerFailure;

  /// Held-open calls, so a test can make something else happen while one is in
  /// flight — the shape of every "the answer came back after the player had
  /// moved on" race.
  Completer<void>? createPlayerDelay;
  Completer<void>? playerMeDelay;

  /// What `GET /api/health` advertises under `accounts` (SPEC 4.5). Empty by
  /// default, which is a deployment with sign-in switched off: no screen shows
  /// anything about it, so every test that predates accounts is unaffected.
  List<String> accounts = const <String>[];

  /// The credential `POST /api/account/link` issues; it deliberately differs
  /// from [issued], so a test can tell the swap happened.
  PlayerCredentials linkIssued = testCredentials(2);

  /// Overrides the whole `200` body of a link; null builds one from the call.
  AccountLink? linkResult;

  /// Thrown by every link call.
  ApiException? linkFailure;

  /// Thrown by the **next** link call only, then forgotten: the 401 path, where
  /// a stale credential is dropped and the same token presented again.
  ApiException? linkFailureOnce;

  /// What `DELETE /api/players/me` reports, unless [deleteFailure] is set.
  int scoresAnonymised = 0;
  ApiException? deleteFailure;

  int leaderboardCalls = 0;
  int submitCalls = 0;
  int createPlayerCalls = 0;
  int profileCalls = 0;
  int healthCalls = 0;
  int linkCalls = 0;
  int deletePlayerCalls = 0;

  /// What each link call carried, in order.
  final List<PlayerCredentials?> linkCredentials = <PlayerCredentials?>[];
  final List<String> linkProviders = <String>[];
  final List<String> linkTokens = <String>[];

  /// What each submission carried, in order.
  final List<PlayerCredentials?> submitCredentials = <PlayerCredentials?>[];
  final List<String?> submitCountries = <String?>[];
  final List<String?> leaderboardCountries = <String?>[];

  /// The `balls` parameter of each leaderboard call, in order (SPEC 4.6).
  final List<int> leaderboardBallCounts = <int>[];

  /// The `Authorization` header value of the last submission, or null when it
  /// went out anonymously.
  String? get lastAuthHeader =>
      submitCredentials.isEmpty ? null : submitCredentials.last?.header;

  @override
  Future<HealthInfo> health() async {
    healthCalls++;
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    return HealthInfo(ok: true, version: '1.0.0', rooms: 0, accounts: accounts);
  }

  @override
  Future<AccountLink> linkAccount({
    required String provider,
    required String idToken,
    PlayerCredentials? credentials,
  }) async {
    linkCalls++;
    linkProviders.add(provider);
    linkTokens.add(idToken);
    linkCredentials.add(credentials);
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    final once = linkFailureOnce;
    if (once != null) {
      linkFailureOnce = null;
      throw once;
    }
    final failure = linkFailure;
    if (failure != null) throw failure;
    return linkResult ??
        AccountLink(
          credentials: linkIssued,
          provider: provider,
          // Without credentials the account is created or handed back; with them
          // the player we already were gains it (SPEC 4.5).
          outcome: credentials == null
              ? AccountLinkOutcome.created
              : AccountLinkOutcome.linked,
          name: 'Tester',
          games: 1,
          bestScore: 100,
          rank: 5,
          linkedAt: DateTime.utc(2026, 9, 21, 10),
          createdAt: DateTime.utc(2026, 9, 20, 10),
        );
  }

  @override
  Future<int> deletePlayer(PlayerCredentials credentials) async {
    deletePlayerCalls++;
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    final failure = deleteFailure;
    if (failure != null) throw failure;
    return scoresAnonymised;
  }

  @override
  Future<List<LeaderboardEntry>> leaderboard(
    LeaderboardPeriod period, {
    int limit = 100,
    String? country,
    int ballCount = minBallCount,
  }) async {
    leaderboardCalls++;
    leaderboardCountries.add(country);
    leaderboardBallCounts.add(ballCount);
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    if (ballCount >= 2) {
      return twoBallEntries ?? const <LeaderboardEntry>[];
    }
    if (country == null) return entries;
    return countryEntries[country] ?? const <LeaderboardEntry>[];
  }

  @override
  Future<SubmitResult> submitScore(
    String name,
    Replay replay, {
    PlayerCredentials? credentials,
    String? country,
  }) async {
    submitCalls++;
    submitCredentials.add(credentials);
    submitCountries.add(country);
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    if (submitResults.isNotEmpty) return submitResults.removeAt(0);
    return submitResult ??
        SubmitResult.accepted(
          id: 'id-1',
          score: replay.claimedScore,
          rank: 7,
          playerId: credentials?.id,
          country: country,
          countryRank: country == null ? null : 2,
        );
  }

  @override
  Future<PlayerCredentials> createPlayer({String? name}) async {
    createPlayerCalls++;
    await createPlayerDelay?.future;
    final failure = createPlayerFailure;
    if (failure != null) throw failure;
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    return issued;
  }

  @override
  Future<PlayerProfile> playerMe(PlayerCredentials credentials) async {
    profileCalls++;
    await playerMeDelay?.future;
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    final p = profile;
    if (p == null) {
      throw const ApiException(
        ApiErrorKind.unauthorized,
        'invalid_credentials',
        statusCode: 401,
        errorCode: 'invalid_credentials',
      );
    }
    return p;
  }

  @override
  Future<int> rank(int score, {int ballCount = minBallCount}) async => 7;

  // ------------------------------------------------- cosmetic shop (SPEC 4.8)

  /// The catalogue this "server" serves. Seeded with the real one
  /// (`server/lib/src/catalogue.dart`) so a screen test sees the prices a device
  /// would; a test about what the shop *renders* replaces it wholesale, which is
  /// how "the shop lists what the server returns and nothing hardcoded" is
  /// checked.
  List<ShopItem> catalogueItems = defaultCatalogue();

  /// The wallet. Debited by [shopBuy] exactly as the server's transaction does.
  int shopBalance = 0;

  /// Bought items. Free ones are owned without being in here, as on the server.
  Set<String> shopOwned = <String>{};

  /// Stored slot choices; the defaults are filled in on the way out.
  Map<String, String> shopEquipped = <String, String>{};

  int shopEarnedToday = 0;
  int shopDailyCap = 200;
  int shopLatestVersion = 1;

  /// The one-time unlock this "server" sells (SPEC 4.9). **Null by default**,
  /// which is a deployment with no RevenueCat configured — so every test that
  /// predates the money feature sees a shop with no money section at all.
  UnlockProduct? shopUnlock;

  /// Whether this "server" has granted this player the unlock (SPEC 4.9).
  ///
  /// It is the **server's** answer and nothing else: every item then comes back
  /// `owned` with no row written anywhere, exactly as the real server answers, so a
  /// cosmetic added to [catalogueItems] afterwards is covered without being listed
  /// as bought.
  bool shopPremium = false;

  /// How many purchases the last sync call granted, as it reports them. A test
  /// that wants "the webhook already landed" sets [shopPremium] instead and leaves
  /// this at 0 — which is exactly the shape of the real race.
  int syncGranted = 0;

  /// Makes the **next** sync call grant premium, standing in for the grant the
  /// real server makes from RevenueCat's verified webhook. It is the *server's*
  /// move: a test that leaves it false is a server that has granted nothing, and
  /// the client must then claim nothing.
  bool syncGrantsOnCall = false;

  /// Overrides the `owned` flag the sync reports — whether RevenueCat knows of the
  /// unlock for this store account at all. Null means "the same as premium", which
  /// is the ordinary case; setting it true with [shopPremium] false is a refunded
  /// purchase the store still remembers.
  bool? syncOwned;

  /// Ledger rows the sync call reports.
  List<PurchaseRecord> syncPurchases = const <PurchaseRecord>[];

  /// Thrown by every sync call.
  ApiException? syncFailure;

  // ------------------------------------------- rewarded ads (SPEC 4.10)

  /// What `GET /api/ads/offer` answers. [AdOffer.none] by default, which is a
  /// deployment with `ADS_ENABLED` off — so no screen draws an ad button and every
  /// test that predates this feature sees what it always saw.
  AdOffer adOffer = AdOffer.none;

  /// Sparks this "server" credits when the **next** offer call is made, standing
  /// in for the credit the real server makes when Google's signed callback
  /// arrives. It is the **server's** move: a test that leaves it at 0 is a server
  /// that has not credited anything, and the client must then claim nothing.
  ///
  /// It fires on the first call after being set, which is what the poll in
  /// `AdsService` is looking for: `adTotal` moving.
  int adCreditsOnNextOffer = 0;

  /// Thrown by every offer call — our own server unreachable while the ad itself
  /// went fine, which is the case where the client must say "on their way".
  ApiException? adOfferFailure;

  int adsOfferCalls = 0;
  final List<PlayerCredentials> adsOfferCredentials = <PlayerCredentials>[];

  int purchasesSyncCalls = 0;
  final List<PlayerCredentials> syncCredentials = <PlayerCredentials>[];

  /// Thrown by every shop call — a shop that is reachable while the rest of the
  /// API is not, and the other way round.
  ApiException? shopFailure;

  /// Thrown by the **next** buy only, then forgotten: the mid-flight failure,
  /// where the client cannot know whether the purchase landed.
  ApiException? buyFailureOnce;

  /// Makes [buyFailureOnce] fire *after* the purchase has been recorded, which is
  /// the nastier half of the same race: the wallet was debited and the answer was
  /// lost.
  bool buyLandsBeforeFailure = false;

  /// Thrown by every equip call.
  ApiException? equipFailure;

  int shopCatalogueCalls = 0;
  int shopInventoryCalls = 0;
  int shopBuyCalls = 0;
  int shopEquipCalls = 0;

  /// What each call carried, in order.
  final List<String> shopBuys = <String>[];
  final List<Map<String, String?>> shopEquips = <Map<String, String?>>[];
  final List<PlayerCredentials?> shopCredentials = <PlayerCredentials?>[];

  /// The real seeded catalogue of SPEC 4.8, in the server's own order.
  static List<ShopItem> defaultCatalogue() => <ShopItem>[
    shopItem('theme.neon', 'theme', 0),
    shopItem('theme.classic', 'theme', 0),
    shopItem('theme.modernist', 'theme', 150),
    shopItem('theme.glass', 'theme', 250),
    shopItem('ball.orb', 'ball', 0),
    shopItem('ball.comet', 'ball', 80),
    shopItem('ball.prism', 'ball', 120),
    shopItem('ball.ember', 'ball', 180),
    shopItem('paddle.arc', 'paddle', 0),
    shopItem('paddle.blade', 'paddle', 80),
    shopItem('paddle.halo', 'paddle', 120),
    shopItem('paddle.chevron', 'paddle', 180),
  ];

  /// One catalogue entry, with `free` derived from the price exactly as the
  /// server derives it.
  static ShopItem shopItem(
    String id,
    String kind,
    int priceTokens, {
    bool owned = false,
  }) => ShopItem(
    id: id,
    kind: kind,
    priceTokens: priceTokens,
    free: priceTokens == 0,
    nameKey: id,
    owned: owned,
  );

  /// Whether this "server" considers [id] owned: premium, bought, or free.
  ///
  /// [shopPremium] comes first for the same reason the real server puts it first:
  /// premium is ownership of the whole catalogue, present and future, not a set of
  /// rows that has to be kept in step with it.
  bool shopOwns(String id) =>
      shopPremium ||
      shopOwned.contains(id) ||
      catalogueItems.any((item) => item.id == id && item.free);

  /// Every slot filled in, as both shop endpoints answer.
  Map<String, String> get _resolvedEquipped {
    final slots = <String, String>{};
    for (final item in catalogueItems) {
      if (slots.containsKey(item.kind)) continue;
      if (item.free) slots[item.kind] = item.id;
    }
    for (final entry in shopEquipped.entries) {
      slots[entry.key] = entry.value;
    }
    return slots;
  }

  List<String> get _ownedIds => <String>[
    for (final item in catalogueItems)
      if (shopOwns(item.id)) item.id,
  ];

  void _shopCall(PlayerCredentials credentials) {
    shopCredentials.add(credentials);
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    final failure = shopFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<ShopCatalogue> shopCatalogue(
    PlayerCredentials credentials, {
    required int version,
  }) async {
    shopCatalogueCalls++;
    _shopCall(credentials);
    return ShopCatalogue(
      version: version,
      latestVersion: shopLatestVersion,
      kinds: <String>[
        for (final kind in const ['theme', 'ball', 'paddle'])
          if (catalogueItems.any((item) => item.kind == kind)) kind,
      ],
      items: <ShopItem>[
        for (final item in catalogueItems)
          shopItem(
            item.id,
            item.kind,
            item.priceTokens,
            owned: shopOwns(item.id),
          ),
      ],
      balance: shopBalance,
      equipped: _resolvedEquipped,
      premium: shopPremium,
      // The real server stops advertising the product the moment it is owned:
      // there is then nothing left to sell (SPEC 4.9).
      unlock: shopPremium ? null : shopUnlock,
    );
  }

  @override
  Future<ShopInventory> shopInventory(
    PlayerCredentials credentials, {
    required int version,
  }) async {
    shopInventoryCalls++;
    _shopCall(credentials);
    return ShopInventory(
      version: version,
      latestVersion: shopLatestVersion,
      balance: shopBalance,
      owned: _ownedIds,
      equipped: _resolvedEquipped,
      earnedToday: shopEarnedToday,
      dailyCap: shopDailyCap,
      premium: shopPremium,
    );
  }

  @override
  Future<ShopPurchase> shopBuy(
    PlayerCredentials credentials,
    String itemId, {
    required int version,
  }) async {
    shopBuyCalls++;
    shopBuys.add(itemId);
    _shopCall(credentials);
    final once = buyFailureOnce;
    if (once != null && !buyLandsBeforeFailure) {
      buyFailureOnce = null;
      throw once;
    }
    final item = catalogueItems.firstWhere(
      (i) => i.id == itemId,
      orElse: () => shopItem('', '', -1),
    );
    if (item.priceTokens < 0) {
      return ShopPurchase.refused(
        error: ShopPurchase.unknownItemError,
        itemId: itemId,
        priceTokens: 0,
        balance: shopBalance,
      );
    }
    final alreadyOwned = shopOwns(itemId);
    if (!alreadyOwned && shopBalance < item.priceTokens) {
      return ShopPurchase.refused(
        error: ShopPurchase.insufficientTokensError,
        itemId: itemId,
        priceTokens: item.priceTokens,
        balance: shopBalance,
      );
    }
    final charged = alreadyOwned ? 0 : item.priceTokens;
    shopBalance -= charged;
    shopOwned.add(itemId);
    if (once != null) {
      // The purchase landed and the answer was lost on the way back.
      buyFailureOnce = null;
      throw once;
    }
    return ShopPurchase.done(
      itemId: itemId,
      priceTokens: item.priceTokens,
      charged: charged,
      alreadyOwned: alreadyOwned,
      balance: shopBalance,
      owned: _ownedIds,
      premium: shopPremium,
    );
  }

  @override
  Future<PurchaseSync> purchasesSync(PlayerCredentials credentials) async {
    purchasesSyncCalls++;
    syncCredentials.add(credentials);
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    final failure = syncFailure;
    if (failure != null) throw failure;
    // The server grants, not the client: this is where the entitlement appears,
    // and the client is only ever told about it afterwards.
    if (syncGrantsOnCall) {
      shopPremium = true;
      syncGranted = 1;
      syncGrantsOnCall = false;
    }
    return PurchaseSync(
      premium: shopPremium,
      granted: syncGranted,
      owned: syncOwned ?? shopPremium,
      balance: shopBalance,
      purchases: syncPurchases,
    );
  }

  @override
  Future<AdOffer> adsOffer(PlayerCredentials credentials) async {
    adsOfferCalls++;
    adsOfferCredentials.add(credentials);
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    final failure = adOfferFailure;
    if (failure != null) throw failure;
    // A premium player is offered **no** ads (SPEC 4.9), with the day's allowance
    // untouched: not fewer ads, none. Exactly what the real server answers.
    if (shopPremium) {
      return AdOffer(
        available: false,
        sparks: adOffer.sparks,
        earnedToday: adOffer.earnedToday,
        dailyCap: adOffer.dailyCap,
        remaining: adOffer.remaining,
        cooldownSeconds: adOffer.cooldownSeconds,
        waitSeconds: adOffer.waitSeconds,
        balance: shopBalance,
        adTotal: adOffer.adTotal,
        premium: true,
        placements: adOffer.placements,
      );
    }
    // The server credits, not the client: this is where the wallet and the ad
    // ledger move, and the client is only ever told about it afterwards.
    if (adCreditsOnNextOffer > 0) {
      final credited = adCreditsOnNextOffer;
      adCreditsOnNextOffer = 0;
      shopBalance += credited;
      adOffer = AdOffer(
        // One reward used up: the cooldown starts, so the next ad is not offered.
        available: false,
        sparks: adOffer.sparks,
        earnedToday: adOffer.earnedToday + credited,
        dailyCap: adOffer.dailyCap,
        remaining: adOffer.remaining - credited,
        cooldownSeconds: adOffer.cooldownSeconds,
        waitSeconds: adOffer.cooldownSeconds,
        balance: shopBalance,
        adTotal: adOffer.adTotal + credited,
        placements: adOffer.placements,
      );
    }
    return adOffer;
  }

  @override
  Future<Map<String, String>> shopEquip(
    PlayerCredentials credentials,
    Map<String, String?> slots, {
    required int version,
  }) async {
    shopEquipCalls++;
    shopEquips.add(slots);
    _shopCall(credentials);
    final failure = equipFailure;
    if (failure != null) throw failure;
    for (final entry in slots.entries) {
      final id = entry.value;
      if (id == null) {
        shopEquipped.remove(entry.key);
        continue;
      }
      // Equipping is a preference, not an entitlement (SPEC 4.8).
      if (!shopOwns(id)) {
        throw const ApiException(
          ApiErrorKind.badResponse,
          'item_not_owned',
          statusCode: 403,
          errorCode: 'item_not_owned',
        );
      }
      shopEquipped[entry.key] = id;
    }
    return _resolvedEquipped;
  }
}

/// Stand-in for the store: StoreKit / Google Play through RevenueCat
/// (SPEC 4.9).
///
/// Nothing real can run here — no payment sheet, no receipt, no store account —
/// which is exactly why [PurchaseGateway] is an interface. What *is* testable is
/// everything above it, and that is where the money rules live: that the client
/// never computes a balance, that a completed payment is followed by asking the
/// server, that a cancelled one is silent, and that a purchase landing while the
/// app is backgrounded still ends with the server being asked.
///
/// It also deliberately **never returns a balance or an amount of Sparks**, just
/// like the real one: a gateway that did would be a phone deciding how much money
/// it had spent.
class FakePurchaseGateway implements PurchaseGateway {
  FakePurchaseGateway({this.available = true, Map<String, String>? prices})
    : storePrices = prices ?? _defaultPrices();

  /// A build with RevenueCat keys on a platform with a store. False is the web
  /// build, an unconfigured fork, and a desktop: the shop then shows no packs.
  @override
  bool available;

  /// Product id → the store's own localised price string. The values look like
  /// what StoreKit really returns in different markets, because the point of the
  /// test is that the app prints them rather than making one up.
  Map<String, String> storePrices;

  /// The one product this app sells, at a string no build of this app could have
  /// produced from a number — which is the property every price test is about.
  static Map<String, String> _defaultPrices() => <String, String>{
    testUnlockProductId: '17,99 zł',
  };

  /// What the next [buy] reports. A test sets this to walk every outcome a real
  /// player meets.
  PurchaseOutcome outcome = PurchaseOutcome.completed;

  /// Consumed in order, one per call, before [outcome].
  final List<PurchaseOutcome> outcomes = <PurchaseOutcome>[];

  /// [identify] fails: RevenueCat unreachable, or a misconfigured key.
  bool identifyFails = false;

  /// [prices] answers nothing — a store that is up but knows no products, which
  /// on a device means the store paperwork is unfinished.
  bool pricesEmpty = false;

  final StreamController<void> _updates = StreamController<void>.broadcast();

  int identifyCalls = 0;
  int priceCalls = 0;
  int restoreCalls = 0;
  bool disposed = false;

  /// App user ids [identify] was called with, in order. The rule under test:
  /// it is our player id, so the two systems agree without a mapping table.
  final List<String> identified = <String>[];

  /// Products [buy] was asked for, in order.
  final List<String> bought = <String>[];

  @override
  Future<bool> identify(String playerId) async {
    identifyCalls++;
    identified.add(playerId);
    return !identifyFails;
  }

  @override
  Future<List<StorePrice>> prices(List<String> productIds) async {
    priceCalls++;
    if (pricesEmpty) return const <StorePrice>[];
    return <StorePrice>[
      for (final id in productIds)
        if (storePrices[id] case final price?)
          StorePrice(productId: id, priceString: price),
    ];
  }

  @override
  Future<PurchaseAttempt> buy(String productId) async {
    bought.add(productId);
    final next = outcomes.isNotEmpty ? outcomes.removeAt(0) : outcome;
    return PurchaseAttempt(next, productId: productId);
  }

  @override
  Future<void> restore() async => restoreCalls++;

  @override
  Stream<void> get purchaseUpdates => _updates.stream;

  /// A purchase that completed while the app was in the background, or a pending
  /// payment approved days later: the store tells us something changed, and the
  /// app's only correct move is to ask the server.
  void emitPurchaseUpdate() {
    if (!_updates.isClosed) _updates.add(null);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _updates.close();
  }
}

/// The store product identifier the real server sells (`FullUnlock.productId` in
/// `server/lib/src/catalogue.dart`).
///
/// `test/services/unlock_pin_test.dart` pins it against the server's own table and
/// against `ios/Arco.storekit`, so it cannot drift between the halves of the
/// feature.
const String testUnlockProductId = 'arco.unlock.full';

/// The one-time unlock the real server advertises (SPEC 4.9), for a test that
/// wants a deployment which sells it.
UnlockProduct testUnlock() =>
    const UnlockProduct(productId: testUnlockProductId, nameKey: 'unlock.full');

/// Stand-in for the ads layer: the Google Mobile Ads SDK and Google's UMP consent
/// SDK (SPEC 4.10).
///
/// Nothing real can run here — no ad fill, no full-screen video, no consent form —
/// which is exactly why [AdsGateway] is an interface. What *is* testable is
/// everything above it, and that is where the rules live: that the client never
/// credits a Spark, that the button is absent unless an ad is genuinely in hand,
/// that the consent form is asked for at the moment the player asks to earn, and
/// that refusing it leaves a working game with no ad button.
///
/// It deliberately **never returns an amount of Sparks**, just like the real one: a
/// gateway that did would be a phone deciding how much it had earned, which is the
/// whole thing a rewarded ad must not allow.
class FakeAdsGateway implements AdsGateway {
  FakeAdsGateway({
    this.available = true,
    this.consentState = AdConsentState.allowed,
    this.fills = true,
  });

  /// A build with an AdMob unit on a platform AdMob serves. False is the web
  /// build, a desktop, and any build a human has not configured — and then no
  /// screen draws an ad button.
  @override
  bool available;

  /// Whether an ad request would fill. False is the ordinary "no ad for this
  /// player right now", which is not an error and shows no button.
  bool fills;

  /// What consent currently says. A test sets [AdConsentState.required] to get the
  /// European case, where the shop offers the form instead of the ad.
  AdConsentState consentState;

  /// What [requestConsent] answers. A test sets [AdConsentOutcome.refused] to walk
  /// the case that matters most: a player who says no keeps a fully working game
  /// and simply never sees an ad button again.
  AdConsentOutcome consentOutcome = AdConsentOutcome.obtained;

  /// What the next [show] reports.
  AdShowOutcome showOutcome = AdShowOutcome.rewarded;

  /// Consumed in order, one per call, before [showOutcome].
  final List<AdShowOutcome> showOutcomes = <AdShowOutcome>[];

  final StreamController<void> _changes = StreamController<void>.broadcast();

  bool _loaded = false;
  int loadCalls = 0;
  int showCalls = 0;
  int consentRefreshCalls = 0;
  int consentRequestCalls = 0;
  bool disposed = false;

  /// Every `(playerId, placement)` [show] was called with, in order. The rule
  /// under test: the player id is ours, and it is what ends up in the ad's signed
  /// `custom_data` — so Google's callback names a wallet without a mapping table.
  final List<({String playerId, AdPlacementId placement})> shown =
      <({String playerId, AdPlacementId placement})>[];

  @override
  bool get loaded => _loaded;

  @override
  AdConsentState get consent => consentState;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<AdConsentState> refreshConsent() async {
    consentRefreshCalls++;
    if (!available) return consentState = AdConsentState.denied;
    _notify();
    return consentState;
  }

  @override
  Future<AdConsentOutcome> requestConsent() async {
    consentRequestCalls++;
    switch (consentOutcome) {
      case AdConsentOutcome.obtained:
      case AdConsentOutcome.notRequired:
        consentState = AdConsentState.allowed;
      case AdConsentOutcome.refused:
      case AdConsentOutcome.unavailable:
        // Google says ads may not be requested. The button goes away and stays
        // away, and nothing else about the game changes.
        consentState = AdConsentState.denied;
        _loaded = false;
    }
    _notify();
    return consentOutcome;
  }

  @override
  Future<bool> load() async {
    loadCalls++;
    // The real gateway refuses to request an ad without permission to, and that
    // line is the whole of the consent guarantee — so the fake refuses too.
    if (!available || !fills || consentState != AdConsentState.allowed) {
      return false;
    }
    _loaded = true;
    _notify();
    return true;
  }

  @override
  Future<AdShowOutcome> show({
    required String playerId,
    required AdPlacementId placement,
  }) async {
    showCalls++;
    shown.add((playerId: playerId, placement: placement));
    if (!_loaded) return AdShowOutcome.failed;
    // A shown ad is consumed, exactly as the real one is: the next button needs a
    // new preload.
    _loaded = false;
    _notify();
    return showOutcomes.isNotEmpty ? showOutcomes.removeAt(0) : showOutcome;
  }

  /// An ad that finished loading on its own, or a consent state that settled while
  /// a screen was open.
  void emitChange() => _notify();

  @override
  Future<void> dispose() async {
    disposed = true;
    await _changes.close();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}

/// An `AdOffer` shaped like the one the real server answers for a player with a
/// fresh allowance (SPEC 4.10).
///
/// The numbers are the server's own (`AdRate` in `server/lib/src/tokens.dart`) and
/// `test/services/ad_pin_test.dart` pins them against it, so a change to the
/// economy on one side fails on the other rather than drifting.
AdOffer testAdOffer({
  bool available = true,
  int sparks = 10,
  int earnedToday = 0,
  int dailyCap = 60,
  int? remaining,
  int cooldownSeconds = 300,
  int waitSeconds = 0,
  int balance = 0,
  int adTotal = 0,
}) => AdOffer(
  available: available,
  sparks: sparks,
  earnedToday: earnedToday,
  dailyCap: dailyCap,
  remaining: remaining ?? dailyCap - earnedToday,
  cooldownSeconds: cooldownSeconds,
  waitSeconds: waitSeconds,
  balance: balance,
  adTotal: adTotal,
  placements: const <String>['shop', 'gameOver'],
);

/// Stand-in for the native Apple / Google sheets (SPEC 4.5).
///
/// The real ones cannot run on a simulator without configured client ids, which
/// is the whole reason [NativeSignIn] is an interface: everything above it —
/// which buttons appear, the credential swap, the messages — is testable without
/// a device or a Google project.
class FakeNativeSignIn implements NativeSignIn {
  FakeNativeSignIn({
    Set<SignInProvider>? available,
    this.token = 'header.payload.signature',
  }) : available = available ?? SignInProvider.values.toSet();

  /// Which providers this "device" can run.
  Set<SignInProvider> available;

  /// The identity token handed back by a successful sheet.
  String token;

  /// The player backs out: [NativeSignIn.identityToken] answers null and nothing
  /// may be shown.
  bool cancel = false;

  /// The sheet cannot run at all (an old iPhone, an unconfigured build).
  bool unavailable = false;

  /// A failure of the provider's own, by its message code.
  String? failure;

  final List<SignInProvider> calls = <SignInProvider>[];
  int forgetCalls = 0;

  @override
  Future<bool> isAvailable(SignInProvider provider) async =>
      available.contains(provider);

  @override
  Future<String?> identityToken(SignInProvider provider) async {
    calls.add(provider);
    if (unavailable) throw const SignInUnavailable('no sheet here');
    final code = failure;
    if (code != null) throw SignInFailure(code);
    return cancel ? null : token;
  }

  @override
  Future<void> forgetSession() async => forgetCalls++;
}

/// In-memory duel server: answers the handshake, hands out a room and can push
/// `start`, `snap`, `over` and `peer_left` frames on demand.
class FakeDuelServer implements WsTransport {
  FakeDuelServer({this.slot = 0, this.peerName = 'Rival'});

  final int slot;
  final String peerName;

  final StreamController<dynamic> _out = StreamController<dynamic>();
  final List<ClientMsg> received = <ClientMsg>[];

  /// Every client frame as raw JSON, for the fields the core's message classes
  /// do not model yet — the ball count of SPEC 2.3 travels as `n`.
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  String code = 'KX7Q';
  String clientName = '';
  bool closed = false;

  /// Balls this room plays with (SPEC 2.3). Set from the `create` frame, and
  /// echoed on `room` and `start` the way a v2 server does; a test playing the
  /// joiner sets it directly, which is the creator having chosen it.
  int ballCount = minBallCount;

  /// Usable as a [WsConnector].
  Future<WsTransport> connect(Uri uri) async => this;

  @override
  Stream<dynamic> get stream => _out.stream;

  @override
  void send(String data) {
    final raw = decodeFrame(data);
    final msg = ClientMsg.decode(data);
    if (msg == null || raw == null) return;
    received.add(msg);
    frames.add(raw);
    switch (msg) {
      case HelloMsg():
        clientName = msg.name;
        emit(const WelcomeMsg(version: protocolVersion));
      case CreateRoomMsg():
        // The creator's choice of game, which the room is then played with.
        final n = raw['n'];
        if (n is int && n >= minBallCount && n <= maxBallCount) ballCount = n;
        emitWithBalls(
          RoomMsg(code: code, slot: slot, names: [clientName, null]),
        );
      case JoinRoomMsg():
        code = msg.code;
        emitWithBalls(RoomMsg(code: code, slot: slot, names: names()));
      case PingMsg():
        emit(PongMsg(clientMs: msg.clientMs, tick: -1));
      case RematchMsg():
      case LeaveMsg():
      case InputMsg():
        break;
    }
  }

  List<String> names() =>
      slot == 0 ? [clientName, peerName] : [peerName, clientName];

  void emit(ServerMsg msg) {
    if (!_out.isClosed) _out.add(encodeMsg(msg));
  }

  /// [msg] plus the room's `n`, the way a v2 server answers (SPEC 3). The core's
  /// `RoomMsg` / `StartMsg` have no field for the ball count yet, so it is added
  /// to the frame itself — which is what the client reads it off.
  void emitWithBalls(ServerMsg msg) {
    if (!_out.isClosed) {
      _out.add(jsonEncode(<String, dynamic>{...msg.toJson(), 'n': ballCount}));
    }
  }

  void start({int seed = 424242, int countdown = 6}) =>
      emitWithBalls(StartMsg(seed: seed, countdown: countdown, names: names()));

  /// A `start` from a server that says nothing about ball counts.
  void startWithoutBalls({int seed = 424242, int countdown = 6}) =>
      emit(StartMsg(seed: seed, countdown: countdown, names: names()));

  void snap(GameState state, {List<GameEvent> events = const []}) =>
      emit(SnapMsg(tick: state.tick, state: state.toJson(), events: events));

  void over({required int winner, List<int> scores = const [10, 20]}) =>
      emit(OverMsg(winner: winner, scores: scores));

  void peerLeft() => emit(const PeerLeftMsg());

  @override
  Future<void> close() async {
    closed = true;
    await _out.close();
  }
}

/// Input source driven by a callback: a constant input or a scripted bot.
class FakeInput implements InputController {
  FakeInput([this.provider]);

  final PlayerInput Function()? provider;
  int resets = 0;
  int pauses = 0;
  int resumes = 0;

  @override
  PlayerInput get current => provider?.call() ?? PlayerInput.none;

  @override
  void reset() => resets++;

  @override
  void pause() => pauses++;

  @override
  void resume() => resumes++;

  @override
  void dispose() {}
}
