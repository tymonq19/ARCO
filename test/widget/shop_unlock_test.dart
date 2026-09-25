/// The one-time unlock in the shop (SPEC §4.9).
///
/// What these tests are actually defending:
///
/// * **the price on screen is the store's**, verbatim. A build that formatted its
///   own would show the wrong currency to most of the world, and in several
///   countries a price without local tax is not merely rude.
/// * **the shop does not nag.** The card sits below the earning panel, there is
///   nothing anywhere else in the app that points at it, and it carries no
///   "best value", no discount and no countdown.
/// * **a deployment that sells nothing shows nothing** — not a disabled button,
///   not an apology.
/// * **buying unlocks everything, and only the server can do it.** Every cosmetic
///   becomes owned, including one the server adds afterwards; the ad row goes away
///   entirely; and a purchase the server has not granted claims nothing.
/// * **a player who has paid is never sold to again**: the card becomes a quiet
///   confirmation, and the balance stops being the headline because it has nothing
///   left to buy.
/// * **Restore Purchases is a real action** and says honestly what it did.
library;

import 'package:arco/app/settings.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/purchase_gateway.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:arco/ui/widgets/shop_card.dart';
import 'package:arco/ui/widgets/spark_ad.dart';
import 'package:arco/ui/widgets/unlock_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  const en = Strings('en');
  const pl = Strings('pl');
  const price = '17,99 zł';

  void useLargeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 3600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Opens the shop and lets its requests settle. Not `pumpAndSettle`: a progress
  /// indicator is on screen while the catalogue is in flight and never settles.
  Future<void> openShop(WidgetTester tester, TestEnv env) async {
    await tester.pumpWidget(wrapApp(env, const ShopScreen()));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> settle(WidgetTester tester, [int frames = 25]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// A device on a deployment that sells the unlock.
  Future<TestEnv> unlockEnv({
    int balance = 0,
    FakePurchaseGateway? store,
    bool premium = false,
    AdOffer? adOffer,
    FakeAdsGateway? adsGateway,
  }) async {
    final env = await createTestEnv(
      balance: balance,
      sellsUnlock: true,
      premium: premium,
      store: store,
      adOffer: adOffer,
      adsGateway: adsGateway,
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    env.api.profile = PlayerProfile(id: testPlayerId(1), games: 2);
    return env;
  }

  /// A section label, whatever case the theme puts it in: `SectionLabel` runs its
  /// title through `GameTheme.heading`, which upper-cases on the neon themes.
  Finder headingText(String raw) => find.byWidgetPredicate(
    (w) => w is Text && w.data?.toUpperCase() == raw.toUpperCase(),
    description: 'heading "$raw"',
  );

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      for (var i = 0; i < 14 && finder.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pump();
      }
    }
    expect(finder, findsWidgets, reason: 'never scrolled to $finder');
    await tester.ensureVisible(finder.first);
    await tester.pump();
  }

  group('a deployment that sells nothing', () {
    testWidgets('draws no money section at all', (tester) async {
      useLargeViewport(tester);
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.profile = PlayerProfile(id: testPlayerId(1), games: 2);
      await openShop(tester, env);

      // The widget is in the tree (the screen always builds it) and renders
      // nothing: no heading, no restore button, no apology.
      expect(find.byType(UnlockSection), findsOneWidget);
      expect(headingText(en.t('shop.unlockTitle')), findsNothing);
      expect(find.text(en.t('shop.restore')), findsNothing);
      expect(find.text(en.t('shop.unlockFree')), findsNothing);
      // And the store was never asked anything.
      expect(env.store.identifyCalls, 0);
      expect(env.store.priceCalls, 0);
    });

    testWidgets('a build with no store keys shows nothing either', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv(store: FakePurchaseGateway(available: false));
      await openShop(tester, env);
      expect(headingText(en.t('shop.unlockTitle')), findsNothing);
      expect(find.text(en.t('shop.restore')), findsNothing);
    });
  });

  group('the offer', () {
    testWidgets('shows the store\'s own price string, never a built one', (
      tester,
    ) async {
      useLargeViewport(tester);
      // Three markets, three formats, none of which this app could produce from a
      // number. Whatever the store hands it is what appears.
      for (final quoted in const ['4,99 zł', 'US\$3.99', '¥600']) {
        final env = await unlockEnv(
          store: FakePurchaseGateway(
            prices: <String, String>{testUnlockProductId: quoted},
          ),
        );
        await openShop(tester, env);
        await scrollTo(tester, headingText(en.t('shop.unlockTitle')));

        expect(
          find.text(quoted),
          findsOneWidget,
          reason:
              'the store said "$quoted" and the app must print exactly that',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('names the product the way the server named it', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.unlockTitle')));

      // `nameKey` is the server's, resolved through Strings: never a title this
      // screen invented about something somebody is about to pay for.
      expect(find.text(en.item('unlock.full')), findsOneWidget);
      for (final key in const [
        'shop.unlockPerk.now',
        'shop.unlockPerk.later',
        'shop.unlockPerk.ads',
      ]) {
        expect(find.text(en.t(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('a store with no price for it offers no button', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv(
        store: FakePurchaseGateway(prices: const <String, String>{}),
      );
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.unlockTitle')));

      expect(find.text(en.t('shop.unlockStoreSilent')), findsOneWidget);
      expect(find.text(en.t('shop.unlockButton')), findsNothing);
    });

    testWidgets('a silent store says so and offers no price', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv(
        store: FakePurchaseGateway()..pricesEmpty = true,
      );
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.unlockTitle')));

      expect(find.text(en.t('shop.unlockStoreSilent')), findsOneWidget);
      expect(find.text(price), findsNothing);
    });
  });

  group('the shop does not nag', () {
    testWidgets('the unlock sits below the earning panel', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.unlockTitle')));

      final earning = tester.getTopLeft(find.text(en.t('shop.earnHint'))).dy;
      final unlock = tester
          .getTopLeft(headingText(en.t('shop.unlockTitle')))
          .dy;
      expect(
        unlock,
        greaterThan(earning),
        reason:
            'the order is the argument: everything here is earnable by play',
      );
    });

    testWidgets('it says once that nothing is behind a payment', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.unlockTitle')));
      expect(find.text(en.t('shop.unlockFree')), findsOneWidget);
    });

    test('no urgency, no discount and no "best value" anywhere', () {
      // Checked against the strings rather than the pixels, because this is a
      // rule about what the app is allowed to say.
      for (final table in [Strings.en, Strings.pl]) {
        for (final key in table.keys.where(
          (k) => k.startsWith('shop.unlock') || k.startsWith('unlock.'),
        )) {
          final value = table[key]!.toLowerCase();
          for (final nag in const [
            'best value',
            'most popular',
            'save ',
            'only ',
            'hurry',
            'limited',
            'bonus',
            'discount',
            'najlepsza oferta',
            'najpopularniejsz',
            'oszczędzasz',
            'tylko teraz',
            'pośpiesz',
            'promocja',
            'zniżka',
            'rabat',
          ]) {
            expect(value, isNot(contains(nag)), reason: '$key nags: "$nag"');
          }
        }
      }
    });

    test('there is exactly one thing for sale, and no tier to compare', () {
      // A second product would need a second name key. The absence of one is the
      // cheapest possible guard against a price list creeping back.
      for (final table in [Strings.en, Strings.pl]) {
        expect(
          table.keys.where((k) => k.startsWith('unlock.')),
          ['unlock.full'],
          reason: 'one product, one name',
        );
      }
    });

    test('nothing outside the shop mentions buying anything', () {
      // The title screen, the game-over screen and Settings must not point at the
      // unlock. Checked by key prefix: every string about buying lives under
      // `shop.` or `unlock.`, so nothing else can be pointing at it.
      for (final table in [Strings.en, Strings.pl]) {
        for (final entry in table.entries) {
          if (entry.key.startsWith('shop.')) continue;
          if (entry.key.startsWith('unlock.')) continue;
          final value = entry.value.toLowerCase();
          for (final word in const [
            'unlock everything',
            'odblokuj wszystko',
            'buy sparks',
            'kup iskry',
          ]) {
            expect(value, isNot(contains(word)), reason: entry.key);
          }
        }
      }
    });
  });

  group('buying', () {
    // The button label alone: `find.text` is exact, so it cannot be confused with
    // the "ONE-TIME UNLOCK" heading above it.
    Finder buyButton() => find.text(en.t('shop.unlockButton'));

    testWidgets('a tap opens the store for the server\'s product', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      env.api.syncGrantsOnCall = true;
      await openShop(tester, env);
      await scrollTo(tester, buyButton());

      await tester.tap(buyButton());
      await settle(tester);

      expect(env.store.bought, [testUnlockProductId]);
    });

    testWidgets('a granted purchase unlocks every cosmetic, including one the '
        'server adds afterwards', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      env.api.syncGrantsOnCall = true;
      await openShop(tester, env);
      await scrollTo(tester, buyButton());

      await tester.tap(buyButton());
      await settle(tester);

      expect(find.text(en.t('shop.unlockDone')), findsOneWidget);
      // Every card in the shop now reads as owned or worn — no price, no lock.
      for (final card in tester.widgetList<ShopCard>(find.byType(ShopCard))) {
        expect(
          card.state,
          anyOf(ShopCardState.owned, ShopCardState.worn),
          reason: '${card.itemId} is not owned after the unlock',
        );
      }
      // And a look the server only adds later is covered the moment it appears:
      // the entitlement is ownership of the catalogue, not a list of rows.
      env.api.catalogueItems = <ShopItem>[
        ...FakeApiClient.defaultCatalogue(),
        FakeApiClient.shopItem('theme.aurora', 'theme', 300),
      ];
      await env.shop.refresh(force: true);
      await settle(tester);
      expect(
        env.shop.snapshot.owns('theme.aurora'),
        isTrue,
        reason: 'every cosmetic added later, at no extra cost',
      );
      expect(
        env.api.shopOwned,
        isEmpty,
        reason: 'and nothing was written per item to make that true',
      );
    });

    testWidgets('the card becomes a confirmation and the price disappears', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      env.api.syncGrantsOnCall = true;
      await openShop(tester, env);
      await scrollTo(tester, buyButton());

      await tester.tap(buyButton());
      await settle(tester);
      await scrollTo(tester, headingText(en.t('shop.unlockedTitle')));

      expect(find.text(en.t('shop.unlockedHeading')), findsOneWidget);
      expect(find.text(en.t('shop.unlockedBody')), findsOneWidget);
      expect(
        find.text(price),
        findsNothing,
        reason: 'a player who has paid must never be shown the price again',
      );
      expect(buyButton(), findsNothing);
      expect(find.text(en.t('shop.unlockFree')), findsNothing);
    });

    testWidgets('a purchase the server has not granted claims nothing', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv(balance: 50);
      // The store took the money and the server has granted nothing yet: the
      // screen must not unlock anything by itself.
      env.api.syncGrantsOnCall = false;
      await openShop(tester, env);
      await scrollTo(tester, buyButton());

      await tester.tap(buyButton());
      await settle(tester);

      expect(find.text(en.t('shop.unlockWaiting')), findsOneWidget);
      expect(env.shop.premium, isFalse);
      expect(env.shop.snapshot.owns('theme.glass'), isFalse);
      expect(
        find.text(en.t('shop.unlockedHeading')),
        findsNothing,
        reason: 'nothing is confirmed, so nothing is confirmed on screen',
      );
    });

    testWidgets('a failed purchase changes nothing at all', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv(balance: 120);
      env.store.outcome = PurchaseOutcome.failed;
      await openShop(tester, env);
      await scrollTo(tester, buyButton());

      await tester.tap(buyButton());
      await settle(tester);

      expect(find.text(en.t('shop.unlockFailed')), findsOneWidget);
      expect(env.shop.premium, isFalse);
      expect(env.shop.balance, 120, reason: 'and nothing was taken');
      expect(env.shop.snapshot.owns('theme.glass'), isFalse);
      // The offer is still standing, unchanged, and safe to try again.
      expect(find.text(price), findsOneWidget);
      expect(env.api.purchasesSyncCalls, 0);
    });

    testWidgets('cancelling says nothing at all', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      env.store.outcome = PurchaseOutcome.cancelled;
      await openShop(tester, env);
      await scrollTo(tester, buyButton());

      await tester.tap(buyButton());
      await settle(tester);

      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'a player who changed their mind does not need telling',
      );
    });

    testWidgets('a pending payment is explained, not reported as a failure', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      env.store.outcome = PurchaseOutcome.pending;
      await openShop(tester, env);
      await scrollTo(tester, buyButton());

      await tester.tap(buyButton());
      await settle(tester);

      expect(find.text(en.t('shop.unlockPending')), findsOneWidget);
      expect(find.text(en.t('shop.unlockFailed')), findsNothing);
    });

    testWidgets('a store that is down says nothing was charged', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      env.store.outcome = PurchaseOutcome.storeUnavailable;
      await openShop(tester, env);
      await scrollTo(tester, buyButton());

      await tester.tap(buyButton());
      await settle(tester);

      expect(find.text(en.t('shop.unlockStoreDown')), findsOneWidget);
    });
  });

  group('what premium changes', () {
    testWidgets('the ad row disappears entirely', (tester) async {
      useLargeViewport(tester);
      // A deployment that credits ads, and a player who bought the unlock. Not a
      // shorter allowance: no ad row at all, and nothing said about it.
      final env = await unlockEnv(
        premium: true,
        adOffer: testAdOffer(),
        adsGateway: FakeAdsGateway(),
      );
      await openShop(tester, env);

      expect(env.ads.premium, isTrue);
      expect(env.ads.offeredInShop, isFalse);
      expect(find.text(en.t('ads.watch')), findsNothing);
      expect(headingText(en.t('ads.title')), findsNothing);
      expect(find.text(en.t('ads.dayFull')), findsNothing);
      expect(
        tester.getSize(find.byType(SparkAdSection)).height,
        0,
        reason: 'the row must draw nothing at all',
      );
      expect(
        env.adsGateway.loadCalls,
        0,
        reason: 'and no ad may be requested for somebody who paid for none',
      );
    });

    testWidgets('the free player keeps their ad row', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv(
        adOffer: testAdOffer(),
        adsGateway: FakeAdsGateway(),
      );
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('ads.watch')));
      expect(find.text(en.t('ads.watch')), findsOneWidget);
    });

    testWidgets('the balance stops being the headline', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv(premium: true, balance: 240);
      await openShop(tester, env);

      // The wallet is still the server's and still moving; it simply has nothing
      // left to buy, so the app bar says what the player has instead.
      expect(env.shop.balance, 240);
      expect(find.text(en.t('shop.premiumBadge')), findsWidgets);
      expect(find.text('240'), findsNothing);
      // And the earning panel goes with it: a bar measuring progress towards
      // items already owned measures nothing.
      expect(find.text(en.t('shop.earnHint')), findsNothing);
      expect(headingText(en.t('shop.earnTitle')), findsNothing);
    });

    testWidgets('the free player keeps their balance and earning panel', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv(balance: 240);
      await openShop(tester, env);

      expect(find.text('240'), findsWidgets);
      expect(find.text(en.t('shop.premiumBadge')), findsNothing);
      await scrollTo(tester, find.text(en.t('shop.earnHint')));
      expect(find.text(en.t('shop.earnHint')), findsOneWidget);
    });

    testWidgets('every cosmetic is owned and one tap wears it', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv(premium: true);
      await openShop(tester, env);

      final glass = find.byWidgetPredicate(
        (w) => w is ShopCard && w.itemId == 'theme.glass',
      );
      await scrollTo(tester, glass);
      expect(tester.widget<ShopCard>(glass).state, ShopCardState.owned);

      await tester.tap(glass);
      await settle(tester);

      expect(
        env.shop.snapshot.equipped['theme'],
        'theme.glass',
        reason: 'owned means equippable, with no purchase in between',
      );
      expect(
        env.api.shopBuys,
        isEmpty,
        reason: 'nothing is bought: it is already theirs',
      );
    });
  });

  group('offline', () {
    testWidgets('a cached unlock keeps working with no network', (
      tester,
    ) async {
      useLargeViewport(tester);
      // The phone synced once after the purchase and has been in a tunnel since.
      // This is the restart case: nothing but the cache, and everything still
      // unlocked.
      final env = await unlockEnv(premium: true, balance: 90);
      env.api.offline = true;
      await openShop(tester, env);

      expect(find.text(en.t('shop.premiumBadge')), findsWidgets);
      await scrollTo(tester, headingText(en.t('shop.unlockedTitle')));
      expect(find.text(en.t('shop.unlockedHeading')), findsOneWidget);
      expect(
        find.text(price),
        findsNothing,
        reason: 'no offer to a player who has already paid, online or not',
      );
      for (final card in tester.widgetList<ShopCard>(find.byType(ShopCard))) {
        expect(card.state, anyOf(ShopCardState.owned, ShopCardState.worn));
      }
    });

    testWidgets('a phone that never synced is offered nothing and claims '
        'nothing', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      env.api.offline = true;
      await openShop(tester, env);

      expect(env.shop.premium, isFalse);
      expect(headingText(en.t('shop.unlockTitle')), findsNothing);
      expect(find.text(en.t('shop.offline')), findsOneWidget);
    });
  });

  group('restore purchases', () {
    testWidgets('the button is there and says plainly what it does', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('shop.restore')));

      expect(find.text(en.t('shop.restore')), findsOneWidget);
      expect(find.text(en.t('shop.restoreHint')), findsOneWidget);
    });

    testWidgets('it is still there for a player who already owns it', (
      tester,
    ) async {
      // The player most likely to look for it is the one who just changed phones.
      useLargeViewport(tester);
      final env = await unlockEnv(premium: true);
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('shop.restore')));
      expect(find.text(en.t('shop.restore')), findsOneWidget);
    });

    testWidgets('tapping it asks the store and the server', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('shop.restore')));

      await tester.tap(find.text(en.t('shop.restore')));
      await settle(tester);

      expect(env.store.restoreCalls, 1);
      expect(env.api.purchasesSyncCalls, greaterThanOrEqualTo(1));
      expect(
        find.text(en.t('shop.restoreNothing')),
        findsOneWidget,
        reason: 'no purchase on this store account is a fact, not a failure',
      );
    });

    testWidgets('a recovered purchase unlocks everything and says so', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      // The server, asked again, re-verifies with RevenueCat and finds a purchase
      // it had never granted — a reinstall, or a webhook that never arrived.
      env.api.syncGrantsOnCall = true;
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('shop.restore')));

      await tester.tap(find.text(en.t('shop.restore')));
      await settle(tester);

      expect(find.text(en.t('shop.restoreDone')), findsOneWidget);
      expect(env.shop.premium, isTrue);
      for (final card in tester.widgetList<ShopCard>(find.byType(ShopCard))) {
        expect(card.state, anyOf(ShopCardState.owned, ShopCardState.worn));
      }
    });

    testWidgets('a server it cannot reach is reported as that', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('shop.restore')));
      env.api.syncFailure = const ApiException(ApiErrorKind.network, 'offline');

      await tester.tap(find.text(en.t('shop.restore')));
      await settle(tester);

      expect(find.text(en.t('shop.restoreFailed')), findsOneWidget);
      expect(find.text(en.t('shop.restoreNothing')), findsNothing);
    });
  });

  group('Polish', () {
    testWidgets('the whole offer is translated, and the price is not', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await unlockEnv();
      env.settings.language = AppLanguage.pl;
      await openShop(tester, env);
      await scrollTo(tester, headingText(pl.t('shop.unlockTitle')));

      expect(headingText(pl.t('shop.unlockTitle')), findsOneWidget);
      expect(find.text(pl.item('unlock.full')), findsOneWidget);
      expect(find.text(pl.t('shop.unlockPerk.ads')), findsOneWidget);
      expect(find.text(pl.t('shop.unlockFree')), findsOneWidget);
      expect(find.text(pl.t('shop.restore')), findsOneWidget);
      // And the price is still the store's, untranslated and untouched.
      expect(find.text(price), findsOneWidget);
    });

    testWidgets('the confirmation is translated too', (tester) async {
      useLargeViewport(tester);
      final env = await unlockEnv(premium: true);
      env.settings.language = AppLanguage.pl;
      await openShop(tester, env);

      expect(find.text(pl.t('shop.premiumBadge')), findsWidgets);
      await scrollTo(tester, headingText(pl.t('shop.unlockedTitle')));
      expect(find.text(pl.t('shop.unlockedHeading')), findsOneWidget);
      expect(find.text(pl.t('shop.unlockedBody')), findsOneWidget);
    });
  });
}
