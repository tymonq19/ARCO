/// Rewarded ads and the consent flow, behind one interface (SPEC §4.10).
///
/// Everything above this file — when a button appears, what it says, what happens
/// after the ad, when the consent form is asked for — is ordinary Dart that a test
/// can drive. Everything below it is `google_mobile_ads`, the Google Mobile Ads
/// SDK and Google's UMP SDK, none of which can run in a unit test and none of
/// which will serve an ad on a simulator that has no ad unit configured. That is
/// the whole reason the seam exists, and it is the same seam
/// `purchase_gateway.dart` and `native_sign_in.dart` draw.
///
/// **This layer never decides what an ad is worth, and it never credits
/// anything.** It reports what the SDK did — an ad is in hand, the player watched
/// it through, they closed it early — and the *Sparks* come from our server, on
/// Google's signed server-side verification callback (see
/// `server/lib/src/ads.dart`). A gateway that returned an amount would be a phone
/// deciding how much it had earned, which is the one thing a rewarded ad must
/// never allow.
///
/// What this layer *does* own is the join between the ad and the wallet: the
/// `custom_data` it sets on the ad before showing it is `<playerId>:<placement>`,
/// which travels inside the content Google signs and is what the callback resolves
/// to a wallet.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../app/ads_config.dart';

/// Where an ad is offered (SPEC §4.10). Mirrors the server's `AdPlacement`, and is
/// pinned against it by `test/services/ad_pin_test.dart`.
///
/// Exactly two, and the list is short on purpose: an ad appears only where it
/// answers something the player already wants. There is no value for a launch, a
/// duel or an interstitial, and adding one would mean adding it here, on the
/// server, and to the argument for it.
enum AdPlacementId {
  /// The shop's earning panel: a way to earn Sparks, beside the other way.
  shop,

  /// The solo game-over overlay: an optional extra on the run just finished.
  gameOver,
}

/// How a consent request came out.
///
/// Every one of these is an ordinary thing that happens to a real player, which is
/// why each has a name rather than sharing a generic failure: "you are not in a
/// region that requires this", "you chose", "you declined" and "we could not ask"
/// are four different things, and only one of them means the game should look any
/// different.
enum AdConsentOutcome {
  /// No consent is required here (outside the EEA, the UK and the regulated US
  /// states). Ads may be requested.
  notRequired,

  /// The player answered the form, and Google says ads may now be requested. That
  /// includes a player who consented to *non-personalised* ads only — which is a
  /// perfectly good ad, so the button works.
  obtained,

  /// The player answered and ads may **not** be requested. The ad button is then
  /// absent, permanently and silently, and the rest of the game is untouched.
  refused,

  /// The form could not be reached or shown. Treated exactly like [refused] for
  /// what the player sees — no button — because the alternative is requesting an
  /// ad we have no permission for.
  unavailable,
}

/// What showing an ad came to.
enum AdShowOutcome {
  /// The player watched it through and the SDK reports the reward earned. **This
  /// is not yet Sparks**: Google's callback tells our server, and our server
  /// credits. The client's next move is to ask the server, never to add anything.
  rewarded,

  /// Closed before the reward. Silence is the correct response — a player who
  /// changed their mind does not need a message about it.
  dismissed,

  /// The ad could not be shown, or there was none in hand. Nothing happened.
  failed,
}

/// Whether ads may be requested, as far as consent is concerned.
enum AdConsentState {
  /// Nothing has been asked yet.
  unknown,

  /// A form is required and has not been answered. This is the state in which the
  /// shop offers to ask — and the only state in which any form is ever shown.
  required,

  /// Ads may be requested: either consent was given or none is needed here.
  allowed,

  /// Ads may not be requested. No button, anywhere.
  denied,
}

/// The ads layer, as the rest of the app needs it.
abstract interface class AdsGateway {
  /// Whether this build and this device could show an ad at all: a configured ad
  /// unit and a platform AdMob serves. False on the web build, on desktop, and in
  /// any build a human has not configured or switched to test ads.
  bool get available;

  /// Whether an ad is in hand **right now**.
  ///
  /// The button is drawn only when this is true, which is the whole reason it is
  /// preloaded: a rewarded ad that has to be fetched when tapped is a button that
  /// spins and sometimes fails, and that is worse than no button.
  bool get loaded;

  /// Whether ads may be requested at all.
  AdConsentState get consent;

