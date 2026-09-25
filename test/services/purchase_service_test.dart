/// The one-time unlock, client side (SPEC §4.9).
///
/// One rule runs through every test here: **the client never grants anything.** A
/// payment goes through the store; the entitlement comes from our server; this app
/// asks and repeats the answer. So the assertions are mostly about what the app
/// does *not* do — it does not unlock, it does not guess, and when the server has
/// not confirmed anything it says so rather than showing a state nobody has.
///
/// The rest is the list of things that actually happen to real players: they
/// cancel, their bank hesitates, the store is down, the train goes into a tunnel,
/// they reinstall on a new phone, and the App Store finishes the payment while the
/// app is in the background.
library;

import 'package:arco/services/api_client.dart';
import 'package:arco/services/purchase_gateway.dart';
import 'package:arco/services/purchase_service.dart';
import 'package:arco/services/shop_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../helpers/test_env.dart';

void main() {
  const unlock = testUnlockProductId;

  /// A device on a deployment that sells the unlock, with the shop already synced
  /// — which is the state the shop screen is in by the time the card can be
  /// tapped.
  Future<TestEnv> sellingEnv({
    FakePurchaseGateway? store,
    int balance = 0,
    bool premium = false,
  }) async {
    final env = await createTestEnv(
      sellsUnlock: true,
      premium: premium,
      store: store,
      balance: balance,
    );
    await env.shop.refresh(issue: true, force: true);
    await env.purchases.refresh();
    return env;
  }

  group('what is offered', () {
    test('nothing at all when the deployment takes no money', () async {
      final env = await createTestEnv();
      await env.shop.refresh(issue: true, force: true);
      await env.purchases.refresh();

      expect(
        env.purchases.offered,
        isFalse,
        reason: 'a shop that cannot take money must not show a price',
      );
      expect(env.purchases.status, PurchaseStatus.unavailable);
      expect(env.purchases.offer, isNull);
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

    test('one offer, with the store\'s own price string', () async {
      final env = await sellingEnv();
      expect(env.purchases.offered, isTrue);
      expect(env.purchases.status, PurchaseStatus.ready);

      final offer = env.purchases.offer!;
      expect(offer.productId, unlock, reason: 'the product is the server\'s');
      expect(offer.nameKey, 'unlock.full');
      expect(
        offer.priceString,
        '17,99 zł',
        reason: 'the price is the store\'s, verbatim, in the store\'s format',
      );
      expect(offer.buyable, isTrue);
    });

    test(
      'the product asked of the store is the server\'s, not a built-in one',
      () async {
        // A server advertising some other identifier is the case that catches a
        // client with the product id compiled into it.
        final env = await createTestEnv(sellsUnlock: true);
        env.api.shopUnlock = const UnlockProduct(
          productId: 'arco.unlock.other',
          nameKey: 'unlock.full',
        );
        env.store.storePrices = <String, String>{
          'arco.unlock.other': 'US\$3.99',
        };
        await env.shop.refresh(issue: true, force: true);
        await env.purchases.refresh();

        expect(env.purchases.offer!.productId, 'arco.unlock.other');
        expect(env.purchases.offer!.priceString, 'US\$3.99');
      },
    );

    test('the RevenueCat user is identified as our player id', () async {
      final env = await sellingEnv();
      // The join between the two systems (SPEC §4.9): no mapping table, so
      // nothing can fall out of step.
      final credentials = await env.identity.load();
      expect(env.store.identified, [credentials!.id]);
    });

    test('a store that has no price for it cannot sell it', () async {
      final env = await sellingEnv(
        store: FakePurchaseGateway(prices: const <String, String>{}),
      );
      expect(env.purchases.status, PurchaseStatus.storeSilent);
      expect(env.purchases.offer!.priceString, isNull);
      expect(
        env.purchases.offer!.buyable,
        isFalse,
        reason: 'offering it would be offering a dead button',
      );
    });

    test('a store that answers nothing is storeSilent, not ready', () async {
      final env = await sellingEnv(
        store: FakePurchaseGateway()..pricesEmpty = true,
      );
      expect(env.purchases.status, PurchaseStatus.storeSilent);
      expect(
        env.purchases.offered,
        isTrue,
        reason: 'there is a product; it is the price that is missing',
      );
    });

    test('a store that cannot identify us is storeSilent', () async {
      final env = await sellingEnv(
        store: FakePurchaseGateway()..identifyFails = true,
      );
      expect(env.purchases.status, PurchaseStatus.storeSilent);
      expect(env.purchases.offer, isNull);
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

    test('a player who already owns it is offered nothing', () async {
      final env = await sellingEnv(premium: true);
      expect(env.purchases.premium, isTrue);
      expect(
        env.purchases.offered,
        isFalse,
        reason: 'the server stops advertising what is already owned',
      );
      expect(env.purchases.status, PurchaseStatus.unavailable);
      expect(
        env.purchases.canRestore,
        isTrue,
        reason: 'restore stays available: a second device needs it',
      );
    });
  });

  group('a completed purchase', () {
    test('the client never unlocks anything itself', () async {
      final env = await sellingEnv();
      // The store says paid, and the *server* grants nothing: a webhook that has
      // not landed and a sync that found nothing. The client must claim nothing.
      env.store.outcome = PurchaseOutcome.completed;
      env.api.syncGrantsOnCall = false;

      final report = await env.purchases.buy(unlock);

      expect(report.kind, PurchaseReportKind.awaitingServer);
      expect(
        report.premium,
        isFalse,
        reason: 'nothing was confirmed, so nothing is claimed',
      );
      expect(
        env.shop.premium,
        isFalse,
        reason: 'the entitlement is the server\'s and the server did not grant',
      );
      expect(
        env.shop.snapshot.owns('theme.glass'),
        isFalse,
        reason: 'a paid-for look stays locked until the server says otherwise',
      );
    });

    test('everything is unlocked once the server has granted it', () async {
      final env = await sellingEnv();
      // The server grants when the sync call reaches it — which is what the real
      // server does off RevenueCat's verified webhook.
      env.api.syncGrantsOnCall = true;

      final report = await env.purchases.buy(unlock);

      expect(report.kind, PurchaseReportKind.unlocked);
      expect(report.premium, isTrue);
      expect(env.shop.premium, isTrue);
      for (final item in env.shop.snapshot.items) {
        expect(
          env.shop.snapshot.owns(item.id),
          isTrue,
          reason: '${item.id} must be owned once everything is unlocked',
        );
      }
    });

    test('a cosmetic the server adds later is covered too', () async {
      final env = await sellingEnv();
      env.api.syncGrantsOnCall = true;
      await env.purchases.buy(unlock);

      // The catalogue grows — a look added months after the purchase. The server
      // writes no row per item, so what makes this work is the entitlement, not a
      // list: the item arrives owned without anybody backfilling anything.
      env.api.catalogueItems = <ShopItem>[
        ...FakeApiClient.defaultCatalogue(),
        FakeApiClient.shopItem('theme.aurora', 'theme', 300),
      ];
      await env.shop.refresh(force: true);

      expect(env.shop.snapshot.item('theme.aurora'), isNotNull);
      expect(
        env.shop.snapshot.owns('theme.aurora'),
        isTrue,
        reason: 'every cosmetic added later, at no extra cost (SPEC §4.9)',
      );
      expect(
        env.api.shopOwned,
        isEmpty,
        reason: 'premium is ownership, not a row per item',
      );
    });

    test('it asks the server, and re-reads the inventory from it', () async {
      final env = await sellingEnv();
      env.api.syncGrantsOnCall = true;
      final inventoryCalls = env.api.shopInventoryCalls;

      await env.purchases.buy(unlock);

      expect(env.api.purchasesSyncCalls, 1, reason: 'the nudge of SPEC §4.9');
      expect(
        env.api.shopInventoryCalls,
        greaterThan(inventoryCalls),
        reason: 'what is owned always comes from the inventory endpoint',
      );
    });

    test(
      'the sync request carries the player credentials and nothing else',
      () async {
        final env = await sellingEnv();
        env.api.syncGrantsOnCall = true;
        await env.purchases.buy(unlock);
        final credentials = await env.identity.load();
        expect(env.api.syncCredentials.single.id, credentials!.id);
      },
    );

    test('a webhook that got there first still reads as unlocked', () async {
      final env = await sellingEnv();
      // The real race: the webhook granted it before the phone could ask, so the
      // sync itself grants nothing and reports 0 — but the entitlement is there.
      env.api.shopPremium = true;
      env.api.syncGranted = 0;

      final report = await env.purchases.buy(unlock);

      expect(report.kind, PurchaseReportKind.unlocked);
      expect(report.premium, isTrue);
      expect(env.shop.premium, isTrue);
    });

    test('a store that says "already owned" still asks the server', () async {
      final env = await sellingEnv();
      // What a non-consumable says on a second attempt, and what a reinstall runs
      // into. Only the server knows whether it was ever granted.
      env.store.outcome = PurchaseOutcome.alreadyOwned;
      env.api.syncGrantsOnCall = true;

      final report = await env.purchases.buy(unlock);

      expect(env.api.purchasesSyncCalls, 1);
      expect(report.kind, PurchaseReportKind.unlocked);
      expect(report.premium, isTrue);
    });

    test(
      'an unreachable server is "paid, on its way", never an unlock',
      () async {
        final env = await sellingEnv();
        env.api.syncFailure = const ApiException(
          ApiErrorKind.network,
          'offline',
        );

        final report = await env.purchases.buy(unlock);

        expect(report.kind, PurchaseReportKind.awaitingServer);
        expect(report.waiting, isTrue);
        expect(report.premium, isFalse);
        expect(
          env.shop.premium,
          isFalse,
          reason:
              'the webhook will grant it; this phone may not pretend it has',
        );
      },
    );
  });

  group('every other outcome', () {
    test('cancelled is silent and asks nobody anything', () async {
      final env = await sellingEnv(balance: 50);
      env.store.outcome = PurchaseOutcome.cancelled;

      final report = await env.purchases.buy(unlock);

      expect(report.kind, PurchaseReportKind.cancelled);
      expect(report.premium, isFalse);
      expect(
        env.api.purchasesSyncCalls,
        0,
        reason: 'nothing happened, so there is nothing to ask about',
      );
      expect(env.shop.balance, 50, reason: 'and nothing was taken');
    });

    test('pending says the money is not in yet', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.pending;
      final report = await env.purchases.buy(unlock);
      expect(report.kind, PurchaseReportKind.pending);
      expect(env.api.purchasesSyncCalls, 0);
      expect(env.shop.premium, isFalse);
    });

    test('a store that is down charged nothing', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.storeUnavailable;
      final report = await env.purchases.buy(unlock);
      expect(report.kind, PurchaseReportKind.storeUnavailable);
      expect(env.api.purchasesSyncCalls, 0);
      expect(env.shop.premium, isFalse);
    });

    test('no network charged nothing', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.offline;
      final report = await env.purchases.buy(unlock);
      expect(report.kind, PurchaseReportKind.offline);
      expect(env.shop.premium, isFalse);
    });

    test('a device that forbids purchases says so', () async {
      final env = await sellingEnv();
      env.store.outcome = PurchaseOutcome.notAllowed;
      final report = await env.purchases.buy(unlock);
      expect(report.kind, PurchaseReportKind.notAllowed);
    });

    test('anything else is an honest failure, and takes nothing', () async {
      final env = await sellingEnv(balance: 120);
      env.store.outcome = PurchaseOutcome.failed;
      final report = await env.purchases.buy(unlock);
      expect(report.kind, PurchaseReportKind.failed);
      expect(env.shop.premium, isFalse);
      expect(env.shop.balance, 120);
      expect(
        env.shop.snapshot.owns('theme.glass'),
        isFalse,
        reason: 'a failed purchase changes nothing at all',
      );
    });

    test('a retry after a failure is safe and unlocks once', () async {
      final env = await sellingEnv();
      env.store.outcomes.add(PurchaseOutcome.failed);
      expect((await env.purchases.buy(unlock)).kind, PurchaseReportKind.failed);
      env.api.syncGrantsOnCall = true;
      final second = await env.purchases.buy(unlock);
      expect(second.kind, PurchaseReportKind.unlocked);
      expect(env.shop.premium, isTrue);
      expect(env.store.bought, [unlock, unlock]);
    });

    test('a product this build is not offering never opens a sheet', () async {
      final env = await sellingEnv();
      final report = await env.purchases.buy('arco.unlock.deluxe');
      expect(report.kind, PurchaseReportKind.storeUnavailable);
      expect(
        env.store.bought,
        isEmpty,
        reason: 'the product is the server\'s; nothing else is buyable',
      );
    });

    test('a product with no store price never opens a sheet', () async {
      final env = await sellingEnv(
        store: FakePurchaseGateway(prices: const <String, String>{}),
      );
      final report = await env.purchases.buy(unlock);
      expect(report.kind, PurchaseReportKind.storeUnavailable);
      expect(env.store.bought, isEmpty);
    });

    test('a second tap while one purchase is in flight is refused', () async {
      final env = await sellingEnv();
      env.api.syncGrantsOnCall = true;
      final first = env.purchases.buy(unlock);
      final second = await env.purchases.buy(unlock);
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
      env.api.syncGrantsOnCall = true;
      env.store.emitPurchaseUpdate();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(env.api.purchasesSyncCalls, 1);
      expect(env.shop.premium, isTrue, reason: 'the server granted it, not us');
    });

    test('recheck is silent when there is nothing new', () async {
      final env = await sellingEnv(balance: 120);
      await env.purchases.recheck();
      expect(env.api.purchasesSyncCalls, 1);
      expect(env.shop.premium, isFalse);
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
      // No purchase on this store account: a fact, not a failure.
      expect(report.failed, isFalse);
      expect(report.foundSomething, isFalse);
      expect(report.premium, isFalse);
    });

    test('a purchase the server had never granted is recovered', () async {
      final env = await sellingEnv();
      // The server, asked again, re-verifies with RevenueCat and finds a purchase
      // it had never granted — a reinstall, or a webhook that never arrived.
      env.api.syncGrantsOnCall = true;

      final report = await env.purchases.restore();

      expect(report.foundSomething, isTrue);
      expect(report.premium, isTrue);
      expect(report.granted, 1);
      expect(env.shop.premium, isTrue);
      for (final item in env.shop.snapshot.items) {
        expect(env.shop.snapshot.owns(item.id), isTrue);
      }
    });

    test(
      'a purchase that was already ours reads as restored, not as nothing',
      () async {
        final env = await sellingEnv(premium: true);
        final report = await env.purchases.restore();
        expect(report.premium, isTrue);
        expect(
          report.granted,
          0,
          reason: 'nothing to grant is the healthy answer, not a failure',
        );
        expect(report.failed, isFalse);
      },
    );

    test('a refunded purchase the store still reports unlocks nothing', () async {
      final env = await sellingEnv();
      // RevenueCat keeps reporting the transaction; our server has stamped it
      // refunded. The honest answer is "nothing to restore", never a lock removed.
      env.api.syncOwned = true;
      final report = await env.purchases.restore();
      expect(report.premium, isFalse);
      expect(report.foundSomething, isFalse);
      expect(env.shop.premium, isFalse);
    });

    test('running it twice grants once', () async {
      final env = await sellingEnv();
      env.api.syncGrantsOnCall = true;
      final first = await env.purchases.restore();
      final second = await env.purchases.restore();
      expect(first.granted, 1);
      expect(second.premium, isTrue);
      expect(env.api.purchasesSyncCalls, 2);
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
      env.api.syncGrantsOnCall = true;
      final report = await env.purchases.restore();
      expect(env.store.restoreCalls, 0);
      expect(report.foundSomething, isTrue);
      expect(env.shop.premium, isTrue);
    });
  });

  group('offline, and after a restart', () {
    test('a cached entitlement keeps working with no network', () async {
      // The phone synced once after the purchase and has been in a tunnel since.
      // Everything stays unlocked: that is what was paid for, and the server
      // refuses anything it disagrees with anyway.
      final env = await createTestEnv(premium: true);
      env.api.offline = true;
      await env.shop.refresh(issue: true, force: true);

      expect(env.shop.status, ShopStatus.offline);
      expect(env.shop.premium, isTrue);
      expect(env.shop.snapshot.owns('theme.glass'), isTrue);
      expect(env.shop.snapshot.showsBalance, isFalse);
    });

    test('a cached entitlement offers nothing to buy', () async {
      final env = await createTestEnv(premium: true);
      env.api.offline = true;
      await env.shop.refresh(issue: true, force: true);
      await env.purchases.refresh();

      expect(
        env.purchases.offered,
        isFalse,
        reason: 'a player who has paid is never shown the price again',
      );
      expect(env.purchases.premium, isTrue);
    });

    test('a device that never synced claims nothing', () async {
      final env = await createTestEnv(sellsUnlock: true);
      env.api.offline = true;
      await env.shop.refresh(issue: true, force: true);

      expect(env.shop.premium, isFalse);
      expect(env.shop.snapshot.owns('theme.glass'), isFalse);
      expect(env.shop.snapshot.owns('theme.neon'), isTrue);
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
      // The case a non-consumable meets constantly: a reinstall, a second device,
      // a family-shared purchase. It is not an error and it is not a second
      // charge — it is a reason to ask our server what it holds.
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
      expect(await gateway.prices(const [unlock]), isEmpty);
      expect(
        (await gateway.buy(unlock)).outcome,
        PurchaseOutcome.storeUnavailable,
      );
      await gateway.restore();
      await gateway.dispose();
    });
  });

  group('the wire format', () {
    test('a product without an identifier is dropped', () {
      expect(UnlockProduct.fromJson(const {'nameKey': 'unlock.full'}), isNull);
      expect(UnlockProduct.fromJson(const {'productId': ''}), isNull);
      expect(
        UnlockProduct.fromJson(const {'productId': unlock})!.nameKey,
        unlock,
        reason:
            'a product with no name key falls back to its id, never to null',
      );
    });

    test('the product carries no price, and never gains one', () {
      const product = UnlockProduct(productId: unlock, nameKey: 'unlock.full');
      expect(product.toJson().keys, {'productId', 'nameKey'});
    });

    test('a catalogue with no unlock is a deployment that sells nothing', () {
      final catalogue = ShopCatalogue.fromJson(const {
        'ok': true,
        'version': 1,
        'items': <dynamic>[],
      });
      expect(catalogue.unlock, isNull);
      expect(catalogue.premium, isFalse);
    });

    test('a catalogue reports the product and the entitlement', () {
      final catalogue = ShopCatalogue.fromJson(const {
        'ok': true,
        'version': 1,
        'items': <dynamic>[],
        'premium': false,
        'unlock': {'productId': unlock, 'nameKey': 'unlock.full'},
      });
      expect(catalogue.unlock!.productId, unlock);
      expect(catalogue.unlock!.nameKey, 'unlock.full');
    });

    test('the inventory carries the entitlement', () {
      final inventory = ShopInventory.fromJson(const {
        'ok': true,
        'version': 1,
        'owned': <dynamic>[],
        'premium': true,
        'purchasedTotal': 1,
      });
      expect(inventory.premium, isTrue);
      expect(inventory.purchasedTotal, 1);
    });

    test('the sync body is read for the server\'s answer only', () {
      final sync = PurchaseSync.fromJson(const {
        'ok': true,
        'premium': true,
        'granted': 1,
        'owned': true,
        'balance': 350,
        'purchases': [
          {
            'transactionId': '1000000123',
            'productId': unlock,
            'store': 'app_store',
            'purchasedAt': '2026-09-24T11:00:00Z',
            'creditedAt': '2026-09-24T11:00:01Z',
            'refunded': false,
          },
        ],
      });
      expect(sync.premium, isTrue);
      expect(sync.granted, 1);
      expect(sync.owned, isTrue);
      expect(sync.balance, 350);
      expect(sync.purchases.single.transactionId, '1000000123');
      expect(sync.purchases.single.refunded, isFalse);
    });

    test('an entitlement the server does not confirm is not premium', () {
      // The shape of a refund: the store still has the transaction, our server has
      // revoked it. `owned` true and `premium` false is not a contradiction, and
      // the client must follow `premium`.
      final sync = PurchaseSync.fromJson(const {
        'ok': true,
        'premium': false,
        'granted': 0,
        'owned': true,
        'balance': 0,
      });
      expect(sync.premium, isFalse);
      expect(sync.owned, isTrue);
    });

    test('the ad offer carries the entitlement', () {
      final offer = AdOffer.fromJson(const {
        'ok': true,
        'available': false,
        'premium': true,
        'remaining': 6,
      });
      expect(offer.premium, isTrue);
      expect(
        offer.available,
        isFalse,
        reason: 'the allowance is untouched; no ad is offered at all',
      );
      expect(offer.remaining, 6);
    });

    test('health says whether the deployment can take money', () {
      expect(
        const HealthInfo(ok: true, version: '1', rooms: 0).purchases,
        isFalse,
      );
    });
  });
}
