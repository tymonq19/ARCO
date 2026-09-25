import 'dart:ui' show Locale, PlatformDispatcher;

/// The country hint the client attaches to a score (SPEC §4.6).
///
/// It is derived from the **device locale** and is a hint, never a claim: the
/// server validates the shape only, drops anything it cannot use and still
/// stores the run, so a stale or exotic locale can never cost somebody a
/// verified score. Nothing here asks for a permission and nothing looks at the
/// network — a national leaderboard is not worth a location prompt.
class DeviceCountry {
  const DeviceCountry._();

  /// Length of an ISO 3166-1 alpha-2 code.
  static const int codeLength = 2;

  /// The region subtag of [locale] as an uppercase alpha-2 code, or null when
  /// the locale carries nothing usable.
  ///
  /// Only the region subtag is ever sent: the server refuses a whole locale tag
  /// (`pl_PL`, `en-GB`) on purpose. A three-digit UN M49 region (`es_419`), an
  /// empty subtag and anything that is not two ASCII letters resolve to null,
  /// which submits without a country.
  static String? fromLocale(Locale? locale) {
    final raw = locale?.countryCode;
    if (raw == null) return null;
    final code = raw.trim().toUpperCase();
    if (code.length != codeLength) return null;
    for (final unit in code.codeUnits) {
      if (unit < 0x41 || unit > 0x5A) return null; // A-Z only
    }
    return code;
  }

  /// The first usable country among [locales], in the device's own preference
  /// order: a phone set to `en` with `pl_PL` second still plays in Poland.
  static String? fromLocales(List<Locale> locales) {
    for (final locale in locales) {
      final code = fromLocale(locale);
      if (code != null) return code;
    }
    return null;
  }

  /// [code] as its flag emoji: the two regional-indicator symbols for its
  /// letters. Rendered by the system emoji font, so it needs no asset and no
  /// table of 249 names in two languages — which is exactly why the server
  /// ships neither (SPEC §4.6).
  static String flagEmoji(String code) {
    if (code.length != codeLength) return '';
    // U+1F1E6 REGIONAL INDICATOR SYMBOL LETTER A is 'A' shifted up by this.
    const int offset = 0x1F1E6 - 0x41;
    final upper = code.toUpperCase();
    return String.fromCharCodes([
      for (final unit in upper.codeUnits) unit + offset,
    ]);
  }

  /// The country this device reports right now, or null when it reports none.
  ///
  /// Read through [PlatformDispatcher] rather than a `BuildContext`, so a
  /// background retry of a pending replay can ask for it too.
  static String? current() => fromLocales(PlatformDispatcher.instance.locales);
}
