/// One WebSocket client: protocol enforcement (hello first, bad-message
/// budget, frame size) and dispatch to the [RoomRegistry].
library;

import 'dart:async';

import 'package:arco_core/arco_core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'duel_ball_count.dart';
import 'logging.dart';
import 'rate_limit.dart';
import 'room.dart';
import 'rooms.dart';

/// Client frames longer than this are rejected as `bad_message`
/// (measured in UTF-16 code units of the text frame, i.e. ≥ bytes for ASCII).
///
/// This check can only run once `dart:io` has reassembled the frame, so the
/// wire-level `maxClientFrameBytes` guard in `ws_frame_guard.dart` refuses a
/// grossly oversized message before it is buffered at all.
const int maxClientFrameLength = 4096;

/// After this many protocol violations the socket is closed.
const int maxBadMessages = 5;

/// Client frames one socket may send per second, and how many it may send in
/// one burst.
///
/// SPEC §3 has the client send at most one `input` per tick (60/s) plus a `ping`
/// every couple of seconds, so this is ~2x the legitimate steady rate. Without
/// a budget every frame is free: `join`, `ping` and `input` are answered as fast
/// as the event loop can decode them, which both walks the 4-char room-code
/// space in seconds and starves the tick driver.
const int maxMessagesPerSecond = 120;
const int maxMessageBurst = 240;

/// After this many `join`s for a code no live room uses, the socket is closed.
///
/// Guessing is not a protocol violation - `room_not_found` is a normal reply
/// (SPEC §3) - but the code space is only 32^4, so blind guessing must end.
///
/// This budget dies with the socket, so on its own it only makes the guesser
/// reconnect; [joinMissesPerIp] is the budget that survives that.
const int maxMissedJoins = 10;

/// A socket that has not completed the `hello` handshake this long after the
/// upgrade is closed (SPEC §3: `hello` must be first). Without a deadline a
/// peer that opens a socket and says nothing stays registered forever.
const Duration helloDeadline = Duration(seconds: 5);

/// WebSocket close codes used by the server.
///
/// An endpoint may only *send* 1000 or a code from the private 4000-4999
/// range (the reserved codes 1001/1002/1008 are set by the protocol layer
/// itself), so every server-side reason lives in 40xx.
const int closeCodeNormal = 1000;
const int closeCodeShutdown = 4000;
const int closeCodeIdleTimeout = 4001;
const int closeCodeProtocolError = 4002;
const int closeCodePolicyViolation = 4008;

class ClientSession {
  ClientSession({
    required this.id,
    required this.channel,
    required this.ip,
    required this.registry,
    required this.log,
    this.helloTimeout = helloDeadline,
    TokenBucket? messageBudget,
  }) : _messages =
           messageBudget ??
           TokenBucket(
             ratePerSecond: maxMessagesPerSecond,
             burst: maxMessageBurst,
           );

  final int id;
  final WebSocketChannel channel;

  /// Client IP (from `X-Forwarded-For` or the socket); used for rate limits.
  final String ip;
  final RoomRegistry registry;
  final Logger log;

  /// How long after [listen] a missing `hello` closes the socket.
  final Duration helloTimeout;

  /// Set by a successful `hello`; null until then.
  String? name;

  Room? room;
  int slot = -1;

  /// Per-socket frame budget; an exhausted bucket closes the connection.
  final TokenBucket _messages;

  int _badMessages = 0;
  int _missedJoins = 0;
  bool _closed = false;
  bool _closing = false;
  StreamSubscription<dynamic>? _sub;
  Timer? _helloTimer;

  bool get isClosed => _closed;
  bool get hasHello => name != null;
  bool get isInRoom => room != null;
  int get badMessages => _badMessages;

  /// `join`s so far for a code that no live room uses.
  int get missedJoins => _missedJoins;

  /// Starts consuming frames. Must be called once after construction.
  void listen() {
    _sub = channel.stream.listen(
      _onFrame,
      onError: (Object e) {
        log.debug('session $id socket error: $e');
        _onDone();
      },
      onDone: _onDone,
      cancelOnError: true,
    );
    // Arms the `hello` deadline: a socket that never introduces itself holds a
    // session slot (and nothing else can reclaim it) until the peer hangs up.
    _helloTimer = Timer(helloTimeout, () {
      if (_closed || _closing || hasHello) return;
      log.info('session $id closed: no hello within $helloTimeout');
      unawaited(close(closeCodeProtocolError, 'hello_timeout'));
    });
  }

  void send(ServerMsg msg) => sendFrame(encodeMsg(msg));

  void sendFrame(String frame) {
    if (_closed || _closing) return;
    try {
      channel.sink.add(frame);
    } catch (e) {
      log.debug('session $id send failed: $e');
    }
  }

