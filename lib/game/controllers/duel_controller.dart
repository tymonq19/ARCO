import 'dart:async';

import 'package:arco_core/arco_core.dart';
import 'package:flutter/foundation.dart';

import '../../app/settings.dart';
import '../../services/audio_service.dart';
import '../../services/duel_client.dart';
import '../../services/haptics.dart';
import '../input/input_controller.dart';
import '../render/fx_state.dart';

/// Online duel: wraps [DuelClient] and runs the client-side prediction of
/// SPEC §3.
///
/// The local [GameState] is stepped every tick with the own input in the own
/// slot and [PlayerInput.none] for the opponent, which keeps the own paddle
/// perfectly responsive. Each snapshot replaces the local state, except the
/// predicted own paddle angle, which is kept unless it drifted more than
/// [paddleSnapTolerance] rad. Audio and effects are driven by the snapshot
/// events only, so nothing is played twice; each kind of event may do so at
/// most once per rendered frame, so a burst of snapshots that queued up during
/// a stall cannot machine-gun ten identical hits at once.
class DuelController extends ChangeNotifier {
  DuelController({
    required this.client,
    required this.settings,
    required this.audio,
    required this.haptics,
    required this.input,
  }) {
    client.addListener(_onClientChanged);
    _subscription = client.messages.listen(_onMessage);
    // Nothing is steerable until a match starts, so the sensors of the control
    // mode stay closed through the lobby and the waiting room; every path in
    // and out of a live match pauses or resumes them (SPEC §5.1: the lobby is
    // a waiting room, the arena is where input happens).
    input.pause();
  }

  /// Simulation steps a single frame may catch up.
  static const int maxCatchUpSteps = 5;

  /// Above this difference (radians) the own paddle snaps to the server.
  static const double paddleSnapTolerance = 0.2;

  /// Input keep-alive: resend at least every this many ticks.
  static const int inputResendTicks = 10;

  final DuelClient client;
  final Settings settings;
  final AudioService audio;
  final Haptics haptics;
  final InputController input;
  final FxState fx = FxState();

  late final StreamSubscription<ServerMsg> _subscription;
  final List<PlayerInput> _inputs = <PlayerInput>[
    PlayerInput.none,
    PlayerInput.none,
  ];

  GameState? _state;
  double _accumulator = 0;
  int _countdownTicksLeft = 0;
  int _countdownSecond = -1;
  bool _over = false;
  bool _peerLeft = false;
  bool _rematchRequested = false;
  int _winner = -1;
  List<int> _scores = const <int>[0, 0];
  String? _error;
  int _lastSentTick = -1000;
  int _highestSentTick = -1000;
  PlayerInput? _lastSentInput;
  int _hudSignature = 0;
  int _matchSlot = 0;
  int _feedbackDone = 0;

  // ------------------------------------------------------------------ getters

  GameState? get state => _state;
  DuelClientState get status => client.state;
  int? get ping => client.pingMs;
  String? get roomCode => client.roomCode;

  /// Own player index; 0 (bottom half) for the host, 1 (top half) for the
  /// joiner. Latched from the `room` message so the rendered side of a match
  /// can never change while it is on screen.
  int get slot => _matchSlot;

  /// True for player 1, whose board is rendered rotated by 180°.
  bool get rotated => _matchSlot == 1;

  List<String> get names => <String>[
    client.names.isNotEmpty ? (client.names[0] ?? '') : '',
    client.names.length > 1 ? (client.names[1] ?? '') : '',
  ];

  String get ownName => names[slot];
  String get opponentName => names[1 - slot];

  bool get hasMatch => _state != null;
  bool get inCountdown => _countdownTicksLeft > 0;
  int get countdownSeconds => (_countdownTicksLeft / tickRate).ceil();
  bool get over => _over;
  bool get peerLeft => _peerLeft;
  bool get rematchRequested => _rematchRequested;
  int get winner => _winner;
  bool get won => _winner >= 0 && _winner == slot;
  List<int> get scores => _scores;
  String? get error => _error;

