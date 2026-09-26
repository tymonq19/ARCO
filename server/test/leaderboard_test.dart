/// REST API: health, score submission with replay verification, listing,
/// ranking, limits and CORS (SPEC §4).
library;

import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late ArcoServer server;
  late Replay replay;

  setUpAll(() {
    // One real solo game, recorded through the core, reused by every test.
    replay = recordSoloReplay(seed: 20260923);
    final check = ReplayVerifier.verify(replay);
    expect(
      check.ok,
      isTrue,
      reason: 'the fixture replay must verify: ${check.reason}',
    );
    expect(replay.finalTick, greaterThan(0));
  });

  setUp(() async {
    server = await bootServer();
  });

  Uri api(String path, [Map<String, String>? query]) =>
      Uri.parse('${server.baseUrl}$path').replace(queryParameters: query);

  Future<http.Response> postScore(Object body) => http.post(
    api('/api/scores'),
    headers: {'content-type': 'application/json'},
    body: body is String ? body : jsonEncode(body),
  );

  Map<String, dynamic> decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  group('health', () {
    test('reports the version and the room count', () async {
      final r = await http.get(api('/api/health'));
      expect(r.statusCode, 200);
      expect(decode(r), {
        'ok': true,
        'version': serverVersion,
        'rooms': 0,
        // Which sign-ins this deployment accepts (SPEC §4.5). Empty here
        // because this server boots with accounts switched off, which is the
        // default and what a deployment with no client ids configured gets.
        'accounts': <String>[],
        // Catalogue version the cosmetic shop serves (SPEC §4.8), so a client
        // learns from the call it already makes whether the shop holds a kind
        // of item its build cannot draw.
        'catalogue': Catalogue.version,
        // Whether this deployment can take money for Sparks (SPEC §4.9). False
        // here for the same reason `accounts` is empty: no RevenueCat keys are
        // configured, which is the default and what every build gets until a
        // human has done the store paperwork.
        'purchases': false,
        // And whether it credits rewarded ads (SPEC §4.10). False for the same
        // reason again: `ADS_ENABLED` is off by default, so the app offers no ad
        // button at all rather than one that could never pay.
        'ads': false,
      });
    });

    test('unknown routes answer JSON 404', () async {
      final r = await http.get(api('/api/nope'));
      expect(r.statusCode, 404);
      expect(decode(r)['error'], 'not_found');
    });
  });

  group('POST /api/scores', () {
    test('a verified replay is stored, ranked and listed', () async {
      final r = await postScore(scoreBody('Tester', replay));
      expect(r.statusCode, 201, reason: r.body);
      final body = decode(r);
      expect(body['ok'], isTrue);
      expect(body['score'], replay.claimedScore);
      expect(body['rank'], 1);
      expect(body['id'], isA<String>());
      expect((body['id'] as String).length, 32);

      final list = await http.get(api('/api/leaderboard'));
      expect(list.statusCode, 200);
      final entries = (decode(list)['entries'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(entries, hasLength(1));
      expect(entries.single['rank'], 1);
      expect(entries.single['name'], 'Tester');
      expect(entries.single['score'], replay.claimedScore);
      expect(entries.single['seconds'], replay.finalTick ~/ tickRate);
      expect(
        entries.single['createdAt'],
        matches(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'),
      );
    });

    test('a tampered claimed score is rejected with replay_mismatch', () async {
      final tampered = Replay(
        config: replay.config,
        inputs: replay.inputs,
        finalTick: replay.finalTick,
        claimedScore: replay.claimedScore + 1000,
      );
      final r = await postScore(scoreBody('Cheater', tampered));
      expect(r.statusCode, 400, reason: r.body);
      final body = decode(r);
      expect(body['ok'], isFalse);
      expect(body['error'], 'replay_mismatch');
      expect(body['detail'], 'score_mismatch');

      final list = await http.get(api('/api/leaderboard'));
      expect(
        (decode(list)['entries'] as List<dynamic>),
        isEmpty,
        reason: 'nothing may be stored',
      );
    });

    test('a replay that did not end is rejected', () async {
      final unfinished = Replay(
        config: replay.config,
        inputs: replay.inputs,
        finalTick: 30,
        claimedScore: 0,
      );
      final r = await postScore(scoreBody('Quitter', unfinished));
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'replay_mismatch');
      expect(decode(r)['detail'], 'not_finished');
    });

    test('invalid names are rejected', () async {
      for (final name in <String>[
        'x',
        '',
        '   ',
        'way too long a name',
        'bad<name>',
      ]) {
        final r = await postScore(scoreBody(name, replay));
        expect(r.statusCode, 400, reason: 'name "$name" -> ${r.body}');
        expect(decode(r)['error'], 'invalid_name', reason: 'name "$name"');
      }
    });

    test('a malformed body is invalid_json', () async {
      final r = await postScore('{not json');
      expect(r.statusCode, 400);
      expect(decode(r)['error'], 'invalid_json');

      final notAnObject = await postScore('[1,2,3]');
      expect(notAnObject.statusCode, 400);
      expect(decode(notAnObject)['error'], 'invalid_json');
    });

    test('a malformed or non-solo replay is invalid_replay', () async {
      final missing = await postScore({'name': 'Tester'});
      expect(missing.statusCode, 400);
      expect(decode(missing)['error'], 'invalid_replay');

      final junk = await postScore({
        'name': 'Tester',
        'replay': {'v': 1, 'cfg': 'nope'},
      });
      expect(junk.statusCode, 400);
      expect(decode(junk)['error'], 'invalid_replay');

      final duel = Replay(
        config: const GameConfig(mode: GameMode.duel, seed: 7),
        inputs: <InputLog>[InputLog(), InputLog()],
        finalTick: 100,
        claimedScore: 0,
      );
      final duelResponse = await postScore(scoreBody('Tester', duel));
      expect(duelResponse.statusCode, 400);
      expect(decode(duelResponse)['error'], 'invalid_replay');
    });

    test('a future replay format is unsupported_version', () async {
      final body = scoreBody('Tester', replay);
      (body['replay'] as Map<String, dynamic>)['v'] = Replay.version + 1;
      final r = await postScore(body);
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'unsupported_version');
    });

    test('bodies over 2 MB are rejected with 413', () async {
      final padding = 'a' * (maxScoreBodyBytes + 1024);
      final r = await postScore('{"name":"Tester","pad":"$padding"}');
      expect(r.statusCode, 413);
      expect(decode(r)['error'], 'payload_too_large');
    });

    test(
      'the 413 names the cap, so an over-long replay is not opaque',
      () async {
        // The cap is a byte budget, but what hits it is game length: a replay
        // carries one [tick, input] pair per input change, so a solo game whose
        // input changes on nearly every tick outgrows 2 MB after ~45 min - well
        // before ReplayVerifier.maxTicks. The client can only tell the player
        // that (instead of reporting a bare transport failure) if the answer
        // carries the limit it broke.
        final log = InputLog();
        for (var tick = 0; tick < ReplayVerifier.maxTicks; tick++) {
          log.record(tick, PlayerInput.aiming(tick % inputAimSteps));
        }
        final dense = Replay(
          config: const GameConfig(mode: GameMode.solo, seed: 20260923),
          inputs: <InputLog>[log],
          finalTick: ReplayVerifier.maxTicks,
          claimedScore: 999999,
        );
        final body = jsonEncode(scoreBody('Tester', dense));
        expect(
          body.length,
          greaterThan(maxScoreBodyBytes),
          reason: 'a dense one-hour replay is what overflows the cap',
        );

        final r = await postScore(body);
        expect(r.statusCode, 413);
        final json = decode(r);
        expect(json['error'], 'payload_too_large');
        expect(json['limit'], maxScoreBodyBytes);
        expect(json['detail'], contains('too long'));
      },
    );

    test('an input log longer than the replay is invalid_replay', () async {
      // Entries at ticks the verifier never reaches are padding: bound the
      // replay by its tick count, not only by the request body size.
      final log = InputLog();
      for (var tick = 0; tick < 200; tick++) {
        log.record(tick, PlayerInput.moving(tick.isEven ? 1 : -1));
      }
      final padded = Replay(
        config: const GameConfig(mode: GameMode.solo, seed: 20260923),
        inputs: <InputLog>[log],
        finalTick: 10,
        claimedScore: 0,
      );
      final r = await postScore(scoreBody('Tester', padded));
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], 'invalid_replay');
      expect(decode(r)['detail'], contains('200 entries for 10 tick(s)'));
    });

    test('a maximal body is not decoded on the tick isolate', () async {
      // Well-formed and just under the 2 MB cap, rejected right after the
      // parse (finalTick past maxTicks): what it costs the server is the JSON
      // decode plus rebuilding the input log, with no simulation and no write.
      final body = _maximalScoreBody();
      expect(body.length, lessThanOrEqualTo(maxScoreBodyBytes));

      // The tick driver drops backlog beyond 5 ticks per callback; x10 makes
      // that cap bite after ~8 ms of starvation instead of ~83 ms, so a
      // blocked event loop shows up in a short test.
      final starved = await bootServer(tickMultiplier: 10);
      Future<http.Response> flood() => http.post(
        Uri.parse('${starved.baseUrl}/api/scores'),
        headers: {'content-type': 'application/json'},
        body: body,
      );

      final warmup = await flood();
      expect(warmup.statusCode, 400, reason: warmup.body);
      expect(decode(warmup)['error'], 'replay_mismatch');
      expect(decode(warmup)['detail'], 'too_long');

      const submissions = 8;
      final before = starved.rooms.droppedTicks;
      for (var i = 0; i < submissions; i++) {
        expect((await flood()).statusCode, 400, reason: 'submission $i');
      }
      final dropped = starved.rooms.droppedTicks - before;
      expect(
        dropped,
        lessThan(50),
        reason:
            'the driver lost $dropped ticks while $submissions submissions '
            'were parsed, so the body is being decoded on the isolate that '
            'runs the rooms (~115 ticks before the parse moved off it, <15 '
            'after)',
      );
    });

    test('the eleventh submission within a minute is rate limited', () async {
      for (var i = 0; i < scoreSubmissionsPerMinute; i++) {
        final r = await postScore('{');
        expect(r.statusCode, 400, reason: 'attempt $i');
      }
      final limited = await postScore('{');
      expect(limited.statusCode, 429);
      expect(decode(limited)['error'], 'rate_limited');
      expect(limited.headers['retry-after'], '60');
    });

    test('expired rate-limiter keys are swept, not kept forever', () async {
      var now = 0;
      final limiter = RateLimiter(
        limit: scoreSubmissionsPerMinute,
        window: const Duration(minutes: 1),
        clock: () => now,
      );
      final swept = await bootServer(
        submitLimiter: limiter,
        apiSweepInterval: const Duration(milliseconds: 10),
      );
      final r = await http.post(
        Uri.parse('${swept.baseUrl}/api/scores'),
        headers: {'content-type': 'application/json'},
        body: '{',
      );
      expect(r.statusCode, 400);
      expect(limiter.keyCount, 1, reason: 'the submitter is tracked');

      // The attacker shape: the key is the proxy-appended X-Forwarded-For hop,
      // so one cheap 400-answering request per spoofed address opens a fresh
      // bucket and no 429 ever stands in the way. The clock is frozen, so all
      // of these stay inside the window and really do pile up.
      const spoofed = 40;
      for (var i = 0; i < spoofed; i++) {
        final s = await http.post(
          Uri.parse('${swept.baseUrl}/api/scores'),
          headers: {
            'content-type': 'application/json',
            'x-forwarded-for': '203.0.113.${i + 1}',
          },
          body: '{',
        );
        expect(s.statusCode, 400, reason: 'spoofed submitter $i');
      }
      expect(
        limiter.keyCount,
        spoofed + 1,
        reason: 'each spoofed address costs one map entry',
      );

      // The window has slid, so no key holds an event any more: the periodic
      // sweep must drop every one of them, otherwise every submitter ever seen
      // stays in the map and memory grows without bound.
      now += const Duration(minutes: 1).inMilliseconds + 1;
      await pumpUntil(
        () => limiter.keyCount == 0,
        reason: 'the submit limiter is never swept',
      );

      // Shutting the server down cancels the sweeper.
      await swept.stop();
      limiter.allow('198.51.100.7');
      now += const Duration(minutes: 1).inMilliseconds + 1;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        limiter.keyCount,
        1,
        reason: 'the sweeper stopped with the server',
      );
    });

    test(
      'rate limiting keys on the proxy-appended X-Forwarded-For hop',
      () async {
        Future<http.Response> submitAs(String forwarded) => http.post(
          api('/api/scores'),
          headers: {
            'content-type': 'application/json',
            'x-forwarded-for': forwarded,
          },
          body: '{',
        );

        // The rightmost hop is what the reverse proxy saw; the tests connect
        // over loopback, so the header is trusted here.
        for (var i = 0; i < scoreSubmissionsPerMinute; i++) {
          expect(
            (await submitAs('10.0.0.1, 203.0.113.9')).statusCode,
            400,
            reason: 'attempt $i',
          );
        }
        // Rotating the client-supplied prefix must not open a fresh bucket.
        expect((await submitAs('9.9.9.9, 203.0.113.9')).statusCode, 429);
        expect(
          (await submitAs('203.0.113.9, 8.8.8.8, 203.0.113.9')).statusCode,
          429,
        );
        expect((await submitAs('203.0.113.9')).statusCode, 429);
        // A different client is unaffected.
        expect((await submitAs('10.0.0.1, 198.51.100.4')).statusCode, 400);
      },
    );

    test('VERIFY_REPLAYS=off stores the claimed score unverified', () async {
      final dev = await bootServer(verifyReplays: false);
      final tampered = Replay(
        config: replay.config,
        inputs: replay.inputs,
        finalTick: replay.finalTick,
        claimedScore: 999999,
      );
      final r = await http.post(
        Uri.parse('${dev.baseUrl}/api/scores'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(scoreBody('DevMode', tampered)),
      );
      expect(r.statusCode, 201, reason: r.body);
      expect(decode(r)['score'], 999999);
    });
  });

  group('GET /api/leaderboard', () {
    /// Inserts a row straight into storage so a specific `created_at` can be
    /// used without waiting a week.
    Future<void> seed(String name, int score, Duration ago) {
      return server.store.insert(
        ScoreRow(
          id: 'id-$name',
          name: name,
          score: score,
          ticks: score * 6,
          seed: 1,
          createdAt: Db.formatTimestamp(DateTime.now().toUtc().subtract(ago)),
          ipHash: LeaderboardService.hashIp('10.0.0.1'),
          hash: 0,
        ),
      );
    }

    test('orders by score desc then createdAt asc and honours limit', () async {
      await seed('Bronze', 100, const Duration(minutes: 3));
      await seed('Gold', 300, const Duration(minutes: 2));
      await seed('Silver', 200, const Duration(minutes: 1));

      final all = await http.get(api('/api/leaderboard'));
      final entries = (decode(all)['entries'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(
        [for (final e in entries) e['name']],
        ['Gold', 'Silver', 'Bronze'],
      );
      expect([for (final e in entries) e['rank']], [1, 2, 3]);

      final limited = await http.get(api('/api/leaderboard', {'limit': '2'}));
      expect((decode(limited)['entries'] as List<dynamic>), hasLength(2));

      // Over-large limits are clamped instead of rejected.
      final clamped = await http.get(
        api('/api/leaderboard', {'limit': '5000'}),
      );
      expect(clamped.statusCode, 200);
      expect((decode(clamped)['entries'] as List<dynamic>), hasLength(3));
    });

    test('period filters the rolling window', () async {
      await seed('Today', 10, const Duration(hours: 2));
      await seed('ThisWeek', 20, const Duration(days: 3));
      await seed('Ancient', 30, const Duration(days: 40));

      Future<List<String>> names(String period) async {
        final r = await http.get(api('/api/leaderboard', {'period': period}));
        expect(r.statusCode, 200);
        final entries = (decode(r)['entries'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        return [for (final e in entries) e['name'] as String];
      }

      expect(await names('day'), ['Today']);
      expect(await names('week'), ['ThisWeek', 'Today']);
      expect(await names('all'), ['Ancient', 'ThisWeek', 'Today']);

      final bad = await http.get(
        api('/api/leaderboard', {'period': 'century'}),
      );
      expect(bad.statusCode, 400);
      expect(decode(bad)['error'], 'invalid_period');
    });

    test('rank counts strictly better scores', () async {
      await seed('A', 100, const Duration(minutes: 1));
      await seed('B', 200, const Duration(minutes: 1));
      await seed('C', 300, const Duration(minutes: 1));

      Future<int> rankOf(String score) async {
        final r = await http.get(
          api('/api/leaderboard/rank', {'score': score}),
        );
        expect(r.statusCode, 200);
        return decode(r)['rank'] as int;
      }

      expect(await rankOf('150'), 3);
      expect(await rankOf('300'), 1);
      expect(await rankOf('0'), 4);

      final missing = await http.get(api('/api/leaderboard/rank'));
      expect(missing.statusCode, 400);
      expect(decode(missing)['error'], 'invalid_score');
    });
  });

  group('CORS', () {
    test('api responses allow any origin', () async {
      final r = await http.get(
        api('/api/health'),
        headers: {'origin': 'https://example.com'},
      );
      expect(r.headers['access-control-allow-origin'], '*');
    });

    test('preflight is answered with 204', () async {
      final request = http.Request('OPTIONS', api('/api/scores'))
        ..headers['origin'] = 'https://example.com'
        ..headers['access-control-request-method'] = 'POST';
      final response = await request.send();
      expect(response.statusCode, 204);
      expect(response.headers['access-control-allow-origin'], '*');
      expect(
        response.headers['access-control-allow-methods'],
        contains('POST'),
      );
    });
  });
}

/// A submission just under the 2 MB cap: one input log filling the body, with
/// `finalTick` past [ReplayVerifier.maxTicks] so it is rejected as soon as it
/// has been parsed.
String _maximalScoreBody() {
  final tail = ']],"ft":${ReplayVerifier.maxTicks + 1},"sc":0}';
  final buffer =
      StringBuffer('{"name":"Flooder","replay":{"v":${Replay.version},"cfg":')
        ..write(
          jsonEncode(const GameConfig(mode: GameMode.solo, seed: 7).toJson()),
        )
        ..write(',"in":[[');
  var tick = 0;
  while (buffer.length + tail.length + 32 < maxScoreBodyBytes) {
    if (tick > 0) buffer.write(',');
    buffer.write('[$tick,${tick.isEven ? 1 : 2}]');
    tick++;
  }
  return (buffer
        ..write(tail)
        ..write('}'))
      .toString();
}
