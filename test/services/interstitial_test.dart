import 'package:arco/services/ads_gateway.dart';
import 'package:arco/services/interstitial_ads.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// The ad between solo games (SPEC §4.10): every third run, never twice within
/// three minutes, never in a new player's first games, never for a player with
/// the unlock, never without consent — and shown on the way out, never waited
/// for.
void main() {
  late DateTime clock;

  Future<TestEnv> envWith({
    bool premium = false,
    AdConsentState consent = AdConsentState.allowed,
    bool fills = true,
    int pastGames = InterstitialService.graceGames,
  }) async {
    clock = DateTime(2026, 10, 1, 12);
    final env = await createTestEnv(
      premium: premium,
      now: () => clock,
      adsGateway: FakeAdsGateway(consentState: consent),
      interstitialGateway: FakeInterstitialGateway(fills: fills),
    );
    await env.storage.setAdBreakCounts(games: pastGames, since: 0);
    return env;
  }

  /// Finishes [n] runs and leaves the score screen after each.
  Future<int> play(TestEnv env, int n) async {
    for (var i = 0; i < n; i++) {
      await env.interstitials.gameFinished();
      await env.interstitials.showIfDue();
      clock = clock.add(const Duration(minutes: 2));
    }
    return env.interstitialGateway.showCalls;
  }

  test('one ad every third run', () async {
    final env = await envWith();
    expect(await play(env, 2), 0);
    expect(await play(env, 1), 1, reason: 'the third run');
    expect(await play(env, 2), 1);
    expect(await play(env, 1), 2, reason: 'the sixth run');
  });

  test('a new player plays their first games without one', () async {
    final env = await envWith(pastGames: 0);
    expect(await play(env, InterstitialService.graceGames), 0);
    // The grace is over and three runs have gone by since the last ad (none).
    expect(await play(env, 1), 1);
  });

  test('never twice within three minutes, however short the runs', () async {
    final env = await envWith();
    await play(env, 2);
    await env.interstitials.gameFinished();
    await env.interstitials.showIfDue();
    expect(env.interstitialGateway.showCalls, 1);
    // Three runs of twenty seconds each: due by count, not by time.
    for (var i = 0; i < 3; i++) {
      clock = clock.add(const Duration(seconds: 20));
      await env.interstitials.gameFinished();
      await env.interstitials.showIfDue();
    }
    expect(env.interstitialGateway.showCalls, 1);
    clock = clock.add(const Duration(minutes: 2));
    await env.interstitials.showIfDue();
    expect(env.interstitialGateway.showCalls, 2);
  });

  test('a player with the unlock never sees one', () async {
    final env = await envWith(premium: true);
    expect(await play(env, 12), 0);
    expect(env.interstitialGateway.loadCalls, 0);
  });

  test('a rewarded ad the player watched counts as the break', () async {
    final env = await envWith();
    await play(env, 2);
    await env.interstitials.adWatched();
    expect(await play(env, 1), 0, reason: 'the count started over');
    expect(await play(env, 2), 1);
  });

  test(
    'no consent asked yet: the break asks once instead of showing',
    () async {
      final env = await envWith(consent: AdConsentState.required);
      expect(await play(env, 3), 0);
      expect(env.adsGateway.consentRequestCalls, 1);
      // Answered (the fake grants it), so the next break is a real ad.
      expect(await play(env, 3), 1);
      expect(env.adsGateway.consentRequestCalls, 1);
    },
  );

  test('no ad loaded means no wait and no ad', () async {
    final env = await envWith(fills: false);
    expect(await play(env, 6), 0);
  });

  test('a build with no interstitial unit never asks', () async {
    final env = await createTestEnv(adsGateway: FakeAdsGateway());
    for (var i = 0; i < 12; i++) {
      await env.interstitials.gameFinished();
      await env.interstitials.showIfDue();
    }
    expect(env.interstitialGateway.loadCalls, 0);
  });
}
