/// Room registry: code generation, join/leave, caps, idle cleanup and the
/// single 60 Hz tick driver that steps every running room (SPEC §3).
library;

import 'dart:async';
import 'dart:math';

import 'package:arco_core/arco_core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'logging.dart';
import 'rate_limit.dart';
import 'room.dart';
import 'session.dart';

/// Rooms a single IP may create per minute (SPEC §3).
const int roomsPerIpPerMinute = 4;

/// `join`s naming no live room that one client IP may spend inside
/// [joinMissWindow]; past it every further `join` from that IP is refused
/// without looking the code up at all.
///
/// The per-socket budget ([maxMissedJoins]) ends one socket's guessing, but a
/// reconnect loop pays only a WebSocket handshake per socket: measured at
/// ~4900 codes/s from a single IP, which walks all 32^4 = 1 048 576 codes in
/// under four minutes and finds every waiting room. Keyed by `clientIp()`, the
/// budget survives reconnects, so enumeration drops to 20 codes per 10 minutes
/// - about a year for the whole space.
///
/// 20 misses per 10 minutes is far more than honest play costs: a mistyped code
/// is one miss, and only codes that name no live room count, so retrying a code
/// that exists (`room_full`) is free. Two players behind one NAT share the
/// budget and still have ~10 mistypes each; `create` is never refused by it, so
/// even an IP that has spent its budget can still host a room and share the
/// code.
const int joinMissesPerIp = 20;

/// Window over which [joinMissesPerIp] is counted.
const Duration joinMissWindow = Duration(minutes: 10);

/// Hard cap on simultaneously live rooms (SPEC §3).
const int maxLiveRooms = 500;

/// Hard cap on simultaneously connected WebSocket sessions.
///
/// SPEC §3 caps live rooms at 500, i.e. 1000 seated players; the rest of the
/// budget covers clients sitting in the lobby. Without a cap the room limit
/// alone leaves the memory behind unroomed sessions unmetered.
const int maxLiveSessions = 2000;

/// Hard cap on simultaneously connected sessions from one client IP.
///
/// `clientIp` resolves `X-Forwarded-For` behind a proxy, so this counts real
/// clients; it is set high enough that only a single abusive source hits it.
const int maxLiveSessionsPerIp = 64;

/// Minimum gap between two "tick driver starved" warnings.
///
/// A blocked event loop hits the catch-up cap on every timer callback, so the
/// warning reports the ticks lost since the previous line instead of printing
/// one line per callback.
const Duration droppedTickReportInterval = Duration(seconds: 1);

class RoomRegistry {
  RoomRegistry({
    required this.log,
    this.maxRooms = maxLiveRooms,
    this.maxSessions = maxLiveSessions,
    this.maxSessionsPerIp = maxLiveSessionsPerIp,
    this.helloTimeout = helloDeadline,
    this.idleTimeout = const Duration(minutes: 10),
    this.sweepInterval = const Duration(seconds: 30),
    this.tickMultiplier = 1,
    this.maxCatchUpTicks = 5,
    Random? random,
    DateTime Function()? clock,
    RateLimiter? createLimiter,
    RateLimiter? joinMissLimiter,
  }) : assert(tickMultiplier >= 1),
       _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now,
       _createLimiter =
           createLimiter ??
           RateLimiter(
             limit: roomsPerIpPerMinute,
             window: const Duration(minutes: 1),
           ),
       _joinMissLimiter =
           joinMissLimiter ??
           RateLimiter(limit: joinMissesPerIp, window: joinMissWindow);

  final Logger log;

  /// Hard cap on live rooms (SPEC §3: 500).
  final int maxRooms;

  /// Hard caps on concurrent sessions, globally and per client IP.
  final int maxSessions;
  final int maxSessionsPerIp;

  /// Deadline handed to every new [ClientSession] for its `hello`.
  final Duration helloTimeout;

  /// Rooms that are not playing (waiting for a friend, or finished without a
  /// rematch) and idle longer than this are destroyed.
  final Duration idleTimeout;
  final Duration sweepInterval;

  /// TEST-ONLY HOOK. Scales the tick clock: `n` means the driver advances
  /// rooms at `n × 60` ticks per real second so an end-to-end test can play a
  /// whole duel in a few seconds. Production always uses 1.
  final int tickMultiplier;

  /// Maximum ticks processed per timer callback (spiral-of-death guard).
  /// Backlog beyond it is dropped: the sim slows down instead of snowballing.
  final int maxCatchUpTicks;

