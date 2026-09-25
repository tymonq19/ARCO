import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/foundation.dart';

import '../../app/settings.dart';
import '../../services/audio_service.dart';
import '../../services/haptics.dart';
import '../input/input_controller.dart';
import '../render/fx_state.dart';

/// Runs one endless solo game (SPEC §5.4).
///
/// Real frame time is accumulated and consumed in fixed 1/60 s steps (at most
/// [maxCatchUpSteps] per frame). Every step records the input into an
/// [InputLog] **at the same tick it is handed to [Simulation.step]**, which is
/// exactly what [ReplayVerifier] replays, so the server can re-simulate the
/// game bit-for-bit.
class SoloController extends ChangeNotifier {
  SoloController({
    required this.settings,
    required this.audio,
    required this.haptics,
    required this.input,
    int Function()? seedSource,
  }) : _seedSource = seedSource ?? _randomSeed {
    _reset(_seedSource());
  }

  /// Simulation steps a single frame may catch up (spiral-of-death guard).
  static const int maxCatchUpSteps = 5;

  final Settings settings;
  final AudioService audio;
  final Haptics haptics;
  final InputController input;
  final FxState fx = FxState();

  final int Function() _seedSource;
  final List<PlayerInput> _inputs = <PlayerInput>[PlayerInput.none];

  late GameState _state;
  late InputLog _log;
  double _accumulator = 0;
  bool _started = false;
  bool _paused = false;
  bool _newBest = false;
  Replay? _replay;
  int _hudSignature = 0;

  GameState get state => _state;

  /// Delta-encoded input log of this game; the replay is built from it.
  InputLog get inputLog => _log;

  bool get started => _started;
  bool get paused => _paused;
  bool get gameOver => _state.phase == Phase.gameOver;
  bool get running => _started && !_paused && !gameOver;

  Player get player => _state.players[0];
  int get score => player.score;
  int get lives => player.lives;
  int get multiplier => player.multiplier;
  double get elapsedSeconds => _state.elapsedSeconds;

  /// True when this game beat the stored personal best.
  bool get newBest => _newBest;

  /// Verifiable replay of the finished game; null until game over.
  Replay? get replay => _replay;

  /// Starts the first serve (tap to start).
  void start() {
    if (_started || gameOver) return;
    _started = true;
    _accumulator = 0;
    audio.play(Sfx.click);
    notifyListeners();
  }

  void pause() {
    if (!_started || _paused || gameOver) return;
    _paused = true;
    _accumulator = 0;
    input.reset();
    notifyListeners();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _accumulator = 0;
    notifyListeners();
  }

  void togglePause() => _paused ? resume() : pause();

  /// Fresh game: new seed, new input log, cleared effects.
  void retry() {
    _reset(_seedSource());
    audio.play(Sfx.click);
    notifyListeners();
  }

  /// Advances the simulation by the real time of one rendered frame.
  void advance(double dtSeconds) {
    fx.update(dtSeconds);
    if (running) {
      _accumulator += dtSeconds;
      var steps = 0;
      while (_accumulator >= dt && steps < maxCatchUpSteps) {
        _accumulator -= dt;
        steps++;
        _stepOnce();
        if (gameOver) break;
      }
      if (steps >= maxCatchUpSteps && _accumulator > dt) {
        // Dropped frames: discard the backlog instead of fast-forwarding.
        _accumulator = 0;
      }
    }
    fx.trackBall(_state.ball, smooth: false);
    _notifyIfHudChanged();
  }

  void _stepOnce() {
    final current = input.current;
    _log.record(_state.tick, current);
    _inputs[0] = current;
    Simulation.step(_state, _inputs);
    _consumeEvents();
  }

  void _consumeEvents() {
    for (final e in _state.events) {
      fx.applyEvent(e, _state);
      switch (e.type) {
        case GameEventType.serve:
          audio.play(Sfx.serve);
        case GameEventType.paddleHit:
          audio.play(Sfx.hit);
          haptics.light();
        case GameEventType.wallHit:
          audio.play(Sfx.wall);
        case GameEventType.pickup:
          audio.play(e.pickup == PickupType.heart ? Sfx.heart : Sfx.star);
          haptics.medium();
        case GameEventType.lifeLost:
          audio.play(Sfx.lose);
          haptics.heavy();
        case GameEventType.gameOver:
          _finish();
        default:
          break;
      }
    }
  }

  void _finish() {
    audio.play(Sfx.gameover);
    input.reset();
    _newBest = settings.recordScore(score);
    _replay = Replay(
      config: _state.config,
      inputs: <InputLog>[_log],
      finalTick: _state.tick,
      claimedScore: score,
    );
  }

  void _reset(int seed) {
    _state = GameState.initial(
      GameConfig(mode: GameMode.solo, seed: seed & 0xFFFFFFFF),
    );
    _log = InputLog();
    _inputs[0] = PlayerInput.none;
    _accumulator = 0;
    _started = false;
    _paused = false;
    _newBest = false;
    _replay = null;
    _hudSignature = 0;
    input.reset();
    fx.reset();
    fx.ballSmoothing = 1;
  }

  /// The HUD only shows whole seconds, lives, score, multiplier and the phase,
  /// so listeners are notified when one of those changes — not 60 times a
  /// second.
  void _notifyIfHudChanged() {
    final signature = Object.hash(
      score,
      lives,
      multiplier,
      elapsedSeconds.floor(),
      _state.phase.index,
      _paused,
      _started,
    );
    if (signature == _hudSignature) return;
    _hudSignature = signature;
    notifyListeners();
  }

  static int _randomSeed() => math.Random().nextInt(0x7FFFFFFF);

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }
}
