import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'app/cosmetics.dart';
import 'app/game_theme.dart';
import 'app/settings.dart';
import 'app/strings.dart';
import 'app/theme.dart';
import 'services/account_offer.dart';
import 'services/account_service.dart';
import 'services/ads_gateway.dart';
import 'services/ads_service.dart';
import 'services/api_client.dart';
import 'services/audio_service.dart';
import 'services/haptics.dart';
import 'services/native_sign_in.dart';
import 'services/player_identity.dart';
import 'services/purchase_gateway.dart';
import 'services/purchase_service.dart';
import 'services/score_submitter.dart';
import 'services/secret_store.dart';
import 'services/shop_service.dart';
import 'services/storage.dart';
import 'ui/duel_lobby_screen.dart';
import 'ui/home_screen.dart';
import 'ui/leaderboard_screen.dart';
import 'ui/onboarding_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/shop_screen.dart';
import 'ui/solo_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  final storage = await Storage.load();
  final settings = Settings(storage);
  final audio = AudioService(muted: !settings.sound);
  // Preloading the effects must not delay the first frame.
  audio.init();
  runApp(ArcoApp(storage: storage, settings: settings, audio: audio));
}

/// Application shell: providers, the selected [GameTheme] and the named routes.
class ArcoApp extends StatefulWidget {
  const ArcoApp({
    super.key,
    required this.storage,
    required this.settings,
    required this.audio,
    this.secrets,
    this.signIn,
    this.purchases,
    this.ads,
  });

  final Storage storage;
  final Settings settings;
  final AudioService audio;

  /// Where the player's credential is kept (SPEC §4.4); the platform keychain
  /// unless a test hands over something else.
  final SecretStore? secrets;

  /// The native Apple / Google sheets (SPEC §4.5). Neither provider can run on a
  /// simulator without configured client ids, so a test hands over a fake.
  final NativeSignIn? signIn;

  /// The store (SPEC §4.9). StoreKit and Google Play Billing cannot run in a
  /// test or on an unconfigured simulator, so a test hands over a fake — and a
  /// build with no RevenueCat keys gets one that reports itself unavailable, so
  /// the shop simply shows no packs.
  final PurchaseGateway? purchases;

  /// The ads layer (SPEC §4.10). The Mobile Ads SDK and Google's UMP SDK cannot
  /// run in a test, and neither will serve an ad to a build with no AdMob unit
  /// configured, so a test hands over a fake — and a build with no unit gets one
  /// that reports itself unavailable, so no ad button is ever drawn.
  final AdsGateway? ads;

  @override
  State<ArcoApp> createState() => _ArcoAppState();
}

class _ArcoAppState extends State<ArcoApp> {
  /// Every named route the app can show.
  static final Map<String, WidgetBuilder> routes = <String, WidgetBuilder>{
    HomeScreen.route: (_) => const HomeScreen(),
    OnboardingScreen.route: (_) => const OnboardingScreen(),
    SoloScreen.route: (_) => const SoloScreen(),
    DuelLobbyScreen.route: (_) => const DuelLobbyScreen(),
    LeaderboardScreen.route: (_) => const LeaderboardScreen(),
    SettingsScreen.route: (_) => const SettingsScreen(),
    ShopScreen.route: (_) => const ShopScreen(),
  };

  late final ApiClient _api;
  late final Haptics _haptics;
  late final PlayerIdentity _identity;
  late final AccountService _accounts;
  late final ShopService _shop;
  late final PurchaseService _purchases;
  late final AdsService _ads;

  /// Where the app opens. Read once, at launch: the selector below rebuilds
  /// [MaterialApp] whenever the theme or the language changes, and the
  /// navigator keeps the stack it already has.
  late final String _initialRoute;