  /// Fires whenever [loaded] or [consent] changes, so a screen can rebuild.
  Stream<void> get changes;

  /// Asks Google whether a consent form is required here, **without showing
  /// anything**. Network only, and safe to call whenever a screen that might offer
  /// an ad opens.
  Future<AdConsentState> refreshConsent();

  /// Shows the consent form, if one is required.
  ///
  /// Called at the moment the player asks to earn Sparks from an ad — never on
  /// launch, and never as a condition of playing.
  Future<AdConsentOutcome> requestConsent();

  /// Loads one rewarded ad, if consent allows and none is in hand. Returns
  /// whether there is one afterwards.
  Future<bool> load();

  /// Shows the loaded ad, attributing its reward to [playerId] at [placement].
  ///
  /// The attribution is the point: it goes into AdMob's server-side verification
  /// options, arrives inside the signed content of Google's callback, and is what
  /// our server resolves to a wallet.
  Future<AdShowOutcome> show({
    required String playerId,
    required AdPlacementId placement,
  });

  Future<void> dispose();
}

/// The `custom_data` an ad carries (SPEC §4.10): `<playerId>:<placement>`.
///
/// The format is the server's (`AdCustomData` in `server/lib/src/ads.dart`) and
/// the two halves cannot share code, so it is pinned literally on both sides by a
/// test. It is deliberately the plainest thing that works — no JSON to mis-escape
/// through an ad SDK, Google's ad servers and a URL-encoded query parameter.
String adCustomData(String playerId, AdPlacementId placement) =>
    '$playerId:${placement.name}';

/// The real ads layer, through `google_mobile_ads`.
///
/// Initialised lazily: nothing here touches the SDK until a screen that could
/// offer an ad actually asks, so a player who never opens the shop never starts
/// the Mobile Ads SDK, and a build with no ad unit never calls in at all.
class GoogleRewardedAds implements AdsGateway {
  GoogleRewardedAds({String? adUnitId, this.debugGeographyEea = false})
    : _adUnitId = adUnitId ?? AdsConfig.rewardedUnitId;

  /// `ConsentDebugSettings.debugGeography = debugGeographyEea`, which makes a
  /// **test device** look like it is in the EEA so the consent form can actually
  /// be walked through from anywhere. It needs the device's own hashed id in
  /// AdMob's test-device list to have any effect at all, so it is safe, but it is
  /// off by default and SETUP.md says what to do with it.
  final bool debugGeographyEea;

  final String? _adUnitId;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  bool _initialised = false;
  bool _loading = false;
  RewardedAd? _ad;
  AdConsentState _consent = AdConsentState.unknown;

  @override
  bool get available => _adUnitId != null;

  @override
  bool get loaded => _ad != null;

