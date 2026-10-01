/// The ad between solo games: an interstitial after every third finished run
/// (SPEC §4.10).
///
/// This is the one ad in the app the player does not ask for, so it lives
/// under rules that are worth more than the impressions they cost:
///
/// * **every [gamesPerBreak]th finished solo game**, counted from the last ad of
///   any kind — a rewarded ad the player chose to watch is an ad break too;
/// * **never twice within [minGap]**, however short the games were;
/// * **never in a new player's first [graceGames] games** — the first evening
///   with the game is not the moment to find out it has ads;
/// * **never after a duel**: it would land between a rematch and its answer.
///   Only the solo screen calls this;
/// * **never for a player who holds the unlock** (SPEC §4.9). This is what the
///   unlock is *for*, so it is checked twice: by the shop's state and by the
///   server's last ad offer;
/// * **never without consent.** It rides on the same UMP answer as the rewarded
///   ad. Where consent is still open, the first break that falls due shows
///   Google's form instead of an ad, once.
///
/// And it is shown on the way **out** of the score screen — RETRY or HOME —
/// never over it: the result, the record and the board line are the player's to
/// read first. An ad that is not loaded by then is simply skipped; the player
/// never waits for one.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../app/ads_config.dart';
import 'ads_gateway.dart';
import 'storage.dart';

/// The platform half: loads and shows one interstitial. Behind an interface
/// because the SDK cannot run in a test.
abstract interface class InterstitialGateway {
  /// A configured unit on a platform AdMob serves.
  bool get available;

  /// An ad is in hand and can be shown at once.
  bool get loaded;

  /// Requests an ad; true when one is in hand afterwards. Must only be called
  /// with consent to request ads.
  Future<bool> load();

  /// Shows the ad in hand; true when it was shown and has been closed.
  Future<bool> show();

  Future<void> dispose();
}

/// [InterstitialGateway] over `google_mobile_ads`.
class GoogleInterstitialAds implements InterstitialGateway {
  GoogleInterstitialAds({String? adUnitId})
    : _adUnitId = adUnitId ?? AdsConfig.interstitialUnitId;

  final String? _adUnitId;
  InterstitialAd? _ad;
  bool _loading = false;
  bool _initialised = false;

  @override
  bool get available => _adUnitId != null;

  @override
  bool get loaded => _ad != null;

  @override
  Future<bool> load() async {
    final unitId = _adUnitId;
    if (unitId == null) return false;
    if (_ad != null) return true;
    if (_loading) return false;
    _loading = true;
    try {
      if (!_initialised) {
        await MobileAds.instance.initialize();
        _initialised = true;
      }
      final done = Completer<bool>();
      await InterstitialAd.load(
        adUnitId: unitId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            _ad = ad;
            if (!done.isCompleted) done.complete(true);
          },
          onAdFailedToLoad: (error) {
            // No fill is ordinary: there is no ad between these two games.
            debugPrint('interstitial did not load: ${error.message}');
            if (!done.isCompleted) done.complete(false);
          },
        ),
      );
      return await done.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => false,
      );
    } catch (e) {
      debugPrint('interstitial load failed: $e');
      return false;
    } finally {
      _loading = false;
    }
  }

  @override
  Future<bool> show() async {
    final ad = _ad;
    if (ad == null) return false;
    _ad = null;
    final closed = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback<InterstitialAd>(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!closed.isCompleted) closed.complete(true);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('interstitial failed to show: ${error.message}');
        ad.dispose();
        if (!closed.isCompleted) closed.complete(false);
      },
    );
    try {
      await ad.show();
      return await closed.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => true,
      );
    } catch (e) {
      debugPrint('interstitial show failed: $e');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _ad?.dispose();
    _ad = null;
  }
}

/// Decides when the ad between games falls due, preloads it, and shows it on
/// the way out of the score screen.
class InterstitialService {
  InterstitialService({
    required this.gateway,
    required this.consent,
    required this.storage,
    required this.isPremium,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// An ad break every this many finished solo games.
  static const int gamesPerBreak = 3;

  /// A new player's first games, which never end in an ad.
  static const int graceGames = 5;

  /// The shortest time between two ad breaks, however quick the games.
  static const Duration minGap = Duration(minutes: 3);

  final InterstitialGateway gateway;

  /// The consent half of the rewarded-ad layer: one UMP answer covers every ad
  /// this app requests.
  final AdsGateway consent;

  final Storage storage;

  /// Whether this player holds the one-time unlock, as far as anything on the
  /// device knows. Read at the moment of every decision, never cached.
  final bool Function() isPremium;

  final DateTime Function() _now;

  /// Whether the next way out of the score screen should show an ad.
  bool get due {
    if (!_countReached) return false;
    final last = storage.adBreakAt;
    return last == null || _now().difference(last) >= minGap;
  }

  /// Everything but the clock: enough runs since the last ad, past the grace,
  /// and somebody who may be shown one. The ad is preloaded from here, so it is
  /// in hand when [minGap] runs out between two quick games.
  bool get _countReached {
    if (!gateway.available || !consent.available || isPremium()) return false;
    if (storage.adBreakGames <= graceGames) return false;
    return storage.adBreakSince >= gamesPerBreak;
  }

  /// A solo game ended. Counts it and, when that makes a break due, preloads the
  /// ad so it is in hand by the time the player taps RETRY or HOME.
  Future<void> gameFinished() async {
    await storage.setAdBreakCounts(
      games: storage.adBreakGames + 1,
      since: storage.adBreakSince + 1,
    );
    if (!_countReached) return;
    if (consent.consent == AdConsentState.unknown) {
      await consent.refreshConsent();
    }
    if (consent.consent == AdConsentState.allowed) await gateway.load();
  }

  /// Any ad just closed — a rewarded one counts — so the count starts over.
  Future<void> adWatched() async {
    await storage.setAdBreakCounts(games: storage.adBreakGames, since: 0);
    await storage.setAdBreakAt(_now());
  }

  /// Called on the way out of the score screen. Shows the ad when a break is
  /// due and one is in hand; otherwise returns at once. Never waits for a load.
  Future<void> showIfDue() async {
    if (!due) return;
    if (consent.consent == AdConsentState.required) {
      // The first break that falls due where consent is still open asks for it
      // instead of showing an ad — once: Google does not show the form again
      // after it has been answered. Either way this break is spent.
      await consent.requestConsent();
      await adWatched();
      return;
    }
    if (!gateway.loaded) return;
    if (await gateway.show()) await adWatched();
  }

  Future<void> dispose() => gateway.dispose();
}
