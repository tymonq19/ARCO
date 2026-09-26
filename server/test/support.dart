/// Shared helpers for the server tests: booting a server on an ephemeral port,
/// driving WebSocket clients and recording verifiable solo replays.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Default budget for "the next message must arrive".
const Duration receiveTimeout = Duration(seconds: 20);

/// A logger that swallows everything (tests assert on behaviour, not on logs).
Logger silentLogger() => Logger(LogLevel.error, sink: (_) {});

/// Boots a server on 127.0.0.1 with an ephemeral port and an in-memory
/// database, and stops it when the test ends.
///
/// [tickMultiplier] is the test-only speed knob documented on
/// [ArcoServer]: rooms advance at `tickMultiplier × 60` sim ticks per
/// real second, which lets a full duel play out in a couple of seconds.
///
/// [dbPath] overrides the in-memory database, which is what the migration test
/// needs: it boots against a file written by the old schema.
///
/// [accounts] switches Sign in with Apple / Google on (SPEC §4.5); it is off by
/// default, exactly as a deployment with no client ids configured is. When it is
/// on, [appleJwksUri] / [googleJwksUri] must point at a [FakeKeyServer] (or
/// [fetchSigningKeys] must answer), so no test ever reaches a real provider.
///
/// [purchases] switches the one-time unlock on (SPEC §4.9), off by default in
/// the same way. When it is on, [revenueCatBaseUri] should point at a
/// [FakeRevenueCat] on loopback: no test ever reaches the real RevenueCat, and
/// none needs a real API key.
///
/// [ads] switches rewarded ads that pay Sparks on (SPEC §4.10), off by default in
/// the same way. Its `keysUrl` should point at a [FakeAdMobKeyServer] (see
/// `ads_support.dart`), so the whole signature path runs against a keypair the
/// test generated and no test ever reaches gstatic or needs an AdMob account.
Future<ArcoServer> bootServer({
  int tickMultiplier = 1,
  bool verifyReplays = true,
  String dbPath = ':memory:',
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
  AccountsConfig accounts = const AccountsConfig(),
  PurchasesConfig purchases = const PurchasesConfig(),
  AdsConfig ads = const AdsConfig(),
  JwksFetcher? fetchSigningKeys,
  Uri? appleJwksUri,
  Uri? googleJwksUri,
  Uri? revenueCatBaseUri,
  RevenueCatFetcher? fetchRevenueCat,
  JwksFetcher? fetchAdMobKeys,
}) async {
  final server = ArcoServer(
    config: ServerConfig(
      port: 0,
      dbPath: dbPath,
      verifyReplays: verifyReplays,
      logLevel: LogLevel.error,
      accounts: accounts,
      purchases: purchases,
      ads: ads,
    ),
    log: silentLogger(),
    address: InternetAddress.loopbackIPv4,
    tickMultiplier: tickMultiplier,
    roomIdleTimeout: roomIdleTimeout,
    roomSweepInterval: roomSweepInterval,
    maxRooms: maxRooms,
    maxSessions: maxSessions,
    maxSessionsPerIp: maxSessionsPerIp,
    helloTimeout: helloTimeout,
    wsPingInterval: wsPingInterval,
    createLimiter: createLimiter,
    joinMissLimiter: joinMissLimiter,
    submitLimiter: submitLimiter,
    upgradeLimiter: upgradeLimiter,
    playerLimiter: playerLimiter,
    accountLimiter: accountLimiter,
    shopLimiter: shopLimiter,
    purchaseLimiter: purchaseLimiter,
    adLimiter: adLimiter,
    apiSweepInterval: apiSweepInterval,
    fetchSigningKeys: fetchSigningKeys,
    appleJwksUri: appleJwksUri,
    googleJwksUri: googleJwksUri,
    revenueCatBaseUri: revenueCatBaseUri,
    fetchRevenueCat: fetchRevenueCat,
    fetchAdMobKeys: fetchAdMobKeys,
  );
  await server.start();
  addTearDown(server.stop);
  return server;
}

