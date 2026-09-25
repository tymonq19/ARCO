/// Rewarded ads that pay Sparks, client side (SPEC §4.10).
///
/// One rule runs through every test here: **the client never credits a Spark.** An
/// ad is watched through the Google Mobile Ads SDK; the Sparks come from our
/// server, on the server-side verification callback Google signs and posts to it;
/// this app asks and repeats the answer. So most of the assertions are about what
/// the app does *not* do — it does not add, it does not guess, and when the server
/// has not confirmed anything it says exactly that.
///
/// The rest is the list of things that actually happen to real players: no ad fills,
/// they close the ad after ten seconds, they are in Europe and have not chosen about
/// data yet, they choose *no*, they have watched the six the day allows, or they
/// watched one four minutes ago.
library;

import 'package:arco/services/ads_gateway.dart';
import 'package:arco/services/ads_service.dart';
import 'package:arco/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  /// A device on a deployment that credits ads, with the shop already synced —
  /// which is the state the shop screen is in by the time an ad can be tapped.
  Future<TestEnv> adEnv({
    FakeAdsGateway? gateway,
    AdOffer? offer,
    int balance = 0,
  }) async {
    final env = await createTestEnv(
      balance: balance,
      adsGateway: gateway ?? FakeAdsGateway(),
      adOffer: offer ?? testAdOffer(balance: balance),
    );
    await env.shop.refresh(issue: true, force: true);
    await env.ads.refresh();
    return env;
  }

  group('what is offered', () {
    test('nothing at all when the deployment credits no ads', () async {
      // `GET /api/ads/offer` answers `ads_disabled`, which comes back as
      // `AdOffer.none`. The right UI is *nothing* — not a disabled button, not an
      // explanation — because every Spark an ad pays is earnable by playing.
      final env = await createTestEnv(adsGateway: FakeAdsGateway());
      await env.ads.refresh();

      expect(env.ads.offeredInShop, isFalse);
      expect(env.ads.offeredAtGameOver, isFalse);
      expect(env.ads.canWatch, isFalse);
      expect(
        env.adsGateway.loadCalls,
        0,
        reason: 'nothing should ask Google for an ad we could not pay for',
      );
    });

    test('nothing at all when this build has no AdMob unit', () async {
      final env = await adEnv(gateway: FakeAdsGateway(available: false));
      expect(env.ads.configured, isFalse);
      expect(env.ads.offeredInShop, isFalse);
      expect(env.ads.offeredAtGameOver, isFalse);
      expect(env.adsGateway.loadCalls, 0);
    });

    test('nothing when no ad filled, which is the ordinary case', () async {
      // No fill is not an error: there simply is no ad for this player right now.
      // The button is absent rather than present and failing, which is the whole
      // reason it is preloaded.
      final env = await adEnv(gateway: FakeAdsGateway(fills: false));
      expect(env.adsGateway.loadCalls, 1, reason: 'it was asked for');
      expect(env.adsGateway.loaded, isFalse);
      expect(env.ads.canWatch, isFalse);
      expect(env.ads.offeredInShop, isFalse);
      expect(env.ads.offeredAtGameOver, isFalse);
    });

    test(
      'a loaded ad on an available allowance is offered in both places',
      () async {
        final env = await adEnv();
        expect(env.adsGateway.loaded, isTrue);
        expect(env.ads.canWatch, isTrue);
        expect(env.ads.offeredInShop, isTrue);
        expect(env.ads.offeredAtGameOver, isTrue);
        expect(env.ads.offer.sparks, 10, reason: 'the amount is the server\'s');
        expect(env.ads.offer.dailyCap, 60);
      },
    );

    test('nothing during the cooldown, and no ad is even requested', () async {
      final env = await adEnv(
        offer: testAdOffer(available: false, waitSeconds: 190, earnedToday: 10),
      );
      expect(env.ads.canWatch, isFalse);
      expect(env.ads.offeredInShop, isFalse);
      expect(env.ads.offeredAtGameOver, isFalse);
      expect(
        env.adsGateway.loadCalls,
        0,
        reason: 'asking Google for an ad we could not pay for spends real data',
      );
      // The reason is carried, so the shop can say which bound it is rather than
      // silently losing a button that was there a minute ago.
      expect(env.ads.offer.waitSeconds, 190);
      expect(env.ads.offer.dayFull, isFalse);
    });

    test('nothing once the day\'s allowance is spent', () async {
      final env = await adEnv(
        offer: testAdOffer(
          available: false,
          sparks: 0,
          earnedToday: 60,
          remaining: 0,
        ),
      );
      expect(env.ads.canWatch, isFalse);
      expect(env.ads.offeredInShop, isFalse);
      expect(env.ads.offer.dayFull, isTrue);
      expect(env.adsGateway.loadCalls, 0);
    });

    test('a server we cannot reach offers nothing', () async {
      final env = await createTestEnv(
        adsGateway: FakeAdsGateway(),
        adOffer: testAdOffer(),
      );
      env.api.offline = true;
      await env.ads.refresh();
      expect(env.ads.offeredInShop, isFalse);
      expect(env.adsGateway.loadCalls, 0);
    });
  });

  group('consent', () {
    test('is never asked for on its own, only checked', () async {
      // `refreshConsent` shows nothing: it asks Google whether a form is required
      // here. Opening a screen must not put a privacy form in somebody's face.
      final env = await adEnv();
      expect(env.adsGateway.consentRefreshCalls, 0, reason: 'already allowed');
      expect(env.adsGateway.consentRequestCalls, 0);
    });

    test(
      'an unanswered form is what the shop offers, in place of the ad',
      () async {
        final env = await adEnv(
          gateway: FakeAdsGateway(consentState: AdConsentState.required),
        );
        expect(env.ads.needsConsent, isTrue);
        expect(env.ads.canWatch, isFalse);
        expect(
          env.ads.offeredInShop,
          isTrue,
          reason:
              'the shop is where the ask belongs: the player is reading about '
              'earning sparks',
        );
        expect(
          env.ads.offeredAtGameOver,
          isFalse,
          reason: 'game over is not the moment for a privacy form',
        );
        expect(
          env.adsGateway.loadCalls,
          0,
          reason: 'no ad may be requested before consent',
        );
      },
    );

    test('the form is shown on the tap, and then the ad runs', () async {
      final env = await adEnv(
        gateway: FakeAdsGateway(consentState: AdConsentState.required),
      );
      env.api.adCreditsOnNextOffer = 10;
      final report = await env.ads.watch(AdPlacementId.shop);

      expect(env.adsGateway.consentRequestCalls, 1);
      expect(env.adsGateway.showCalls, 1);
      expect(report.kind, AdReportKind.credited);
      expect(report.sparks, 10);
    });

    test('refusing leaves a fully working game with no ad button', () async {
      final env = await adEnv(
        gateway: FakeAdsGateway(consentState: AdConsentState.required)
          ..consentOutcome = AdConsentOutcome.refused,
      );
      final report = await env.ads.watch(AdPlacementId.shop);

      expect(report.kind, AdReportKind.consentRefused);
      expect(
        report.silent,
        isTrue,
        reason: 'a player who said no has said their piece',
      );
      expect(env.adsGateway.showCalls, 0, reason: 'no ad was requested');
      expect(env.ads.consent, AdConsentState.denied);
      expect(env.ads.canWatch, isFalse);
      expect(env.ads.needsConsent, isFalse);
      expect(env.ads.offeredInShop, isFalse, reason: 'the button is gone');
      expect(env.ads.offeredAtGameOver, isFalse);
      // And the rest of the game is untouched: the wallet, the catalogue and the
      // earning panel are exactly what they were.
      expect(env.shop.balanceKnown, isTrue);
      expect(env.shop.snapshot.hasCatalogue, isTrue);
      expect(env.api.adsOfferCalls, greaterThan(0));
      expect(env.shop.balance, 0);
    });

    test('a form that cannot be shown is treated as a refusal', () async {
      // No network, a platform with no UMP, a form Google could not load. The
      // alternative would be requesting an ad we have no permission for.
      final env = await adEnv(
        gateway: FakeAdsGateway(consentState: AdConsentState.required)
          ..consentOutcome = AdConsentOutcome.unavailable,
      );
      final report = await env.ads.watch(AdPlacementId.shop);
      expect(report.kind, AdReportKind.consentRefused);
      expect(env.adsGateway.showCalls, 0);
      expect(env.ads.offeredInShop, isFalse);
    });

    test('a region that needs no form gets straight to the ad', () async {
      final env = await adEnv();
      env.api.adCreditsOnNextOffer = 10;
      final report = await env.ads.watch(AdPlacementId.shop);
      expect(
        env.adsGateway.consentRequestCalls,
        0,
        reason: 'consent was already allowed; nothing to ask',
      );
      expect(report.kind, AdReportKind.credited);
    });
  });

  group('watching one', () {
    test('the reward is never credited client side', () async {
      // The single most important test in this file. The gateway reports a watched
      // ad and the server credits nothing; the app must claim nothing.
      final env = await adEnv(balance: 40);
      final report = await env.ads.watch(AdPlacementId.shop);

      expect(env.adsGateway.showCalls, 1);
      expect(report.kind, AdReportKind.awaitingServer);
      expect(report.sparks, 0, reason: 'never a number the phone made up');
      expect(env.shop.balance, 40, reason: 'the wallet did not move');
    });

    test('a credited ad reports the server\'s own figures', () async {
      final env = await adEnv(balance: 40);
      // The server's move, standing in for Google's callback arriving.
      env.api.adCreditsOnNextOffer = 10;
      final report = await env.ads.watch(AdPlacementId.shop);

      expect(report.kind, AdReportKind.credited);
      expect(report.sparks, 10);
      expect(report.balance, 50);
      expect(env.shop.balance, 50, reason: 'read back from the inventory');
    });

    test('the ad carries our player id and the placement', () async {
      // The join between the two systems: this player id goes into the ad's signed
      // `custom_data`, and Google's callback resolves it to a wallet with no
      // mapping table in between.
      final env = await adEnv();
      await env.ads.watch(AdPlacementId.gameOver);
      final shown = env.adsGateway.shown.single;
      expect(shown.playerId, (await env.identity.load())!.id);
      expect(shown.placement, AdPlacementId.gameOver);
    });

    test('closing the ad early is silent and pays nothing', () async {
      final env = await adEnv(balance: 40);
      env.adsGateway.showOutcome = AdShowOutcome.dismissed;
      final report = await env.ads.watch(AdPlacementId.shop);

      expect(report.kind, AdReportKind.dismissed);
      expect(report.silent, isTrue);
      expect(report.sparks, 0);
      expect(env.shop.balance, 40);
      expect(
        env.api.adsOfferCalls,
        1,
        reason: 'only the refresh that opened the screen; nothing to poll for',
      );
    });

    test('an ad that cannot be shown says so and charges nothing', () async {
      final env = await adEnv();
      env.adsGateway.showOutcome = AdShowOutcome.failed;
      final report = await env.ads.watch(AdPlacementId.shop);
      expect(report.kind, AdReportKind.unavailable);
      expect(report.sparks, 0);
    });

    test('nothing happens with no ad in hand', () async {
      final env = await adEnv(gateway: FakeAdsGateway(fills: false));
      final report = await env.ads.watch(AdPlacementId.shop);
      expect(report.kind, AdReportKind.unavailable);
      expect(env.adsGateway.showCalls, 0);
    });

    test('a server we cannot reach afterwards is "on their way"', () async {
      // Watched, and this phone could not ask. Nothing is lost — Google's callback
      // goes to our server and does not need the app — but nothing may be claimed.
      final env = await adEnv(balance: 40);
      env.api.adOfferFailure = const ApiException(
        ApiErrorKind.network,
        'offline',
      );
      final report = await env.ads.watch(AdPlacementId.shop);
      expect(report.kind, AdReportKind.awaitingServer);
      expect(report.sparks, 0);
      expect(env.shop.balance, 40);
    });

    test('a second tap while one ad is in flight does nothing', () async {
      final env = await adEnv();
      final first = env.ads.watch(AdPlacementId.shop);
      final second = await env.ads.watch(AdPlacementId.shop);
      await first;
      expect(second.kind, AdReportKind.unavailable);
      expect(env.adsGateway.showCalls, 1);
    });

    test('the allowance and the next ad are refreshed afterwards', () async {
      final env = await adEnv();
      env.api.adCreditsOnNextOffer = 10;
      await env.ads.watch(AdPlacementId.shop);
      // The fake server starts the cooldown when it credits, so the button is gone
      // and — correctly — no new ad was requested.
      expect(env.ads.offer.waitSeconds, greaterThan(0));
      expect(env.ads.canWatch, isFalse);
      expect(env.ads.offeredInShop, isFalse);
      expect(env.ads.offer.earnedToday, 10);
    });

    test('the poll stops as soon as the credit lands', () async {
      final env = await adEnv();
      env.api.adCreditsOnNextOffer = 10;
      final before = env.api.adsOfferCalls;
      await env.ads.watch(AdPlacementId.shop);
      // One poll that found it, plus the refresh afterwards. Not the full budget.
      expect(env.api.adsOfferCalls - before, lessThanOrEqualTo(2));
    });

    test('a watch with no identity does nothing', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore(failing: true),
        adsGateway: FakeAdsGateway(),
        adOffer: testAdOffer(),
      );
      env.api.createPlayerFailure = const ApiException(
        ApiErrorKind.network,
        'offline',
      );
      final report = await env.ads.watch(AdPlacementId.shop);
      expect(report.kind, AdReportKind.unavailable);
      expect(env.adsGateway.showCalls, 0);
    });
  });

  group('the amounts on screen', () {
    test('are all the server\'s, and none is held by the client', () async {
      // The client has no copy of an ad's worth, a daily cap or a cooldown: it
      // draws what it is told. A second opinion could only ever disagree.
      final env = await adEnv(
        offer: testAdOffer(
          sparks: 7,
          earnedToday: 21,
          dailyCap: 42,
          cooldownSeconds: 111,
        ),
      );
      expect(env.ads.offer.sparks, 7);
      expect(env.ads.offer.earnedToday, 21);
      expect(env.ads.offer.dailyCap, 42);
      expect(env.ads.offer.remaining, 21);
      expect(env.ads.offer.cooldownSeconds, 111);
    });

    test('AdOffer.none is what an unconfigured deployment looks like', () {
      expect(AdOffer.none.available, isFalse);
      expect(AdOffer.none.sparks, 0);
      expect(AdOffer.none.dailyCap, 0);
      expect(AdOffer.none.adTotal, 0);
    });

    test('a 404 ads_disabled is not an error worth a message', () async {
      final env = await createTestEnv(
        adsGateway: FakeAdsGateway(),
        adOffer: testAdOffer(),
      );
      env.api.adOfferFailure = const ApiException(
        ApiErrorKind.badResponse,
        'ads_disabled',
        statusCode: 404,
        errorCode: 'ads_disabled',
      );
      await env.ads.refresh();
      expect(env.ads.offer, same(AdOffer.none));
      expect(env.ads.offeredInShop, isFalse);
    });
  });

  group('the custom data', () {
    // The format the server reads (`AdCustomData` in `server/lib/src/ads.dart`).
    // The two halves cannot share code, so it is pinned literally on both sides.
    const playerId = '0123456789abcdef0123456789abcdef';

    test('is playerId:placement', () {
      expect(adCustomData(playerId, AdPlacementId.shop), '$playerId:shop');
      expect(
        adCustomData(playerId, AdPlacementId.gameOver),
        '$playerId:gameOver',
      );
    });

    test('there are exactly two placements', () {
      // A new value here is a new place an ad appears. There is none for a launch,
      // a duel or an interstitial, and adding one should take a deliberate change
      // on both sides rather than a flag.
      expect(AdPlacementId.values, <AdPlacementId>[
        AdPlacementId.shop,
        AdPlacementId.gameOver,
      ]);
    });
  });
}
