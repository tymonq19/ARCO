/// Player input and the delta-encoded per-player input log. See SPEC.md §2.4.
library;

import 'constants.dart';
import 'det_math.dart';

class PlayerInput {
  const PlayerInput({this.move = 0, this.aim = -1})
    : assert(move >= -inputMoveMax && move <= inputMoveMax),
      assert(aim >= -1 && aim < inputAimSteps);

  /// -16..16 → angular velocity = move / 16 × paddleSpeed. Only used when [aim] < 0.
  final int move;

  /// -1 = none; otherwise 0..4095 → target angle = aim × tau / 4096.
  final int aim;

  static const PlayerInput none = PlayerInput();

  factory PlayerInput.moving(int move) =>
      PlayerInput(move: move.clamp(-inputMoveMax, inputMoveMax));

  factory PlayerInput.aiming(int aim) => PlayerInput(aim: aim);

  /// Quantizes an angle in radians (any range) to an aim input.
  factory PlayerInput.aimAngle(double angle) {
    final a = DetMath.normAngle(angle);
    var q = (a * inputAimSteps / DetMath.tau).floor();
    if (q >= inputAimSteps) q = 0;
    if (q < 0) q = 0;
    return PlayerInput(aim: q);
  }

  bool get hasAim => aim >= 0;

  double get targetAngle => aim * DetMath.tau / inputAimSteps;

  /// Largest value [encode] can return (4128).
  static const int maxEncoded = 2 * inputMoveMax + inputAimSteps;

  int encode() => aim < 0 ? move + inputMoveMax : (2 * inputMoveMax + 1) + aim;

  static PlayerInput decode(int v) {
    if (v < 0 || v > maxEncoded) return none;
    if (v <= 2 * inputMoveMax) return PlayerInput(move: v - inputMoveMax);
    return PlayerInput(aim: v - (2 * inputMoveMax + 1));
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerInput && other.move == move && other.aim == aim;

  @override
  int get hashCode => Object.hash(move, aim);

  @override
  String toString() => 'PlayerInput(move: $move, aim: $aim)';
}

/// Delta-encoded inputs of ONE player: an entry is stored only when the input
/// differs from the previously recorded one.
class InputLog {
  InputLog();

  final List<int> _ticks = <int>[];
  final List<int> _values = <int>[];

  int get length => _ticks.length;
  int get lastTick => _ticks.isEmpty ? -1 : _ticks.last;

  /// Records [input] for [tick]. Ticks must be non-decreasing; a repeated tick
  /// overwrites the previous entry for that tick. Unchanged inputs are skipped.
  void record(int tick, PlayerInput input) {
    final v = input.encode();
    if (_ticks.isNotEmpty) {
      if (tick < _ticks.last) {
        throw ArgumentError(
          'InputLog.record: tick $tick < last ${_ticks.last}',
        );
      }
      if (tick == _ticks.last) {
        final prev = _values.length >= 2
            ? _values[_values.length - 2]
            : PlayerInput.none.encode();
        if (prev == v) {
          _ticks.removeLast();
          _values.removeLast();
        } else {
          _values[_values.length - 1] = v;
        }
        return;
      }
      if (_values.last == v) return;
    } else if (v == PlayerInput.none.encode()) {
      return;
    }
    _ticks.add(tick);
    _values.add(v);
  }

  /// Input in effect at [tick]: the last recorded value at or before it.
  PlayerInput inputAt(int tick) {
    var lo = 0;
    var hi = _ticks.length - 1;
    var idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_ticks[mid] <= tick) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return idx < 0 ? PlayerInput.none : PlayerInput.decode(_values[idx]);
  }

  List<List<int>> toJson() => [
    for (var i = 0; i < _ticks.length; i++) [_ticks[i], _values[i]],
  ];

  factory InputLog.fromJson(List<dynamic> json) {
    final log = InputLog();
    for (final e in json) {
      final pair = e as List<dynamic>;
      log.record(pair[0] as int, PlayerInput.decode(pair[1] as int));
    }
    return log;
  }
}
