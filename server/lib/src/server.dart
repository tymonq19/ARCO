/// Wires config, storage, rooms and the HTTP handler into one startable unit
/// (used by `bin/server.dart` and by the tests).
library;

import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;

import 'accounts.dart';
import 'ads.dart';
import 'api.dart';
import 'catalogue.dart';
import 'config.dart';
import 'id_token.dart';
import 'leaderboard.dart';
import 'logging.dart';
import 'players.dart';
import 'purchases.dart';
import 'rate_limit.dart';
import 'rooms.dart';
import 'score_store.dart';
import 'shop.dart';
import 'session.dart';
import 'tokens.dart';
import 'version.dart';

class ArcoServer {
  ArcoServer({
    required this.config,
    Logger? log,
    InternetAddress? address,
    int tickMultiplier = 1,
    Duration roomIdleTimeout = const Duration(minutes: 10),
    Duration roomSweepInterval = const Duration(seconds: 30),
    int maxRooms = maxLiveRooms,
    int maxSessions = maxLiveSessions,
    int maxSessionsPerIp = maxLiveSessionsPerIp,
    Duration helloTimeout = helloDeadline,
    Duration wsPingInterval = webSocketPingInterval,
    RateLimiter? createLimiter,
    RateLimiter? joinMissLimiter,
    RateLimiter? submitLimiter,
    RateLimiter? upgradeLimiter,
    RateLimiter? playerLimiter,
    RateLimiter? accountLimiter,
    RateLimiter? shopLimiter,
    RateLimiter? purchaseLimiter,
    RateLimiter? adLimiter,
    Duration apiSweepInterval = const Duration(seconds: 30),
    JwksFetcher? fetchSigningKeys,
    Uri? appleJwksUri,
    Uri? googleJwksUri,
    Uri? revenueCatBaseUri,
    RevenueCatFetcher? fetchRevenueCat,
    JwksFetcher? fetchAdMobKeys,
  }) : log = log ?? Logger(config.logLevel),
       _address = address,
       _tickMultiplier = tickMultiplier,
       _roomIdleTimeout = roomIdleTimeout,
       _roomSweepInterval = roomSweepInterval,
       _maxRooms = maxRooms,
       _maxSessions = maxSessions,
       _maxSessionsPerIp = maxSessionsPerIp,
       _helloTimeout = helloTimeout,
       _wsPingInterval = wsPingInterval,
       _createLimiter = createLimiter,
       _joinMissLimiter = joinMissLimiter,
       _submitLimiter = submitLimiter,
       _upgradeLimiter = upgradeLimiter,
       _playerLimiter = playerLimiter,
       _accountLimiter = accountLimiter,
       _shopLimiter = shopLimiter,
       _purchaseLimiter = purchaseLimiter,
       _adLimiter = adLimiter,
       _apiSweepInterval = apiSweepInterval,
       _fetchSigningKeys = fetchSigningKeys,
       _appleJwksUri = appleJwksUri,
       _googleJwksUri = googleJwksUri,
       _revenueCatBaseUri = revenueCatBaseUri,
       _fetchRevenueCat = fetchRevenueCat,
       _fetchAdMobKeys = fetchAdMobKeys;

  final ServerConfig config;
  final Logger log;

  /// Explicit bind address; null → `config.host`, null → all IPv4 interfaces.
  final InternetAddress? _address;

  /// TEST-ONLY HOOK, forwarded to [RoomRegistry.tickMultiplier]: `n` makes
  /// rooms advance at `n × 60` ticks per real second so an end-to-end test can
  /// play a whole duel in a couple of seconds. Production always uses 1.
  final int _tickMultiplier;
  final Duration _roomIdleTimeout;
  final Duration _roomSweepInterval;

  /// Room cap and room-creation limiter; overridable so tests can reach them
  /// without opening 500 rooms.
  final int _maxRooms;
  final RateLimiter? _createLimiter;

  /// Per-IP budget for `join`s naming no live room; overridable so tests can
  /// reach it without spending the production budget.
  final RateLimiter? _joinMissLimiter;

  /// Session caps, `hello` deadline and WebSocket keep-alive period;
  /// overridable so the tests can reach them without 2000 sockets or a 15 s
  /// wait.
  final int _maxSessions;
  final int _maxSessionsPerIp;
  final Duration _helloTimeout;
  final Duration _wsPingInterval;

  /// Score-submission, `/ws`-upgrade and player-issuing limiters, and how
  /// often their expired keys are dropped; overridable so tests can drive the
  /// sweeper with a fake clock.
  final RateLimiter? _submitLimiter;
  final RateLimiter? _upgradeLimiter;
  final RateLimiter? _playerLimiter;
  final RateLimiter? _accountLimiter;
  final RateLimiter? _shopLimiter;
  final RateLimiter? _purchaseLimiter;
  final RateLimiter? _adLimiter;
  final Duration _apiSweepInterval;

