/// The rewarded-ad row in the shop, and the offer on the game-over overlay
/// (SPEC §4.10).
///
/// What these tests are actually defending:
///
/// * **the button is absent whenever it would not work.** No ad loaded, no AdMob
///   configured, a deployment that credits no ads, the day's allowance spent, the
///   cooldown running — every one of those draws no button. A rewarded button that
///   spins or fails is worse than no button.
/// * **the order on screen is the argument**: earning panel, then the ad, then the
///   packs. Playing first, half a minute of attention second, money last.
/// * **the consent form is offered in the shop and never on the game-over
///   overlay**, and refusing it leaves a fully working shop with no ad row.
/// * **no number on screen is this app's**: a watched ad shows the balance the
///   server reported, and while the server has not credited it the screen says so.
/// * **an ad is never offered before or during a game** — only on the overlay after
///   one.
library;

import 'package:arco/app/strings.dart';
import 'package:arco/services/ads_gateway.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:arco/ui/solo_screen.dart';
import 'package:arco/ui/widgets/spark_ad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  const en = Strings('en');

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

  /// A device on a deployment that credits rewarded ads.
  Future<TestEnv> adEnv({
    int balance = 0,
    FakeAdsGateway? gateway,
    AdOffer? offer,
    List<ShopPack>? packs,
  }) async {
    final env = await createTestEnv(
      balance: balance,
      packs: packs ?? const <ShopPack>[],
      adsGateway: gateway ?? FakeAdsGateway(),
      adOffer: offer ?? testAdOffer(balance: balance),
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    env.api.profile = PlayerProfile(id: testPlayerId(1), games: 2);
    return env;
  }

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

  group('the row is absent whenever it would not work', () {
    testWidgets('a deployment that credits no ads draws nothing', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.profile = PlayerProfile(id: testPlayerId(1), games: 2);
      await openShop(tester, env);

      // The widget is in the tree (the screen always builds it) and renders
      // nothing: no title, no button, no apology.
      expect(find.byType(SparkAdSection), findsOneWidget);
      expect(headingText(en.t('ads.title')), findsNothing);
      expect(find.text(en.t('ads.watch')), findsNothing);
      expect(env.adsGateway.loadCalls, 0);
    });

    testWidgets('a build with no AdMob unit draws nothing', (tester) async {
      useLargeViewport(tester);
      final env = await adEnv(gateway: FakeAdsGateway(available: false));
      await openShop(tester, env);

      expect(headingText(en.t('ads.title')), findsNothing);
      expect(find.text(en.t('ads.watch')), findsNothing);
    });

    testWidgets('no ad loaded means no button', (tester) async {
      // The whole reason the ad is preloaded. A button drawn now would be a button
      // that fetches on tap, spins, and sometimes fails.
      useLargeViewport(tester);
      final env = await adEnv(gateway: FakeAdsGateway(fills: false));
      await openShop(tester, env);

      expect(env.adsGateway.loadCalls, 1, reason: 'it was asked for');
      expect(find.text(en.t('ads.watch')), findsNothing);
      expect(headingText(en.t('ads.title')), findsNothing);
    });

    testWidgets('the cooldown says which bound it is, without a button', (
      tester,
    ) async {
      // A row that was there five minutes ago and is gone now reads as a bug, so
      // the two bounds get a sentence. Everything else is silence.
      useLargeViewport(tester);
      final env = await adEnv(
        offer: testAdOffer(
          available: false,
          waitSeconds: 130,
          earnedToday: 10,
          adTotal: 10,
        ),
      );
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('ads.title')));

      expect(find.text(en.f('ads.cooldown', {'minutes': 3})), findsOneWidget);
      expect(find.text(en.t('ads.watch')), findsNothing);
      expect(
        find.text(en.f('ads.today', {'earned': 10, 'cap': 60})),
        findsOneWidget,
      );
    });

    testWidgets('the day\'s allowance being spent says so', (tester) async {
      useLargeViewport(tester);
      final env = await adEnv(
        offer: testAdOffer(
          available: false,
          sparks: 0,
          earnedToday: 60,
          remaining: 0,
          adTotal: 60,
        ),
      );
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('ads.title')));

      expect(find.text(en.t('ads.dayFull')), findsOneWidget);
      expect(find.text(en.t('ads.watch')), findsNothing);
    });
  });

  group('the row when there is an ad', () {
    testWidgets('shows what it pays and what the day has paid', (tester) async {
      useLargeViewport(tester);
      final env = await adEnv(offer: testAdOffer(earnedToday: 20, adTotal: 20));
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('ads.title')));

      // Every number is the server's.
      expect(
        find.text(en.f('ads.hint', {'sparks': en.sparks(10)})),
        findsOneWidget,
      );
      expect(
        find.text(en.f('ads.today', {'earned': 20, 'cap': 60})),
        findsOneWidget,
      );
      expect(find.text(en.t('ads.watch')), findsOneWidget);
    });

    testWidgets('sits between the earning panel and the packs', (tester) async {
      // The order is the argument twice over: sparks come from playing; an ad costs
      // attention; a pack costs money.
      useLargeViewport(tester);
      final env = await adEnv(packs: testSparkPacks());
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('shop.packsTitle')));

      final earning = tester.getTopLeft(find.text(en.t('shop.earnHint'))).dy;
      final ad = tester.getTopLeft(headingText(en.t('ads.title'))).dy;
      final packs = tester.getTopLeft(headingText(en.t('shop.packsTitle'))).dy;
      expect(ad, greaterThan(earning));
      expect(packs, greaterThan(ad));
    });

    testWidgets('a tap shows the ad, attributed to this player', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await adEnv();
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('ads.watch')));

      await tester.tap(find.text(en.t('ads.watch')));
      await tester.pump();
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final shown = env.adsGateway.shown.single;
      expect(shown.playerId, testPlayerId(1));
      expect(shown.placement, AdPlacementId.shop);
    });

    testWidgets('the message carries the server\'s balance', (tester) async {
      useLargeViewport(tester);
      final env = await adEnv(balance: 40);
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('ads.watch')));
      // The server's move, armed *after* the screen has settled: it stands in for
      // Google's signed callback landing while the ad is on screen.
      env.api.adCreditsOnNextOffer = 10;

      await tester.tap(find.text(en.t('ads.watch')));
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        find.text(
          en.f('ads.credited', {
            'sparks': en.sparks(10),
            'balance': en.sparks(50),
          }),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a server that has not credited yet says "on their way"', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await adEnv(balance: 40);
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('ads.watch')));

      await tester.tap(find.text(en.t('ads.watch')));
      await tester.pump();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(find.text(en.t('ads.waiting')), findsOneWidget);
      // And no number was invented: the wallet in the app bar is unchanged.
      expect(env.shop.balance, 40);
    });

    testWidgets('closing the ad early says nothing at all', (tester) async {
      useLargeViewport(tester);
      final env = await adEnv();
      env.adsGateway.showOutcome = AdShowOutcome.dismissed;
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('ads.watch')));

      await tester.tap(find.text(en.t('ads.watch')));
      await tester.pump();
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(find.byType(SnackBar), findsNothing);
      expect(find.text(en.t('ads.waiting')), findsNothing);
      expect(find.text(en.t('ads.noAd')), findsNothing);
    });
  });

  group('consent', () {
    testWidgets('an unanswered form is offered here, in place of the ad', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await adEnv(
        gateway: FakeAdsGateway(consentState: AdConsentState.required),
      );
      await openShop(tester, env);
      await scrollTo(tester, headingText(en.t('ads.title')));

      // The ask, with the line above already saying that declining costs nothing.
      expect(find.text(en.t('ads.consentButton')), findsOneWidget);
      expect(find.text(en.t('ads.consentHint')), findsOneWidget);
      expect(find.text(en.t('ads.watch')), findsNothing);
      expect(
        env.adsGateway.loadCalls,
        0,
        reason: 'no ad may be requested before consent',
      );
    });

    testWidgets('refusing leaves a fully working shop with no ad row', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await adEnv(
        balance: 200,
        packs: testSparkPacks(),
        gateway: FakeAdsGateway(consentState: AdConsentState.required)
          ..consentOutcome = AdConsentOutcome.refused,
      );
      await openShop(tester, env);
      await scrollTo(tester, find.text(en.t('ads.consentButton')));

      await tester.tap(find.text(en.t('ads.consentButton')));
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // The row is gone, and nothing was said about it.
      expect(find.text(en.t('ads.consentButton')), findsNothing);
      expect(find.text(en.t('ads.watch')), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(env.adsGateway.showCalls, 0);

      // And the rest of the shop is exactly what it was: the cosmetics, the
      // earning panel, the wallet and the packs.
      expect(find.text(en.t('shop.earnHint')), findsWidgets);
      await scrollTo(tester, headingText(en.t('shop.packsTitle')));
      expect(headingText(en.t('shop.packsTitle')), findsOneWidget);
      expect(env.shop.balance, 200);
      // The game is playable: a cosmetic can still be bought and worn.
      final bought = await env.shop.buy('ball.comet');
      expect(bought.ok, isTrue, reason: 'the shop still works');
      expect(env.shop.snapshot.owns('ball.comet'), isTrue);
    });
  });

  group('the game-over overlay', () {
    /// Plays a solo run to its end. No input at all: the paddle never moves, the
    /// three lives go quickly and the game ends on its own.
    Future<void> playUntilOver(WidgetTester tester, TestEnv env) async {
      await tester.tap(find.text(en.t('solo.tapToStart')).last);
      for (var i = 0; i < 6000 && env.api.submitCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(env.api.submitCalls, 1, reason: 'the game never ended');
      // Frames for the overlay, the ad refresh and the preload.
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Either heading is fine — a first game is a personal best — and Retry is
      // on the overlay whichever it is.
      expect(find.text(en.t('solo.retry')), findsOneWidget);
    }

    testWidgets('offers an ad only after the run, never before it', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await adEnv();
      await tester.pumpWidget(wrapApp(env, const SoloScreen()));
      await tester.pump();

      // The start panel: nothing about ads, and no ad has even been requested.
      expect(find.text(en.t('ads.watch')), findsNothing);
      expect(env.adsGateway.loadCalls, 0);

      await playUntilOver(tester, env);
      expect(find.text(en.t('ads.watch')), findsOneWidget);
      expect(env.adsGateway.loadCalls, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no ad loaded means no button on the overlay either', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await adEnv(gateway: FakeAdsGateway(fills: false));
      await tester.pumpWidget(wrapApp(env, const SoloScreen()));
      await playUntilOver(tester, env);
      expect(find.text(en.t('ads.watch')), findsNothing);
      expect(find.text(en.t('solo.retry')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('never shows the consent form here', (tester) async {
      // Game over is not the moment for a privacy form. The shop is where the ask
      // happens; here there is simply nothing.
      useLargeViewport(tester);
      final env = await adEnv(
        gateway: FakeAdsGateway(consentState: AdConsentState.required),
      );
      await tester.pumpWidget(wrapApp(env, const SoloScreen()));
      await playUntilOver(tester, env);
      expect(find.text(en.t('ads.consentButton')), findsNothing);
      expect(find.text(en.t('ads.watch')), findsNothing);
      expect(env.adsGateway.consentRequestCalls, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a watched ad reports the server\'s figures under the score', (
      tester,
    ) async {
      useLargeViewport(tester);
      final env = await adEnv(balance: 40);
      await tester.pumpWidget(wrapApp(env, const SoloScreen()));
      await playUntilOver(tester, env);
      await tester.ensureVisible(find.text(en.t('ads.watch')));
      await tester.pump();
      // Armed after the overlay has settled: Google's callback lands while the ad
      // is on screen, not before it is offered.
      env.api.adCreditsOnNextOffer = 10;

      await tester.tap(find.text(en.t('ads.watch')));
      await tester.pump();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(env.adsGateway.shown.single.placement, AdPlacementId.gameOver);
      expect(
        find.text(
          en.f('ads.credited', {
            'sparks': en.sparks(10),
            'balance': en.sparks(50),
          }),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });
}
