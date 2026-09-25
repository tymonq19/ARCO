import 'package:arco/services/api_client.dart';
import 'package:arco/ui/home_screen.dart';
import 'package:arco/ui/settings_screen.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// Renders the home screen with no best score in [language] on the narrowest
/// supported phone and asserts the empty-state message is laid out in full:
/// neither ellipsized nor clipped mid-word.
Future<void> expectWholeEmptyBestMessage(
  WidgetTester tester,
  String language,
  String message,
) async {
  useNarrowPhone(tester);
  final env = await createTestEnv(prefs: {'language': language});
  await tester.pumpWidget(wrapApp(env, const HomeScreen()));

  final finder = find.text(message);
  expect(finder, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  // No "..." at the end.
  expect(paragraph.didExceedMaxLines, isFalse);
  // And no word wider than the space it got, which would be clipped instead.
  expect(
    paragraph.getMinIntrinsicWidth(double.infinity),
    lessThanOrEqualTo(paragraph.size.width + 0.5),
  );
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('shows the menu, the best score and no layout overflow', (
    tester,
  ) async {
    useIPhoneSe(tester);
    final env = await createTestEnv(prefs: const {'bestScore': 4321});
    await tester.pumpWidget(wrapApp(env, const HomeScreen()));

    expect(find.text('ARCO'), findsOneWidget);
    expect(find.text('Keep the ball in the ring'), findsOneWidget);
    expect(find.text('SOLO'), findsOneWidget);
    expect(find.text('DUEL'), findsOneWidget);
    expect(find.text('LEADERBOARD'), findsOneWidget);
    expect(find.text('SETTINGS'), findsOneWidget);
    expect(find.text('Personal best'), findsOneWidget);
    expect(find.text('4321'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the ARCO wordmark stays on one line on a narrow phone at large '
      'text scale', (tester) async {
    useNarrowPhone(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(
      wrapApp(
        env,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: const HomeScreen(),
          ),
        ),
      ),
    );

    final title = find.text('ARCO');
    expect(title, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(title);
    // One short word, scaled down by the FittedBox rather than broken: a
    // single line, and no glyph clipped off the end of it.
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(
      paragraph.getMinIntrinsicWidth(double.infinity),
      lessThanOrEqualTo(paragraph.size.width + 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the ARCO wordmark is horizontally centred', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(wrapApp(env, const HomeScreen()));

    // letterSpacing puts no space after the last glyph in the measured line
    // width, so the centred box is the centred word: any nudge meant to
    // "cancel" that space (a Padding around the wordmark) instead shifts it
    // off-centre by half the letter-spacing, which is visible on a phone.
    final title = tester.getRect(find.text('ARCO'));
    final screen = tester.getRect(find.byType(HomeScreen));
    expect(title.center.dx, moreOrLessEquals(screen.center.dx, epsilon: 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('persists the nickname and flags an invalid one', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(wrapApp(env, const HomeScreen()));
    expect(find.text('Tester'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Neo_99');
    await tester.pump();
    expect(env.settings.playerName, 'Neo_99');
    expect(find.text('Invalid nickname'), findsNothing);

    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    expect(find.text('Invalid nickname'), findsOneWidget);
  });

  testWidgets('shows the Polish translation when the language is PL', (
    tester,
  ) async {
    useIPhoneSe(tester);
    final env = await createTestEnv(prefs: const {'language': 'pl'});
    await tester.pumpWidget(wrapApp(env, const HomeScreen()));
    expect(find.text('ZAGRAJ SOLO'), findsOneWidget);
    expect(find.text('POJEDYNEK'), findsOneWidget);
    expect(find.text('TABLICA WYNIKÓW'), findsOneWidget);
    expect(find.text('USTAWIENIA'), findsOneWidget);
    expect(find.text('Utrzymaj piłkę w kole'), findsOneWidget);
  });

  // SPEC 4.8: the wallet is on the title screen, and it is a glance rather than
  // an announcement — one quiet row that is also the way into the shop.
  testWidgets('shows the balance and the way into the shop', (tester) async {
    useTallPhone(tester);
    final env = await createTestEnv(balance: 240);

    await tester.pumpWidget(
      wrapApp(
        env,
        const HomeScreen(),
        routes: {'/shop': (_) => const ShopScreen()},
      ),
    );
    await tester.pump();

    expect(find.text('240 sparks'), findsOneWidget);
    expect(find.text('SHOP'), findsOneWidget);
    expect(find.text('Looks, balls and paddles'), findsOneWidget);

    await tester.tap(find.text('SHOP'));
    await tester.pumpAndSettle();
    expect(find.byType(ShopScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('says nothing about a wallet the server has never described', (
    tester,
  ) async {
    useTallPhone(tester);
    // No identity, so nothing is asked and no figure is invented: "0 sparks"
    // would be a claim about a wallet nobody has looked at.
    final env = await createTestEnv();

    await tester.pumpWidget(wrapApp(env, const HomeScreen()));
    await tester.pump();

    expect(find.text('Sparks'), findsOneWidget);
    expect(find.text('Play a run to start earning'), findsOneWidget);
    expect(find.text('0 sparks'), findsNothing);
    expect(env.api.shopCatalogueCalls, 0);
    expect(env.api.createPlayerCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigates to a named route', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(
      wrapApp(
        env,
        const HomeScreen(),
        routes: {SettingsScreen.route: (_) => const SettingsScreen()},
      ),
    );
    await tester.tap(find.text('SETTINGS'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('CONTROLS'), findsOneWidget);
  });

  testWidgets('shows the whole empty best message on a narrow phone (EN)', (
    tester,
  ) async {
    await expectWholeEmptyBestMessage(tester, 'en', 'No games played yet');
  });

  testWidgets('shows the whole empty best message on a narrow phone (PL)', (
    tester,
  ) async {
    await expectWholeEmptyBestMessage(
      tester,
      'pl',
      'Nie zagrano jeszcze żadnej gry',
    );
  });
  // SPEC 4.4 / 4.6: the standing is shown where it is free to show - one cached
  // read, no polling - and nothing about it ever asks the player to sign in.
  testWidgets('shows the global and national standing once there is one', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      prefs: const {'bestScore': 900},
      secrets: FakeSecretStore.withCredentials(testCredentials(7)),
    );
    env.api.profile = PlayerProfile(
      id: testPlayerId(7),
      name: 'Tester',
      bestScore: 900,
      rank: 12,
      games: 3,
      country: 'PL',
      countryBestScore: 900,
      countryRank: 2,
    );

    await tester.pumpWidget(wrapApp(env, const HomeScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Global rank'), findsOneWidget);
    expect(find.text('#12'), findsOneWidget);
    expect(find.text('Rank in \u{1F1F5}\u{1F1F1} PL'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
    expect(env.api.profileCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('says so when the player has an identity but no ranked run', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      secrets: FakeSecretStore.withCredentials(testCredentials(7)),
    );
    // SPEC 4.4: bestScore and rank are null exactly while games is 0 - which is
    // what a player whose first submission has not landed yet looks like.
    env.api.profile = PlayerProfile(id: testPlayerId(7), games: 0);

    await tester.pumpWidget(wrapApp(env, const HomeScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Global rank'), findsOneWidget);
    expect(find.text('Not ranked yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('asks nothing and shows no rank while the player is anonymous', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(prefs: const {'bestScore': 900});

    await tester.pumpWidget(wrapApp(env, const HomeScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Personal best'), findsOneWidget);
    expect(find.text('Global rank'), findsNothing);
    expect(env.api.profileCalls, 0);
    expect(env.api.createPlayerCalls, 0);
  });
}
