// The two money paths on a real device, against a real server
// (SPEC §4.9 the one-time unlock, SPEC §4.10 rewarded ads).
//
//   flutter test integration_test/money_tour_test.dart -d <device-id> \
//       --dart-define=SERVER_URL=http://127.0.0.1:8080 \
//       --dart-define=MONEY_CONTROL_URL=http://127.0.0.1:8099 \
//       --dart-define=REVENUECAT_IOS_KEY=appl_… \
//       --dart-define=ADMOB_TEST_ADS=on
//
// What only a device and a live server can show, and what no unit test can:
//
//   * the **real StoreKit / Play Billing layer** answers this build — the product
//     id the server advertises is the id the store has, and the price shown is the
//     store's own string. With Xcode's `ios/Arco.storekit` configuration enabled
//     in the run scheme this needs no App Store account. The product is a
//     **non-consumable**, so a second run on the same simulator finds it already
//     owned, which is itself one of the cases worth walking;
//   * the **real Mobile Ads SDK** loads Google's published test rewarded unit and
//     plays it to the end on this simulator;
//   * and — the point of both features — **watching an ad and finishing a
//     purchase grant nothing on the phone.** The balance on screen moves only
//     after the server has been credited through its own verified path, and it then
//     equals the balance the server holds, to the Spark; the unlock appears only
//     after the server says the entitlement is granted.
//
// The server side is driven through the verification harness named by
// `MONEY_CONTROL_URL`: it mints a RevenueCat-shaped webhook and an AdMob
// server-side-verification callback signed with a real P-256 key, which is the
// one thing a simulator cannot receive from the outside world. Everything those
// two calls then reach — the shared-secret comparison, the ECDSA verification,
// the crediting transaction — is the shipping server. Without that define the
// test still runs and still proves the half it can: that nothing credits itself.
//
// It holds on each interesting screen for [_screenHold] so an external
// screenshot loop (`xcrun simctl io <udid> screenshot …`) catches it, and prints
// every figure it reads with an `ARCO-MONEY:` prefix so the run can be checked
// against the server's own database afterwards.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:arco/app/ads_config.dart';
import 'package:arco/app/purchase_config.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/main.dart' as app;
import 'package:arco/services/ads_gateway.dart';
import 'package:arco/services/ads_service.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/player_identity.dart';
import 'package:arco/services/purchase_service.dart';
import 'package:arco/services/shop_service.dart';
import 'package:arco/ui/home_screen.dart';
import 'package:arco/ui/onboarding_screen.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:arco/ui/widgets/neon_button.dart';
import 'package:arco/ui/widgets/spark_ad.dart';
import 'package:arco/ui/widgets/spark_balance.dart';
import 'package:arco/ui/widgets/unlock_card.dart';

const Duration _frame = Duration(milliseconds: 16);
const Duration _screenHold = Duration(seconds: 3);

/// The product this run buys: `FullUnlock.productId` on the server.
const String _unlock = 'arco.unlock.full';

/// What one rewarded ad pays, per the server's `AdRate`.
const int _adSparks = 10;

/// The verification harness (see the file comment). Empty means "not available",
/// and the credited halves are then reported as skipped rather than faked.
const String _controlUrl = String.fromEnvironment('MONEY_CONTROL_URL');

/// `--dart-define=MONEY_SHOW_CONSENT_FORM=on` lets the run actually open
/// Google's consent form when the SDK says one is required here.
///
/// Off by default, and deliberately: the form is a native sheet outside the
/// Flutter view, so **only a human can answer it** — `simctl` cannot tap, and a
/// run that opened it unattended would hang until the timeout. With it off the
/// test still checks the property that matters, which is that a required form
/// means `canWatch` is false and therefore no ad was ever requested.
const String _consentFormFlag = String.fromEnvironment(
  'MONEY_SHOW_CONSENT_FORM',
);
bool get _showConsentForm => _consentFormFlag.toLowerCase() == 'on';

