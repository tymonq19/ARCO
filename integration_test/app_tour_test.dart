// A scripted tour of every screen, used to verify the app on a real device or
// simulator. It holds on each screen long enough for an external screenshot
// loop (`xcrun simctl io <udid> screenshot ...`) to catch it.
//
//   flutter test integration_test/app_tour_test.dart -d <device-id> \
//       --dart-define=SERVER_URL=http://localhost:18100
//
// Three rules keep this reliable on a device:
//
//   * nothing waits on the wall clock with `Future.delayed`, and nothing calls
//     `pumpAndSettle`: the arena animates forever (a `Ticker` drives
//     `GameView`), so "settled" never happens and a bare sleep would starve the
//     frames that make the screenshots interesting. Instead [hold] pumps frames
//     until the binding's own clock has advanced, with a frame cap as a
//     backstop;
//   * the twelve seconds of gameplay are *played*, not idled through: an
//     untouched paddle loses all three lives in well under 12 s, and the
//     game-over overlay then swallows the tap aimed at the HUD's pause button.
//     [playFor] reads the live simulation out of `GameView.stateOf` and steers
//     the app's own floating joystick with a real finger, so the tour sees a
//     populated arena and the pause panel is reachable afterwards;
//   * navigation uses the app's own affordances (the pause panel's MENU button
//     inside the arena, the AppBar back button elsewhere) instead of
//     `pageBack()`, which looks for a back button tooltipped "Back" and
//     therefore finds nothing when the app runs in Polish — and nothing at all
//     on the solo screen, which has no AppBar.
import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:arco/app/game_theme.dart';
import 'package:arco/app/settings.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/game/arena_geometry.dart';
import 'package:arco/game/input/joystick_input.dart';
import 'package:arco/game/render/game_view.dart';
import 'package:arco/main.dart' as app;
import 'package:arco/ui/home_screen.dart';
import 'package:arco/ui/onboarding_screen.dart';
import 'package:arco/ui/widgets/code_display.dart';
import 'package:arco/ui/widgets/neon_button.dart';

/// One frame at ~60 Hz.
const Duration _frame = Duration(milliseconds: 16);

/// Long enough for the external 2 s screenshot loop to catch the screen.
const Duration _screenHold = Duration(seconds: 3);

/// A route transition (300 ms) plus a little slack.
const Duration _transition = Duration(milliseconds: 700);

/// Pumps frames until [duration] has passed on the binding's clock.
///
/// The clock is real time under the live (device) binding and fake under
/// `flutter test`; a pump of [_frame] moves both forward, so the same loop
/// works in either. The frame cap is a backstop so a clock that stops moving
/// cannot turn this into an infinite loop.
Future<void> hold(WidgetTester tester, Duration duration) async {
  final clock = tester.binding.clock;
  final end = clock.now().add(duration);
  final maxFrames = duration.inMilliseconds ~/ _frame.inMilliseconds + 240;
  var frames = 0;
  while (frames < maxFrames && clock.now().isBefore(end)) {
    await tester.pump(_frame);
    frames++;
  }
}

/// The localized strings the running app is actually using, so the finders
/// below work whether the device is in English or in Polish.
Strings stringsOf(WidgetTester tester) =>
    Strings.read(tester.element(find.byType(MaterialApp)));

/// The look the running app is in, so the tour matches section headings
/// whatever theme was last chosen (some themes set them in normal case).
GameTheme themeOf(WidgetTester tester) =>
    GameTheme.read(tester.element(find.byType(MaterialApp)));

/// A finder that also sees the rows a lazy list has built but is not painting.
///
/// The settings list is longer than a phone — it opens on the theme previews —
/// so the controls below them start off screen; [reveal] scrolls them in.
Finder offscreenText(String text) => find.text(text, skipOffstage: false);

/// A [NeonButton] carrying [label] — the tappable ancestor of its `Text`.
Finder neonButton(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(NeonButton));

/// Taps [finder] and pumps through the route transition it may start.
Future<void> tapAndWait(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  Duration settle = _transition,
}) async {
  expect(finder, findsWidgets, reason: reason);
  await tester.tap(finder.first);
  await hold(tester, settle);
}

