import 'package:arco_core/arco_core.dart';
import 'package:arco/game/controllers/duel_controller.dart';
import 'package:arco/game/render/game_view.dart';
import 'package:arco/services/duel_client.dart';
import 'package:arco/ui/duel_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

DuelController buildController(TestEnv env, FakeDuelServer server) {
  return DuelController(
    client: DuelClient(
      wsUri: () => Uri.parse('ws://fake.local/ws'),
      connector: server.connect,
    ),
    settings: env.settings,
    audio: env.audio,
    haptics: env.haptics,
    input: FakeInput(),
  );
}

/// Connects and starts a match. Everything is driven with `tester.pump` so the
/// binding's fake clock keeps the futures moving.
Future<void> startMatch(
  WidgetTester tester,
  DuelController controller,
  FakeDuelServer server, {
  bool join = false,
  int countdown = 120,
  String name = 'Tester',
}) async {
  final connecting = join
      ? controller.joinRoom(name, 'KX7Q')
      : controller.createRoom(name);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
  await connecting;
  server.start(countdown: countdown);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  testWidgets('shows both HUDs, the countdown and the win overlay', (
    tester,
  ) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    final server = FakeDuelServer();
    final controller = buildController(env, server);
    await tester.pumpWidget(wrapApp(env, DuelScreen(controller: controller)));
    await startMatch(tester, controller, server);

    expect(find.byType(GameView), findsOneWidget);
    expect(find.text('Tester'), findsOneWidget);
    expect(find.text('Rival'), findsOneWidget);
    expect(controller.rotated, isFalse);
    expect(controller.hasMatch, isTrue);
    expect(controller.fx.countdownLabel, isNotNull);

    // Play a few frames: the countdown runs out, then the simulation starts.
    await pumpFrames(tester, 140);
    expect(controller.inCountdown, isFalse);
    expect(controller.state!.tick, greaterThan(0));
    expect(tester.takeException(), isNull);

    server.over(winner: 0, scores: const [220, 80]);
    await tester.pump();
    await tester.pump();
    expect(find.text('YOU WIN'), findsOneWidget);
    expect(find.text('220'), findsOneWidget);
    expect(find.text('80'), findsOneWidget);
    expect(find.text('REMATCH'), findsOneWidget);
    expect(find.text('LEAVE'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('player 1 renders rotated and can lose', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    final server = FakeDuelServer(slot: 1, peerName: 'Host');
    final controller = buildController(env, server);
    await tester.pumpWidget(wrapApp(env, DuelScreen(controller: controller)));
    await startMatch(tester, controller, server, join: true, countdown: 0);

    expect(controller.slot, 1);
    expect(controller.rotated, isTrue);
    expect(find.text('Host'), findsOneWidget);
    await pumpFrames(tester, 10);

    server.over(winner: 0, scores: const [90, 30]);
    await tester.pump();
    await tester.pump();
    expect(find.text('YOU LOSE'), findsOneWidget);
    // Own score is shown on the left, the opponent's on the right.
    expect(find.text('30'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('maximum-length names and long scores never overflow', (
    tester,
  ) async {
    // Narrowest supported phone, both nicknames at the protocol maximum
    // (nameMaxLength = 12) and five-digit scores: the HUD strips and the
    // result panel must truncate, not overflow.
    useNarrowPhone(tester);
    final env = await createTestEnv();
    final server = FakeDuelServer(peerName: 'Konstantynaa');
    final controller = buildController(env, server);
    await tester.pumpWidget(wrapApp(env, DuelScreen(controller: controller)));
    await startMatch(
      tester,
      controller,
      server,
      countdown: 0,
      name: 'Maksymiliann',
    );
    await pumpFrames(tester, 5);
    // Both HUD strips are on screen with the long names laid out.
    expect(find.text('Maksymiliann'), findsOneWidget);
    expect(find.text('Konstantynaa'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // A snapshot with five-digit scores: the name must give way to the score
    // block instead of pushing the strip past the screen edge.
    final snapshot = GameState.initial(
      const GameConfig(mode: GameMode.duel, seed: 424242),
    );
    snapshot.tick = controller.state!.tick + 1;
    snapshot.players[0].score = 41230;
    snapshot.players[1].score = 39870;
    server.snap(snapshot);
    await tester.pump();
    await tester.pump();
    expect(find.text('41230'), findsOneWidget);
    expect(find.text('39870'), findsOneWidget);
    expect(tester.takeException(), isNull);

    server.over(winner: 0, scores: const [41230, 39870]);
    await tester.pump();
    await tester.pump();
    // Once the overlay is up each score is on screen twice: HUD + panel.
    expect(find.text('YOU WIN'), findsOneWidget);
    expect(find.text('41230'), findsNWidgets(2));
    expect(find.text('39870'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('shows the peer-left overlay', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    final server = FakeDuelServer();
    final controller = buildController(env, server);
    await tester.pumpWidget(wrapApp(env, DuelScreen(controller: controller)));
    await startMatch(tester, controller, server, countdown: 0);
    await pumpFrames(tester, 5);

    server.peerLeft();
    await tester.pump();
    await tester.pump();
    expect(find.text('Your opponent left the game'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