void say(Object? message) {
  // ignore: avoid_print
  print('ARCO-MONEY: $message');
}

T serviceOf<T>(WidgetTester tester) =>
    Provider.of<T>(tester.element(find.byType(MaterialApp)), listen: false);

Future<void> hold(WidgetTester tester, Duration duration) async {
  final clock = tester.binding.clock;
  final end = clock.now().add(duration);
  final maxFrames = duration.inMilliseconds ~/ _frame.inMilliseconds + 240;
  var frames = 0;
  while (frames < maxFrames && clock.now().isBefore(end)) {
    await tester.pump(_frame);
    frames++;
  }
}

/// Pumps until [ready] holds, or gives up. Never `pumpAndSettle`: the arena
/// animates forever, so "settled" never happens.
Future<bool> waitFor(
  WidgetTester tester,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final clock = tester.binding.clock;
  final end = clock.now().add(timeout);
  var frames = 0;
  while (clock.now().isBefore(end) && frames < 6000) {
    if (ready()) return true;
    await tester.pump(_frame);
    frames++;
  }
  return ready();
}

/// Asserts that [finder] puts nothing on screen.
///
/// Two shapes count, and both are the shop saying "there is nothing here": the
/// widget is not built at all (the catalogue never arrived), or it is built and
/// returns `SizedBox.shrink()`. A shrink inside a stretching column still takes
/// the column's width, so height is what "draws nothing" means.
///
/// It **waits** for that, rather than reading the layout the instant a service
/// call returned. Every caller here asserts right after awaiting something that
/// ends in `notifyListeners()`, and a listener marks the element dirty for the
/// *next* frame: the size still on the render object at that moment is the one
/// from before the answer arrived. Reading it directly makes this assertion a
/// race, and a race that fails on a device and passes in a widget test is the
/// worst kind — it reports the app hiding nothing when the app is hiding it a
/// frame later.
Future<void> expectDrawsNothing(
  WidgetTester tester,
  Finder finder, {
  required String reason,
}) async {
  bool drawsNothing() {
    final elements = finder.evaluate();
    if (elements.isEmpty) return true;
    return tester.getSize(finder).height == 0;
  }

  await waitFor(tester, drawsNothing, timeout: const Duration(seconds: 5));
  if (finder.evaluate().isEmpty) return;
  expect(tester.getSize(finder).height, 0, reason: reason);
}

/// Scrolls the shop to the bottom, where the earning panel, the ad row and the
/// unlock card live, and holds there so a screenshot loop catches them.
Future<void> showMoneySections(WidgetTester tester) async {
  final list = find.byType(Scrollable);
  if (list.evaluate().isEmpty) return;
  for (var i = 0; i < 14; i++) {
    await tester.drag(list.first, const Offset(0, -320));
    await tester.pump(_frame);
  }
  await hold(tester, _screenHold);
}

/// The harness call that delivers one RevenueCat webhook for [transactionId].
///
/// The harness builds the envelope RevenueCat posts and signs it with the shared
/// secret; it deliberately also carries a `sparks`, a `price` and a `quantity`,
/// none of which the server reads.
Future<Map<String, dynamic>> deliverWebhook({
  required String playerId,
  required String transactionId,
}) async {
  final response = await http.post(
    Uri.parse('$_controlUrl/control/webhook'),
    headers: const {'Content-Type': 'application/json'},
    body: jsonEncode({
      'playerId': playerId,
      'productId': _unlock,
      'transactionId': transactionId,
    }),
  );
  return jsonDecode(response.body) as Map<String, dynamic>;
}

/// The harness call that delivers one signed AdMob verification callback.
Future<Map<String, dynamic>> deliverAdCallback({
  required String playerId,
  required String transactionId,
  required String placement,
}) async {
  final response = await http.post(
    Uri.parse('$_controlUrl/control/adcallback'),
    headers: const {'Content-Type': 'application/json'},
    body: jsonEncode({
      'playerId': playerId,
      'transactionId': transactionId,
      'placement': placement,
    }),
  );
  return jsonDecode(response.body) as Map<String, dynamic>;
}

