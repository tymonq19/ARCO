/// Rewarded ads that pay Sparks, server side (SPEC §4.10).
///
/// The properties under test are the ones that print Sparks if they break:
///
/// * **only a signed callback credits.** A client cannot say "I watched an ad",
///   and an edited query string is refused — the tampering test rewrites
///   `custom_data` *after* signing, which is the shape of every attack the
///   signature exists to stop.
/// * **the amount is the server's, never the message's.** Every crediting
///   callback here advertises `reward_amount=1000000`, and every one of them pays
///   [AdRate.sparksPerAd].
/// * **one watched ad credits exactly once**, however many times AdMob retries,
///   and a reward that has paid one player never pays another.
/// * **the bounds hold**: a daily cap separate from the play one, and a cooldown
///   measured on Google's own signed timestamps so it is correct even when
///   callbacks arrive out of order.
/// * **the two caps never interact.** Six ads leave a good run paying full, and a
///   full play day leaves the ad allowance intact.
/// * **the env switch turns the whole thing off cleanly** — `404` from both
///   routes, `ads: false` in health, and a cosmetic shop that has not noticed.
///
/// No test reaches Google. The server is pointed at [FakeAdMobKeyServer] on
/// loopback, and every callback is signed with a real P-256 keypair the test
/// generates — so the whole verification path runs (DER `SubjectPublicKeyInfo`,
/// the named-curve OID, the split at `&signature=`, the DER `SEQUENCE { r, s }`)
/// without an AdMob account.
library;

import 'dart:convert';

import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'ads_support.dart';
import 'support.dart';

