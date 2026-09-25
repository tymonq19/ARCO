import 'package:arco_core/arco_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import '../arena_geometry.dart';

/// A control scheme: produces the [PlayerInput] for the current frame.
abstract class InputController {
  PlayerInput get current;

  /// Drops any in-flight gesture so the paddle stops (pause, game over).
  void reset() {}

  /// Releases the OS sensors this controller holds while no match is live —
  /// the duel lobby, the waiting room, the result overlay — without throwing
  /// the controller away; [resume] re-acquires them. A paused source reports
  /// [PlayerInput.none], since it is no longer reading the device. Idempotent,
  /// and nothing to do for the control modes that only read touches or keys.
  void pause() {}

  /// Re-acquires whatever [pause] released. Safe to call when nothing is
  /// paused, and a no-op after [dispose].
  void resume() {}

  /// Releases sensors / listeners. Safe to call twice.
  void dispose() {}
}

/// Default [InputController.pause] / [InputController.resume] for the control
/// modes that hold no sensor subscription: touches and key events cost nothing
/// while no match is running, so there is nothing to release.
mixin NoSensorInput {
  void pause() {}
  void resume() {}
}

/// Makes [InputController.dispose] idempotent for the [ChangeNotifier]-based
/// controllers: [ChangeNotifier.dispose] asserts it is called exactly once, so
/// without this guard a second call would throw in debug mode.
mixin IdempotentDispose on ChangeNotifier {
  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

/// Implemented by controllers that consume raw pointer events from the
/// arena's gesture layer.
abstract class PointerInputHandler {
  void onPointerDown(PointerDownEvent event, ArenaGeometry geometry);
  void onPointerMove(PointerMoveEvent event, ArenaGeometry geometry);
  void onPointerUp(int pointer);
}

/// First controller with a non-idle input wins (keyboard over touch etc.).
class CompositeInput implements InputController {
  const CompositeInput(this.sources);

  final List<InputController> sources;

  @override
  PlayerInput get current {
    for (final s in sources) {
      final i = s.current;
      if (i != PlayerInput.none) return i;
    }
    return PlayerInput.none;
  }

  @override
  void reset() {
    for (final s in sources) {
      s.reset();
    }
  }

  @override
  void pause() {
    for (final s in sources) {
      s.pause();
    }
  }

  @override
  void resume() {
    for (final s in sources) {
      s.resume();
    }
  }

  @override
  void dispose() {
    for (final s in sources) {
      s.dispose();
    }
  }
}

/// Finds the first component of type [T] inside [controller], unwrapping
/// [CompositeInput]; null when there is none. Used by the game view to reach
/// the pointer handler, the joystick overlay state and the tilt sensor.
T? findInput<T extends Object>(InputController? controller) {
  if (controller == null) return null;
  if (controller is T) return controller as T;
  if (controller is CompositeInput) {
    for (final source in controller.sources) {
      final found = findInput<T>(source);
      if (found != null) return found;
    }
  }
  return null;
}
