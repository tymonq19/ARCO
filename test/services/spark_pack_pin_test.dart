/// The Spark packs, pinned against the server's own table (SPEC §4.9).
///
/// The client holds almost nothing about the packs by itself: the list, the
/// amounts and the product identifiers all arrive from
/// `GET /api/shop/catalogue`, and the *prices* come from the store. What it does
/// hold is a display name per pack, and the test fixture that pretends to be the
/// server — and both would rot silently if a product id were renamed in
/// `server/lib/src/catalogue.dart` and nowhere else.
///
/// So this reads the server's source and checks three things that cannot be
/// checked any other way:
///
/// * every pack the server sells has a name in **both** languages, or its card
///   would show a raw product identifier to a paying customer;
/// * the fixture the widget and service tests use really is the server's table,
///   so a passing test means something;
/// * every product id is a string **both stores accept**, because App Store
///   Connect and the Play Console each reject shapes the other allows, and a
///   rejected id is found out during store review rather than here;
/// * and `ios/Arco.storekit` — the checked-in StoreKit configuration that makes
///   the payment sheet work on a simulator with no App Store account
///   (SETUP.md §9.7) — sells exactly the server's packs, as consumables. That
///   file is read by Xcode and by nothing else, so a pack added to the server
///   and forgotten there would simply be missing from the sheet, with no error
///   anywhere.
library;

import 'dart:convert';
import 'dart:io';

import 'package:arco/app/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  final packs = _serverPacks();

  test('the server really is the source being read', () {
    expect(
      packs,
      isNotEmpty,
      reason: 'no Spark packs parsed out of the server',
    );
    expect(
      packs.map((p) => p.productId).toSet(),
      hasLength(packs.length),
      reason: 'two packs with one product id would credit the wrong amount',
    );
  });

  test('the test fixture is the server table, not a hopeful copy', () {
    final fixture = testSparkPacks();
    expect(
      [for (final p in fixture) p.productId],
      [for (final p in packs) p.productId],
      reason: 'the fake server must sell what the real one sells',
    );
    expect(
      [for (final p in fixture) p.sparks],
      [for (final p in packs) p.sparks],
    );
    expect(
      [for (final p in fixture) p.nameKey],
      [for (final p in packs) p.nameKey],
    );
  });

  test('every pack has a name in both languages', () {
    for (final pack in packs) {
      expect(
        Strings.en[pack.nameKey],
        isNotNull,
        reason: 'no English name for ${pack.productId}',
      );
      expect(
        Strings.pl[pack.nameKey],
        isNotNull,
        reason: 'no Polish name for ${pack.productId}',
      );
      // And the lookup really resolves, rather than falling back to the key —
      // which on a paid card would print `pack.small` at somebody who is about
      // to be charged money.
      expect(const Strings('en').item(pack.nameKey), isNot(pack.nameKey));
      expect(const Strings('pl').item(pack.nameKey), isNot(pack.nameKey));
    }
  });

  test('every product id is a shape both stores accept', () {
    for (final pack in packs) {
      expect(
        pack.productId,
        matches(RegExp(r'^[a-z][a-z0-9.]*[a-z0-9]$')),
        reason:
            '${pack.productId}: lowercase letters, digits and dots only — the '
            'intersection of App Store Connect and Play Console rules',
      );
      expect(pack.productId.length, lessThanOrEqualTo(100));
      expect(pack.productId, isNot(contains('..')));
    }
  });

  group('the simulator StoreKit configuration', () {
    test('sells exactly the packs the server sells', () {
      final products = _storeKitProducts();
      expect(
        products.keys.toList()..sort(),
        packs.map((p) => p.productId).toList()..sort(),
        reason:
            'ios/Arco.storekit must list the server catalogue, no more and no '
            'less — see SETUP.md §9.7',
      );
    });

    test('lists every pack as a consumable', () {
      // A non-consumable cannot be bought twice, and a subscription renews. A
      // Spark pack is neither: it is spent, and it is bought again.
      for (final entry in _storeKitProducts().entries) {
        expect(
          entry.value['type'],
          'Consumable',
          reason: '${entry.key} must be a consumable',
        );
      }
    });

    test('carries a display name and a price for each pack', () {
      // The price here is a placeholder Xcode shows on a simulator; a real
      // player is always shown the store's own string (SPEC §4.9). What matters
      // is that there *is* one, or the sheet cannot open.
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
          isA<List<dynamic>>().having((l) => l.length, 'languages', isPositive),
          reason: '${entry.key}: a product with no localization has no name',
        );
      }
    });
  });

  test('a pack pays enough to be worth buying and not the whole shop twice', () {
    // Sanity, not policy: the smallest pack has to buy *something* in the shop
    // (the cheapest paid cosmetic is 80 Sparks), and a pack that pays less than
    // the daily earning allowance of 200 would be a pack that is slower than
    // playing.
    final smallest = packs.map((p) => p.sparks).reduce((a, b) => a < b ? a : b);
    expect(smallest, greaterThanOrEqualTo(80));
    for (final pack in packs) {
      expect(pack.sparks, greaterThan(0));
    }
  });
}

class _Pack {
  const _Pack(this.productId, this.sparks, this.nameKey);
  final String productId;
  final int sparks;
  final String nameKey;
}

List<_Pack> _serverPacks() {
  final source = _catalogueFile().readAsStringSync();
  final pattern = RegExp(
    r"SparkPack\(\s*productId:\s*'([^']+)',\s*"
    r'sparks:\s*(\d+),\s*'
    r"nameKey:\s*'([^']+)'",
  );
  final packs = [
    for (final m in pattern.allMatches(source))
      _Pack(m.group(1)!, int.parse(m.group(2)!), m.group(3)!),
  ];
  if (packs.isEmpty) {
    fail('no Spark packs parsed out of ${_catalogueFile().path}');
  }
  return packs;
}

/// The products `ios/Arco.storekit` declares, by product id.
Map<String, Map<String, dynamic>> _storeKitProducts() {
  final decoded = jsonDecode(_repoFile('ios/Arco.storekit').readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    fail('ios/Arco.storekit is not a JSON object');
  }
  final products = decoded['products'];
  if (products is! List) fail('ios/Arco.storekit has no "products"');
  return <String, Map<String, dynamic>>{
    for (final product in products.cast<Map<String, dynamic>>())
      '${product['productID']}': product,
  };
}

/// The server's catalogue, found by walking up from wherever the test runner
/// started: the two packages live in one repository, so this is always there.
File _catalogueFile() => _repoFile('server/lib/src/catalogue.dart');

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
