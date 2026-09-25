import 'dart:async';

import 'package:arco/game/input/follow_input.dart';
import 'package:arco/game/input/input_controller.dart';
import 'package:arco/game/input/joystick_input.dart';
import 'package:arco/game/input/keyboard_input.dart';
import 'package:arco/game/input/tilt_input.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../helpers/test_env.dart';

void main() {
  // KeyboardInput touches HardwareKeyboard.instance.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every InputController.dispose is safe to call twice', () async {
    final env = await createTestEnv();
    final accelerometer = StreamController<AccelerometerEvent>();
    addTearDown(accelerometer.close);

    final tilt = TiltInput(
      settings: env.settings,
      source: accelerometer.stream,
    );
    final joystick = JoystickInput();
    final follow = FollowInput();
    final keyboard = KeyboardInput();
    final composite = CompositeInput([tilt, joystick, follow, keyboard]);

    expect(accelerometer.hasListener, isTrue);

    // First dispose releases the sensor subscription.
    composite.dispose();
    expect(accelerometer.hasListener, isFalse);

    // Second dispose, whether through the composite or straight on a source,
    // is a documented no-op (InputController.dispose: "Safe to call twice").
    expect(composite.dispose, returnsNormally);
    expect(tilt.dispose, returnsNormally);
    expect(joystick.dispose, returnsNormally);
    expect(follow.dispose, returnsNormally);
    expect(keyboard.dispose, returnsNormally);
  });

  test(
    'TiltInput.pause releases the sensor and resume opens it again',
    () async {
      final env = await createTestEnv();
      // Broadcast: a paused source has to be listenable a second time.
      final accelerometer = StreamController<AccelerometerEvent>.broadcast();
      addTearDown(accelerometer.close);
      final tilt = TiltInput(
        settings: env.settings,
        source: accelerometer.stream,
      );
      expect(accelerometer.hasListener, isTrue);

      // A clear left tilt (left edge down → ax > 0) moves the paddle.
      accelerometer.add(
        AccelerometerEvent(9.81, 0, 0, DateTime.fromMicrosecondsSinceEpoch(0)),
      );
      await pumpEventQueue();
      expect(tilt.current, isNot(PlayerInput.none));

      tilt.pause();
      expect(accelerometer.hasListener, isFalse);
      expect(
        tilt.current,
        PlayerInput.none,
        reason: 'a frozen gravity vector must not keep pushing the paddle',
      );
      expect(tilt.pause, returnsNormally, reason: 'pause is idempotent');
      expect(accelerometer.hasListener, isFalse);

      tilt.resume();
      expect(accelerometer.hasListener, isTrue);
      expect(
        tilt.current,
        isNot(PlayerInput.none),
        reason: 'the filtered gravity vector survives the pause',
      );
      // A second resume must not stack a second subscription on the stream: one
      // pause is then enough to release it again.
      tilt.resume();
      tilt.pause();
      expect(accelerometer.hasListener, isFalse);

      tilt.resume();
      tilt.dispose();
      expect(accelerometer.hasListener, isFalse);
      // Disposed for good: resume must not re-open the sensor.
      tilt.resume();
      expect(accelerometer.hasListener, isFalse);
    },
  );
}