  @override
  AdConsentState get consent => _consent;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<AdConsentState> refreshConsent() async {
    if (!available) return _set(AdConsentState.denied);
    final done = Completer<void>();
    try {
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(
          consentDebugSettings: debugGeographyEea
              ? ConsentDebugSettings(
                  debugGeography: DebugGeography.debugGeographyEea,
                )
              : null,
        ),
        done.complete,
        (FormError error) {
          debugPrint('UMP consent update failed: ${error.message}');
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      // No network, no plugin, a platform that has no UMP: all the same answer.
      debugPrint('UMP consent update unavailable: $e');
      return _set(AdConsentState.denied);
    }
    return _set(await _readConsent());
  }

  @override
  Future<AdConsentOutcome> requestConsent() async {
    if (!available) return AdConsentOutcome.unavailable;
    if (_consent == AdConsentState.unknown) await refreshConsent();
    if (_consent == AdConsentState.allowed) {
      // Either the player has already chosen, or no choice is required here.
      return AdConsentOutcome.notRequired;
    }
    try {
      final dismissed = Completer<FormError?>();
      // `loadAndShowConsentFormIfRequired` is the one call Google documents for
      // this: it is a no-op when no form is required, so there is no state for
      // this app to keep about whether it has asked.
      await ConsentForm.loadAndShowConsentFormIfRequired(dismissed.complete);
      final error = await dismissed.future.timeout(const Duration(minutes: 5));
      if (error != null) {
        debugPrint('UMP consent form failed: ${error.message}');
        _set(AdConsentState.denied);
        return AdConsentOutcome.unavailable;
      }
    } catch (e) {
      debugPrint('UMP consent form unavailable: $e');
      _set(AdConsentState.denied);
      return AdConsentOutcome.unavailable;
    }
    final state = _set(await _readConsent());
    // Google's own answer to "may I request an ad", whatever the player chose and
    // whatever region they are in. A player who allowed non-personalised ads only
    // lands here as `allowed`, which is right: that is a perfectly good ad.
    return state == AdConsentState.allowed
        ? AdConsentOutcome.obtained
        : AdConsentOutcome.refused;
  }

  @override
  Future<bool> load() async {
    final unitId = _adUnitId;
    if (unitId == null) return false;
    if (_ad != null) return true;
    if (_loading) return false;
    // Never request an ad without permission to. This is the line that makes a
    // refused consent a game with no ads rather than a compliance problem.
    if (_consent != AdConsentState.allowed) return false;
    _loading = true;
    try {
      if (!_initialised) {
        await MobileAds.instance.initialize();
        _initialised = true;
      }
      final done = Completer<bool>();
      await RewardedAd.load(
        adUnitId: unitId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            _ad = ad;
            if (!done.isCompleted) done.complete(true);
            _notify();
          },
          onAdFailedToLoad: (error) {
            // No fill is the ordinary case, not an error: there simply is no ad
            // for this player right now, and the button stays absent.
            debugPrint('rewarded ad did not load: ${error.message}');
            if (!done.isCompleted) done.complete(false);
          },
        ),
      );
      return await done.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => false,
      );
    } catch (e) {
      debugPrint('rewarded ad load failed: $e');
      return false;
    } finally {
      _loading = false;
    }
  }

  @override
  Future<AdShowOutcome> show({
    required String playerId,
    required AdPlacementId placement,
  }) async {
    final ad = _ad;
    if (ad == null) return AdShowOutcome.failed;
    _ad = null;
    _notify();
    var rewarded = false;
    final closed = Completer<void>();
    try {
      // The attribution, set immediately before showing: it is what ends up in the
      // signed content of Google's callback, and therefore what decides whose
      // wallet this ad pays.
      await ad.setServerSideOptions(
        ServerSideVerificationOptions(
          userId: playerId,
          customData: adCustomData(playerId, placement),
        ),
      );
      ad.fullScreenContentCallback = FullScreenContentCallback<RewardedAd>(
        onAdDismissedFullScreenContent: (ad) {
          ad.dispose();
          if (!closed.isCompleted) closed.complete();
        },
        onAdFailedToShowFullScreenContent: (ad, error) {
          debugPrint('rewarded ad failed to show: ${error.message}');
          ad.dispose();
          if (!closed.isCompleted) closed.complete();
        },
      );
      await ad.show(
        onUserEarnedReward: (_, reward) {
          // The SDK's `reward.amount` is deliberately not read. What an ad pays is
          // the server's table, credited on Google's signed callback; this flag
          // says only "the player watched it through".
          rewarded = true;
        },
      );
      await closed.future.timeout(const Duration(minutes: 10));
    } catch (e) {
      debugPrint('rewarded ad show failed: $e');
      return rewarded ? AdShowOutcome.rewarded : AdShowOutcome.failed;
    }
    return rewarded ? AdShowOutcome.rewarded : AdShowOutcome.dismissed;
  }

  @override
  Future<void> dispose() async {
    _ad?.dispose();
    _ad = null;
    await _changes.close();
  }

  /// Google's own answer to "may I request an ad", which is the only question this
  /// app needs about consent.
  ///
  /// `canRequestAds()` folds together the region, the form, the player's choice and
  /// whether they consented to personalised or only non-personalised ads — so this
  /// app never interprets a consent status itself, which is exactly the kind of
  /// thing an app should not be interpreting.
  Future<AdConsentState> _readConsent() async {
    try {
      if (await ConsentInformation.instance.canRequestAds()) {
        return AdConsentState.allowed;
      }
      final status = await ConsentInformation.instance.getConsentStatus();
      return status == ConsentStatus.required
          ? AdConsentState.required
          : AdConsentState.denied;
    } catch (e) {
      debugPrint('UMP consent status unavailable: $e');
      return AdConsentState.denied;
    }
  }

  AdConsentState _set(AdConsentState state) {
    if (_consent == state) return state;
    _consent = state;
    _notify();
    return state;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
