import 'package:arco/app/game_theme.dart';
import 'package:arco/app/settings.dart';
import 'package:arco/main.dart';
import 'package:arco/services/storage.dart';
import 'package:arco/ui/home_screen.dart';
import 'package:arco/ui/onboarding_screen.dart';
import 'package:arco/ui/widgets/neon_button.dart';
import 'package:arco/ui/widgets/neon_panel.dart';
import 'package:arco/ui/widgets/shop_card.dart';
import 'package:arco/ui/widgets/theme_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_env.dart';

/// The English nickname rule, shown as the field's helper and, when the name
/// breaks it, as its error.
const String nicknameRule = '2–12 characters: letters, digits, space, _ or -';

/// The card captions, which each card sets in its *own* theme's heading case.
const Map<ThemeId, String> cardLabel = {
  ThemeId.neon: 'NEON',
  ThemeId.classic: 'CLASSIC',
  ThemeId.modernist: 'Modernist',
  ThemeId.glass: 'Glass',
};

/// Scrolls [finder] into view, then taps it: the welcome screen is taller than
/// a phone once the four cards are on it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// The one continue button, so a test can read whether it is enabled.
NeonButton continueButton(WidgetTester tester) => tester.widget<NeonButton>(
  find.ancestor(
    of: find.text('START PLAYING'),
    matching: find.byType(NeonButton),
  ),
);

/// The distinct rows the theme cards are laid out in.
///
/// Measured from each card's centre, not its top: the unselected cards are
/// scaled down about their centre, which leaves the centres of one row aligned
/// while the tops are not.
Set<double> cardRows(WidgetTester tester) => tester
    .widgetList<ThemePreview>(find.byType(ThemePreview))
    .map((p) => (tester.getCenter(find.byWidget(p)).dy * 10).round() / 10)
    .toSet();

/// The overlay style the welcome screen is asking the platform for.
///
/// The app shell posts one of these too, so the *deepest* one wins — and that
/// is the screen's own, keyed to the look being previewed rather than to the
/// one still in storage.
SystemUiOverlayStyle overlayStyle(WidgetTester tester) => tester
    .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
    )
    .last
    .value;

/// A context inside the screen's own theme subtree.
BuildContext screenContext(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first);

/// Runs the whole app, as `main()` does.
Future<void> pumpApp(WidgetTester tester, TestEnv env) async {
  await tester.pumpWidget(
    ArcoApp(storage: env.storage, settings: env.settings, audio: env.audio),
  );
  await tester.pump();
}

/// A fresh [Settings] over the same preferences store, i.e. a real relaunch.
Future<Settings> relaunch() async {
  SharedPreferences.resetStatic();
  return Settings(await Storage.load());
}

