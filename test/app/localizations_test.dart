import 'package:arco/app/settings.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/main.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/test_env.dart';

/// SPEC 5.6: the app ships EN + PL, so every declared locale needs Material /
/// Cupertino / Widgets localizations installed — a Material widget such as the
/// Home nickname `TextField` looks `MaterialLocalizations` up and throws when
/// the resolved locale has no delegate.
void main() {
  Future<BuildContext> pumpApp(
    WidgetTester tester, {
    required Locale deviceLocale,
    AppLanguage language = AppLanguage.system,
  }) async {
    tester.platformDispatcher.localesTestValue = <Locale>[deviceLocale];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    useTallPhone(tester);
    final env = await createTestEnv(prefs: {'language': language.name});
    await tester.pumpWidget(
      ArcoApp(storage: env.storage, settings: env.settings, audio: env.audio),
    );
    await tester.pump();
    return tester.element(find.byType(TextField));
  }

  testWidgets('a Polish device builds the app without losing Material '
      'localizations', (tester) async {
    final context = await pumpApp(
      tester,
      deviceLocale: const Locale('pl', 'PL'),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Pseudonim'), findsOneWidget);
    expect(Localizations.localeOf(context).languageCode, 'pl');
    expect(MaterialLocalizations.of(context).backButtonTooltip, 'Wstecz');
    expect(CupertinoLocalizations.of(context).copyButtonLabel, 'Kopiuj');
  });

  testWidgets('an unsupported device locale falls back to English', (
    tester,
  ) async {
    final context = await pumpApp(
      tester,
      deviceLocale: const Locale('de', 'DE'),
    );

    expect(tester.takeException(), isNull);
    expect(Localizations.localeOf(context).languageCode, 'en');
    expect(MaterialLocalizations.of(context).backButtonTooltip, 'Back');
  });

  testWidgets('the language override drives Material own strings too', (
    tester,
  ) async {
    final context = await pumpApp(
      tester,
      deviceLocale: const Locale('en', 'US'),
      language: AppLanguage.pl,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Pseudonim'), findsOneWidget);
    expect(Localizations.localeOf(context).languageCode, 'pl');
    expect(MaterialLocalizations.of(context).backButtonTooltip, 'Wstecz');
  });

  testWidgets('switching the language at runtime reloads the delegates', (
    tester,
  ) async {
    final context = await pumpApp(
      tester,
      deviceLocale: const Locale('pl', 'PL'),
      language: AppLanguage.pl,
    );
    expect(MaterialLocalizations.of(context).backButtonTooltip, 'Wstecz');

    Provider.of<Settings>(context, listen: false).language = AppLanguage.en;
    await tester.pump();

    final next = tester.element(find.byType(TextField));
    expect(find.text('Nickname'), findsOneWidget);
    expect(Localizations.localeOf(next).languageCode, 'en');
    expect(MaterialLocalizations.of(next).backButtonTooltip, 'Back');
    expect(tester.takeException(), isNull);
  });

  // English is the primary language: it is the authoritative key set and the
  // fallback for anything the app cannot resolve. Polish is fully supported,
  // so the two tables must stay the same size.
  test('English holds the complete, authoritative string set', () {
    expect(Strings.en.keys.toSet(), Strings.pl.keys.toSet());
    expect(Strings.en.length, Strings.pl.length);
    for (final key in Strings.en.keys) {
      expect(Strings.en[key], isNotEmpty, reason: 'en/$key is empty');
      expect(Strings.pl[key], isNotEmpty, reason: 'pl/$key is missing/empty');
    }
  });

  test('an unknown locale resolves to English, never to Polish', () {
    const pl = Locale('pl');
    expect(
      Strings.resolveLanguage(AppLanguage.system, const Locale('de')),
      'en',
    );
    expect(
      Strings.resolveLanguage(AppLanguage.system, const Locale('ja')),
      'en',
    );
    expect(
      Strings.resolveLanguage(AppLanguage.system, const Locale('en')),
      'en',
    );
    expect(Strings.resolveLanguage(AppLanguage.system, pl), 'pl');
    expect(Strings.resolveLanguage(AppLanguage.en, pl), 'en');
    expect(Strings.resolveLanguage(AppLanguage.pl, const Locale('en')), 'pl');
  });

  test('an unknown language code reads the English table', () {
    expect(const Strings('pl').t('home.nickname'), 'Pseudonim');
    expect(const Strings('en').t('home.nickname'), 'Nickname');
    expect(const Strings('de').t('home.nickname'), 'Nickname');
    // A code the tables do not carry is returned as-is rather than throwing.
    expect(const Strings('en').t('nope.missing'), 'nope.missing');
  });

  // SPEC 4.8: the shop currency is named, and Polish declines it. A currency that
  // is ungrammatical every time a number ends in 5 is a currency nobody believes
  // in, so the three forms are checked at the boundaries that catch every naive
  // implementation.
  group('the shop currency', () {
    const en = Strings('en');
    const pl = Strings('pl');

    test('English has one singular and one plural', () {
      expect(en.t('currency.name'), 'Sparks');
      expect(en.sparks(1), '1 spark');
      expect(en.sparks(0), '0 sparks');
      expect(en.sparks(2), '2 sparks');
      expect(en.sparks(80), '80 sparks');
      expect(en.sparks(250), '250 sparks');
    });

    test('Polish takes iskra / iskry / iskier, including the teens', () {
      expect(pl.t('currency.name'), 'Iskry');
      expect(pl.sparks(1), '1 iskra');
      expect(pl.sparks(2), '2 iskry');
      expect(pl.sparks(3), '3 iskry');
      expect(pl.sparks(4), '4 iskry');
      expect(pl.sparks(5), '5 iskier');
      expect(pl.sparks(0), '0 iskier');
      // The teens are the trap: 12-14 take the many form although 2-4 do not.
      expect(pl.sparks(12), '12 iskier');
      expect(pl.sparks(13), '13 iskier');
      expect(pl.sparks(14), '14 iskier');
      expect(pl.sparks(22), '22 iskry');
      expect(pl.sparks(23), '23 iskry');
      expect(pl.sparks(25), '25 iskier');
      expect(pl.sparks(80), '80 iskier');
      expect(pl.sparks(112), '112 iskier');
      expect(pl.sparks(122), '122 iskry');
      expect(pl.sparks(200), '200 iskier');
      expect(pl.sparks(250), '250 iskier');
    });

    test('the currency is named the same way in every sentence', () {
      // One word per language, used everywhere: no screen invents "coins",
      // "points" or "credits" beside it.
      for (final language in [en, pl]) {
        // Three letters, not four: the Polish genitive plural is *iskier*, which
        // drops the "r" of the stem — which is exactly why the app cannot get
        // away with pasting a noun after a number.
        final stem = language.t('currency.name').toLowerCase().substring(0, 3);
        expect(language.sparks(5).toLowerCase(), contains(stem));
        expect(language.sparks(1).toLowerCase(), contains(stem));
      }
      for (final table in [Strings.en, Strings.pl]) {
        for (final key in table.keys.where((k) => k.startsWith('shop.'))) {
          final value = table[key]!.toLowerCase();
          for (final wrong in ['coin', 'moneta', 'credit', 'kredyt', 'gem']) {
            expect(
              value,
              isNot(contains(wrong)),
              reason: '$key calls the currency something else',
            );
          }
        }
      }
    });
  });
}
