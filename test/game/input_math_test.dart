import 'package:arco/app/settings.dart';
import 'package:arco/game/arena_geometry.dart';
import 'package:arco/game/input/follow_input.dart';
import 'package:arco/game/input/joystick_input.dart';
import 'package:arco/game/input/keyboard_input.dart';
import 'package:arco/game/input/tilt_input.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const Size iPhoneSe = Size(375, 667);

void main() {
  group('joystick', () {
    test('12% dead zone, 16 steps, symmetric', () {
      expect(JoystickInput.moveFor(0), 0);
      expect(JoystickInput.moveFor(0.11), 0);
      expect(JoystickInput.moveFor(-0.11), 0);
      expect(JoystickInput.moveFor(0.12), 0);
      expect(JoystickInput.moveFor(1), inputMoveMax);
      expect(JoystickInput.moveFor(-1), -inputMoveMax);
      // Clamped beyond the track.
      expect(JoystickInput.moveFor(3), inputMoveMax);
      expect(JoystickInput.moveFor(0.5), -JoystickInput.moveFor(-0.5));
      expect(JoystickInput.moveFor(0.5), 8);
      var previous = 0;
      for (var i = 1; i <= 10; i++) {
        final value = JoystickInput.moveFor(i / 10);
        expect(value, greaterThanOrEqualTo(previous));
        previous = value;
      }
    });

    test('past the dead zone follows the SPEC 5.2 formula exactly', () {
      // SPEC 5.2: move = round(clamp(dx / 64, -1, 1) * 16). The dead zone cuts
      // the first 12% of the travel, it must not rescale what is left of it.
      for (final n in <double>[0.13, 0.25, 0.375, 0.5, 0.625, 0.75, 0.9, 1]) {
        final expected = (n * inputMoveMax).round();
        expect(JoystickInput.moveFor(n), expected, reason: 'n = $n');
        expect(JoystickInput.moveFor(-n), -expected, reason: 'n = -$n');
      }
      // Same curve as the other analog mode (TiltInput.moveFor), so half a
      // deflection means half the paddle speed in both.
      expect(JoystickInput.moveFor(0.5), 8);
      expect(TiltInput.moveFor(0.175, 1).abs(), JoystickInput.moveFor(0.5));
    });

    test('anchors in the lower 60% and maps the horizontal offset', () {
      final geometry = ArenaGeometry.fit(iPhoneSe);
      final joystick = JoystickInput();

      // Upper 40% of the view is ignored.
      joystick.onPointerDown(
        const PointerDownEvent(pointer: 1, position: Offset(180, 100)),
        geometry,
      );
      expect(joystick.active, isFalse);

      joystick.onPointerDown(
        const PointerDownEvent(pointer: 2, position: Offset(180, 520)),
        geometry,
      );
      expect(joystick.active, isTrue);
      expect(joystick.current, PlayerInput.none);
      expect(joystick.origin, const Offset(180, 520));

      // Knob left: negative move, which decreases the paddle angle and moves
      // the paddle left on screen (see JoystickInput's mapping notes).
      joystick.onPointerMove(
        const PointerMoveEvent(pointer: 2, position: Offset(116, 520)),
        geometry,
      );
      expect(joystick.knobOffset, -JoystickInput.maxOffset);
      expect(joystick.current.move, -inputMoveMax);
      expect(joystick.current.aim, -1);

      // Clamped to 64 px.
      joystick.onPointerMove(
        const PointerMoveEvent(pointer: 2, position: Offset(20, 520)),
        geometry,
      );
      expect(joystick.knobOffset, -JoystickInput.maxOffset);

      joystick.onPointerMove(
        const PointerMoveEvent(pointer: 2, position: Offset(244, 520)),
        geometry,
      );
      expect(joystick.current.move, inputMoveMax);

      joystick.onPointerUp(2);
      expect(joystick.active, isFalse);
      expect(joystick.current, PlayerInput.none);
      joystick.dispose();
    });

    test('fixed sides park the pill in the bottom corners', () {
      final left = JoystickInput(side: JoystickSide.left);
      final right = JoystickInput(side: JoystickSide.right);
      final l = left.trackCenter(iPhoneSe)!;
      final r = right.trackCenter(iPhoneSe)!;
      expect(l.dx, lessThan(iPhoneSe.width / 2));
      expect(r.dx, greaterThan(iPhoneSe.width / 2));
      expect(l.dy, greaterThan(iPhoneSe.height * 0.8));
      expect(r.dy, closeTo(l.dy, 0.001));
      expect(JoystickInput().trackCenter(iPhoneSe), isNull);
      left.dispose();
      right.dispose();
    });
  });

  group('tilt', () {
    test('roll is atan2(ax, ay) in portrait', () {
      expect(TiltInput.rollFor(0, 9.81, Orientation.portrait), 0);
      expect(
        TiltInput.rollFor(4.905, 8.496, Orientation.portrait),
        closeTo(0.5236, 0.001),
      );
      expect(
        TiltInput.rollFor(-4.905, 8.496, Orientation.portrait),
        closeTo(-0.5236, 0.001),
      );
    });

    test('landscape uses the rotated axes', () {
      // Device rotated so that +x points up: gravity sits on +x.
      expect(TiltInput.rollFor(9.81, 0, Orientation.landscape), 0);
      // ... and the opposite landscape orientation.
      expect(TiltInput.rollFor(-9.81, 0, Orientation.landscape), 0);
      expect(
        TiltInput.rollFor(8.496, -4.905, Orientation.landscape),
        closeTo(0.5236, 0.001),
      );
    });

    test('dead zone, sensitivity and sign', () {
      expect(TiltInput.moveFor(0, 1), 0);
      expect(TiltInput.moveFor(0.039, 1), 0);
      expect(TiltInput.moveFor(-0.039, 1), 0);
      // A left tilt (left edge down) reads a positive roll and must move the
      // paddle left, i.e. a negative move.
      expect(TiltInput.moveFor(0.35, 1), -inputMoveMax);
      expect(TiltInput.moveFor(-0.35, 1), inputMoveMax);
      expect(TiltInput.moveFor(0.9, 1), -inputMoveMax);
      // Higher sensitivity needs less tilt for full deflection.
      expect(TiltInput.moveFor(0.175, 2), -inputMoveMax);
      expect(TiltInput.moveFor(0.175, 1), -8);
      // Lower sensitivity needs more.
      expect(TiltInput.moveFor(0.35, 0.5), -8);
    });
  });

  group('follow', () {
    test('aims at the finger angle around the arena center', () {
      final geometry = ArenaGeometry.fit(
        iPhoneSe,
        topInset: 96,
        bottomInset: 24,
      );
      final follow = FollowInput();
      final below = Offset(geometry.center.dx, geometry.center.dy + 100);
      follow.onPointerDown(
        PointerDownEvent(pointer: 1, position: below),
        geometry,
      );
      expect(follow.active, isTrue);
      // Below the center on screen is angle 3*pi/2 in sim coordinates.
      expect(
        follow.current.targetAngle,
        closeTo(DetMath.threeHalfPi, DetMath.tau / inputAimSteps),
      );

      final right = Offset(geometry.center.dx + 100, geometry.center.dy);
      follow.onPointerMove(
        PointerMoveEvent(pointer: 1, position: right),
        geometry,
      );
      expect(
        follow.current.targetAngle,
        closeTo(0, DetMath.tau / inputAimSteps),
      );

      follow.onPointerUp(1);
      expect(follow.current, PlayerInput.none);
      follow.dispose();
    });

    test('player 1 sees the board rotated by 180 degrees', () {
      final geometry = ArenaGeometry.fit(iPhoneSe, rotated: true);
      final follow = FollowInput();
      final below = Offset(geometry.center.dx, geometry.center.dy + 100);
      follow.onPointerDown(
        PointerDownEvent(pointer: 1, position: below),
        geometry,
      );
      // The bottom of player 1's screen is the top half of the arena.
      expect(
        follow.current.targetAngle,
        closeTo(DetMath.halfPi, DetMath.tau / inputAimSteps),
      );
      follow.dispose();
    });
  });

  group('keyboard', () {
    test('arrows and A/D map to full deflection', () {
      expect(KeyboardInput.moveFor(left: false, right: false), 0);
      expect(KeyboardInput.moveFor(left: true, right: true), 0);
      expect(KeyboardInput.moveFor(left: true, right: false), -inputMoveMax);
      expect(KeyboardInput.moveFor(left: false, right: true), inputMoveMax);
    });
  });

  group('arena geometry', () {
    test('maps sim units to screen with the y flip', () {
      final geometry = ArenaGeometry.fit(
        iPhoneSe,
        topInset: 96,
        bottomInset: 24,
      );
      final bottom = geometry.toScreen(0, -1);
      expect(bottom.dx, closeTo(geometry.center.dx, 0.001));
      expect(bottom.dy, closeTo(geometry.center.dy + geometry.radius, 0.001));
      final rotated = ArenaGeometry.fit(iPhoneSe, rotated: true);
      final top = rotated.toScreen(0, 1);
      expect(top.dy, closeTo(rotated.center.dy + rotated.radius, 0.001));
      expect(geometry.radius * 2, lessThanOrEqualTo(iPhoneSe.width - 32));
    });

    test('quantizes aim angles into the 4096 step scale', () {
      expect(quantizeAim(0), 0);
      expect(quantizeAim(DetMath.tau), 0);
      expect(quantizeAim(-0.0001), inputAimSteps - 1);
      expect(quantizeAim(DetMath.pi), inputAimSteps ~/ 2);
    });
  });
}
