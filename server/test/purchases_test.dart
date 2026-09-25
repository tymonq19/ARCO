/// The one-time unlock, server side (SPEC §4.9).
///
/// One product, `arco.unlock.full`, non-consumable, bought once: every cosmetic
/// there is and every one added later, and no ads. The properties under test are
/// the ones that cost money — ours or a player's — if they break:
///
/// * **the client never says what it owns.** The webhook carries a price and the
///   sync path carries nothing at all; what a purchase grants is looked up in the
///   server's own `FullUnlock` and nowhere else.
/// * **premium is ownership of everything, answered rather than stored**, so an
///   item added to the catalogue after the purchase is covered with nothing to
///   backfill.
/// * **one payment grants once**, even when the webhook arrives twice, even when
///   the client nudge and the webhook race, and even when both see the same store
///   transaction.
/// * **a refund revokes premium and leaves Spark-bought cosmetics alone**, which
///   is the documented decision rather than an accident.
/// * **a non-consumable genuinely restores**: a reinstall or a second device
///   recovers premium through the sync path, from RevenueCat's own record.
/// * **an unknown product is refused** instead of granted at a guess.
/// * **the ledger explains an entitlement**: premium is one row naming the store
///   transaction that paid for it.
/// * **the env switch turns the whole thing off cleanly** — no product in the
///   catalogue, `404` from both endpoints, and a server that refuses to start
///   half-configured.
///
/// No test reaches RevenueCat: the server is pointed at [FakeRevenueCat] on
/// loopback, and the webhook is posted by the test itself with the shared secret
/// the server is configured with.
library;

import 'dart:convert';