  Player? get me {
    final s = _state;
    return s != null && slot < s.players.length ? s.players[slot] : null;
  }

  Player? get opponent {
    final s = _state;
    final other = 1 - slot;
    return s != null && other < s.players.length ? s.players[other] : null;
  }

  // ------------------------------------------------------------------ commands

  /// Connects and asks the server for a fresh room code.
  Future<void> createRoom(String name) async {
    _error = null;
    await client.connect(name);
    client.createRoom();
  }

  /// Connects and joins [code].
  Future<void> joinRoom(String name, String code) async {
    _error = null;
    await client.connect(name);
    client.joinRoom(code);
  }

  void rematch() {
    if (!_over) return;
    _rematchRequested = true;
    _error = null;
    client.rematch();
    notifyListeners();
  }

  /// Leaves the room but keeps the connection (back to the lobby).
  void leaveRoom() {
    _state = null;
    _over = false;
    _peerLeft = false;
    _rematchRequested = false;
    _winner = -1;
    _countdownTicksLeft = 0;
    fx.reset();
    input.reset();
    input.pause();
    client.leave();
    notifyListeners();
  }

  Future<void> disconnect() => client.disconnect();

  /// Clears a transient error message (after showing it).
  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  // -------------------------------------------------------------------- frames

  /// Advances the local prediction by the real time of one rendered frame.
  void advance(double dtSeconds) {
    // A new frame: every kind of event may be felt and heard again.
    _feedbackDone = 0;
    fx.update(dtSeconds);
    final s = _state;
    if (s == null) return;
    _accumulator += dtSeconds;
    var steps = 0;
    while (_accumulator >= dt && steps < maxCatchUpSteps) {
      _accumulator -= dt;
      steps++;
      if (_countdownTicksLeft > 0) {
        _countdownTicksLeft--;
        final second = countdownSeconds;
        if (second != _countdownSecond) {
          _countdownSecond = second;
          audio.play(Sfx.countdown);
        }
        continue;
      }
      if (_over) break;
      _stepLocal(s);
    }
    if (steps >= maxCatchUpSteps && _accumulator > dt) _accumulator = 0;
    fx.trackBall(s.ball);
    _notifyIfHudChanged();
  }

  void _stepLocal(GameState s) {
    final own = input.current;
    for (var i = 0; i < _inputs.length; i++) {
      _inputs[i] = i == slot ? own : PlayerInput.none;
    }
    _sendInput(s.tick, own);
    Simulation.step(s, _inputs);
  }

  void _sendInput(int tick, PlayerInput value) {
    // A snapshot replaces the local state, so the local tick goes back to the
    // server tick the snapshot was taken at whenever it arrives later than the
    // client predicted. The server ignores inputs older than the last one it
    // accepted (SPEC §3), so the outgoing tick must never go backwards; it is
    // only used for ordering there, and the latest input always wins.
    final sendTick = tick > _highestSentTick ? tick : _highestSentTick;
    if (value == _lastSentInput &&
        sendTick - _lastSentTick < inputResendTicks) {
      return;
    }
    _lastSentInput = value;
    _lastSentTick = sendTick;
    _highestSentTick = sendTick;
    client.sendInput(sendTick, value);
  }

  // ------------------------------------------------------------------ messages

  void _onClientChanged() {
    if (client.lastError != null) _error = client.lastError;
    notifyListeners();
  }

  void _onMessage(ServerMsg msg) {
    switch (msg) {
      case StartMsg():
        _beginMatch(msg);
      case SnapMsg():
        _applySnapshot(msg);
      case OverMsg():
        _finish(msg);
      case PeerLeftMsg():
        _peerLeft = true;
        input.reset();
        input.pause();
        notifyListeners();
      case ErrorMsg():
        _error = msg.code;
        notifyListeners();
      case RoomMsg():
        _matchSlot = msg.slot == 1 ? 1 : 0;
        _error = null;
        notifyListeners();
      case WelcomeMsg():
      case PongMsg():
        break;
    }
  }

