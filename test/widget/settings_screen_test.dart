import 'package:arco/app/game_theme.dart';
import 'package:arco/app/server_config.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/app/settings.dart';
import 'package:arco/ui/widgets/shop_card.dart';
import 'package:arco/ui/widgets/theme_preview.dart';
import 'package:arco/ui/settings_screen.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/contrast.dart';
import '../helpers/test_env.dart';

/// Jumps the settings list to its end; deterministic where a fling is not.
///
/// A lazy [ListView] only estimates its extent from the children it has laid
/// out, so the jump is repeated until the maximum stops growing.
Future<void> scrollToBottom(WidgetTester tester) async {
  var previous = -1.0;
  for (var i = 0; i < 10; i++) {
    final scrollable = tester.firstState<ScrollableState>(
      find.byType(Scrollable),
    );
    final max = scrollable.position.maxScrollExtent;
    if (max == previous) return;
    previous = max;
    scrollable.position.jumpTo(max);
    await tester.pump();
  }
}

/// Text anywhere in the settings list, whether or not it is scrolled into view.
///
/// The list opens on the theme previews, so the rows below them start off
/// screen; a lazy sliver keeps them built (see the list's `cacheExtent`) but
/// [CommonFinders.text] skips anything the sliver is not painting.
Finder listText(String text) => find.text(text, skipOffstage: false);

/// Scrolls [finder] into view so it can be tapped or measured.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  expect(finder, findsWidgets, reason: 'nothing to reveal for $finder');
  await tester.ensureVisible(finder.first);
  await tester.pump();
}

/// Every settings control sits on a panel, i.e. on the theme's panel fill.
double contrastOnPanel(Color fg) =>
    contrastRatio(fg, GameThemes.neon.panelFill);

/// The outline of the 44 px `_choice` segment that carries [label].
BorderSide segmentBorder(WidgetTester tester, String label) {
  final containers = tester.widgetList<Container>(
    find.ancestor(of: find.text(label), matching: find.byType(Container)),
  );
  for (final c in containers) {
    final decoration = c.decoration;
    if (c.constraints?.maxHeight == 44 &&
        decoration is BoxDecoration &&
        decoration.border != null) {
      return decoration.border!.top;
    }
  }
  fail('no 44 px bordered segment around "$label"');
}

