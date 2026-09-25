import 'package:arco/game/render/game_view.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/ui/solo_screen.dart';
import 'package:arco/ui/widgets/neon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  testWidgets('starts on tap, runs the arena and pauses', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(wrapApp(env, const SoloScreen()));

    expect(find.byType(GameView), findsOneWidget);
    expect(find.text('TAP TO START'), findsNWidgets(2));
    expect(find.text('SCORE'), findsOneWidget);
    expect(find.text('BEST'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);

    await tester.tap(find.text('TAP TO START').last);
    await pumpFrames(tester, 5);
    expect(find.text('TAP TO START'), findsNothing);

    // Run past the first serve so the ball is live.
    await pumpFrames(tester, 80);
    expect(tester.takeException(), isNull);

    // Pause and resume through the HUD button.
    await tester.tap(find.byType(NeonIconButton));
    await tester.pump();
    expect(find.text('PAUSED'), findsOneWidget);
    await tester.tap(find.text('RESUME'));
    await tester.pump();
    expect(find.text('PAUSED'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows the control hint for the selected scheme', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv(prefs: const {'controlMode': 'follow'});
    await tester.pumpWidget(wrapApp(env, const SoloScreen()));
    expect(find.text('Tap where you want the paddle to go'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HUD clock stays on one line on a narrow phone at large text '
      'scale', (tester) async {
    useNarrowPhone(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(
      wrapApp(
        env,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: const SoloScreen(),
          ),
        ),
      ),
    );

    final clock = find.text('00:00');
    expect(clock, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(clock);
    final oneLineHeight = paragraph.getMinIntrinsicHeight(double.infinity);
    final unwrappedWidth = paragraph.getMaxIntrinsicWidth(double.infinity);
    expect(
      paragraph.size.height,
      lessThanOrEqualTo(oneLineHeight + 0.5),
      reason: 'the clock wrapped onto a second line',
    );
    expect(
      paragraph.size.width,
      greaterThanOrEqualTo(unwrappedWidth - 0.5),
      reason: 'the clock is clipped',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
  // SPEC 4.7: the one refusal the player can act on. The run was verified and
  // is kept, so a different nickname is all that is missing - and the score
  // must not be lost on the way.
  testWidgets('a refused nickname can be changed from the game-over panel', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv();
    env.api.submitResults.add(
      const SubmitResult.rejected(error: offensiveNameError, statusCode: 400),
    );
    await tester.pumpWidget(wrapApp(env, const SoloScreen()));
    await tester.tap(find.text('TAP TO START').last);

    // No input at all: the paddle never moves, so the three lives go quickly
    // and the game ends on its own.
    for (var i = 0; i < 6000 && env.api.submitCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(env.api.submitCalls, 1, reason: 'the game never ended');
    await pumpFrames(tester, 4);

    expect(
      find.textContaining('That nickname cannot go on the leaderboard'),
      findsOneWidget,
    );
    expect(
      env.storage.pendingReplay,
      isNotNull,
      reason: 'the verified run is kept while the name is sorted out',
    );

    await tester.tap(find.text('CHANGE NICKNAME'));
    await pumpFrames(tester, 20);
    expect(find.byType(Dialog), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Polite');
    await pumpFrames(tester, 4);
    await tester.tap(find.text('SAVE'));
    await pumpFrames(tester, 20);

    expect(env.api.submitCalls, 2);
    expect(env.settings.playerName, 'Polite');
    expect(env.storage.pendingReplay, isNull);
    expect(find.textContaining('Global rank'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  // SPEC 4.8: what a run earned is part of the result, next to the score, and it
  // is the number the **server** computed from the replay it verified.
  testWidgets('a run that earned sparks shows them beside the score', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    env.api.profile = PlayerProfile(id: testPlayerId(1), games: 1);
    env.api.shopBalance = 124;
    env.api.shopEarnedToday = 24;
    env.api.submitResult = SubmitResult.accepted(
      id: 'id-1',
      score: 2400,
      rank: 3,
      playerId: testPlayerId(1),
      tokens: 24,
      tokenBalance: 124,
    );

    await tester.pumpWidget(wrapApp(env, const SoloScreen()));
    await tester.tap(find.text('TAP TO START').last);
    for (var i = 0; i < 6000 && env.api.submitCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(env.api.submitCalls, 1, reason: 'the game never ended');
    await pumpFrames(tester, 12);

    expect(find.text('+24'), findsOneWidget);
    expect(
      find.textContaining('resets at midnight UTC'),
      findsNothing,
      reason: 'the cap has not been reached, so there is nothing to explain',
    );
    // The wallet followed, so the title screen shows it without another request.
    expect(env.shop.balance, 124);
    expect(env.shop.snapshot.earnedToday, 24);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  // SPEC 4.9: one rule across the app — a Spark figure appears where it can be
  // acted on. A player who bought the unlock owns everything sparks could buy, so
  // the run's reward chip is not shown to them. The server still credits it, and a
  // revoked entitlement brings the figure back with everything earned meanwhile.
  testWidgets('a run by a player who bought the unlock shows no spark chip', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      premium: true,
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    env.api.profile = PlayerProfile(id: testPlayerId(1), games: 1);
    env.api.shopBalance = 124;
    env.api.shopEarnedToday = 200;
    env.api.shopDailyCap = 200;
    env.api.submitResult = SubmitResult.accepted(
      id: 'id-1',
      score: 2400,
      rank: 3,
      playerId: testPlayerId(1),
      tokens: 24,
      tokenBalance: 124,
    );

    await tester.pumpWidget(wrapApp(env, const SoloScreen()));
    await tester.tap(find.text('TAP TO START').last);
    for (var i = 0; i < 6000 && env.api.submitCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(env.api.submitCalls, 1, reason: 'the game never ended');
    await pumpFrames(tester, 12);

    expect(find.text('+24'), findsNothing);
    expect(
      find.textContaining('resets at midnight UTC'),
      findsNothing,
      reason:
          'an allowance with nothing to spend it on is not worth a sentence',
    );
    // The result itself is exactly where it was: the run still happened, and it
    // still says so.
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data == 'GAME OVER' || w.data == 'NEW BEST!'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Best:'), findsOneWidget);
    expect(
      env.shop.balance,
      124,
      reason: 'the server credited it; only the readout is gone',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a run that earned nothing because of the daily cap says so', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    env.api.profile = PlayerProfile(id: testPlayerId(1), games: 9);
    env.api.shopEarnedToday = 200;
    env.api.shopDailyCap = 200;
    env.api.shopBalance = 640;
    env.api.submitResult = SubmitResult.accepted(
      id: 'id-1',
      score: 3000,
      rank: 3,
      playerId: testPlayerId(1),
      tokens: 0,
      tokenBalance: 640,
    );

    await tester.pumpWidget(wrapApp(env, const SoloScreen()));
    await tester.tap(find.text('TAP TO START').last);
    for (var i = 0; i < 6000 && env.api.submitCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await pumpFrames(tester, 12);

    // No "+0": nothing was earned, and a zero dressed as a reward is a lie.
    expect(find.text('+0'), findsNothing);
    expect(
      find.textContaining('You have earned today\'s 200 sparks'),
      findsOneWidget,
    );
    expect(find.textContaining('resets at midnight UTC'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an offline game says nothing about sparks it did not earn', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv();
    env.api.offline = true;

    await tester.pumpWidget(wrapApp(env, const SoloScreen()));
    await tester.tap(find.text('TAP TO START').last);
    for (var i = 0; i < 6000 && env.api.submitCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await pumpFrames(tester, 8);

    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
    expect(env.shop.balanceKnown, isFalse);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
