/// The Spark-pack section of the shop screen (SPEC §4.9).
///
/// What these tests are actually defending:
///
/// * **the price on screen is the store's**, verbatim. A build that formatted its
///   own would show the wrong currency to most of the world, and in several
///   countries a price without local tax is not merely rude.
/// * **the shop does not nag.** The section sits below the earning panel, there is
///   nothing anywhere else in the app that points at it, and no card carries a
///   "best value", a discount or a countdown.
/// * **a deployment that sells nothing shows nothing** — not a disabled row, not
///   an apology.
/// * **Restore Purchases exists and tells the truth** about what it does, because
///   a consumable does not restore and a button that implies otherwise is a lie.
/// * **no number on screen is this app's**: a paid pack shows the balance the
///   server reported, and when the server has not credited it yet the screen says
///   that instead.
library;

import 'package:arco/app/settings.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/purchase_gateway.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:arco/ui/widgets/spark_packs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  const en = Strings('en');
  const pl = Strings('pl');

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
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// A device on a deployment that sells Sparks.
  Future<TestEnv> packsEnv({
    int balance = 0,
    FakePurchaseGateway? store,
    List<ShopPack>? packs,
  }) async {
    final env = await createTestEnv(
      balance: balance,
      packs: packs ?? testSparkPacks(),
      store: store,
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
      // nothing: no title, no restore button, no apology.
      expect(find.byType(SparkPacksSection), findsOneWidget);
      expect(headingText(en.t('shop.packsTitle')), findsNothing);
      expect(find.text(en.t('shop.restore')), findsNothing);
      expect(find.text(en.t('shop.packsHint')), findsNothing);
      // And the store was never asked anything.
      expect(env.store.identifyCalls, 0);
      expect(env.store.priceCalls, 0);
    });

    testWidgets('a build with no store keys shows nothing either', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv(store: FakePurchaseGateway(available: false));
      await openShop(tester, env);
      expect(headingText(en.t('shop.packsTitle')), findsNothing);
    });
  });

  group('the price list', () {
    testWidgets('shows the store\'s own price string, never a built one', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv(
        store: FakePurchaseGateway(
          // Prices in three markets, in three formats, none of which this app
          // could produce from a number.
          prices: const {
            'arco.sparks.small': '4,99 zł',
            'arco.sparks.medium': 'US\$11.99',
            'arco.sparks.large': '¥3,800',
          },
        ),
      );
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.packsTitle')));

      expect(find.text('4,99 zł'), findsOneWidget);
      expect(find.text('US\$11.99'), findsOneWidget);
      expect(find.text('¥3,800'), findsOneWidget);
    });

    testWidgets('shows the server\'s Spark amounts and the server\'s names', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.packsTitle')));

      for (final pack in testSparkPacks()) {
        expect(
          find.text(en.item(pack.nameKey)),
          findsOneWidget,
          reason: 'no name on the card for ${pack.productId}',
        );
        expect(
          find.text(en.sparks(pack.sparks)),
          findsOneWidget,
          reason: 'no amount on the card for ${pack.productId}',
        );
      }
    });

    testWidgets('the list is whatever the server served, not a built-in one', (
      tester,
    ) async {
      useLargeViewport(tester);
      // A server with one pack of its own, at an amount no build of this app has
      // ever heard of.
      final env = await packsEnv(
        packs: const [
          ShopPack(
            productId: 'arco.sparks.small',
            sparks: 777,
            nameKey: 'pack.small',
          ),
        ],
      );
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.packsTitle')));

      expect(find.text(en.sparks(777)), findsOneWidget);
      expect(find.text(en.item('pack.medium')), findsNothing);
      expect(find.text(en.item('pack.large')), findsNothing);
    });

    testWidgets('a pack the store has no price for is marked, not priced', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv(
        store: FakePurchaseGateway(
          prices: const {'arco.sparks.small': '4,99 zł'},
        ),
      );
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.packsTitle')));

      expect(find.text('4,99 zł'), findsOneWidget);
      expect(
        find.text(en.t('shop.packsPriceMissing')),
        findsNWidgets(2),
        reason: 'no price is shown rather than a made-up one',
      );
    });

    testWidgets('a silent store says so and offers no prices', (tester) async {
      useLargeViewport(tester);
      final env = await packsEnv(
        store: FakePurchaseGateway()..pricesEmpty = true,
      );
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.packsTitle')));

      expect(find.text(en.t('shop.packsStoreSilent')), findsOneWidget);
      expect(find.text('4,99 zł'), findsNothing);
    });
  });

  group('the shop does not nag', () {
    testWidgets('the packs sit below the earning panel', (tester) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.packsTitle')));

      final earning = tester.getTopLeft(find.text(en.t('shop.earnHint'))).dy;
      final packs = tester.getTopLeft(headingText(en.t('shop.packsTitle'))).dy;
      expect(
        packs,
        greaterThan(earning),
        reason: 'the order is the argument: Sparks come from playing first',
      );
    });

    testWidgets('it says once that nothing is behind a payment', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.packsTitle')));
      expect(find.text(en.t('shop.packsHint')), findsOneWidget);
    });

    testWidgets('no urgency, no discount and no "best value" anywhere', (
      tester,
    ) async {
      // Checked against the strings rather than the pixels, because this is a
      // rule about what the app is allowed to say.
      for (final table in [Strings.en, Strings.pl]) {
        for (final key in table.keys.where(
          (k) => k.startsWith('shop.pack') || k.startsWith('pack.'),
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
            'najlepsza oferta',
            'najpopularniejsz',
            'oszczędzasz',
            'tylko teraz',
            'pośpiesz',
            'promocja',
          ]) {
            expect(value, isNot(contains(nag)), reason: '$key nags: "$nag"');
          }
        }
      }
    });

    testWidgets('nothing outside the shop mentions buying Sparks', (
      tester,
    ) async {
      // The title screen, the game-over screen and Settings must not point at the
      // packs. Checked by key prefix: every string about buying lives under
      // `shop.pack*`, so nothing else can be pointing at it.
      for (final table in [Strings.en, Strings.pl]) {
        for (final entry in table.entries) {
          if (entry.key.startsWith('shop.')) continue;
          if (entry.key.startsWith('pack.')) continue;
          final value = entry.value.toLowerCase();
          for (final word in const ['buy sparks', 'kup iskry']) {
            expect(entry.value, isNot(contains(word)), reason: entry.key);
            expect(value, isNot(contains(word)), reason: entry.key);
          }
        }
      }
    });
  });

  group('buying', () {
    testWidgets('a tap opens the store for that product', (tester) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      env.api.syncCreditsOnCall = 300;
      await openShop(tester, env);
      await scrollTo(tester, find.text('4,99 zł'));

      await tester.tap(find.text('4,99 zł'));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(env.store.bought, ['arco.sparks.small']);
    });

    testWidgets('the message carries the server\'s balance', (tester) async {
      useLargeViewport(tester);
      final env = await packsEnv(balance: 50);
      env.api.syncCreditsOnCall = 300;
      await openShop(tester, env);
      await scrollTo(tester, find.text('4,99 zł'));

      await tester.tap(find.text('4,99 zł'));
      await tester.pump();
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        find.text(
          en.f('shop.packBought', {
            'sparks': en.sparks(300),
            'balance': en.sparks(350),
          }),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a paid purchase the server has not credited says so', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv(balance: 50);
      // The store took the money and the server has credited nothing yet: the
      // screen must not invent a figure.
      env.api.syncCreditsOnCall = 0;
      await openShop(tester, env);
      await scrollTo(tester, find.text('4,99 zł'));

      await tester.tap(find.text('4,99 zł'));
      await tester.pump();
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(find.text(en.t('shop.packWaiting')), findsOneWidget);
    });

    testWidgets('cancelling says nothing at all', (tester) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      env.store.outcome = PurchaseOutcome.cancelled;
      await openShop(tester, env);
      await scrollTo(tester, find.text('4,99 zł'));

      await tester.tap(find.text('4,99 zł'));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

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
      final env = await packsEnv();
      env.store.outcome = PurchaseOutcome.pending;
      await openShop(tester, env);
      await scrollTo(tester, find.text('4,99 zł'));

      await tester.tap(find.text('4,99 zł'));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(find.text(en.t('shop.packPending')), findsOneWidget);
      expect(find.text(en.t('shop.packFailed')), findsNothing);
    });

    testWidgets('a store that is down says nothing was charged', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      env.store.outcome = PurchaseOutcome.storeUnavailable;
      await openShop(tester, env);
      await scrollTo(tester, find.text('4,99 zł'));

      await tester.tap(find.text('4,99 zł'));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(find.text(en.t('shop.packStoreDown')), findsOneWidget);
    });

    testWidgets('a pack with no store price cannot be tapped', (tester) async {
      useLargeViewport(tester);
      final env = await packsEnv(
        store: FakePurchaseGateway(
          prices: const {'arco.sparks.small': '4,99 zł'},
        ),
      );
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('shop.packsPriceMissing')).first);

      await tester.tap(find.text(en.t('shop.packsPriceMissing')).first);
      await tester.pump();
      expect(env.store.bought, isEmpty);
    });
  });

  group('restore purchases', () {
    testWidgets('the button is there and says plainly what it does', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('shop.restore')));

      expect(find.text(en.t('shop.restore')), findsOneWidget);
      // The honest sentence, not fine print: a consumable does not restore, the
      // Sparks are on the Arco player rather than the phone, and signing in is
      // what carries them.
      expect(find.text(en.t('shop.restoreHint')), findsOneWidget);
    });

    testWidgets('tapping it asks the store and the server', (tester) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('shop.restore')));

      await tester.tap(find.text(en.t('shop.restore')));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(env.store.restoreCalls, 1);
      expect(env.api.purchasesSyncCalls, greaterThanOrEqualTo(1));
      expect(find.text(en.t('shop.restoreNothing')), findsOneWidget);
    });

    testWidgets('a payment it recovers is reported with the server\'s figure', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      env.api.syncCreditsOnCall = 800;
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('shop.restore')));

      await tester.tap(find.text(en.t('shop.restore')));
      await tester.pump();
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        find.text(en.f('shop.restoreCredited', {'sparks': en.sparks(800)})),
        findsOneWidget,
      );
    });
  });

  group('Polish', () {
    testWidgets('the whole section is translated, with declined amounts', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await packsEnv();
      env.settings.language = AppLanguage.pl;
      await openShop(tester, env);
      await scrollTo(tester, headingText(pl.t('shop.packsTitle')));

      expect(headingText(pl.t('shop.packsTitle')), findsOneWidget);
      expect(find.text(pl.t('shop.restore')), findsOneWidget);
      // 300 iskier, 800 iskier, 2000 iskier — the genitive plural, which is the
      // form a naive implementation gets wrong.
      expect(find.text(pl.sparks(300)), findsOneWidget);
      expect(find.text(pl.sparks(800)), findsOneWidget);
      expect(find.text(pl.sparks(2000)), findsOneWidget);
      // And the price is still the store's, untranslated and untouched.
      expect(find.text('4,99 zł'), findsOneWidget);
    });
  });
}