/// Polls [condition] until it holds or [timeout] expires.
Future<void> pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail(
        'condition not met within $timeout${reason == null ? '' : ': $reason'}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A WebSocket client with a buffered, typed inbox.
class TestClient {
  TestClient._(this.channel) {
    _sub = channel.stream.listen(
      _deliver,
      onError: (Object e) => _finish(e),
      onDone: () => _finish(null),
    );
  }

  /// Connects to `/ws`; when [name] is given, performs the `hello` handshake.
  static Future<TestClient> connect(ArcoServer server, {String? name}) async {
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://${server.address.address}:${server.port}/ws'),
    );
    await channel.ready;
    final client = TestClient._(channel);
    addTearDown(client.dispose);
    if (name != null) await client.hello(name);
    return client;
  }

  final WebSocketChannel channel;
  late final StreamSubscription<dynamic> _sub;

  /// Parsed [ServerMsg]s, or the raw frame when it could not be parsed.
  final List<Object> _inbox = <Object>[];

  /// Every text frame the server sent, decoded as JSON and in arrival order.
  ///
  /// Kept alongside the parsed inbox because a frame may carry fields core's
  /// `ServerMsg.parse` does not model yet — the duel ball count (SPEC §3) is
  /// one — and a test that asserts on such a field has to see the frame itself.
  final List<Map<String, dynamic>> jsonFrames = <Map<String, dynamic>>[];
  final List<Completer<Object>> _waiters = <Completer<Object>>[];
  final Completer<void> _closed = Completer<void>();
  bool _done = false;
  Object? _error;

  /// Completes when the server (or [close]) ended the connection.
  Future<void> get closed => _closed.future;
  bool get isClosed => _done;
  int? get closeCode => channel.closeCode;
  int get pending => _inbox.length;

  void sendRaw(Object frame) => channel.sink.add(frame);

  void send(ClientMsg msg) => sendRaw(encodeMsg(msg));

  /// The newest frame of type [t] the server has sent, as raw JSON.
  Map<String, dynamic> jsonOf(String t) {
    for (final frame in jsonFrames.reversed) {
      if (frame['t'] == t) return frame;
    }
    fail(
      'no "$t" frame received (got ${[for (final f in jsonFrames) f['t']]})',
    );
  }

  /// Sends `create`, optionally asking for [balls] balls (SPEC §3).
  ///
  /// Written as a raw frame because the ball count travels in a field core's
  /// [CreateRoomMsg] does not carry yet; omitting [balls] sends exactly the
  /// frame [CreateRoomMsg] encodes.
  void createRoom({int? balls}) =>
      sendRaw(jsonEncode({'t': 'create', ballCountField: ?balls}));

  Future<void> hello(String name, {int version = protocolVersion}) async {
    send(HelloMsg(version: version, name: name));
    await nextOf<WelcomeMsg>();
  }

  /// The next frame, whatever it is.
  Future<ServerMsg> next({Duration timeout = receiveTimeout}) async {
    final item = await _take(timeout);
    if (item is ServerMsg) return item;
    fail('unparsable server frame: $item');
  }

  /// The next message of type [T]. Snapshots and pongs in between are skipped
  /// (unless [T] is one of them); anything else fails the test.
  Future<T> nextOf<T extends ServerMsg>({
    Duration timeout = receiveTimeout,
  }) async {
    final watch = Stopwatch()..start();
    while (true) {
      final left = timeout - watch.elapsed;
      if (left <= Duration.zero) fail('no $T within $timeout');
      final msg = await next(timeout: left);
      if (msg is T) return msg;
      if (msg is SnapMsg || msg is PongMsg) continue;
      fail('expected $T, got ${msg.toJson()}');
    }
  }

  /// Closes the client side of the socket.
  Future<void> close([int code = 1000]) => channel.sink.close(code);

  Future<void> dispose() async {
    await _sub.cancel();
    try {
      await channel.sink.close();
    } catch (_) {
      // Already gone.
    }
  }

  void _deliver(Object? frame) {
    if (frame is String) {
      jsonFrames.addAll([?decodeFrame(frame)]);
    }
    final Object item =
        (frame is String ? ServerMsg.decode(frame) : null) ?? '$frame';
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(item);
    } else {
      _inbox.add(item);
    }
  }

  void _finish(Object? error) {
    if (_done) return;
    _done = true;
    _error = error;
    final waiters = List<Completer<Object>>.of(_waiters);
    _waiters.clear();
    for (final w in waiters) {
      w.completeError(StateError(_closedMessage));
    }
    if (!_closed.isCompleted) _closed.complete();
  }

  String get _closedMessage =>
      'socket closed (code ${channel.closeCode})${_error == null ? '' : ': $_error'}';

  Future<Object> _take(Duration timeout) {
    if (_inbox.isNotEmpty) return Future<Object>.value(_inbox.removeAt(0));
    if (_done) return Future<Object>.error(StateError(_closedMessage));
    final completer = Completer<Object>();
    _waiters.add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(completer);
        throw TimeoutException('no frame within $timeout');
      },
    );
  }
}