  final Random _random;
  final DateTime Function() _clock;
  final RateLimiter _createLimiter;

  /// Per-IP budget for `join`s that name no live room ([joinMissesPerIp]).
  final RateLimiter _joinMissLimiter;

  final Map<String, Room> _rooms = <String, Room>{};
  final Set<ClientSession> _sessions = <ClientSession>{};

  /// Live session count per client IP; keys are dropped as they reach zero, so
  /// this map is bounded by the number of connected clients.
  final Map<String, int> _sessionsPerIp = <String, int>{};

  Timer? _tickTimer;
  Timer? _sweepTimer;
  final Stopwatch _stopwatch = Stopwatch();
  int _ticksDone = 0;
  int _droppedTicks = 0;

  /// Ticks dropped since the last warning, and when that warning went out;
  /// null means nothing has been reported yet, so the first drop is logged at
  /// once (see [droppedTickReportInterval]).
  int _droppedSinceReport = 0;
  DateTime? _lastDropReport;
  int _nextSessionId = 1;
  bool _closed = false;

  int get roomCount => _rooms.length;
  int get sessionCount => _sessions.length;
  Iterable<Room> get rooms => _rooms.values;
  Room? roomByCode(String code) => _rooms[code];

  /// Total ticks the driver has executed since [start].
  int get ticksDone => _ticksDone;

  /// Ticks dropped because of the catch-up cap.
  int get droppedTicks => _droppedTicks;

  DateTime now() => _clock();

  // ------------------------------------------------------------- lifecycle

  /// Starts the tick driver and the idle sweeper.
  void start() {
    if (_tickTimer != null) return;
    _stopwatch
      ..reset()
      ..start();
    _ticksDone = 0;
    // One period per tick at 1×; at n× the timer fires n times as often so
    // the driver never needs more than ~1 tick per callback.
    final periodMicros = max(1000, (1000000 ~/ tickRate) ~/ tickMultiplier);
    _tickTimer = Timer.periodic(
      Duration(microseconds: periodMicros),
      (_) => _onTick(),
    );
    _sweepTimer = Timer.periodic(sweepInterval, (_) => sweep());
  }

