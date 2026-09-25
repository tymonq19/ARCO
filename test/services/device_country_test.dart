import 'dart:ui' show Locale;

import 'package:arco/services/device_country.dart';
import 'package:flutter_test/flutter_test.dart';

/// SPEC §4.6: the country is the **region subtag of the device locale** and
/// nothing else — no permission, no lookup, and no whole locale tag, which the
/// server refuses on purpose.
void main() {
  test('the region subtag of a locale becomes the country', () {
    expect(DeviceCountry.fromLocale(const Locale('pl', 'PL')), 'PL');
    expect(DeviceCountry.fromLocale(const Locale('en', 'gb')), 'GB');
    expect(DeviceCountry.fromLocale(const Locale('de', ' at ')), 'AT');
  });

  test('a locale with nothing usable sends no country', () {
    expect(DeviceCountry.fromLocale(null), isNull);
    expect(DeviceCountry.fromLocale(const Locale('en')), isNull);
    expect(DeviceCountry.fromLocale(const Locale('en', '')), isNull);
    // A UN M49 region (es-419 "Latin America") is not an alpha-2 code.
    expect(DeviceCountry.fromLocale(const Locale('es', '419')), isNull);
    // Neither is a script or a three-letter code.
    expect(DeviceCountry.fromLocale(const Locale('sr', 'Latn')), isNull);
    expect(DeviceCountry.fromLocale(const Locale('en', 'P1')), isNull);
  });

  test('the device order decides which country is used', () {
    expect(
      DeviceCountry.fromLocales(const [
        Locale('en'),
        Locale('pl', 'PL'),
        Locale('de', 'DE'),
      ]),
      'PL',
    );
    expect(DeviceCountry.fromLocales(const [Locale('en')]), isNull);
    expect(DeviceCountry.fromLocales(const []), isNull);
  });

  test('a code is labelled with its own flag', () {
    // Two regional indicator symbols, which every system emoji font draws as
    // the flag - so no table of country names has to be shipped or translated.
    expect(DeviceCountry.flagEmoji('PL'), '\u{1F1F5}\u{1F1F1}');
    expect(DeviceCountry.flagEmoji('gb'), '\u{1F1EC}\u{1F1E7}');
    expect(DeviceCountry.flagEmoji('X'), '');
  });
}
