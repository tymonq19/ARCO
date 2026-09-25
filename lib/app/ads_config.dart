/// Build-time AdMob identifiers (SPEC §4.10).
///
/// An AdMob ad unit id is not a secret — it ships inside every copy of every app
/// that uses it — but it *is* an account identifier, and a real one hardcoded in a
/// repository is a real one that a fork, a test run or a CI build would send
/// impressions to. So the real ids live in `--dart-define`s, exactly as the
/// RevenueCat SDK keys do (`purchase_config.dart`) and for the same reason: one
/// checkout builds the dev and the store flavour, and a checkout that has been
/// given nothing gets no ads at all.
///
/// **A build with nothing configured shows no ad button.** Not a disabled one, not
/// an error — nothing, because every Spark an ad pays is earnable by playing and
/// there is no hole to apologise for. That is also what the web build gets, and
/// every desktop platform, since AdMob has no ads for either.
///
/// **`--dart-define=ADMOB_TEST_ADS=on`** switches to Google's *published test ad
/// units*, which serve a real rewarded ad to anybody without an AdMob account.
/// That is what makes the whole loop — load, show, earn, Google's signed callback,
/// our server's credit — walkable on a simulator before a human has signed up for
/// anything. It is a build-time switch rather than a runtime setting so that a
/// release build cannot be talked into test ads, and so a test id can never be
/// left serving in a shipped build by a stale preference.
library;

import 'package:flutter/foundation.dart';

abstract final class AdsConfig {
  /// The real iOS rewarded unit, from
  /// `--dart-define=ADMOB_IOS_REWARDED_UNIT=ca-app-pub-…/…`.
  static const String iosRewardedUnit = String.fromEnvironment(
    'ADMOB_IOS_REWARDED_UNIT',
  );

  /// The real Android rewarded unit, from
  /// `--dart-define=ADMOB_ANDROID_REWARDED_UNIT=ca-app-pub-…/…`.
  static const String androidRewardedUnit = String.fromEnvironment(
    'ADMOB_ANDROID_REWARDED_UNIT',
  );

  /// `--dart-define=ADMOB_TEST_ADS=on` (or `true`).
  ///
  /// Accepts both spellings because the server's switches are `on`/`off` and
  /// Dart's own `bool.fromEnvironment` wants `true`/`false`, and a human who
  /// types the wrong one of those should not be debugging a missing button.
  static const String _testAds = String.fromEnvironment('ADMOB_TEST_ADS');

  static bool get testAds {
    final value = _testAds.toLowerCase();
    return value == 'on' || value == 'true' || value == '1';
  }

  /// Google's **published** test rewarded ad units, documented at
  /// <https://developers.google.com/admob/ios/test-ads> and
  /// <https://developers.google.com/admob/android/test-ads>.
  ///
  /// These are public constants of Google's, identical in every app that uses
  /// them, and they always fill. They are hardcoded here on purpose: that is what
  /// "test ads work without an AdMob account" means, and pinning them in a test
  /// (`test/services/ad_pin_test.dart`) is what stops a real id being pasted over
  /// one of them by accident.
  static const String testIosRewardedUnit =
      'ca-app-pub-3940256099942544/1712485313';
  static const String testAndroidRewardedUnit =
      'ca-app-pub-3940256099942544/5224354917';

  /// Google's published test **application** ids, for the value the native side
  /// needs (`GADApplicationIdentifier` in `Info.plist`,
  /// `com.google.android.gms.ads.APPLICATION_ID` in the manifest).
  ///
  /// Not read by any Dart code — the SDK reads them from the platform manifests —
  /// but stated here so that the checked-in manifests and SETUP.md have one place
  /// to agree with, and so a test can assert the manifests still hold the *test*
  /// ids rather than somebody's real account.
  static const String testIosAppId = 'ca-app-pub-3940256099942544~1458002511';
  static const String testAndroidAppId =
      'ca-app-pub-3940256099942544~3347511713';

  /// The rewarded ad unit this build should ask for, or null when there is none.
  ///
  /// Null on the web and on desktop (AdMob has no ads there), and null in any
  /// build a human has neither configured nor switched to test ads.
  static String? get rewardedUnitId {
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        if (testAds) return testIosRewardedUnit;
        return iosRewardedUnit.isEmpty ? null : iosRewardedUnit;
      case TargetPlatform.android:
        if (testAds) return testAndroidRewardedUnit;
        return androidRewardedUnit.isEmpty ? null : androidRewardedUnit;
      default:
        return null;
    }
  }

  /// Whether this build can ask for an ad at all.
  ///
  /// Checked before anything is shown, so a build with no unit id never draws a
  /// button it cannot fill.
  static bool get configured => rewardedUnitId != null;
}
