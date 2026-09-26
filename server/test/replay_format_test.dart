/// Replay format version and the two-ball replay (SPEC §2.5, §4).
///
/// The product rule under test: a replay recorded by an older build cannot be
/// re-simulated by this one — the simulation itself changed — so it has to be
/// refused **before** anything is simulated, and with a meaning the app can put
/// on screen as *update the app*, never as *your score was refused*. A player who
/// has just finished a good run must not be told their game was rejected when
/// what is actually wrong is their app version.
library;

import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

/// The body an **old** client sends: replay format 1, and a config with no ball
/// count at all, because ball counts did not exist when it was written.
Map<String, dynamic> legacyBody(
  Replay replay, {
  String name = 'Veteran',
  int? finalTick,
  List<dynamic>? inputs,
}) => {
  'name': name,
  'replay': {
    'v': 1,
    'cfg': {'m': replay.config.mode.index, 's': replay.config.seed},
    'in': inputs ?? [for (final log in replay.inputs) log.toJson()],
    'ft': finalTick ?? replay.finalTick,
    'sc': replay.claimedScore,
  },
};

void main() {
  late ArcoServer server;
  late Replay oneBall;
  late Replay twoBall;

  setUpAll(() {
    oneBall = recordScoringSoloReplay(seed: 20260923);
    twoBall = recordScoringSoloReplay(seed: 20260923, ballCount: 2);
  });

  setUp(() async {
    server = await bootServer();
  });

  Map<String, dynamic> decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Future<http.Response> post(Object body, {String? authorization}) => http.post(
    Uri.parse('${server.baseUrl}/api/scores'),
    headers: {
      'content-type': 'application/json',
      'authorization': ?authorization,
    },
    body: body is String ? body : jsonEncode(body),
  );

  group('a replay from an older build', () {
    test('is refused as unsupported_version, not as a bad score', () async {
      final r = await post(legacyBody(oneBall));
      expect(r.statusCode, 400, reason: r.body);
      final json = decode(r);
      expect(json['error'], 'unsupported_version');
      expect(
        json['error'],
        isNot('replay_mismatch'),
        reason: 'this is about the app version, not about the run',
      );
      // The detail names both versions, so the app (and the log) can say which
      // way round the mismatch is.
      expect(json['detail'], contains('replay version 1'));
      expect(json['detail'], contains('${Replay.version}'));
      expect(await server.store.count(), 0, reason: 'nothing may be stored');
    });

    test('is refused before anything is simulated', () async {
      // This body is wrong in three further ways the server checks *after* the
      // version: the tick count is past `maxTicks`, the input log holds more
      // entries than there are ticks, and the claimed score is a fiction. If any
      // of them were reached first the answer would be `replay_mismatch` or
      // `invalid_replay`, so the answer below is the proof of ordering.
      final padded = [
        for (var tick = 0; tick < 200; tick++) [tick, tick.isEven ? 1 : 2],
      ];
      final r = await post(
        legacyBody(
          oneBall,
          finalTick: ReplayVerifier.maxTicks + 1,
          inputs: [padded],
        ),
      );
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'unsupported_version');
      expect(await server.store.count(), 0);
    });

    test('the verifier itself simulates no ticks for it', () async {
      final stale = Replay(
        config: oneBall.config,
        inputs: oneBall.inputs,
        finalTick: oneBall.finalTick,
        claimedScore: oneBall.claimedScore,
        formatVersion: 1,
      );
      final result = ReplayVerifier.verify(stale);
      expect(result.ok, isFalse);
      expect(result.reason, 'unsupported_version');
      expect(result.ticks, 0, reason: 'refused before the first step');
      expect(result.score, 0);
      expect(result.hash, 0);
    });

    test('is refused even with replay verification switched off', () async {
      // `VERIFY_REPLAYS=off` trusts the claimed score; it does not make this
      // server able to understand a game it cannot simulate, so the version
      // check is deliberately in front of that switch.
      final lenient = await bootServer(verifyReplays: false);
      final r = await http.post(
        Uri.parse('${lenient.baseUrl}/api/scores'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(legacyBody(oneBall)),
      );
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'unsupported_version');
      expect(await lenient.store.count(), 0);
    });

    test('earns no Sparks, because it never becomes a run', () async {
      final me = await issuePlayer(server, name: 'Veteran');
      final r = await post(legacyBody(oneBall), authorization: authOf(me));
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'unsupported_version');
      expect(await server.store.walletBalance(me['id'] as String), 0);
    });
  });

  group('a two-ball replay', () {
    test('verifies and is stored with its score and its board', () async {
      final check = ReplayVerifier.verify(twoBall);
      expect(check.ok, isTrue, reason: check.reason);
      expect(check.score, twoBall.claimedScore);

      final r = await post(scoreBody('Duo', twoBall));
      expect(r.statusCode, 201, reason: r.body);
      final json = decode(r);
      expect(json['score'], twoBall.claimedScore);
      expect(json['balls'], 2);
      expect(json['rank'], 1);
      final rows = await server.store.topScores(balls: 2);
      expect(rows, hasLength(1));
      expect(rows.single.score, twoBall.claimedScore);
      expect(rows.single.balls, 2);
      expect(rows.single.ticks, twoBall.finalTick);
    });

    test('the score comes from the re-simulation, not the claim', () async {
      final body = scoreBody('Duo', twoBall);
      (body['replay'] as Map<String, dynamic>)['sc'] =
          twoBall.claimedScore + 5000;
      final r = await post(body);
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'replay_mismatch');
      expect(decode(r)['detail'], 'score_mismatch');
      expect(await server.store.count(), 0);
    });

    test('a tampered input log fails the re-simulation', () async {
      final body = scoreBody('Duo', twoBall);
      final replay = body['replay'] as Map<String, dynamic>;
      final logs = (replay['in'] as List<dynamic>).cast<List<dynamic>>();
      // Drop the last input change: the paddle then misses differently and the
      // game does not end where the claim says it does.
      logs[0] = logs[0].sublist(0, logs[0].length - 1);
      replay['in'] = logs;
      final r = await post(body);
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'replay_mismatch');
      expect(await server.store.count(), 0);
    });

    test('a two-ball duel replay is still refused, like any duel', () async {
      final duel = Replay(
        config: const GameConfig(mode: GameMode.duel, seed: 7, ballCount: 2),
        inputs: <InputLog>[InputLog(), InputLog()],
        finalTick: 100,
        claimedScore: 0,
      );
      final r = await post(scoreBody('Duo', duel));
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'invalid_replay');
    });
  });

  group('a ball count this build cannot simulate', () {
    test('is refused where the replay is decoded', () async {
      for (final n in [0, 3, 99, -1]) {
        final body = scoreBody('Tester', oneBall);
        final cfg =
            (body['replay'] as Map<String, dynamic>)['cfg']
                as Map<String, dynamic>;
        cfg['n'] = n;
        final r = await post(body);
        expect(r.statusCode, 400, reason: 'n=$n gave ${r.body}');
        expect(decode(r)['error'], 'invalid_replay');
        expect(
          decode(r)['detail'],
          contains('ballCount $n outside'),
          reason: 'the refusal names the range this build runs',
        );
      }
      expect(await server.store.count(), 0);
    });

    test('cannot even be built in process, let alone verified', () {
      // The verifier's `bad_config` refusal is a belt-and-braces path with no
      // way to reach it from here: `GameConfig` asserts the range in its own
      // constructor and `GameConfig.fromJson` throws, so a config this build
      // cannot run is refused twice over before any code could simulate it.
      expect(
        () => GameConfig(mode: GameMode.solo, seed: 7, ballCount: 3),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => GameConfig.fromJson({'m': 0, 's': 7, 'n': 3}),
        throwsFormatException,
      );
      // A config it *can* run reaches the simulation, which is what makes the
      // two refusals above meaningful rather than vacuous.
      final result = ReplayVerifier.verify(
        Replay(
          config: const GameConfig(mode: GameMode.solo, seed: 7, ballCount: 2),
          inputs: <InputLog>[InputLog()],
          finalTick: 600,
          claimedScore: 0,
        ),
      );
      expect(result.reason, anyOf('score_mismatch', 'early_finish'));
      expect(result.ticks, greaterThan(0), reason: 'it really did simulate');
    });

    test('a missing ball count is the classic one-ball game', () async {
      // Exactly what a client that predates boards sends, but with the current
      // format version: the config decodes to one ball and the run is filed on
      // the classic board.
      final body = scoreBody('Tester', oneBall);
      final cfg =
          (body['replay'] as Map<String, dynamic>)['cfg']
              as Map<String, dynamic>;
      cfg.remove('n');
      final r = await post(body);
      expect(r.statusCode, 201, reason: r.body);
      expect(decode(r)['balls'], 1);
    });
  });
}
