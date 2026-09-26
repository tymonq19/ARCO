/// Cross-process end-to-end smoke test against a *running* server.
///
///     dart run tool/e2e_smoke.dart [baseUrl]          # default http://localhost:18100
///
/// Unlike `test/` (which boots the server in the test isolate) this tool talks
/// to a separate server process over real sockets, exactly like the Flutter
/// client does, and checks the three paths that only a real deployment
/// exercises:
///
///   0. the server answers `GET /api/health`;
///   1a. a solo game recorded with the core (aim-at-ball bot for ~60 s of sim
///       time, then the paddle runs away until `gameOver`) is accepted by
///       `POST /api/scores` with 201 + a rank and shows up in
///       `GET /api/leaderboard`;
///   1b. the same replay with `claimedScore + 1` is rejected with
///       400 `replay_mismatch` (so replay verification really runs);
///   1c. a **two-ball** solo game is accepted, filed on the two-ball board and
///       is on that board only (so the board dimension of §4.6 really exists in
///       storage and not just in the query string);
///   2.  two WebSocket clients create/join a room, get `start`, receive
///       snapshots while sending inputs, the server applies those inputs, and
///       when one leaves the other receives `peer_left`;
///   3.  a room created with two balls carries that count to both players and
///       the server simulates it (so the duel ball count of §3 survives a real
///       socket, not just a test harness).
///
/// Prints `PASS`/`FAIL` per step and exits non-zero when any step failed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String defaultBaseUrl = 'http://localhost:18100';

/// Sim seconds the aim-at-ball bot plays before it starts missing on purpose.
const int botSeconds = 60;

const Duration httpTimeout = Duration(seconds: 30);
const Duration wsTimeout = Duration(seconds: 20);
const Duration healthTimeout = Duration(seconds: 30);

/// How long inputs are streamed into the duel room, and when the two clients
/// stop chasing the ball and hold a fixed aim so the applied-input assertion
/// has a target to compare against.
const Duration duelPlayFor = Duration(milliseconds: 3500);
const Duration duelHoldAfter = Duration(milliseconds: 2000);

/// A failed expectation; its message is the whole story, so no stack needed.
class _Failure implements Exception {
  _Failure(this.message);

  final String message;

  @override
  String toString() => message;
}

void _expect(bool condition, String message) {
  if (!condition) throw _Failure(message);
}

Future<void> main(List<String> args) async {
  if (args.length > 1 ||
      (args.isNotEmpty && (args.first == '-h' || args.first == '--help'))) {
    stdout.writeln('usage: dart run tool/e2e_smoke.dart [baseUrl]');
    exitCode = 64;
    return;
  }
  final raw = args.isEmpty ? defaultBaseUrl : args.first;
  final Uri base;
  try {
    base = _normalizeBase(raw);
  } on FormatException catch (e) {
    stderr.writeln('invalid base url "$raw": ${e.message}');
    exitCode = 64;
    return;
  }
  exitCode = await _Smoke(base).run();
}

/// Requires an absolute http(s) URL and makes the path end with `/` so that
/// `base.resolve('api/health')` keeps any prefix the deployment uses.
Uri _normalizeBase(String raw) {
  final uri = Uri.parse(raw.trim());
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException('scheme must be http or https');
  }
  if (uri.host.isEmpty) throw const FormatException('missing host');
  final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
  return uri.replace(path: path, query: null, fragment: null);
}

class _Smoke {
  _Smoke(this.base) : _http = _Http(base);

  final Uri base;
  final _Http _http;

  /// Name used for the submitted score; unique per run so the leaderboard
  /// lookup cannot match an entry from an earlier run.
  final String playerName = _uniqueName();

  /// The replay recorded in step 1a, reused (tampered) by step 1b.
  Replay? _replay;