  /// Closes the socket; the registry is notified through the stream's onDone.
  Future<void> close([int code = closeCodeNormal, String? reason]) async {
    if (_closed || _closing) return;
    _closing = true;
    _helloTimer?.cancel();
    _helloTimer = null;
    try {
      await channel.sink.close(code, reason);
    } catch (e) {
      log.debug('session $id close failed: $e');
    }
    _onDone();
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    _helloTimer?.cancel();
    _helloTimer = null;
    unawaited(_sub?.cancel());
    registry.onDisconnect(this);
  }

  void _violation(String code) {
    _badMessages++;
    send(ErrorMsg(code: code));
    if (_badMessages >= maxBadMessages) {
      log.info('session $id closed after $_badMessages bad messages');
      unawaited(close(closeCodePolicyViolation, 'too many bad messages'));
    }
  }

  /// Counts a `join` for a code that is not in use (the `error` reply has
  /// already been sent) and closes the socket once either budget is spent:
  /// this socket's [maxMissedJoins] or its IP's [joinMissesPerIp], which
  /// outlives the socket and so also stops a reconnect loop.
  void _missedJoin() {
    _missedJoins++;
    final ipBudgetLeft = registry.chargeJoinMiss(ip);
    if (_missedJoins >= maxMissedJoins || !ipBudgetLeft) {
      log.info(
        'session $id closed after $_missedJoins missed joins '
        '(${registry.joinMissCount(ip)} from $ip)',
      );
      unawaited(close(closeCodePolicyViolation, 'room_code_guessing'));
    }
  }

  void _onFrame(dynamic frame) {
    if (_closed || _closing) return;
    // Metered before the frame is decoded, so a flood cannot buy event-loop
    // time with a jsonDecode per message.
    if (!_messages.take()) {
      log.info('session $id closed: more than $maxMessagesPerSecond msg/s');
      send(const ErrorMsg(code: 'rate_limited'));
      unawaited(close(closeCodePolicyViolation, 'message_rate'));
      return;
    }
    if (frame is! String) {
      _violation('bad_message');
      return;
    }
    if (frame.length > maxClientFrameLength) {
      _violation('bad_message');
      return;
    }
    // Decoded to a map first, then parsed: `create` carries the ball count in an
    // additive field core's parser does not model (see `duel_ball_count.dart`),
    // and reading it off the raw object is what keeps that field out of the
    // shared protocol classes until they carry it themselves.
    final json = decodeFrame(frame);
    if (json == null) {
      _violation('bad_message');
      return;
    }
    final msg = ClientMsg.parse(json);
    if (msg == null) {
      _violation('bad_message');
      return;
    }

    if (!hasHello) {
      if (msg is! HelloMsg) {
        _violation('bad_message');
        return;
      }
      _handleHello(msg);
      return;
    }

    switch (msg) {
      case HelloMsg():
        _violation('bad_message');
      case CreateRoomMsg():
        final balls = ballCountOf(json);
        if (balls == null) {
          // No room is created: the creator asked for a game this build cannot
          // run, and opening a different one would put both players in a match
          // nobody chose.
          _violation(badBallCountError);
          return;
        }
        registry.create(this, ballCount: balls);
      case JoinRoomMsg(:final code):
        // The per-IP budget is consulted before the code is looked up, so a
        // spent budget answers nothing a guesser could learn from.
        if (!registry.allowJoinAttempt(this)) return;
        final normalized = normalizeRoomCode(code);
        if (normalized == null) {
          send(const ErrorMsg(code: 'bad_code'));
          _missedJoin();
          return;
        }
        if (!registry.join(this, normalized)) _missedJoin();
      case InputMsg():
        final r = room;
        if (r == null) {
          send(const ErrorMsg(code: 'not_in_room'));
          return;
        }
        r.applyInput(slot, msg, registry.now());
      case RematchMsg():
        if (room == null) {
          send(const ErrorMsg(code: 'not_in_room'));
          return;
        }
        registry.rematch(this);
      case LeaveMsg():
        if (room == null) {
          send(const ErrorMsg(code: 'not_in_room'));
          return;
        }
        registry.leave(this);
      case PingMsg(:final clientMs):
        send(PongMsg(clientMs: clientMs, tick: room?.currentTick ?? -1));
    }
  }

  void _handleHello(HelloMsg msg) {
    if (msg.version != protocolVersion) {
      _badMessages++;
      send(const ErrorMsg(code: 'bad_version'));
      unawaited(close(closeCodeProtocolError, 'unsupported protocol version'));
      return;
    }
    final normalized = normalizeName(msg.name);
    if (normalized == null) {
      _violation('bad_name');
      return;
    }
    name = normalized;
    _helloTimer?.cancel();
    _helloTimer = null;
    send(const WelcomeMsg(version: protocolVersion));
    log.debug('session $id hello name="$normalized" ip=$ip');
  }

  @override
  String toString() =>
      'ClientSession#$id(${name ?? '?'}${room == null ? '' : ', room ${room!.code}/$slot'})';
}
