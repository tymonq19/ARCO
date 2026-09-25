import 'storage.dart';

/// When the app may offer an account, and when it must keep quiet (SPEC §4.5).
///
/// The offer is never a gate on playing, so the only thing that makes it
/// acceptable is that saying no works. The rule, deliberately simple enough to
/// state on one line: **the first no silences it for a week, the second for a
/// month, the third for good.** Nothing counts the offer being *shown* — a
/// player who scrolls past it is not saying anything — and signing in or
/// deleting the account stops it permanently.
class AccountOffer {
  AccountOffer({required this.storage, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// The silence each dismissal buys, in order. Running off the end of this
  /// list is "never again".
  static const List<Duration> gaps = <Duration>[
    Duration(days: 7),
    Duration(days: 30),
  ];

  /// The dismissal count that means "never ask again", used by a sign-out and by
  /// a deletion as well as by the third no. One past [gaps], which a test pins
  /// to the list's own length.
  static const int forever = 3;

  final Storage storage;
  final DateTime Function() _now;

  int get dismissals => storage.accountOfferDismissals;

  /// True while the offer must not be shown. A count past [gaps] is permanent;
  /// otherwise the gap for that dismissal has to have elapsed.
  ///
  /// A missing or future timestamp counts as "just now": a clock that moved
  /// backwards must not turn into a fresh round of offers.
  bool get silenced {
    final count = dismissals;
    if (count <= 0) return false;
    if (count >= forever) return true;
    final at = storage.accountOfferDismissedAt;
    if (at == null) return true;
    final since = _now().toUtc().difference(at);
    return since.isNegative || since < gaps[count - 1];
  }

  /// How long is left of the current silence, for a log or a test; null when the
  /// offer may be shown and [Duration.zero] when it is silenced for good.
  Duration? get remaining {
    if (!silenced) return null;
    final count = dismissals;
    final at = storage.accountOfferDismissedAt;
    if (count >= forever || at == null) return Duration.zero;
    return gaps[count - 1] - _now().toUtc().difference(at);
  }

  /// The player waved the offer away. Moves to the next, longer gap.
  Future<void> dismiss() =>
      storage.setAccountOfferDismissal(dismissals + 1, _now());

  /// Stop offering permanently: the player signed in (there is nothing left to
  /// offer), signed out on purpose, or deleted their account.
  Future<void> silenceForever() =>
      storage.setAccountOfferDismissal(forever, _now());
}