void main() {
  testWidgets('the status bar follows the look being previewed', (
    tester,
  ) async {
    useTallPhone(tester);
    // Both paid looks owned, so both can be tried on: a look that has not been
    // bought is locked (SPEC 4.8) and there is nothing to preview.
    final env = await createTestEnv(
      playerName: null,
      owned: const {'theme.modernist', 'theme.glass'},
    );
    await pumpApp(tester, env);
    expect(find.byType(OnboardingScreen), findsOneWidget);

    expect(
      overlayStyle(tester).statusBarIconBrightness,
      Brightness.light,
      reason: 'Neon is dark, so the clock and the battery must be light',
    );

    await tapVisible(tester, find.text(cardLabel[ThemeId.modernist]!));
    await tester.pumpAndSettle();
    expect(
      overlayStyle(tester).statusBarIconBrightness,
      Brightness.dark,
      reason:
          'nothing is persisted while browsing, so only the screen can ask '
          'for dark glyphs on Modernist paper',
    );

    await tapVisible(tester, find.text(cardLabel[ThemeId.glass]!));
    await tester.pumpAndSettle();
    expect(overlayStyle(tester).statusBarIconBrightness, Brightness.light);
  });

  testWidgets('a first launch opens the welcome screen, a second one does not', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      playerName: null,
      owned: const {'theme.modernist'},
    );
    expect(env.settings.onboarded, isFalse);

    await pumpApp(tester, env);
    expect(find.byType(OnboardingScreen), findsOneWidget);
    // The welcome screen replaces home rather than covering it: home reads the
    // nickname once, in initState, so it must not be built first.
    expect(find.byType(HomeScreen), findsNothing);

    await tapVisible(tester, find.text(cardLabel[ThemeId.modernist]!));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('START PLAYING'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);

    // A relaunch over the same store goes straight home.
    await tester.pumpWidget(const SizedBox());
    final settings = await relaunch();
    expect(settings.onboarded, isTrue);
    expect(settings.themeId, ThemeId.modernist);
    await tester.pumpWidget(
      ArcoApp(
        storage: await Storage.load(),
        settings: settings,
        audio: env.audio,
      ),
    );
    await tester.pump();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });

  testWidgets('a stored nickname without the flag is not onboarded again', (
    tester,
  ) async {
    useTallPhone(tester);
    // What a build older than this screen left behind: a persisted nickname and
    // no 'onboarded' key at all.
    final env = await createTestEnv(playerName: 'Veteran');
    expect(env.storage.getBool('onboarded'), isTrue, reason: 'written back');
    expect(env.settings.onboarded, isTrue);

    await pumpApp(tester, env);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(env.settings.playerName, 'Veteran');
  });

  testWidgets('the screen shows the wordmark, four looks and a nickname', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(playerName: null);
    await tester.pumpWidget(wrapApp(env, const OnboardingScreen()));

    expect(find.text('ARCO'), findsOneWidget);
    expect(find.text('Welcome! Pick a look and a name.'), findsOneWidget);
    expect(find.text('CHOOSE A LOOK'), findsOneWidget);
    expect(find.byType(ThemePreview), findsNWidgets(GameThemes.themeCount));
    for (final label in cardLabel.values) {
      expect(find.text(label), findsOneWidget, reason: 'card "$label"');
    }
    // The generated nickname is pre-filled, so continuing is enough.
    expect(find.text(env.settings.playerName), findsOneWidget);
    expect(find.text(nicknameRule), findsWidgets);
    expect(find.text('Both can be changed later.'), findsOneWidget);
    expect(continueButton(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a look repaints the screen in it, and only there', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      playerName: null,
      owned: const {'theme.modernist'},
    );
    await tester.pumpWidget(wrapApp(env, const OnboardingScreen()));

    expect(GameTheme.read(screenContext(tester)).id, ThemeId.neon);
    expect(find.byType(NeonBackground), findsOneWidget);

    await tapVisible(tester, find.text(cardLabel[ThemeId.modernist]!));

    // Mid-dissolve both backdrops are on screen: the look changes by fading,
    // not by cutting.
    expect(GameTheme.read(screenContext(tester)).id, ThemeId.modernist);
    expect(find.byType(NeonBackground), findsNWidgets(2));

    // Settle rather than pumping exactly the duration: an interpolation
    // simulation is only "done" one frame past its end.
    await tester.pumpAndSettle();
    expect(find.byType(NeonBackground), findsOneWidget);
    expect(
      Theme.of(screenContext(tester)).scaffoldBackgroundColor,
      GameThemes.modernist.background,
    );
    // Modernist sets headings in normal case, so the section label followed.
    expect(find.text('Choose a look'), findsOneWidget);
    expect(find.text('CHOOSE A LOOK'), findsNothing);

    // Nothing is committed until the player continues, so quitting here leaves
    // the stored look alone.
    expect(env.settings.themeId, ThemeId.neon);
    expect(env.storage.getString('theme'), isNull);
    expect(env.settings.onboarded, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invalid nickname disables continue, a valid one enables it', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(playerName: null);
    await tester.pumpWidget(wrapApp(env, const OnboardingScreen()));
    expect(continueButton(tester).onPressed, isNotNull);

    for (final bad in ['x', '', '   ', 'Neo!']) {
      await tester.enterText(find.byType(TextField), bad);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        continueButton(tester).onPressed,
        isNull,
        reason: '"$bad" should not be accepted',
      );
      // Not a silent block: the rule stays on screen and turns into the error.
      expect(find.text(nicknameRule), findsWidgets);
    }

    await tester.enterText(find.byType(TextField), 'Neo_99');
    await tester.pump(const Duration(milliseconds: 300));
    expect(continueButton(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('continuing persists the look, the nickname and the flag', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      playerName: null,
      owned: const {'theme.glass'},
    );
    await pumpApp(tester, env);

    await tapVisible(tester, find.text(cardLabel[ThemeId.glass]!));
    await tester.pumpAndSettle();
    // Deliberately messy: the stored name is the normalized one, which is what
    // the server would accept and the leaderboard would show.
    await tester.enterText(find.byType(TextField), '  Neo   99 ');
    await tester.pump();
    await tapVisible(tester, find.text('START PLAYING'));
    await tester.pumpAndSettle();

    expect(env.settings.playerName, 'Neo 99');
    expect(env.settings.themeId, ThemeId.glass);
    expect(env.settings.onboarded, isTrue);
    expect(env.storage.getString('playerName'), 'Neo 99');
    expect(env.storage.getString('theme'), 'glass');
    expect(env.storage.getBool('onboarded'), isTrue);
    // And the home screen opened on the chosen name and look.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Neo 99'), findsOneWidget);
    expect(
      Theme.of(screenContext(tester)).scaffoldBackgroundColor,
      GameThemes.glass.background,
    );
  });

  testWidgets('speaks Polish', (tester) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      playerName: null,
      prefs: const {'language': 'pl'},
    );
    await tester.pumpWidget(wrapApp(env, const OnboardingScreen()));

    expect(find.text('Witaj! Wybierz motyw i pseudonim.'), findsOneWidget);
    expect(find.text('WYBIERZ MOTYW'), findsOneWidget);
    expect(find.text('Twój pseudonim'), findsOneWidget);
    expect(find.text('ZACZNIJ GRAĆ'), findsOneWidget);
    expect(find.text('Oba możesz zmienić później.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final theme in GameThemes.all) {
    testWidgets('fits 320x568 at 1.6 text scale (${theme.id.name})', (
      tester,
    ) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(playerName: null, theme: theme.id);
      await tester.pumpWidget(
        wrapApp(
          env,
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: const OnboardingScreen(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // Everything is reachable by scrolling, nothing is painted outside its
      // box, and no card is squeezed below the design's floor.
      expect(find.byType(ThemePreview), findsNWidgets(GameThemes.themeCount));
      for (final preview in tester.widgetList<ThemePreview>(
        find.byType(ThemePreview),
      )) {
        expect(preview.width, greaterThanOrEqualTo(100));
        expect(preview.width, lessThanOrEqualTo(ThemePreview.defaultWidth));
      }
      // Two by two on a 320 pt phone, so all four looks are visible at once
      // without a sideways gesture.
      expect(cardRows(tester), hasLength(2), reason: 'expected a 2x2 grid');

      await tester.ensureVisible(find.text('START PLAYING'));
      await tester.pump();
      expect(continueButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('lays the four looks out in one row when they fit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final env = await createTestEnv(playerName: null);
    await tester.pumpWidget(wrapApp(env, const OnboardingScreen()));

    expect(
      cardRows(tester),
      hasLength(1),
      reason: 'expected a single centred row',
    );
    expect(tester.takeException(), isNull);
  });

  // SPEC 4.8: a genuine first launch owns the free looks and nothing else. The
  // paid ones are shown — they are worth wanting — but locked, and a locked card
  // answers no tap, because at the welcome screen there is nothing to buy with.
  testWidgets('a first launch offers the free looks and says where the others '
      'come from', (tester) async {
    useTallPhone(tester);
    final env = await createTestEnv(playerName: null);
    await tester.pumpWidget(wrapApp(env, const OnboardingScreen()));
    await tester.pump();

    expect(find.byType(ThemePreview), findsNWidgets(GameThemes.themeCount));
    expect(find.byType(LockBadge), findsNWidgets(2));
    expect(
      find.text('More looks unlock in the shop as you play.'),
      findsOneWidget,
    );

    final cards = tester.widgetList<ThemePreview>(find.byType(ThemePreview));
    for (final card in cards) {
      final free =
          card.theme.id == ThemeId.neon || card.theme.id == ThemeId.classic;
      expect(
        card.onTap != null,
        free,
        reason: '${card.theme.id.name} should ${free ? '' : 'not '}be offered',
      );
    }

    // Tapping a locked look changes nothing at all: no look, no navigation.
    await tapVisible(tester, find.text(cardLabel[ThemeId.glass]!));
    await tester.pumpAndSettle();
    expect(GameTheme.read(screenContext(tester)).id, ThemeId.neon);
    expect(env.settings.themeId, ThemeId.neon);
    expect(tester.takeException(), isNull);

    // And the free one is still a normal choice.
    await tapVisible(tester, find.text(cardLabel[ThemeId.classic]!));
    await tester.pumpAndSettle();
    expect(GameTheme.read(screenContext(tester)).id, ThemeId.classic);
  });

  testWidgets('every look is offered to a player who owns them all', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(
      playerName: null,
      owned: const {'theme.modernist', 'theme.glass'},
    );
    await tester.pumpWidget(wrapApp(env, const OnboardingScreen()));
    await tester.pump();

    expect(find.byType(LockBadge), findsNothing);
    expect(
      find.text('More looks unlock in the shop as you play.'),
      findsNothing,
    );
    for (final card in tester.widgetList<ThemePreview>(
      find.byType(ThemePreview),
    )) {
      expect(card.onTap, isNotNull, reason: card.theme.id.name);
    }
  });
}