/// Plays a full solo game with the core and returns a replay that
/// [ReplayVerifier] accepts.
///
/// [controller] supplies the input for each tick (default: [PlayerInput.none],
/// i.e. the paddle never moves, so the game ends in a few hundred ticks).
Replay recordSoloReplay({
  int seed = 20260923,
  int ballCount = minBallCount,
  PlayerInput Function(GameState state)? controller,
}) {
  final state = GameState.initial(
    GameConfig(mode: GameMode.solo, seed: seed, ballCount: ballCount),
  );
  final log = InputLog();
  final inputs = <PlayerInput>[PlayerInput.none];
  while (state.phase != Phase.gameOver &&
      state.tick < ReplayVerifier.maxTicks) {
    final input = controller?.call(state) ?? PlayerInput.none;
    log.record(state.tick, input);
    inputs[0] = input;
    Simulation.step(state, inputs);
  }
  return Replay(
    config: state.config,
    inputs: <InputLog>[log],
    finalTick: state.tick,
    claimedScore: state.players[0].score,
  );
}

/// A solo replay that actually **scores**, for the token tests (SPEC §4.8).
///
/// [recordSoloReplay] leaves the paddle still, which ends the game in a few
/// hundred ticks for a score under 20 — below the earning threshold, so it can
/// never pay a token. This plays properly instead: the paddle chases the ball
/// that is nearest the rim, but from where that ball was [reactionTicks] ticks
/// ago, which is what makes it eventually lose. Measured with the defaults:
/// ~4 240 ticks (71 s) and a verified score of 2 218, in a 35 KB body — a
/// realistic good run, well inside the 2 MB submission cap.
///
/// A smaller [reactionTicks] plays better and scores more; below about 14 the
/// one-ball paddle stops losing at all and the game runs into
/// `ReplayVerifier.maxTicks` with an input log too large to submit, which is
/// itself worth knowing.
///
/// With [ballCount] 2 the same paddle has two balls to meet and loses much
/// sooner, so the default reaction is shorter there: 12 ticks, which measures at
/// ~1 900 ticks and a verified score around 2 900 — a real two-ball run that
/// earns real Sparks, which is what the board and the wallet tests need.
Replay recordScoringSoloReplay({
  int seed = 20260923,
  int ballCount = minBallCount,
  int? reactionTicks,
}) {
  final reaction = reactionTicks ?? (ballCount > 1 ? 12 : 16);
  final history = <double>[];
  return recordSoloReplay(
    seed: seed,
    ballCount: ballCount,
    controller: (state) {
      // The ball closest to escaping is the one that has to be met; with one
      // ball this is exactly "chase the ball".
      Ball? target;
      var furthest = -1.0;
      for (final ball in state.balls) {
        if (!ball.active) continue;
        final r = ball.x * ball.x + ball.y * ball.y;
        if (r > furthest) {
          furthest = r;
          target = ball;
        }
      }
      history.add(
        target == null
            ? (history.isEmpty ? 0.0 : history.last)
            : DetMath.atan2(target.y, target.x),
      );
      final index = history.length - 1 - reaction;
      return PlayerInput.aimAngle(history[index < 0 ? 0 : index]);
    },
  );
}