/// Pumps until [finder] matches, up to [timeout]; returns false on timeout.
Future<bool> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final clock = tester.binding.clock;
  final end = clock.now().add(timeout);
  final maxFrames = timeout.inMilliseconds ~/ _frame.inMilliseconds + 240;
  var frames = 0;
  while (frames < maxFrames && clock.now().isBefore(end)) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.pump(_frame);
    frames++;
  }
  return finder.evaluate().isNotEmpty;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Let the engine render every frame the framework asks for, not just the
  // pumped ones: the arena is `Ticker`-driven, and on a device the tour is
  // watched from outside, so it has to animate at full rate.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'tour: home, solo gameplay, leaderboard, settings, duel lobby',
    (tester) async {
      app.main();
      // `main` awaits shared_preferences before `runApp`, so the first frame is
      // not there yet; wait for a screen instead of guessing a delay. Which one
      // depends on the device: a clean install opens the welcome screen, a phone
      // that has run Arco before goes straight home.
      expect(
        await waitFor(
          tester,
          find.byWidgetPredicate(
            (w) => w is HomeScreen || w is OnboardingScreen,
          ),
        ),
        isTrue,
        reason: 'the app did not reach its first screen',
      );
      final s = stringsOf(tester);

      // --- Welcome ------------------------------------------------------------
      if (find.byType(OnboardingScreen).evaluate().isNotEmpty) {
        await hold(tester, _screenHold); // 0: the look chooser
        // Pick a look, watch it dissolve in, then come back to the default so
        // the rest of the tour looks the way it always does.
        for (final option in [GameThemes.modernist, GameThemes.neon]) {
          final card = find.text(option.heading(s.t(option.nameKey)));
          await reveal(tester, card);
          await tapAndWait(
            tester,
            card,
            reason: 'the welcome screen has no ${option.id.name} card',
            settle: OnboardingScreen.transition + const Duration(seconds: 1),
          );
        }
        final start = neonButton(s.t('onboarding.start'));
        await reveal(tester, start);
        await tapAndWait(
          tester,
          start,
          reason: 'the welcome screen has no start button',
        );
        expect(
          await waitFor(tester, find.byType(HomeScreen)),
          isTrue,
          reason: 'continuing from the welcome screen did not open home',
        );
      }
      await hold(tester, _screenHold); // 1: home

      expect(find.text(s.t('app.title')), findsOneWidget);
      expect(find.text(s.t('home.best')), findsOneWidget);

      // --- Solo ---------------------------------------------------------------
      await tapAndWait(
        tester,
        neonButton(s.t('home.solo')),
        reason: 'the home screen has no SOLO button',
      );
      expect(find.text(s.t('solo.tapToStart')), findsWidgets);
      await hold(tester, _screenHold); // 2: solo, tap-to-start overlay

      // The overlay's own button, not a blind tap at the centre of the screen.
      await tapAndWait(
        tester,
        neonButton(s.t('solo.tapToStart')),
        reason: 'the start overlay has no start button',
        settle: const Duration(milliseconds: 300),
      );
      expect(
        find.text(s.t('solo.tapToStart')),
        findsNothing,
        reason: 'the start overlay should be gone once the game runs',
      );

      // 3-5: gameplay. Walls start spawning 7-9 s in and pickups 3-5 s in, so
      // the screenshot loop needs a dozen seconds of *surviving* play to see a
      // populated arena.
      await playFor(tester, const Duration(seconds: 12));
      expect(
        find.text(s.t('solo.gameOver')),
        findsNothing,
        reason: 'the paddle lost all three lives during the 12 s of play',
      );
      expect(
        find.byIcon(Icons.pause),
        findsOneWidget,
        reason: 'the game should still be running after 12 s',
      );

      // Back to home through the pause panel (the arena has no AppBar).
      await tapAndWait(
        tester,
        find.byIcon(Icons.pause),
        reason: 'no pause button in the HUD',
        settle: const Duration(milliseconds: 300),
      );
      expect(find.text(s.t('solo.paused')), findsOneWidget);
      await hold(tester, const Duration(seconds: 2)); // 6: pause panel
      await tapAndWait(
        tester,
        neonButton(s.t('common.home')),
        reason: 'no HOME button in the pause panel',
      );
      expect(find.byType(HomeScreen), findsOneWidget);
      await hold(tester, const Duration(seconds: 1));

      // --- Leaderboard --------------------------------------------------------
      await tapAndWait(
        tester,
        neonButton(s.t('home.leaderboard')),
        reason: 'the home screen has no LEADERBOARD button',
      );
      expect(find.text(s.t('lb.all')), findsOneWidget);
      // Either rows arrived, or the list settled on its empty / offline state.
      await waitFor(
        tester,
        find.byType(ListView),
        timeout: const Duration(seconds: 8),
      );
      await hold(tester, _screenHold); // 7: leaderboard
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'the leaderboard was still loading after 11 s',
      );
      await goBack(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      await hold(tester, const Duration(seconds: 1));

      // --- Settings -----------------------------------------------------------
      await tapAndWait(
        tester,
        neonButton(s.t('home.settings')),
        reason: 'the home screen has no SETTINGS button',
      );
      // The section headers follow the theme's heading case (`_section` in
      // settings_screen.dart), so the raw string may never appear as a `Text`.
      final theme = themeOf(tester);
      expect(
        offscreenText(theme.heading(s.t('settings.theme'))),
        findsOneWidget,
      );
      expect(
        offscreenText(theme.heading(s.t('settings.controls'))),
        findsOneWidget,
      );
      await hold(tester, _screenHold); // 8: settings, the theme previews

      // The control-mode selector: pick TILT, which is also what reveals the
      // sensitivity slider below it.
      final tiltRow = controlRow(s.t('settings.controlTilt'));
      await reveal(tester, tiltRow);
      await tapAndWait(
        tester,
        tiltRow,
        reason: 'no tilt row in the control-mode selector',
        settle: const Duration(milliseconds: 400),
      );
      expect(
        await waitFor(tester, sliderFinder()),
        isTrue,
        reason: 'picking tilt did not reveal the sensitivity slider',
      );
      expect(
        offscreenText(theme.heading(s.t('settings.tiltSensitivity'))),
        findsOneWidget,
      );
      await reveal(tester, sliderFinder());
      await hold(tester, _screenHold); // 9: tilt mode, slider on screen

      // Drag the slider to both ends, so the assertion holds whatever value
      // was persisted from an earlier run.
      await tester.drag(find.byType(Slider), const Offset(-400, 0));
      await hold(tester, const Duration(seconds: 1));
      final low = sensitivity(tester);
      expect(
        low,
        Settings.minTiltSensitivity,
        reason: 'dragging the slider left did not reach the minimum',
      );
      await tester.drag(find.byType(Slider), const Offset(400, 0));
      await hold(tester, const Duration(seconds: 2)); // 10: slider at the top
      final high = sensitivity(tester);
      expect(
        high,
        Settings.maxTiltSensitivity,
        reason:
            'dragging the slider right did not reach the maximum '
            '(min $low, ended at $high)',
      );
      // The readout next to the slider follows the value.
      expect(find.text(high.toStringAsFixed(1)), findsWidgets);

      // Put the joystick back, so the tour leaves the app as it found it and
      // the slider is shown to disappear with the mode.
      final joystickRow = controlRow(s.t('settings.controlJoystick'));
      await reveal(tester, joystickRow);
      await tapAndWait(
        tester,
        joystickRow,
        reason: 'no joystick row in the control-mode selector',
        settle: const Duration(milliseconds: 400),
      );
      expect(
        sliderFinder(),
        findsNothing,
        reason: 'the sensitivity slider outlived tilt mode',
      );
      await hold(tester, const Duration(seconds: 2)); // 11: back to joystick
      await goBack(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      await hold(tester, const Duration(seconds: 1));

      // --- Duel lobby ---------------------------------------------------------
      await tapAndWait(
        tester,
        neonButton(s.t('home.duel')),
        reason: 'the home screen has no DUEL button',
      );
      expect(find.text(s.t('duel.create')), findsOneWidget);
      await hold(tester, const Duration(seconds: 2)); // 9: duel lobby menu

      await tapAndWait(
        tester,
        neonButton(s.t('duel.create')),
        reason: 'the duel lobby has no CREATE ROOM button',
        settle: const Duration(milliseconds: 300),
      );
      expect(
        await waitFor(tester, find.byType(CodeDisplay)),
        isTrue,
        reason: 'the server did not hand out a room code',
      );
      final code = tester.widget<CodeDisplay>(find.byType(CodeDisplay)).code;
      // SPEC's alphabet is not A-Z: it drops the letters that read like digits
      // (I, O) and adds 2-9, so "DN3N" is a perfectly good code.
      expect(code.length, roomCodeLength, reason: 'room code: $code');
      expect(
        code.split('').every(roomCodeAlphabet.contains),
        isTrue,
        reason: 'room code "$code" uses characters outside the SPEC alphabet',
      );
      expect(find.text(s.t('duel.waiting')), findsOneWidget);
      await hold(
        tester,
        const Duration(seconds: 4),
      ); // 10: waiting for a friend

      // --- Teardown -----------------------------------------------------------
      // Leave the room and walk back to the home screen before the test ends:
      // that closes the WebSocket and disposes the duel controller and its ping
      // timer while the tree is still alive, instead of racing the binding's own
      // teardown with a live socket.
      await tapAndWait(
        tester,
        neonButton(s.t('duel.leave')),
        reason: 'the waiting room has no LEAVE button',
        settle: const Duration(milliseconds: 500),
      );
      await goBack(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      await hold(tester, const Duration(seconds: 2));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

/// Plays the arena for [duration] with the app's own floating joystick.
///
/// A tour that only pumps frames is a tour of the game-over screen: with no
/// input the ball escapes and the three lives are gone in a few seconds. This
/// puts a finger down inside the joystick's active band and, every frame,
/// deflects the knob toward the ball's angle — the live [GameState] comes from
/// `GameView.stateOf`, the same closure the painter reads.
///
/// Knob right means a larger paddle angle (see [JoystickInput]'s class doc), so
/// the deflection is proportional to the signed angular error, which keeps the
/// paddle from buzzing around the target.
Future<void> playFor(WidgetTester tester, Duration duration) async {
  final view = find.byType(GameView);
  // Inside the lower [JoystickInput.activeFraction] of the view, which is what
  // anchors the pill, and clear of the bottom inset.
  final rect = tester.getRect(view);
  final anchor = Offset(rect.center.dx, rect.bottom - rect.height * 0.18);
  final gesture = await tester.startGesture(anchor);
  final clock = tester.binding.clock;
  final end = clock.now().add(duration);
  final maxFrames = duration.inMilliseconds ~/ _frame.inMilliseconds + 600;
  var frames = 0;
  try {
    while (frames < maxFrames && clock.now().isBefore(end)) {
      final state = tester.widget<GameView>(view).stateOf();
      var deflection = 0.0;
      // The first ball: a game can have two (SPEC 2.3), and a bot that has to
      // pick one picks the one the simulation resolves first.
      final ball = state?.balls.first;
      if (ball != null && ball.active && state!.players.isNotEmpty) {
        final error = angleDelta(
          math.atan2(ball.y, ball.x),
          state.players.first.paddle.angle,
        );
        // Full deflection once the paddle is more than ~0.25 rad off target.
        deflection = (error / 0.25).clamp(-1.0, 1.0) * JoystickInput.maxOffset;
      }
      await gesture.moveTo(anchor + Offset(deflection, 0));
      await tester.pump(_frame);
      frames++;
    }
  } finally {
    // Lift the finger whatever happened, so the paddle stops and the pause
    // button is not competing with a live pointer.
    await gesture.up();
    await tester.pump(_frame);
  }
}

/// The tappable [ListTile] of the control-mode row titled [title].
Finder controlRow(String title) => find.ancestor(
  of: offscreenText(title),
  matching: find.byType(ListTile, skipOffstage: false),
);

/// The sensitivity slider, whether or not it is scrolled into view yet.
Finder sliderFinder() => find.byType(Slider, skipOffstage: false);

/// The sensitivity slider's current value.
double sensitivity(WidgetTester tester) =>
    tester.widget<Slider>(find.byType(Slider)).value;

/// Scrolls [finder] into view and pumps through the scroll it may start.
///
/// `ensureVisible` needs the widget to exist in the tree already, which it does
/// here: the settings list is short enough that everything is laid out inside
/// the viewport's cache extent.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  expect(finder, findsWidgets, reason: 'nothing to reveal for $finder');
  await tester.ensureVisible(finder.first);
  await hold(tester, _transition);
}

/// Pops the current route with the AppBar's own back button.
///
/// [WidgetTester.pageBack] looks the button up by the English tooltip "Back",
/// which the app does not have when it runs in Polish; the widget type is
/// language-independent.
Future<void> goBack(WidgetTester tester) async {
  await tapAndWait(
    tester,
    find.byType(BackButton),
    reason: 'no back button in the AppBar',
  );
}
