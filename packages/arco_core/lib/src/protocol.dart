/// WebSocket protocol shared by client and server. See SPEC.md §3.
///
/// Every frame is a JSON object with a `t` discriminator. Use [ClientMsg.parse]
/// / [ServerMsg.parse] to decode and `toJson()` + [encodeMsg] to encode.
library;

import 'dart:convert';

import 'constants.dart';
import 'model.dart';

String encodeMsg(Object msg) {
  if (msg is ClientMsg) return jsonEncode(msg.toJson());
  if (msg is ServerMsg) return jsonEncode(msg.toJson());
  throw ArgumentError('not a protocol message: $msg');
}

Map<String, dynamic>? decodeFrame(Object? frame) {
  if (frame is! String) return null;
  try {
    final j = jsonDecode(frame);
    return j is Map<String, dynamic> ? j : null;
  } on FormatException {
    return null;
  }
}

/// Uppercases, strips whitespace and returns the code if it is valid, else null.
String? normalizeRoomCode(String raw) {
  final code = raw.trim().toUpperCase();
  if (code.length != roomCodeLength) return null;
  for (final r in code.runes) {
    if (!roomCodeAlphabet.contains(String.fromCharCode(r))) return null;
  }
  return code;
}

/// Validates/normalizes a player name per SPEC §4.2; returns null if invalid.
///
/// Length is counted in characters (code points), not UTF-16 code units, so a
/// name made of astral-plane letters counts the same as an ASCII one.
String? normalizeName(String raw) {
  final name = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  final chars = name.runes.length;
  if (chars < nameMinLength || chars > nameMaxLength) return null;
  if (!RegExp(r'^[\p{L}\p{N} _-]+$', unicode: true).hasMatch(name)) return null;
  return name;
}

// ---------------------------------------------------------------- client → server

sealed class ClientMsg {
  const ClientMsg();

  Map<String, dynamic> toJson();

  static ClientMsg? parse(Map<String, dynamic> j) {
    try {
      switch (j['t']) {
        case 'hello':
          return HelloMsg(version: j['v'] as int, name: j['name'] as String);
        case 'create':
          return const CreateRoomMsg();
        case 'join':
          return JoinRoomMsg(code: j['code'] as String);
        case 'input':
          return InputMsg(tick: j['tick'] as int, input: j['i'] as int);
        case 'rematch':
          return const RematchMsg();
        case 'leave':
          return const LeaveMsg();
        case 'ping':
          return PingMsg(clientMs: j['c'] as int);
      }
    } on TypeError {
      return null;
    }
    return null;
  }

  static ClientMsg? decode(Object? frame) {
    final j = decodeFrame(frame);
    return j == null ? null : parse(j);
  }
}

class HelloMsg extends ClientMsg {
  const HelloMsg({required this.version, required this.name});
  final int version;
  final String name;
  @override
  Map<String, dynamic> toJson() => {'t': 'hello', 'v': version, 'name': name};
}

class CreateRoomMsg extends ClientMsg {
  const CreateRoomMsg();
  @override
  Map<String, dynamic> toJson() => const {'t': 'create'};
}

class JoinRoomMsg extends ClientMsg {
  const JoinRoomMsg({required this.code});
  final String code;
  @override
  Map<String, dynamic> toJson() => {'t': 'join', 'code': code};
}

class InputMsg extends ClientMsg {
  const InputMsg({required this.tick, required this.input});

  /// Client's sim tick when the input was sampled.
  final int tick;

  /// `PlayerInput.encode()` value.
  final int input;
  @override
  Map<String, dynamic> toJson() => {'t': 'input', 'tick': tick, 'i': input};
}

class RematchMsg extends ClientMsg {
  const RematchMsg();
  @override
  Map<String, dynamic> toJson() => const {'t': 'rematch'};
}

class LeaveMsg extends ClientMsg {
  const LeaveMsg();
  @override
  Map<String, dynamic> toJson() => const {'t': 'leave'};
}

class PingMsg extends ClientMsg {
  const PingMsg({required this.clientMs});
  final int clientMs;
  @override
  Map<String, dynamic> toJson() => {'t': 'ping', 'c': clientMs};
}

// ---------------------------------------------------------------- server → client