/// Request body for `POST /api/scores`.
Map<String, dynamic> scoreBody(String name, Replay replay) => {
  'name': name,
  'replay': replay.toJson(),
};

/// Issues an anonymous player through `POST /api/players` (SPEC §4.4) and
/// returns the decoded body, which carries `id` and `secret`.
Future<Map<String, dynamic>> issuePlayer(
  ArcoServer server, {
  String? name,
}) async {
  final response = await http.post(
    Uri.parse('${server.baseUrl}/api/players'),
    headers: {'content-type': 'application/json'},
    body: name == null ? null : jsonEncode({'name': name}),
  );
  expect(response.statusCode, 201, reason: response.body);
  return jsonDecode(response.body) as Map<String, dynamic>;
}

/// A 32-hex player id of the shape `POST /api/players` issues, without issuing
/// one: for the cases that need an id nobody holds.
String testPlayerId(int n) => n.toRadixString(16).padLeft(32, '0');

/// The `Authorization` value for credentials issued by [issuePlayer].
String playerAuth(String id, String secret) => '$playerAuthScheme $id:$secret';

/// The `Authorization` value for a whole `POST /api/players` response body, or
/// for a `POST /api/account/link` one — both carry `id` and `secret`.
String authOf(Map<String, dynamic> issued) =>
    playerAuth(issued['id'] as String, issued['secret'] as String);

/// Credits [tokens] to [playerId] through the **real** earning path (SPEC §4.8).
///
/// There is deliberately no endpoint that hands out tokens, so a test that needs
/// a balance earns one: this calls the same storage operation `POST /api/scores`
/// calls, with a verified score of its own. A run pays at most
/// [TokenRate.maxTokensPerRun] and a day at most [TokenRate.dailyCap], so the
/// helper spends as many runs as it takes and steps back a day whenever the
/// allowance is used up.
///
/// The grants are dated in the past ([from]) so that they never consume *today's*
/// allowance, which is what the daily-cap tests measure. Two players granted from
/// the same [from] land on the same days, which is itself worth being able to
/// arrange: a merge re-applies the daily cap to the union of the two ledgers.
Future<void> grantTokens(
  ArcoServer server,
  String playerId,
  int tokens, {
  DateTime? from,
}) async {
  var remaining = tokens;
  var day = from ?? DateTime.utc(2020, 1, 1, 12);
  var earnedThatDay = 0;
  var run = 0;
  while (remaining > 0) {
    if (earnedThatDay >= TokenRate.dailyCap) {
      day = day.subtract(const Duration(days: 1));
      earnedThatDay = 0;
    }
    var want = remaining;
    if (want > TokenRate.maxTokensPerRun) want = TokenRate.maxTokensPerRun;
    final leftToday = TokenRate.dailyCap - earnedThatDay;
    if (want > leftToday) want = leftToday;
    final award = await server.store.awardTokens(
      playerId: playerId,
      scoreId: 'grant-$run',
      score: want * TokenRate.scorePerToken,
      replayKey: 'grant-$playerId-$run',
      now: day,
    );
    expect(award.tokens, want, reason: 'the grant helper must not be capped');
    remaining -= award.tokens;
    earnedThatDay += award.tokens;
    run++;
  }
  expect(
    await server.store.walletBalance(playerId),
    greaterThanOrEqualTo(tokens),
  );
}

