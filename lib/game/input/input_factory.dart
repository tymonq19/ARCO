import '../../app/settings.dart';
import 'follow_input.dart';
import 'input_controller.dart';
import 'joystick_input.dart';
import 'tilt_input.dart';

/// Builds the touch/sensor controller for the selected control mode. The
/// keyboard is layered on top by the game view itself.
InputController createInputController(Settings settings) {
  switch (settings.controlMode) {
    case ControlMode.joystick:
      return JoystickInput(side: settings.joystickSide);
    case ControlMode.tilt:
      return TiltInput(settings: settings);
    case ControlMode.follow:
      return FollowInput();
  }
}
