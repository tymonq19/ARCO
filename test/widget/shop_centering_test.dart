// The shop used to sit against the left edge: cards are capped at their drawn
// width, so a row rarely fills the screen, and a left-aligned Wrap piled every
// leftover pixel on the right. These tests assert the geometry rather than a
// picture, so a regression names itself.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:arco/ui/widgets/shop_card.dart';

import '../helpers/test_env.dart';

/// The gap on the left of the card block must equal the gap on its right.
Future<void> expectCardsCentred(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);

  final env = await createTestEnv(balance: 400);
  await tester.pumpWidget(wrapApp(env, const ShopScreen()));
  await tester.pump(const Duration(milliseconds: 350));

  final cards = find.byType(ShopCard);
  expect(cards, findsWidgets, reason: 'the shop should list cards at $size');

  var left = double.infinity;
  var right = double.negativeInfinity;
  for (final element in cards.evaluate()) {
    final box = element.renderObject! as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    left = left < origin.dx ? left : origin.dx;
    final edge = origin.dx + box.size.width;
    right = right > edge ? right : edge;
  }

  final gapLeft = left;
  final gapRight = size.width - right;
  expect(
    (gapLeft - gapRight).abs(),
    lessThan(1.5),
    reason: 'cards are off-centre at $size: $gapLeft left, $gapRight right',
  );
}

void main() {
  testWidgets('cards are centred on a phone', (tester) async {
    await expectCardsCentred(tester, const Size(390, 844));
  });

  testWidgets('cards are centred on a narrow phone', (tester) async {
    await expectCardsCentred(tester, const Size(320, 568));
  });

  testWidgets('cards are centred on a tablet', (tester) async {
    await expectCardsCentred(tester, const Size(834, 1100));
  });

  testWidgets('the content column stops widening', (tester) async {
    tester.view.physicalSize =
        const Size(1400, 1000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);
    final env = await createTestEnv(balance: 400);
    await tester.pumpWidget(wrapApp(env, const ShopScreen()));
    await tester.pump(const Duration(milliseconds: 350));

    final list = tester.renderObject<RenderBox>(find.byType(ListView));
    expect(
      list.size.width,
      lessThanOrEqualTo(ShopScreen.maxContentWidth + 0.5),
      reason: 'the shop should not stretch a metre of glass',
    );
  });
}