sealed class ServerMsg {
  const ServerMsg();

  Map<String, dynamic> toJson();

  static ServerMsg? parse(Map<String, dynamic> j) {
    try {
      switch (j['t']) {
        case 'welcome':
          return WelcomeMsg(version: j['v'] as int);
        case 'room':
          return RoomMsg(
            code: j['code'] as String,
            slot: j['slot'] as int,
            names: [for (final n in j['names'] as List<dynamic>) n as String?],
          );
        case 'start':
          return StartMsg(
            seed: j['seed'] as int,
            countdown: j['countdown'] as int,
            names: [for (final n in j['names'] as List<dynamic>) n as String],
          );
        case 'snap':
          return SnapMsg(
            tick: j['tick'] as int,
            state: j['s'] as Map<String, dynamic>,
            events: [
              for (final e in j['ev'] as List<dynamic>)
                GameEvent.fromJson(e as List<dynamic>),
            ],
          );
        case 'over':
          return OverMsg(
            winner: j['winner'] as int,
            scores: [for (final s in j['scores'] as List<dynamic>) s as int],
          );
        case 'peer_left':
          return const PeerLeftMsg();
        case 'pong':
          return PongMsg(clientMs: j['c'] as int, tick: j['tick'] as int);
        case 'error':
          return ErrorMsg(code: j['code'] as String);
      }
    } on TypeError {
      return null;
    }
    return null;
  }

  static ServerMsg? decode(Object? frame) {
    final j = decodeFrame(frame);
    return j == null ? null : parse(j);
  }
}

class WelcomeMsg extends ServerMsg {
  const WelcomeMsg({required this.version});
  final int version;
  @override
  Map<String, dynamic> toJson() => {'t': 'welcome', 'v': version};
}

class RoomMsg extends ServerMsg {
  const RoomMsg({required this.code, required this.slot, required this.names});
  final String code;

  /// This client's player index (0 = creator / bottom half, 1 = joiner / top half).
  final int slot;

  /// Two entries; null while a slot is empty.
  final List<String?> names;
  @override
  Map<String, dynamic> toJson() => {
    't': 'room',
    'code': code,
    'slot': slot,
    'names': names,
  };
}

class StartMsg extends ServerMsg {
  const StartMsg({
    required this.seed,
    required this.countdown,
    required this.names,
  });
  final int seed;

  /// Server ticks until sim tick 0.
  final int countdown;
  final List<String> names;
  @override
  Map<String, dynamic> toJson() => {
    't': 'start',
    'seed': seed,
    'countdown': countdown,
    'names': names,
  };
}

class SnapMsg extends ServerMsg {
  const SnapMsg({
    required this.tick,
    required this.state,
    required this.events,
  });
  final int tick;

  /// `GameState.toJson()`; decode with `GameState.fromJson`.
  final Map<String, dynamic> state;

  /// Events since the previous snapshot.
  final List<GameEvent> events;
  @override
  Map<String, dynamic> toJson() => {
    't': 'snap',
    'tick': tick,
    's': state,
    'ev': [for (final e in events) e.toJson()],
  };
}

class OverMsg extends ServerMsg {
  const OverMsg({required this.winner, required this.scores});
  final int winner;
  final List<int> scores;
  @override
  Map<String, dynamic> toJson() => {
    't': 'over',
    'winner': winner,
    'scores': scores,
  };
}

class PeerLeftMsg extends ServerMsg {
  const PeerLeftMsg();
  @override
  Map<String, dynamic> toJson() => const {'t': 'peer_left'};
}

class PongMsg extends ServerMsg {
  const PongMsg({required this.clientMs, required this.tick});
  final int clientMs;

  /// Current server sim tick of the client's room (-1 when not playing).
  final int tick;
  @override
  Map<String, dynamic> toJson() => {'t': 'pong', 'c': clientMs, 'tick': tick};
}

/// Error codes: bad_code, room_not_found, room_full, not_in_room, bad_message,
/// rate_limited, bad_version, bad_name.
class ErrorMsg extends ServerMsg {
  const ErrorMsg({required this.code});
  final String code;
  @override
  Map<String, dynamic> toJson() => {'t': 'error', 'code': code};
}
