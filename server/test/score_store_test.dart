/// Storage access runs off the event loop (SPEC §4.3 storage, §3 tick driver):
/// every `sqlite3` call goes to the [ScoreStore] isolate, so a slow or blocked
/// query cannot stop this isolate from ticking rooms and answering requests.
library;

import 'dart:async';
import 'dart:io';

import 'package:arco_server/arco_server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  ScoreRow row(String id, int score, {DateTime? at}) => ScoreRow(
    id: id,
    name: 'P-$id',
    score: score,
    ticks: score * 6,
    seed: 1,
    createdAt: Db.formatTimestamp(at ?? DateTime.now().toUtc()),
    ipHash: LeaderboardService.hashIp('10.0.0.1'),
    hash: 0,
  );

  Future<ScoreStore> openStore({
    String path = ':memory:',
    Duration busyTimeout = Db.defaultBusyTimeout,
  }) async {
    final store = await ScoreStore.open(path, busyTimeout: busyTimeout);
    addTearDown(store.close);
    return store;
  }

  test(
    'insert, topScores, rank and count round-trip through the isolate',
    () async {
      final store = await openStore();
      final now = DateTime.utc(2026, 9, 23, 12);
      await store.insert(
        row('a', 100, at: now.subtract(const Duration(days: 40))),
      );
      await store.insert(
        row('b', 300, at: now.subtract(const Duration(days: 3))),
      );
      await store.insert(
        row('c', 200, at: now.subtract(const Duration(hours: 2))),
      );

      expect(await store.count(), 3);
      expect(
        [for (final r in await store.topScores(now: now)) r.id],
        ['b', 'c', 'a'],
      );
      expect(await store.topScores(limit: 1, now: now), hasLength(1));
      expect(
        [
          for (final r in await store.topScores(
            period: LeaderboardPeriod.week,
            now: now,
          ))
            r.id,
        ],
        ['b', 'c'],
      );
      expect(
        [
          for (final r in await store.topScores(
            period: LeaderboardPeriod.day,
            now: now,
          ))
            r.id,
        ],
        ['c'],
      );
      expect(await store.rank(250, now: now), 2);
      expect(await store.rank(250, period: LeaderboardPeriod.day, now: now), 1);
    },
  );

  test(
    'a write blocked by another connection does not stall the event loop',
    () async {
      final dir = Directory.systemTemp.createTempSync('arco_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/scores.db';
      // Short enough to keep the test quick; long enough that a blocking call on
      // this isolate would be plainly visible in the heartbeat below.
      const busyTimeout = Duration(milliseconds: 400);
      final store = await openStore(path: path, busyTimeout: busyTimeout);

      // A second connection holds the write lock for the whole insert, so SQLite
      // waits out `busy_timeout` inside the C call and then fails.
      final holder = sqlite3.open(path);
      holder.execute('PRAGMA busy_timeout = 0');
      holder.execute('BEGIN EXCLUSIVE');

      var beats = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => beats++,
      );
      addTearDown(heartbeat.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final before = beats;
      final watch = Stopwatch()..start();
      await expectLater(
        store.insert(row('blocked', 10)),
        throwsA(
          isA<ScoreStoreException>().having(
            (e) => e.message,
            'message',
            contains('locked'),
          ),
        ),
      );
      final duringBlock = beats - before;

      expect(
        watch.elapsed,
        greaterThanOrEqualTo(busyTimeout * 0.5),
        reason: 'the write should really have waited for the lock',
      );
      // Before storage moved off the event loop this was 0: the isolate sat
      // inside sqlite3 for the whole busy_timeout, ticking nothing.
      expect(
        duringBlock,
        greaterThanOrEqualTo(10),
        reason: 'timers must keep firing while a write waits for the lock',
      );

      // The store stays usable once the lock is gone.
      holder
        ..execute('ROLLBACK')
        ..close();
      await store.insert(row('after', 20));
      expect(await store.count(), 1);
    },
  );

  test('a failing statement is reported without killing the isolate', () async {
    final store = await openStore();
    await store.insert(row('dup', 10));
    await expectLater(
      store.insert(row('dup', 20)),
      throwsA(isA<ScoreStoreException>()),
    );
    expect(await store.count(), 1);
    expect(await store.rank(0), 2);
  });

  test(
    'a database that cannot be opened fails open(), not the server',
    () async {
      final dir = Directory.systemTemp.createTempSync('arco_store_bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      // A directory is not a database file: the worker reports it and exits, and
      // open() rethrows instead of leaving a half-started store behind.
      await expectLater(
        ScoreStore.open(dir.path),
        throwsA(isA<ScoreStoreException>()),
      );
    },
  );

  test('calls after close fail instead of hanging', () async {
    final store = await openStore();
    await store.insert(row('a', 10));
    await store.close();
    expect(store.isClosed, isTrue);
    await expectLater(store.count(), throwsA(isA<ScoreStoreException>()));
    // Closing twice is a no-op (the server calls stop() on failed startups).
    await store.close();
  });
}
