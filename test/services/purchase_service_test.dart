/// Buying Sparks with real money, client side (SPEC §4.9).
///
/// One rule runs through every test here: **the client never computes a
/// balance.** A payment goes through the store; the Sparks come from our server;
/// this app asks and repeats the answer. So the assertions are mostly about what
/// the app does *not* do — it does not add, it does not guess, and when the server
/// has not confirmed anything it says so rather than showing a figure.
///
/// The rest is the list of things that actually happen to real players: they
/// cancel, their bank hesitates, the store is down, the train goes into a tunnel,
/// and the App Store finishes the payment while the app is in the background.
library;

import 'package:arco/services/api_client.dart';
import 'package:arco/services/purchase_gateway.dart';
import 'package:arco/services/purchase_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../helpers/test_env.dart';

void main() {
  const small = 'arco.sparks.small';
  const large = 'arco.sparks.large';

  /// A device on a deployment that sells Sparks, with the shop already synced —
  /// which is the state the shop screen is in by the time a pack can be tapped.
  Future<TestEnv> sellingEnv({
    FakePurchaseGateway? store,
    int balance = 0,
  }) async {
    final env = await createTestEnv(
      packs: testSparkPacks(),
      store: store,
      balance: balance,
    );
    await env.shop.refresh(issue: true, force: true);
    await env.purchases.refresh();
    return env;
  }

  group('what is offered', () {
    test('nothing at all when the deployment sells no packs', () async {
      final env = await createTestEnv();
      await env.shop.refresh(issue: true, force: true);
      await env.purchases.refresh();

      expect(
        env.purchases.offered,
        isFalse,
        reason: 'a shop that cannot take money must not show a price list',
      );
      expect(env.purchases.status, PurchaseStatus.unavailable);
      expect(env.purchases.offers, isEmpty);
      expect(
        env.store.identifyCalls,
        0,
        reason: 'nothing should touch the store when there is nothing to sell',
      );
    });

    test('nothing at all when this build has no store keys', () async {
      final env = await sellingEnv(
        store: FakePurchaseGateway(available: false),
      );
      expect(env.purchases.offered, isFalse);
      expect(env.purchases.status, PurchaseStatus.unavailable);
    });

    test('one offer per pack, with the store\'s own price string', () async {
      final env = await sellingEnv();
      expect(env.purchases.offered, isTrue);
      expect(env.purchases.status, PurchaseStatus.ready);
      expect(env.purchases.offers, hasLength(3));

      final offer = env.purchases.offerFor(small)!;
      expect(offer.sparks, 300, reason: 'the amount is the server\'s');
      expect(
        offer.priceString,
        '4,99 zł',
        reason: 'the price is the store\'s, verbatim, in the store\'s format',
      );
      expect(offer.buyable, isTrue);
    });

    test('the RevenueCat user is identified as our player id', () async {
      final env = await sellingEnv();
      // The join between the two systems (SPEC §4.9): no mapping table, so
      // nothing can fall out of step.
      final credentials = await env.identity.load();
      expect(env.store.identified, [credentials!.id]);
    });

    test('a pack the store has no price for cannot be tapped', () async {
      final store = FakePurchaseGateway(
        prices: const {'arco.sparks.small': '4,99 zł'},
      );
      final env = await sellingEnv(store: store);
      expect(env.purchases.offerFor(small)!.buyable, isTrue);
      expect(
        env.purchases.offerFor(large)!.buyable,
        isFalse,
        reason: 'offering it would be offering a dead button',
      );
      expect(env.purchases.offerFor(large)!.priceString, isNull);
    });

    test('a store that answers nothing is storeSilent, not ready', () async {
      final env = await sellingEnv(
        store: FakePurchaseGateway()..pricesEmpty = true,
      );
      expect(env.purchases.status, PurchaseStatus.storeSilent);
      expect(
        env.purchases.offered,
        isTrue,
        reason: 'there are packs; it is the prices that are missing',
      );
    });

    test('a store that cannot identify us is storeSilent', () async {
      final env = await sellingEnv(
        store: FakePurchaseGateway()..identifyFails = true,
      );
      expect(env.purchases.status, PurchaseStatus.storeSilent);
      expect(env.purchases.offers, isEmpty);
    });

    test('concurrent refreshes join one call', () async {
      final env = await sellingEnv();
      env.store.priceCalls = 0;
      await Future.wait([
        env.purchases.refresh(),
        env.purchases.refresh(),
        env.purchases.refresh(),
      ]);
      expect(env.store.priceCalls, 1);
    });
  });

  group('a completed purchase', () {
    test('the client never adds the Sparks itself', () async {
      final env = await sellingEnv(balance: 50);
      // The store says paid, and the *server* credits nothing: a webhook that has
      // not landed and a sync that found nothing. The client must claim nothing.
      env.store.outcome = PurchaseOutcome.completed;
      env.api.syncCreditsOnCall = 0;

      final report = await env.purchases.buy(small);

      expect(report.kind, PurchaseReportKind.awaitingServer);
      expect(
        report.sparks,
        0,
        reason: 'nothing was confirmed, so nothing is claimed',
      );
      expect(
        env.shop.balance,
        50,
        reason: 'the wallet is the server\'s and the server did not move it',
      );
    });

    test('the balance shown is the one the server credited', () async {
      final env = await sellingEnv(balance: 50);
      // The server credits 300 when the sync call reaches it — which is what the
      // real server does off RevenueCat's verified webhook.
      env.api.syncCreditsOnCall = 300;

      final report = await env.purchases.buy(small);

      expect(report.kind, PurchaseReportKind.credited);
      expect(report.sparks, 300);
      expect(report.balance, 350);
      expect(env.shop.balance, 350);
    });

    test('it asks the server, and re-reads the wallet from it', () async {
      final env = await sellingEnv();
      env.api.syncCreditsOnCall = 300;
      final inventoryCalls = env.api.shopInventoryCalls;

      await env.purchases.buy(small);

      expect(env.api.purchasesSyncCalls, 1, reason: 'the nudge of SPEC §4.9');
      expect(
        env.api.shopInventoryCalls,
        greaterThan(inventoryCalls),
        reason: 'the balance always comes from the inventory endpoint',
      );
    });

    test(
      'the sync request carries the player credentials and nothing else',
      () async {
        final env = await sellingEnv();
        env.api.syncCreditsOnCall = 300;
        await env.purchases.buy(small);
        final credentials = await env.identity.load();
        expect(env.api.syncCredentials.single.id, credentials!.id);
      },
    );

    test('a webhook that got there first still reads as credited', () async {
      final env = await sellingEnv(balance: 0);
      // The real race: the webhook credited it before the phone could ask, so the
      // sync itself credits nothing and reports 0 — but the wallet has grown.
      env.api.shopBalance = 800;
      env.api.syncCredited = 0;
      env.api.syncSparks = 0;

      final report = await env.purchases.buy(large);

      expect(report.kind, PurchaseReportKind.credited);
      expect(report.balance, 800);
      expect(env.shop.balance, 800);
    });

    test('a store that says "already owned" still asks the server', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.alreadyOwned;
      env.api.syncCreditsOnCall = 300;

      final report = await env.purchases.buy(small);

      expect(
        env.api.purchasesSyncCalls,
        1,
        reason: 'only the server knows whether it was ever credited',
      );
      expect(report.kind, PurchaseReportKind.credited);
      expect(report.sparks, 300);
    });

    test(
      'an unreachable server is "paid, on its way", never a number',
      () async {
        final env = await sellingEnv(balance: 120);
        env.api.syncFailure = const ApiException(
          ApiErrorKind.network,
          'offline',
        );

        final report = await env.purchases.buy(small);

        expect(report.kind, PurchaseReportKind.awaitingServer);
        expect(report.waiting, isTrue);
        expect(report.sparks, 0);
        expect(
          env.shop.balance,
          120,
          reason:
              'the webhook will credit it; this phone may not pretend it has',
        );
      },
    );
  });

  group('every other outcome', () {
    test('cancelled is silent and asks nobody anything', () async {
      final env = await sellingEnv(balance: 50);
      env.store.outcome = PurchaseOutcome.cancelled;

      final report = await env.purchases.buy(small);

      expect(report.kind, PurchaseReportKind.cancelled);
      expect(report.sparks, 0);
      expect(
        env.api.purchasesSyncCalls,
        0,
        reason: 'nothing happened, so there is nothing to ask about',
      );
      expect(env.shop.balance, 50);
    });

    test('pending says the money is not in yet', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.pending;
      final report = await env.purchases.buy(small);
      expect(report.kind, PurchaseReportKind.pending);
      expect(env.api.purchasesSyncCalls, 0);
      expect(env.shop.balance, 0);
    });

    test('a store that is down charged nothing', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.storeUnavailable;
      final report = await env.purchases.buy(small);
      expect(report.kind, PurchaseReportKind.storeUnavailable);
      expect(env.api.purchasesSyncCalls, 0);
    });

    test('no network charged nothing', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.offline;
      final report = await env.purchases.buy(small);
      expect(report.kind, PurchaseReportKind.offline);
    });

    test('a device that forbids purchases says so', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.notAllowed;
      final report = await env.purchases.buy(small);
      expect(report.kind, PurchaseReportKind.notAllowed);
    });

    test('anything else is an honest failure', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.failed;
      final report = await env.purchases.buy(small);
      expect(report.kind, PurchaseReportKind.failed);
    });

    test('a product this build is not offering never opens a sheet', () async {
      final env = await sellingEnv();
      final report = await env.purchases.buy('arco.sparks.infinite');
      expect(report.kind, PurchaseReportKind.storeUnavailable);
      expect(
        env.store.bought,
        isEmpty,
        reason: 'the pack list is the server\'s; nothing else is buyable',
      );
    });

    test('a pack with no store price never opens a sheet', () async {
      final env = await sellingEnv(
        store: FakePurchaseGateway(
          prices: const {'arco.sparks.small': '4,99 zł'},
        ),
      );
      final report = await env.purchases.buy(large);
      expect(report.kind, PurchaseReportKind.storeUnavailable);
      expect(env.store.bought, isEmpty);
    });

    test('a second tap while one purchase is in flight is refused', () async {
      final env = await sellingEnv();
      env.api.syncCreditsOnCall = 300;
      final first = env.purchases.buy(small);
      final second = await env.purchases.buy(small);
      await first;
      expect(second.kind, PurchaseReportKind.failed);
      expect(
        env.store.bought,
        hasLength(1),
        reason: 'one double tap must not open two payment sheets',
      );
    });
  });

  group('a purchase that lands while the app is elsewhere', () {
    test('a store update makes the app ask the server', () async {
      final env = await sellingEnv();
      // The App Store finished the payment while the game was in the background,
      // or a pending payment was approved a day later. The event carries nothing;
      // the only correct move is to ask the server.
      env.api.syncCreditsOnCall = 800;
      env.store.emitPurchaseUpdate();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(env.api.purchasesSyncCalls, 1);
      expect(env.shop.balance, 800, reason: 'the server credited it, not us');
    });

    test('recheck is silent when there is nothing new', () async {
      final env = await sellingEnv(balance: 120);
      await env.purchases.recheck();
      expect(env.api.purchasesSyncCalls, 1);
      expect(env.shop.balance, 120);
    });

    test('recheck does nothing on a build with no store', () async {
      final env = await sellingEnv(
        store: FakePurchaseGateway(available: false),
      );
      await env.purchases.recheck();
      expect(env.api.purchasesSyncCalls, 0);
    });
  });

  group('restore purchases', () {
    test('it re-links the store account and asks the server', () async {
      final env = await sellingEnv();
      final report = await env.purchases.restore();

      expect(env.store.restoreCalls, 1);
      expect(env.api.purchasesSyncCalls, 1);
      // A consumable does not restore, so the ordinary answer is "nothing left",
      // and that is not a failure.
      expect(report.failed, isFalse);
      expect(report.foundSomething, isFalse);
    });

    test('a payment that never landed is recovered', () async {
      final env = await sellingEnv();
      // The server, asked again, re-verifies with RevenueCat and finds a purchase
      // it had never credited — the one case where restoring genuinely helps.
      env.api.syncCreditsOnCall = 300;

      final report = await env.purchases.restore();

      expect(report.foundSomething, isTrue);
      expect(report.sparks, 300);
      expect(env.shop.balance, 300);
    });

    test(
      'an unreachable server is a failure, not "nothing to restore"',
      () async {
        final env = await sellingEnv();
        env.api.syncFailure = const ApiException(
          ApiErrorKind.network,
          'offline',
        );
        final report = await env.purchases.restore();
        expect(report.failed, isTrue);
        expect(report.foundSomething, isFalse);
      },
    );

    test('it works on a build with no store keys at all', () async {
      // The button exists in every build the store guidelines cover, and the
      // useful half — asking our server — does not need the store.
      final env = await sellingEnv(
        store: FakePurchaseGateway(available: false),
      );
      env.api.syncCreditsOnCall = 300;
      final report = await env.purchases.restore();
      expect(env.store.restoreCalls, 0);
      expect(report.foundSomething, isTrue);
      expect(env.shop.balance, 300);
    });
  });

  group('the store error mapping', () {
    // Getting these wrong means shouting at a player who changed their mind, or
    // telling somebody their payment failed when a parent is still approving it.
    test('cancelled is cancelled', () {
      expect(
        RevenueCatPurchases.outcomeFor(
          PurchasesErrorCode.purchaseCancelledError,
        ),
        PurchaseOutcome.cancelled,
      );
    });

    test('a pending payment is pending, not a failure', () {
      expect(
        RevenueCatPurchases.outcomeFor(PurchasesErrorCode.paymentPendingError),
        PurchaseOutcome.pending,
      );
    });

    test('already purchased is worth checking with the server', () {
      for (final code in const [
        PurchasesErrorCode.productAlreadyPurchasedError,
        PurchasesErrorCode.receiptAlreadyInUseError,
      ]) {
        expect(
          RevenueCatPurchases.outcomeFor(code),
          PurchaseOutcome.alreadyOwned,
        );
      }
      expect(
        const PurchaseAttempt(PurchaseOutcome.alreadyOwned).worthChecking,
        isTrue,
      );
    });

    test('network trouble is offline, not a store problem', () {
      for (final code in const [
        PurchasesErrorCode.networkError,
        PurchasesErrorCode.offlineConnectionError,
      ]) {
        expect(RevenueCatPurchases.outcomeFor(code), PurchaseOutcome.offline);
      }
    });

    test('a device that forbids purchases is not a failure', () {
      expect(
        RevenueCatPurchases.outcomeFor(
          PurchasesErrorCode.purchaseNotAllowedError,
        ),
        PurchaseOutcome.notAllowed,
      );
    });

    test('a store or backend problem is storeUnavailable', () {
      for (final code in const [
        PurchasesErrorCode.storeProblemError,
        PurchasesErrorCode.productNotAvailableForPurchaseError,
        PurchasesErrorCode.configurationError,
      ]) {
        expect(
          RevenueCatPurchases.outcomeFor(code),
          PurchaseOutcome.storeUnavailable,
        );
      }
    });

    test('an unrecognised code is a plain failure, never a success', () {
      for (final code in PurchasesErrorCode.values) {
        expect(
          RevenueCatPurchases.outcomeFor(code),
          isNot(PurchaseOutcome.completed),
          reason: '$code must never read as a completed purchase',
        );
      }
    });

    test('a real PlatformException maps through the helper', () {
      // The code arrives as a stringified index, which is the shape the plugin
      // really throws.
      final exception = PlatformException(
        code: '${PurchasesErrorCode.purchaseCancelledError.index}',
        message: 'User cancelled',
      );
      expect(
        RevenueCatPurchases.outcomeFor(
          PurchasesErrorHelper.getErrorCode(exception),
        ),
        PurchaseOutcome.cancelled,
      );
    });
  });

  group('a gateway with no keys', () {
    test('reports itself unavailable and touches no plugin', () async {
      final gateway = RevenueCatPurchases(apiKey: null, logging: false);
      expect(gateway.available, isFalse);
      // Every call is a no-op rather than a plugin crash: an unconfigured build
      // has to keep working, because nothing in the game is behind a payment.
      expect(await gateway.identify(testPlayerId(1)), isFalse);
      expect(await gateway.prices(const [small]), isEmpty);
      expect(
        (await gateway.buy(small)).outcome,
        PurchaseOutcome.storeUnavailable,
      );
      await gateway.restore();
      await gateway.dispose();
    });
  });

  group('the wire format', () {
    test('a pack without a product id or an amount is dropped', () {
      expect(ShopPack.fromJson({'sparks': 300}), isNull);
      expect(ShopPack.fromJson({'productId': '', 'sparks': 300}), isNull);
      expect(ShopPack.fromJson({'productId': small}), isNull);
      expect(ShopPack.fromJson({'productId': small, 'sparks': 0}), isNull);
      expect(ShopPack.fromJson({'productId': small, 'sparks': -5}), isNull);
    });

    test('a pack carries no price, and never gains one', () {
      const pack = ShopPack(
        productId: small,
        sparks: 300,
        nameKey: 'pack.small',
      );
      expect(pack.toJson().keys, {'productId', 'sparks', 'nameKey'});
    });

    test('a catalogue with no packs is a deployment that sells none', () {
      final catalogue = ShopCatalogue.fromJson(const {
        'ok': true,
        'version': 1,
        'items': <dynamic>[],
      });
      expect(catalogue.packs, isEmpty);
    });

    test('the sync body is read for the server\'s numbers only', () {
      final sync = PurchaseSync.fromJson(const {
        'ok': true,
        'credited': 1,
        'sparks': 300,
        'balance': 350,
        'purchases': [
          {
            'transactionId': '1000000123',
            'productId': small,
            'sparks': 300,
            'store': 'app_store',
            'purchasedAt': '2026-09-24T11:00:00Z',
            'refunded': false,
          },
        ],
      });
      expect(sync.credited, 1);
      expect(sync.sparks, 300);
      expect(sync.balance, 350);
      expect(sync.purchases.single.transactionId, '1000000123');
      expect(sync.purchases.single.refunded, isFalse);
    });

    test('health says whether the deployment can take money', () {
      expect(
        const HealthInfo(ok: true, version: '1', rooms: 0).purchases,
        isFalse,
      );
    });
  });
}
