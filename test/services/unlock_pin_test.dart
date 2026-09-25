/// The one-time unlock, pinned against the server's own table and the checked-in
/// StoreKit configuration (SPEC §4.9).
///
/// The client holds almost nothing about the product by itself: the identifier and
/// the name key arrive from `GET /api/shop/catalogue`, and the *price* comes from
/// the store. What it does hold is a display name, and the test fixture that
/// pretends to be the server — and both would rot silently if the product were
/// renamed in `server/lib/src/catalogue.dart` and nowhere else.
///
/// So this reads the server's source and checks what cannot be checked any other
/// way:
///
/// * the product has a name in **both** languages, or the card would show a raw
///   store identifier to somebody about to be charged money;
/// * the fixture the widget and service tests use really is the server's product,
///   so a passing test means something;
/// * the identifier is a string **both stores accept**, because App Store Connect
///   and the Play Console each reject shapes the other allows, and a rejected id is
///   found out during store review rather than here;
/// * **no price lives anywhere in our code** — not in `lib/`, not in the server's
///   catalogue. The only honest price is the store's, and a number in our source
///   would be wrong in most markets and illegal in several;
/// * and `ios/Arco.storekit` — the configuration that makes the payment sheet work
///   on a simulator with no App Store account (SETUP.md §9.7) — sells exactly that
///   product, as a **non-consumable**. A consumable there would let the sheet buy
///   it twice and would never restore, which is the whole property this model is
///   built on. That file is read by Xcode and by nothing else, so a mismatch would
///   simply be a missing product in the sheet, with no error anywhere.
library;

import 'dart:convert';
import 'dart:io';

import 'package:arco/app/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  final unlock = _serverUnlock();

  test('the server really is the source being read', () {
    expect(unlock.productId, isNotEmpty);
    expect(unlock.nameKey, isNotEmpty);
    expect(
      unlock.entitlement,
      isNotEmpty,
      reason:
          'the RevenueCat entitlement is half of the store paperwork; a server '
          'that names none cannot be set up from SETUP.md §9.4',
    );
  });

  test('exactly one product is sold, and it is not a currency pack', () {
    // The whole point of the model: one purchase, no tiers, nothing that only
    // makes sense beside a struck-through price.
    final source = _catalogueFile().readAsStringSync();
    expect(
      RegExp(r'UnlockProduct\(\s*productId:').allMatches(source).length,
      1,
      reason: 'one product, or the shop has a price list again',
    );
    expect(
      source,
      isNot(contains('SparkPack(')),
      reason: 'the Spark packs are gone; a leftover one would still be sold',
    );
    expect(
      unlock.productId,
      isNot(contains('sparks')),
      reason: 'what is bought is the unlock, not a quantity of anything',
    );
  });

  test('the test fixture is the server product, not a hopeful copy', () {
    final fixture = testUnlock();
    expect(fixture.productId, unlock.productId);
    expect(fixture.nameKey, unlock.nameKey);
    expect(testUnlockProductId, unlock.productId);
  });

  test('the product has a name in both languages', () {
    expect(
      Strings.en[unlock.nameKey],
      isNotNull,
      reason: 'no English name for ${unlock.productId}',
    );
    expect(
      Strings.pl[unlock.nameKey],
      isNotNull,
      reason: 'no Polish name for ${unlock.productId}',
    );
    // And the lookup really resolves, rather than falling back to the key — which
    // on a paid card would print `unlock.full` at somebody about to pay.
    expect(const Strings('en').item(unlock.nameKey), isNot(unlock.nameKey));
    expect(const Strings('pl').item(unlock.nameKey), isNot(unlock.nameKey));
  });

  test('the product id is a shape both stores accept', () {
    expect(
      unlock.productId,
      matches(RegExp(r'^[a-z][a-z0-9.]*[a-z0-9]$')),
      reason:
          '${unlock.productId}: lowercase letters, digits and dots only — the '
          'intersection of App Store Connect and Play Console rules',
    );
    expect(unlock.productId.length, lessThanOrEqualTo(100));
    expect(unlock.productId, isNot(contains('..')));
  });

  group('no price anywhere in our code', () {
    // The rule of SPEC §4.9, checked where it can actually be broken: a number
    // beside a currency, or a currency name, in a string the app can print.
    test('no string in either language carries a price', () {
      // A figure next to a currency, in any of the shapes a well-meaning
      // hardcoded price takes. The server URL hint holds an IP address, which is
      // why this looks for the currency rather than for a decimal point.
      final money = RegExp(
        r'([0-9][\s\u00a0]*(zł|pln|usd|eur|gbp)\b)'
        r'|([\$€£¥][\s\u00a0]*[0-9])'
        r'|([0-9][\s\u00a0]*[\$€£¥])',
        caseSensitive: false,
      );
      // And in the money strings themselves, no amount of any kind.
      final amount = RegExp(r'[0-9]+[.,][0-9]{2}');
      for (final table in [Strings.en, Strings.pl]) {
        for (final entry in table.entries) {
          expect(
            money.hasMatch(entry.value),
            isFalse,
            reason: '${entry.key} looks like it contains a price',
          );
          if (!entry.key.startsWith('shop.') &&
              !entry.key.startsWith('unlock.')) {
            continue;
          }
          expect(
            amount.hasMatch(entry.value),
            isFalse,
            reason: '${entry.key} looks like it contains an amount of money',
          );
        }
      }
    });

    test('no file in lib/ holds a price literal', () {
      // The rule is about the code, not only the strings: a price composed in a
      // widget is the same mistake one layer down. What the app prints is whatever
      // the store handed it, and there is nowhere else for a figure to come from.
      // No `\$` here, unlike the string check: in Dart source a dollar sign is
      // interpolation or a record field, never a currency.
      final money = RegExp(
        r'([0-9][\s\u00a0]*(zł|PLN|USD|EUR|GBP)\b)|([€£¥][\s\u00a0]*[0-9])',
      );
      for (final file in _dartFilesUnder('lib')) {
        final source = file.readAsStringSync();
        expect(
          money.hasMatch(source),
          isFalse,
          reason: '${file.path} looks like it holds a price',
        );
      }
    });

    test('the server advertises an id and a name key, and nothing else', () {
      // `UnlockProduct.toJson` is the whole of what crosses to the client. A
      // `price` field there is the failure this asserts against.
      final source = _catalogueFile().readAsStringSync();
      final json = RegExp(
        r"Map<String, dynamic> toJson\(\) => \{'productId': productId, "
        r"'nameKey': nameKey\};",
      );
      expect(
        json.hasMatch(source.replaceAll(RegExp(r'\s+'), ' ')),
        isTrue,
        reason:
            'the product the server advertises must carry no price; see '
            'UnlockProduct.toJson in server/lib/src/catalogue.dart',
      );
    });
  });

  group('the simulator StoreKit configuration', () {
    test('sells exactly the product the server sells', () {
      final products = _storeKitProducts();
      expect(
        products.keys.toList(),
        [unlock.productId],
        reason:
            'ios/Arco.storekit must list the server product, no more and no '
            'less — see SETUP.md §9.7',
      );
    });

    test('lists it as a non-consumable, and sells no subscription', () {
      // A consumable could be bought twice and would never restore; a
      // subscription renews and expires. The unlock is neither: it is bought once
      // and kept, which is what makes Restore Purchases a real feature.
      for (final entry in _storeKitProducts().entries) {
        expect(
          entry.value['type'],
          'NonConsumable',
          reason: '${entry.key} must be a non-consumable',
        );
      }
      final config = _storeKitConfig();
      expect(config['subscriptionGroups'], isEmpty);
      expect(config['nonRenewingSubscriptions'], isEmpty);
    });

    test('carries a display name in both languages, and a price Xcode reads', () {
      // The price here is a placeholder Xcode shows on a simulator; a real player
      // is always shown the store's own string (SPEC §4.9). What matters is that
      // there *is* one, or the sheet cannot open.
      for (final entry in _storeKitProducts().entries) {
        final price = entry.value['displayPrice'];
        expect(price, isA<String>());
        expect(
          double.tryParse(price as String),
          isNotNull,
          reason: '${entry.key}: displayPrice must be a number Xcode can read',
        );
        final localizations = entry.value['localizations'];
        expect(
          localizations,
          isA<List<dynamic>>(),
          reason: '${entry.key}: a product with no localization has no name',
        );
        final locales = <String>[
          for (final l in localizations as List<dynamic>)
            '${(l as Map<String, dynamic>)['locale']}'.split('_').first,
        ];
        expect(
          locales,
          containsAll(<String>['en', 'pl']),
          reason:
              '${entry.key}: the app ships EN + PL, so the sheet should too',
        );
      }
    });
  });
}

