/// Replays: a seed plus the input logs, verifiable by re-simulation. SPEC §2.5.
library;

import 'dart:convert';

import 'input.dart';
import 'model.dart';
import 'simulation.dart';

class Replay {
  const Replay({
    required this.config,
    required this.inputs,
    required this.finalTick,
    required this.claimedScore,
    this.formatVersion = version,
  });

  static const int version = 1;

  final GameConfig config;

  /// One log per player (`config.playerCount` entries).
  final List<InputLog> inputs;

  /// Tick at which the game reached [Phase.gameOver].
  final int finalTick;

  /// Player 0's score as computed by the client.
  final int claimedScore;

  /// Replay format version this instance carries (see [version]).
  final int formatVersion;

  Map<String, dynamic> toJson() => {
    'v': formatVersion,
    'cfg': config.toJson(),
    'in': [for (final l in inputs) l.toJson()],
    'ft': finalTick,
    'sc': claimedScore,
  };

  factory Replay.fromJson(Map<String, dynamic> j) => Replay(
    config: GameConfig.fromJson(j['cfg'] as Map<String, dynamic>),
    inputs: [
      for (final l in j['in'] as List<dynamic>)
        InputLog.fromJson(l as List<dynamic>),
    ],
    finalTick: j['ft'] as int,
    claimedScore: j['sc'] as int,
    formatVersion: j['v'] as int,
  );

  String encode() => jsonEncode(toJson());

  factory Replay.decode(String s) =>
      Replay.fromJson(jsonDecode(s) as Map<String, dynamic>);
}

class ReplayResult {
  const ReplayResult({
    required this.ok,
    this.reason,
    this.score = 0,
    this.ticks = 0,
    this.hash = 0,
    this.lives = 0,
  });

  final bool ok;

  /// `unsupported_version | bad_inputs | too_long | not_finished | score_mismatch | wrong_mode`.
  final String? reason;
  final int score;
  final int ticks;
  final int hash;
  final int lives;

  @override
  String toString() =>
      'ReplayResult(ok: $ok, reason: $reason, score: $score, ticks: $ticks)';
}

/// Re-simulates a [Replay] and checks it against the claim.
class ReplayVerifier {
  ReplayVerifier._();

  static const int maxTicks = 216000; // 1 hour of play

  /// Solo replays only (mode must be solo). Runs the sim from `config.seed`,
  /// applying `inputs[p].inputAt(tick)` each tick, until `phase == gameOver`
  /// or `finalTick` steps were taken. ok iff the game ended (gameOver) at
  /// exactly `finalTick` (i.e. `state.tick == finalTick` right after the step
  /// that set gameOver), `finalTick <= maxTicks`, and
  /// `players[0].score == claimedScore`.
  ///
  /// Failure reasons: `unsupported_version`, `wrong_mode`, `bad_inputs`
  /// (wrong number of logs or a non-monotonic / out-of-range log), `too_long`,
  /// `not_finished` (no gameOver by finalTick), `early_finish` (gameOver
  /// before finalTick) and `score_mismatch`. Whenever the simulation ran, the
  /// result carries the simulated score, ticks, hash and lives.
  static ReplayResult verify(Replay r) {
    if (r.formatVersion != Replay.version) {
      return const ReplayResult(ok: false, reason: 'unsupported_version');
    }
    if (r.config.mode != GameMode.solo) {
      return const ReplayResult(ok: false, reason: 'wrong_mode');
    }
    if (r.inputs.length != r.config.playerCount) {
      return const ReplayResult(ok: false, reason: 'bad_inputs');
    }
    for (final log in r.inputs) {
      if (!_isWellFormed(log)) {
        return const ReplayResult(ok: false, reason: 'bad_inputs');
      }
    }
    if (r.finalTick > maxTicks) {
      return const ReplayResult(ok: false, reason: 'too_long');
    }
    if (r.finalTick <= 0) {
      return const ReplayResult(ok: false, reason: 'not_finished');
    }

    final state = GameState.initial(r.config);
    final entries = r.inputs[0].toJson();
    final inputs = <PlayerInput>[PlayerInput.none];
    var cursor = 0;
    var current = PlayerInput.none;
    while (state.tick < r.finalTick && state.phase != Phase.gameOver) {
      while (cursor < entries.length && entries[cursor][0] <= state.tick) {
        current = PlayerInput.decode(entries[cursor][1]);
        cursor++;
      }
      inputs[0] = current;
      Simulation.step(state, inputs);
    }

    final score = state.players[0].score;
    final lives = state.players[0].lives;
    final hash = state.hash();
    if (state.phase != Phase.gameOver) {
      return ReplayResult(
        ok: false,
        reason: 'not_finished',
        score: score,
        ticks: state.tick,
        hash: hash,
        lives: lives,
      );
    }
    if (state.tick != r.finalTick) {
      return ReplayResult(
        ok: false,
        reason: 'early_finish',
        score: score,
        ticks: state.tick,
        hash: hash,
        lives: lives,
      );
    }
    if (score != r.claimedScore) {
      return ReplayResult(
        ok: false,
        reason: 'score_mismatch',
        score: score,
        ticks: state.tick,
        hash: hash,
        lives: lives,
      );
    }
    return ReplayResult(
      ok: true,
      score: score,
      ticks: state.tick,
      hash: hash,
      lives: lives,
    );
  }

  /// Strictly increasing non-negative ticks and encodable input values.
  static bool _isWellFormed(InputLog log) {
    var last = -1;
    for (final e in log.toJson()) {
      final tick = e[0];
      final value = e[1];
      if (tick <= last) return false;
      if (value < 0 || value > PlayerInput.maxEncoded) return false;
      last = tick;
    }
    return true;
  }
}