  /// TEST-ONLY HOOKS: where a provider's signing keys come from. The tests
  /// point these at a fake key server on loopback so no test ever depends on
  /// Apple or Google being reachable. Production leaves them null and the
  /// providers use their published HTTPS endpoints.
  final JwksFetcher? _fetchSigningKeys;
  final Uri? _appleJwksUri;
  final Uri? _googleJwksUri;

  /// TEST-ONLY HOOKS: where RevenueCat's REST API is (SPEC §4.9). The tests point
  /// these at a fake RevenueCat on loopback, so no test ever reaches the real
  /// one — and no test needs a real API key. Production leaves them null and the
  /// service talks to `api.revenuecat.com` over HTTPS.
  final Uri? _revenueCatBaseUri;
  final RevenueCatFetcher? _fetchRevenueCat;

  /// TEST-ONLY HOOK: where AdMob's published verifier keys come from
  /// (SPEC §4.10). The tests point this at a fake key server on loopback serving
  /// a keypair they generated, so the whole signature path is exercised without
  /// ever reaching gstatic and without an AdMob account. Production leaves it null
  /// and the cache fetches `AdsConfig.defaultKeysUrl` over HTTPS.
  final JwksFetcher? _fetchAdMobKeys;

  ScoreStore? _store;
  RoomRegistry? _rooms;
  LeaderboardService? _leaderboard;
  PlayerService? _players;
  AccountService? _accounts;
  ShopService? _shop;
  PurchaseService? _purchases;
  AdsService? _ads;
  ApiHandler? _api;
  HttpServer? _http;

  ScoreStore get store => _store!;
  RoomRegistry get rooms => _rooms!;
  LeaderboardService get leaderboard => _leaderboard!;
  PlayerService get players => _players!;
  AccountService get accounts => _accounts!;
  ShopService get shop => _shop!;
  PurchaseService get purchases => _purchases!;
  AdsService get ads => _ads!;
  ApiHandler get api => _api!;

  bool get isRunning => _http != null;

  /// Bound port (valid after [start]); with `config.port == 0` the OS picks it.
  int get port => _http?.port ?? config.port;

  /// Address the socket is bound to (valid after [start]).
  InternetAddress get address =>
      _http?.address ?? _address ?? InternetAddress.anyIPv4;

  /// Base URL of the REST API, e.g. `http://127.0.0.1:8080`.
  String get baseUrl {
    final host = address.type == InternetAddressType.IPv6
        ? '[${address.address}]'
        : address.address;
    return 'http://$host:$port';
  }

