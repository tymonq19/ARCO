import 'package:arco/app/game_theme.dart';
import 'package:arco/game/render/fx_state.dart';
import 'package:arco/ui/widgets/theme_preview.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [child] centred on a plain surface, with no app shell above it: the
/// preview must work anywhere, including a first-launch chooser that runs before
/// any theme has been chosen.
Future<void> pumpBare(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  for (final theme in GameThemes.all) {
    final name = theme.id.name;

    testWidgets('ThemePreview builds at its design size ($name)', (
      tester,
    ) async {
      await pumpBare(
        tester,
        ThemePreview(theme: theme, label: 'Sample', selected: false),
      );
      final box = tester.getSize(find.byType(ThemePreview));
      expect(box.width, ThemePreview.defaultWidth);
      expect(box.height, ThemePreview.defaultHeight);
      expect(find.byType(ThemeArena), findsOneWidget);
      // The caption is set in the theme's own heading case.
      expect(find.text(theme.heading('Sample')), findsOneWidget);
      // The illustration is a recorded picture, never a live blur.
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ThemePreview builds selected at the picker size ($name)', (
      tester,
    ) async {
      await pumpBare(
        tester,
        ThemePreview(
          theme: theme,
          width: 124,
          height: 182,
          label: 'Sample',
          selected: true,
          onTap: () {},
        ),
      );
      expect(tester.getSize(find.byType(ThemePreview)), const Size(124, 182));
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ThemeArena fills a bare box ($name)', (tester) async {
      await pumpBare(
        tester,
        SizedBox(width: 90, height: 90, child: ThemeArena(theme: theme)),
      );
      expect(tester.getSize(find.byType(ThemeArena)), const Size(90, 90));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a tap on a preview reports the choice', (tester) async {
    var taps = 0;
    await pumpBare(
      tester,
      ThemePreview(
        theme: GameThemes.glass,
        label: 'Glass',
        onTap: () => taps++,
      ),
    );
    await tester.tap(find.byType(ThemePreview));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('a preview without a label gives the whole card to the arena', (
    tester,
  ) async {
    await pumpBare(tester, const ThemePreview(theme: GameThemes.neon));
    expect(find.byType(Text), findsNothing);
    expect(
      tester.getSize(find.byType(ThemeArena)).height,
      ThemePreview.defaultHeight,
    );
  });

  test('the shared pose really contains what a preview promises', () {
    final state = previewState();
    // A paddle, a live ball, one wall and one star — the five things the
    // illustration is meant to show, in the real simulation's own types.
    expect(state.players, hasLength(1));
    expect(state.ball.active, isTrue);
    expect(state.walls, hasLength(1));
    expect(state.walls.single.solid, isTrue);
    expect(state.pickups.single.type, PickupType.star);
    expect(state.phase, Phase.playing);
    // The wake is seeded from the ball's own velocity, so it is a real trail.
    expect(previewFx().trailCount, FxState.trailLength);
    // And it is shared: building a second preview does not rebuild the pose.
    expect(previewState(), same(state));
    expect(previewFx(), same(previewFx()));
  });
}