  @override
  void initState() {
    super.initState();
    _initialRoute = widget.settings.onboarded
        ? HomeScreen.route
        : OnboardingScreen.route;
    // The closure is re-read on every call, so changing the server URL in
    // Settings takes effect immediately.
    _api = ApiClient(baseUrl: () => widget.settings.effectiveBaseUrl);
    _haptics = Haptics(widget.settings);
    // Reads the stored credential on first use and issues one only when a score
    // is actually submitted (SPEC §4.4) - nothing here talks to the server.
    _identity = PlayerIdentity(
      api: _api,
      storage: widget.storage,
      secrets: widget.secrets ?? KeychainSecretStore(),
    );
    // Sign in with Apple / Google (SPEC §4.5). Nothing here talks to a provider
    // or to the server: the first call happens when a screen that could offer an
    // account asks which ones the deployment accepts.
    _accounts = AccountService(
      api: _api,
      identity: _identity,
      native: widget.signIn ?? PlatformSignIn(),
      offer: AccountOffer(storage: widget.storage),
      storage: widget.storage,
    );
    widget.settings.addListener(_onSettingsChanged);
    // The cosmetic shop (SPEC 4.8). Nothing here talks to the server either: the
    // last known wallet and the equipped items are read from storage
    // synchronously, so the game opens wearing what the player bought even with
    // no network, and the first request happens when a screen asks for one.
    _shop = ShopService(
      api: _api,
      identity: _identity,
      storage: widget.storage,
      settings: widget.settings,
    );
    // Buying Sparks with real money (SPEC §4.9). Nothing here touches StoreKit
    // or the network at construction: the store is first asked for its prices
    // when the shop screen opens, and only if the server said there are packs
    // to price. A build with no RevenueCat keys never calls in at all.
    _purchases = PurchaseService(
      gateway: widget.purchases ?? RevenueCatPurchases(),
      api: _api,
      identity: _identity,
      shop: _shop,
    );
    // Rewarded ads that pay Sparks (SPEC §4.10). Nothing here touches the Mobile
    // Ads SDK, the UMP SDK or the network at construction: the first call happens
    // when a screen that could offer an ad asks — the shop, or a finished solo run
    // — and only then is consent checked and an ad preloaded. A build with no
    // AdMob unit never calls in at all, and a player who never finishes a run
    // never starts the ads SDK.
    _ads = AdsService(
      gateway: widget.ads ?? GoogleRewardedAds(),
      api: _api,
      identity: _identity,
      shop: _shop,
    );
    // A solo score recorded while offline is retried once at app start; the
    // leaderboard and the solo screen retry it again when they open.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.storage.pendingReplay == null) return;
      final outcome = await ScoreSubmitter(
        api: _api,
        storage: widget.storage,
        identity: _identity,
      ).retryPending();
      // A replay that finally landed paid into the wallet (SPEC 4.8); the
      // balance the server reported is worth keeping, so the title screen shows
      // it without another request.
      if (outcome is SubmitAccepted && outcome.tokens != null) {
        await _shop.noteRun(
          tokens: outcome.tokens,
          balance: outcome.tokenBalance,
        );
      }
    });
  }

  void _onSettingsChanged() => widget.audio.muted = !widget.settings.sound;

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    _ads.dispose();
    _purchases.dispose();
    _shop.dispose();
    _identity.dispose();
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<Storage>.value(value: widget.storage),
        ChangeNotifierProvider<Settings>.value(value: widget.settings),
        Provider<AudioService>.value(value: widget.audio),
        Provider<Haptics>.value(value: _haptics),
        Provider<ApiClient>.value(value: _api),
        ChangeNotifierProvider<PlayerIdentity>.value(value: _identity),
        Provider<AccountService>.value(value: _accounts),
        ChangeNotifierProvider<ShopService>.value(value: _shop),
        ChangeNotifierProvider<PurchaseService>.value(value: _purchases),
        ChangeNotifierProvider<AdsService>.value(value: _ads),
      ],
      // SPEC 5.6: the language follows the Settings override, so the app
      // locale is rebuilt with it and Material's own strings (text selection
      // menu, back tooltip) follow the switch alongside [Strings].
      //
      // The selector also carries the chosen [GameTheme]: it is provided above
      // the navigator, so switching it in Settings repaints every screen, every
      // widget and the arena live. A record of the two keeps unrelated setting
      // changes (a slider drag) from rebuilding the whole app.
      child: Selector<Settings, (AppLanguage, GameTheme)>(
        selector: (_, settings) => (settings.language, settings.theme),
        builder: (context, value, _) {
          final (language, theme) = value;
          return Provider<GameTheme>.value(
            value: theme,
            // The status bar sits on the theme's own background, with nothing
            // drawn behind it: on Modernist's paper, white system glyphs are
            // invisible. Screens with an AppBar get the same answer from
            // `appBarTheme.systemOverlayStyle`, since an AppBar posts its own
            // annotation over this one.
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: systemOverlayStyleFor(theme),
              // The equipped ball and paddle (SPEC 4.8), provided above the
              // navigator exactly like the theme: buying a skin in the shop
              // repaints the arena on the next frame without anything below
              // having to be told. The `child` is built once — an equip must not
              // rebuild [MaterialApp] and disturb the navigator's stack.
              child: Selector<ShopService, Equipped>(
                selector: (_, shop) => shop.equipped,
                builder: (context, equipped, child) =>
                    Provider<Equipped?>.value(value: equipped, child: child!),
                child: MaterialApp(
                  title: 'Arco',
                  debugShowCheckedModeBanner: false,
                  theme: buildAppTheme(theme),
                  // The GameTheme provided above switches instantly, so Material must
                  // not cross-fade its own colours behind it: half a second of a navy
                  // scaffold under off-white panels reads as a glitch.
                  themeAnimationDuration: Duration.zero,
                  supportedLocales: const [Locale('en'), Locale('pl')],
                  // Material/Cupertino/Widgets localizations must be installed for
                  // every declared locale: TextField and other Material widgets look
                  // them up.
                  localizationsDelegates: const [
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  locale: Strings.localeFor(language),
                  initialRoute: _initialRoute,
                  // A first launch opens the welcome screen *instead of* home, not
                  // on top of it: Navigator's default expansion of a '/welcome'
                  // initial route would push '/' underneath it, which builds the
                  // home screen — and its nickname field, which reads the name
                  // once — before the player has chosen one.
                  onGenerateInitialRoutes: (route) => <Route<void>>[
                    MaterialPageRoute<void>(
                      settings: RouteSettings(name: route),
                      builder: routes[route]!,
                    ),
                  ],
                  routes: routes,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