  /// Runs every step in order and returns the number of failures.
  Future<int> run() async {
    stdout.writeln('arco e2e smoke');
    stdout.writeln('  base url : $base');
    stdout.writeln('  name     : $playerName');
    stdout.writeln('');
    var failures = 0;
    try {
      if (!await _run('0  server is up', _stepHealth)) {
        stdout.writeln('');
        stdout.writeln('aborted: no healthy server at $base');
        return 1;
      }
      if (!await _run('1a solo replay accepted and listed', _stepSubmit)) {
        failures++;
      }
      if (!await _run('1b tampered score rejected', _stepTampered)) failures++;
      if (!await _run('1c two-ball replay on its own board', _stepTwoBall)) {
        failures++;
      }
      if (!await _run('2  duel room over two WebSockets', _stepDuel)) {
        failures++;
      }
      if (!await _run('3  two-ball duel room', _stepTwoBallDuel)) failures++;
    } finally {
      _http.close();
    }
    stdout.writeln('');
    stdout.writeln(
      failures == 0 ? 'ALL STEPS PASSED' : '$failures STEP(S) FAILED',
    );
    return failures == 0 ? 0 : 1;
  }

  Future<bool> _run(String name, Future<void> Function() body) async {
    final watch = Stopwatch()..start();
    try {
      await body();
      stdout.writeln('PASS  $name  (${_ms(watch)})');
      return true;
    } catch (e, st) {
      stdout.writeln('FAIL  $name  (${_ms(watch)})');
      stdout.writeln('      $e');
      if (e is! _Failure) {
        for (final line in st.toString().split('\n').take(5)) {
          stdout.writeln('      $line');
        }
      }
      return false;
    }
  }

  static String _ms(Stopwatch w) => '${w.elapsedMilliseconds} ms';

  // ------------------------------------------------------------------ step 0

