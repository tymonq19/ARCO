import 'dart:async';

import 'package:flutter/services.dart' show MissingPluginException;

import 'package:arco/app/game_theme.dart';
import 'package:arco/game/input/tilt_input.dart';
import 'package:arco/ui/home_screen.dart';
import 'package:arco/ui/settings_screen.dart';
import 'package:arco/ui/widgets/menu_ball_backdrop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../helpers/test_env.dart';

/// The living background of the title screen: the three ways it stops, the two
/// ways it is turned off, and the physics that has to keep it inside the box
/// whether or not the device has an accelerometer at all.
void main() {
  /// A broadcast accelerometer, so the backdrop can let go of it and take it
  /// again across a pause.
  StreamController<AccelerometerEvent> fakeSensor() {
    final controller = StreamController<AccelerometerEvent>.broadcast();
    addTearDown(controller.close);
    return controller;
  }

  /// A phone held upright: +g along the device's y axis, which is screen "up".
  AccelerometerEvent upright() =>
      AccelerometerEvent(0, 9.81, 0, DateTime.fromMicrosecondsSinceEpoch(0));

  /// The running layer. `skipOffstage: false`, because a route that has been
  /// covered goes offstage and it is exactly then that this has to be inspected.
  Finder findLayer() => find.byType(MenuBallLayer, skipOffstage: false);

  MenuBallLayerState layer(WidgetTester tester) =>
      tester.state<MenuBallLayerState>(findLayer());

  /// The backdrop on its own, in a route, so `ModalRoute` exists above it.
  Widget harness(
    TestEnv env,
    Stream<AccelerometerEvent>? sensor, {
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    return wrapApp(
      env,
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(child: MenuBallBackdrop(accelerometer: sensor)),
                Center(
                  child: TextButton(
                    onPressed: () =>
                        Navigator.of(context).pushNamed(SettingsScreen.route),
                    child: const Text('open'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      routes: {SettingsScreen.route: (_) => const SettingsScreen()},
    );
  }

  // ------------------------------------------------------------------ sleeping

  // An accelerometer stream and a running ticker behind a menu that is open and
  // idle are the easiest way there is to flatten a battery.
  testWidgets('stops when the app is backgrounded and starts again when it '
      'comes back', (tester) async {
    useTallPhone(tester);
    final env = await createTestEnv(menuMotion: true);
    final sensor = fakeSensor();
    await tester.pumpWidget(harness(env, sensor.stream));
    await pumpFrames(tester, 4);

    expect(layer(tester).running, isTrue);
    expect(sensor.hasListener, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(
      layer(tester).running,
      isFalse,
      reason: 'the ticker kept running while the app was not in front',
    );
    expect(
      sensor.hasListener,
      isFalse,
      reason: 'the accelerometer was left open in the background',
    );

    // And nothing moves while it is asleep, however many frames go by.
    final parked = layer(tester).motion.position;
    await pumpFrames(tester, 20);
    expect(layer(tester).motion.position, parked);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(layer(tester).running, isTrue);
    expect(sensor.hasListener, isTrue);
    await pumpFrames(tester, 6);
    expect(layer(tester).motion.position, isNot(parked));
    expect(tester.takeException(), isNull);
  });

  testWidgets('stops when the player leaves the menu and starts again when '
      'they come back', (tester) async {
    useTallPhone(tester);
    final env = await createTestEnv(menuMotion: true);
    final sensor = fakeSensor();
    await tester.pumpWidget(harness(env, sensor.stream));
    await pumpFrames(tester, 4);
    expect(layer(tester).running, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    // The menu is still mounted underneath — that is the whole trap.
    expect(findLayer(), findsOneWidget);
    expect(
      layer(tester).running,
      isFalse,
      reason: 'the menu kept animating behind a screen being read',
    );
    expect(sensor.hasListener, isFalse);

    final parked = layer(tester).motion.position;
    await pumpFrames(tester, 20);
    expect(layer(tester).motion.position, parked);

    // Not pumpAndSettle: once it is running again it schedules frames forever,
    // which is the whole point of it.
    await tester.pageBack();
    await pumpFrames(tester, 40);
    expect(layer(tester).running, isTrue);
    expect(sensor.hasListener, isTrue);
    await pumpFrames(tester, 6);
    expect(layer(tester).motion.position, isNot(parked));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancels the accelerometer subscription on dispose', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await createTestEnv(menuMotion: true);
    final sensor = fakeSensor();
    await tester.pumpWidget(harness(env, sensor.stream));
    await pumpFrames(tester, 4);
    expect(sensor.hasListener, isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(sensor.hasListener, isFalse);
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------------- off

  testWidgets('the setting hides it and opens no sensor', (tester) async {
    useTallPhone(tester);
    final env = await createTestEnv();
    final sensor = fakeSensor();
    await tester.pumpWidget(harness(env, sensor.stream));
    await pumpFrames(tester, 8);

    expect(findLayer(), findsNothing);
    expect(
      sensor.hasListener,
      isFalse,
      reason: 'a switched-off background still woke the accelerometer',
    );

    // And back on again without a restart: the switch is live.
    env.settings.menuMotion = true;
    await pumpFrames(tester, 4);
    expect(findLayer(), findsOneWidget);
    expect(sensor.hasListener, isTrue);

    // Off again disposes it, which is what releases the sensor.
    env.settings.menuMotion = false;
    await tester.pump();
    expect(findLayer(), findsNothing);
    expect(sensor.hasListener, isFalse);
    expect(tester.takeException(), isNull);
  });

  // Motion behind text is not only a matter of taste: it makes some people
  // unwell, and they should not have to find a switch for it.
  testWidgets('the platform reduce-motion request hides it without being '
      'asked', (tester) async {
    useTallPhone(tester);
    final env = await createTestEnv(menuMotion: true);
    final sensor = fakeSensor();
    await tester.pumpWidget(
      wrapApp(
        env,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Scaffold(
              body: MenuBallBackdrop(accelerometer: sensor.stream),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester, 8);

    expect(findLayer(), findsNothing);
    expect(sensor.hasListener, isFalse);
    expect(
      env.settings.menuMotion,
      isTrue,
      reason: 'the platform request must not overwrite the player preference',
    );
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------- no sensor

  // Every desktop and the web build. `sensors_plus` fails the stream there, and
  // the background has to go on looking alive rather than dead or broken.
  testWidgets('a platform with no accelerometer still drifts', (tester) async {
    useTallPhone(tester);
    final env = await createTestEnv(menuMotion: true);
    await tester.pumpWidget(
      harness(
        env,
        Stream<AccelerometerEvent>.error(
          MissingPluginException('no accelerometer'),
        ),
      ),
    );
    await pumpFrames(tester, 4);
    final start = layer(tester).motion.position;
    await pumpFrames(tester, 40);

    expect(layer(tester).running, isTrue);
    expect(
      (layer(tester).motion.position - start).distance,
      greaterThan(1),
      reason: 'with no sensor the ball stopped moving',
    );
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------------ tilting

  testWidgets('leans the way the phone leans', (tester) async {
    useTallPhone(tester);
    final env = await createTestEnv(menuMotion: true);
    final sensor = fakeSensor();
    await tester.pumpWidget(harness(env, sensor.stream));
    await pumpFrames(tester, 4);

    // Left edge down (ax > 0, the convention TiltInput documents): down the
    // screen is now to the left, so the ball has to end up left of where the
    // same run leaves it with the phone tilted the other way.
    for (var i = 0; i < 40; i++) {
      sensor.add(
        AccelerometerEvent(9.81, 0, 0, DateTime.fromMicrosecondsSinceEpoch(i)),
      );
      await tester.pump(const Duration(milliseconds: 33));
    }
    final leftward = layer(tester).motion.velocity.dx;

    await tester.pumpWidget(const SizedBox());
    final other = fakeSensor();
    await tester.pumpWidget(harness(env, other.stream));
    await pumpFrames(tester, 4);
    for (var i = 0; i < 40; i++) {
      other.add(
        AccelerometerEvent(-9.81, 0, 0, DateTime.fromMicrosecondsSinceEpoch(i)),
      );
      await tester.pump(const Duration(milliseconds: 33));
    }
    final rightward = layer(tester).motion.velocity.dx;

    expect(
      leftward,
      lessThan(rightward),
      reason: 'tilting the phone did not change which way the ball goes',
    );
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------------- themes

  // It sits behind the wordmark, the nickname field and four buttons, in four
  // themes, on the narrowest phone the app supports, at the text scale a player
  // with poor eyesight actually uses.
  for (final theme in GameThemes.all) {
    testWidgets('the title screen renders with it on at 320x568 and 1.6 text '
        'scale (${theme.id.name})', (tester) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(theme: theme.id, menuMotion: true);
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
      await pumpFrames(tester, 10);

      expect(findLayer(), findsOneWidget);
      expect(find.text('ARCO'), findsOneWidget);
      expect(find.text('SOLO'), findsOneWidget);
      final state = layer(tester);
      final box = tester.getSize(findLayer());
      expect(state.motion.position.dx, inInclusiveRange(0, box.width));
      expect(state.motion.position.dy, inInclusiveRange(0, box.height));
      expect(
        tester.takeException(),
        isNull,
        reason: 'the title screen overflowed or threw under ${theme.id.name}',
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  // Never brighter than the text in front of it, in any theme, and never
  // invisible either.
  test('the backdrop is dim in every theme', () {
    for (final theme in GameThemes.all) {
      final alpha = backdropOpacity(theme);
      expect(alpha, greaterThan(0.1), reason: theme.id.name);
      expect(alpha, lessThanOrEqualTo(0.3), reason: theme.id.name);
    }
    // Ink on paper is the strongest mark of the four, so it is drawn faintest.
    expect(
      backdropOpacity(GameThemes.modernist),
      lessThan(backdropOpacity(GameThemes.classic)),
    );
  });

  // ------------------------------------------------------------------ physics

  group('MenuBallMotion', () {
    const box = Size(320, 568);

    test('never leaves the box, whatever gravity does', () {
      for (final gravity in <Offset?>[
        null,
        Offset.zero,
        const Offset(0, 1),
        const Offset(0, -1),
        const Offset(1, 0),
        const Offset(-0.7, 0.7),
      ]) {
        final motion = MenuBallMotion()..radius = 8;
        for (var i = 0; i < 3000; i++) {
          motion.step(box, 1 / 30, gravity);
          expect(motion.position.dx, inInclusiveRange(8, box.width - 8));
          expect(motion.position.dy, inInclusiveRange(8, box.height - 8));
        }
      }
    });

    test('a stalled frame cannot throw the ball out of the box', () {
      final motion = MenuBallMotion()..radius = 8;
      for (var i = 0; i < 40; i++) {
        motion.step(box, 5, const Offset(0.6, 0.8));
        expect(motion.position.dx, inInclusiveRange(8, box.width - 8));
        expect(motion.position.dy, inInclusiveRange(8, box.height - 8));
      }
    });

    test('a box smaller than the ball cannot throw it out either', () {
      final motion = MenuBallMotion()..radius = 40;
      for (var i = 0; i < 60; i++) {
        motion.step(const Size(10, 12), 1 / 30, const Offset(0, 1));
        expect(motion.position.dx, inInclusiveRange(0, 10));
        expect(motion.position.dy, inInclusiveRange(0, 12));
      }
    });

    test('stays inside the speed band, so it never races and never stalls', () {
      const unit = 320.0;
      final slowest = MenuBallMotion.slowest * MenuBallMotion.cruise * unit;
      final fastest = MenuBallMotion.fastest * MenuBallMotion.cruise * unit;
      for (final gravity in <Offset?>[
        null,
        const Offset(0, 1),
        const Offset(-1, 0),
      ]) {
        final motion = MenuBallMotion()..radius = 8;
        for (var i = 0; i < 2000; i++) {
          motion.step(box, 1 / 30, gravity);
          expect(
            motion.velocity.distance,
            inInclusiveRange(slowest - 0.01, fastest + 0.01),
          );
        }
      }
    });

    test('an empty box and a zero step change nothing', () {
      final motion = MenuBallMotion();
      motion.step(Size.zero, 1 / 30, const Offset(0, 1));
      expect(motion.position, Offset.zero);
      motion.step(box, 0, const Offset(0, 1));
      expect(motion.position, Offset.zero);
    });

    test('with no sensor it keeps touring instead of resting', () {
      final motion = MenuBallMotion()..radius = 8;
      var travelled = 0.0;
      var previous = motion.position;
      for (var i = 0; i < 3000; i++) {
        motion.step(box, 1 / 30, null);
        travelled += (motion.position - previous).distance;
        previous = motion.position;
      }
      // A hundred seconds at cruising speed is several screens' worth.
      expect(travelled, greaterThan(box.height * 3));
    });

    test('gravity decides which way it settles', () {
      // The swirl is what keeps it off the floor, so the honest measure is where
      // it spends its time rather than where it ends up on any one frame.
      double meanY(Offset gravity) {
        final motion = MenuBallMotion()..radius = 8;
        var sum = 0.0;
        for (var i = 0; i < 1800; i++) {
          motion.step(box, 1 / 30, gravity);
          sum += motion.position.dy;
        }
        return sum / 1800;
      }

      expect(
        meanY(const Offset(0, 1)),
        greaterThan(meanY(const Offset(0, -1))),
      );

      double meanX(Offset gravity) {
        final motion = MenuBallMotion()..radius = 8;
        var sum = 0.0;
        for (var i = 0; i < 1800; i++) {
          motion.step(box, 1 / 30, gravity);
          sum += motion.position.dx;
        }
        return sum / 1800;
      }

      expect(
        meanX(const Offset(1, 0)),
        greaterThan(meanX(const Offset(-1, 0))),
      );
    });

    test('bounces off all four walls', () {
      final hit = <String>{};
      final motion = MenuBallMotion()..radius = 8;
      for (var i = 0; i < 6000; i++) {
        final before = motion.velocity;
        motion.step(box, 1 / 30, null);
        final after = motion.velocity;
        if (before.dx < 0 && after.dx > 0) hit.add('left');
        if (before.dx > 0 && after.dx < 0) hit.add('right');
        if (before.dy < 0 && after.dy > 0) hit.add('top');
        if (before.dy > 0 && after.dy < 0) hit.add('bottom');
      }
      expect(hit, containsAll(<String>['left', 'right', 'top', 'bottom']));
    });
  });

  // The vector the backdrop steers by, taken from the app's one sensor path
  // rather than a second one.
  group('TiltInput.screenGravity', () {
    test('is null until the first sample', () async {
      final env = await createTestEnv(menuMotion: true);
      final controller = StreamController<AccelerometerEvent>();
      addTearDown(controller.close);
      final tilt = TiltInput(settings: env.settings, source: controller.stream);
      addTearDown(tilt.dispose);
      expect(tilt.screenGravity, isNull);
    });

    test('points down the screen for a phone held upright, and shortens as it '
        'is laid flat', () async {
      final env = await createTestEnv(menuMotion: true);
      final controller = StreamController<AccelerometerEvent>.broadcast();
      addTearDown(controller.close);
      final tilt = TiltInput(settings: env.settings, source: controller.stream);
      addTearDown(tilt.dispose);

      controller.add(upright());
      await pumpEventQueue();
      final g = tilt.screenGravity!;
      expect(g.dx, moreOrLessEquals(0, epsilon: 1e-6));
      expect(g.dy, moreOrLessEquals(1, epsilon: 1e-3));

      // Left edge down: down the screen is now to the left.
      controller.add(
        AccelerometerEvent(9.81, 0, 0, DateTime.fromMicrosecondsSinceEpoch(1)),
      );
      for (var i = 0; i < 200; i++) {
        controller.add(
          AccelerometerEvent(
            9.81,
            0,
            0,
            DateTime.fromMicrosecondsSinceEpoch(i),
          ),
        );
      }
      await pumpEventQueue();
      expect(tilt.screenGravity!.dx, lessThan(-0.9));

      // Flat on a table: none of gravity is in the screen plane, so the vector
      // goes to nothing rather than to a direction picked out of sensor noise.
      for (var i = 0; i < 200; i++) {
        controller.add(
          AccelerometerEvent(
            0,
            0,
            9.81,
            DateTime.fromMicrosecondsSinceEpoch(i),
          ),
        );
      }
      await pumpEventQueue();
      expect(tilt.screenGravity!.distance, lessThan(0.05));
    });

    test('is read uncalibrated: gravity is not where the player holds the '
        'phone', () async {
      final env = await createTestEnv(menuMotion: true);
      env.settings.tiltBaseline = 0.6;
      final controller = StreamController<AccelerometerEvent>.broadcast();
      addTearDown(controller.close);
      final tilt = TiltInput(settings: env.settings, source: controller.stream);
      addTearDown(tilt.dispose);
      controller.add(upright());
      await pumpEventQueue();
      expect(tilt.screenGravity!.dy, moreOrLessEquals(1, epsilon: 1e-3));
    });
  });
}