/// A stand-in for RevenueCat's REST API on loopback (SPEC §4.9).
///
/// Everything about the unlock that is worth testing is on *our* side of the
/// line: who becomes premium, from which transaction, exactly once, and what a
/// refund takes back. None of it should depend on RevenueCat being reachable, and
/// a test must never need a real secret API key. So the server is pointed at
/// this, over plain HTTP on 127.0.0.1 — which `isFetchableRevenueCatUri` allows
/// for exactly this reason and for nothing else.
///
/// It serves `GET /v1/subscribers/{app_user_id}`, the one call the server makes,
/// in the shape RevenueCat really answers it: a `subscriber` object whose
/// `non_subscriptions` map goes product id → list of purchases (a non-consumable
/// lives there, which is what makes a restore possible) and whose `entitlements`
/// map is what RevenueCat itself thinks the customer holds.
class FakeRevenueCat {
  FakeRevenueCat._(this._server) {
    _server.listen((request) async {
      requests++;
      paths.add(request.uri.path);
      authorizations.add(
        request.headers.value(HttpHeaders.authorizationHeader),
      );
      await request.drain<void>();
      final response = request.response;
      final failWith = status;
      if (failWith != null) {
        response.statusCode = failWith;
        await response.close();
        return;
      }
      // RevenueCat answers 404 for an app user it has never seen, which is every
      // player who has never bought anything. The server reads that as "nothing
      // bought", not as a failure.
      final appUserId = Uri.decodeComponent(
        request.uri.pathSegments.isEmpty ? '' : request.uri.pathSegments.last,
      );
      final owned = purchases[appUserId];
      if (owned == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final byProduct = <String, List<Map<String, dynamic>>>{};
      for (final purchase in owned) {
        byProduct.putIfAbsent(purchase.productId, () => []).add({
          'id': 'rc_${purchase.transactionId}',
          'is_sandbox': purchase.sandbox,
          'purchase_date': purchase.purchasedAt.toIso8601String(),
          'store': purchase.store,
          // Omitted when the test is asking what happens to a transaction
          // RevenueCat reports without a store id, which must not be credited.
          if (!purchase.withoutStoreTransactionId)
            'store_transaction_id': purchase.transactionId,
        });
      }
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'request_date': '2026-09-24T12:00:00Z',
          'subscriber': {
            'original_app_user_id': appUserId,
            'first_seen': '2026-09-01T12:00:00Z',
            'entitlements': <String, dynamic>{
              for (final id in entitlements[appUserId] ?? const <String>{})
                id: <String, dynamic>{
                  'product_identifier': FullUnlock.productId,
                  // Null is what a non-consumable's entitlement carries: it does
                  // not expire.
                  'expires_date': null,
                  'purchase_date': '2026-09-24T11:00:00Z',
                },
            },
            'subscriptions': <String, dynamic>{},
            'non_subscriptions': byProduct,
          },
        }),
      );
      await response.close();
    });
  }

  static Future<FakeRevenueCat> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeRevenueCat._(server);
    addTearDown(fake.stop);
    return fake;
  }

  final HttpServer _server;

  /// What RevenueCat "knows": app user id → its non-subscription purchases. An
  /// app user id that is absent is answered with a 404, as the real one does.
  final Map<String, List<FakeStorePurchase>> purchases =
      <String, List<FakeStorePurchase>>{};

  /// The **entitlements** RevenueCat reports as held, per app user id.
  ///
  /// Kept separate from [purchases] on purpose, because the interesting case is
  /// the two disagreeing: RevenueCat saying somebody is entitled while no
  /// transaction backs it is a misconfigured product, and the server must log it
  /// rather than grant premium from it.
  final Map<String, Set<String>> entitlements = <String, Set<String>>{};

  /// Records that RevenueCat reports [entitlement] for [appUserId], with or
  /// without a purchase behind it.
  void entitle(
    String appUserId, {
    String entitlement = FullUnlock.premiumEntitlement,
  }) {
    entitlements.putIfAbsent(appUserId, () => <String>{}).add(entitlement);
    known(appUserId);
  }

  /// Set to make every call fail with this status (RevenueCat having a bad day).
  int? status;

  int requests = 0;

  /// Paths and `Authorization` headers seen, so a test can assert the server
  /// asked about the right app user id with its own secret key.
  final List<String> paths = <String>[];
  final List<String?> authorizations = <String?>[];

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  /// Records that [appUserId] bought [productId], as the stores would.
  ///
  /// The default is the unlock, which is the only product this build sells; a test
  /// names another one when it is asking what happens to a product RevenueCat
  /// knows and we do not.
  void grant(
    String appUserId, {
    String productId = FullUnlock.productId,
    required String transactionId,
    String store = 'app_store',
    bool sandbox = false,
    bool withoutStoreTransactionId = false,
    DateTime? purchasedAt,
  }) => purchases
      .putIfAbsent(appUserId, () => [])
      .add(
        FakeStorePurchase(
          productId: productId,
          transactionId: transactionId,
          store: store,
          sandbox: sandbox,
          withoutStoreTransactionId: withoutStoreTransactionId,
          purchasedAt: purchasedAt ?? DateTime.utc(2026, 9, 24, 11),
        ),
      );

  /// An app user RevenueCat knows about but who has bought nothing.
  void known(String appUserId) =>
      purchases.putIfAbsent(appUserId, () => <FakeStorePurchase>[]);

  Future<void> stop() => _server.close(force: true);
}