  Future<void> _stepHealth() async {
    final watch = Stopwatch()..start();
    Object? last;
    while (watch.elapsed < healthTimeout) {
      try {
        final res = await _http.get('api/health');
        if (res.status == 200) {
          final body = res.json;
          _expect(body['ok'] == true, 'health returned ok=${body['ok']}');
          stdout.writeln(
            '      version=${body['version']} rooms=${body['rooms']}',
          );
          return;
        }
        last = 'HTTP ${res.status}: ${res.body}';
      } catch (e) {
        last = e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw _Failure('not healthy within $healthTimeout (last: $last)');
  }

  // ----------------------------------------------------------------- step 1a

  Future<void> _stepSubmit() async {
    final watch = Stopwatch()..start();
    final replay = _recordSoloGame();
    _replay = replay;
    final local = ReplayVerifier.verify(replay);
    stdout.writeln(
      '      recorded ${replay.finalTick} ticks '
      '(${replay.finalTick / tickRate} s) score=${replay.claimedScore} '
      'inputs=${replay.inputs[0].length} in ${_ms(watch)}',
    );
    _expect(
      local.ok,
      'the recorded replay does not even verify locally: $local',
    );

    final res = await _http.postJson('api/scores', {
      'name': playerName,
      'replay': replay.toJson(),
    });
    _expect(
      res.status == 201,
      'POST /api/scores returned ${res.status}, expected 201: ${res.body}',
    );
    final body = res.json;
    _expect(body['ok'] == true, 'submission body says ok=${body['ok']}');
    final score = body['score'];
    final rank = body['rank'];
    final id = body['id'];
    _expect(
      score == replay.claimedScore,
      'server verified score $score, client claimed ${replay.claimedScore}',
    );
    _expect(rank is int && rank >= 1, 'bad rank $rank');
    _expect(id is String && id.isNotEmpty, 'bad id $id');
    stdout.writeln('      201 id=$id score=$score rank=$rank');

    _expect(
      body['balls'] == 1,
      'a one-ball run was filed on board ${body['balls']}',
    );

    // No `balls` parameter: a client that has never heard of boards asks the
    // question it always asked and must get the classic board (§4.6).
    final list = await _http.get('api/leaderboard', {
      'period': 'all',
      'limit': '100',
    });
    _expect(
      list.status == 200,
      'GET /api/leaderboard returned ${list.status}: ${list.body}',
    );
    _expect(
      list.json['balls'] == 1,
      'the default board is ${list.json['balls']}, expected 1',
    );
    final entries = (list.json['entries'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final mine = entries.where((e) => e['name'] == playerName).toList();
    _expect(
      mine.length == 1,
      'expected exactly one leaderboard entry named "$playerName", '
      'found ${mine.length} among ${entries.length} entries',
    );
    final entry = mine.single;
    _expect(
      entry['score'] == replay.claimedScore,
      'leaderboard score ${entry['score']} != ${replay.claimedScore}',
    );
    _expect(
      entry['seconds'] == replay.finalTick ~/ tickRate,
      'leaderboard seconds ${entry['seconds']} != '
      '${replay.finalTick ~/ tickRate}',
    );
    _expect(
      entry['rank'] == rank,
      'leaderboard rank ${entry['rank']} != submission rank $rank',
    );
    final createdAt = entry['createdAt'];
    _expect(
      createdAt is String && DateTime.tryParse(createdAt) != null,
      'bad createdAt $createdAt',
    );
    stdout.writeln(
      '      leaderboard rank=${entry['rank']} score=${entry['score']} '
      'seconds=${entry['seconds']} createdAt=$createdAt '
      '(${entries.length} entries)',
    );

    // The same run must not also be on the two-ball board.
    _expect(
      !await _isOnBoard(playerName, 2),
      'the one-ball run shows up on the two-ball board',
    );
  }

  /// Whether a leaderboard entry named [name] is on the [balls] board.
  Future<bool> _isOnBoard(String name, int balls) async {
    final res = await _http.get('api/leaderboard', {
      'period': 'all',
      'limit': '100',
      'balls': '$balls',
    });
    _expect(
      res.status == 200,
      'GET /api/leaderboard?balls=$balls returned ${res.status}: ${res.body}',
    );
    _expect(
      res.json['balls'] == balls,
      'asked for board $balls, got ${res.json['balls']}',
    );
    return (res.json['entries'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .any((e) => e['name'] == name);
  }

  /// Plays a full solo game with the core: an aim-at-ball bot for the first
  /// [botSeconds] of sim time, then [ScriptedInput.avoidBall] so the ball
  /// escapes three times and the game reaches [Phase.gameOver]. Every tick's
  /// input is recorded, so the server can re-simulate the game exactly.
  Replay _recordSoloGame({int ballCount = minBallCount}) {
    final state = GameState.initial(
      GameConfig(
        mode: GameMode.solo,
        seed: DateTime.now().microsecond + 1,
        ballCount: ballCount,
      ),
    );
    final log = InputLog();
    final inputs = <PlayerInput>[PlayerInput.none];
    final aimUntil = botSeconds * tickRate;
    while (state.phase != Phase.gameOver &&
        state.tick < ReplayVerifier.maxTicks) {
      final input = state.tick < aimUntil
          ? ScriptedInput.aimAtBall(state, 0)
          : ScriptedInput.avoidBall(state, 0);
      log.record(state.tick, input);
      inputs[0] = input;
      Simulation.step(state, inputs);
    }
    _expect(
      state.phase == Phase.gameOver,
      'the bot never finished the game (${state.tick} ticks)',
    );
    return Replay(
      config: state.config,
      inputs: <InputLog>[log],
      finalTick: state.tick,
      claimedScore: state.players[0].score,
    );
  }

  // ----------------------------------------------------------------- step 1b

  Future<void> _stepTampered() async {
    final replay = _replay;
    _expect(replay != null, 'step 1a did not produce a replay');
    final tampered = Replay(
      config: replay!.config,
      inputs: replay.inputs,
      finalTick: replay.finalTick,
      claimedScore: replay.claimedScore + 1,
    );
    final res = await _http.postJson('api/scores', {
      'name': playerName,
      'replay': tampered.toJson(),
    });
    _expect(
      res.status == 400,
      'POST /api/scores with a tampered score returned ${res.status}, '
      'expected 400: ${res.body}',
    );
    final body = res.json;
    _expect(body['ok'] == false, 'tampered submission says ok=${body['ok']}');
    _expect(
      body['error'] == 'replay_mismatch',
      'expected error replay_mismatch, got ${body['error']}',
    );
    stdout.writeln(
      '      400 error=${body['error']} detail=${body['detail']} '
      '(claimed ${tampered.claimedScore} instead of ${replay.claimedScore})',
    );
  }

  // ----------------------------------------------------------------- step 1c

  /// A two-ball solo game is a different board, not a different leaderboard:
  /// the run is verified the same way and stored beside the classic ones, but
  /// it appears only where two-ball runs belong (§4.6).
  Future<void> _stepTwoBall() async {
    final name = '$playerName-2';
    final replay = _recordSoloGame(ballCount: 2);
    _expect(replay.config.ballCount == 2, 'the fixture is not a two-ball run');
    final local = ReplayVerifier.verify(replay);
    _expect(local.ok, 'the two-ball replay does not verify locally: $local');
    stdout.writeln(
      '      recorded ${replay.finalTick} ticks score=${replay.claimedScore} '
      'inputs=${replay.inputs[0].length}',
    );

    final res = await _http.postJson('api/scores', {
      'name': name,
      'replay': replay.toJson(),
    });
    _expect(
      res.status == 201,
      'POST /api/scores (two balls) returned ${res.status}: ${res.body}',
    );
    _expect(
      res.json['balls'] == 2,
      'a two-ball run was filed on board ${res.json['balls']}',
    );
    _expect(
      res.json['score'] == replay.claimedScore,
      'server verified ${res.json['score']}, client claimed '
      '${replay.claimedScore}',
    );
    stdout.writeln(
      '      201 balls=2 score=${res.json['score']} rank=${res.json['rank']}',
    );

    _expect(
      await _isOnBoard(name, 2),
      'the two-ball run is missing from the two-ball board',
    );
    _expect(
      !await _isOnBoard(name, 1),
      'the two-ball run appears on the classic board, which would make that '
      'board meaningless',
    );
  }

  // ------------------------------------------------------------------ step 2

  Future<void> _stepDuel() async {
    final a = await _WsClient.connect(base, 'A', 'E2E-A');
    final b = await _WsClient.connect(base, 'B', 'E2E-B');
    try {
      a.send(const CreateRoomMsg());
      final roomA = await a.waitFor<RoomMsg>();
      _expect(roomA.slot == 0, 'creator got slot ${roomA.slot}, expected 0');
      _expect(
        roomA.code.length == roomCodeLength &&
            normalizeRoomCode(roomA.code) == roomA.code,
        'bad room code "${roomA.code}"',
      );
      _expect(
        roomA.names[0] == 'E2E-A' && roomA.names[1] == null,
        'fresh room names ${roomA.names}',
      );

      b.send(JoinRoomMsg(code: roomA.code));
      final roomB = await b.waitFor<RoomMsg>();
      _expect(
        roomB.code == roomA.code,
        'joined ${roomB.code}, not ${roomA.code}',
      );
      _expect(roomB.slot == 1, 'joiner got slot ${roomB.slot}, expected 1');
      _expect(
        roomB.names[0] == 'E2E-A' && roomB.names[1] == 'E2E-B',
        'room names after join: ${roomB.names}',
      );
      stdout.writeln('      room ${roomA.code} with ${roomB.names}');

      final startA = await a.waitFor<StartMsg>();
      final startB = await b.waitFor<StartMsg>();
      _expect(
        startA.seed == startB.seed,
        'clients got different seeds: ${startA.seed} vs ${startB.seed}',
      );
      _expect(
        startA.countdown == countdownTicks,
        'countdown ${startA.countdown} != $countdownTicks',
      );
      stdout.writeln(
        '      start seed=${startA.seed} countdown=${startA.countdown}',
      );

      await _waitUntil(
        () => a.snapshotCount > 0 && b.snapshotCount > 0,
        timeout: wsTimeout,
        what: 'the first snapshot of both clients (countdown is 3 s)',
      );

      // Both clients aim at the ball from the snapshots they receive, then
      // hold a fixed angle inside their own half so the last snapshot proves
      // the server really applied their inputs.
      const targets = <double>[DetMath.pi + 0.9, 0.9];
      final watch = Stopwatch()..start();
      var tick = 0;
      while (watch.elapsed < duelPlayFor) {
        final hold = watch.elapsed >= duelHoldAfter;
        for (var slot = 0; slot < 2; slot++) {
          final client = slot == 0 ? a : b;
          final input = hold
              ? PlayerInput.aimAngle(targets[slot])
              : client.aimAtBall(slot);
          client.send(InputMsg(tick: tick, input: input.encode()));
        }
        tick++;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      stdout.writeln(
        '      sent $tick inputs per client in ${_ms(watch)}; '
        'snapshots A=${a.snapshotCount} B=${b.snapshotCount}; '
        'last tick A=${a.lastTick} B=${b.lastTick}',
      );
      _expect(
        a.badFrames.isEmpty && b.badFrames.isEmpty,
        'unparsable frames: ${a.badFrames}${b.badFrames}',
      );
      _expect(
        a.snapshotCount >= 10,
        'client A got only ${a.snapshotCount} snapshots',
      );
      _expect(
        b.snapshotCount >= 10,
        'client B got only ${b.snapshotCount} snapshots',
      );
      _expect(a.lastTick >= 30, 'last snapshot tick ${a.lastTick} is too low');
      _expect(
        (a.lastTick - b.lastTick).abs() <= snapshotInterval,
        'clients are ${a.lastTick - b.lastTick} ticks apart',
      );

      final last = a.decodeLastSnapshot();
      _expect(last != null, 'no snapshot to inspect');
      if (a.sawOver || b.sawOver) {
        stdout.writeln(
          '      note: the duel reached game over during the run, '
          'skipping the applied-input check',
        );
      } else {
        for (var slot = 0; slot < 2; slot++) {
          final angle = last!.players[slot].paddle.angle;
          final off = DetMath.angleDiff(targets[slot], angle).abs();
          _expect(
            off < 0.05,
            'server did not apply slot $slot input: paddle at $angle, '
            'aimed at ${targets[slot]} (off by $off rad)',
          );
        }
        stdout.writeln(
          '      both paddles reached the angle their client aimed at',
        );
      }

      a.send(const LeaveMsg());
      await b.waitFor<PeerLeftMsg>();
      stdout.writeln('      B received peer_left after A left');
    } finally {
      await a.dispose();
      await b.dispose();
    }
  }

  // ------------------------------------------------------------------- step 3

  /// A duel room the creator asked for two balls in (§3).
  ///
  /// Both players have to be told the count — the joiner *before* the countdown
  /// — and the server has to simulate it, which the snapshots prove: the config
  /// inside them names two balls and the ball list has two entries.
  Future<void> _stepTwoBallDuel() async {
    final a = await _WsClient.connect(base, 'A', '$playerName-A');
    final b = await _WsClient.connect(base, 'B', '$playerName-B');
    try {
      a.sendFrame(jsonEncode({'t': 'create', ballCountField: 2}));
      final roomA = await a.waitFor<RoomMsg>();
      _expect(
        a.frameOf('room')[ballCountField] == 2,
        'the creator was told ${a.frameOf('room')[ballCountField]} ball(s)',
      );

      b.send(JoinRoomMsg(code: roomA.code));
      await b.waitFor<RoomMsg>();
      _expect(
        b.frameOf('room')[ballCountField] == 2,
        'the joiner was told ${b.frameOf('room')[ballCountField]} ball(s) '
        'before the countdown',
      );

      final startA = await a.waitFor<StartMsg>();
      await b.waitFor<StartMsg>();
      for (final client in [a, b]) {
        _expect(
          client.frameOf('start')[ballCountField] == 2,
          '${client.label}: start says '
          '${client.frameOf('start')[ballCountField]} ball(s)',
        );
      }
      stdout.writeln('      room ${roomA.code} balls=2 seed=${startA.seed}');

      await _waitUntil(
        () => a.snapshotCount > 0 && b.snapshotCount > 0,
        timeout: wsTimeout,
        what: 'the first snapshot of both clients (countdown is 3 s)',
      );
      for (final client in [a, b]) {
        final state = client.decodeLastSnapshot();
        _expect(state != null, '${client.label}: no snapshot to inspect');
        _expect(
          state!.config.ballCount == 2,
          '${client.label}: the simulated config has '
          '${state.config.ballCount} ball(s)',
        );
        _expect(
          state.balls.length == 2,
          '${client.label}: the snapshot carries ${state.balls.length} ball(s)',
        );
      }
      _expect(
        a.badFrames.isEmpty && b.badFrames.isEmpty,
        'unparsable frames: ${a.badFrames}${b.badFrames}',
      );
      stdout.writeln(
        '      both clients simulate two balls '
        '(snapshots A=${a.snapshotCount} B=${b.snapshotCount})',
      );
    } finally {
      await a.dispose();
      await b.dispose();
    }
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  required Duration timeout,
  required String what,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      throw _Failure('timed out after $timeout waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

String _uniqueName() {
  final ms = DateTime.now().millisecondsSinceEpoch % 100000;
  return 'E2E-${ms.toString().padLeft(5, '0')}';
}

// --------------------------------------------------------------------- HTTP

class _Response {
  _Response(this.status, this.body);

  final int status;
  final String body;

  Map<String, dynamic> get json {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw _Failure('expected a JSON object, got $body');
    }
    return decoded;
  }
}

class _Http {
  _Http(this.base);

  final Uri base;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  Future<_Response> get(String path, [Map<String, String>? query]) async {
    var uri = base.resolve(path);
    if (query != null) uri = uri.replace(queryParameters: query);
    final request = await _client.getUrl(uri).timeout(httpTimeout);
    return _read(await request.close().timeout(httpTimeout));
  }

  Future<_Response> postJson(String path, Object body) async {
    final request = await _client
        .postUrl(base.resolve(path))
        .timeout(httpTimeout);
    final bytes = utf8.encode(jsonEncode(body));
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
    return _read(await request.close().timeout(httpTimeout));
  }

  Future<_Response> _read(HttpClientResponse response) async {
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(httpTimeout);
    return _Response(response.statusCode, body);
  }

  void close() => _client.close(force: true);
}

// ---------------------------------------------------------------- WebSocket

/// A WebSocket client with a typed inbox. Snapshots are counted instead of
/// queued (there are 20 per second), everything else waits in [_inbox].
class _WsClient {
  _WsClient._(this.label, this._channel) {
    _sub = _channel.stream.listen(_onFrame, onError: _onError, onDone: _onDone);
  }

  /// Connects to `/ws`, sends `hello` and waits for `welcome`.
  static Future<_WsClient> connect(Uri base, String label, String name) async {
    final wsBase = base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');
    final channel = WebSocketChannel.connect(wsBase.resolve('ws'));
    await channel.ready.timeout(wsTimeout);
    final client = _WsClient._(label, channel);
    client.send(HelloMsg(version: protocolVersion, name: name));
    final welcome = await client.waitFor<WelcomeMsg>();
    _expect(
      welcome.version == protocolVersion,
      '$label: server speaks protocol ${welcome.version}',
    );
    return client;
  }

  final String label;
  final WebSocketChannel _channel;
  late final StreamSubscription<dynamic> _sub;

  final List<ServerMsg> _inbox = <ServerMsg>[];
  final List<Completer<ServerMsg>> _waiters = <Completer<ServerMsg>>[];

  /// Frames the shared protocol parser could not decode (must stay empty).
  final List<String> badFrames = <String>[];

  int snapshotCount = 0;
  int lastTick = -1;
  bool sawOver = false;

  Map<String, dynamic>? _lastSnapshot;

  /// The newest raw frame of each type, by `t`. Kept because a frame may carry
  /// fields the shared parser does not model yet — the duel ball count is one
  /// (§3) — and this tool exists to check what actually crosses the socket.
  final Map<String, Map<String, dynamic>> lastFrames =
      <String, Map<String, dynamic>>{};

  bool _done = false;
  Object? _error;

  void send(ClientMsg msg) => _channel.sink.add(encodeMsg(msg));

  /// Sends a frame this tool built itself, for a field the shared classes do
  /// not carry yet.
  void sendFrame(String frame) => _channel.sink.add(frame);

  /// The newest frame of type [t], as raw JSON.
  Map<String, dynamic> frameOf(String t) {
    final frame = lastFrames[t];
    _expect(frame != null, '$label: never received a "$t" frame');
    return frame!;
  }

  GameState? decodeLastSnapshot() {
    final snapshot = _lastSnapshot;
    return snapshot == null ? null : GameState.fromJson(snapshot);
  }

  /// Aim-at-ball input for [slot] based on the newest snapshot.
  PlayerInput aimAtBall(int slot) {
    final state = decodeLastSnapshot();
    return state == null
        ? PlayerInput.none
        : ScriptedInput.aimAtBall(state, slot);
  }

  /// The next message of type [T]; other messages are discarded, an
  /// [ErrorMsg] fails the step.
  Future<T> waitFor<T extends ServerMsg>({Duration timeout = wsTimeout}) async {
    final watch = Stopwatch()..start();
    while (true) {
      final left = timeout - watch.elapsed;
      if (left <= Duration.zero) {
        throw _Failure('$label: no $T within $timeout');
      }
      final msg = await _take(left);
      if (msg is T) return msg;
      if (msg is ErrorMsg) {
        throw _Failure('$label: server error "${msg.code}" while awaiting $T');
      }
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
    try {
      await _channel.sink.close();
    } catch (_) {
      // Already gone.
    }
  }

  void _onFrame(Object? frame) {
    if (frame is String) {
      final json = decodeFrame(frame);
      final type = json?['t'];
      if (json != null && type is String) lastFrames[type] = json;
    }
    final msg = frame is String ? ServerMsg.decode(frame) : null;
    if (msg == null) {
      badFrames.add('$frame');
      return;
    }
    if (msg is SnapMsg) {
      snapshotCount++;
      lastTick = msg.tick;
      _lastSnapshot = msg.state;
      return;
    }
    if (msg is OverMsg) sawOver = true;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(msg);
    } else {
      _inbox.add(msg);
    }
  }

  void _onError(Object error) => _finish(error);

  void _onDone() => _finish(null);

  void _finish(Object? error) {
    if (_done) return;
    _done = true;
    _error = error;
    final waiters = List<Completer<ServerMsg>>.of(_waiters);
    _waiters.clear();
    for (final w in waiters) {
      w.completeError(_Failure(_closedMessage));
    }
  }

  String get _closedMessage =>
      '$label: socket closed (code ${_channel.closeCode})'
      '${_error == null ? '' : ': $_error'}';

  Future<ServerMsg> _take(Duration timeout) {
    if (_inbox.isNotEmpty) return Future<ServerMsg>.value(_inbox.removeAt(0));
    if (_done) return Future<ServerMsg>.error(_Failure(_closedMessage));
    final completer = Completer<ServerMsg>();
    _waiters.add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(completer);
        throw _Failure('$label: no frame within $timeout');
      },
    );
  }
}