class _Unlock {
  const _Unlock(this.productId, this.nameKey, this.entitlement);
  final String productId;
  final String nameKey;
  final String entitlement;
}

_Unlock _serverUnlock() {
  final source = _catalogueFile().readAsStringSync();
  String one(RegExp pattern, String what) {
    final match = pattern.firstMatch(source);
    if (match == null) fail('no $what parsed out of ${_catalogueFile().path}');
    return match.group(1)!;
  }

  return _Unlock(
    one(
      RegExp(r"static const String productId = '([^']+)'"),
      'unlock product id',
    ),
    one(RegExp(r"nameKey: '([^']+)'"), 'unlock name key'),
    one(
      RegExp(r"static const String premiumEntitlement = '([^']+)'"),
      'RevenueCat entitlement',
    ),
  );
}

/// `ios/Arco.storekit`, decoded.
Map<String, dynamic> _storeKitConfig() {
  final decoded = jsonDecode(_repoFile('ios/Arco.storekit').readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    fail('ios/Arco.storekit is not a JSON object');
  }
  return decoded;
}

/// The products `ios/Arco.storekit` declares, by product id.
Map<String, Map<String, dynamic>> _storeKitProducts() {
  final products = _storeKitConfig()['products'];
  if (products is! List) fail('ios/Arco.storekit has no "products"');
  return <String, Map<String, dynamic>>{
    for (final product in products.cast<Map<String, dynamic>>())
      '${product['productID']}': product,
  };
}

/// The server's catalogue, found by walking up from wherever the test runner
/// started: the two packages live in one repository, so this is always there.
File _catalogueFile() => _repoFile('server/lib/src/catalogue.dart');

/// Every `.dart` file under [relative], for a rule about the whole client.
List<File> _dartFilesUnder(String relative) {
  final dir = Directory('${_repoFile('pubspec.yaml').parent.path}/$relative');
  if (!dir.existsSync()) fail('$relative not found');
  return <File>[
    for (final entry in dir.listSync(recursive: true))
      if (entry is File && entry.path.endsWith('.dart')) entry,
  ];
}

/// [relative], found by walking up from wherever the test runner started.
File _repoFile(String relative) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final file = File('${dir.path}/$relative');
    if (file.existsSync()) return file;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('$relative not found above ${Directory.current.path}');
}
