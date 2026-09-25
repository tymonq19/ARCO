import 'package:arco/ui/duel_lobby_screen.dart';
import 'package:arco/ui/widgets/code_display.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  testWidgets('creates a room and shows the code with the waiting state', (
    tester,
  ) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    final server = FakeDuelServer();
    await tester.pumpWidget(
      wrapApp(env, DuelLobbyScreen(connector: server.connect)),
    );

    expect(find.text('CREATE ROOM'), findsOneWidget);
    expect(find.text('JOIN'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);

    await tester.tap(find.text('CREATE ROOM'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CodeDisplay), findsOneWidget);
    expect(find.text('K'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('Q'), findsOneWidget);
    expect(find.text('Waiting for a friend…'), findsOneWidget);
    expect(find.text('COPY CODE'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(server.clientName, 'Tester');
    // 375 pt leaves room for the full-size tiles, so they must not shrink.
    // Each measured box is the 56-px tile plus its 5-px margins.
    final wideTiles = find.descendant(
      of: find.byType(CodeDisplay),
      matching: find.byType(Container),
    );
    expect(wideTiles, findsNWidgets(4));
    for (var i = 0; i < 4; i++) {
      expect(tester.getSize(wideTiles.at(i)).width, closeTo(56 + 10, 0.01));
    }
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows the room code inside the panel on a 320-pt phone', (
    tester,
  ) async {
    useNarrowPhone(tester);
    final env = await createTestEnv();
    final server = FakeDuelServer();
    await tester.pumpWidget(
      wrapApp(env, DuelLobbyScreen(connector: server.connect)),
    );

    await tester.tap(find.text('CREATE ROOM'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CodeDisplay), findsOneWidget);
    final area = tester.getRect(find.byType(CodeDisplay));
    final tiles = find.descendant(
      of: find.byType(CodeDisplay),
      matching: find.byType(Container),
    );
    expect(tiles, findsNWidgets(4));
    for (var i = 0; i < 4; i++) {
      final tile = tester.getRect(tiles.at(i));
      expect(tile.left, greaterThanOrEqualTo(area.left - 0.01));
      expect(tile.right, lessThanOrEqualTo(area.right + 0.01));
      // Shrunk to fit (box = tile + 10 px of margin), but still big enough
      // to read out loud.
      expect(tile.width - 10, greaterThanOrEqualTo(40));
      expect(tile.width - 10, lessThanOrEqualTo(56));
    }
    // All four letters are laid out, none of them clipped away.
    for (final c in const ['K', 'X', '7', 'Q']) {
      final letter = tester.getRect(find.text(c));
      expect(letter.left, greaterThanOrEqualTo(area.left - 0.01));
      expect(letter.right, lessThanOrEqualTo(area.right + 0.01));
    }
    // A RenderFlex overflow would have been reported by now.
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('filters and uppercases the join code', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    final server = FakeDuelServer(slot: 1);
    await tester.pumpWidget(
      wrapApp(env, DuelLobbyScreen(connector: server.connect)),
    );

    await tester.tap(find.text('JOIN'));
    await tester.pump();
    expect(find.text('Join a room'), findsOneWidget);

    // 0, O, I and punctuation are not in the code alphabet.
    await tester.enterText(find.byType(TextField), 'k-x0i7qz');
    await tester.pump();
    expect(find.text('KX7Q'), findsOneWidget);

    await tester.tap(find.text('JOIN').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(server.received.length, greaterThanOrEqualTo(2));
    expect(server.code, 'KX7Q');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rejects an invalid nickname before connecting', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv(prefs: const {'playerName': 'x'});
    final server = FakeDuelServer();
    await tester.pumpWidget(
      wrapApp(env, DuelLobbyScreen(connector: server.connect)),
    );
    await tester.tap(find.text('CREATE ROOM'));
    await tester.pump();
    expect(find.text('Invalid nickname'), findsOneWidget);
    expect(server.received, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
