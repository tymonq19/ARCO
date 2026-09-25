/// The token economy (SPEC §4.8): how a verified run turns into tokens, and the
/// two bounds that keep that from being farmable.
///
/// Pure arithmetic and constants, no storage and no I/O, so the rule can be
/// asserted in a unit test and read in one sitting.
///
/// The one rule that must never bend: tokens are computed from the score **this
/// server computed** by re-simulating the replay (SPEC §4), never from a number
/// a client sent. Nothing in this file takes a token amount as input; the only
/// input is a verified score.
library;

/// How a verified solo score becomes tokens.
///
/// The numbers come from what solo scores actually look like. Measured against
/// the real simulation: an idle game scores under 20; a player who genuinely
/// plays a minute or two scores 400–3 000; a player good enough to keep the
/// rally alive indefinitely runs into `ReplayVerifier.maxTicks` (one hour) at
/// roughly 1 000 000. A rate that is linear all the way up would therefore pay
/// a strong player 10 000 times what a beginner gets, so the per-run cap
/// matters more than the rate does.
///
/// * [scorePerToken] = 100 — a token per 100 points. A first real run (a few
///   hundred points) pays 3–6 tokens; a good two-minute run pays 20–30. Small
///   enough numbers that the shop is a goal, big enough that a run is never
///   worth nothing.
/// * [maxTokensPerRun] = 50, reached at 5 000 points (about four minutes of
///   good play). Above that a run pays no more, which flattens the whole top
///   end of the distribution: the hour-long perfect run that scores a million
///   is worth exactly what a strong four-minute run is worth. A bot therefore
///   buys its owner nothing a good player cannot have.
/// * [dailyCap] = 200 per player per UTC day — four capped runs, or a dozen
///   ordinary ones. An evening of real play reaches it; nothing reaches it
///   faster than that, no matter how the runs are produced.
///
/// What that means for the shop: the paid items cost 80…250 and 1 160 tokens
/// buys every one of them, so the first unlock lands on the first evening and
/// the full set takes about a week of committed play. Those two facts are the
/// whole design — a shop you can clear on day one has nothing left to offer,
/// and one you can never dent is decoration.
abstract final class TokenRate {
  /// Verified score points per token.
  static const int scorePerToken = 100;

  /// Most tokens one run can ever pay, whatever it scored.
  static const int maxTokensPerRun = 50;

  /// Score at which [maxTokensPerRun] is reached (5 000).
  static const int scoreAtRunCap = maxTokensPerRun * scorePerToken;

  /// Most tokens one player can earn from play in a single UTC day.
  static const int dailyCap = 200;

  /// Tokens a run that the server verified at [score] earns, before the daily
  /// cap is applied.
  ///
  /// Truncated, not rounded: a run under [scorePerToken] points earns nothing.
  /// That is deliberate — a floor of one token per submission would make dying
  /// on purpose the fastest way to earn, and a player who is trying crosses 100
  /// points inside the first minute (survival alone pays a point a second, a
  /// paddle hit pays ten).
  static int forScore(int score) {
    if (score <= 0) return 0;
    final tokens = score ~/ scorePerToken;
    return tokens > maxTokensPerRun ? maxTokensPerRun : tokens;
  }

  /// [forScore] clipped to what is left of the day's allowance.
  ///
  /// A run that crosses the boundary is paid what remains rather than refused:
  /// the cap is there to bound the day, not to punish the run that reaches it.
  static int forScoreWithinDay(int score, {required int alreadyEarnedToday}) {
    final remaining = dailyCap - alreadyEarnedToday;
    if (remaining <= 0) return 0;
    final earned = forScore(score);
    return earned > remaining ? remaining : earned;
  }
}

/// The UTC day a timestamp falls in, as `YYYY-MM-DD`.
///
/// The daily cap runs on UTC days for everybody rather than on the submitter's
/// local day: a device-supplied timezone would be one more number a client
/// could send to widen its own allowance, and there is no honest way to learn a
/// timezone from a request. It resets at 00:00 UTC, which the client can say
/// plainly.
String utcDay(DateTime at) {
  final u = at.toUtc();
  final month = u.month.toString().padLeft(2, '0');
  final day = u.day.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-$month-$day';
}

/// How a watched rewarded ad becomes Sparks (SPEC §4.10).
///
/// The same discipline as [TokenRate], for the same reason: nothing in this class
/// takes an amount as input. AdMob's server-side verification callback carries a
/// `reward_amount` — a number a human typed into the AdMob dashboard — and the
/// server does not read it. What an ad pays is [sparksPerAd], looked up here,
/// exactly as what a store purchase grants is looked up in `FullUnlock`
/// (SPEC §4.9). A dashboard is not a source of truth about our economy.
///
/// **The two bounds, and why they are these numbers.**
///
/// * [sparksPerAd] = 10. A rewarded ad runs about 30 seconds. Play pays a Spark
///   per 100 verified points, so 10 Sparks is roughly a 1 000-point run — about
///   a minute of real play. An ad is therefore worth about what it costs in
///   time, which is the only ratio that is honest: pay much more and playing
///   becomes the slow way to earn, pay much less and the button is a con.
/// * [dailyCap] = 60 per player per UTC day, i.e. six ads. **Separate from
///   [TokenRate.dailyCap]** and deliberately less than a third of it: an evening
///   of play pays 200, an evening of ads pays 60, so playing always dominates and
///   nobody can watch their way past a player who plays. The two caps never
///   interact — ad Sparks are not written to `earned_total` and a full ad day
///   leaves a full play day untouched — because a player who has watched six ads
///   must not then find their runs paying nothing.
/// * [cooldown] = 5 minutes between rewards. Six ads at five minutes apart is
///   half an hour spread across a day, which is a nudge; without it the shop is
///   a place you sit and farm, and that is a different app.
///
/// What that means for the shop: the cheapest paid cosmetic is 80 Sparks, so it
/// is eight ads — two days of the ad allowance, or one good evening of play.
/// Ads shorten the wait; they are never the route.
abstract final class AdRate {
  /// Sparks one watched rewarded ad pays.
  static const int sparksPerAd = 10;

  /// Most Sparks one player can earn from ads in a single UTC day.
  static const int dailyCap = 60;

  /// How many ads that is, at [sparksPerAd] each — stated so the number in the
  /// UI and the number in the cap cannot drift apart.
  static const int adsPerDay = dailyCap ~/ sparksPerAd;

  /// Shortest gap between two *paying* ads, measured on Google's own signed
  /// timestamps rather than on when a callback happened to reach us.
  ///
  /// Measuring on the signed timestamp is what makes this bound safe to enforce:
  /// a callback can be delayed or arrive out of order, and the time an ad was
  /// watched is a fact Google signed, not a fact about our network.
  static const Duration cooldown = Duration(minutes: 5);

  /// [sparksPerAd] clipped to what is left of the day's ad allowance.
  ///
  /// A reward that crosses the boundary is paid what remains rather than refused,
  /// exactly as [TokenRate.forScoreWithinDay] does: the cap bounds the day, it
  /// does not punish the ad that reaches it. The player has already watched it.
  static int forAdWithinDay({required int alreadyEarnedToday}) {
    final remaining = dailyCap - alreadyEarnedToday;
    if (remaining <= 0) return 0;
    return remaining < sparksPerAd ? remaining : sparksPerAd;
  }
}