/// The wallet as the **server** holds it, read with the app's own credentials.
Future<Map<String, dynamic>> serverWallet(
  ApiClient api,
  PlayerCredentials credentials,
) async {
  final response = await http.get(
    Uri.parse('${api.baseUrl}/api/shop/inventory'),
    headers: {'Authorization': 'Arco ${credentials.id}:${credentials.secret}'},
  );
  return jsonDecode(response.body) as Map<String, dynamic>;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('money: nothing credits itself, and the server is the wallet', (
    tester,
  ) async {
    app.main();
    expect(
      await waitFor(
        tester,
        () => find
            .byWidgetPredicate((w) => w is HomeScreen || w is OnboardingScreen)
            .evaluate()
            .isNotEmpty,
      ),
      isTrue,
      reason: 'the app must reach its first screen',
    );

    final api = serviceOf<ApiClient>(tester);
    final identity = serviceOf<PlayerIdentity>(tester);
    final shop = serviceOf<ShopService>(tester);
    final purchases = serviceOf<PurchaseService>(tester);
    final ads = serviceOf<AdsService>(tester);

    say('server=${api.baseUrl}');
    say('control=${_controlUrl.isEmpty ? '(none)' : _controlUrl}');
    say('revenueCat configured=${PurchaseConfig.configured}');
    say(
      'admob unit=${AdsConfig.rewardedUnitId ?? '(none)'} '
      'testAds=${AdsConfig.testAds}',
    );

    // A fresh install opens on the welcome screen; continue through it.
    final strings = Strings.read(tester.element(find.byType(MaterialApp)));
    if (find.byType(OnboardingScreen).evaluate().isNotEmpty) {
      final start = find.ancestor(
        of: find.text(strings.t('onboarding.start')),
        matching: find.byType(NeonButton),
      );
      await tester.ensureVisible(start.first);
      await hold(tester, const Duration(milliseconds: 300));
      await tester.tap(start.first);
      expect(
        await waitFor(
          tester,
          () => find.byType(HomeScreen).evaluate().isNotEmpty,
        ),
        isTrue,
        reason: 'the welcome screen must lead to the home screen',
      );
      await hold(tester, const Duration(seconds: 1));
    }

    // ------------------------------------------------------------------ shop

    // Into the shop the way a player gets there: the wallet card on the home
    // screen.
    expect(find.byType(ShopEntryCard), findsOneWidget);
    await tester.tap(find.byType(ShopEntryCard));
    await hold(tester, _screenHold);
    expect(find.byType(ShopScreen), findsOneWidget);

    final reachedServer = await waitFor(tester, () => shop.snapshot.known);
    final credentials = await identity.ensureIssued();
    say(
      'reached the server=$reachedServer '
      'playerId=${credentials?.id ?? '(none issued)'}',
    );

    if (!reachedServer) {
      // No network, or no server: the case a player on a train is in. The game
      // is not allowed to become a worse game because of it, and it is
      // certainly not allowed to offer something it cannot honour.
      await purchases.refresh();
      await ads.refresh();
      await hold(tester, const Duration(seconds: 2));
      say(
        'offline: purchases offered=${purchases.offered} '
        'status=${purchases.status.name} | ads offeredInShop='
        '${ads.offeredInShop} consent=${ads.consent.name} '
        'offerAvailable=${ads.offer.available}',
      );
      expect(
        purchases.offered,
        isFalse,
        reason: 'an unreachable server sells nothing',
      );
      expect(
        ads.offeredInShop,
        isFalse,
        reason: 'an unreachable server pays nothing for an ad',
      );
      await expectDrawsNothing(
        tester,
        find.byType(UnlockSection),
        reason: 'no unlock card when there is no server',
      );
      await expectDrawsNothing(
        tester,
        find.byType(SparkAdSection),
        reason: 'no ad row when there is no server',
      );
      // And the shop is still a shop: the catalogue the phone last cached, or
      // the built-in free skins on a first run.
      await showMoneySections(tester);
      say('offline: the shop still draws, with no money in it. done');
      return;
    }

    expect(credentials, isNotNull, reason: 'the shop must issue a player');
    final player = credentials!;

    Future<void> expectAppMatchesServer(String when) async {
      final server = await serverWallet(api, player);
      await shop.refresh(force: true);
      await hold(tester, const Duration(milliseconds: 400));
      say(
        '$when: app balance=${shop.balance} | server balance=${server['balance']} '
        'purchasedTotal=${server['purchasedTotal']} adTotal=${server['adTotal']} '
        'earnedTotal=${server['earnedTotal']}',
      );
      expect(
        shop.balance,
        server['balance'],
        reason: 'the balance on screen must be the balance the server holds',
      );
    }

    await expectAppMatchesServer('fresh shop');
    final opening = shop.balance;
    await showMoneySections(tester);

    // -------------------------------------------------------- the real store

    await purchases.refresh();
    await waitFor(
      tester,
      () => purchases.status != PurchaseStatus.loading,
      timeout: const Duration(seconds: 25),
    );
    say(
      'purchase status=${purchases.status.name} offered=${purchases.offered} '
      'premium=${purchases.premium}',
    );
    final offer = purchases.offer;
    if (offer != null) {
      say(
        '  unlock ${offer.productId} '
        'store price=${offer.priceString ?? '(the store did not answer)'}',
      );
    }
    final sellsUnlock = shop.snapshot.unlock != null;
    final alreadyPremium = shop.snapshot.premium;
    if (!sellsUnlock && !alreadyPremium) {
      // A deployment with `PURCHASES_ENABLED=off`, or one the phone could not
      // reach. Either way the shop must be a cosmetics shop with **no money in
      // it at all** — not an empty price, not a disabled button, nothing.
      say(
        'the server sells nothing, so the shop shows nothing: '
        'offered=${purchases.offered} status=${purchases.status.name}',
      );
      expect(
        purchases.offered,
        isFalse,
        reason: 'no product from the server means no unlock card',
      );
      // The section is always in the tree and shrinks to nothing, so what is
      // checked is what it draws.
      expect(
        find.text(strings.t('shop.unlockTitle').toUpperCase()),
        findsNothing,
        reason: 'nothing for sale means no unlock heading anywhere',
      );
      await expectDrawsNothing(
        tester,
        find.byType(UnlockSection),
        reason: 'the unlock card must draw nothing at all',
      );
    } else if (alreadyPremium) {
      // A simulator that already bought the non-consumable on an earlier run —
      // which is exactly the state a reinstall is in, and the state the old
      // consumable model could never reach. The offer must be gone, every cosmetic
      // must be owned, and no ad may be offered.
      say('this player is already premium: the offer must be gone');
      expect(
        purchases.offered,
        isFalse,
        reason: 'a player who has paid must never be shown the price again',
      );
      expect(
        shop.snapshot.items.every((item) => shop.snapshot.owns(item.id)),
        isTrue,
        reason: 'premium owns the whole catalogue',
      );
      expect(
        ads.offer.available,
        isFalse,
        reason: 'the unlock buys no ads, not fewer ads',
      );
    } else {
      // The server's product carries no price: the id is ours, the money is the
      // store's.
      expect(
        shop.snapshot.unlock!.productId,
        _unlock,
        reason: 'a server that sells must offer this product',
      );
    }

    if (purchases.status == PurchaseStatus.ready) {
      await hold(tester, _screenHold);
      final report = await purchases.buy(_unlock);
      say(
        'real store purchase of $_unlock -> ${report.kind.name} '
        'premium=${report.premium} serverAnswered=${report.serverAnswered}',
      );
      // Whatever the store did, the app may not have unlocked anything by itself:
      // every figure and every lock on screen is still the server's.
      await expectAppMatchesServer('after the store sheet');
      expect(
        shop.snapshot.premium,
        report.premium,
        reason: 'the phone and the server must agree about the entitlement',
      );
    } else {
      say(
        'SKIPPED the store sheet: status=${purchases.status.name}. '
        'A build with no RevenueCat key, a device whose store does not know this '
        'product, or a player who already owns it.',
      );
      expect(
        purchases.offer?.buyable ?? false,
        isFalse,
        reason: 'an unpriced product must never be buyable',
      );
    }

    // ------------------------------------------- the server grants, we do not

    if (_controlUrl.isNotEmpty && (sellsUnlock || alreadyPremium)) {
      final txn = 'storekit-${DateTime.now().microsecondsSinceEpoch}';
      final first = await deliverWebhook(
        playerId: player.id,
        transactionId: txn,
      );
      say('webhook #1 -> $first');
      // `granted` is about the **transaction**, not about the player, and this
      // transaction id is minted fresh on every run. A player who is already
      // premium — the same simulator on a second run, or a second store — still
      // gets a new ledger row for a payment the server has never seen, which is
      // what makes refunding one of two rows leave the other standing.
      expect(
        first['granted'],
        isTrue,
        reason:
            'a transaction id the server has never seen is a new grant, '
            'premium or not',
      );
      expect(first['duplicate'], isFalse);
      expect(first['premium'], isTrue);

      // The app learns about it the only way it can: by asking.
      await purchases.recheck();
      await expectAppMatchesServer('after the webhook');
      expect(
        shop.snapshot.premium,
        isTrue,
        reason: 'the server granted it, so the phone must now see it',
      );
      expect(
        shop.snapshot.items.every((item) => shop.snapshot.owns(item.id)),
        isTrue,
        reason: 'every cosmetic, present and future',
      );
      await ads.refresh();
      expect(
        ads.offeredInShop,
        isFalse,
        reason: 'no ad is offered to somebody who paid for none',
      );
      await expectDrawsNothing(
        tester,
        find.byType(SparkAdSection),
        reason: 'the ad row must be gone entirely',
      );
      await showMoneySections(tester);

      // The second delivery of the same transaction.
      final again = await deliverWebhook(
        playerId: player.id,
        transactionId: txn,
      );
      say('webhook #2 (same transaction) -> $again');
      expect(again['granted'], isFalse);
      expect(again['duplicate'], isTrue);
      await purchases.recheck();
      await expectAppMatchesServer('after the replayed webhook');
      expect(
        shop.snapshot.premium,
        isTrue,
        reason: 'a replayed transaction changes nothing',
      );

      // And restore, which under this model is a real feature: the server
      // re-verifies with RevenueCat and answers with what it holds.
      final restored = await purchases.restore();
      say(
        'restore -> premium=${restored.premium} granted=${restored.granted} '
        'failed=${restored.failed}',
      );
      expect(restored.failed, isFalse);
      expect(
        restored.premium,
        isTrue,
        reason: 'a non-consumable genuinely restores',
      );
    } else {
      say(
        'SKIPPED the granted purchase halves: '
        'controlUrl=${_controlUrl.isNotEmpty} '
        'sellsUnlock=$sellsUnlock premium=$alreadyPremium.',
      );
    }

    // ------------------------------------------------------------- a real ad

    await ads.refresh();
    await waitFor(
      tester,
      () => ads.canWatch || !ads.configured,
      timeout: const Duration(seconds: 30),
    );
    say(
      'ads configured=${ads.configured} consent=${ads.consent.name} '
      'canWatch=${ads.canWatch} offeredInShop=${ads.offeredInShop} '
      'offer(available=${ads.offer.available} sparks=${ads.offer.sparks} '
      'remaining=${ads.offer.remaining} waitSeconds=${ads.offer.waitSeconds})',
    );

    if (ads.canWatch) {
      final beforeAd = shop.balance;
      await hold(tester, _screenHold);
      final report = await ads.watch(AdPlacementId.shop);
      say(
        'real rewarded ad -> ${report.kind.name} sparks=${report.sparks} '
        'balance=${report.balance}',
      );
      // The ad was watched. Google's callback cannot reach a laptop, so the
      // server has not been told, so there must be no Sparks.
      await expectAppMatchesServer(
        'after watching the ad, before any callback',
      );
      expect(
        shop.balance,
        beforeAd,
        reason: 'watching an ad credits nothing: only the server callback does',
      );

      if (_controlUrl.isNotEmpty) {
        final credited = await deliverAdCallback(
          playerId: player.id,
          transactionId: 'admob-${DateTime.now().microsecondsSinceEpoch}',
          placement: 'shop',
        );
        say('signed AdMob callback -> $credited');
        expect(credited['credited'], _adSparks);
        await ads.refresh();
        await expectAppMatchesServer('after the signed callback');
        expect(
          shop.balance,
          beforeAd + _adSparks,
          reason: 'an ad pays exactly what the server table says',
        );
      }
    } else if (ads.needsConsent) {
      // The server says an ad would pay and Google's UMP SDK says a consent form
      // is required here, so what the shop offers is the form, not an ad. The
      // property to check is that **no ad was requested**: a build that asked
      // Google for one before consent would be the compliance problem the whole
      // flow exists to avoid.
      say(
        'consent is required here, so the shop offers the form and no ad was '
        'requested (canWatch=${ads.canWatch}). Refusing it leaves the game '
        'exactly as it is, with no ad row.',
      );
      expect(
        ads.canWatch,
        isFalse,
        reason: 'no ad may be in hand before consent',
      );
      expect(
        ads.offeredInShop,
        isTrue,
        reason: 'the shop is where the form is offered',
      );
      await showMoneySections(tester);
      if (_showConsentForm) {
        final beforeAd = shop.balance;
        final report = await ads.watch(AdPlacementId.shop);
        say(
          'consent form answered -> ${report.kind.name} '
          'consent is now ${ads.consent.name} canWatch=${ads.canWatch}',
        );
        await expectAppMatchesServer('after the consent form');
        expect(
          shop.balance,
          beforeAd,
          reason: 'answering a consent form credits nothing',
        );
      }
    } else {
      say(
        'SKIPPED the ad: configured=${ads.configured} '
        'consent=${ads.consent.name} offerAvailable=${ads.offer.available}. '
        'A build with no AdMob unit, or a server with ads switched off, draws '
        'no ad row at all — which is the documented behaviour.',
      );
      // "No ad to offer" and "nothing to say" are different states, and only
      // the second one draws nothing. A deployment with ads switched off, or a
      // build with no AdMob unit, owes the player no explanation for a row that
      // was never there — but an ad that is merely on cooldown, or a day that is
      // already full, is a sentence worth one line, and the row keeps that line.
      // Asserting a blank row on `!available` alone would be asserting that the
      // app forgets to say why.
      final nothingToSay =
          !ads.configured || ads.premium || ads.offer.dailyCap <= 0;
      if (nothingToSay) {
        await expectDrawsNothing(
          tester,
          find.byType(SparkAdSection),
          reason: 'a server that pays nothing for an ad must draw no ad row',
        );
      } else {
        say(
          'the ad row keeps a one-line note: dayFull=${ads.offer.dayFull} '
          'waitSeconds=${ads.offer.waitSeconds}',
        );
      }
    }

    // ------------------------------------------------- the game still works

    // Whatever the money paths did or did not do, this is a cosmetics shop and
    // it works: the catalogue is there and nothing about it is gated.
    expect(shop.snapshot.items, isNotEmpty);
    say(
      'cosmetics on offer=${shop.snapshot.items.length} '
      'owned=${shop.snapshot.owned.length} openingBalance=$opening',
    );
    await hold(tester, _screenHold);
    say('done');
  });
}