void main() {
  // Four 124 pt cards do not fit on a phone, so the row scrolls sideways. If it
  // always started at Neon, a player running Glass would open Settings and find
  // the selected card entirely off the right edge — nothing on screen would
  // look chosen.
  for (final option in GameThemes.all) {
    testWidgets('the picker opens on ${option.id.name}, already running', (
      tester,
    ) async {
      useIPhoneSe(tester);
      // Each launch must re-read the store, or every theme after the first one
      // would be handed the cached preferences of the first.
      SharedPreferences.resetStatic();
      final env = await createTestEnv(theme: option.id);
      expect(env.settings.themeId, option.id);
      await tester.pumpWidget(wrapApp(env, const SettingsScreen()));
      await tester.pump();

      final card = find.byWidgetPredicate(
        (w) => w is ThemePreview && w.theme.id == option.id,
      );
      expect(card, findsOneWidget);
      final rect = tester.getRect(card);
      final screen =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(
        rect.left,
        greaterThanOrEqualTo(-0.5),
        reason: 'the selected card is cut off on the left',
      );
      expect(
        rect.right,
        lessThanOrEqualTo(screen + 0.5),
        reason: 'the selected card is cut off on the right',
      );
    });
  }

  testWidgets('shows every settings group and toggles sound', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));

    expect(find.text('SETTINGS'), findsOneWidget);
    expect(find.text('THEME'), findsOneWidget);
    expect(find.byType(ThemePreview), findsNWidgets(GameThemes.themeCount));
    expect(listText('LANGUAGE'), findsOneWidget);
    expect(listText('Sound'), findsOneWidget);
    expect(listText('Haptics'), findsOneWidget);
    expect(listText('CONTROLS'), findsOneWidget);
    expect(listText('Joystick'), findsOneWidget);
    expect(listText('Tilt'), findsOneWidget);
    expect(listText('Follow'), findsOneWidget);
    expect(listText('JOYSTICK POSITION'), findsOneWidget);

    expect(env.settings.sound, isTrue);
    await reveal(tester, listText('Sound'));
    await tester.tap(find.text('Sound'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(env.settings.sound, isFalse);

    await scrollToBottom(tester);
    expect(find.text('Advanced'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switches the control scheme and the language', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));

    await reveal(tester, listText('Follow'));
    await tester.tap(find.text('Follow'));
    await tester.pump();
    expect(env.settings.controlMode, ControlMode.follow);
    expect(listText('JOYSTICK POSITION'), findsNothing);

    await reveal(tester, listText('Polish'));
    await tester.tap(find.text('Polish'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(env.settings.language, AppLanguage.pl);
    expect(find.text('USTAWIENIA'), findsOneWidget);
    expect(listText('Dźwięk'), findsOneWidget);
    expect(listText('Podążaj za palcem'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the advanced section edits and tests the server URL', (
    tester,
  ) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));

    await scrollToBottom(tester);
    await tester.tap(find.text('Advanced'));
    // The expansion animation plus the lazy list needs several frames before
    // the revealed controls are laid out where they are painted.
    await pumpFrames(tester, 12, frame: const Duration(milliseconds: 40));
    await scrollToBottom(tester);
    expect(find.text('Server URL'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'http://10.0.0.5:9000');
    await tester.pump();
    expect(env.settings.serverUrl, 'http://10.0.0.5:9000');
    expect(env.settings.effectiveBaseUrl, 'http://10.0.0.5:9000');

    // Drop the text field focus so its selection overlay stops covering the
    // bottom of the list, then scroll the button fully into view.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await scrollToBottom(tester);
    await tester.tap(find.text('TEST CONNECTION'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Server OK'), findsOneWidget);
  });

  testWidgets('the tilt section exposes the sensitivity slider', (
    tester,
  ) async {
    useIPhoneSe(tester);
    final env = await createTestEnv(prefs: const {'controlMode': 'tilt'});
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));
    await tester.pump(const Duration(milliseconds: 50));

    expect(listText('TILT SENSITIVITY'), findsOneWidget);
    await scrollToBottom(tester);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('CALIBRATE'), findsOneWidget);
    expect(find.text('Tilt preview'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unselected controls stay visible on the panel surface', (
    tester,
  ) async {
    // Tall enough that the joystick-position row is laid out without a scroll.
    useTallPhone(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));

    // Joystick is the default mode, so Tilt and Follow must read as empty
    // radio buttons; invisible ones leave one lone dot and no radio group.
    final radios = tester
        .widgetList<Icon>(
          find.byIcon(Icons.radio_button_unchecked, skipOffstage: false),
        )
        .toList();
    expect(radios, hasLength(2));
    for (final radio in radios) {
      expect(
        contrastOnPanel(radio.color!),
        greaterThanOrEqualTo(3.0),
        reason: 'unchecked radio painted in ${radio.color}',
      );
    }

    // Without a visible outline the language / joystick-side rows look like a
    // single button instead of a 3-way choice.
    for (final label in ['English', 'Polish', 'Left', 'Right']) {
      await reveal(tester, listText(label));
      final border = segmentBorder(tester, label);
      expect(
        contrastOnPanel(border.color),
        greaterThanOrEqualTo(3.0),
        reason: 'unselected segment "$label" outlined in ${border.color}',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the compiled-in server URL hint is readable body text', (
    tester,
  ) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));

    await scrollToBottom(tester);
    await tester.tap(find.text('Advanced'));
    await pumpFrames(tester, 12, frame: const Duration(milliseconds: 40));
    await scrollToBottom(tester);

    // With no override both the effective URL (12 px) and the compiled-in
    // default (11 px) show the same string; the 11 px one is the hint.
    final hint = tester
        .widgetList<Text>(find.text(ServerConfig.defaultBaseUrl))
        .firstWhere((t) => t.style?.fontSize == 11);
    expect(
      contrastOnPanel(hint.style!.color!),
      greaterThanOrEqualTo(4.5),
      reason: 'default URL painted in ${hint.style!.color}',
    );
  });

  test('every theme outlines unselected controls above the 3:1 floor', () {
    for (final theme in GameThemes.all) {
      expect(
        contrastRatio(theme.outline, theme.panelFill),
        greaterThanOrEqualTo(3.0),
        reason: '${theme.id.name}: outline on a panel',
      );
      expect(
        contrastRatio(theme.outline, theme.background),
        greaterThanOrEqualTo(3.0),
        reason: '${theme.id.name}: outline on the background',
      );
    }
  });

  testWidgets('the picker marks the current theme and applies a tap instantly', (
    tester,
  ) async {
    // Wide enough that all four cards are centred side by side, so the tap
    // needs no sideways scrolling.
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // A player who owns every look: the picker offers what the server says is
    // theirs (SPEC 4.8), and a look that is not is locked rather than tappable.
    final env = await createTestEnv(
      owned: const {'theme.modernist', 'theme.glass'},
    );
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));

    ThemePreview previewOf(GameTheme theme) => tester
        .widgetList<ThemePreview>(find.byType(ThemePreview))
        .firstWhere((p) => p.theme.id == theme.id);

    expect(find.byType(ThemePreview), findsNWidgets(GameThemes.themeCount));
    expect(env.settings.themeId, ThemeId.neon);
    expect(previewOf(GameThemes.neon).selected, isTrue);
    expect(previewOf(GameThemes.modernist).selected, isFalse);

    await tester.tap(find.text('Modernist'));
    await tester.pump();

    expect(env.settings.themeId, ThemeId.modernist);
    expect(previewOf(GameThemes.modernist).selected, isTrue);
    expect(previewOf(GameThemes.neon).selected, isFalse);
    // Applied live: the Material theme under the screen is the light one now,
    // and the headings have stopped shouting.
    final context = tester.element(find.byType(SettingsScreen));
    expect(
      Theme.of(context).scaffoldBackgroundColor,
      GameThemes.modernist.background,
    );
    expect(find.text('Theme'), findsWidgets);
    expect(find.text('THEME'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // SPEC 4.8: a look that costs sparks is the shop's to sell, so the picker shows
  // it locked instead of giving it away — and the tap goes where it can be had.
  testWidgets(
    'a look that has not been bought is locked, and leads to the shop',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final env = await createTestEnv();
      await tester.pumpWidget(
        wrapApp(
          env,
          const SettingsScreen(),
          routes: {ShopScreen.route: (_) => const ShopScreen()},
        ),
      );
      await tester.pump();

      // The two free looks are the player's; the two paid ones are not.
      expect(find.byType(ThemePreview), findsNWidgets(GameThemes.themeCount));
      expect(
        find.byType(LockBadge),
        findsNWidgets(2),
        reason: 'Modernist and Glass cost sparks and have not been bought',
      );

      // Classic captions in upper case, Modernist and Glass do not: each card is
      // drawn in the look it shows, which is the whole point of it.
      await tester.tap(find.text('CLASSIC'));
      await tester.pump();
      expect(env.settings.themeId, ThemeId.classic, reason: 'a free look');

      await tester.tap(find.text('Glass'));
      await tester.pumpAndSettle();
      expect(
        env.settings.themeId,
        ThemeId.classic,
        reason: 'a look nobody paid for must not be applied by tapping it',
      );
      expect(find.byType(ShopScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // SPEC 4.9: the one-time unlock covers every cosmetic, so the picker in Settings
  // has to honour it as well as the shop does. Drawing a lock over something the
  // player has paid for is the one mistake worth a test of its own.
  testWidgets('every look is unlocked for a player who bought the unlock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final env = await createTestEnv(
      premium: true,
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    env.api.profile = PlayerProfile(id: testPlayerId(1), games: 1);
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));
    await tester.pump();

    expect(find.byType(ThemePreview), findsNWidgets(GameThemes.themeCount));
    expect(
      find.byType(LockBadge),
      findsNothing,
      reason: 'nothing is locked for somebody who bought everything',
    );

    // And a paid look applies on one tap, with no trip to the shop in between.
    await tester.tap(find.text('Glass'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(env.settings.themeId, ThemeId.glass);
    expect(env.api.shopEquips, [
      {'theme': 'theme.glass'},
    ]);
    expect(
      env.api.shopBuys,
      isEmpty,
      reason: 'it is already theirs; there is nothing to buy',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an owned look applies and is stored on the server', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final env = await createTestEnv(
      owned: const {'theme.glass'},
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    // A server that knows this player: without a profile the fake answers 401,
    // which correctly makes the app forget its identity (SPEC 4.4) and leaves
    // nothing to authenticate the equip with.
    env.api.profile = PlayerProfile(id: testPlayerId(1), games: 1);
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));
    await tester.pump();

    expect(find.byType(LockBadge), findsOneWidget, reason: 'only Modernist');

    await tester.tap(find.text('Glass'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(env.settings.themeId, ThemeId.glass);
    expect(env.api.shopEquips, [
      {'theme': 'theme.glass'},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the shop is reachable from Settings', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(
      wrapApp(
        env,
        const SettingsScreen(),
        routes: {ShopScreen.route: (_) => const ShopScreen()},
      ),
    );
    await tester.pump();

    await tester.tap(find.text('MORE LOOKS IN THE SHOP'));
    await tester.pumpAndSettle();
    expect(find.byType(ShopScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