  Future<void> start() async {
    if (_http != null) return;
    final bindTo = _address ?? await _resolveHost(config.host);
    // Storage lives on its own isolate: a query or a blocked write must never
    // stop this isolate from ticking rooms and answering requests.
    final store = await ScoreStore.open(config.dbPath);
    _store = store;
    final rooms = RoomRegistry(
      log: log,
      tickMultiplier: _tickMultiplier,
      idleTimeout: _roomIdleTimeout,
      sweepInterval: _roomSweepInterval,
      maxRooms: _maxRooms,
      maxSessions: _maxSessions,
      maxSessionsPerIp: _maxSessionsPerIp,
      helloTimeout: _helloTimeout,
      createLimiter: _createLimiter,
      joinMissLimiter: _joinMissLimiter,
    );
    _rooms = rooms;
    final leaderboard = LeaderboardService(
      store: store,
      verifyReplays: config.verifyReplays,
      log: log,
    );
    _leaderboard = leaderboard;
    final players = PlayerService(store: store, log: log);
    _players = players;
    final accounts = AccountService(
      store: store,
      players: players,
      providers: accountProvidersFor(
        config.accounts,
        log: log,
        fetch: _fetchSigningKeys,
        appleJwksUri: _appleJwksUri,
        googleJwksUri: _googleJwksUri,
      ),
      log: log,
    );
    _accounts = accounts;
    // The one-time unlock (SPEC §4.9). Constructed whether or not it is switched
    // on: with `PURCHASES_ENABLED` off it advertises no product at all and its
    // two routes answer `purchases_disabled`, which is one code path rather than
    // a conditionally wired server.
    final purchases = PurchaseService(
      store: store,
      config: config.purchases,
      log: log,
      revenueCatBaseUri: _revenueCatBaseUri,
      fetchRevenueCat: _fetchRevenueCat,
    );
    _purchases = purchases;
    // The shop advertises the unlock, and takes no money for it: whether there is
    // a product to show is a deployment question only `PurchaseService` can
    // answer, so it is handed the answer rather than reading `FullUnlock` itself.
    final shop = ShopService(
      store: store,
      log: log,
      unlock: purchases.unlockFor,
    );
    _shop = shop;
    // Rewarded ads that pay Sparks (SPEC §4.10). Constructed whether or not it is
    // switched on, exactly like purchases: with `ADS_ENABLED` off its two routes
    // answer `ads_disabled`, no client offers an ad, and nothing is fetched from
    // Google. Nothing here touches the network at construction — the verifier keys
    // are fetched on the first callback that needs them.
    final ads = AdsService(
      store: store,
      config: config.ads,
      log: log,
      fetchKeys: _fetchAdMobKeys,
    );
    _ads = ads;
    final api = ApiHandler(
      leaderboard: leaderboard,
      players: players,
      accounts: accounts,
      shop: shop,
      purchases: purchases,
      ads: ads,
      rooms: rooms,
      log: log,
      submitLimiter: _submitLimiter,
      upgradeLimiter: _upgradeLimiter,
      playerLimiter: _playerLimiter,
      accountLimiter: _accountLimiter,
      shopLimiter: _shopLimiter,
      purchaseLimiter: _purchaseLimiter,
      adLimiter: _adLimiter,
      sweepInterval: _apiSweepInterval,
      pingInterval: _wsPingInterval,
    );
    _api = api;

    rooms.start();
    api.start();
    try {
      _http = await shelf_io.serve(api.handler, bindTo, config.port);
    } catch (_) {
      api.close();
      await rooms.close();
      await store.close();
      _rooms = null;
      _store = null;
      _leaderboard = null;
      _players = null;
      _accounts = null;
      _shop = null;
      _purchases = null;
      _ads = null;
      _api = null;
      rethrow;
    }
    if (!config.verifyReplays) {
      log.warn('VERIFY_REPLAYS=off: scores are stored WITHOUT verification');
    }
    if (config.accounts.hasUnusedClientIds) {
      log.warn(
        'client ids are configured but ACCOUNTS_ENABLED is not "on": '
        'Sign in with Apple / Google is switched OFF',
      );
    }
    log.info(
      accounts.enabled
          ? 'accounts enabled: ${accounts.providerNames.join(', ')}'
          : 'accounts disabled (ACCOUNTS_ENABLED=off)',
    );
    if (config.purchases.hasUnusedKeys) {
      log.warn(
        'RevenueCat keys are configured but PURCHASES_ENABLED is not "on": '
        'the one-time unlock is switched OFF',
      );
    }
    log.info(
      purchases.enabled
          ? 'purchases enabled: ${FullUnlock.productId} '
                '(entitlement "${FullUnlock.premiumEntitlement}"), '
                'sandbox ${config.purchases.creditSandbox ? 'granted' : 'ignored'}'
          : 'purchases disabled (PURCHASES_ENABLED=off)',
    );
    if (config.ads.hasUnusedSettings) {
      log.warn(
        'AdMob settings are configured but ADS_ENABLED is not "on": '
        'rewarded ads are switched OFF',
      );
    }
    log.info(
      ads.enabled
          ? 'ads enabled: ${AdRate.sparksPerAd} sparks per ad, '
                '${AdRate.dailyCap}/day, ${AdRate.cooldown.inMinutes} min '
                'cooldown, keys ${config.ads.keysUri}'
                '${config.ads.requiresKey ? ', arco_key required' : ''}'
          : 'ads disabled (ADS_ENABLED=off)',
    );
    log.info(
      'arco_server $serverVersion db=${config.dbPath} '
      '(${await store.count()} scores, ${await store.playerCount()} players) '
      'tick=x$_tickMultiplier',
    );
  }

  /// Graceful shutdown: stop the tick driver, close every WebSocket, drain
  /// in-flight HTTP requests (forced after 3 s) and close the database.
  Future<void> stop() async {
    final http = _http;
    _http = null;
    _api?.close();
    await _rooms?.close();
    _rooms = null;
    if (http != null) {
      try {
        await http.close().timeout(const Duration(seconds: 3));
      } on TimeoutException {
        await http.close(force: true);
      }
    }
    await _store?.close();
    _store = null;
    _leaderboard = null;
    _players = null;
    _accounts = null;
    _shop = null;
    _purchases = null;
    _ads = null;
    _api = null;
  }

  static Future<InternetAddress> _resolveHost(String? host) async {
    if (host == null || host.isEmpty) return InternetAddress.anyIPv4;
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return literal;
    final resolved = await InternetAddress.lookup(host);
    if (resolved.isEmpty) throw StateError('cannot resolve HOST "$host"');
    return resolved.first;
  }
}
