import 'package:flutter/services.dart';

import '../app/settings.dart';

/// Haptic feedback gated by the Settings switch. Light on paddle hits, medium
/// on pickups, heavy on life loss (SPEC §5.5).
///
/// Every strength is rate-limited for the same reason the sound effects collapse
/// repeats: a fast rally lands a paddle hit every ~115 ms and a frame can carry
/// two, and firing the light impact on each one turns the phone into a buzzer
/// while queueing platform calls faster than the taptic engine can play them.
/// The limits are per strength, so the pickup or the life loss in the middle of
/// a rally is never swallowed by the paddle hits around it.
class Haptics {
  Haptics(this._settings, {Duration Function()? clock})
    : _clock = clock ?? _monotonic();

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// Minimum gap between two impacts of the same strength.
  static const Duration lightGap = Duration(milliseconds: 45);
  static const Duration mediumGap = Duration(milliseconds: 110);
  static const Duration heavyGap = Duration(milliseconds: 220);
  static const Duration selectionGap = Duration(milliseconds: 45);

  final Settings _settings;
  final Duration Function() _clock;
  final Map<_Kind, Duration> _last = <_Kind, Duration>{};

  bool get enabled => _settings.haptics;

  void light() {
    if (_due(_Kind.light, lightGap)) HapticFeedback.lightImpact();
  }

  void medium() {
    if (_due(_Kind.medium, mediumGap)) HapticFeedback.mediumImpact();
  }

  void heavy() {
    if (_due(_Kind.heavy, heavyGap)) HapticFeedback.heavyImpact();
  }

  void selection() {
    if (_due(_Kind.selection, selectionGap)) HapticFeedback.selectionClick();
  }

  /// True when this strength is enabled and has not fired within [gap]. Keyed by
  /// [kind] and not by the gap, because a light impact and a selection click
  /// share the same interval but must not suppress each other.
  bool _due(_Kind kind, Duration gap) {
    if (!enabled) return false;
    final now = _clock();
    final last = _last[kind];
    if (last != null && now - last < gap) return false;
    _last[kind] = now;
    return true;
  }
}

enum _Kind { light, medium, heavy, selection }
