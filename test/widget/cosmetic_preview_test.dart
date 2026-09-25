import 'package:arco/app/game_theme.dart';
import 'package:arco/game/render/ball_art.dart';
import 'package:arco/game/render/cosmetic_preview.dart';
import 'package:arco/game/render/fx_state.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [child] centred on a plain surface, with no app shell above it: a shop
/// card has to work anywhere, including before a theme has been provided.
Future<void> pumpBare(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

const List<String> catalogueItems = [
  'ball.orb',
  'ball.comet',
  'ball.prism',
  'ball.ember',
  'paddle.arc',
  'paddle.blade',
  'paddle.halo',
  'paddle.chevron',
];

void main() {
  for (final theme in GameThemes.all) {
    final name = theme.id.name;

    testWidgets('every item previews at card size ($name)', (tester) async {
      for (final item in catalogueItems) {
        await pumpBare(
          tester,
          CosmeticPreview(itemId: item, theme: theme, label: item),
        );
        final box = tester.getSize(find.byType(CosmeticPreview));
        expect(box.width, CosmeticPreview.defaultWidth, reason: item);
        expect(box.height, CosmeticPreview.defaultHeight, reason: item);
        expect(find.byType(CosmeticArena), findsOneWidget);
        expect(find.text(theme.heading(item)), findsOneWidget);
        // The illustration is a recorded picture, never a live blur.
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull, reason: item);
      }
    });

    testWidgets('every item previews selected, in a tight grid cell ($name)', (
      tester,
    ) async {
      for (final item in catalogueItems) {
        await pumpBare(
          tester,
          CosmeticPreview(
            itemId: item,
            theme: theme,
            width: 104,
            height: 92,
            label: item.split('.').last,
            selected: true,
            onTap: () {},
          ),
        );
        expect(
          tester.getSize(find.byType(CosmeticPreview)),
          const Size(104, 92),
        );
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(tester.takeException(), isNull, reason: item);
      }
    });

    testWidgets('a bare illustration fills its box, at any zoom ($name)', (
      tester,
    ) async {
      for (final item in ['ball.ember', 'paddle.chevron']) {
        for (final zoom in [1.0, 3.0]) {
          await pumpBare(
            tester,
            SizedBox(
              width: 88,
              height: 64,
              child: CosmeticArena(
                itemId: item,
                theme: theme,
                magnification: zoom,
              ),
            ),
          );
          expect(
            tester.getSize(find.byType(CosmeticArena)),
            const Size(88, 64),
          );
          expect(tester.takeException(), isNull, reason: '$item at $zoom');
        }
      }
    });
  }

  testWidgets('a tap on a card reports the choice', (tester) async {
    var taps = 0;
    await pumpBare(
      tester,
      CosmeticPreview(
        itemId: 'ball.comet',
        theme: GameThemes.glass,
        label: 'Comet',
        onTap: () => taps++,
      ),
    );
    await tester.tap(find.byType(CosmeticPreview));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('an id this build cannot draw still renders something', (
    tester,
  ) async {
    // A theme id, and an item from a server newer than this build. A shop grid
    // must degrade to the free default, never throw.
    for (final id in ['theme.glass', 'ball.supernova', '']) {
      await pumpBare(
        tester,
        CosmeticPreview(itemId: id, theme: GameThemes.neon),
      );
      expect(find.byType(CosmeticArena), findsOneWidget, reason: id);
      expect(tester.takeException(), isNull, reason: id);
    }
  });

  testWidgets('a card without a label gives the whole box to the arena', (
    tester,
  ) async {
    await pumpBare(
      tester,
      const CosmeticPreview(itemId: 'paddle.halo', theme: GameThemes.neon),
    );
    expect(find.byType(Text), findsNothing);
    expect(
      tester.getSize(find.byType(CosmeticArena)).height,
      CosmeticPreview.defaultHeight,
    );
  });

  test('the shared poses are what the cards promise', () {
    final ball = ballPose();
    // A ball in flight, a seeded wake and nothing else on the board: a ball card
    // is about the ball.
    expect(ball.ball.active, isTrue);
    expect(ball.walls, isEmpty);
    expect(ball.pickups, isEmpty);
    expect(ballPoseFx().trailCount, FxState.trailLength);
    expect(ballPoseFx().hasBall, isTrue);
    // Far enough into the run that an ember's whole shower is alight.
    expect(ballPoseFx().frames, greaterThan(EmberBallArt.sparkLifeFrames));

    // The paddle pose has no ball at all, so nothing crosses the paddle.
    final paddle = paddlePose();
    expect(paddle.ball.active, isFalse);
    expect(paddle.players.single.paddle.angle, bottomCenterAngle);
    expect(paddlePoseFx().trailCount, 0);

    // Both are built once and shared.
    expect(ballPose(), same(ball));
    expect(paddlePose(), same(paddle));
    expect(ballPoseFx(), same(ballPoseFx()));
  });

  test('a card knows which pose an id needs', () {
    expect(CosmeticCard.forItem('ball.prism'), CosmeticCard.ball);
    expect(CosmeticCard.forItem('paddle.blade'), CosmeticCard.paddle);
    expect(CosmeticCard.forItem('theme.neon'), CosmeticCard.ball);
  });
}