/// One purchase in [FakeRevenueCat]'s memory.
class FakeStorePurchase {
  const FakeStorePurchase({
    required this.productId,
    required this.transactionId,
    required this.store,
    required this.sandbox,
    required this.withoutStoreTransactionId,
    required this.purchasedAt,
  });

  final String productId;
  final String transactionId;
  final String store;
  final bool sandbox;
  final bool withoutStoreTransactionId;
  final DateTime purchasedAt;
}

/// The webhook secret the purchase tests configure their servers with.
const String testWebhookSecret = 'whsec-test-0123456789';

/// A `PurchasesConfig` with the feature on and both secrets set, which is the
/// only configuration that starts (SPEC §4.9).
PurchasesConfig testPurchasesConfig({bool creditSandbox = false}) =>
    PurchasesConfig(
      enabled: true,
      webhookSecret: testWebhookSecret,
      apiKey: 'sk_test_key',
      creditSandbox: creditSandbox,
    );

/// A RevenueCat webhook body for a completed purchase of the unlock (SPEC §4.9).
///
/// Shaped like the real thing, including the fields the server deliberately does
/// **not** read — `price`, `currency`, `country_code` — so that a test proves what
/// the purchase grants comes from the server's own `FullUnlock` rather than from
/// the event.
Map<String, dynamic> purchaseWebhookBody({
  required String appUserId,
  String productId = FullUnlock.productId,
  required String transactionId,
  String type = 'NON_RENEWING_PURCHASE',
  String store = 'APP_STORE',
  String environment = 'PRODUCTION',
  String eventId = 'evt_1',
  List<String> aliases = const <String>[],
  String? originalAppUserId,
  DateTime? purchasedAt,
  double price = 4.99,
}) => {
  'api_version': '1.0',
  'event': {
    'id': eventId,
    'type': type,
    'app_user_id': appUserId,
    'original_app_user_id': originalAppUserId ?? appUserId,
    'aliases': aliases,
    'product_id': productId,
    'transaction_id': transactionId,
    'original_transaction_id': transactionId,
    'store': store,
    'environment': environment,
    'purchased_at_ms':
        (purchasedAt ?? DateTime.utc(2026, 9, 24, 11)).millisecondsSinceEpoch,
    'event_timestamp_ms':
        (purchasedAt ?? DateTime.utc(2026, 9, 24, 11)).millisecondsSinceEpoch,
    // Read by nobody. What the purchase grants comes from `FullUnlock`, so a
    // price in the body is not merely untrusted, it is unused.
    'price': price,
    'price_in_purchased_currency': price,
    'currency': 'USD',
    'country_code': 'US',
  },
};

/// A RevenueCat refund / chargeback webhook body (SPEC §4.9).
Map<String, dynamic> refundWebhookBody({
  required String appUserId,
  String productId = FullUnlock.productId,
  required String transactionId,
  String cancelReason = 'CUSTOMER_SUPPORT',
  String eventId = 'evt_refund_1',
  String environment = 'PRODUCTION',
}) => {
  'api_version': '1.0',
  'event': {
    'id': eventId,
    'type': 'CANCELLATION',
    'cancel_reason': cancelReason,
    'app_user_id': appUserId,
    'original_app_user_id': appUserId,
    'product_id': productId,
    'transaction_id': transactionId,
    'original_transaction_id': transactionId,
    'store': 'APP_STORE',
    'environment': environment,
    'purchased_at_ms': DateTime.utc(2026, 9, 24, 11).millisecondsSinceEpoch,
  },
};
