import 'dart:io';

import 'package:arco/app/game_theme.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/services/shop_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two things the client knows about the catalogue by itself, pinned against
/// the server's own source (SPEC §4.8).
///
/// The client decides nothing about prices or ownership — but it does hold a set
/// of ids that cost nothing ([ShopSnapshot.freeItemIds]), so a phone that has
/// never reached the server can still play and still pick between the looks that
/// are free. That set, and the catalogue version this build can draw, are the
/// only two facts here, and both are read out of `server/lib/src/catalogue.dart`
/// rather than copied into this file.
///
/// The failure direction matters: believing the phone about something that costs
/// tokens is impossible (only the server grants a paid item, and it refuses an
/// equip it disagrees with), so the worst a drifted entry can do is lock a free
/// look or cost one refused request. This test keeps even that from happening.
void main() {
  final items = _serverCatalogue();

  test('the server really is the source being read', () {
    expect(
      items,
      hasLength(12),
      reason: 'four themes, four balls, four paddles',
    );
    expect(items.map((i) => i.kind).toSet(), CosmeticSlot.all.toSet());
  });

  test('the free items are exactly the ones the server gives away', () {
    expect({
      for (final i in items.where((i) => i.price == 0)) i.id,
    }, ShopSnapshot.freeItemIds);
    // And every one of them is really free on the client's reading of it.
    for (final id in ShopSnapshot.freeItemIds) {
      expect(
        const ShopSnapshot().owns(id),
        isTrue,
        reason: '$id must be wearable on a phone that has never synced',
      );
    }
  });

  test('nothing that costs tokens is owned by default', () {
    for (final item in items.where((i) => i.price > 0)) {
      expect(
        const ShopSnapshot().owns(item.id),
        isFalse,
        reason: '${item.id} costs ${item.price} and must come from the server',
      );
    }
  });

  test('every slot in the catalogue is a slot the client has', () {
    for (final item in items) {
      expect(CosmeticSlot.of(item.id), item.kind, reason: item.id);
      expect(CosmeticSlot.all, contains(item.kind));
    }
  });

  test('every item has a name in both languages', () {
    for (final item in items) {
      // The server's `nameKey` is the item id, so these keys line up by
      // construction — which is only true as long as the strings exist.
      expect(
        Strings.en[item.id],
        isNotNull,
        reason: 'no English name for ${item.id}',
      );
      expect(
        Strings.pl[item.id],
        isNotNull,
        reason: 'no Polish name for ${item.id}',
      );
      expect(const Strings('en').item(item.id), isNot(item.id));
      expect(const Strings('pl').item(item.id), isNot(item.id));
    }
  });

  test('every look the catalogue sells is a look this build can draw', () {
    for (final item in items.where((i) => i.kind == CosmeticSlot.theme)) {
      expect(
        GameThemes.byItemId(item.id),
        isNotNull,
        reason: '${item.id} is sold and cannot be rendered',
      );
    }
  });

  test(
    'the catalogue version this build draws is the one the server serves',
    () {
      // A bump means the server grew a *kind* of item this app has never drawn
      // (SPEC §4.8). Failing here is the point: somebody has to teach the client
      // the new kind, or raise this constant on purpose once it can.
      expect(ShopService.clientCatalogueVersion, _serverCatalogueVersion());
    },
  );
}

class _Item {
  const _Item(this.id, this.kind, this.price);
  final String id;
  final String kind;
  final int price;
}

List<_Item> _serverCatalogue() {
  final source = _catalogueFile().readAsStringSync();
  final pattern = RegExp(
    r"CatalogueItem\(\s*id:\s*'([^']+)',\s*"
    r'kind:\s*CosmeticKind\.(\w+),\s*'
    r'priceTokens:\s*(\d+)',
  );
  final items = [
    for (final m in pattern.allMatches(source))
      _Item(m.group(1)!, m.group(2)!, int.parse(m.group(3)!)),
  ];
  if (items.isEmpty) {
    fail('no catalogue entries parsed out of ${_catalogueFile().path}');
  }
  return items;
}

int _serverCatalogueVersion() {
  final source = _catalogueFile().readAsStringSync();
  final match = RegExp(r'static const int version = (\d+);').firstMatch(source);
  if (match == null) fail('no catalogue version in ${_catalogueFile().path}');
  return int.parse(match.group(1)!);
}

/// The server's catalogue, found by walking up from wherever the test runner
/// started: the two packages live in one repository, so this is always there.
File _catalogueFile() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final file = File('${dir.path}/server/lib/src/catalogue.dart');
    if (file.existsSync()) return file;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    'server/lib/src/catalogue.dart not found above ${Directory.current.path}',
  );
}