  /// Stops the timers and closes every connection (server shutdown).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _tickTimer?.cancel();
    _sweepTimer?.cancel();
    _tickTimer = null;
    _sweepTimer = null;
    _stopwatch.stop();
    final sessions = List<ClientSession>.of(_sessions);
    _rooms.clear();
    await Future.wait([
      for (final s in sessions) s.close(closeCodeShutdown, 'server shutdown'),
    ]);
    _sessions.clear();
    _sessionsPerIp.clear();
  }

  /// Wraps a freshly upgraded socket in a session and starts listening.
  ClientSession accept(WebSocketChannel channel, String ip) {
    final session = ClientSession(
      id: _nextSessionId++,
      channel: channel,
      ip: ip,
      registry: this,
      log: log,
      helloTimeout: helloTimeout,
    );
    if (_closed) {
      unawaited(session.close(closeCodeShutdown, 'server shutdown'));
      return session;
    }
    final refusal = _refuseReason(ip);
    if (refusal != null) {
      log.warn('refusing session from $ip: $refusal');
      session.send(const ErrorMsg(code: 'rate_limited'));
      unawaited(session.close(closeCodePolicyViolation, refusal));
      return session;
    }
    _sessions.add(session);
    _sessionsPerIp.update(ip, (n) => n + 1, ifAbsent: () => 1);
    session.listen();
    log.debug(
      'session ${session.id} connected from $ip (${_sessions.length} online)',
    );
    return session;
  }

  /// Why a socket from [ip] must not be accepted, or null when it may be.
  ///
  /// The caps bound the memory a peer can hold before it has done anything at
  /// all: [maxRooms] only meters clients that got as far as `create`.
  String? _refuseReason(String ip) {
    if (_sessions.length >= maxSessions) return 'session_cap';
    if ((_sessionsPerIp[ip] ?? 0) >= maxSessionsPerIp) {
      return 'session_cap_per_ip';
    }
    return null;
  }

  // ------------------------------------------------------------- tick driver

  void _onTick() {
    // Exact 60 Hz (× multiplier) from the stopwatch, independent of timer jitter.
    final due =
        _stopwatch.elapsedMicroseconds * tickRate * tickMultiplier ~/ 1000000;
    catchUpTo(due);
  }

  /// Runs the driver up to tick [due], at most [maxCatchUpTicks] per call; the
  /// rest of the backlog is dropped so a slow callback cannot snowball.
  ///
  /// Public so tests can drive the catch-up cap without real timers.
  void catchUpTo(int due) {
    var n = 0;
    while (_ticksDone < due && n < maxCatchUpTicks) {
      tickAll();
      _ticksDone++;
      n++;
    }
    if (_ticksDone < due) {
      final lost = due - _ticksDone;
      _droppedTicks += lost;
      _ticksDone = due;
      _reportDropped(lost);
    } else if (_droppedSinceReport > 0) {
      // A burst that ended while the warning was throttled still has to be
      // accounted for, so the log is flushed on the first healthy callback
      // past the interval.
      _reportDropped(0);
    }
  }

  /// Warns that the driver lost [lost] ticks, at most once per
  /// [droppedTickReportInterval].
  ///
  /// A dropped tick is real time the simulation never spends: every seated
  /// player runs in slow motion while their client keeps predicting forward,
  /// so the next snapshot corrects them backwards and the game visibly
  /// stutters. [droppedTicks] alone is in-memory, so without this line a
  /// starved event loop leaves nothing at all in the server log.
  void _reportDropped(int lost) {
    _droppedSinceReport += lost;
    final now = _clock();
    final last = _lastDropReport;
    if (last != null && now.difference(last) < droppedTickReportInterval) {
      return;
    }
    _lastDropReport = now;
    final since = _droppedSinceReport;
    _droppedSinceReport = 0;
    log.warn(
      'tick driver starved: dropped $since ticks ($_droppedTicks total, cap '
      '$maxCatchUpTicks per callback), rooms run slow; '
      '$_runningRoomCount/${_rooms.length} rooms running, '
      '${_sessions.length} sessions',
    );
  }

  /// Rooms the driver is currently stepping (see [Room.isRunning]).
  int get _runningRoomCount => _rooms.values.where((r) => r.isRunning).length;

  /// Advances every running room by one tick. Public so tests can drive the
  /// registry without timers.
  void tickAll() {
    if (_rooms.isEmpty) return;
    for (final room in List<Room>.of(_rooms.values)) {
      if (!room.isRunning) continue;
      try {
        room.tick();
      } catch (e, st) {
        log.error('room ${room.code} tick failed, destroying room', e, st);
        _destroy(room, notify: true);
      }
    }
  }

  // ------------------------------------------------------------- rooms

  /// A fresh 4-char code over [roomCodeAlphabet] that no live room uses.
  String generateCode() => generateRoomCode(_random, _rooms.containsKey);

  /// Draws codes from [random] over [roomCodeAlphabet] until [isTaken] says the
  /// code is free. Exposed (and pure) so the generator can be tested directly.
  static String generateRoomCode(
    Random random,
    bool Function(String code) isTaken,
  ) {
    while (true) {
      final units = List<int>.generate(
        roomCodeLength,
        (_) => roomCodeAlphabet.codeUnitAt(
          random.nextInt(roomCodeAlphabet.length),
        ),
      );
      final code = String.fromCharCodes(units);
      if (!isTaken(code)) return code;
    }
  }

  int newSeed() => _random.nextInt(1 << 32);

  /// Handles `create`: leaves the current room if any, enforces caps, seats
  /// the player in slot 0 and replies with `room`.
  ///
  /// [ballCount] is the creator's choice of how many balls every game in this
  /// room is played with (SPEC §3); it is fixed for the room's life and is
  /// reported in the `room` message both players receive.
  void create(ClientSession session, {int ballCount = minBallCount}) {
    // Caps are checked before the caller's current room is torn down, so a
    // refused create leaves the client exactly where it was.
    if (_rooms.length >= maxRooms) {
      log.warn(
        'room cap reached ($maxRooms), refusing create from ${session.ip}',
      );
      session.send(const ErrorMsg(code: 'rate_limited'));
      return;
    }
    if (!_createLimiter.allow(session.ip)) {
      session.send(const ErrorMsg(code: 'rate_limited'));
      return;
    }
    if (session.room != null) leave(session);
    final now = _clock();
    final room = Room(generateCode(), now: now, ballCount: ballCount);
    _rooms[room.code] = room;
    room.addPlayer(session, now);
    room.broadcastRoomInfo();
    log.info(
      'room ${room.code} created by ${session.name} with $ballCount ball(s) '
      '(${_rooms.length} rooms)',
    );
  }

  /// Misses currently counted against [ip] (diagnostics / tests).
  int joinMissCount(String ip) => _joinMissLimiter.count(ip);

  /// Whether a `join` from [session] may be answered at all.
  ///
  /// Checked *before* the code is looked up: the whole value of a guess is the
  /// difference between `room_not_found` and `room`/`room_full`, so an IP that
  /// has spent its [joinMissesPerIp] budget must not learn which of the two it
  /// would have got. On refusal the client is told `rate_limited` and the socket
  /// is closed, which is also what makes the reconnect loop pointless: every
  /// fresh socket from that IP is cut off on its first `join`.
  bool allowJoinAttempt(ClientSession session) {
    final budget = _joinMissLimiter.limit;
    if (_joinMissLimiter.count(session.ip) < budget) return true;
    log.warn(
      'refusing join from ${session.ip}: more than $budget missed joins per '
      '${_joinMissLimiter.window.inMinutes} min (room code guessing)',
    );
    session.send(const ErrorMsg(code: 'rate_limited'));
    unawaited(session.close(closeCodePolicyViolation, 'room_code_guessing'));
    return false;
  }

  /// Records a `join` from [ip] that named no live room and returns whether
  /// that IP has budget left afterwards.
  bool chargeJoinMiss(String ip) {
    _joinMissLimiter.allow(ip);
    return _joinMissLimiter.count(ip) < _joinMissLimiter.limit;
  }

  /// Handles `join`: [code] must already be normalized, and
  /// [allowJoinAttempt] must have passed. Replies with `room` or an `error`
  /// itself.
  ///
  /// Returns false when no live room has that code, which the caller meters:
  /// the reply leaks nothing on its own, but 32^4 codes are few enough that
  /// unlimited guessing enumerates every open room.
  bool join(ClientSession session, String code) {
    final room = _rooms[code];
    if (room == null) {
      session.send(const ErrorMsg(code: 'room_not_found'));
      return false;
    }
    if (room.isFull || room.state != RoomState.waiting) {
      session.send(const ErrorMsg(code: 'room_full'));
      return true;
    }
    if (session.room == room) {
      room.broadcastRoomInfo();
      return true;
    }
    if (session.room != null) leave(session);
    final now = _clock();
    room.addPlayer(session, now);
    room.broadcastRoomInfo();
    log.info('room ${room.code}: ${session.name} joined');
    if (room.isFull) room.begin(newSeed(), now);
    return true;
  }

  void rematch(ClientSession session) {
    final room = session.room;
    if (room == null) return;
    if (room.voteRematch(session.slot, _clock())) {
      log.info('room ${room.code}: rematch');
      room.begin(newSeed(), _clock());
    }
  }

  /// Handles `leave` and disconnects: the peer receives `peer_left` and the
  /// room is destroyed; both players are back in the lobby.
  void leave(ClientSession session) {
    final room = session.room;
    if (room == null) return;
    if (_closed) {
      room.removePlayer(session);
      return;
    }
    final peer = room.peerOf(session);
    room.removePlayer(session);
    peer?.send(const PeerLeftMsg());
    _destroy(room, notify: false);
    log.info('room ${room.code}: ${session.name} left');
  }

  void onDisconnect(ClientSession session) {
    if (!_sessions.remove(session)) return;
    final left = (_sessionsPerIp[session.ip] ?? 1) - 1;
    if (left <= 0) {
      _sessionsPerIp.remove(session.ip);
    } else {
      _sessionsPerIp[session.ip] = left;
    }
    leave(session);
    log.debug(
      'session ${session.id} disconnected (${_sessions.length} online)',
    );
  }

  void _destroy(Room room, {required bool notify}) {
    _rooms.remove(room.code);
    for (final s in List<ClientSession?>.of(room.slots)) {
      if (s == null) continue;
      room.removePlayer(s);
      if (notify) s.send(const PeerLeftMsg());
    }
  }

  /// Destroys rooms that are not running and have been idle longer than
  /// [idleTimeout]; their remaining player is disconnected with close code
  /// [closeCodeIdleTimeout]. Also prunes the create rate limiter.
  void sweep() {
    final now = _clock();
    for (final room in List<Room>.of(_rooms.values)) {
      if (room.isRunning) continue;
      if (now.difference(room.lastActivity) <= idleTimeout) continue;
      log.info(
        'room ${room.code} idle for ${idleTimeout.inMinutes} min, destroying',
      );
      final players = [for (final s in room.slots) ?s];
      _destroy(room, notify: false);
      for (final s in players) {
        unawaited(s.close(closeCodeIdleTimeout, 'idle_timeout'));
      }
    }
    _createLimiter.sweep();
    _joinMissLimiter.sweep();
  }
}
