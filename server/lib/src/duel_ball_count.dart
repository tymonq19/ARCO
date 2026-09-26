/// The ball count a duel room plays with, and how it travels over the
/// WebSocket protocol of SPEC §3.
///
/// A duel is two people playing **one** simulation, so both ends have to build
/// the same [GameConfig] — including its `ballCount`, which changes the game
/// completely. The creator of the room chooses it; the joining player is told
/// what they are joining before the countdown starts; and the config the server
/// simulates is the only authority, so neither client can play a different game
/// by asking for one.
///
/// It travels as one additive JSON field, [ballCountField], on the three frames
/// that describe a room: `create` (the creator's choice), `room` (what the room
/// is, sent to both players on join) and `start` (what the game about to run
/// is). The field is additive on purpose:
///
/// * a frame carrying it still parses with core's `ClientMsg.parse` /
///   `ServerMsg.parse`, which read named keys and ignore the rest, so nothing
///   that exists today breaks;
/// * a `create` **without** it is one ball, which is what a client that does not
///   know about ball counts means and the only game it can draw;
/// * and a client that ignores `n` on `start` still converges, because the
///   config is inside every `snap` (`GameState.toJson()['cfg']['n']`) — the
///   field only saves it from playing the countdown with the wrong ball count.
///
/// The server attaches the field to every `room` and `start` it sends, even when
/// the count is 1, so a client can tell from any room message whether it is
/// talking to a server that knows about ball counts at all.
library;

import 'dart:convert';

import 'package:arco_core/arco_core.dart';

/// JSON key the ball count travels under (SPEC §3).
const String ballCountField = 'n';

/// A `create` naming a ball count this build cannot simulate.
///
/// Refused rather than quietly rounded into range: a room silently opened with
/// one ball when the creator asked for two would have both players staring at a
/// game neither of them chose, and the creator's own screen would disagree with
/// the server for the whole match.
const String badBallCountError = 'bad_balls';

/// The ball count a decoded client frame asks for.
///
/// An absent field is [minBallCount] — the classic game, and what a client that
/// has never heard of ball counts is asking for. A field that is present but is
/// not an integer this build can run is null, i.e. [badBallCountError].
int? ballCountOf(Map<String, dynamic> frame) {
  final raw = frame[ballCountField];
  if (raw == null) return minBallCount;
  if (raw is! int || raw < minBallCount || raw > maxBallCount) return null;
  return raw;
}

/// Encodes [msg] with [ballCount] attached under [ballCountField].
String encodeWithBallCount(ServerMsg msg, int ballCount) =>
    jsonEncode({...msg.toJson(), ballCountField: ballCount});
