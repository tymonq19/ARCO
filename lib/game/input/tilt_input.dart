import 'dart:async';
import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Orientation;
import 'package:sensors_plus/sensors_plus.dart';

import '../../app/settings.dart';
import 'input_controller.dart';

/// Tilt control from the accelerometer's gravity vector (SPEC §5.2).
///
/// The raw stream is low-pass filtered (α = 0.15). Roll is `atan2(ax, ay)` in
/// portrait (the axes are swapped in landscape, see [rollFor]) minus the
/// calibrated baseline; `move = round(clamp(roll / maxRoll, -1, 1) * 16)`
/// with `maxRoll = 0.35 rad / sensitivity` and a 0.04 rad dead zone.
class TiltInput extends ChangeNotifier
    with IdempotentDispose
    implements InputController {
  TiltInput({required this.settings, Stream<AccelerometerEvent>? source})
    : _source = source {
    _subscribe();
  }

  static const double alpha = 0.15;
  static const double baseMaxRoll = 0.35;
  static const double deadZone = 0.04;

  final Settings settings;

  /// Stream to sample; null means the real `sensors_plus` one. Kept so
  /// [resume] can open the same source again after [pause].
  final Stream<AccelerometerEvent>? _source;

  StreamSubscription<AccelerometerEvent>? _sub;
  bool _closed = false;
  double _ax = 0;
  double _ay = 9.81;
  bool _hasSample = false;
  bool _available = true;

  /// Set by the view from `MediaQuery.orientationOf`.
  Orientation orientation = Orientation.portrait;

  /// False when the platform has no accelerometer (desktop, tests).
  bool get available => _available;
  bool get hasSample => _hasSample;

  void _subscribe() {
    try {
      final stream =
          _source ??
          accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval);
      _sub = stream.listen(
        _onEvent,
        onError: (Object e) {
          _available = false;
          notifyListeners();
        },
        cancelOnError: true,
      );
    } on Object {
      _available = false;
    }
  }

  void _onEvent(AccelerometerEvent e) {
    if (!_hasSample) {
      _ax = e.x;
      _ay = e.y;
      _hasSample = true;
    } else {
      _ax += alpha * (e.x - _ax);
      _ay += alpha * (e.y - _ay);
    }
    notifyListeners();
  }

  /// Roll for the filtered gravity vector. Portrait: `atan2(ax, ay)`. In
  /// landscape the screen's "up" is the device's ±x axis, so the axes are
  /// rotated: `+x up → atan2(-ay, ax)`, `−x up → atan2(ay, -ax)`.
  static double rollFor(double ax, double ay, Orientation orientation) {
    if (orientation == Orientation.portrait) return math.atan2(ax, ay);
    return ax >= 0 ? math.atan2(-ay, ax) : math.atan2(ay, -ax);
  }

  /// Pure mapping from a baseline-relative roll to `move`.
  ///
  /// Sign: with the Android/iOS accelerometer convention a LEFT tilt (left
  /// edge down) yields `ax > 0`, hence a positive roll. The paddle must then
  /// move LEFT on screen, which is a DEcreasing angle at the bottom of the
  /// ring (see [JoystickInput] for the angle/screen mapping), so the value is
  /// negated.
  static int moveFor(double roll, double sensitivity) {
    if (roll.abs() < deadZone) return 0;
    final maxRoll = baseMaxRoll / sensitivity;
    final n = (roll / maxRoll).clamp(-1.0, 1.0);
    return -(n * inputMoveMax).round();
  }

  /// Uncalibrated roll in radians.
  double get rawRoll => rollFor(_ax, _ay, orientation);

  /// Roll relative to the calibrated baseline, wrapped to (−π, π].
  double get roll {
    var r = rawRoll - settings.tiltBaseline;
    if (r > math.pi) r -= 2 * math.pi;
    if (r <= -math.pi) r += 2 * math.pi;
    return r;
  }

  /// Normalized deflection −1..1 for the live preview in Settings.
  double get normalized {
    final maxRoll = baseMaxRoll / settings.tiltSensitivity;
    return (roll / maxRoll).clamp(-1.0, 1.0);
  }

  /// Stores the current roll as "level".
  void calibrate() {
    settings.tiltBaseline = rawRoll;
    notifyListeners();
  }

  @override
  PlayerInput get current {
    // While paused the gravity vector is frozen at the last sample, so it must
    // not be reported as live input: it would keep pushing the paddle.
    if (!_hasSample || _sub == null) return PlayerInput.none;
    final m = moveFor(roll, settings.tiltSensitivity);
    return m == 0 ? PlayerInput.none : PlayerInput.moving(m);
  }

  /// Nothing to release: the filtered gravity vector stays valid while the
  /// game is paused.
  @override
  void reset() {}

  /// Closes the accelerometer stream while no match is live, so the duel lobby
  /// and the result overlay stop waking the sensor at 50 Hz; [current] reads
  /// [PlayerInput.none] until [resume]. The filtered gravity vector and the
  /// calibration survive, so [resume] carries on from the last sample instead
  /// of re-seeding from the first new one.
  @override
  void pause() {
    _sub?.cancel();
    _sub = null;
  }

  /// Re-opens the stream after [pause]. A no-op while it is already open,
  /// after [dispose], and when the platform has no accelerometer.
  @override
  void resume() {
    if (_sub != null || _closed || !_available) return;
    _subscribe();
  }

  @override
  void dispose() {
    _closed = true;
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
