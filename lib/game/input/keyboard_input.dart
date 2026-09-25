import 'package:arco_core/arco_core.dart';
import 'package:flutter/services.dart';

import 'input_controller.dart';

/// Arrow keys / A-D on desktop and web (SPEC §5.2). Listens through
/// [HardwareKeyboard] so it works regardless of which widget has focus.
class KeyboardInput with NoSensorInput implements InputController {
  KeyboardInput() {
    HardwareKeyboard.instance.addHandler(_handle);
  }

  final Set<LogicalKeyboardKey> _down = <LogicalKeyboardKey>{};
  bool _disposed = false;

  /// Not `const`: [LogicalKeyboardKey] overrides `==`, which constant sets
  /// forbid, so the sets are built once at class-load time instead.
  static final Set<LogicalKeyboardKey> _leftKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.keyA,
  };
  static final Set<LogicalKeyboardKey> _rightKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.keyD,
  };

  bool _handle(KeyEvent event) {
    if (event is KeyDownEvent) {
      _down.add(event.logicalKey);
    } else if (event is KeyUpEvent) {
      _down.remove(event.logicalKey);
    }
    // Never consume: other handlers (e.g. text fields) must still see keys.
    return false;
  }

  bool get _left => _down.any(_leftKeys.contains);
  bool get _right => _down.any(_rightKeys.contains);

  static int moveFor({required bool left, required bool right}) =>
      left == right ? 0 : (left ? -inputMoveMax : inputMoveMax);

  @override
  PlayerInput get current {
    final m = moveFor(left: _left, right: _right);
    return m == 0 ? PlayerInput.none : PlayerInput.moving(m);
  }

  /// Forgets held keys (the game lost focus or paused).
  @override
  void reset() => _down.clear();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    HardwareKeyboard.instance.removeHandler(_handle);
  }
}
