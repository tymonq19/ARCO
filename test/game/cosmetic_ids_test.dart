import 'dart:io';

import 'package:arco/app/cosmetics.dart';
import 'package:arco/app/game_theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// The client's item ids, pinned against the server's catalogue (SPEC §4.8).
///
/// The pin is the server's own source, not a copy of it: `server/lib/src/
/// catalogue.dart` is read and parsed here, so renaming an item on either side
/// breaks this test instead of quietly breaking the shop — a buy would succeed
/// and the arena would then draw the free default, which is the worst possible
/// failure because nobody notices it until a player complains.
void main() {
  final items = _serverCatalogue();

  test('the server really is the source being read', () {
    expect(
      items,
      hasLength(12),
      reason: 'four themes, four balls, four paddles',
    );
    expect(items.map((i) => i.kind).toSet(), {'theme', 'ball', 'paddle'});
  });

  test('every ball id matches the catalogue, in catalogue order', () {
    expect(
      [for (final i in items.where((i) => i.kind == 'ball')) i.id],
      [for (final skin in BallSkin.values) skin.id],
    );
  });

  test('every paddle id matches the catalogue, in catalogue order', () {
    expect(
      [for (final i in items.where((i) => i.kind == 'paddle')) i.id],
      [for (final skin in PaddleSkin.values) skin.id],
    );
  });

  test('every theme id matches the catalogue, in catalogue order', () {
    // Not this agent's code, but the same failure: a renamed theme would sell an
    // item the client cannot resolve.
    expect(
      [for (final i in items.where((i) => i.kind == 'theme')) i.id],
      [for (final theme in GameThemes.all) theme.nameKey],
    );
  });

  test('the free item of each kind is what the client falls back to', () {
    final freeBall = items.firstWhere((i) => i.kind == 'ball' && i.price == 0);
    final freePaddle = items.firstWhere(
      (i) => i.kind == 'paddle' && i.price == 0,
    );
    expect(freeBall.id, BallSkin.fallback.id);
    expect(freePaddle.id, PaddleSkin.fallback.id);
    // And what a player who has never equipped anything wears.
    expect(Equipped.defaults.ball, BallSkin.fallback);
    expect(Equipped.defaults.paddle, PaddleSkin.fallback);
  });

  test('an id this build does not know resolves to the free default', () {
    for (final id in [
      null,
      '',
      'ball.supernova',
      'paddle.trident',
      'theme.glass',
      'BALL.ORB',
    ]) {
      expect(BallSkin.lookup(id), isNull, reason: '$id');
      expect(PaddleSkin.lookup(id), isNull, reason: '$id');
      expect(BallSkin.parse(id), BallSkin.orb, reason: '$id');
      expect(PaddleSkin.parse(id), PaddleSkin.arc, reason: '$id');
    }
    // And the shop can tell the difference before it offers a card.
    expect(canRenderItem('ball.orb'), isTrue);
    expect(canRenderItem('paddle.chevron'), isTrue);
    expect(canRenderItem('theme.glass'), isFalse);
    expect(canRenderItem('ball.supernova'), isFalse);
    expect(canRenderItem(null), isFalse);
    // Which is what the inventory endpoint's shape has to survive.
    expect(Equipped.fromWire(null), Equipped.defaults);
    expect(
      Equipped.fromWire({'ball': 'ball.supernova', 'paddle': null}),
      Equipped.defaults,
    );
  });

  test('an equipped pair round-trips through the wire shape', () {
    const worn = Equipped(ball: BallSkin.ember, paddle: PaddleSkin.chevron);
    expect(worn.toWire(), {'ball': 'ball.ember', 'paddle': 'paddle.chevron'});
    expect(Equipped.fromWire(worn.toWire()), worn);
    expect(
      worn.copyWith(ball: BallSkin.orb),
      const Equipped(ball: BallSkin.orb, paddle: PaddleSkin.chevron),
    );
    expect(worn, isNot(Equipped.defaults));
  });
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
