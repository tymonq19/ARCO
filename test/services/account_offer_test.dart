import 'package:arco/services/account_offer.dart';
import 'package:arco/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The rule that keeps the account offer from becoming nagging (SPEC §4.5):
/// the first no silences it for a week, the second for a month, the third for
/// good.
void main() {
  late DateTime clock;

  Future<AccountOffer> offer({Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    return AccountOffer(storage: await Storage.load(), now: () => clock);
  }

  setUp(() => clock = DateTime.utc(2026, 9, 23, 12));

  test('a player who has never said no is offered it', () async {
    final it = await offer();
    expect(it.dismissals, 0);
    expect(it.silenced, isFalse);
    expect(it.remaining, isNull);
  });

  test('the first no buys a week of silence', () async {
    final it = await offer();
    await it.dismiss();

    expect(it.dismissals, 1);
    expect(it.silenced, isTrue);
    expect(it.remaining, const Duration(days: 7));

    clock = clock.add(const Duration(days: 6, hours: 23));
    expect(it.silenced, isTrue);

    clock = clock.add(const Duration(hours: 2));
    expect(it.silenced, isFalse);
  });

  test('the second no buys a month', () async {
    final it = await offer();
    await it.dismiss();
    clock = clock.add(const Duration(days: 8));
    await it.dismiss();

    expect(it.dismissals, 2);
    expect(it.silenced, isTrue);

    clock = clock.add(const Duration(days: 29));
    expect(it.silenced, isTrue);

    clock = clock.add(const Duration(days: 2));
    expect(it.silenced, isFalse);
  });

  test('the third no is permanent', () async {
    final it = await offer();
    await it.dismiss();
    clock = clock.add(const Duration(days: 8));
    await it.dismiss();
    clock = clock.add(const Duration(days: 31));
    await it.dismiss();

    expect(it.dismissals, AccountOffer.forever);
    expect(it.silenced, isTrue);
    expect(it.remaining, Duration.zero);

    clock = clock.add(const Duration(days: 4000));
    expect(it.silenced, isTrue);
  });

  test('the permanent count is one past the list of gaps', () {
    expect(AccountOffer.forever, AccountOffer.gaps.length + 1);
  });

  test('signing in, signing out or deleting stops it for good', () async {
    final it = await offer();
    await it.silenceForever();

    clock = clock.add(const Duration(days: 365));
    expect(it.silenced, isTrue);
    expect(it.dismissals, AccountOffer.forever);
  });

  test('a dismissal without a timestamp stays silenced', () async {
    // What a build that wrote only the count would leave behind: a count with
    // nowhere to measure the gap from must not read as "ask again".
    final it = await offer(prefs: const {'accountOfferDismissals': 1});
    expect(it.silenced, isTrue);
    expect(it.remaining, Duration.zero);
  });

  test('a clock that moved backwards does not reopen the offer', () async {
    final it = await offer();
    await it.dismiss();
    clock = clock.subtract(const Duration(days: 400));
    expect(it.silenced, isTrue);
  });

  test('the dismissal survives a restart, because it is in prefs', () async {
    final first = await offer();
    await first.dismiss();
    final storage = first.storage;

    final second = AccountOffer(storage: storage, now: () => clock);
    expect(second.dismissals, 1);
    expect(second.silenced, isTrue);
  });
}
