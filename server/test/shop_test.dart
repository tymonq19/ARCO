/// Cosmetic items, server side (SPEC §4.8): the catalogue, the token wallet,
/// buying, owning and equipping.
///
/// The product rule under test throughout: **ownership lives on the server.** A
/// wallet kept on the phone is edited in five minutes with a file browser, so
/// nothing here believes a number a client sent — a request carries an item id
/// and the credentials of §4.4, and the server decides everything else.
///
/// The other rule, the one that must never bend: everything sold is **purely
/// cosmetic**. `packages/arco_core` is untouched by this feature, and the
/// catalogue has no field a simulation could read. One test below pins the exact
/// set of keys an item is served with, so adding one would fail loudly.
///
/// This file boots the server with **no money feature configured** (SPEC §4.9 is
/// off), which is the state every deployment starts in: the shop advertises no
/// product to buy, nobody is premium, and the Spark economy below is the whole of
/// it. What premium changes is tested where the money is, in
/// `purchases_test.dart`.
library;

import 'dart:convert';

import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late ArcoServer server;

  setUp(() async {
    server = await bootServer();
  });

  Uri api(String path) => Uri.parse('${server.baseUrl}$path');

  Map<String, dynamic> decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Future<http.Response> getCatalogue(String? auth, {String? version}) =>
      http.get(
        api('/api/shop/catalogue${version == null ? '' : '?v=$version'}'),
        headers: {'authorization': ?auth},
      );

  Future<http.Response> getInventory(String? auth) =>
      http.get(api('/api/shop/inventory'), headers: {'authorization': ?auth});

  Future<http.Response> postBuy(String? auth, Object? body) => http.post(
    api('/api/shop/buy'),
    headers: {'content-type': 'application/json', 'authorization': ?auth},
    body: body == null ? null : (body is String ? body : jsonEncode(body)),
  );

  Future<http.Response> postEquip(String? auth, Object? body) => http.post(
    api('/api/shop/equip'),
    headers: {'content-type': 'application/json', 'authorization': ?auth},
    body: body == null ? null : (body is String ? body : jsonEncode(body)),
  );

  /// The catalogue as a map from item id to its entry.
  Future<Map<String, Map<String, dynamic>>> itemsOf(String auth) async {
    final r = await getCatalogue(auth);
    expect(r.statusCode, 200, reason: r.body);
    return {
      for (final raw in decode(r)['items'] as List<dynamic>)
        (raw as Map<String, dynamic>)['id'] as String: raw,
    };
  }

  group('GET /api/shop/catalogue', () {
    test(
      'serves every item with a price, a name key and an owned flag',
      () async {
        final me = await issuePlayer(server);
        final r = await getCatalogue(authOf(me));
        expect(r.statusCode, 200, reason: r.body);
        final body = decode(r);

        expect(body['ok'], isTrue);
        expect(body['version'], Catalogue.version);
        expect(body['latestVersion'], Catalogue.version);
        expect(body['kinds'], ['theme', 'ball', 'paddle']);
        expect(body['balance'], 0, reason: 'a new player has earned nothing');
        expect(
          body['premium'],
          isFalse,
          reason: 'nobody has bought the one-time unlock (SPEC §4.9)',
        );
        expect(
          body.containsKey('unlock'),
          isFalse,
          reason: 'and with no RevenueCat configured there is nothing to sell',
        );

        final items = (body['items'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        expect(items, hasLength(Catalogue.items.length));
        expect(
          [for (final i in items) i['id']],
          [for (final i in Catalogue.items) i.id],
          reason: 'served in the order the shop should show them',
        );

        final neon = items.firstWhere((i) => i['id'] == 'theme.neon');
        expect(neon['kind'], 'theme');
        expect(neon['priceTokens'], 0);
        expect(neon['free'], isTrue);
        expect(
          neon['owned'],
          isTrue,
          reason: 'free items are owned by everybody',
        );
        expect(
          neon['nameKey'],
          'theme.neon',
          reason: 'the client translates the name; the server sends a key',
        );

        final glass = items.firstWhere((i) => i['id'] == 'theme.glass');
        expect(glass['priceTokens'], 250);
        expect(glass['free'], isFalse);
        expect(glass['owned'], isFalse);
      },
    );

    test('an item carries nothing the simulation could read', () async {
      // The iron rule of this feature as an assertion. Everything sold is
      // cosmetic: the server re-simulates every submitted replay to verify it
      // (SPEC §4), so an item that changed a paddle or a ball would make honest
      // runs fail verification — and a leaderboard where money buys rank is
      // worth nothing. If somebody adds a field here, this fails.
      final me = await issuePlayer(server);
      final items = await itemsOf(authOf(me));
      for (final item in items.values) {
        expect(
          item.keys.toSet(),
          <String>{'id', 'kind', 'priceTokens', 'free', 'nameKey', 'owned'},
          reason: 'no item may carry a gameplay effect: ${item['id']}',
        );
      }
    });

    test('the free items are what a player owns before they pay or play', () async {
      // The free path, stated as the baseline the rest of the feature is measured
      // against: two themes, a ball and a paddle, owned by everybody with no row
      // written for anybody (SPEC §4.8).
      final me = await issuePlayer(server);
      final body = decode(await getInventory(authOf(me)));
      expect(body['premium'], isFalse);
      expect((body['owned'] as List<dynamic>).cast<String>(), <String>[
        'theme.neon',
        'theme.classic',
        'ball.orb',
        'paddle.arc',
      ]);
      expect(
        (await server.store.inventory(me['id'] as String)).ownedItemIds,
        isEmpty,
      );
    });

    test('a fresh player is equipped with the free defaults', () async {
      final me = await issuePlayer(server);
      final r = await getCatalogue(authOf(me));
      expect(decode(r)['equipped'], {
        'theme': 'theme.neon',
        'ball': 'ball.orb',
        'paddle': 'paddle.arc',
      });
      // Nothing was written to get that answer: a default is the absence of a
      // row, so issuing a player stays a single insert.
      final inventory = await server.store.inventory(me['id'] as String);
      expect(inventory.equipped, isEmpty);
      expect(inventory.ownedItemIds, isEmpty);
    });

    test('the prices are the same for everybody', () async {
      final a = await issuePlayer(server);
      final b = await issuePlayer(server);
      await grantTokens(server, a['id'] as String, 100);
      expect(
        (await postBuy(authOf(a), {'itemId': 'ball.comet'})).statusCode,
        200,
      );

      final mine = await itemsOf(authOf(a));
      final theirs = await itemsOf(authOf(b));
      for (final id in mine.keys) {
        expect(mine[id]!['priceTokens'], theirs[id]!['priceTokens']);
        expect(mine[id]!['free'], theirs[id]!['free']);
      }
      expect(mine['ball.comet']!['owned'], isTrue);
      expect(
        theirs['ball.comet']!['owned'],
        isFalse,
        reason: 'only the owned flag differs between two players',
      );
    });

    test('GET /api/health advertises the catalogue version', () async {
      final r = await http.get(api('/api/health'));
      expect(decode(r)['catalogue'], Catalogue.version);
    });
  });

  group('catalogue versioning', () {
    test('an item is only served to a client version that has it', () {
      // The mechanism, on the table itself: nothing is served to a client that
      // predates it, and every kind appears only from the version that
      // introduced it. Adding a ball is content and does not move the version;
      // adding a *kind* does, because an older build has no way to draw it.
      expect(Catalogue.upTo(0), isEmpty);
      expect(Catalogue.kindsUpTo(0), isEmpty);
      expect(Catalogue.upTo(Catalogue.version), Catalogue.items);
      for (final item in Catalogue.items) {
        expect(
          item.sinceVersion,
          lessThanOrEqualTo(Catalogue.version),
          reason:
              '${item.id} is marked as newer than the catalogue version, so no '
              'client would ever be served it',
        );
        expect(
          item.id,
          startsWith('${item.kind.name}.'),
          reason: 'an id says what kind it is without a lookup',
        );
      }
      for (final kind in CosmeticKind.values) {
        expect(
          Catalogue.defaultFor(kind).free,
          isTrue,
          reason: 'the default of a slot must cost nothing',
        );
        expect(Catalogue.countOf(kind), greaterThan(1));
      }
    });

    test(
      'a client asking for an older version is served that version',
      () async {
        final me = await issuePlayer(server);
        final r = await getCatalogue(authOf(me), version: '1');
        expect(r.statusCode, 200, reason: r.body);
        expect(decode(r)['version'], 1);
        expect(
          (decode(r)['items'] as List<dynamic>).length,
          Catalogue.upTo(1).length,
        );
      },
    );

    test('a client ahead of its server is clamped, not refused', () async {
      // An ordinary state during a rollout: the app updated before the server
      // did. The honest answer is what this server actually has.
      final me = await issuePlayer(server);
      final r = await getCatalogue(authOf(me), version: '99');
      expect(r.statusCode, 200, reason: r.body);
      expect(decode(r)['version'], Catalogue.version);
      expect(decode(r)['latestVersion'], Catalogue.version);
    });

    test('a v that is not a version is refused', () async {
      final me = await issuePlayer(server);
      for (final bad in <String>['abc', '0', '-3', '1.5']) {
        final r = await getCatalogue(authOf(me), version: bad);
        expect(r.statusCode, 400, reason: 'v=$bad → ${r.body}');
        expect(decode(r)['error'], invalidVersionError);
        expect(decode(r)['latestVersion'], Catalogue.version);
      }
    });
  });

  group('POST /api/shop/buy', () {
    test('buys an item, debits the wallet and records it', () async {
      final me = await issuePlayer(server);
      final id = me['id'] as String;
      await grantTokens(server, id, 200);

      final r = await postBuy(authOf(me), {'itemId': 'ball.comet'});
      expect(r.statusCode, 200, reason: r.body);
      final body = decode(r);
      expect(body['ok'], isTrue);
      expect(body['itemId'], 'ball.comet');
      expect(body['priceTokens'], 80);
      expect(body['charged'], 80);
      expect(body['alreadyOwned'], isFalse);
      expect(body['balance'], 120);
      expect(body['owned'], contains('ball.comet'));

      // And it is a fact about storage, not about one response.
      final inventory = await getInventory(authOf(me));
      expect(decode(inventory)['balance'], 120);
      expect(decode(inventory)['spentTotal'], 80);
      expect(decode(inventory)['earnedTotal'], 200);
      expect(decode(inventory)['owned'], contains('ball.comet'));
      expect((await itemsOf(authOf(me)))['ball.comet']!['owned'], isTrue);
    });

    test('refuses when the balance is short, and charges nothing', () async {
      final me = await issuePlayer(server);
      await grantTokens(server, me['id'] as String, 79);

      final r = await postBuy(authOf(me), {'itemId': 'ball.comet'});
      expect(r.statusCode, 402, reason: r.body);
      final body = decode(r);
      expect(body['ok'], isFalse);
      expect(body['error'], BuyOutcome.insufficientTokensError);
      expect(body['priceTokens'], 80);
      expect(
        body['balance'],
        79,
        reason: 'the client can say "you need 1 more"',
      );

      expect(await server.store.walletBalance(me['id'] as String), 79);
      expect(
        decode(await getInventory(authOf(me)))['owned'],
        isNot(contains('ball.comet')),
      );
    });

    test('a player with no wallet at all is refused the same way', () async {
      final me = await issuePlayer(server);
      final r = await postBuy(authOf(me), {'itemId': 'paddle.blade'});
      expect(r.statusCode, 402, reason: r.body);
      expect(decode(r)['balance'], 0);
    });

    test('buying twice charges once', () async {
      final me = await issuePlayer(server);
      final id = me['id'] as String;
      await grantTokens(server, id, 200);

      final first = await postBuy(authOf(me), {'itemId': 'ball.comet'});
      expect(decode(first)['charged'], 80);

      // What a phone on a flaky network does after a lost response.
      final again = await postBuy(authOf(me), {'itemId': 'ball.comet'});
      expect(again.statusCode, 200, reason: again.body);
      expect(decode(again)['alreadyOwned'], isTrue);
      expect(decode(again)['charged'], 0);
      expect(decode(again)['balance'], 120);
      expect(await server.store.walletBalance(id), 120);
      expect(await server.store.inventory(id).then((i) => i.ownedItemIds), [
        'ball.comet',
      ]);
    });

    test('buying a free item succeeds and writes nothing', () async {
      final me = await issuePlayer(server);
      final r = await postBuy(authOf(me), {'itemId': 'theme.classic'});
      expect(r.statusCode, 200, reason: r.body);
      expect(decode(r)['alreadyOwned'], isTrue);
      expect(decode(r)['charged'], 0);
      // Free items are owned implicitly: an entitlement that is true for
      // everybody is not worth a row per player (SPEC §4.8).
      final inventory = await server.store.inventory(me['id'] as String);
      expect(inventory.ownedItemIds, isEmpty);
      expect(
        decode(await getInventory(authOf(me)))['owned'],
        contains('theme.classic'),
      );
    });

    test('an unknown item id is refused', () async {
      final me = await issuePlayer(server);
      await grantTokens(server, me['id'] as String, 200);
      for (final bad in <String>['ball.nope', 'theme', 'THEME.NEON', '../x']) {
        final r = await postBuy(authOf(me), {'itemId': bad});
        expect(r.statusCode, 404, reason: '$bad → ${r.body}');
        expect(decode(r)['error'], BuyOutcome.unknownItemError);
      }
      expect(await server.store.walletBalance(me['id'] as String), 200);
    });

    test('a client cannot send a price or a balance', () async {
      final me = await issuePlayer(server);
      await grantTokens(server, me['id'] as String, 200);
      // Everything but the item id is ignored, because there is no field in the
      // request the server would believe.
      final r = await postBuy(authOf(me), {
        'itemId': 'theme.glass',
        'priceTokens': 0,
        'price': 1,
        'balance': 999999,
        'charged': 0,
        'free': true,
        'owned': true,
      });
      expect(r.statusCode, 402, reason: r.body);
      expect(decode(r)['priceTokens'], 250);
      expect(decode(r)['balance'], 200);
      expect(await server.store.walletBalance(me['id'] as String), 200);
    });

    test('a malformed body is refused', () async {
      final me = await issuePlayer(server);
      for (final body in <Object?>[
        null,
        '',
        'not json',
        <String, Object?>{},
        {'itemId': 7},
        {'itemId': ''},
        [1, 2, 3],
      ]) {
        final r = await postBuy(authOf(me), body);
        expect(r.statusCode, 400, reason: '$body → ${r.body}');
        expect(decode(r)['error'], 'invalid_json');
      }
    });

    test('an oversized body is refused before it is parsed', () async {
      final me = await issuePlayer(server);
      final r = await postBuy(
        authOf(me),
        jsonEncode({
          'itemId': 'ball.comet',
          'pad': 'x' * (maxShopBodyBytes + 1),
        }),
      );
      expect(r.statusCode, 413, reason: r.body);
      expect(decode(r)['limit'], maxShopBodyBytes);
    });
  });

  group('POST /api/shop/equip', () {
    test('equips an owned item and reports every slot', () async {
      final me = await issuePlayer(server);
      await grantTokens(server, me['id'] as String, 200);
      expect(
        (await postBuy(authOf(me), {'itemId': 'ball.comet'})).statusCode,
        200,
      );

      final r = await postEquip(authOf(me), {'ball': 'ball.comet'});
      expect(r.statusCode, 200, reason: r.body);
      expect(decode(r)['equipped'], {
        'theme': 'theme.neon',
        'ball': 'ball.comet',
        'paddle': 'paddle.arc',
      });
      // It is a preference that follows the player, so it is readable again.
      expect(decode(await getInventory(authOf(me)))['equipped'], {
        'theme': 'theme.neon',
        'ball': 'ball.comet',
        'paddle': 'paddle.arc',
      });
    });

    test('a free item can be equipped without buying anything', () async {
      final me = await issuePlayer(server);
      final r = await postEquip(authOf(me), {'theme': 'theme.classic'});
      expect(r.statusCode, 200, reason: r.body);
      expect((decode(r)['equipped'] as Map)['theme'], 'theme.classic');
    });

    test('refuses something the player does not own', () async {
      final me = await issuePlayer(server);
      final r = await postEquip(authOf(me), {'theme': 'theme.glass'});
      expect(r.statusCode, 403, reason: r.body);
      expect(decode(r)['error'], EquipOutcome.notOwnedError);
      expect(decode(r)['itemId'], 'theme.glass');
      // Equipping grants nothing: the refusal leaves the slot as it was and the
      // item unowned.
      expect(
        (decode(await getInventory(authOf(me)))['equipped'] as Map)['theme'],
        'theme.neon',
      );
      expect(
        decode(await getInventory(authOf(me)))['owned'],
        isNot(contains('theme.glass')),
      );
    });

    test('a call that gets one slot wrong changes none of them', () async {
      final me = await issuePlayer(server);
      await grantTokens(server, me['id'] as String, 200);
      expect(
        (await postBuy(authOf(me), {'itemId': 'ball.comet'})).statusCode,
        200,
      );

      final r = await postEquip(authOf(me), {
        'ball': 'ball.comet',
        'theme': 'theme.glass',
      });
      expect(r.statusCode, 403, reason: r.body);
      // A partial equip would leave the player wearing half of what they asked
      // for, so the whole call is validated before anything is written.
      expect(decode(await getInventory(authOf(me)))['equipped'], {
        'theme': 'theme.neon',
        'ball': 'ball.orb',
        'paddle': 'paddle.arc',
      });
    });

    test('null puts a slot back to the free default', () async {
      final me = await issuePlayer(server);
      await grantTokens(server, me['id'] as String, 200);
      await postBuy(authOf(me), {'itemId': 'ball.comet'});
      await postEquip(authOf(me), {'ball': 'ball.comet'});

      final r = await postEquip(authOf(me), {'ball': null});
      expect(r.statusCode, 200, reason: r.body);
      expect((decode(r)['equipped'] as Map)['ball'], 'ball.orb');
      final stored = await server.store.inventory(me['id'] as String);
      expect(
        stored.equipped,
        isEmpty,
        reason: 'the default is the absence of a row, not a row naming it',
      );
      expect(stored.ownedItemIds, [
        'ball.comet',
      ], reason: 'unequipping is not unbuying');
    });

    test('an item in the wrong slot is refused', () async {
      final me = await issuePlayer(server);
      final r = await postEquip(authOf(me), {'ball': 'paddle.arc'});
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], EquipOutcome.wrongKindError);
      expect(decode(r)['itemId'], 'paddle.arc');
    });

    test('an unknown item is refused', () async {
      final me = await issuePlayer(server);
      final r = await postEquip(authOf(me), {'ball': 'ball.nope'});
      expect(r.statusCode, 404, reason: r.body);
      expect(decode(r)['error'], EquipOutcome.unknownItemError);
    });

    test('a slot this build has no kind for is refused', () async {
      // A newer client talking to an older server.
      final me = await issuePlayer(server);
      final r = await postEquip(authOf(me), {'trail': 'trail.sparks'});
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], EquipOutcome.unknownKindError);
      expect(decode(r)['kind'], 'trail');
    });

    test('a body naming no slot at all is refused', () async {
      final me = await issuePlayer(server);
      for (final body in <Object?>[
        <String, Object?>{},
        {'ball': 7},
      ]) {
        final r = await postEquip(authOf(me), body);
        expect(r.statusCode, 400, reason: '$body → ${r.body}');
        expect(decode(r)['error'], invalidSlotsError);
      }
    });
  });

  group('credentials', () {
    // Every shop endpoint fails closed (SPEC §4.4): what somebody owns and what
    // their wallet holds is theirs, and a wrong credential is never downgraded
    // to anonymous.
    final routes = <String, Future<http.Response> Function(String? auth)>{
      'GET /api/shop/catalogue': getCatalogue,
      'GET /api/shop/inventory': getInventory,
      'POST /api/shop/buy': (auth) => postBuy(auth, {'itemId': 'ball.comet'}),
      'POST /api/shop/equip': (auth) => postEquip(auth, {'ball': 'ball.orb'}),
    };

    test('no credentials is 401 missing_credentials', () async {
      for (final entry in routes.entries) {
        final r = await entry.value(null);
        expect(r.statusCode, 401, reason: '${entry.key} → ${r.body}');
        expect(decode(r)['error'], missingCredentialsError);
      }
    });

    test('wrong credentials is 401 invalid_credentials', () async {
      final me = await issuePlayer(server);
      final id = me['id'] as String;
      for (final header in <String>[
        playerAuth(id, 'not-the-secret'),
        playerAuth('0' * 32, me['secret'] as String),
        'Arco nonsense',
        'Bearer ${me['secret']}',
      ]) {
        for (final entry in routes.entries) {
          final r = await entry.value(header);
          expect(
            r.statusCode,
            401,
            reason: '${entry.key} / $header → ${r.body}',
          );
          expect(decode(r)['error'], invalidCredentialsError);
        }
      }
    });
  });

  group('rate limiting', () {
    test('shop calls are metered per IP like every other route', () async {
      final limited = await bootServer(
        shopLimiter: RateLimiter(limit: 2, window: const Duration(minutes: 1)),
      );
      final me = await issuePlayer(limited);
      Uri at(String path) => Uri.parse('${limited.baseUrl}$path');
      Future<http.Response> call() => http.get(
        at('/api/shop/catalogue'),
        headers: {'authorization': authOf(me)},
      );

      expect((await call()).statusCode, 200);
      expect((await call()).statusCode, 200);
      final refused = await call();
      expect(refused.statusCode, 429, reason: refused.body);
      expect(refused.headers['retry-after'], '60');
      expect(jsonDecode(refused.body), containsPair('error', 'rate_limited'));
      // The budget is spent before the credentials are even looked at, so a
      // flood of unauthenticated calls costs no database work.
      final anonymous = await http.get(at('/api/shop/catalogue'));
      expect(anonymous.statusCode, 429);
    });
  });

  group('concurrency', () {
    // A burst of purchases is exactly what the per-IP budget is there to stop,
    // so these two boot a server whose shop budget is out of the way: what is
    // under test is the wallet, not the limiter (which has its own test above).
    late ArcoServer busy;

    setUp(() async {
      busy = await bootServer(
        shopLimiter: RateLimiter(
          limit: 10000,
          window: const Duration(minutes: 1),
        ),
      );
    });

    Future<http.Response> buyFrom(Map<String, dynamic> me, String itemId) =>
        http.post(
          Uri.parse('${busy.baseUrl}/api/shop/buy'),
          headers: {
            'content-type': 'application/json',
            'authorization': authOf(me),
          },
          body: jsonEncode({'itemId': itemId}),
        );

    test('many simultaneous buys of one item charge exactly once', () async {
      final me = await issuePlayer(busy);
      final id = me['id'] as String;
      await grantTokens(busy, id, 200);

      final responses = await Future.wait(<Future<http.Response>>[
        for (var i = 0; i < 24; i++) buyFrom(me, 'ball.comet'),
      ]);
      for (final r in responses) {
        expect(r.statusCode, 200, reason: r.body);
      }
      final charged = responses.fold<int>(
        0,
        (sum, r) => sum + (decode(r)['charged'] as int),
      );
      expect(charged, 80, reason: 'the price was taken exactly once');
      expect(await busy.store.walletBalance(id), 120);
      expect((await busy.store.inventory(id)).ownedItemIds, ['ball.comet']);
    });

    test('simultaneous buys can never overdraw the wallet', () async {
      final me = await issuePlayer(busy);
      final id = me['id'] as String;
      // Enough for two of the cheaper items and nothing like enough for all
      // eight, so the burst has to be refused somewhere.
      await grantTokens(busy, id, 200);
      final paid = [
        for (final item in Catalogue.items)
          if (!item.free) item,
      ];
      expect(
        paid.fold<int>(0, (sum, i) => sum + i.priceTokens),
        greaterThan(200),
      );

      // Four rounds of the whole paid catalogue at once: 32 simultaneous
      // purchases against a wallet that can afford two of them.
      final responses = await Future.wait(<Future<http.Response>>[
        for (var round = 0; round < 4; round++)
          for (final item in paid) buyFrom(me, item.id),
      ]);

      var charged = 0;
      for (final r in responses) {
        expect(
          r.statusCode,
          anyOf(200, 402),
          reason: 'only success or "not enough tokens": ${r.body}',
        );
        final body = decode(r);
        expect(
          body['balance'],
          greaterThanOrEqualTo(0),
          reason: 'no response may ever report a negative balance',
        );
        if (r.statusCode == 200) charged += body['charged'] as int;
      }

      final balance = await busy.store.walletBalance(id);
      expect(balance, greaterThanOrEqualTo(0));
      expect(
        charged,
        200 - balance,
        reason: 'every token that left the wallet bought exactly one item',
      );
      final inventory = await busy.store.inventory(id);
      final spentOnOwned = inventory.ownedItemIds.fold<int>(
        0,
        (sum, owned) => sum + Catalogue.byId(owned)!.priceTokens,
      );
      expect(spentOnOwned, charged);
      expect(inventory.spentTotal, charged);
      expect(inventory.balance + inventory.spentTotal, 200);
    });
  });

  group('the shop follows the player', () {
    test('deleting a player takes the wallet and the items with it', () async {
      final me = await issuePlayer(server);
      final id = me['id'] as String;
      await grantTokens(server, id, 200);
      await postBuy(authOf(me), {'itemId': 'ball.comet'});
      await postEquip(authOf(me), {'ball': 'ball.comet'});
      expect(await server.store.walletBalance(id), 120);

      final deleted = await http.delete(
        api('/api/players/me'),
        headers: {'authorization': authOf(me)},
      );
      expect(deleted.statusCode, 200, reason: deleted.body);

      // A wallet, a shelf of cosmetics and a record of which runs paid for them
      // are all links between the person and their play (SPEC §4.5).
      final inventory = await server.store.inventory(id);
      expect(inventory.balance, 0);
      expect(inventory.ownedItemIds, isEmpty);
      expect(inventory.equipped, isEmpty);
      expect((await getInventory(authOf(me))).statusCode, 401);
    });

    test('a merge carries the wallet, the items and the slots across', () async {
      // Signing in on a second phone merges that phone's anonymous player into
      // the account (SPEC §4.5). Purchases and tokens belong to the person, so
      // they move with the scores — somebody who bought a theme on the second
      // phone before signing in must not watch it vanish when they do.
      final account = await issuePlayer(server);
      final local = await issuePlayer(server);
      final accountId = account['id'] as String;
      final localId = local['id'] as String;

      // Different days on purpose: the merge is a clean sum only when the two
      // halves did not each spend the same day's allowance. The case where they
      // did is the next test.
      await grantTokens(server, accountId, 100);
      await grantTokens(
        server,
        localId,
        200,
        from: DateTime.utc(2019, 6, 1, 12),
      );
      expect(
        (await postBuy(authOf(local), {'itemId': 'ball.comet'})).statusCode,
        200,
      );
      expect(
        (await postEquip(authOf(local), {'ball': 'ball.comet'})).statusCode,
        200,
      );

      // Link the account to the first player, then present it again from the
      // second: that is the merge, driven through the storage operation the
      // account endpoint uses.
      Future<AccountLinkResult> link(String? caller, String tokenHash) async {
        final credential = server.players.mintCredential();
        return server.store.linkAccount(
          AccountLinkRequest(
            provider: 'apple',
            subject: 'subject-42',
            callerPlayerId: caller,
            tokenHash: tokenHash,
            tokenExpiresAt: DateTime.now().toUtc().add(
              const Duration(hours: 1),
            ),
            newPlayerId: server.players.newId(),
            credentialId: credential.id,
            secretHash: credential.secretHash,
            now: DateTime.now().toUtc(),
          ),
        );
      }

      expect((await link(accountId, 'hash-one')).kind, AccountLinkKind.linked);
      final merged = await link(localId, 'hash-two');
      expect(merged.kind, AccountLinkKind.merged);
      expect(merged.playerId, accountId);

      final survivor = await server.store.inventory(accountId);
      expect(
        survivor.balance,
        220,
        reason: '100 of the account plus the 120 the absorbed player had left',
      );
      expect(survivor.spentTotal, 80);
      expect(survivor.ownedItemIds, ['ball.comet']);
      expect(
        survivor.equipped['ball'],
        'ball.comet',
        reason: 'the absorbed player had chosen it and the survivor had not',
      );
      final absorbed = await server.store.inventory(localId);
      expect(absorbed.balance, 0);
      expect(absorbed.ownedItemIds, isEmpty);
    });

    test('a merge re-applies the daily cap to the two ledgers together', () async {
      // The daily cap is "what one person may earn in a day" (SPEC §4.8). Two
      // anonymous players that each earned a full day's allowance on the same
      // day are, after a merge, one person who earned two — so the excess is
      // taken back rather than banked. Without this, farming tokens on throwaway
      // players and signing them all into one account would multiply the cap by
      // however many players somebody could be bothered to make.
      final account = await issuePlayer(server);
      final local = await issuePlayer(server);
      final accountId = account['id'] as String;
      final localId = local['id'] as String;
      final sameDay = DateTime.utc(2020, 5, 5, 12);
      await grantTokens(server, accountId, TokenRate.dailyCap, from: sameDay);
      await grantTokens(server, localId, TokenRate.dailyCap, from: sameDay);

      Future<AccountLinkResult> link(String? caller, String tokenHash) async {
        final credential = server.players.mintCredential();
        return server.store.linkAccount(
          AccountLinkRequest(
            provider: 'apple',
            subject: 'subject-99',
            callerPlayerId: caller,
            tokenHash: tokenHash,
            tokenExpiresAt: DateTime.now().toUtc().add(
              const Duration(hours: 1),
            ),
            newPlayerId: server.players.newId(),
            credentialId: credential.id,
            secretHash: credential.secretHash,
            now: DateTime.now().toUtc(),
          ),
        );
      }

      expect((await link(accountId, 'cap-one')).kind, AccountLinkKind.linked);
      expect((await link(localId, 'cap-two')).kind, AccountLinkKind.merged);

      final survivor = await server.store.inventory(accountId);
      expect(
        survivor.balance,
        TokenRate.dailyCap,
        reason: 'two allowances on one day are still one allowance',
      );
      expect(survivor.balance, greaterThanOrEqualTo(0));
    });
  });
}
