/// Rewarded ads, pinned against the server and against the promises made about
/// them (SPEC §4.10).
///
/// The client holds almost nothing about ads by itself: what one pays, the daily
/// cap and the cooldown all arrive from `GET /api/ads/offer`. What it *does* hold
/// is the shape of the `custom_data` that joins an ad to a wallet, the names of the
/// two placements, and the test fixture that pretends to be the server — and every
/// one of those would rot silently if the server changed underneath it.
///
/// So this reads the server's own source and checks the things that cannot be
/// checked any other way, plus three promises about the app that are easiest to
/// keep by asserting them:
///
/// * **no interstitial, anywhere.** Checked by reading every file in `lib/`: the
///   only ad class this app may name is the rewarded one.
/// * **the real ad unit ids are never hardcoded.** The only `ca-app-pub-` strings
///   in the repository are Google's published *test* ids.
/// * **nothing outside the shop and the game-over overlay mentions watching an
///   ad**, which is the same rule the packs live under.
library;

import 'dart:io';

import 'package:arco/app/ads_config.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/services/ads_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  group('the test ad units', () {
    test('are Google\'s published ones, verbatim', () {
      // Public constants of Google's, identical in every app that uses them, and
      // they always fill. Pinned literally, because "test ads work without an
      // AdMob account" is only true while these are exactly right — and because a
      // real id pasted over one of them would send a stranger's impressions
      // somewhere.
      expect(
        AdsConfig.testIosRewardedUnit,
        'ca-app-pub-3940256099942544/1712485313',
      );
      expect(
        AdsConfig.testAndroidRewardedUnit,
        'ca-app-pub-3940256099942544/5224354917',
      );
      expect(AdsConfig.testIosAppId, 'ca-app-pub-3940256099942544~1458002511');
      expect(
        AdsConfig.testAndroidAppId,
        'ca-app-pub-3940256099942544~3347511713',
      );
      // Every one of them is on Google's own demo publisher account, which is what
      // makes them safe to hardcode at all.
      for (final id in <String>[
        AdsConfig.testIosRewardedUnit,
        AdsConfig.testAndroidRewardedUnit,
        AdsConfig.testIosAppId,
        AdsConfig.testAndroidAppId,
      ]) {
        expect(id, startsWith('ca-app-pub-3940256099942544'));
      }
    });

    test('a build with nothing configured has no ad unit at all', () {
      // This test process has no `--dart-define`s, which is exactly the state of a
      // fork, a CI build and a checkout nobody has configured. It gets no ads.
      expect(AdsConfig.iosRewardedUnit, isEmpty);
      expect(AdsConfig.androidRewardedUnit, isEmpty);
      expect(AdsConfig.testAds, isFalse);
      expect(
        AdsConfig.configured,
        isFalse,
        reason: 'no unit id means no ad button, not a broken one',
      );
      expect(AdsConfig.rewardedUnitId, isNull);
    });

    test('the real ids are never hardcoded anywhere in lib/', () {
      // The only AdMob identifiers in the source are Google's test ones, and they
      // live in exactly one file.
      final offenders = <String>[];
      for (final file in _dartFiles(_dir('lib'))) {
        for (final match in RegExp(
          r'ca-app-pub-[0-9]+',
        ).allMatches(file.readAsStringSync())) {
          if (match.group(0) == 'ca-app-pub-3940256099942544') continue;
          offenders.add('${file.path}: ${match.group(0)}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'a real AdMob id belongs in a --dart-define, not in source',
      );
    });

    test('the native manifests hold the test app ids, not an account', () {
      // The Mobile Ads SDK reads the app id from the platform manifest, so those
      // two files are the one place a real account id could be committed by
      // accident. They are checked in with Google's test ids and SETUP.md says to
      // replace them at deploy time.
      final plist = File(
        '${_dir('ios').path}/Runner/Info.plist',
      ).readAsStringSync();
      expect(plist, contains('GADApplicationIdentifier'));
      expect(plist, contains(AdsConfig.testIosAppId));
      final manifest = File(
        '${_dir('android').path}/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('com.google.android.gms.ads.APPLICATION_ID'));
      expect(manifest, contains(AdsConfig.testAndroidAppId));
    });
  });

  group('the ad formats', () {
    test('only rewarded ads are named anywhere in lib/', () {
      // The rule of SPEC §4.10, kept by reading the source rather than by
      // remembering: never an interstitial, never an app-open ad, never a banner.
      // Those are ads shown *at* somebody; a rewarded ad is one they asked for.
      const forbidden = <String>[
        'InterstitialAd',
        'AppOpenAd',
        'BannerAd',
        'AdWidget',
        'NativeAd',
        'RewardedInterstitialAd',
      ];
      final offenders = <String>[];
      for (final file in _dartFiles(_dir('lib'))) {
        final source = file.readAsStringSync();
        for (final name in forbidden) {
          if (source.contains(name)) offenders.add('${file.path}: $name');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'an ad the player did not ask for is not a format this app has; '
            'adding one needs a new argument, not a new import',
      );
    });

    test(
      'there are exactly two placements, and neither is a launch or a duel',
      () {
        expect(AdPlacementId.values, <AdPlacementId>[
          AdPlacementId.shop,
          AdPlacementId.gameOver,
        ]);
        expect(
          AdPlacementId.values.map((p) => p.name),
          _serverPlacements(),
          reason: 'the placement names cross the wire in custom_data',
        );
      },
    );
  });

  group('against the server', () {
    test('the custom data format is the one the server parses', () {
      // `AdCustomData.encode` on the server is `'$playerId$separator$placement'`
      // with `separator = ':'`. Read out of the server's source, because the two
      // halves cannot share code and a drift means a reward with nowhere to land.
      expect(_serverCustomDataSeparator(), ':');
      const playerId = '0123456789abcdef0123456789abcdef';
      expect(adCustomData(playerId, AdPlacementId.shop), '$playerId:shop');
      expect(
        adCustomData(playerId, AdPlacementId.gameOver),
        '$playerId:gameOver',
      );
    });

    test('the test fixture carries the server\'s real numbers', () {
      // `testAdOffer()` is what every widget test believes the server said. If the
      // economy moves on the server and not here, those tests keep passing while
      // testing a deployment that does not exist.
      final rate = _serverAdRate();
      final offer = testAdOffer();
      expect(offer.sparks, rate.sparksPerAd);
      expect(offer.dailyCap, rate.dailyCap);
      expect(offer.cooldownSeconds, rate.cooldownMinutes * 60);
    });

    test('the ad allowance is smaller than the play one', () {
      // The product decision, asserted from the client side too: an evening of ads
      // must be worth less than an evening of play, or playing is the slow route.
      final rate = _serverAdRate();
      expect(rate.dailyCap, lessThan(rate.playDailyCap));
      expect(rate.dailyCap * 3, lessThanOrEqualTo(rate.playDailyCap));
      expect(rate.dailyCap % rate.sparksPerAd, 0);
    });
  });

  group('what the app is allowed to say', () {
    test('no urgency and no "double your sparks" anywhere', () {
      // An ad is half a minute the player gives us. The honest way to ask is to
      // say what it pays and stop; checked against the strings, because this is a
      // rule about what the app may say.
      for (final table in [Strings.en, Strings.pl]) {
        for (final key in table.keys.where((k) => k.startsWith('ads.'))) {
          final value = table[key]!.toLowerCase();
          for (final nag in const [
            'double',
            'free sparks',
            'hurry',
            'limited',
            'only ',
            'don\'t miss',
            'darmowe iskry',
            'podwój',
            'pośpiesz',
            'tylko teraz',
            'nie przegap',
          ]) {
            expect(value, isNot(contains(nag)), reason: '$key nags: "$nag"');
          }
        }
      }
    });

    test('every ads string exists in both languages', () {
      final en = Strings.en.keys.where((k) => k.startsWith('ads.')).toSet();
      final pl = Strings.pl.keys.where((k) => k.startsWith('ads.')).toSet();
      expect(en, isNotEmpty);
      expect(en, pl);
      for (final key in en) {
        expect(Strings.pl[key], isNotNull, reason: key);
        expect(const Strings('pl').t(key), isNot(key));
      }
    });

    test('nothing outside the ads strings points at watching one', () {
      // The same rule the Spark packs live under: every string about ads lives
      // under `ads.`, so the title screen, Settings and the leaderboard cannot be
      // pointing at one.
      for (final table in [Strings.en, Strings.pl]) {
        for (final entry in table.entries) {
          if (entry.key.startsWith('ads.')) continue;
          final value = entry.value.toLowerCase();
          for (final word in const [
            'watch an ad',
            'watch a video',
            'obejrzyj reklamę',
            'obejrzyj wideo',
          ]) {
            expect(value, isNot(contains(word)), reason: entry.key);
          }
        }
      }
    });
  });
}

/// The server's ad economy, read out of `server/lib/src/tokens.dart`.
_AdRate _serverAdRate() {
  final source = _serverFile('lib/src/tokens.dart').readAsStringSync();
  int number(String name, {String scope = 'AdRate'}) {
    final cut = source.indexOf('abstract final class $scope');
    final body = cut < 0 ? source : source.substring(cut);
    final match = RegExp(
      'static const int $name = ([0-9_]+);',
    ).firstMatch(body);
    if (match == null) fail('no $scope.$name in the server tokens.dart');
    return int.parse(match.group(1)!.replaceAll('_', ''));
  }

  final cooldown = RegExp(
    r'static const Duration cooldown = Duration\(minutes: (\d+)\);',
  ).firstMatch(source);
  if (cooldown == null) fail('no AdRate.cooldown in the server tokens.dart');
  return _AdRate(
    sparksPerAd: number('sparksPerAd'),
    dailyCap: number('dailyCap'),
    cooldownMinutes: int.parse(cooldown.group(1)!),
    playDailyCap: number('dailyCap', scope: 'TokenRate'),
  );
}

class _AdRate {
  const _AdRate({
    required this.sparksPerAd,
    required this.dailyCap,
    required this.cooldownMinutes,
    required this.playDailyCap,
  });

  final int sparksPerAd;
  final int dailyCap;
  final int cooldownMinutes;
  final int playDailyCap;
}

/// The placement names the server's `AdPlacement` enum declares, in order.
List<String> _serverPlacements() {
  final source = _serverFile('lib/src/ads.dart').readAsStringSync();
  final cut = source.indexOf('enum AdPlacement {');
  if (cut < 0) fail('no AdPlacement enum in the server ads.dart');
  final body = source.substring(cut, source.indexOf('}', cut));
  // The values are the identifiers that end in `,` or `;` at the start of a line,
  // ignoring the doc comments between them.
  return <String>[
    for (final line in body.split('\n'))
      if (RegExp(r'^  ([a-z][A-Za-z]*)[,;]\s*$').firstMatch(line.trimRight())
          case final m?)
        m.group(1)!,
  ];
}

String _serverCustomDataSeparator() {
  final source = _serverFile('lib/src/ads.dart').readAsStringSync();
  final match = RegExp(
    "static const String separator = '(.*)';",
  ).firstMatch(source);
  if (match == null) fail('no AdCustomData.separator in the server ads.dart');
  return match.group(1)!;
}

Iterable<File> _dartFiles(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

File _serverFile(String relative) => File('${_dir('server').path}/$relative');

/// [name] at the repository root, found by walking up from wherever the test
/// runner started: the packages live in one repository, so it is always there.
Directory _dir(String name) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${dir.path}/$name');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('$name/ not found above ${Directory.current.path}');
}
