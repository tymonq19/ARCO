/// Compile-time RevenueCat SDK keys (SPEC §4.9).
///
/// These are the **public** keys, one per platform, and they are not secrets: a
/// public SDK key is baked into every build of every app that uses RevenueCat, it
/// can only be used to make purchases *for* this app, and our server never
/// believes anything the SDK says with it. What is secret lives on the server —
/// the webhook secret and the RevenueCat API key, both environment variables and
/// neither present in this repository or in any build (see SETUP.md).
///
/// They live in `--dart-define`s rather than in source for the same reason the
/// sign-in client ids do (`account_config.dart`): one checkout builds the dev and
/// the store flavour, and a fork that has no RevenueCat project simply leaves
/// them empty and gets no Spark packs — no dead button, no crash, and a game that
/// is entirely playable, because every Spark a pack sells is earnable by playing.
library;

import 'package:flutter/foundation.dart';

abstract final class PurchaseConfig {
  /// The iOS public SDK key (`appl_…`), from
  /// `--dart-define=REVENUECAT_IOS_KEY=…`.
  static const String iosKey = String.fromEnvironment('REVENUECAT_IOS_KEY');

  /// The Android public SDK key (`goog_…`), from
  /// `--dart-define=REVENUECAT_ANDROID_KEY=…`.
  static const String androidKey = String.fromEnvironment(
    'REVENUECAT_ANDROID_KEY',
  );

  /// The key for the platform this build is running on, or null where there is
  /// none — which is every platform RevenueCat has no store on (the web build,
  /// desktop) and every build a human has not yet configured.
  static String? get keyForPlatform {
    if (kIsWeb) return null;
    final key = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => iosKey,
      TargetPlatform.android => androidKey,
      _ => '',
    };
    return key.isEmpty ? null : key;
  }

  /// Whether this build can talk to a store at all.
  ///
  /// Checked before anything is shown, so a build with no keys never draws a
  /// price list it cannot fill — the section is simply absent.
  static bool get configured => keyForPlatform != null;
}
