/// Room code generation (SPEC §3): 4 characters over a fixed alphabet that
/// excludes look-alikes, never colliding with a live room.
library;

import 'dart:math';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A [Random] that returns a fixed sequence of indices, so a code collision
/// can be provoked deterministically.
class _SequenceRandom implements Random {
  _SequenceRandom(this.values);

  final List<int> values;
  int _cursor = 0;

  @override
  int nextInt(int max) => values[_cursor++ % values.length] % max;

  @override
  double nextDouble() => throw UnsupportedError('not used');

  @override
  bool nextBool() => throw UnsupportedError('not used');
}

void main() {
  group('room codes', () {
    test('use only the documented alphabet and length', () {
      final registry = RoomRegistry(log: silentLogger());
      addTearDown(registry.close);
      expect(roomCodeAlphabet, 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789');
      expect(roomCodeAlphabet.contains('0'), isFalse);
      expect(roomCodeAlphabet.contains('O'), isFalse);
      expect(roomCodeAlphabet.contains('1'), isFalse);
      expect(roomCodeAlphabet.contains('I'), isFalse);

      for (var i = 0; i < 5000; i++) {
        final code = registry.generateCode();
        expect(code.length, roomCodeLength);
        for (final char in code.split('')) {
          expect(roomCodeAlphabet, contains(char), reason: 'code "$code"');
        }
        expect(
          normalizeRoomCode(code),
          code,
          reason: 'generated codes must parse',
        );
      }
    });

    test('are spread over the whole space', () {
      final registry = RoomRegistry(log: silentLogger());
      addTearDown(registry.close);
      final seen = <String>{};
      const draws = 5000;
      for (var i = 0; i < draws; i++) {
        seen.add(registry.generateCode());
      }
      // 32^4 = 1_048_576 codes, so a handful of birthday collisions is normal
      // among 5000 draws that are not registered as rooms.
      expect(seen.length, greaterThan(draws - 100));
      final used = <String>{};
      for (final code in seen) {
        for (final char in code.split('')) {
          used.add(char);
        }
      }
      expect(
        used.length,
        roomCodeAlphabet.length,
        reason: 'every letter must occur',
      );
    });

    test('never collide with a live room', () {
      // The scripted random yields "AAAA", then "BBBB": the first draw is
      // already taken, so the generator must draw again.
      final random = _SequenceRandom(<int>[0, 0, 0, 0, 1, 1, 1, 1]);
      final taken = <String>{'AAAA'};
      expect(RoomRegistry.generateRoomCode(random, taken.contains), 'BBBB');
    });

    test('a registry hands out a fresh code per room', () async {
      final server = await bootServer();
      final codes = <String>{};
      for (var i = 0; i < roomsPerIpPerMinute; i++) {
        final client = await TestClient.connect(server, name: 'Host$i');
        client.send(const CreateRoomMsg());
        codes.add((await client.nextOf<RoomMsg>()).code);
      }
      expect(codes, hasLength(roomsPerIpPerMinute));
      expect(server.rooms.roomCount, roomsPerIpPerMinute);
    });
  });

  group('server configuration', () {
    test('defaults match SPEC §4.3', () {
      final config = ServerConfig.fromEnvironment(const <String, String>{});
      expect(config.port, 8080);
      expect(config.dbPath, 'data/arco.db');
      expect(config.verifyReplays, isTrue);
      expect(config.logLevel, LogLevel.info);
      expect(config.host, isNull);
    });

    test('reads PORT, DB_PATH, VERIFY_REPLAYS and LOG_LEVEL', () {
      final config = ServerConfig.fromEnvironment(const {
        'PORT': '9000',
        'DB_PATH': '/tmp/x.db',
        'VERIFY_REPLAYS': 'off',
        'LOG_LEVEL': 'debug',
        'HOST': '127.0.0.1',
      });
      expect(config.port, 9000);
      expect(config.dbPath, '/tmp/x.db');
      expect(config.verifyReplays, isFalse);
      expect(config.logLevel, LogLevel.debug);
      expect(config.host, '127.0.0.1');
    });

    test('rejects invalid values', () {
      expect(
        () => ServerConfig.fromEnvironment(const {'PORT': 'http'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ServerConfig.fromEnvironment(const {'PORT': '70000'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ServerConfig.fromEnvironment(const {'VERIFY_REPLAYS': 'maybe'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ServerConfig.fromEnvironment(const {'LOG_LEVEL': 'loud'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('storage', () {
    test('keeps scores ordered and ranks them', () {
      final db = Db.open(':memory:');
      addTearDown(db.close);
      final now = DateTime.utc(2026, 9, 23, 12);
      for (var i = 0; i < 3; i++) {
        db.insertScore(
          ScoreRow(
            id: 'id$i',
            name: 'P$i',
            score: 100 * (i + 1),
            ticks: 600,
            seed: i,
            createdAt: Db.formatTimestamp(now.add(Duration(seconds: i))),
            ipHash: 'hash',
            hash: 0,
          ),
        );
      }
      expect(db.count, 3);
      expect(
        [for (final r in db.topScores(now: now)) r.score],
        [300, 200, 100],
      );
      expect(db.topScores(limit: 1, now: now), hasLength(1));
      expect(db.rank(250, now: now), 2);
      expect(db.rank(300, now: now), 1);
      expect(
        db.topScores(
          period: LeaderboardPeriod.day,
          now: now.add(const Duration(days: 2)),
        ),
        isEmpty,
      );
    });

    test('IP hashes are sha256 and never store the address', () {
      final hash = LeaderboardService.hashIp('203.0.113.7');
      expect(hash, hasLength(64));
      expect(hash, matches(r'^[0-9a-f]{64}$'));
      expect(hash, isNot(contains('203')));
      expect(LeaderboardService.hashIp('203.0.113.7'), hash);
      expect(LeaderboardService.hashIp('203.0.113.8'), isNot(hash));
    });
  });
}
