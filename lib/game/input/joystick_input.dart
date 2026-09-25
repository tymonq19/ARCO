import 'dart:ui';

import 'package:arco_core/arco_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import '../../app/settings.dart';
import '../arena_geometry.dart';
import 'input_controller.dart';

/// Floating one-axis joystick (SPEC §5.2).
///
/// Touch-down anywhere in the lower 60% of the arena view anchors a pill
/// track at the touch point; the knob follows the finger's horizontal offset
/// clamped to ±[maxOffset] px. `move = round(clamp(dx / 64, -1, 1) * 16)`
/// after a 12% dead zone.
///
/// Direction mapping: knob LEFT → `dx < 0` → negative `move` → the sim
/// DEcreases the paddle angle. With the paddle at the bottom of the ring
/// (angle 3π/2; the renderer flips y) a decreasing angle moves it toward
/// −x, i.e. left on screen. Player 1 in a duel sees the board rotated 180°;
/// their paddle sits at π/2 and a decreasing angle moves it toward +x, which
/// is again left on *their* rotated screen. So no sign flip is needed for
/// either player.
class JoystickInput extends ChangeNotifier
    with IdempotentDispose, NoSensorInput
    implements InputController, PointerInputHandler {
  JoystickInput({this.side = JoystickSide.float});

  static const double maxOffset = 64;
  static const double deadZone = 0.12;

  /// Fraction of the view height (from the bottom) that accepts touch-downs.
  static const double activeFraction = 0.6;

  /// Pill geometry for the overlay painter.
  static const double knobRadius = 26;
  static const double trackHalfWidth = maxOffset + knobRadius;
  static const double trackHalfHeight = knobRadius + 6;
  static const double fixedMargin = 24;

  final JoystickSide side;

  int? _pointer;
  Offset? _origin;
  double _dx = 0;
  PlayerInput _current = PlayerInput.none;

  bool get active => _pointer != null;

  /// Horizontal knob offset in px (−64..64).
  double get knobOffset => _dx;

  /// Touch anchor of the current gesture (float mode draws the pill here).
  Offset? get origin => _origin;

  /// Pure mapping from a normalized deflection (dx / maxOffset) to `move`.
  ///
  /// The SPEC §5.2 formula verbatim: `round(clamp(dx / 64, -1, 1) * 16)`. The
  /// dead zone only cuts the first 12% of the travel to 0, it does not rescale
  /// what is left of it onto the full range — so half a deflection is half the
  /// paddle speed, same as [TiltInput.moveFor].
  static int moveFor(double normalized) {
    final n = normalized.clamp(-1.0, 1.0);
    if (n.abs() <= deadZone) return 0;
    return (n * inputMoveMax).round();
  }

  /// Where the pill is drawn for a view of [size].
  Offset? trackCenter(Size size) {
    switch (side) {
      case JoystickSide.float:
        return _origin;
      case JoystickSide.left:
        return Offset(
          fixedMargin + trackHalfWidth,
          size.height - fixedMargin - trackHalfHeight,
        );
      case JoystickSide.right:
        return Offset(
          size.width - fixedMargin - trackHalfWidth,
          size.height - fixedMargin - trackHalfHeight,
        );
    }
  }

  @override
  PlayerInput get current => _current;

  @override
  void onPointerDown(PointerDownEvent event, ArenaGeometry geometry) {
    if (_pointer != null) return;
    final size = geometry.size;
    if (event.localPosition.dy < size.height * (1 - activeFraction)) return;
    _pointer = event.pointer;
    _origin = event.localPosition;
    _dx = 0;
    _current = PlayerInput.none;
    notifyListeners();
  }

  @override
  void onPointerMove(PointerMoveEvent event, ArenaGeometry geometry) {
    if (event.pointer != _pointer) return;
    final origin = _origin;
    if (origin == null) return;
    _dx = (event.localPosition.dx - origin.dx).clamp(-maxOffset, maxOffset);
    final move = moveFor(_dx / maxOffset);
    _current = move == 0 ? PlayerInput.none : PlayerInput.moving(move);
    notifyListeners();
  }

  @override
  void onPointerUp(int pointer) {
    if (pointer != _pointer) return;
    _pointer = null;
    _origin = null;
    _dx = 0;
    _current = PlayerInput.none;
    notifyListeners();
  }

  /// Drops the current gesture (e.g. when the game pauses).
  @override
  void reset() {
    if (_pointer == null) return;
    onPointerUp(_pointer!);
  }
}