  void _beginMatch(StartMsg msg) {
    _state = GameState.initial(
      GameConfig(mode: GameMode.duel, seed: msg.seed & 0xFFFFFFFF),
    );
    _countdownTicksLeft = msg.countdown;
    _countdownSecond = -1;
    _accumulator = 0;
    _over = false;
    _peerLeft = false;
    _rematchRequested = false;
    _winner = -1;
    _scores = const <int>[0, 0];
    _error = null;
    _lastSentTick = -1000;
    _highestSentTick = -1000;
    _lastSentInput = null;
    _hudSignature = 0;
    _feedbackDone = 0;
    input.reset();
    input.resume();
    fx.reset();
    // Snapshot corrections are smoothed over about three frames.
    fx.ballSmoothing = 0.4;
    notifyListeners();
  }

  void _applySnapshot(SnapMsg msg) {
    final local = _state;
    final next = GameState.fromJson(msg.state);
    if (local != null &&
        slot < local.players.length &&
        slot < next.players.length) {
      final predicted = local.players[slot].paddle.angle;
      final authoritative = next.players[slot].paddle.angle;
      if (DetMath.angleDiff(authoritative, predicted).abs() <=
          paddleSnapTolerance) {
        next.players[slot].paddle.angle = predicted;
      }
    }
    _state = next;
    if (_countdownTicksLeft > 0) {
      // The server is already simulating: drop the remaining countdown.
      _countdownTicksLeft = 0;
      _countdownSecond = 0;
    }
    for (final e in msg.events) {
      // When several snapshots land between two frames — a UI-thread stall or
      // a network hiccup queues them at 20 Hz — only the newest state survives,
      // so replaying every snapshot's events would fire a burst of overlapping
      // sounds and shakes for hits that are already half a second old. One
      // round of feedback per event kind per frame is enough to feel them.
      final kind = 1 << e.type.index;
      if (_feedbackDone & kind != 0) continue;
      _feedbackDone |= kind;
      fx.applyEvent(e, next, ownPlayer: slot);
      _feedback(e);
    }
    _notifyIfHudChanged();
  }

  void _feedback(GameEvent e) {
    final mine = e.player == slot;
    switch (e.type) {
      case GameEventType.serve:
        audio.play(Sfx.serve);
      case GameEventType.paddleHit:
        audio.play(Sfx.hit);
        if (mine) haptics.light();
      case GameEventType.wallHit:
        audio.play(Sfx.wall);
      case GameEventType.pickup:
        audio.play(e.pickup == PickupType.heart ? Sfx.heart : Sfx.star);
        if (mine) haptics.medium();
      case GameEventType.lifeLost:
        audio.play(Sfx.lose);
        if (mine) haptics.heavy();
      default:
        break;
    }
  }

  void _finish(OverMsg msg) {
    _over = true;
    _winner = msg.winner;
    _scores = msg.scores;
    _rematchRequested = false;
    _countdownTicksLeft = 0;
    input.reset();
    input.pause();
    audio.play(won ? Sfx.win : Sfx.gameover);
    haptics.heavy();
    fx.shake = 1;
    notifyListeners();
  }

  void _notifyIfHudChanged() {
    final s = _state;
    final signature = Object.hash(
      s?.tick == null ? 0 : (s!.tick ~/ tickRate),
      s?.players[0].score ?? 0,
      s != null && s.players.length > 1 ? s.players[1].score : 0,
      s?.players[0].lives ?? 0,
      s != null && s.players.length > 1 ? s.players[1].lives : 0,
      s?.phase.index ?? -1,
      countdownSeconds,
      _over,
      _peerLeft,
    );
    if (signature == _hudSignature) return;
    _hudSignature = signature;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription.cancel();
    client.removeListener(_onClientChanged);
    input.dispose();
    client.dispose();
    super.dispose();
  }
}