import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  Map<String, dynamic> decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Future<http.Response> postWebhook(
    ArcoServer server,
    Object? body, {
    String? secret = testWebhookSecret,
  }) => http.post(
    Uri.parse('${server.baseUrl}/api/purchases/webhook'),
    headers: {'content-type': 'application/json', 'authorization': ?secret},
    body: body == null ? null : (body is String ? body : jsonEncode(body)),
  );

  Future<http.Response> postSync(ArcoServer server, String? auth) => http.post(
    Uri.parse('${server.baseUrl}/api/purchases/sync'),
    headers: {'content-type': 'application/json', 'authorization': ?auth},
    body: '{}',
  );

  Future<http.Response> getCatalogue(ArcoServer server, String auth) =>
      http.get(
        Uri.parse('${server.baseUrl}/api/shop/catalogue'),
        headers: {'authorization': auth},
      );

  Future<http.Response> getInventory(ArcoServer server, String auth) =>
      http.get(
        Uri.parse('${server.baseUrl}/api/shop/inventory'),
        headers: {'authorization': auth},
      );

  Future<http.Response> buy(ArcoServer server, String auth, String itemId) =>
      http.post(
        Uri.parse('${server.baseUrl}/api/shop/buy'),
        headers: {'content-type': 'application/json', 'authorization': auth},
        body: jsonEncode({'itemId': itemId}),
      );

  Future<http.Response> equip(
    ArcoServer server,
    String auth,
    Map<String, String?> slots,
  ) => http.post(
    Uri.parse('${server.baseUrl}/api/shop/equip'),
    headers: {'content-type': 'application/json', 'authorization': auth},
    body: jsonEncode(slots),
  );

  group('the product', () {
    test('one product, with an id both stores accept, and no price', () {
      // Lowercase letters, digits and dots: the intersection of App Store
      // Connect's and the Play Console's rules, so one id serves both. The same
      // rule the three Spark packs followed, which is why one id could replace
      // them without either store having to be argued with.
      expect(
        FullUnlock.productId,
        matches(RegExp(r'^[a-z][a-z0-9.]*[a-z0-9]$')),
        reason: '${FullUnlock.productId} must be usable in both stores',
      );
      expect(FullUnlock.product.productId, FullUnlock.productId);
      expect(FullUnlock.product.nameKey, 'unlock.full');
      // The one field that must never exist. A price here would be wrong in most
      // markets and would drift from the stores the moment a tier changed; the
      // only honest price is the localised one the device's own store reports.
      expect(FullUnlock.product.toJson().keys, {'productId', 'nameKey'});
      expect(
        FullUnlock.product.toJson().keys.any(
          (k) => k.toLowerCase().contains('price'),
        ),
        isFalse,
      );
    });

    test('it is attached to a RevenueCat entitlement', () {
      // What a non-consumable is, in RevenueCat's own vocabulary: a permanent
      // thing a customer either holds or does not. A consumable had nothing to
      // attach an entitlement to, which is exactly why restoring was an apology.
      expect(FullUnlock.premiumEntitlement, 'premium');
    });

    test('nothing else is the unlock', () {
      expect(FullUnlock.isUnlock(FullUnlock.productId), isTrue);
      expect(FullUnlock.isUnlock(null), isFalse);
      expect(FullUnlock.isUnlock(''), isFalse);
      // The Spark packs this build no longer sells are not it either, which is
      // what makes a legacy ledger row grant nothing.
      expect(FullUnlock.isUnlock('arco.sparks.small'), isFalse);
      expect(FullUnlock.isUnlock('arco.unlock.full.pro'), isFalse);
      // And the two tables must not overlap: a product id that is also an item id
      // would make "what did this buy" ambiguous in the ledger.
      for (final item in Catalogue.items) {
        expect(FullUnlock.isUnlock(item.id), isFalse, reason: item.id);
      }
    });

    test('a client too old for it is served no product', () {
      expect(FullUnlock.upTo(1)?.productId, FullUnlock.productId);
      expect(
        FullUnlock.upTo(0),
        isNull,
        reason: 'a version that predates the product cannot be sold it',
      );
    });
  });

  group('the guards on talking to RevenueCat', () {
    test('a secret API key never goes out over plain HTTP', () {
      // The only exception is loopback, which is how the tests point the server
      // at their own fake — and nothing else.
      expect(
        isFetchableRevenueCatUri(Uri.parse('https://api.revenuecat.com/v1/x')),
        isTrue,
      );
      expect(
        isFetchableRevenueCatUri(Uri.parse('http://127.0.0.1:8080/v1/x')),
        isTrue,
      );
      expect(
        isFetchableRevenueCatUri(Uri.parse('http://localhost:8080/v1/x')),
        isTrue,
      );
      expect(
        isFetchableRevenueCatUri(Uri.parse('http://api.revenuecat.com/v1/x')),
        isFalse,
        reason: 'a key on the wire in clear is a key somebody else has',
      );
      expect(
        isFetchableRevenueCatUri(Uri.parse('http://10.0.0.5/v1/x')),
        isFalse,
      );
      expect(isFetchableRevenueCatUri(Uri.parse('ftp://x/v1')), isFalse);
      expect(
        isFetchableRevenueCatUri(Uri.parse('file:///etc/passwd')),
        isFalse,
      );
    });

    test('a refusal to fetch is an exception, not a silent empty answer', () {
      expect(
        () => fetchRevenueCatOverHttps(
          Uri.parse('http://api.revenuecat.com/v1/subscribers/x'),
          'sk_test',
          const Duration(seconds: 1),
        ),
        throwsA(isA<RevenueCatException>()),
      );
    });
  });

  group('reading a webhook event', () {
    test('the original transaction id wins, because it is the payment', () {
      // Apple reissues a transaction id on a restore — which a non-consumable
      // makes an everyday event rather than a curiosity. Granting has to be keyed
      // on the id that identifies the *payment*, or one purchase becomes two.
      final event = WebhookEvent.parse({
        'event': {
          'type': 'NON_RENEWING_PURCHASE',
          'app_user_id': 'abc',
          'product_id': FullUnlock.productId,
          'transaction_id': 'reissued-2',
          'original_transaction_id': 'original-1',
        },
      })!;
      expect(event.transactionId, 'original-1');
    });

    test('every app user id the event names is offered, in order', () {
      final event = WebhookEvent.parse({
        'event': {
          'type': 'NON_RENEWING_PURCHASE',
          'app_user_id': 'a',
          'original_app_user_id': 'b',
          'aliases': ['b', 'c'],
        },
      })!;
      expect(event.appUserIds, [
        'a',
        'b',
        'c',
      ], reason: 'deduplicated, ordered');
    });

    test('the environment decides whether it is real money', () {
      WebhookEvent at(String environment) => WebhookEvent.parse({
        'event': {'type': 'NON_RENEWING_PURCHASE', 'environment': environment},
      })!;
      expect(at('SANDBOX').isSandbox, isTrue);
      expect(at('sandbox').isSandbox, isTrue);
      expect(at('PRODUCTION').isSandbox, isFalse);
      // Absent reads as production, which is the safe direction: a real payment
      // is granted, and a sandbox one that forgot to say so is the store's bug.
      expect(
        WebhookEvent.parse({
          'event': {'type': 'NON_RENEWING_PURCHASE'},
        })!.isSandbox,
        isFalse,
      );
    });

    test('a body with no event, or no type, is not an event', () {
      expect(WebhookEvent.parse(null), isNull);
      expect(WebhookEvent.parse('a string'), isNull);
      expect(WebhookEvent.parse(<String, dynamic>{}), isNull);
      expect(WebhookEvent.parse({'event': 'not an object'}), isNull);
      expect(
        WebhookEvent.parse({
          'event': {'app_user_id': 'a'},
        }),
        isNull,
      );
    });

    test('only the granting types grant, and the revoking ones revoke', () {
      expect(grantingEventTypes.intersection(revokingEventTypes), isEmpty);
      // A non-consumable arrives as NON_RENEWING_PURCHASE: RevenueCat uses that
      // type for every purchase that will not auto-renew.
      expect(grantingEventTypes, contains('NON_RENEWING_PURCHASE'));
      for (final type in grantingEventTypes) {
        final event = WebhookEvent.parse({
          'event': {'type': type},
        })!;
        expect(event.grants, isTrue);
        expect(event.revokes, isFalse);
      }
      for (final type in revokingEventTypes) {
        final event = WebhookEvent.parse({
          'event': {'type': type},
        })!;
        expect(event.revokes, isTrue);
        expect(event.grants, isFalse);
      }
    });
  });

  group('configuration', () {
    test('off by default, and nothing else changes', () async {
      final config = ServerConfig.fromEnvironment(const {});
      expect(config.purchases.enabled, isFalse);
      expect(config.purchases.hasUnusedKeys, isFalse);
    });

    test('on with both secrets', () {
      final config = ServerConfig.fromEnvironment(const {
        'PURCHASES_ENABLED': 'on',
        'REVENUECAT_WEBHOOK_SECRET': 'whsec-abc',
        'REVENUECAT_API_KEY': 'sk_abc',
      });
      expect(config.purchases.enabled, isTrue);
      expect(config.purchases.webhookSecret, 'whsec-abc');
      expect(config.purchases.apiKey, 'sk_abc');
      expect(config.purchases.creditSandbox, isFalse);
    });

    test('refuses to start enabled without the webhook secret', () {
      expect(
        () => ServerConfig.fromEnvironment(const {
          'PURCHASES_ENABLED': 'on',
          'REVENUECAT_API_KEY': 'sk_abc',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('REVENUECAT_WEBHOOK_SECRET'),
          ),
        ),
      );
    });

    test('refuses to start enabled without the API key', () {
      expect(
        () => ServerConfig.fromEnvironment(const {
          'PURCHASES_ENABLED': 'on',
          'REVENUECAT_WEBHOOK_SECRET': 'whsec-abc',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('REVENUECAT_API_KEY'),
          ),
        ),
      );
    });

    test('names both when both are missing', () {
      expect(
        () => ServerConfig.fromEnvironment(const {'PURCHASES_ENABLED': 'on'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('REVENUECAT_WEBHOOK_SECRET'),
              contains('REVENUECAT_API_KEY'),
            ),
          ),
        ),
      );
    });

    test('keys set with the switch off start normally and are flagged', () {
      final config = ServerConfig.fromEnvironment(const {
        'REVENUECAT_WEBHOOK_SECRET': 'whsec-abc',
        'REVENUECAT_API_KEY': 'sk_abc',
      });
      expect(config.purchases.enabled, isFalse);
      expect(config.purchases.hasUnusedKeys, isTrue);
    });

    test('a secret with whitespace is a quoting accident, not a secret', () {
      expect(
        () => ServerConfig.fromEnvironment(const {
          'PURCHASES_ENABLED': 'on',
          'REVENUECAT_WEBHOOK_SECRET': 'whsec abc',
          'REVENUECAT_API_KEY': 'sk_abc',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('PURCHASES_ENABLED must be on or off', () {
      expect(
        () => ServerConfig.fromEnvironment(const {'PURCHASES_ENABLED': 'yes'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('a secret is never in toString', () {
      final config = testPurchasesConfig();
      expect(config.toString(), isNot(contains(testWebhookSecret)));
      expect(config.toString(), isNot(contains('sk_test_key')));
    });
  });

  group('switched off', () {
    late ArcoServer server;

    setUp(() async {
      server = await bootServer();
    });

    test('the catalogue advertises no product at all', () async {
      final me = await issuePlayer(server);
      final r = await getCatalogue(server, authOf(me));
      expect(r.statusCode, 200, reason: r.body);
      expect(
        decode(r).containsKey('unlock'),
        isFalse,
        reason: 'a shop that cannot take money must not offer something to buy',
      );
      expect(decode(r)['premium'], isFalse);
    });

    test('health says so, exactly as it does for accounts', () async {
      final r = await http.get(Uri.parse('${server.baseUrl}/api/health'));
      expect(decode(r)['purchases'], isFalse);
    });

    test('the webhook is a 404, even with a correct-looking secret', () async {
      final r = await postWebhook(
        server,
        purchaseWebhookBody(appUserId: testPlayerId(1), transactionId: 'txn-1'),
      );
      expect(r.statusCode, 404);
      expect(decode(r)['error'], purchasesDisabledError);
    });

    test('the sync endpoint is a 404 for an authenticated player', () async {
      final me = await issuePlayer(server);
      final r = await postSync(server, authOf(me));
      expect(r.statusCode, 404);
      expect(decode(r)['error'], purchasesDisabledError);
      expect(await server.store.purchaseCount(), 0);
    });

    test('the rest of the shop is untouched', () async {
      final me = await issuePlayer(server);
      await grantTokens(server, me['id'] as String, 100);
      final r = await buy(server, authOf(me), 'ball.comet');
      expect(r.statusCode, 200, reason: r.body);
      expect(decode(r)['charged'], 80);
    });
  });

  group('switched on', () {
    late ArcoServer server;
    late FakeRevenueCat revenueCat;

    setUp(() async {
      revenueCat = await FakeRevenueCat.start();
      server = await bootServer(
        purchases: testPurchasesConfig(),
        revenueCatBaseUri: revenueCat.baseUri,
      );
    });

    test('the catalogue advertises the unlock, with no price', () async {
      final me = await issuePlayer(server);
      final r = await getCatalogue(server, authOf(me));
      expect(r.statusCode, 200, reason: r.body);
      final body = decode(r);
      final unlock = body['unlock'] as Map<String, dynamic>;
      expect(unlock, {
        'productId': FullUnlock.productId,
        'nameKey': 'unlock.full',
      });
      expect(
        unlock.keys.any((k) => k.toLowerCase().contains('price')),
        isFalse,
        reason: "the price is the store's, localised, never ours",
      );
      expect(body['premium'], isFalse);
      expect(body['balance'], 0);
      // The free path is untouched beside it: every item still carries the Spark
      // price a player who never pays earns their way to.
      final items = (body['items'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(items, hasLength(Catalogue.items.length));
      expect(
        items.firstWhere((i) => i['id'] == 'theme.glass')['priceTokens'],
        250,
      );
    });

    test('health says the deployment can take money', () async {
      final r = await http.get(Uri.parse('${server.baseUrl}/api/health'));
      expect(decode(r)['purchases'], isTrue);
    });

    group('the webhook secret', () {
      test('a webhook with no Authorization grants nothing', () async {
        final me = await issuePlayer(server);
        final r = await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: me['id'] as String,
            transactionId: 'txn-1',
          ),
          secret: null,
        );
        expect(r.statusCode, 401);
        expect(decode(r)['error'], invalidSignatureError);
        expect(await server.store.isPremium(me['id'] as String), isFalse);
        expect(await server.store.purchaseCount(), 0);
      });

      test('a wrong secret grants nothing', () async {
        final me = await issuePlayer(server);
        final r = await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: me['id'] as String,
            transactionId: 'txn-1',
          ),
          secret: 'whsec-test-0123456788',
        );
        expect(r.statusCode, 401);
        expect(await server.store.isPremium(me['id'] as String), isFalse);
      });

      test('a missing and a wrong secret are the same code', () async {
        final body = purchaseWebhookBody(
          appUserId: testPlayerId(9),
          transactionId: 'txn-x',
        );
        final missing = await postWebhook(server, body, secret: null);
        final wrong = await postWebhook(server, body, secret: 'nope');
        expect(decode(missing)['error'], decode(wrong)['error']);
      });

      test('`Bearer <secret>` is accepted as well as the bare value', () async {
        final me = await issuePlayer(server);
        final r = await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: me['id'] as String,
            transactionId: 'txn-bearer',
          ),
          secret: 'Bearer $testWebhookSecret',
        );
        expect(r.statusCode, 200, reason: r.body);
        expect(await server.store.isPremium(me['id'] as String), isTrue);
      });

      test('the secret is checked before the body is parsed', () async {
        final r = await postWebhook(server, 'not json at all', secret: null);
        expect(
          r.statusCode,
          401,
          reason: 'an unauthenticated caller buys no JSON decoding',
        );
      });
    });

    group('granting premium', () {
      test('a completed purchase makes the player premium', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final r = await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-1'),
        );
        expect(r.statusCode, 200, reason: r.body);
        final body = decode(r);
        expect(body['ok'], isTrue);
        expect(body['granted'], isTrue);
        expect(body['duplicate'], isFalse);
        expect(body['playerId'], id);
        expect(body['productId'], FullUnlock.productId);
        expect(body['premium'], isTrue);
        expect(await server.store.isPremium(id), isTrue);
      });

      test(
        'premium is every item in the catalogue, including ones added later',
        () async {
          final me = await issuePlayer(server);
          final id = me['id'] as String;
          await postWebhook(
            server,
            purchaseWebhookBody(appUserId: id, transactionId: 'txn-all'),
          );

          final body = decode(await getCatalogue(server, authOf(me)));
          final items = (body['items'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          expect(body['premium'], isTrue);
          for (final item in items) {
            expect(item['owned'], isTrue, reason: '${item['id']}');
          }
          // `owned` is the catalogue itself, asserted as an equality rather than
          // as a list of ids: whatever the catalogue holds, premium holds.
          final inventory = decode(await getInventory(server, authOf(me)));
          expect((inventory['owned'] as List<dynamic>).cast<String>(), [
            for (final item in items) item['id'] as String,
          ]);

          // **And this is why an item added next year needs no backfill.** The
          // grant wrote no row naming any item — not one — so ownership is a
          // question answered against the catalogue at the moment it is asked.
          // An item appended to `Catalogue.items` is inside that answer for
          // exactly the reason `theme.glass` is: nobody wrote a row for either,
          // and there is no stored set that could be missing it.
          final stored = await server.store.inventory(id);
          expect(
            stored.ownedItemIds,
            isEmpty,
            reason: 'premium wrote no row in player_items, for any item',
          );
          expect(stored.premium, isTrue);
          for (final item in Catalogue.items) {
            expect(
              await server.store.ownsItem(id, item.id),
              isTrue,
              reason: item.id,
            );
          }
        },
      );

      test('a premium player may wear what they never bought', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-equip'),
        );
        final r = await equip(server, authOf(me), {
          'theme': 'theme.glass',
          'ball': 'ball.ember',
          'paddle': 'paddle.chevron',
        });
        expect(r.statusCode, 200, reason: r.body);
        expect(decode(r)['equipped'], {
          'theme': 'theme.glass',
          'ball': 'ball.ember',
          'paddle': 'paddle.chevron',
        });
        expect(
          (await server.store.inventory(id)).ownedItemIds,
          isEmpty,
          reason: 'wearing is a preference; it buys nothing',
        );
        expect(await server.store.walletBalance(id), 0);
      });

      test('what it grants comes from the server, not the event', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        // An event decorated with every shape somebody might hope the server
        // believes. None of them is read: the product id is the only field that
        // decides anything, and what it grants is looked up here.
        final body = purchaseWebhookBody(appUserId: id, transactionId: 'txn-1');
        body['event'] = {
          ...(body['event'] as Map<String, dynamic>),
          'entitlements': ['premium', 'everything', 'admin'],
          'sparks': 1000000,
          'price': 999999,
          'quantity': 50,
          'grants': ['theme.glass'],
        };
        final r = await postWebhook(server, body);
        expect(r.statusCode, 200, reason: r.body);
        expect(decode(r)['premium'], isTrue);
        // Premium and nothing else: no Sparks appeared, and no item row either.
        expect(await server.store.walletBalance(id), 0);
        expect((await server.store.inventory(id)).ownedItemIds, isEmpty);
      });

      test(
        'the same webhook twice grants exactly once (retries are normal)',
        () async {
          final me = await issuePlayer(server);
          final id = me['id'] as String;
          final body = purchaseWebhookBody(
            appUserId: id,
            transactionId: 'txn-retry',
          );

          final first = await postWebhook(server, body);
          expect(first.statusCode, 200, reason: first.body);
          expect(decode(first)['granted'], isTrue);
          expect(decode(first)['duplicate'], isFalse);

          final second = await postWebhook(server, body);
          expect(
            second.statusCode,
            200,
            reason: 'a 2xx is what makes RevenueCat stop retrying',
          );
          expect(decode(second)['granted'], isFalse);
          expect(decode(second)['duplicate'], isTrue);
          expect(
            decode(second)['premium'],
            isTrue,
            reason: 'the replay reports the state the player is actually in',
          );

          expect(await server.store.isPremium(id), isTrue);
          expect(await server.store.purchaseCount(), 1);
        },
      );

      test('ten deliveries of one purchase still grant once', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final body = purchaseWebhookBody(
          appUserId: id,
          transactionId: 'txn-storm',
        );
        for (var i = 0; i < 10; i++) {
          expect((await postWebhook(server, body)).statusCode, 200);
        }
        expect(await server.store.isPremium(id), isTrue);
        expect(await server.store.purchaseCount(), 1);
      });

      test(
        'a transaction already granted to one player unlocks for no other',
        () async {
          final mine = await issuePlayer(server);
          final yours = await issuePlayer(server);
          const txn = 'txn-shared';
          await postWebhook(
            server,
            purchaseWebhookBody(
              appUserId: mine['id'] as String,
              transactionId: txn,
            ),
          );
          // The same store receipt, replayed under somebody else's app user id.
          final r = await postWebhook(
            server,
            purchaseWebhookBody(
              appUserId: yours['id'] as String,
              transactionId: txn,
            ),
          );
          expect(r.statusCode, 200);
          expect(decode(r)['granted'], isFalse);
          expect(
            decode(r)['premium'],
            isFalse,
            reason: 'the answer is about the asking player, not about the row',
          );
          expect(
            await server.store.isPremium(yours['id'] as String),
            isFalse,
            reason: 'a leaked receipt is worth nothing to whoever leaked it',
          );
          expect(await server.store.isPremium(mine['id'] as String), isTrue);
        },
      );

      test('an unknown product is refused, not granted at a guess', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final r = await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: id,
            productId: 'arco.unlock.everything.pro',
            transactionId: 'txn-unknown',
          ),
        );
        expect(r.statusCode, 400);
        expect(decode(r)['error'], PurchaseGrant.unknownProductError);
        expect(decode(r)['productId'], 'arco.unlock.everything.pro');
        expect(await server.store.isPremium(id), isFalse);
        expect(
          await server.store.purchaseCount(),
          0,
          reason: 'nothing is written for a product we do not sell',
        );
      });

      test('a Spark pack this build no longer sells is refused', () async {
        // Nobody holds one — nothing has shipped — but a webhook naming one is a
        // misconfiguration, and the honest answer is the non-2xx that shows up as
        // failed in RevenueCat's dashboard rather than a silent nothing.
        final me = await issuePlayer(server);
        final r = await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: me['id'] as String,
            productId: 'arco.sparks.small',
            transactionId: 'txn-legacy',
          ),
        );
        expect(r.statusCode, 400);
        expect(decode(r)['error'], PurchaseGrant.unknownProductError);
        expect(await server.store.isPremium(me['id'] as String), isFalse);
      });

      test('a cosmetic item id is not a product id', () async {
        final me = await issuePlayer(server);
        final r = await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: me['id'] as String,
            productId: 'theme.glass',
            transactionId: 'txn-cosmetic',
          ),
        );
        expect(r.statusCode, 400);
        expect(decode(r)['error'], PurchaseGrant.unknownProductError);
      });

      test('an app user id that is not a player is refused', () async {
        final r = await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: testPlayerId(4242),
            transactionId: 'txn-nobody',
          ),
        );
        expect(r.statusCode, 404);
        expect(decode(r)['error'], unknownPlayerError);
        expect(await server.store.purchaseCount(), 0);
      });

      test(
        'a RevenueCat anonymous id never reaches the database as a player',
        () async {
          final r = await postWebhook(
            server,
            purchaseWebhookBody(
              appUserId: r'$RCAnonymousID:5f7e1a',
              transactionId: 'txn-anon',
            ),
          );
          expect(r.statusCode, 404);
          expect(decode(r)['error'], unknownPlayerError);
        },
      );

      test(
        'an alias is tried when the primary app user id is not ours',
        () async {
          final me = await issuePlayer(server);
          final id = me['id'] as String;
          final r = await postWebhook(
            server,
            purchaseWebhookBody(
              appUserId: r'$RCAnonymousID:abc',
              originalAppUserId: r'$RCAnonymousID:abc',
              aliases: <String>[id],
              transactionId: 'txn-alias',
            ),
          );
          expect(r.statusCode, 200, reason: r.body);
          expect(await server.store.isPremium(id), isTrue);
        },
      );

      test('a granting event with no transaction id is a 400', () async {
        final me = await issuePlayer(server);
        final body = purchaseWebhookBody(
          appUserId: me['id'] as String,
          transactionId: 'ignored',
        );
        body['event'] = (body['event'] as Map<String, dynamic>)
          ..remove('transaction_id')
          ..remove('original_transaction_id');
        final r = await postWebhook(server, body);
        expect(r.statusCode, 400);
        expect(
          decode(r)['error'],
          invalidEventError,
          reason: 'with no idempotency key there is no safe way to grant',
        );
        expect(await server.store.purchaseCount(), 0);
      });

      test('a body that is not a RevenueCat event is a 400', () async {
        expect((await postWebhook(server, '{')).statusCode, 400);
        expect((await postWebhook(server, {'nope': 1})).statusCode, 400);
        expect(
          (await postWebhook(server, {
            'event': {'no_type': true},
          })).statusCode,
          400,
        );
      });

      test('an event type we do nothing with is acknowledged', () async {
        final me = await issuePlayer(server);
        for (final type in const [
          'TEST',
          'RENEWAL',
          'TRANSFER',
          'EXPIRATION',
        ]) {
          final r = await postWebhook(
            server,
            purchaseWebhookBody(
              appUserId: me['id'] as String,
              transactionId: 'txn-$type',
              type: type,
            ),
          );
          expect(
            r.statusCode,
            200,
            reason: 'a non-2xx would have RevenueCat retry $type forever',
          );
          expect(decode(r)['granted'], isFalse);
          expect(decode(r)['ignored'], type);
        }
        expect(await server.store.isPremium(me['id'] as String), isFalse);
      });

      test('a sandbox purchase is acknowledged and not granted', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final r = await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: id,
            transactionId: 'txn-sandbox',
            environment: 'SANDBOX',
          ),
        );
        expect(r.statusCode, 200, reason: r.body);
        expect(decode(r)['ignored'], 'sandbox');
        expect(
          await server.store.isPremium(id),
          isFalse,
          reason: 'a sandbox account can buy all day, for nothing',
        );
        expect(await server.store.purchaseCount(), 0);
      });
    });

    group('Sparks are untouched beside it', () {
      test('the unlock credits no Sparks and spends no allowance', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-cap'),
        );
        final body = decode(await getInventory(server, authOf(me)));
        expect(body['premium'], isTrue);
        expect(body['balance'], 0, reason: 'money buys the unlock, not Sparks');
        expect(body['purchasedTotal'], 0);
        expect(body['earnedTotal'], 0);
        expect(
          body['earnedToday'],
          0,
          reason: 'money is not play; buying must not spend the allowance',
        );
        expect(body['dailyCap'], TokenRate.dailyCap);
      });

      test('a premium player still earns Sparks, harmlessly', () async {
        // The honest consequence of one purchase covering everything: a premium
        // player keeps earning and has nothing left to spend on. That has to read
        // as "you already own this", never as an error.
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-earn'),
        );
        await grantTokens(server, id, 120);

        final inventory = decode(await getInventory(server, authOf(me)));
        expect(
          inventory['balance'],
          120,
          reason: 'the wallet still works and still says what it holds',
        );
        expect(inventory['earnedTotal'], 120);

        // A buy — from a stale screen, an older build, a mis-tap — succeeds,
        // costs nothing and says why.
        final bought = await buy(server, authOf(me), 'theme.glass');
        expect(bought.statusCode, 200, reason: bought.body);
        final body = decode(bought);
        expect(body['alreadyOwned'], isTrue);
        expect(body['charged'], 0);
        expect(body['premium'], isTrue);
        expect(body['balance'], 120, reason: 'not a Spark was taken');
        expect((await server.store.inventory(id)).ownedItemIds, isEmpty);

        // And the shop stops offering the unlock, because there is nothing left
        // to sell: the section is simply not in the answer.
        final catalogue = decode(await getCatalogue(server, authOf(me)));
        expect(catalogue['premium'], isTrue);
        expect(catalogue.containsKey('unlock'), isFalse);
      });

      test('a non-premium player is unaffected by any of this', () async {
        final me = await issuePlayer(server);
        final other = await issuePlayer(server);
        // Somebody else buys the unlock.
        await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: other['id'] as String,
            transactionId: 'txn-somebody-else',
          ),
        );

        final id = me['id'] as String;
        await grantTokens(server, id, 100);
        final inventory = decode(await getInventory(server, authOf(me)));
        expect(inventory['premium'], isFalse);
        expect(
          (inventory['owned'] as List<dynamic>).cast<String>(),
          <String>['theme.neon', 'theme.classic', 'ball.orb', 'paddle.arc'],
          reason: 'the free items, and only those',
        );

        // The Spark path works exactly as it always did: pay the price, own the
        // item, and the shop still offers the unlock.
        final bought = await buy(server, authOf(me), 'ball.comet');
        expect(bought.statusCode, 200, reason: bought.body);
        expect(decode(bought)['charged'], 80);
        expect(decode(bought)['premium'], isFalse);
        expect(await server.store.walletBalance(id), 20);

        // And an item they cannot afford is still a 402, not a free ride.
        final refused = await buy(server, authOf(me), 'theme.glass');
        expect(refused.statusCode, 402);
        expect(decode(refused)['error'], BuyOutcome.insufficientTokensError);

        final catalogue = decode(await getCatalogue(server, authOf(me)));
        expect(
          (catalogue['unlock'] as Map<String, dynamic>)['productId'],
          FullUnlock.productId,
        );
      });

      test('the daily cap still behaves for a premium player', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-daily'),
        );
        final today = DateTime.now().toUtc();
        // Capped runs until the day's allowance is gone, then one more: premium
        // changes nothing about the rate or the cap.
        var earned = 0;
        for (var run = 1; earned < TokenRate.dailyCap; run++) {
          final award = await server.store.awardTokens(
            playerId: id,
            scoreId: 'run-$run',
            score: TokenRate.maxTokensPerRun * TokenRate.scorePerToken,
            replayKey: 'key-$run',
            now: today,
          );
          expect(award.tokens, greaterThan(0));
          earned += award.tokens;
        }
        expect(earned, TokenRate.dailyCap);
        final capped = await server.store.awardTokens(
          playerId: id,
          scoreId: 'run-over',
          score: 5000,
          replayKey: 'key-over',
          now: today,
        );
        expect(capped.tokens, 0);
        expect(capped.cappedByDay, isTrue);
        expect(await server.store.walletBalance(id), TokenRate.dailyCap);
      });
    });

    group('refunds', () {
      test('a refund revokes premium', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-r'),
        );
        expect(await server.store.isPremium(id), isTrue);

        final r = await postWebhook(
          server,
          refundWebhookBody(appUserId: id, transactionId: 'txn-r'),
        );
        expect(r.statusCode, 200, reason: r.body);
        final body = decode(r);
        expect(body['revoked'], isTrue);
        expect(body['premium'], isFalse);
        expect(body['playerId'], id);
        expect(await server.store.isPremium(id), isFalse);

        // And the catalogue reads as it did before the purchase, offer included.
        final catalogue = decode(await getCatalogue(server, authOf(me)));
        expect(catalogue['premium'], isFalse);
        expect(
          (catalogue['unlock'] as Map<String, dynamic>)['productId'],
          FullUnlock.productId,
        );
        expect(
          [
            for (final item
                in (catalogue['items'] as List<dynamic>)
                    .cast<Map<String, dynamic>>())
              if (item['owned'] == true) item['id'],
          ],
          <String>['theme.neon', 'theme.classic', 'ball.orb', 'paddle.arc'],
        );
      });

      test('a refund keeps the cosmetics bought with Sparks', () async {
        // The decision this feature had to make, and it is not a close call:
        // those were paid for separately, with Sparks earned by playing, and a
        // refund of the unlock is not a claim on them. It holds by construction —
        // premium was never rows in `player_items`, and the revoke does not read
        // that table at all.
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await grantTokens(server, id, 200);
        final bought = await buy(server, authOf(me), 'ball.comet');
        expect(bought.statusCode, 200, reason: bought.body);
        expect(decode(bought)['charged'], 80);

        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-mixed'),
        );
        expect(await server.store.isPremium(id), isTrue);
        // While premium, wear something only premium covers.
        final equipped = await equip(server, authOf(me), {
          'theme': 'theme.glass',
          'ball': 'ball.comet',
        });
        expect(equipped.statusCode, 200, reason: equipped.body);

        final r = await postWebhook(
          server,
          refundWebhookBody(appUserId: id, transactionId: 'txn-mixed'),
        );
        expect(r.statusCode, 200, reason: r.body);
        expect(decode(r)['premium'], isFalse);

        // The Spark-bought item survives; the premium-only one does not.
        expect(await server.store.ownsItem(id, 'ball.comet'), isTrue);
        expect(await server.store.ownsItem(id, 'theme.glass'), isFalse);
        final inventory = decode(await getInventory(server, authOf(me)));
        final owned = (inventory['owned'] as List<dynamic>).cast<String>();
        expect(owned, contains('ball.comet'));
        expect(owned, isNot(contains('theme.glass')));
        // The wallet is untouched too: the unlock never credited a Spark, so
        // there is nothing to claw back and no balance to floor at zero.
        expect(await server.store.walletBalance(id), 120);
        // The slot they can no longer use answers its free default, and the one
        // they own keeps what they chose. The stored preference is not thrown
        // away, so it comes back intact if they buy either way again.
        expect(inventory['equipped'], {
          'theme': 'theme.neon',
          'ball': 'ball.comet',
          'paddle': 'paddle.arc',
        });
      });

      test('a chargeback revokes the same way a refund does', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-cb'),
        );
        final r = await postWebhook(
          server,
          refundWebhookBody(
            appUserId: id,
            transactionId: 'txn-cb',
            cancelReason: 'BILLING_ERROR',
          ),
        );
        expect(r.statusCode, 200);
        expect(decode(r)['revoked'], isTrue);
        expect(await server.store.isPremium(id), isFalse);
      });

      test('the same refund twice revokes once', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-rr'),
        );
        final body = refundWebhookBody(appUserId: id, transactionId: 'txn-rr');
        final first = await postWebhook(server, body);
        expect(decode(first)['revoked'], isTrue);
        final stamped = (await server.store.purchaseByTransaction(
          'txn-rr',
        ))!.refundedAt;
        final second = await postWebhook(server, body);
        expect(second.statusCode, 200);
        expect(decode(second)['revoked'], isFalse);
        expect(decode(second)['duplicate'], isTrue);
        expect(
          (await server.store.purchaseByTransaction('txn-rr'))!.refundedAt,
          stamped,
          reason: 'a retry must not re-date a revocation that already happened',
        );
      });

      test('a second live purchase survives the refund of the first', () async {
        // The one case where a refund leaves somebody premium: the same player
        // bought the unlock on both stores. Refunding one does not take the other.
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-apple'),
        );
        await postWebhook(
          server,
          purchaseWebhookBody(
            appUserId: id,
            transactionId: 'txn-google',
            store: 'PLAY_STORE',
          ),
        );
        expect(await server.store.purchaseCount(), 2);
        final r = await postWebhook(
          server,
          refundWebhookBody(appUserId: id, transactionId: 'txn-apple'),
        );
        expect(decode(r)['revoked'], isTrue);
        expect(decode(r)['premium'], isTrue, reason: 'the other one stands');
        expect(await server.store.isPremium(id), isTrue);
      });

      test('a refund for a transaction we never recorded is a no-op', () async {
        final me = await issuePlayer(server);
        final r = await postWebhook(
          server,
          refundWebhookBody(
            appUserId: me['id'] as String,
            transactionId: 'txn-never',
          ),
        );
        expect(
          r.statusCode,
          200,
          reason: 'a retry would find the same nothing',
        );
        expect(decode(r)['revoked'], isFalse);
        expect(decode(r)['ignored'], PurchaseRevoke.unknownTransactionError);
      });

      test(
        'a subscription cancellation for another product is a no-op',
        () async {
          final me = await issuePlayer(server);
          final r = await postWebhook(
            server,
            refundWebhookBody(
              appUserId: me['id'] as String,
              productId: 'some.other.subscription',
              transactionId: 'txn-sub',
              cancelReason: 'UNSUBSCRIBE',
            ),
          );
          expect(r.statusCode, 200);
          expect(decode(r)['revoked'], isFalse);
        },
      );

      test('a refund grants nothing, whatever its product says', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        final r = await postWebhook(
          server,
          refundWebhookBody(appUserId: id, transactionId: 'txn-refund-only'),
        );
        expect(r.statusCode, 200);
        expect(await server.store.isPremium(id), isFalse);
        expect(await server.store.purchaseCount(), 0);
      });

      test('a refund with no transaction id is a 400', () async {
        final me = await issuePlayer(server);
        final body = refundWebhookBody(
          appUserId: me['id'] as String,
          transactionId: 'ignored',
        );
        body['event'] = (body['event'] as Map<String, dynamic>)
          ..remove('transaction_id')
          ..remove('original_transaction_id');
        final r = await postWebhook(server, body);
        expect(r.statusCode, 400);
        expect(decode(r)['error'], invalidEventError);
      });
    });

    group('restore, and the client nudge', () {
      test('a reinstall recovers premium from RevenueCat', () async {
        // What a non-consumable buys that a consumable never could: the store
        // still holds the purchase, RevenueCat still reports it, and "Restore
        // purchases" is a feature rather than an apologetic explanation.
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        revenueCat.grant(id, transactionId: 'txn-restore');

        final r = await postSync(server, authOf(me));
        expect(r.statusCode, 200, reason: r.body);
        final body = decode(r);
        expect(body['premium'], isTrue);
        expect(body['granted'], 1);
        expect(body['owned'], isTrue);
        expect(body['balance'], 0);
        expect(await server.store.isPremium(id), isTrue);
        for (final item in Catalogue.items) {
          expect(
            await server.store.ownsItem(id, item.id),
            isTrue,
            reason: item.id,
          );
        }

        // It really asked RevenueCat, about this player, with the server's key.
        expect(revenueCat.requests, 1);
        expect(revenueCat.paths.single, '/v1/subscribers/$id');
        expect(revenueCat.authorizations.single, 'Bearer sk_test_key');
      });

      test('a second device recovers the same purchase', () async {
        // The same person signs in on a tablet: same app user id, same store
        // transaction. The grant is keyed on the transaction, so this is a grant
        // or a no-op — never a second entitlement.
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        revenueCat.grant(id, transactionId: 'txn-two-devices');
        expect(decode(await postSync(server, authOf(me)))['granted'], 1);
        final second = decode(await postSync(server, authOf(me)));
        expect(second['granted'], 0, reason: 'nothing left to restore');
        expect(second['premium'], isTrue);
        expect(second['owned'], isTrue);
        expect(await server.store.purchaseCount(), 1);
      });

      test('the body is not read: nothing in it can unlock anything', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        revenueCat.known(id);
        final r = await http.post(
          Uri.parse('${server.baseUrl}/api/purchases/sync'),
          headers: {
            'content-type': 'application/json',
            'authorization': authOf(me),
          },
          body: jsonEncode({
            'premium': true,
            'entitlements': ['premium'],
            'productId': FullUnlock.productId,
            'transactionId': 'made-up',
          }),
        );
        expect(r.statusCode, 200, reason: r.body);
        expect(decode(r)['premium'], isFalse);
        expect(decode(r)['granted'], 0);
        expect(decode(r)['owned'], isFalse);
        expect(await server.store.purchaseCount(), 0);
      });

      test(
        'a nudge after the webhook already landed grants nothing again',
        () async {
          final me = await issuePlayer(server);
          final id = me['id'] as String;
          const txn = 'txn-both';
          await postWebhook(
            server,
            purchaseWebhookBody(appUserId: id, transactionId: txn),
          );
          revenueCat.grant(id, transactionId: txn);

          final r = await postSync(server, authOf(me));
          expect(r.statusCode, 200, reason: r.body);
          expect(decode(r)['granted'], 0);
          expect(decode(r)['premium'], isTrue);
          expect(await server.store.purchaseCount(), 1);
        },
      );

      test('a nudge first, then the webhook, still grants once', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        const txn = 'txn-race';
        revenueCat.grant(id, transactionId: txn);

        final synced = await postSync(server, authOf(me));
        expect(decode(synced)['granted'], 1);
        final hooked = await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: txn),
        );
        expect(hooked.statusCode, 200);
        expect(decode(hooked)['granted'], isFalse);
        expect(decode(hooked)['duplicate'], isTrue);
        expect(await server.store.isPremium(id), isTrue);
        expect(await server.store.purchaseCount(), 1);
      });

      test('a refunded purchase is not restored by the next sync', () async {
        // The idempotency key earns its keep here: a store may well keep
        // reporting a refunded non-consumable, and a restore must not walk the
        // refund back.
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        const txn = 'txn-refunded-restore';
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: txn),
        );
        await postWebhook(
          server,
          refundWebhookBody(appUserId: id, transactionId: txn),
        );
        expect(await server.store.isPremium(id), isFalse);

        revenueCat.grant(id, transactionId: txn);
        final r = await postSync(server, authOf(me));
        expect(r.statusCode, 200, reason: r.body);
        expect(decode(r)['granted'], 0);
        expect(
          decode(r)['premium'],
          isFalse,
          reason: 'the row is already ours, and it is stamped refunded',
        );
        expect(await server.store.purchaseCount(), 1);
      });

      test(
        'a player who has bought nothing gets an honest empty answer',
        () async {
          final me = await issuePlayer(server);
          final r = await postSync(server, authOf(me));
          expect(r.statusCode, 200, reason: r.body);
          expect(decode(r)['premium'], isFalse);
          expect(decode(r)['granted'], 0);
          expect(
            decode(r)['owned'],
            isFalse,
            reason: 'which is how Restore says "there was nothing to restore"',
          );
          expect(decode(r)['purchases'], isEmpty);
        },
      );

      test('a product RevenueCat knows and we do not is skipped', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        revenueCat.grant(
          id,
          productId: 'some.other.feature',
          transactionId: 'txn-other',
        );
        revenueCat.grant(id, transactionId: 'txn-ours');
        final r = await postSync(server, authOf(me));
        expect(r.statusCode, 200, reason: r.body);
        expect(
          decode(r)['granted'],
          1,
          reason: 'a subscriber record lists everything that user ever bought',
        );
        expect(await server.store.purchaseCount(), 1);
        expect(await server.store.isPremium(id), isTrue);
      });

      test(
        'an entitlement with no transaction behind it grants nothing',
        () async {
          // RevenueCat saying "entitled" is not a payment: an entitlement carries
          // no store transaction id, so granting from one would give up the
          // idempotency that stops a refunded purchase unlocking again. The
          // server logs the disagreement loudly and grants nothing — which is
          // what a product attached to the wrong entitlement looks like.
          final me = await issuePlayer(server);
          final id = me['id'] as String;
          revenueCat.entitle(id);
          final r = await postSync(server, authOf(me));
          expect(r.statusCode, 200, reason: r.body);
          expect(decode(r)['premium'], isFalse);
          expect(decode(r)['granted'], 0);
          expect(decode(r)['owned'], isFalse);
          expect(await server.store.purchaseCount(), 0);
        },
      );

      test('a transaction with no store transaction id is skipped', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        revenueCat.grant(
          id,
          transactionId: 'txn-idless',
          withoutStoreTransactionId: true,
        );
        final r = await postSync(server, authOf(me));
        expect(r.statusCode, 200, reason: r.body);
        expect(
          decode(r)['granted'],
          0,
          reason:
              'two paths keyed differently for one payment is a double '
              'grant waiting to happen',
        );
        expect(await server.store.isPremium(id), isFalse);
      });

      test('a sandbox purchase is skipped here too', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        revenueCat.grant(id, transactionId: 'txn-sandbox-sync', sandbox: true);
        final r = await postSync(server, authOf(me));
        expect(decode(r)['granted'], 0);
        expect(await server.store.isPremium(id), isFalse);
      });

      test(
        'RevenueCat being down is a 503, not a "you bought nothing"',
        () async {
          final me = await issuePlayer(server);
          revenueCat.status = 500;
          final r = await postSync(server, authOf(me));
          expect(r.statusCode, 503);
          expect(decode(r)['error'], revenueCatUnavailableError);
        },
      );

      test('it needs credentials, like every wallet question', () async {
        expect((await postSync(server, null)).statusCode, 401);
        expect(
          (await postSync(
            server,
            'Arco ${testPlayerId(7)}:${'x' * 43}',
          )).statusCode,
          401,
        );
        expect(revenueCat.requests, 0);
      });

      test(
        'the answer carries the ledger, so premium is explainable',
        () async {
          final me = await issuePlayer(server);
          final id = me['id'] as String;
          revenueCat.grant(
            id,
            transactionId: 'txn-ledger',
            store: 'play_store',
          );
          final r = await postSync(server, authOf(me));
          final rows = (decode(r)['purchases'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          expect(rows, hasLength(1));
          expect(rows.single['transactionId'], 'txn-ledger');
          expect(rows.single['productId'], FullUnlock.productId);
          expect(rows.single['store'], 'play_store');
          expect(rows.single['refunded'], isFalse);
          expect(
            rows.single.containsKey('sparks'),
            isFalse,
            reason: 'the unlock is not an amount of anything',
          );
        },
      );
    });

    group('the ledger explains premium', () {
      test('premium is one row naming the store transaction', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-1'),
        );
        await grantTokens(server, id, 150);

        final ledger = await server.store.purchasesOf(id);
        expect(ledger, hasLength(1));
        final row = ledger.single;
        expect(row.transactionId, 'txn-1');
        expect(row.playerId, id);
        expect(row.productId, FullUnlock.productId);
        expect(row.source, 'webhook');
        expect(row.environment, 'PRODUCTION');
        expect(row.eventId, 'evt_1');
        expect(row.refunded, isFalse);
        expect(row.grantsPremium, isTrue);

        // And the Spark side of the wallet is still explained by its own ledger,
        // with nothing in this one pretending to be Sparks.
        final inventory = decode(await getInventory(server, authOf(me)));
        expect(inventory['earnedTotal'], 150);
        expect(inventory['purchasedTotal'], 0);
        expect(inventory['balance'], 150);
      });

      test('a refund is written into the same row, not a new one', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-1'),
        );
        await postWebhook(
          server,
          refundWebhookBody(appUserId: id, transactionId: 'txn-1'),
        );
        final ledger = await server.store.purchasesOf(id);
        expect(ledger, hasLength(1));
        expect(ledger.single.refunded, isTrue);
        expect(ledger.single.refundedAt, isNotNull);
        expect(ledger.single.grantsPremium, isFalse);
        expect(await server.store.isPremium(id), isFalse);
      });

      test('the sync path is marked as such in the ledger', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        revenueCat.grant(id, transactionId: 'txn-src', store: 'play_store');
        await postSync(server, authOf(me));
        final row = (await server.store.purchasesOf(id)).single;
        expect(
          row.source,
          'sync',
          reason: 'a ledger that is all sync means the webhook is broken',
        );
        expect(row.store, 'play_store');
      });

      test('deleting the player removes the ledger with it', () async {
        final me = await issuePlayer(server);
        final id = me['id'] as String;
        await postWebhook(
          server,
          purchaseWebhookBody(appUserId: id, transactionId: 'txn-del'),
        );
        expect(await server.store.purchaseCount(), 1);

        final r = await http.delete(
          Uri.parse('${server.baseUrl}/api/players/me'),
          headers: {'authorization': authOf(me)},
        );
        expect(r.statusCode, 200, reason: r.body);
        expect(await server.store.purchaseCount(), 0);

        // And a refund arriving afterwards finds nothing, and says so calmly.
        final refund = await postWebhook(
          server,
          refundWebhookBody(appUserId: id, transactionId: 'txn-del'),
        );
        expect(refund.statusCode, 200);
        expect(decode(refund)['revoked'], isFalse);
      });
    });

    group('the body cap', () {
      test('an oversized webhook body is a 413, not a decode', () async {
        final r = await postWebhook(
          server,
          jsonEncode({
            'event': {'pad': 'x' * (maxWebhookBodyBytes + 100)},
          }),
        );
        expect(r.statusCode, 413);
        expect(decode(r)['limit'], maxWebhookBodyBytes);
      });

      test('an oversized sync body is a 413', () async {
        final me = await issuePlayer(server);
        final r = await http.post(
          Uri.parse('${server.baseUrl}/api/purchases/sync'),
          headers: {
            'content-type': 'application/json',
            'authorization': authOf(me),
          },
          body: jsonEncode({'pad': 'x' * (maxSyncBodyBytes + 100)}),
        );
        expect(r.statusCode, 413);
      });
    });
  });

  group('sandbox granted (a staging deployment)', () {
    test('PURCHASES_SANDBOX=on grants from a sandbox purchase', () async {
      final revenueCat = await FakeRevenueCat.start();
      final server = await bootServer(
        purchases: testPurchasesConfig(creditSandbox: true),
        revenueCatBaseUri: revenueCat.baseUri,
      );
      final me = await issuePlayer(server);
      final id = me['id'] as String;
      final r = await postWebhook(
        server,
        purchaseWebhookBody(
          appUserId: id,
          transactionId: 'txn-sb',
          environment: 'SANDBOX',
        ),
      );
      expect(r.statusCode, 200, reason: r.body);
      expect(decode(r)['granted'], isTrue);
      expect(await server.store.isPremium(id), isTrue);
      // Recorded as sandbox money, so a row always says which money it was.
      expect(
        (await server.store.purchaseByTransaction('txn-sb'))!.environment,
        'SANDBOX',
      );
    });

    test('and a sandbox restore works, so the flow can be walked', () async {
      final revenueCat = await FakeRevenueCat.start();
      final server = await bootServer(
        purchases: testPurchasesConfig(creditSandbox: true),
        revenueCatBaseUri: revenueCat.baseUri,
      );
      final me = await issuePlayer(server);
      final id = me['id'] as String;
      revenueCat.grant(id, transactionId: 'txn-sb-restore', sandbox: true);
      final r = await postSync(server, authOf(me));
      expect(r.statusCode, 200, reason: r.body);
      expect(decode(r)['premium'], isTrue);
      expect(decode(r)['granted'], 1);
    });
  });

  group('premium follows the person through a merge (SPEC §4.5, §4.9)', () {
    test('a purchase granted before a merge survives it', () async {
      final revenueCat = await FakeRevenueCat.start();
      final server = await bootServer(
        purchases: testPurchasesConfig(),
        revenueCatBaseUri: revenueCat.baseUri,
      );
      final phone = await issuePlayer(server);
      final phoneId = phone['id'] as String;
      await postWebhook(
        server,
        purchaseWebhookBody(appUserId: phoneId, transactionId: 'txn-merge'),
      );
      expect(await server.store.isPremium(phoneId), isTrue);

      // Another device signs in first and takes the account.
      final other = await issuePlayer(server);
      final otherId = other['id'] as String;
      final linked = await server.store.linkAccount(
        AccountLinkRequest(
          provider: 'apple',
          subject: 'apple.subject.merge',
          callerPlayerId: otherId,
          tokenHash: 'hash-token-1',
          tokenExpiresAt: DateTime.utc(2026, 9, 24, 13),
          newPlayerId: testPlayerId(0x900),
          credentialId: 'cred-1',
          secretHash: 'stored-1',
          now: DateTime.utc(2026, 9, 24, 12),
        ),
      );
      expect(linked.ok, isTrue, reason: '${linked.error}');
      expect(await server.store.isPremium(otherId), isFalse);

      // Then the phone that made the purchase signs in with the same account and
      // is absorbed into it. The ledger moves with the person, and premium is
      // answered from it with nothing to migrate.
      final merged = await server.store.linkAccount(
        AccountLinkRequest(
          provider: 'apple',
          subject: 'apple.subject.merge',
          callerPlayerId: phoneId,
          tokenHash: 'hash-token-2',
          tokenExpiresAt: DateTime.utc(2026, 9, 24, 13),
          newPlayerId: testPlayerId(0x901),
          credentialId: 'cred-2',
          secretHash: 'stored-2',
          now: DateTime.utc(2026, 9, 24, 12, 5),
        ),
      );
      expect(merged.kind, AccountLinkKind.merged, reason: '${merged.error}');

      final owner = merged.playerId!;
      expect(owner, otherId);
      expect(await server.store.isPremium(owner), isTrue);
      expect(await server.store.purchasesOf(owner), hasLength(1));

      // And a refund arriving after the merge revokes the surviving player's
      // premium — the row it lands on is the one that moved.
      final refund = await postWebhook(
        server,
        refundWebhookBody(appUserId: phoneId, transactionId: 'txn-merge'),
      );
      expect(refund.statusCode, 200, reason: refund.body);
      expect(decode(refund)['revoked'], isTrue);
      expect(decode(refund)['playerId'], owner);
      expect(await server.store.isPremium(owner), isFalse);
    });
  });
}
