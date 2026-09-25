import 'package:arco_core/arco_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import '../arena_geometry.dart';
import 'input_controller.dart';

/// "Follow the finger": while a pointer is down the paddle aims at the
/// pointer's angle around the arena center. [ArenaGeometry.angleAt] already
/// accounts for the flipped y axis and the 180° rotation of player 1, so the
/// quantized aim is directly a math angle.
class FollowInput extends ChangeNotifier
    with IdempotentDispose, NoSensorInput
    implements InputController, PointerInputHandler {
  int? _pointer;
  PlayerInput _current = PlayerInput.none;

  bool get active => _pointer != null;

  @override
  PlayerInput get current => _current;

  @override
  void onPointerDown(PointerDownEvent event, ArenaGeometry geometry) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _aimAt(event.localPosition, geometry);
  }

  @override
  void onPointerMove(PointerMoveEvent event, ArenaGeometry geometry) {
    if (event.pointer != _pointer) return;
    _aimAt(event.localPosition, geometry);
  }

  @override
  void onPointerUp(int pointer) {
    if (pointer != _pointer) return;
    _pointer = null;
    _current = PlayerInput.none;
    notifyListeners();
  }

  void _aimAt(Offset p, ArenaGeometry g) {
    final dx = p.dx - g.center.dx;
    final dy = p.dy - g.center.dy;
    // Ignore the tiny region around the center where the angle is undefined.
    if (dx * dx + dy * dy < 4) return;
    _current = PlayerInput.aiming(quantizeAim(g.angleAt(p)));
    notifyListeners();
  }

  @override
  void reset() {
    if (_pointer == null) return;
    onPointerUp(_pointer!);
  }
}