void main() {
  Map<String, dynamic> decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Future<http.Response> getCallback(ArcoServer server, String query) =>
      http.get(Uri.parse('${server.baseUrl}/api/ads/callback?$query'));

  Future<http.Response> getOffer(ArcoServer server, String? auth) => http.get(
    Uri.parse('${server.baseUrl}/api/ads/offer'),
    headers: {'authorization': ?auth},
  );

  Future<http.Response> getInventory(ArcoServer server, String auth) =>
      http.get(
        Uri.parse('${server.baseUrl}/api/shop/inventory'),
        headers: {'authorization': auth},
      );

  /// A server with ads on, pointed at a fake key document, plus one player.
  Future<
    ({
      ArcoServer server,
      FakeAdMobKeyServer keys,
      TestVerifierKey key,
      String playerId,
      String auth,
    })
  >
  boot({String callbackKey = ''}) async {
    final keys = await FakeAdMobKeyServer.start();
    final server = await bootServer(
      ads: testAdsConfig(keysUrl: keys.uri, callbackKey: callbackKey),
    );
    final issued = await issuePlayer(server, name: 'Watcher');
    return (
      server: server,
      keys: keys,
      key: keys.keys.first,
      playerId: issued['id'] as String,
      auth: authOf(issued),
    );
  }

  // ------------------------------------------------------------------ rate

  group('the ad rate', () {
    test('pays a fixed amount per ad, from the server table', () {
      expect(AdRate.sparksPerAd, 10);
      expect(AdRate.dailyCap, 60);
      expect(AdRate.adsPerDay, 6);
      expect(AdRate.cooldown, const Duration(minutes: 5));
    });

    test('the ad daily cap is separate from, and smaller than, the play one', () {
      // The whole point of the two caps: a player who watches every ad the day
      // allows still earns less than a third of what playing pays, so playing is
      // never the slow route.
      expect(AdRate.dailyCap, lessThan(TokenRate.dailyCap));
      expect(AdRate.dailyCap * 3, lessThanOrEqualTo(TokenRate.dailyCap));
    });

    test('an ad is worth roughly a minute of real play', () {
      // 10 sparks is what a ~1 000-point run pays, which is about how long an ad
      // takes to watch. Stated as a test so a change to either number has to
      // argue with this one.
      expect(AdRate.sparksPerAd * TokenRate.scorePerToken, 1000);
      expect(AdRate.sparksPerAd, lessThan(TokenRate.maxTokensPerRun));
    });

    test('clips to what is left of the day', () {
      expect(AdRate.forAdWithinDay(alreadyEarnedToday: 0), 10);
      expect(AdRate.forAdWithinDay(alreadyEarnedToday: 50), 10);
      // A partial payment: the ad has been watched, so it is paid what remains
      // rather than refused. Unreachable with the current constants (60 is a
      // whole number of 10s), which is exactly why the arithmetic is pinned here.
      expect(AdRate.forAdWithinDay(alreadyEarnedToday: 55), 5);
      expect(AdRate.forAdWithinDay(alreadyEarnedToday: 60), 0);
      expect(AdRate.forAdWithinDay(alreadyEarnedToday: 999), 0);
    });

    test('the cheapest cosmetic is more than one day of ads is worth', () {
      // Ads shorten the wait; they are not the route. The cheapest paid item
      // costs more than a whole day's ad allowance would... or, if it ever does
      // not, this fails and somebody has to say why.
      final cheapest = Catalogue.items
          .where((item) => !item.free)
          .map((item) => item.priceTokens)
          .reduce((a, b) => a < b ? a : b);
      expect(cheapest, greaterThan(AdRate.sparksPerAd));
    });
  });

  group('the placements', () {
    test('are exactly the two that answer a want', () {
      // A new value here is a new place an ad appears, and it should need a
      // deliberate change rather than a configuration flag. There is no
      // placement for a launch, a duel or an interstitial.
      expect(AdPlacement.values, <AdPlacement>[
        AdPlacement.shop,
        AdPlacement.gameOver,
      ]);
      expect(AdPlacement.names, <String>['shop', 'gameOver']);
    });

    test('parse rejects anything else', () {
      expect(AdPlacement.parse('shop'), AdPlacement.shop);
      expect(AdPlacement.parse('gameOver'), AdPlacement.gameOver);
      expect(AdPlacement.parse('launch'), isNull);
      expect(AdPlacement.parse('interstitial'), isNull);
      expect(AdPlacement.parse(null), isNull);
    });
  });

  group('the custom data', () {
    // The format the app writes and this server reads. Pinned literally on both
    // sides (`test/services/ad_pin_test.dart` in the app) because the two halves
    // cannot share code, and a drift here means a reward with nowhere to land.
    const playerId = '0123456789abcdef0123456789abcdef';

    test('is playerId:placement', () {
      expect(AdCustomData.encode(playerId, AdPlacement.shop), '$playerId:shop');
      expect(
        AdCustomData.encode(playerId, AdPlacement.gameOver),
        '$playerId:gameOver',
      );
    });

    test('round-trips', () {
      for (final placement in AdPlacement.values) {
        final decoded = AdCustomData.decode(
          AdCustomData.encode(playerId, placement),
        );
        expect(decoded.playerId, playerId);
        expect(decoded.placement, placement);
      }
    });

    test('a placement this build has no name for still names the player', () {
      // An app newer than the server: the reward is real and the placement is a
      // label, so it is paid and the row records `unknown`.
      final decoded = AdCustomData.decode('$playerId:somethingNew');
      expect(decoded.playerId, playerId);
      expect(decoded.placement, isNull);
    });

    test('anything that is not a player id reads as no player', () {
      for (final raw in <String>[
        '',
        'shop',
        'not-a-player-id:shop',
        r'$RCAnonymousID:abc',
        ':shop',
      ]) {
        expect(AdCustomData.decode(raw).playerId, isNull, reason: raw);
      }
    });
  });

  // ---------------------------------------------------------- configuration

  group('the configuration', () {
    AdsConfig parse(Map<String, String> env) =>
        AdsConfig.fromEnvironment((key) {
          final raw = env[key]?.trim();
          return (raw == null || raw.isEmpty) ? null : raw;
        });

    test('is off with nothing set', () {
      final config = parse(const {});
      expect(config.enabled, isFalse);
      expect(config.requiresKey, isFalse);
      expect(config.keysUri.toString(), AdsConfig.defaultKeysUrl);
    });

    test('needs no secret to start, which is the whole design', () {
      // Unlike purchases (SPEC §4.9), there is nothing shared to configure: what
      // authenticates a callback is Google's own signature over the query string.
      // So `ADS_ENABLED=on` alone is a complete, safe configuration.
      final config = parse(const {'ADS_ENABLED': 'on'});
      expect(config.enabled, isTrue);
      expect(config.requiresKey, isFalse);
      expect(config.keysUri.scheme, 'https');
    });

    test('the default keys URL is Google\'s, over HTTPS', () {
      expect(
        AdsConfig.defaultKeysUrl,
        'https://www.gstatic.com/admob/reward/verifier-keys.json',
      );
      expect(Uri.parse(AdsConfig.defaultKeysUrl).scheme, 'https');
    });

    test('ADS_ENABLED must be on or off', () {
      expect(() => parse(const {'ADS_ENABLED': 'yes'}), throwsFormatException);
      expect(() => parse(const {'ADS_ENABLED': '1'}), throwsFormatException);
      expect(parse(const {'ADS_ENABLED': 'OFF'}).enabled, isFalse);
      expect(parse(const {'ADS_ENABLED': 'ON'}).enabled, isTrue);
    });

    test('a keys URL that is not an absolute http(s) one refuses to start', () {
      for (final bad in <String>[
        '/admob/keys.json',
        'ftp://example.com/keys',
        'gstatic.com/keys.json',
      ]) {
        expect(
          () => parse({'ADS_ENABLED': 'on', 'ADMOB_SSV_KEYS_URL': bad}),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('a quoting accident in the callback key refuses to start', () {
      expect(
        () => parse(const {'ADMOB_CALLBACK_KEY': 'has a space'}),
        throwsFormatException,
      );
      expect(
        () => parse({'ADMOB_CALLBACK_KEY': 'x' * 600}),
        throwsFormatException,
      );
    });

    test('the callback key never appears in toString', () {
      const secret = 'a-very-secret-callback-key';
      final config = parse(const {
        'ADS_ENABLED': 'on',
        'ADMOB_CALLBACK_KEY': secret,
      });
      expect(config.callbackKey, secret);
      expect(config.toString(), isNot(contains(secret)));
      expect(
        ServerConfig(ads: config).toString(),
        isNot(contains(secret)),
        reason: 'the whole config is logged at startup',
      );
    });

    test('settings with the switch off are noticed, not obeyed', () {
      final config = parse(const {
        'ADMOB_CALLBACK_KEY': 'key',
        'ADMOB_SSV_KEYS_URL': 'https://example.com/keys.json',
      });
      expect(config.enabled, isFalse);
      expect(config.hasUnusedSettings, isTrue);
      expect(parse(const {'ADS_ENABLED': 'on'}).hasUnusedSettings, isFalse);
    });

    test('a server starts with ads on and nothing else configured', () async {
      final server = await bootServer(ads: const AdsConfig(enabled: true));
      expect(server.ads.enabled, isTrue);
      final health = decode(
        await http.get(Uri.parse('${server.baseUrl}/api/health')),
      );
      expect(health['ads'], isTrue);
    });
  });

  // ------------------------------------------------------------ switched off

  group('with ads switched off', () {
    test('the callback answers ads_disabled and credits nothing', () async {
      final keys = await FakeAdMobKeyServer.start();
      final server = await bootServer();
      final issued = await issuePlayer(server);
      final id = issued['id'] as String;
      final response = await getCallback(
        server,
        adCallbackQuery(key: keys.keys.first, playerId: id),
      );
      expect(response.statusCode, 404);
      expect(decode(response)['error'], 'ads_disabled');
      expect(await server.store.walletBalance(id), 0);
      expect(await server.store.adRewardCount(), 0);
      expect(keys.requests, 0, reason: 'nothing is fetched from Google');
    });

    test('the offer endpoint answers ads_disabled', () async {
      final server = await bootServer();
      final issued = await issuePlayer(server);
      final response = await getOffer(server, authOf(issued));
      expect(response.statusCode, 404);
      expect(decode(response)['error'], 'ads_disabled');
    });

    test('health says so and the cosmetic shop has not noticed', () async {
      final server = await bootServer();
      final issued = await issuePlayer(server);
      final health = decode(
        await http.get(Uri.parse('${server.baseUrl}/api/health')),
      );
      expect(health['ads'], isFalse);
      final inventory = decode(await getInventory(server, authOf(issued)));
      expect(inventory['ok'], isTrue);
      expect(inventory['adTotal'], 0);
      expect(inventory['dailyCap'], TokenRate.dailyCap);
    });
  });

  // ------------------------------------------------------ signature checking

  group('the signature', () {
    test('a correctly signed callback credits', () async {
      final it = await boot();
      final response = await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: it.playerId),
      );
      expect(response.statusCode, 200, reason: response.body);
      final body = decode(response);
      expect(body['ok'], isTrue);
      expect(body['credited'], AdRate.sparksPerAd);
      expect(body['duplicate'], isFalse);
      expect(body['refused'], isNull);
      expect(body['playerId'], it.playerId);
      expect(body['placement'], 'shop');
      expect(body['balance'], AdRate.sparksPerAd);
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.sparksPerAd,
      );
    });

    test('an edited custom_data is refused and credits nobody', () async {
      final it = await boot();
      final victim = await issuePlayer(it.server, name: 'Victim');
      // The attack: watch an ad on your own device, then rewrite the query string
      // to point the reward at another wallet — or to point your own reward at
      // yourself twice under a different id. The signature covers custom_data, so
      // both fail.
      final response = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          tamperCustomData: '${victim['id']}:shop',
        ),
      );
      expect(response.statusCode, 401);
      expect(decode(response)['error'], 'invalid_signature');
      expect(await it.server.store.walletBalance(it.playerId), 0);
      expect(await it.server.store.walletBalance(victim['id'] as String), 0);
      expect(await it.server.store.adRewardCount(), 0);
    });

    test('a signature from a different key is refused', () async {
      final it = await boot();
      final impostor = TestVerifierKey.generate(keyId: 424242);
      final response = await getCallback(
        it.server,
        // Signed by a key Google does not publish, but naming the key id it does:
        // the shape of "I made my own keypair".
        adCallbackQuery(
          key: impostor,
          playerId: it.playerId,
          keyId: it.key.keyId,
        ),
      );
      expect(response.statusCode, 401);
      expect(decode(response)['error'], 'invalid_signature');
      expect(await it.server.store.walletBalance(it.playerId), 0);
    });

    test('a key id Google does not publish is refused', () async {
      final it = await boot();
      final response = await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: it.playerId, keyId: '999'),
      );
      expect(response.statusCode, 401);
      expect(decode(response)['error'], 'invalid_signature');
      expect(await it.server.store.walletBalance(it.playerId), 0);
    });

    test(
      'no signature at all is a malformed callback, not a bad one',
      () async {
        final it = await boot();
        final response = await http.get(
          Uri.parse(
            '${it.server.baseUrl}/api/ads/callback'
            '?transaction_id=t1&custom_data=${it.playerId}%3Ashop&timestamp=1',
          ),
        );
        expect(response.statusCode, 400);
        expect(decode(response)['error'], 'invalid_callback');
        expect(decode(response)['detail'], contains('signature'));
      },
    );

    test('a signature that is not base64url is refused', () async {
      final it = await boot();
      final response = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          signature: 'not base64 at all !!',
        ),
      );
      expect(response.statusCode, 400);
      expect(decode(response)['error'], 'invalid_callback');
    });

    test('a well-formed but wrong signature is refused', () async {
      final it = await boot();
      final good = it.key.sign('something else entirely');
      final response = await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: it.playerId, signature: good),
      );
      expect(response.statusCode, 401);
      expect(decode(response)['error'], 'invalid_signature');
    });

    test('the signed content is the query up to &signature=', () async {
      // Stated directly, because it is the one thing that cannot be inferred from
      // a passing end-to-end test: everything before `&signature=` is signed, and
      // appending a parameter *after* it therefore changes nothing.
      final it = await boot();
      final query = adCallbackQuery(key: it.key, playerId: it.playerId);
      final response = await getCallback(it.server, '$query&unexpected=1');
      expect(response.statusCode, 200, reason: response.body);
      expect(decode(response)['credited'], AdRate.sparksPerAd);
    });

    test('inserting a parameter before the signature breaks it', () async {
      final it = await boot();
      final query = adCallbackQuery(key: it.key, playerId: it.playerId);
      final cut = query.indexOf('&signature=');
      final tampered =
          '${query.substring(0, cut)}&reward_amount=9999${query.substring(cut)}';
      final response = await getCallback(it.server, tampered);
      expect(response.statusCode, 401);
      expect(decode(response)['error'], 'invalid_signature');
    });

    test('the key document is fetched once and cached', () async {
      final it = await boot();
      for (var i = 0; i < 5; i++) {
        final response = await getCallback(
          it.server,
          adCallbackQuery(
            key: it.key,
            playerId: it.playerId,
            transactionId: 'txn-$i',
            // Spread out so the cooldown does not bound them; the point here is
            // the fetch count, not the amounts.
            rewardedAt: DateTime.utc(2026, 9, 24, 12 + i),
          ),
        );
        expect(response.statusCode, 200, reason: response.body);
      }
      expect(it.keys.requests, 1);
    });

    test('a rotated key is picked up once the refresh budget allows', () async {
      final keys = await FakeAdMobKeyServer.start();
      final rotated = TestVerifierKey.generate(keyId: 777000111);
      final cache = AdMobKeyCache(
        uri: keys.uri,
        log: silentLogger(),
        minRefreshInterval: Duration.zero,
      );
      expect(await cache.keyFor(keys.keys.first.keyId), isNotNull);
      expect(cache.attempts, 1);
      keys.keys = <TestVerifierKey>[rotated];
      // A key id we have never seen is what a rotation looks like, so one
      // immediate refetch happens rather than waiting for the TTL.
      expect(await cache.keyFor(rotated.keyId), isNotNull);
      expect(cache.attempts, 2);
      expect(cache.keyIds, <String>{rotated.keyId});
    });

    test('a flood of unknown key ids cannot hammer Google', () async {
      // The other half of the rotation policy, and the reason the refresh budget
      // exists: a caller that sends callbacks naming random key ids must not turn
      // into a flood of outbound requests to gstatic.
      final keys = await FakeAdMobKeyServer.start();
      final cache = AdMobKeyCache(uri: keys.uri, log: silentLogger());
      expect(await cache.keyFor(keys.keys.first.keyId), isNotNull);
      for (var i = 0; i < 50; i++) {
        expect(await cache.keyFor('made-up-$i'), isNull);
      }
      expect(keys.requests, 1);
    });

    test('the service credits a signature from a rotated key', () async {
      final keys = await FakeAdMobKeyServer.start();
      final rotated = TestVerifierKey.generate(keyId: 777000111);
      final server = await bootServer();
      final issued = await issuePlayer(server, name: 'Watcher');
      final id = issued['id'] as String;
      final service = AdsService(
        store: server.store,
        config: testAdsConfig(keysUrl: keys.uri),
        log: silentLogger(),
        keys: AdMobKeyCache(
          uri: keys.uri,
          log: silentLogger(),
          minRefreshInterval: Duration.zero,
        ),
      );
      // Warm the cache on the old document, then rotate underneath it.
      expect(
        (await service.callback(
          adCallbackQuery(key: keys.keys.first, playerId: id),
        )).status,
        200,
      );
      keys.keys = <TestVerifierKey>[rotated];
      final result = await service.callback(
        adCallbackQuery(
          key: rotated,
          playerId: id,
          transactionId: 'after-rotation',
          rewardedAt: DateTime.utc(2026, 9, 24, 13),
        ),
      );
      expect(result.status, 200, reason: '${result.body}');
      expect(result.body['credited'], AdRate.sparksPerAd);
      expect(await server.store.walletBalance(id), AdRate.sparksPerAd * 2);
    });

    test('keys we cannot fetch are a 503, not a refused reward', () async {
      final keys = await FakeAdMobKeyServer.start();
      final key = keys.keys.first;
      keys.status = 500;
      final server = await bootServer(ads: testAdsConfig(keysUrl: keys.uri));
      final issued = await issuePlayer(server);
      final id = issued['id'] as String;
      final response = await getCallback(
        server,
        adCallbackQuery(key: key, playerId: id),
      );
      // The callback may be perfectly good and we cannot tell. A 503 makes AdMob
      // retry, which is exactly what should happen.
      expect(response.statusCode, 503);
      expect(decode(response)['error'], 'admob_keys_unavailable');
      expect(await server.store.walletBalance(id), 0);
      expect(await server.store.adRewardCount(), 0);
    });

    test('an unusable key in the document does not poison the others', () {
      final good = TestVerifierKey.generate();
      final parsed = parseAdMobVerifierKeys(
        jsonEncode({
          'keys': [
            {'keyId': 1, 'base64': 'not-a-key'},
            {'keyId': 2},
            good.published,
          ],
        }),
        log: silentLogger(),
        source: Uri.parse('http://127.0.0.1/keys'),
      );
      expect(parsed.keys, <String>{good.keyId});
    });

    test('an EC key with an unsupported curve is named, not guessed at', () {
      // A future rotation onto a curve this build cannot do must fail loudly with
      // the OID in the message, never verify against the wrong curve.
      expect(
        () => parseEcPublicKey(base64.decode(_ed25519Spki)),
        throwsA(isA<FormatException>()),
      );
    });

    test('the keys are fetched over HTTPS, bar loopback', () async {
      // The cache reuses `fetchJwksOverHttps`, which is the one place in this
      // server that talks to a key publisher — so the guard the sign-in keys get
      // (HTTPS only, no redirects, size- and time-capped) is the guard these get.
      // Pinned here because SPEC §4.10 and README.server.md both claim it.
      expect(isFetchableJwksUri(Uri.parse(AdsConfig.defaultKeysUrl)), isTrue);
      expect(
        isFetchableJwksUri(Uri.parse('http://www.gstatic.com/keys.json')),
        isFalse,
        reason: 'a key document over plain HTTP could be rewritten on the path',
      );
      await expectLater(
        fetchJwksOverHttps(Uri.parse('http://www.gstatic.com/keys.json')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('HTTPS only'),
          ),
        ),
      );
    });

    test('Google\'s real published key parses', () {
      // The document shape and the DER encoding, taken from
      // https://www.gstatic.com/admob/reward/verifier-keys.json — so a change to
      // either would fail here rather than in production.
      final key = parseEcPublicKey(base64.decode(_realGoogleKeyBase64));
      expect(key.Q, isNotNull);
      expect(key.parameters!.curve.fieldSize, 256);
    });
  });

  // ------------------------------------------------------------- crediting

  group('crediting', () {
    test('pays the server table, never the callback amount', () async {
      final it = await boot();
      final response = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          // What a compromised or simply mistyped AdMob dashboard would send.
          rewardAmount: 1000000,
          rewardItem: 'sparks',
        ),
      );
      expect(response.statusCode, 200, reason: response.body);
      expect(decode(response)['credited'], AdRate.sparksPerAd);
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.sparksPerAd,
      );
      // Recorded, so a dashboard that has drifted from the code is visible.
      final row = await it.server.store.adReward('admob-txn-1');
      expect(row!.rewardAmount, 1000000);
      expect(row.sparks, AdRate.sparksPerAd);
    });

    test('the ledger records what the callback said about the ad', () async {
      final it = await boot();
      await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          placement: 'gameOver',
          adUnit: 'ca-app-pub-3940256099942544/1712485313',
          adNetwork: 'admob-network-id',
          rewardItem: 'sparks',
          rewardedAt: DateTime.utc(2026, 9, 24, 12, 30),
        ),
      );
      final row = await it.server.store.adReward('admob-txn-1');
      expect(row, isNotNull);
      expect(row!.playerId, it.playerId);
      expect(row.placement, 'gameOver');
      expect(row.adUnit, 'ca-app-pub-3940256099942544/1712485313');
      expect(row.adNetwork, 'admob-network-id');
      expect(row.rewardItem, 'sparks');
      expect(row.keyId, it.key.keyId);
      expect(row.day, '2026-09-24');
      expect(row.rewardedAt, startsWith('2026-09-24T12:30'));
      expect(row.refused, isNull);
      expect(row.paid, isTrue);
    });

    test('the same callback twice credits once', () async {
      final it = await boot();
      final query = adCallbackQuery(key: it.key, playerId: it.playerId);
      final first = await getCallback(it.server, query);
      final second = await getCallback(it.server, query);
      expect(first.statusCode, 200);
      expect(decode(first)['credited'], AdRate.sparksPerAd);
      // A retry is answered 200 so AdMob stops, and credits nothing.
      expect(second.statusCode, 200);
      expect(decode(second)['credited'], 0);
      expect(decode(second)['duplicate'], isTrue);
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.sparksPerAd,
      );
      expect(await it.server.store.adRewardCount(), 1);
    });

    test('ten deliveries of one reward credit once', () async {
      final it = await boot();
      final query = adCallbackQuery(key: it.key, playerId: it.playerId);
      final responses = await Future.wait<http.Response>([
        for (var i = 0; i < 10; i++) getCallback(it.server, query),
      ]);
      for (final response in responses) {
        expect(response.statusCode, 200, reason: response.body);
      }
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.sparksPerAd,
      );
      expect(await it.server.store.adRewardCount(), 1);
    });

    test('a reward that paid one player never pays another', () async {
      // It cannot happen through the signature — custom_data is signed — but the
      // storage layer refuses it anyway, because "one transaction id, one
      // payment" must hold whatever the layer above does.
      final it = await boot();
      final other = await issuePlayer(it.server, name: 'Other');
      await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: it.playerId),
      );
      final second = await it.server.store.creditAdReward(
        AdCreditRequest(
          playerId: other['id'] as String,
          placement: 'shop',
          transactionId: 'admob-txn-1',
          rewardAmount: 10,
          rewardItem: 'sparks',
          adUnit: 'unit',
          adNetwork: 'network',
          keyId: it.key.keyId,
          rewardedAt: DateTime.utc(2026, 9, 24, 12),
          now: DateTime.utc(2026, 9, 24, 12),
        ),
      );
      expect(second.duplicate, isTrue);
      expect(second.sparks, 0);
      expect(await it.server.store.walletBalance(other['id'] as String), 0);
    });

    test('a callback for a player we do not have is refused', () async {
      final it = await boot();
      final response = await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: testPlayerId(0xdead)),
      );
      // Deliberately non-2xx: the app and this deployment disagree about who is
      // playing, and that should surface in AdMob's dashboard as a failed
      // callback rather than be swallowed.
      expect(response.statusCode, 404);
      expect(decode(response)['error'], 'unknown_player');
      expect(await it.server.store.adRewardCount(), 0);
    });

    test('user_id is accepted when custom_data carries no player', () async {
      final it = await boot();
      final response = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          customData: '',
          userId: it.playerId,
        ),
      );
      expect(response.statusCode, 200, reason: response.body);
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.sparksPerAd,
      );
    });

    test('a placement this build has no name for still pays', () async {
      final it = await boot();
      final response = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          customData: '${it.playerId}:someFuturePlacement',
        ),
      );
      expect(response.statusCode, 200, reason: response.body);
      expect(decode(response)['placement'], 'unknown');
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.sparksPerAd,
      );
    });

    test('a query longer than the cap is refused before any crypto', () async {
      final it = await boot();
      final response = await getCallback(it.server, 'x=${'a' * 4000}');
      expect(response.statusCode, 400);
      expect(decode(response)['error'], 'invalid_callback');
      expect(it.keys.requests, 0);
    });

    test('the ledger explains the balance', () async {
      final it = await boot();
      // An evening: a played run, a bought pack's worth of Sparks and an ad.
      await grantTokens(it.server, it.playerId, 40);
      await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: it.playerId),
      );
      final inventory = decode(await getInventory(it.server, it.auth));
      expect(inventory['adTotal'], AdRate.sparksPerAd);
      expect(
        inventory['balance'],
        (inventory['earnedTotal'] as int) +
            (inventory['purchasedTotal'] as int) +
            (inventory['adTotal'] as int) -
            (inventory['spentTotal'] as int),
        reason: 'played for + paid for + watched for - spent',
      );
      final ledger = await it.server.store.adRewards(it.playerId);
      expect(ledger, hasLength(1));
      expect(ledger.first.sparks, AdRate.sparksPerAd);
    });
  });

  // ---------------------------------------------------------------- bounds

  group('the daily cap', () {
    /// Watches [count] ads, spaced out so the cooldown never bounds them.
    Future<List<http.Response>> watch(
      ArcoServer server,
      TestVerifierKey key,
      String playerId, {
      required int count,
      DateTime? from,
    }) async {
      final start = from ?? DateTime.utc(2026, 9, 24, 0);
      final out = <http.Response>[];
      for (var i = 0; i < count; i++) {
        out.add(
          await getCallback(
            server,
            adCallbackQuery(
              key: key,
              playerId: playerId,
              transactionId: 'txn-$i',
              rewardedAt: start.add(Duration(minutes: 10 * i)),
            ),
          ),
        );
      }
      return out;
    }

    test('six ads pay the day, the seventh pays nothing', () async {
      final it = await boot();
      final responses = await watch(
        it.server,
        it.key,
        it.playerId,
        count: AdRate.adsPerDay + 1,
      );
      for (final response in responses) {
        expect(response.statusCode, 200, reason: response.body);
      }
      for (var i = 0; i < AdRate.adsPerDay; i++) {
        expect(decode(responses[i])['credited'], AdRate.sparksPerAd);
      }
      final last = decode(responses.last);
      expect(last['credited'], 0);
      expect(last['refused'], 'daily_cap');
      expect(last['earnedToday'], AdRate.dailyCap);
      expect(await it.server.store.walletBalance(it.playerId), AdRate.dailyCap);
    });

    test(
      'a reward the cap bounced is still recorded, so its retry pays nothing',
      () async {
        final it = await boot();
        await watch(it.server, it.key, it.playerId, count: AdRate.adsPerDay);
        final query = adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'over-the-cap',
          rewardedAt: DateTime.utc(2026, 9, 24, 23),
        );
        expect(decode(await getCallback(it.server, query))['credited'], 0);
        // The row is the idempotency key. Without it, AdMob's retry would arrive
        // after midnight and be paid a second time.
        final row = await it.server.store.adReward('over-the-cap');
        expect(row, isNotNull);
        expect(row!.sparks, 0);
        expect(row.refused, 'daily_cap');
        final retry = decode(await getCallback(it.server, query));
        expect(retry['duplicate'], isTrue);
        expect(retry['credited'], 0);
        expect(
          await it.server.store.walletBalance(it.playerId),
          AdRate.dailyCap,
        );
      },
    );

    test('the cap is a UTC day and the next one is fresh', () async {
      final it = await boot();
      await watch(it.server, it.key, it.playerId, count: AdRate.adsPerDay);
      final response = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'tomorrow',
          rewardedAt: DateTime.utc(2026, 9, 25, 0, 1),
        ),
      );
      expect(decode(response)['credited'], AdRate.sparksPerAd);
      expect(decode(response)['earnedToday'], AdRate.sparksPerAd);
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.dailyCap + AdRate.sparksPerAd,
      );
    });

    test(
      'the day is the one the ad was watched in, not the one it arrived in',
      () async {
        // A callback Google delivers after midnight counts against the day the ad
        // was actually watched, because that is the moment Google signed.
        final it = await boot();
        await watch(it.server, it.key, it.playerId, count: AdRate.adsPerDay);
        final row = await it.server.store.adReward('txn-0');
        expect(row!.day, '2026-09-24');
        // The same ad delivered a day late would still be a full day, so a late
        // delivery cannot be used to earn twice.
        final late = await getCallback(
          it.server,
          adCallbackQuery(
            key: it.key,
            playerId: it.playerId,
            transactionId: 'watched-yesterday-delivered-today',
            rewardedAt: DateTime.utc(2026, 9, 24, 23, 59),
          ),
        );
        expect(decode(late)['credited'], 0);
        expect(decode(late)['refused'], 'daily_cap');
      },
    );

    test('the cap is per player', () async {
      final it = await boot();
      await watch(it.server, it.key, it.playerId, count: AdRate.adsPerDay);
      final other = await issuePlayer(it.server, name: 'Other');
      final response = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: other['id'] as String,
          transactionId: 'other-first-ad',
        ),
      );
      expect(decode(response)['credited'], AdRate.sparksPerAd);
    });

    test('a full ad day leaves a good run paying in full', () async {
      // The two caps must never interact. A player who has watched every ad the
      // day allows must not then find their runs paying nothing — which is what
      // would happen if ad Sparks landed in `earned_total`.
      final it = await boot();
      await watch(it.server, it.key, it.playerId, count: AdRate.adsPerDay);
      final award = await it.server.store.awardTokens(
        playerId: it.playerId,
        scoreId: 'run-after-ads',
        score: 3000,
        replayKey: 'replay-after-ads',
        now: DateTime.utc(2026, 9, 24, 21),
      );
      expect(award.tokens, 30);
      expect(award.cappedByDay, isFalse);
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.dailyCap + 30,
      );
    });

    test('a full play day leaves the ad allowance intact', () async {
      final it = await boot();
      await grantTokens(
        it.server,
        it.playerId,
        TokenRate.dailyCap,
        from: DateTime.utc(2026, 9, 24, 12),
      );
      final response = await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: it.playerId),
      );
      expect(decode(response)['credited'], AdRate.sparksPerAd);
      expect(
        await it.server.store.walletBalance(it.playerId),
        TokenRate.dailyCap + AdRate.sparksPerAd,
      );
    });
  });

  group('the cooldown', () {
    test('two ads inside it pay once', () async {
      final it = await boot();
      final first = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'a',
          rewardedAt: DateTime.utc(2026, 9, 24, 12, 0),
        ),
      );
      final second = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'b',
          rewardedAt: DateTime.utc(2026, 9, 24, 12, 1),
        ),
      );
      expect(decode(first)['credited'], AdRate.sparksPerAd);
      expect(second.statusCode, 200);
      expect(decode(second)['credited'], 0);
      expect(decode(second)['refused'], 'cooldown');
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.sparksPerAd,
      );
    });

    test('a gap of the whole cooldown pays', () async {
      final it = await boot();
      await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'a',
          rewardedAt: DateTime.utc(2026, 9, 24, 12, 0),
        ),
      );
      final second = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'b',
          rewardedAt: DateTime.utc(2026, 9, 24, 12, 0).add(AdRate.cooldown),
        ),
      );
      expect(decode(second)['credited'], AdRate.sparksPerAd);
      expect(
        await it.server.store.walletBalance(it.playerId),
        AdRate.sparksPerAd * 2,
      );
    });

    test('callbacks arriving out of order give the same answer', () async {
      // Measured as an absolute difference between two signed timestamps, so the
      // order Google happens to deliver them in cannot change what is paid.
      final it = await boot();
      final later = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'later',
          rewardedAt: DateTime.utc(2026, 9, 24, 12, 6),
        ),
      );
      final earlier = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'earlier',
          rewardedAt: DateTime.utc(2026, 9, 24, 12, 0),
        ),
      );
      expect(decode(later)['credited'], AdRate.sparksPerAd);
      expect(decode(earlier)['credited'], AdRate.sparksPerAd);

      // And the reverse: an earlier one that is *inside* the cooldown of one
      // already recorded is bounced, whichever way round they arrive.
      final tooClose = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'too-close',
          rewardedAt: DateTime.utc(2026, 9, 24, 12, 4),
        ),
      );
      expect(decode(tooClose)['credited'], 0);
      expect(decode(tooClose)['refused'], 'cooldown');
    });

    test('a bounced ad does not extend the cooldown', () async {
      // Rows that paid nothing are skipped when the cooldown looks back. If they
      // were not, one refused ad would lock a player out for a rolling five
      // minutes at a time and the allowance would never be reachable.
      final it = await boot();
      final at = DateTime.utc(2026, 9, 24, 12);
      await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'paid',
          rewardedAt: at,
        ),
      );
      await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'bounced',
          rewardedAt: at.add(const Duration(minutes: 4, seconds: 59)),
        ),
      );
      final third = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'next',
          rewardedAt: at.add(AdRate.cooldown),
        ),
      );
      expect(decode(third)['credited'], AdRate.sparksPerAd);
    });

    test('is per player', () async {
      final it = await boot();
      final other = await issuePlayer(it.server, name: 'Other');
      final at = DateTime.utc(2026, 9, 24, 12);
      await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          transactionId: 'mine',
          rewardedAt: at,
        ),
      );
      final theirs = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: other['id'] as String,
          transactionId: 'theirs',
          rewardedAt: at.add(const Duration(seconds: 1)),
        ),
      );
      expect(decode(theirs)['credited'], AdRate.sparksPerAd);
    });
  });

  // ----------------------------------------------------------------- offer

  group('GET /api/ads/offer', () {
    test('a fresh player is offered an ad', () async {
      final it = await boot();
      final body = decode(await getOffer(it.server, it.auth));
      expect(body['ok'], isTrue);
      expect(body['available'], isTrue);
      expect(body['sparks'], AdRate.sparksPerAd);
      expect(body['earnedToday'], 0);
      expect(body['dailyCap'], AdRate.dailyCap);
      expect(body['remaining'], AdRate.dailyCap);
      expect(body['cooldownSeconds'], AdRate.cooldown.inSeconds);
      expect(body['waitSeconds'], 0);
      expect(body['balance'], 0);
      expect(body['adTotal'], 0);
      expect(
        body['premium'],
        isFalse,
        reason: 'a free player is who ads exist for',
      );
      expect(body['placements'], <String>['shop', 'gameOver']);
    });

    test('a premium player is offered no ad at all', () async {
      // The other half of what the one-time unlock grants (SPEC §4.9): not "fewer
      // ads", none. The allowance is untouched and full — it is the entitlement
      // that makes the answer false, which is why `premium` is reported beside it
      // rather than leaving a client to wonder why a fresh day pays nothing.
      final it = await boot();
      expect(
        (await it.server.store.grantPurchase(
          PurchaseGrantRequest(
            playerId: it.playerId,
            productId: FullUnlock.productId,
            transactionId: 'unlock-no-ads',
            store: 'app_store',
            environment: 'PRODUCTION',
            source: 'webhook',
            purchasedAt: DateTime.utc(2026, 9, 25, 11),
            now: DateTime.utc(2026, 9, 25, 12),
          ),
        )).premium,
        isTrue,
      );
      final body = decode(await getOffer(it.server, it.auth));
      expect(body['ok'], isTrue);
      expect(body['premium'], isTrue);
      expect(body['available'], isFalse);
      expect(
        body['remaining'],
        AdRate.dailyCap,
        reason: 'nothing was consumed; the button simply is not offered',
      );
      expect(body['waitSeconds'], 0, reason: 'not a cooldown either');
    });

    test('needs credentials', () async {
      final it = await boot();
      expect((await getOffer(it.server, null)).statusCode, 401);
      expect(
        (await getOffer(it.server, 'Arco ${it.playerId}:wrong')).statusCode,
        401,
      );
    });

    test('credits nothing, however often it is called', () async {
      final it = await boot();
      for (var i = 0; i < 5; i++) {
        expect((await getOffer(it.server, it.auth)).statusCode, 200);
      }
      expect(await it.server.store.walletBalance(it.playerId), 0);
      expect(await it.server.store.adRewardCount(), 0);
    });

    test('reports the cooldown after an ad, so the button can hide', () async {
      // The reason the cooldown lives here and not only in the crediting path: a
      // player inside it is shown no button at all, rather than a button that
      // takes thirty seconds and pays nothing.
      final it = await boot();
      await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          rewardedAt: DateTime.now().toUtc(),
        ),
      );
      final body = decode(await getOffer(it.server, it.auth));
      expect(body['available'], isFalse);
      expect(body['waitSeconds'], greaterThan(0));
      expect(body['waitSeconds'], lessThanOrEqualTo(AdRate.cooldown.inSeconds));
      expect(body['adTotal'], AdRate.sparksPerAd);
      expect(body['balance'], AdRate.sparksPerAd);
      expect(body['earnedToday'], AdRate.sparksPerAd);
    });

    test('an old ad leaves no wait', () async {
      final it = await boot();
      await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          rewardedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
        ),
      );
      final body = decode(await getOffer(it.server, it.auth));
      expect(body['waitSeconds'], 0);
      expect(body['available'], isTrue);
      expect(body['adTotal'], AdRate.sparksPerAd);
    });

    test('at the day\'s cap nothing is offered', () async {
      final it = await boot();
      final today = DateTime.now().toUtc();
      for (var i = 0; i < AdRate.adsPerDay; i++) {
        await getCallback(
          it.server,
          adCallbackQuery(
            key: it.key,
            playerId: it.playerId,
            transactionId: 'txn-$i',
            // Hours apart and in the past, so neither the cooldown nor the clock
            // is what makes this unavailable.
            rewardedAt: today.subtract(Duration(hours: 2 + i)),
          ),
        );
      }
      final body = decode(await getOffer(it.server, it.auth));
      expect(body['available'], isFalse);
      expect(body['remaining'], 0);
      expect(body['sparks'], 0);
      expect(body['waitSeconds'], 0, reason: 'the cap, not the cooldown');
      expect(body['earnedToday'], AdRate.dailyCap);
    });
  });

  // ------------------------------------------------------- the URL key

  group('the optional callback key', () {
    const key = 'arco-ssv-url-key-1';

    test('a callback carrying it credits', () async {
      final it = await boot(callbackKey: key);
      final response = await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: it.playerId, callbackKey: key),
      );
      expect(response.statusCode, 200, reason: response.body);
      expect(decode(response)['credited'], AdRate.sparksPerAd);
    });

    test('a callback without it is refused before any crypto', () async {
      final it = await boot(callbackKey: key);
      final response = await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: it.playerId),
      );
      expect(response.statusCode, 401);
      expect(decode(response)['error'], 'invalid_key');
      expect(await it.server.store.adRewardCount(), 0);
      expect(it.keys.requests, 0, reason: 'checked before the key fetch');
    });

    test('a wrong one is refused the same way as a missing one', () async {
      final it = await boot(callbackKey: key);
      final response = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          callbackKey: 'arco-ssv-url-key-2',
        ),
      );
      expect(response.statusCode, 401);
      expect(decode(response)['error'], 'invalid_key');
    });

    test(
      'it is inside the signed content, so it cannot be added later',
      () async {
        final it = await boot(callbackKey: key);
        // Signed without the key, then the key appended: the signature no longer
        // covers the query, so this is refused even though the key is right.
        final query = adCallbackQuery(key: it.key, playerId: it.playerId);
        final cut = query.indexOf('&signature=');
        final response = await getCallback(
          it.server,
          '${query.substring(0, cut)}&arco_key=$key${query.substring(cut)}',
        );
        expect(response.statusCode, 401);
        expect(decode(response)['error'], 'invalid_signature');
      },
    );

    test('with none configured, one in the query is simply ignored', () async {
      final it = await boot();
      final response = await getCallback(
        it.server,
        adCallbackQuery(
          key: it.key,
          playerId: it.playerId,
          callbackKey: 'whatever',
        ),
      );
      expect(response.statusCode, 200, reason: response.body);
      expect(decode(response)['credited'], AdRate.sparksPerAd);
    });
  });

  // ---------------------------------------------------------------- merges

  group('after a sign-in merge', () {
    /// The merge, driven through the storage operation the account endpoint uses
    /// — the same way `shop_test.dart` drives it, so no fake Apple is needed to
    /// test what a merge does to an ad ledger.
    Future<AccountLinkResult> link(
      ArcoServer server,
      String? caller,
      String subject,
      String tokenHash,
    ) async {
      final credential = server.players.mintCredential();
      return server.store.linkAccount(
        AccountLinkRequest(
          provider: 'apple',
          subject: subject,
          callerPlayerId: caller,
          tokenHash: tokenHash,
          tokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
          newPlayerId: server.players.newId(),
          credentialId: credential.id,
          secretHash: credential.secretHash,
          now: DateTime.now().toUtc(),
        ),
      );
    }

    test('a reward for an absorbed player credits the survivor', () async {
      final it = await boot();
      final absorbed = it.playerId;
      final account = await issuePlayer(it.server, name: 'Account');
      final accountId = account['id'] as String;
      expect(
        (await link(it.server, accountId, 'ads-merge-1', 'h1')).kind,
        AccountLinkKind.linked,
      );
      final merged = await link(it.server, absorbed, 'ads-merge-1', 'h2');
      expect(merged.kind, AccountLinkKind.merged);
      expect(merged.playerId, accountId);

      // An ad watched before the merge, delivered after it. The callback resolves
      // the app user id through `canonicalPlayerId`, so the reward lands in the
      // surviving wallet rather than in a player that no longer exists.
      final response = await getCallback(
        it.server,
        adCallbackQuery(key: it.key, playerId: absorbed),
      );
      expect(response.statusCode, 200, reason: response.body);
      expect(decode(response)['playerId'], accountId);
      expect(
        await it.server.store.walletBalance(accountId),
        AdRate.sparksPerAd,
      );
      expect(await it.server.store.walletBalance(absorbed), 0);
      expect(
        (await it.server.store.adRewards(accountId)).single.sparks,
        AdRate.sparksPerAd,
      );
    });

    test('the ad allowance is re-applied to the union', () async {
      // Two halves that each watched a day of ads are one person who watched two
      // days' worth, and the allowance is per person — so the excess comes back
      // off, exactly as it does for play (SPEC §4.8). Money is the deliberate
      // exception: what was paid for stays paid for. Without this, farming
      // ads on throwaway players and signing them all into one account would
      // multiply the cap by however many players somebody could be bothered to
      // make.
      final it = await boot();
      final day = DateTime.utc(2026, 9, 24);
      Future<void> fill(String playerId, String tag) async {
        for (var i = 0; i < AdRate.adsPerDay; i++) {
          final credit = await it.server.store.creditAdReward(
            AdCreditRequest(
              playerId: playerId,
              placement: 'shop',
              transactionId: '$tag-$i',
              rewardAmount: 10,
              rewardItem: 'sparks',
              adUnit: 'unit',
              adNetwork: 'network',
              keyId: '1',
              rewardedAt: day.add(Duration(minutes: 10 * i)),
              now: day,
            ),
          );
          expect(credit.sparks, AdRate.sparksPerAd);
        }
      }

      final account = await issuePlayer(it.server, name: 'Account');
      final accountId = account['id'] as String;
      await fill(accountId, 'one');
      await fill(it.playerId, 'two');
      expect(await it.server.store.walletBalance(accountId), AdRate.dailyCap);
      expect(await it.server.store.walletBalance(it.playerId), AdRate.dailyCap);

      expect(
        (await link(it.server, accountId, 'ads-cap-merge', 'c1')).kind,
        AccountLinkKind.linked,
      );
      expect(
        (await link(it.server, it.playerId, 'ads-cap-merge', 'c2')).kind,
        AccountLinkKind.merged,
      );

      // Both ledgers moved across, and the day is worth one day's allowance.
      expect(
        await it.server.store.adRewards(accountId, limit: 100),
        hasLength(AdRate.adsPerDay * 2),
      );
      expect(
        await it.server.store.walletBalance(accountId),
        AdRate.dailyCap,
        reason: 'two allowances on one day are still one allowance',
      );
      final state = await it.server.store.adRewardState(accountId, now: day);
      expect(state.adTotal, AdRate.dailyCap);
      expect(
        state.earnedToday,
        AdRate.dailyCap * 2,
        reason: 'the ledger is honest',
      );
    });

    test('premium survives a merge that claws back ad sparks', () async {
      // The asymmetry, stated directly: the ad allowance is re-metered and money
      // is not. Somebody who bought the unlock on each of two phones — on the App
      // Store and on Play, say — keeps both rows and stays premium.
      final it = await boot();
      final day = DateTime.utc(2026, 9, 24);
      final account = await issuePlayer(it.server, name: 'Account');
      final accountId = account['id'] as String;
      for (final (index, playerId) in <String>[
        accountId,
        it.playerId,
      ].indexed) {
        expect(
          (await it.server.store.grantPurchase(
            PurchaseGrantRequest(
              playerId: playerId,
              productId: FullUnlock.productId,
              transactionId: 'unlock-$index',
              store: 'app_store',
              environment: 'PRODUCTION',
              source: 'webhook',
              purchasedAt: day,
              now: day,
            ),
          )).granted,
          isTrue,
        );
        for (var i = 0; i < AdRate.adsPerDay; i++) {
          await it.server.store.creditAdReward(
            AdCreditRequest(
              playerId: playerId,
              placement: 'shop',
              transactionId: 'ad-$index-$i',
              rewardAmount: 10,
              rewardItem: 'sparks',
              adUnit: 'unit',
              adNetwork: 'network',
              keyId: '1',
              rewardedAt: day.add(Duration(minutes: 10 * i)),
              now: day,
            ),
          );
        }
      }
      expect(
        (await link(it.server, accountId, 'ads-money-merge', 'm1')).kind,
        AccountLinkKind.linked,
      );
      expect(
        (await link(it.server, it.playerId, 'ads-money-merge', 'm2')).kind,
        AccountLinkKind.merged,
      );
      final inventory = await it.server.store.inventory(accountId);
      expect(
        inventory.premium,
        isTrue,
        reason: 'the unlock follows the person through the merge',
      );
      expect(
        await it.server.store.purchasesOf(accountId),
        hasLength(2),
        reason: 'both payments stay explainable on the surviving player',
      );
      expect(inventory.adTotal, AdRate.dailyCap, reason: 'one day of ads');
      expect(
        inventory.balance,
        AdRate.dailyCap,
        reason: 'the unlock credits no Sparks, so only the ad ones are here',
      );
      // And the other half of what premium grants: no ad is offered at all.
      final offer = decode(
        await getOffer(
          it.server,
          playerAuth(accountId, account['secret'] as String),
        ),
      );
      expect(offer['premium'], isTrue);
      expect(offer['available'], isFalse);
    });
  });

  // ------------------------------------------------------------ rate limit

  group('the per-IP budget', () {
    test('a flood is refused with a retry-after', () async {
      final keys = await FakeAdMobKeyServer.start();
      final server = await bootServer(
        ads: testAdsConfig(keysUrl: keys.uri),
        adLimiter: RateLimiter(limit: 1, window: const Duration(minutes: 1)),
      );
      final issued = await issuePlayer(server);
      final id = issued['id'] as String;
      final first = await getCallback(
        server,
        adCallbackQuery(key: keys.keys.first, playerId: id),
      );
      expect(first.statusCode, 200, reason: first.body);
      final second = await getCallback(
        server,
        adCallbackQuery(
          key: keys.keys.first,
          playerId: id,
          transactionId: 'second',
        ),
      );
      // AdMob retries a 429 like any other non-2xx, so the limit cannot lose a
      // reward.
      expect(second.statusCode, 429);
      expect(second.headers['retry-after'], '60');
      expect(await server.store.walletBalance(id), AdRate.sparksPerAd);
    });
  });
}

/// An Ed25519 `SubjectPublicKeyInfo`: a real key of a kind this server must refuse
/// by name rather than misinterpret.
const String _ed25519Spki =
    'MCowBQYDK2VwAyEAGb9ECWmEzf6FQbrBZ9w7lshQhqowtrbLDFw4rXAxZuE=';

/// Google's real published verifier key, from
/// `https://www.gstatic.com/admob/reward/verifier-keys.json`.
const String _realGoogleKeyBase64 =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE+nzvoGqvDeB9+SzE6igTl7TyK4JB'
    'bglwir9oTcQta8NuG26ZpZFxt+F2NDk7asTE6/2Yc8i1ATcGIqtuS5hv0Q==';
