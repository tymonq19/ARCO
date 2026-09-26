/// Schema migration (SPEC §4.3, §4.4, §4.6): a database file written before
/// player identity existed must upgrade in place, keep every row, and keep
/// serving those rows on the leaderboard as anonymous runs with no country.
///
/// This is the case that actually runs in production: the deployed server has a
/// `scores` table with no `player_id` and no `user_version`, and nobody is going
/// to delete it before the next release.
library;

import 'dart:convert';
import 'dart:io';

import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The `scores`-only schema exactly as the server created it before players
/// existed: no `user_version`, no `player_id`, one index.
void writeLegacyDatabase(String path, List<List<Object?>> rows) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA journal_mode = WAL');
  db.execute('''
    CREATE TABLE IF NOT EXISTS scores (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      score INTEGER NOT NULL,
      ticks INTEGER NOT NULL,
      seed INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      ip_hash TEXT NOT NULL,
      hash INTEGER NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_scores_rank ON scores (score DESC, created_at)',
  );
  final insert = db.prepare(
    'INSERT INTO scores (id, name, score, ticks, seed, created_at, ip_hash, hash) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
  );
  for (final row in rows) {
    insert.execute(row);
  }
  insert.close();
  // Nothing sets user_version, so the file reads as schema version 0.
  expect(db.select('PRAGMA user_version').first.columnAt(0), 0);
  expect(columnNames(db, 'scores'), isNot(contains('player_id')));
  db.close();
}

/// The schema exactly as version 1 left it: players carry a single
/// `secret_hash` column, there is no `player_secrets` table and `scores` has no
/// `country` column yet.
void writeV1Database(String path, {required String secretHash}) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA journal_mode = WAL');
  db.execute('''
    CREATE TABLE scores (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, score INTEGER NOT NULL,
      ticks INTEGER NOT NULL, seed INTEGER NOT NULL, created_at TEXT NOT NULL,
      ip_hash TEXT NOT NULL, hash INTEGER NOT NULL,
      player_id TEXT REFERENCES players (id)
    )
  ''');
  db.execute('CREATE INDEX idx_scores_rank ON scores (score DESC, created_at)');
  db.execute(
    'CREATE INDEX idx_scores_player ON scores (player_id, score DESC, created_at)',
  );
  db.execute('''
    CREATE TABLE players (
      id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, created_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL, name TEXT, account_provider TEXT,
      account_subject TEXT, account_email TEXT, account_linked_at TEXT
    )
  ''');
  db.execute(
    'CREATE UNIQUE INDEX idx_players_account '
    'ON players (account_provider, account_subject) '
    'WHERE account_subject IS NOT NULL',
  );
  db.execute(
    'INSERT INTO players (id, secret_hash, created_at, last_seen_at, name) '
    'VALUES (?, ?, ?, ?, ?)',
    [
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      secretHash,
      '2026-09-10T08:00:00Z',
      '2026-09-11T08:00:00Z',
      'Veteran',
    ],
  );
  db.execute(
    'INSERT INTO scores '
    '(id, name, score, ticks, seed, created_at, ip_hash, hash, player_id) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      'veteran-run',
      'Veteran',
      450,
      2700,
      21,
      '2026-09-11T08:00:00Z',
      'ip-hash-v',
      3,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ],
  );
  db.execute('PRAGMA user_version = 1');
  db.close();
}

/// The schema exactly as version 3 left it — the one currently deployed: player
/// credentials in `player_secrets`, `scores.country` and its index, and no
/// cosmetic tables at all.
///
/// This is the case that actually runs on the next release: a live database with
/// scores, players and credentials in it, which has to gain a shop without
/// losing a row.
void writeV3Database(String path, {required String secretHash}) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA journal_mode = WAL');
  db.execute('''
    CREATE TABLE scores (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, score INTEGER NOT NULL,
      ticks INTEGER NOT NULL, seed INTEGER NOT NULL, created_at TEXT NOT NULL,
      ip_hash TEXT NOT NULL, hash INTEGER NOT NULL,
      player_id TEXT REFERENCES players (id), country TEXT
    )
  ''');
  db.execute('CREATE INDEX idx_scores_rank ON scores (score DESC, created_at)');
  db.execute(
    'CREATE INDEX idx_scores_player ON scores (player_id, score DESC, created_at)',
  );
  db.execute(
    'CREATE INDEX idx_scores_country ON scores (country, score DESC, created_at)',
  );
  db.execute('''
    CREATE TABLE players (
      id TEXT PRIMARY KEY, created_at TEXT NOT NULL, last_seen_at TEXT NOT NULL,
      name TEXT, account_provider TEXT, account_subject TEXT,
      account_linked_at TEXT
    )
  ''');
  db.execute(
    'CREATE UNIQUE INDEX idx_players_account '
    'ON players (account_provider, account_subject) '
    'WHERE account_subject IS NOT NULL',
  );
  db.execute('''
    CREATE TABLE player_secrets (
      id TEXT PRIMARY KEY, player_id TEXT NOT NULL REFERENCES players (id),
      secret_hash TEXT NOT NULL, created_at TEXT NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX idx_player_secrets_player '
    'ON player_secrets (player_id, created_at)',
  );
  db.execute('''
    CREATE TABLE player_aliases (
      old_id TEXT PRIMARY KEY, player_id TEXT NOT NULL REFERENCES players (id),
      merged_at TEXT NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX idx_player_aliases_player ON player_aliases (player_id)',
  );
  db.execute('''
    CREATE TABLE id_token_uses (
      token_hash TEXT PRIMARY KEY, provider TEXT NOT NULL, subject TEXT NOT NULL,
      player_id TEXT NOT NULL, credential_id TEXT, used_at TEXT NOT NULL,
      expires_at TEXT NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX idx_id_token_uses_expiry ON id_token_uses (expires_at)',
  );
  db.execute(
    'INSERT INTO players (id, created_at, last_seen_at, name) '
    'VALUES (?, ?, ?, ?)',
    [
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      '2026-09-15T08:00:00Z',
      '2026-09-20T08:00:00Z',
      'Regular',
    ],
  );
  db.execute(
    'INSERT INTO player_secrets (id, player_id, secret_hash, created_at) '
    'VALUES (?, ?, ?, ?)',
    [
      'cccccccccccccccccccccccccccccccc',
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      secretHash,
      '2026-09-15T08:00:00Z',
    ],
  );
  for (final row in <List<Object?>>[
    [
      'v3-owned',
      'Regular',
      820,
      4900,
      31,
      '2026-09-20T08:00:00Z',
      'ip-hash-r',
      5,
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'PL',
    ],
    [
      'v3-anonymous',
      'Passer-by',
      140,
      900,
      32,
      '2026-09-21T08:00:00Z',
      'ip-hash-p',
      6,
      null,
      null,
    ],
  ]) {
    db.execute(
      'INSERT INTO scores (id, name, score, ticks, seed, created_at, ip_hash, '
      'hash, player_id, country) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      row,
    );
  }
  db.execute('PRAGMA user_version = 3');
  expect(tableNames(db), isNot(contains('player_wallets')));
  db.close();
}

/// The schema exactly as version 4 left it: the cosmetic tables of SPEC §4.8,
/// with a wallet that has Sparks in it, and no paid-purchase ledger.
///
/// This is the file the *next* release actually meets, so it is the one that has
/// to gain the money feature without losing a Spark anybody earned.
void writeV4Database(String path, {required String secretHash}) {
  writeV3Database(path, secretHash: secretHash);
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE player_wallets (
      player_id TEXT PRIMARY KEY REFERENCES players (id),
      balance INTEGER NOT NULL DEFAULT 0 CHECK (balance >= 0),
      earned_total INTEGER NOT NULL DEFAULT 0,
      spent_total INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE player_items (
      player_id TEXT NOT NULL REFERENCES players (id),
      item_id TEXT NOT NULL,
      acquired_at TEXT NOT NULL,
      price_paid INTEGER NOT NULL,
      PRIMARY KEY (player_id, item_id)
    )
  ''');
  db.execute('''
    CREATE TABLE player_equipped (
      player_id TEXT NOT NULL REFERENCES players (id),
      kind TEXT NOT NULL,
      item_id TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (player_id, kind)
    )
  ''');
  db.execute('''
    CREATE TABLE token_awards (
      replay_key TEXT PRIMARY KEY,
      player_id TEXT NOT NULL REFERENCES players (id),
      score_id TEXT NOT NULL,
      score INTEGER NOT NULL,
      tokens INTEGER NOT NULL,
      day TEXT NOT NULL,
      awarded_at TEXT NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX idx_token_awards_player_day ON token_awards (player_id, day)',
  );
  // An evening of play, already banked and partly spent.
  db.execute(
    'INSERT INTO player_wallets '
    '(player_id, balance, earned_total, spent_total, updated_at) '
    'VALUES (?, ?, ?, ?, ?)',
    ['bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 120, 200, 80, '2026-09-21T08:00:00Z'],
  );
  db.execute(
    'INSERT INTO player_items (player_id, item_id, acquired_at, price_paid) '
    'VALUES (?, ?, ?, ?)',
    [
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'ball.comet',
      '2026-09-21T08:00:00Z',
      80,
    ],
  );
  db.execute(
    'INSERT INTO player_equipped (player_id, kind, item_id, updated_at) '
    'VALUES (?, ?, ?, ?)',
    [
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'ball',
      'ball.comet',
      '2026-09-21T08:00:00Z',
    ],
  );
  db.execute('PRAGMA user_version = 4');
  expect(tableNames(db), isNot(contains('spark_purchases')));
  expect(columnNames(db, 'player_wallets'), isNot(contains('purchased_total')));
  db.close();
}

/// The schema exactly as version 5 left it: the paid-Spark ledger of SPEC §4.9
/// on top of v4, with a wallet that has both earned **and** bought Sparks in it,
/// and no ad-reward ledger.
///
/// This is the file the *next* release actually meets, so it is the one that has
/// to gain rewarded ads without losing a Spark anybody earned or paid for.
void writeV5Database(String path, {required String secretHash}) {
  writeV4Database(path, secretHash: secretHash);
  final db = sqlite3.open(path);
  db.execute(
    'ALTER TABLE player_wallets '
    'ADD COLUMN purchased_total INTEGER NOT NULL DEFAULT 0',
  );
  db.execute('''
    CREATE TABLE spark_purchases (
      transaction_id TEXT PRIMARY KEY,
      player_id TEXT NOT NULL REFERENCES players (id),
      product_id TEXT NOT NULL,
      sparks INTEGER NOT NULL,
      store TEXT NOT NULL,
      environment TEXT NOT NULL,
      source TEXT NOT NULL,
      event_id TEXT,
      purchased_at TEXT NOT NULL,
      credited_at TEXT NOT NULL,
      refunded_at TEXT,
      clawed_back INTEGER NOT NULL DEFAULT 0
    )
  ''');
  db.execute(
    'CREATE INDEX idx_spark_purchases_player '
    'ON spark_purchases (player_id, credited_at DESC)',
  );
  // A pack bought with real money, already credited: the v4 wallet held 120 of
  // 200 earned with 80 spent, and this adds 300 paid for on top.
  db.execute(
    'UPDATE player_wallets SET balance = balance + 300, '
    'purchased_total = 300 WHERE player_id = ?',
    ['bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'],
  );
  db.execute(
    'INSERT INTO spark_purchases (transaction_id, player_id, product_id, '
    'sparks, store, environment, source, purchased_at, credited_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      'apple-txn-under-v5',
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'arco.sparks.small',
      300,
      'app_store',
      'PRODUCTION',
      'webhook',
      '2026-09-22T08:00:00Z',
      '2026-09-22T08:00:01Z',
    ],
  );
  db.execute('PRAGMA user_version = 5');
  expect(tableNames(db), isNot(contains('ad_rewards')));
  expect(columnNames(db, 'player_wallets'), isNot(contains('ad_total')));
  db.close();
}

/// The schema exactly as version 6 left it: the ad ledger of SPEC §4.10 beside
/// the **paid-Spark** ledger, which is still called `spark_purchases` — the file
/// the one-time unlock of SPEC §4.9 actually meets.
///
/// This is the shape a deployed server has today: Sparks that were earned, Sparks
/// that were paid for with a consumable pack, Sparks from a watched ad, cosmetics
/// bought with them, and a `spark_purchases` row naming the pack. v7 renames that
/// table and must keep every one of those rows exactly as it found them.
void writeV6Database(String path, {required String secretHash}) {
  writeV5Database(path, secretHash: secretHash);
  final db = sqlite3.open(path);
  db.execute(
    'ALTER TABLE player_wallets ADD COLUMN ad_total INTEGER NOT NULL DEFAULT 0',
  );
  db.execute('''
    CREATE TABLE ad_rewards (
      transaction_id TEXT PRIMARY KEY,
      player_id TEXT NOT NULL REFERENCES players (id),
      placement TEXT NOT NULL,
      sparks INTEGER NOT NULL,
      reward_amount INTEGER NOT NULL,
      reward_item TEXT NOT NULL,
      ad_unit TEXT NOT NULL,
      ad_network TEXT NOT NULL,
      key_id TEXT NOT NULL,
      day TEXT NOT NULL,
      rewarded_at TEXT NOT NULL,
      credited_at TEXT NOT NULL,
      refused TEXT
    )
  ''');
  db.execute(
    'CREATE INDEX idx_ad_rewards_player_day ON ad_rewards (player_id, day)',
  );
  db.execute(
    'CREATE INDEX idx_ad_rewards_player_time '
    'ON ad_rewards (player_id, rewarded_at DESC)',
  );
  // One watched ad, already credited: 420 in the wallet becomes 430.
  db.execute(
    'UPDATE player_wallets SET balance = balance + 10, ad_total = 10 '
    'WHERE player_id = ?',
    ['bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'],
  );
  db.execute(
    'INSERT INTO ad_rewards (transaction_id, player_id, placement, sparks, '
    'reward_amount, reward_item, ad_unit, ad_network, key_id, day, '
    'rewarded_at, credited_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      'admob-txn-under-v6',
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'shop',
      10,
      1,
      'sparks',
      'ca-app-pub-3940256099942544/1712485313',
      'network',
      '3335741209',
      '2026-09-23',
      '2026-09-23T09:00:00Z',
      '2026-09-23T09:00:01Z',
    ],
  );
  db.execute('PRAGMA user_version = 6');
  // The point of this file: the ledger is still under its old name, and the
  // product in it is a Spark pack this build no longer sells.
  expect(tableNames(db), contains('spark_purchases'));
  expect(tableNames(db), isNot(contains('purchases')));
  db.close();
}

/// The schema exactly as version 7 left it — **the one deployed today**: the
/// purchase ledger under its current name, and a `scores` table with no `balls`
/// column, because until v8 there was only ever one ball.
///
/// This is the file v8 has to upgrade without losing a row, and the rows in it
/// are the interesting part: two verified runs that nobody ever asked what ball
/// count they were played with, because there was nothing to ask.
void writeV7Database(String path, {required String secretHash}) {
  writeV6Database(path, secretHash: secretHash);
  final db = sqlite3.open(path);
  db.execute('ALTER TABLE spark_purchases RENAME TO purchases');
  db.execute('DROP INDEX IF EXISTS idx_spark_purchases_player');
  db.execute(
    'CREATE INDEX idx_purchases_player ON purchases (player_id, credited_at DESC)',
  );
  db.execute('PRAGMA user_version = 7');
  // The point of this file: no board column anywhere, and no board index.
  expect(columnNames(db, 'scores'), isNot(contains('balls')));
  expect(indexNames(db, 'scores'), isNot(contains('idx_scores_balls')));
  db.close();
}

List<String> columnNames(Database db, String table) => [
  for (final row in db.select('PRAGMA table_info($table)'))
    row['name'] as String,
];

List<String> tableNames(Database db) => [
  for (final row in db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
  ))
    row['name'] as String,
];

List<String> indexNames(Database db, String table) => [
  for (final row in db.select('PRAGMA index_list($table)'))
    row['name'] as String,
]..sort();

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('arco_migration');
    path = '${dir.path}/arco.db';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// Two rows of the shape the old server stored: a name, a score, no owner.
  void seedLegacy() => writeLegacyDatabase(path, [
    [
      'legacy-gold',
      'Gold',
      900,
      5400,
      11,
      Db.formatTimestamp(DateTime.utc(2026, 9, 1, 10)),
      'ip-hash-a',
      0,
    ],
    [
      'legacy-bronze',
      'Bronze',
      100,
      600,
      12,
      Db.formatTimestamp(DateTime.utc(2026, 9, 2, 10)),
      'ip-hash-b',
      7,
    ],
  ]);

  test('an old database file upgrades and keeps its rows', () {
    seedLegacy();

    final db = Db.open(path);
    addTearDown(db.close);

    expect(db.count, 2, reason: 'nothing may be dropped or rewritten');
    expect(db.playerCount, 0);

    final rows = db.topScores();
    expect([for (final r in rows) r.id], ['legacy-gold', 'legacy-bronze']);
    expect(
      [for (final r in rows) r.playerId],
      [null, null],
      reason: 'a pre-identity row is an anonymous run, not a broken one',
    );
    expect(rows.first.name, 'Gold');
    expect(rows.first.ipHash, 'ip-hash-a');
    expect(rows.last.hash, 7);
    expect(db.rank(500), 2, reason: 'legacy rows still count for rank');
  });

  test('the upgraded schema is the one a fresh database gets', () {
    seedLegacy();
    final upgraded = Db.open(path);
    addTearDown(upgraded.close);

    final freshPath = '${dir.path}/fresh.db';
    final fresh = Db.open(freshPath);
    addTearDown(fresh.close);

    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    final rawFresh = sqlite3.open(freshPath);
    addTearDown(rawFresh.close);

    expect(
      raw.select('PRAGMA user_version').first.columnAt(0),
      Db.schemaVersion,
    );
    expect(
      rawFresh.select('PRAGMA user_version').first.columnAt(0),
      Db.schemaVersion,
    );
    expect(tableNames(raw), tableNames(rawFresh));
    expect(tableNames(raw), containsAll(<String>['players', 'scores']));
    expect(columnNames(raw, 'scores'), columnNames(rawFresh, 'scores'));
    expect(columnNames(raw, 'scores'), contains('player_id'));
    expect(columnNames(raw, 'scores'), contains('country'));
    expect(columnNames(raw, 'players'), columnNames(rawFresh, 'players'));
    expect(
      columnNames(raw, 'players'),
      containsAll(<String>[
        'id',
        'created_at',
        'last_seen_at',
        'name',
        'account_provider',
        'account_subject',
        'account_linked_at',
      ]),
    );
    // SPEC §4.5 stores no address for a linked account, and v2 removed the
    // column the identity layer had reserved for one: the claim is checkable
    // from the schema rather than by auditing every write. Credentials moved
    // out to `player_secrets`, because a player may hold one per device.
    expect(columnNames(raw, 'players'), isNot(contains('account_email')));
    expect(columnNames(raw, 'players'), isNot(contains('secret_hash')));
    expect(
      tableNames(raw),
      containsAll(<String>['player_secrets', 'id_token_uses']),
    );
    // v4 (SPEC §4.8): the cosmetic tables arrive in the same upgrade, empty.
    expect(
      tableNames(raw),
      containsAll(<String>[
        'player_wallets',
        'player_items',
        'player_equipped',
        'token_awards',
      ]),
    );
    for (final table in <String>[
      'player_wallets',
      'player_items',
      'player_equipped',
      'token_awards',
    ]) {
      expect(columnNames(raw, table), columnNames(rawFresh, table));
      expect(raw.select('SELECT COUNT(*) AS c FROM $table').single['c'], 0);
    }
    expect(
      indexNames(raw, 'token_awards'),
      contains('idx_token_awards_player_day'),
    );
    expect(
      columnNames(raw, 'player_secrets'),
      columnNames(rawFresh, 'player_secrets'),
    );
    expect(
      columnNames(raw, 'id_token_uses'),
      columnNames(rawFresh, 'id_token_uses'),
    );
    expect(indexNames(raw, 'scores'), indexNames(rawFresh, 'scores'));
    expect(
      indexNames(raw, 'scores'),
      containsAll(<String>[
        'idx_scores_rank',
        'idx_scores_player',
        'idx_scores_country',
      ]),
      reason: 'the old index survives and the new ones are added',
    );
    expect(indexNames(raw, 'players'), contains('idx_players_account'));
  });

  test('opening an already-upgraded database changes nothing', () {
    seedLegacy();
    Db.open(path).close();

    final again = Db.open(path);
    addTearDown(again.close);
    expect(again.count, 2);

    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    expect(
      raw.select('PRAGMA user_version').first.columnAt(0),
      Db.schemaVersion,
    );

    // migrate() straight onto a current database is also a no-op.
    Db.migrate(raw);
    expect(
      raw.select('PRAGMA user_version').first.columnAt(0),
      Db.schemaVersion,
    );
    expect(raw.select('SELECT COUNT(*) AS c FROM scores').first['c'], 2);
  });

  test('a database from a newer build is refused, not half-read', () {
    seedLegacy();
    final raw = sqlite3.open(path);
    raw.execute('PRAGMA user_version = ${Db.schemaVersion + 1}');
    raw.close();

    expect(
      () => Db.open(path),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('newer than this server supports'),
        ),
      ),
    );
    // The store reports it as a storage failure instead of starting half-open.
    expect(ScoreStore.open(path), throwsA(isA<ScoreStoreException>()));
  });

  test('a migrated database serves old and new rows side by side', () async {
    seedLegacy();
    final server = await bootServer(dbPath: path);
    Uri api(String p) => Uri.parse('${server.baseUrl}$p');
    Map<String, dynamic> decode(http.Response r) =>
        jsonDecode(r.body) as Map<String, dynamic>;

    Future<List<Map<String, dynamic>>> entries() async {
      final r = await http.get(api('/api/leaderboard'));
      expect(r.statusCode, 200, reason: r.body);
      return (decode(r)['entries'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
    }

    // The rows written by the old build are on the leaderboard, unowned.
    final before = await entries();
    expect([for (final e in before) e['name']], ['Gold', 'Bronze']);
    expect(before.every((e) => !e.containsKey('playerId')), isTrue);
    expect(
      before.every((e) => !e.containsKey('country')),
      isTrue,
      reason: 'nobody asked those players where they were playing (SPEC §4.6)',
    );
    final polandBefore = await http.get(api('/api/leaderboard?country=PL'));
    expect(decode(polandBefore)['entries'], isEmpty);

    // A player issued against the migrated file can submit and own a run.
    final issued = await issuePlayer(server, name: 'Newcomer');
    final replay = recordSoloReplay(seed: 20260923);
    final submitted = await http.post(
      api('/api/scores'),
      headers: {
        'content-type': 'application/json',
        'authorization': authOf(issued),
      },
      body: jsonEncode(scoreBody('Newcomer', replay)),
    );
    expect(submitted.statusCode, 201, reason: submitted.body);
    expect(decode(submitted)['playerId'], issued['id']);

    final after = await entries();
    expect(after, hasLength(3));
    final owned = after.singleWhere((e) => e['name'] == 'Newcomer');
    expect(owned['playerId'], issued['id']);
    expect(
      after.where((e) => e['name'] == 'Gold').single.containsKey('playerId'),
      isFalse,
      reason: 'the legacy row must not be adopted by anybody',
    );

    final me = await http.get(
      api('/api/players/me'),
      headers: {'authorization': authOf(issued)},
    );
    expect(me.statusCode, 200, reason: me.body);
    expect(decode(me)['games'], 1);
    expect(decode(me)['bestScore'], replay.claimedScore);
    expect(
      decode(me)['rank'],
      1 + before.where((e) => (e['score'] as int) > replay.claimedScore).length,
      reason: 'ranked among the legacy rows, not separately from them',
    );

    // A run submitted with a country lands on that country's board alone, and
    // the pre-country rows do not dilute it (SPEC §4.6).
    final national = await http.post(
      api('/api/scores'),
      headers: {
        'content-type': 'application/json',
        'authorization': authOf(issued),
      },
      body: jsonEncode({
        'name': 'Newcomer',
        'replay': recordSoloReplay(seed: 424242).toJson(),
        'country': 'PL',
      }),
    );
    expect(national.statusCode, 201, reason: national.body);
    expect(decode(national)['country'], 'PL');
    expect(decode(national)['countryRank'], 1);
    final poland = await http.get(api('/api/leaderboard?country=PL'));
    final polandEntries = (decode(poland)['entries'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(polandEntries, hasLength(1));
    expect(polandEntries.single['country'], 'PL');

    // The file itself still holds the original rows after all of that.
    await server.stop();
    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    expect(
      raw.select('SELECT player_id FROM scores WHERE id = ?', [
        'legacy-gold',
      ]).first['player_id'],
      isNull,
    );
    expect(
      raw.select('SELECT country FROM scores WHERE id = ?', [
        'legacy-gold',
      ]).first['country'],
      isNull,
      reason: 'an upgraded row counts for no country',
    );
    expect(raw.select('SELECT COUNT(*) AS c FROM scores').first['c'], 4);
  });

  group('a version 1 database', () {
    test('keeps its players working after the upgrade', () async {
      // The credential this player was issued before v2 existed. It only ever
      // left the server once, at issue time, so the client still holds it and it
      // has to keep authenticating.
      const secret = 'a-secret-issued-under-schema-v1';
      writeV1Database(path, secretHash: hashPlayerSecret(secret));

      final db = Db.open(path);
      expect(db.playerCount, 1);
      const playerId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final stored = db.playerWithSecrets(playerId);
      expect(stored, isNotNull);
      expect(
        stored!.secretHashes,
        hasLength(1),
        reason: 'the one secret became the one credential',
      );
      expect(
        verifyPlayerSecret(secret, stored.secretHashes.single),
        isTrue,
        reason: 'the digest was carried across unchanged',
      );
      expect(stored.player.name, 'Veteran');
      expect(stored.player.createdAt, '2026-09-10T08:00:00Z');
      expect(stored.player.lastSeenAt, '2026-09-11T08:00:00Z');
      final stats = db.playerScores(playerId);
      expect(stats.bestScore, 450);
      expect(
        stats.country,
        isNull,
        reason: 'the run predates SPEC §4.6, so it counts for no country',
      );
      expect(stats.countryRank, isNull);
      db.close();

      // And the whole way through HTTP, against the migrated file.
      final server = await bootServer(dbPath: path);
      final me = await http.get(
        Uri.parse('${server.baseUrl}/api/players/me'),
        headers: {'authorization': playerAuth(playerId, secret)},
      );
      expect(me.statusCode, 200, reason: me.body);
      final body = jsonDecode(me.body) as Map<String, dynamic>;
      expect(body['id'], playerId);
      expect(body['name'], 'Veteran');
      expect(body['bestScore'], 450);
      expect(body['games'], 1);
      expect(body['country'], isNull);
      expect(body['countryBestScore'], isNull);
      expect(body['countryRank'], isNull);
    });

    test('loses the column that was reserved for an address', () {
      writeV1Database(path, secretHash: hashPlayerSecret('x'));
      Db.open(path).close();

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      expect(
        raw.select('PRAGMA user_version').first.columnAt(0),
        Db.schemaVersion,
      );
      // v3 (SPEC §4.6) arrives in the same upgrade, and the existing row keeps
      // its values with no country.
      expect(columnNames(raw, 'scores'), contains('country'));
      expect(indexNames(raw, 'scores'), contains('idx_scores_country'));
      expect(raw.select('SELECT * FROM scores').single['country'], isNull);
      expect(columnNames(raw, 'players'), isNot(contains('account_email')));
      expect(columnNames(raw, 'players'), isNot(contains('secret_hash')));
      expect(
        tableNames(raw),
        containsAll(<String>[
          'player_secrets',
          'player_aliases',
          'id_token_uses',
        ]),
      );
      // The row itself is untouched apart from those two columns.
      final player = raw.select('SELECT * FROM players').single;
      expect(player['name'], 'Veteran');
      expect(player['account_provider'], isNull);
      expect(raw.select('SELECT COUNT(*) AS c FROM scores').single['c'], 1);
    });
  });

  group('a version 3 database', () {
    // The file the next release actually meets: the schema currently deployed,
    // with scores, a player and a credential in it. It has to gain a shop
    // (SPEC §4.8) without losing a row or invalidating a credential.
    const playerId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const secret = 'a-secret-issued-under-schema-v3';

    test('gains the cosmetic tables and keeps every score', () {
      writeV3Database(path, secretHash: hashPlayerSecret(secret));

      final db = Db.open(path);
      addTearDown(db.close);

      expect(db.count, 2, reason: 'nothing may be dropped or rewritten');
      expect(db.playerCount, 1);
      final rows = db.topScores();
      expect([for (final r in rows) r.id], ['v3-owned', 'v3-anonymous']);
      expect(rows.first.score, 820);
      expect(rows.first.playerId, playerId);
      expect(rows.first.country, 'PL');
      expect(rows.last.playerId, isNull);
      expect(db.rank(500), 2, reason: 'the existing rows still count for rank');
      expect(db.topScores(country: 'PL'), hasLength(1));

      // The credential the client stored before the shop existed still works.
      final stored = db.playerWithSecrets(playerId);
      expect(stored, isNotNull);
      expect(verifyPlayerSecret(secret, stored!.secretHashes.single), isTrue);
      expect(stored.player.name, 'Regular');

      // And the shop starts empty: no wallet, no purchases, no preference. There
      // is nothing to backfill, because free items are owned implicitly and an
      // unset slot means the default.
      expect(db.itemRowCount, 0);
      expect(db.awardCount, 0);
      expect(db.walletBalance(playerId), 0);
      final inventory = db.inventoryOf(playerId, now: DateTime.now().toUtc());
      expect(inventory.balance, 0);
      expect(inventory.earnedTotal, 0);
      expect(inventory.ownedItemIds, isEmpty);
      expect(inventory.equipped, isEmpty);
      expect(inventory.earnedToday, 0);

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      expect(
        raw.select('PRAGMA user_version').first.columnAt(0),
        Db.schemaVersion,
      );
      expect(
        tableNames(raw),
        containsAll(<String>[
          'player_wallets',
          'player_items',
          'player_equipped',
          'token_awards',
        ]),
      );
      // The existing tables keep every column they had. `balls` is the one v8
      // adds (SPEC §4.6); nothing was dropped and nothing was rewritten.
      expect(columnNames(raw, 'scores'), <String>[
        'id',
        'name',
        'score',
        'ticks',
        'seed',
        'created_at',
        'ip_hash',
        'hash',
        'player_id',
        'country',
        'balls',
      ]);
      expect(columnNames(raw, 'players'), <String>[
        'id',
        'created_at',
        'last_seen_at',
        'name',
        'account_provider',
        'account_subject',
        'account_linked_at',
      ]);
    });

    test('serves the shop over HTTP against the migrated file', () async {
      writeV3Database(path, secretHash: hashPlayerSecret(secret));
      final server = await bootServer(dbPath: path);
      Uri api(String p) => Uri.parse('${server.baseUrl}$p');
      Map<String, dynamic> decode(http.Response r) =>
          jsonDecode(r.body) as Map<String, dynamic>;
      final auth = playerAuth(playerId, secret);

      // The player from the old file opens the shop: a zero balance, the free
      // items, and the defaults equipped.
      final catalogue = await http.get(
        api('/api/shop/catalogue'),
        headers: {'authorization': auth},
      );
      expect(catalogue.statusCode, 200, reason: catalogue.body);
      expect(decode(catalogue)['balance'], 0);
      expect(decode(catalogue)['equipped'], {
        'theme': 'theme.neon',
        'ball': 'ball.orb',
        'paddle': 'paddle.arc',
      });
      expect(
        (decode(catalogue)['items'] as List<dynamic>),
        hasLength(Catalogue.items.length),
      );

      // Their old scores did not retroactively pay tokens, so nothing is
      // affordable yet.
      final tooPoor = await http.post(
        api('/api/shop/buy'),
        headers: {'content-type': 'application/json', 'authorization': auth},
        body: jsonEncode({'itemId': 'ball.comet'}),
      );
      expect(tooPoor.statusCode, 402, reason: tooPoor.body);

      // A run played after the upgrade pays, and then the purchase works.
      await grantTokens(server, playerId, 80);
      final bought = await http.post(
        api('/api/shop/buy'),
        headers: {'content-type': 'application/json', 'authorization': auth},
        body: jsonEncode({'itemId': 'ball.comet'}),
      );
      expect(bought.statusCode, 200, reason: bought.body);
      expect(decode(bought)['charged'], 80);
      expect(decode(bought)['balance'], 0);

      // The pre-existing rows are still the leaderboard.
      final board = await http.get(api('/api/leaderboard'));
      final entries = (decode(board)['entries'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect([for (final e in entries) e['name']], ['Regular', 'Passer-by']);
      final me = await http.get(
        api('/api/players/me'),
        headers: {'authorization': auth},
      );
      expect(decode(me)['bestScore'], 820);
      expect(decode(me)['country'], 'PL');

      await server.stop();
      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      expect(raw.select('SELECT COUNT(*) AS c FROM scores').single['c'], 2);
      expect(
        raw.select('SELECT item_id FROM player_items').single['item_id'],
        'ball.comet',
      );
    });
  });

  group('a version 4 database', () {
    // The file the money feature actually meets: a deployed shop with Sparks in
    // a wallet, cosmetics owned and a ledger of runs. It has to gain the paid
    // ledger of SPEC §4.9 without disturbing any of that — a migration that
    // touched a balance would be a migration that stole from somebody.
    const playerId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const secret = 'a-secret-issued-under-schema-v4';

    test('gains the paid-Spark ledger and keeps every Spark', () {
      writeV4Database(path, secretHash: hashPlayerSecret(secret));

      final db = Db.open(path);
      addTearDown(db.close);

      // Nothing about the earned economy moved.
      expect(db.walletBalance(playerId), 120);
      final inventory = db.inventoryOf(playerId, now: DateTime.now().toUtc());
      expect(inventory.balance, 120);
      expect(inventory.earnedTotal, 200);
      expect(inventory.spentTotal, 80);
      expect(inventory.ownedItemIds, <String>['ball.comet']);
      expect(inventory.equipped, {'ball': 'ball.comet'});
      // And the new columns read as the truth: before these versions there was
      // no way to buy a Spark and no way to watch an ad for one, so none of this
      // wallet came from either.
      expect(inventory.purchasedTotal, 0);
      expect(inventory.adTotal, 0);
      expect(db.purchaseCount, 0);
      expect(db.purchasesOf(playerId), isEmpty);
      expect(
        db.isPremium(playerId),
        isFalse,
        reason: 'nobody is premium because nobody has bought anything',
      );
      expect(db.adRewardCount, 0);
      expect(db.adRewards(playerId), isEmpty);

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      expect(
        raw.select('PRAGMA user_version').first.columnAt(0),
        Db.schemaVersion,
      );
      // v5 created `spark_purchases` and v7 renamed it, so a file that skips
      // straight from v4 arrives with the purchase ledger under its current name
      // and no trace of the old one.
      expect(tableNames(raw), contains('purchases'));
      expect(tableNames(raw), isNot(contains('spark_purchases')));
      // v6 lands in the same upgrade (SPEC §4.10), so the wallet gains both
      // appended columns and the ad ledger appears beside the purchase one.
      // Neither of them touched a Spark on the way in.
      expect(tableNames(raw), contains('ad_rewards'));
      expect(columnNames(raw, 'player_wallets'), <String>[
        'player_id',
        'balance',
        'earned_total',
        'spent_total',
        'updated_at',
        'purchased_total',
        'ad_total',
      ]);
      // Every other table is untouched.
      expect(columnNames(raw, 'player_items'), <String>[
        'player_id',
        'item_id',
        'acquired_at',
        'price_paid',
      ]);
      expect(columnNames(raw, 'token_awards'), <String>[
        'replay_key',
        'player_id',
        'score_id',
        'score',
        'tokens',
        'day',
        'awarded_at',
      ]);
    });

    test('the migrated file takes the unlock and explains it', () {
      writeV4Database(path, secretHash: hashPlayerSecret(secret));
      final db = Db.open(path);
      addTearDown(db.close);

      final grant = db.grantPurchase(
        PurchaseGrantRequest(
          playerId: playerId,
          productId: FullUnlock.productId,
          transactionId: 'txn-after-migration',
          store: 'app_store',
          environment: 'PRODUCTION',
          source: 'webhook',
          purchasedAt: DateTime.utc(2026, 9, 24, 11),
          now: DateTime.utc(2026, 9, 24, 12),
        ),
      );
      expect(grant.granted, isTrue);
      expect(grant.premium, isTrue);

      final inventory = db.inventoryOf(
        playerId,
        now: DateTime.utc(2026, 9, 24),
      );
      expect(inventory.premium, isTrue);
      expect(
        inventory.balance,
        120,
        reason: 'the unlock credits no Sparks, so the wallet does not move',
      );
      expect(
        inventory.purchasedTotal,
        0,
        reason: 'money no longer buys Sparks',
      );
      // And it is explainable: one row, naming the payment behind it.
      final row = db.purchaseByTransaction('txn-after-migration')!;
      expect(row.productId, FullUnlock.productId);
      expect(row.grantsPremium, isTrue);
      expect(db.purchasesOf(playerId).single.transactionId, row.transactionId);
      // Everything in the catalogue, including what this player never bought.
      for (final item in Catalogue.items) {
        expect(db.ownsItem(playerId, item.id), isTrue, reason: item.id);
      }
    });

    test('the upgraded v4 file matches a fresh database exactly', () {
      writeV4Database(path, secretHash: hashPlayerSecret(secret));
      final upgraded = Db.open(path);
      addTearDown(upgraded.close);
      final freshPath = '${dir.path}/fresh-v5.db';
      final fresh = Db.open(freshPath);
      addTearDown(fresh.close);

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      final rawFresh = sqlite3.open(freshPath);
      addTearDown(rawFresh.close);
      expect(tableNames(raw), tableNames(rawFresh));
      // Column *order* differs by construction (ALTER TABLE appends), so the
      // sets are what has to match.
      expect(
        columnNames(raw, 'player_wallets').toSet(),
        columnNames(rawFresh, 'player_wallets').toSet(),
      );
      expect(columnNames(raw, 'purchases'), columnNames(rawFresh, 'purchases'));
      expect(indexNames(raw, 'purchases'), indexNames(rawFresh, 'purchases'));
    });
  });

  group('a version 5 database', () {
    // The file rewarded ads actually meet: a deployed shop with Sparks that were
    // earned, Sparks that were paid for, cosmetics owned and both ledgers behind
    // them. It has to gain the ad ledger of SPEC §4.10 without disturbing any of
    // that — a migration that touched a balance would be a migration that stole
    // from somebody, and one that touched `purchased_total` would be one that
    // stole money.
    const playerId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const secret = 'a-secret-issued-under-schema-v5';

    test('gains the ad ledger and keeps every Spark', () {
      writeV5Database(path, secretHash: hashPlayerSecret(secret));

      final db = Db.open(path);
      addTearDown(db.close);

      // Nothing about either existing economy moved.
      expect(db.walletBalance(playerId), 420);
      final inventory = db.inventoryOf(playerId, now: DateTime.now().toUtc());
      expect(inventory.balance, 420);
      expect(inventory.earnedTotal, 200);
      expect(inventory.purchasedTotal, 300);
      expect(inventory.spentTotal, 80);
      expect(inventory.ownedItemIds, <String>['ball.comet']);
      expect(inventory.equipped, {'ball': 'ball.comet'});
      expect(db.purchaseCount, 1);
      final legacy = db.purchaseByTransaction('apple-txn-under-v5')!;
      expect(
        legacy.productId,
        'arco.sparks.small',
        reason: 'the ledger row is untouched, under its original product id',
      );
      expect(
        legacy.grantsPremium,
        isFalse,
        reason: 'a Spark pack paid in Sparks; it never unlocked the catalogue',
      );
      expect(
        db.isPremium(playerId),
        isFalse,
        reason: 'and the upgrade must not hand anybody premium retroactively',
      );
      expect(
        db.ownsItem(playerId, 'theme.glass'),
        isFalse,
        reason: 'only the item this wallet actually bought is owned',
      );
      // And the new column reads as the truth: before this version there were no
      // ads, so none of this wallet came from one.
      expect(inventory.adTotal, 0);
      expect(db.adRewardCount, 0);
      expect(db.adRewards(playerId), isEmpty);

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      expect(
        raw.select('PRAGMA user_version').first.columnAt(0),
        Db.schemaVersion,
      );
      expect(tableNames(raw), contains('ad_rewards'));
      expect(columnNames(raw, 'player_wallets'), <String>[
        'player_id',
        'balance',
        'earned_total',
        'spent_total',
        'updated_at',
        'purchased_total',
        'ad_total',
      ]);
      // Every other table is untouched — `spark_purchases` only in name, which
      // v7 changes and nothing else about it (SPEC §4.9).
      expect(tableNames(raw), contains('purchases'));
      expect(tableNames(raw), isNot(contains('spark_purchases')));
      expect(columnNames(raw, 'purchases'), <String>[
        'transaction_id',
        'player_id',
        'product_id',
        'sparks',
        'store',
        'environment',
        'source',
        'event_id',
        'purchased_at',
        'credited_at',
        'refunded_at',
        'clawed_back',
      ]);
      expect(columnNames(raw, 'token_awards'), <String>[
        'replay_key',
        'player_id',
        'score_id',
        'score',
        'tokens',
        'day',
        'awarded_at',
      ]);
    });

    test('the migrated file takes an ad reward and explains the balance', () {
      writeV5Database(path, secretHash: hashPlayerSecret(secret));
      final db = Db.open(path);
      addTearDown(db.close);

      final credit = db.creditAdReward(
        AdCreditRequest(
          playerId: playerId,
          placement: 'shop',
          transactionId: 'admob-txn-after-migration',
          rewardAmount: 999,
          rewardItem: 'sparks',
          adUnit: 'ca-app-pub-3940256099942544/1712485313',
          adNetwork: 'network',
          keyId: '3335741209',
          rewardedAt: DateTime.utc(2026, 9, 24, 11),
          now: DateTime.utc(2026, 9, 24, 12),
        ),
      );
      expect(credit.credited, isTrue);
      expect(credit.sparks, AdRate.sparksPerAd);
      expect(credit.balance, 420 + AdRate.sparksPerAd);

      final inventory = db.inventoryOf(
        playerId,
        now: DateTime.utc(2026, 9, 24),
      );
      expect(inventory.adTotal, AdRate.sparksPerAd);
      expect(
        inventory.balance,
        inventory.earnedTotal +
            inventory.purchasedTotal +
            inventory.adTotal -
            inventory.spentTotal,
        reason:
            'played for + paid for + watched for - spent, with a '
            'non-duplicable row behind each of the three',
      );
    });

    test('the upgraded v5 file matches a fresh database exactly', () {
      writeV5Database(path, secretHash: hashPlayerSecret(secret));
      final upgraded = Db.open(path);
      addTearDown(upgraded.close);
      final freshPath = '${dir.path}/fresh-v6.db';
      final fresh = Db.open(freshPath);
      addTearDown(fresh.close);

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      final rawFresh = sqlite3.open(freshPath);
      addTearDown(rawFresh.close);
      expect(tableNames(raw), tableNames(rawFresh));
      // Column *order* differs by construction (ALTER TABLE appends), so the
      // sets are what has to match.
      expect(
        columnNames(raw, 'player_wallets').toSet(),
        columnNames(rawFresh, 'player_wallets').toSet(),
      );
      expect(
        columnNames(raw, 'ad_rewards'),
        columnNames(rawFresh, 'ad_rewards'),
      );
      expect(indexNames(raw, 'ad_rewards'), indexNames(rawFresh, 'ad_rewards'));
    });

    test('a v0 file upgrades all the way to the current schema in one step', () {
      // The deployed production file is still the scores-only one. It must reach
      // the current schema through every intermediate version in a single
      // transaction, not just the last hop.
      writeLegacyDatabase(path, <List<Object?>>[
        [
          'legacy-1',
          'Ancient',
          900,
          5000,
          7,
          '2026-09-01T08:00:00Z',
          'ip-hash-a',
          1,
        ],
      ]);
      final db = Db.open(path);
      addTearDown(db.close);
      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      expect(
        raw.select('PRAGMA user_version').first.columnAt(0),
        Db.schemaVersion,
      );
      expect(tableNames(raw), contains('ad_rewards'));
      expect(tableNames(raw), contains('purchases'));
      expect(tableNames(raw), isNot(contains('spark_purchases')));
      expect(columnNames(raw, 'player_wallets'), contains('ad_total'));
      expect(db.count, 1, reason: 'the ancient score is still there');
    });
  });

  group('a version 6 database', () {
    // The file the one-time unlock actually meets (SPEC §4.9): a deployed server
    // with Sparks earned, Sparks *bought* from a consumable pack, Sparks from a
    // watched ad, a cosmetic bought with them, and a `spark_purchases` row naming
    // the pack. v7 renames that table and does nothing else — no row is dropped,
    // rewritten or backfilled, because the entitlement the ledger now answers is
    // derived from it rather than stored in it.
    const playerId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const secret = 'a-secret-issued-under-schema-v6';

    test('the paid-Spark ledger becomes the purchase ledger, row for row', () {
      writeV6Database(path, secretHash: hashPlayerSecret(secret));

      final db = Db.open(path);
      addTearDown(db.close);

      // Not one Spark moved, in any of the three economies.
      expect(db.walletBalance(playerId), 430);
      final inventory = db.inventoryOf(
        playerId,
        now: DateTime.utc(2026, 9, 25),
      );
      expect(inventory.balance, 430);
      expect(inventory.earnedTotal, 200);
      expect(inventory.purchasedTotal, 300);
      expect(inventory.adTotal, 10);
      expect(inventory.spentTotal, 80);
      expect(inventory.ownedItemIds, <String>['ball.comet']);
      expect(inventory.equipped, {'ball': 'ball.comet'});
      expect(db.adRewardCount, 1);
      expect(db.adRewards(playerId).single.transactionId, 'admob-txn-under-v6');

      // The ledger row is the same row, readable under the new name.
      expect(db.purchaseCount, 1);
      final row = db.purchaseByTransaction('apple-txn-under-v5')!;
      expect(row.playerId, playerId);
      expect(row.productId, 'arco.sparks.small');
      expect(row.store, 'app_store');
      expect(row.source, 'webhook');
      expect(row.purchasedAt, '2026-09-22T08:00:00Z');
      expect(row.refunded, isFalse);
      expect(
        row.grantsPremium,
        isFalse,
        reason: 'a Spark pack was never the unlock, so it grants nothing',
      );

      // Nobody is handed premium by an upgrade, and nothing is backfilled: the
      // only thing that makes a player premium is buying the unlock.
      expect(inventory.premium, isFalse);
      expect(db.isPremium(playerId), isFalse);
      expect(db.ownsItem(playerId, 'ball.comet'), isTrue);
      expect(db.ownsItem(playerId, 'theme.glass'), isFalse);
      expect(db.itemRowCount, 1, reason: 'no row per item was written');

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      expect(
        raw.select('PRAGMA user_version').first.columnAt(0),
        Db.schemaVersion,
      );
      expect(tableNames(raw), contains('purchases'));
      expect(tableNames(raw), isNot(contains('spark_purchases')));
      // Including the columns of the model that is gone. They are what still
      // explains the 300 paid-for Sparks in this wallet, so they stay.
      expect(columnNames(raw, 'purchases'), <String>[
        'transaction_id',
        'player_id',
        'product_id',
        'sparks',
        'store',
        'environment',
        'source',
        'event_id',
        'purchased_at',
        'credited_at',
        'refunded_at',
        'clawed_back',
      ]);
      expect(
        raw
            .select(
              'SELECT sparks, clawed_back FROM purchases WHERE '
              'transaction_id = ?',
              ['apple-txn-under-v5'],
            )
            .single
            .values,
        <Object?>[300, 0],
      );
      // The index follows the table rather than keeping the old table's name,
      // which is the one thing `ALTER TABLE … RENAME TO` does not do for us.
      expect(indexNames(raw, 'purchases'), contains('idx_purchases_player'));
      expect(
        indexNames(raw, 'purchases'),
        isNot(contains('idx_spark_purchases_player')),
      );
    });

    test('the migrated file grants and revokes premium', () {
      writeV6Database(path, secretHash: hashPlayerSecret(secret));
      final db = Db.open(path);
      addTearDown(db.close);

      final grant = db.grantPurchase(
        PurchaseGrantRequest(
          playerId: playerId,
          productId: FullUnlock.productId,
          transactionId: 'apple-txn-unlock',
          store: 'app_store',
          environment: 'PRODUCTION',
          source: 'webhook',
          purchasedAt: DateTime.utc(2026, 9, 25, 11),
          now: DateTime.utc(2026, 9, 25, 12),
        ),
      );
      expect(grant.granted, isTrue);
      expect(grant.premium, isTrue);
      expect(
        db.purchaseCount,
        2,
        reason: 'the legacy pack row is still there beside the unlock',
      );
      for (final item in Catalogue.items) {
        expect(db.ownsItem(playerId, item.id), isTrue, reason: item.id);
      }
      expect(
        db.walletBalance(playerId),
        430,
        reason: 'the unlock credits nothing, so the migrated wallet is intact',
      );

      // And a refund takes premium back without touching the cosmetic this
      // wallet bought with Sparks before any of this existed.
      final revoke = db.revokePurchase(
        transactionId: 'apple-txn-unlock',
        now: DateTime.utc(2026, 9, 26),
      );
      expect(revoke.revoked, isTrue);
      expect(revoke.premium, isFalse);
      expect(db.ownsItem(playerId, 'ball.comet'), isTrue);
      expect(db.ownsItem(playerId, 'theme.glass'), isFalse);
      expect(db.walletBalance(playerId), 430);
      expect(
        db.purchaseByTransaction('apple-txn-under-v5')!.refunded,
        isFalse,
        reason: 'and the legacy row is not collateral damage',
      );
    });

    test('the upgraded v6 file matches a fresh database exactly', () {
      writeV6Database(path, secretHash: hashPlayerSecret(secret));
      final upgraded = Db.open(path);
      addTearDown(upgraded.close);
      final freshPath = '${dir.path}/fresh-v7.db';
      final fresh = Db.open(freshPath);
      addTearDown(fresh.close);

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      final rawFresh = sqlite3.open(freshPath);
      addTearDown(rawFresh.close);
      expect(tableNames(raw), tableNames(rawFresh));
      expect(
        columnNames(raw, 'purchases'),
        columnNames(rawFresh, 'purchases'),
        reason: 'a renamed table and a created one must have the same shape',
      );
      expect(indexNames(raw, 'purchases'), indexNames(rawFresh, 'purchases'));
      expect(
        columnNames(raw, 'player_wallets').toSet(),
        columnNames(rawFresh, 'player_wallets').toSet(),
      );
    });
  });

  // --------------------------------------------- v7 → v8: the board column

  /// The upgrade a live deployment is about to take (SPEC §4.3, §4.6): the
  /// leaderboard grows a board dimension, and the rows already in it have to end
  /// up on the board they were actually played on — the one-ball board, because
  /// until now that was the only game there was.
  group('a version 7 database', () {
    const playerId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const secret = 'a-secret-issued-under-schema-v3';

    test('gains the board column and puts every old row on board one', () {
      writeV7Database(path, secretHash: hashPlayerSecret(secret));

      final db = Db.open(path);
      addTearDown(db.close);

      expect(
        db.count,
        2,
        reason: 'a column added with a default drops nothing',
      );
      // Every stored row is a one-ball run, which is the truth about it rather
      // than a guess: two balls could not be played before this version.
      expect(db.countOnBoard(1), 2);
      expect(db.countOnBoard(2), 0);
      final rows = db.topScores();
      expect([for (final r in rows) r.id], ['v3-owned', 'v3-anonymous']);
      expect([for (final r in rows) r.balls], [1, 1]);
      expect(rows.first.score, 820);
      expect(rows.first.playerId, playerId);
      expect(rows.first.country, 'PL');
      expect(
        rows.last.playerId,
        isNull,
        reason: 'an anonymous legacy row stays anonymous',
      );
      expect(
        db.rank(500),
        2,
        reason: 'the legacy rows still count for rank on the board they are on',
      );
      expect(db.topScores(country: 'PL'), hasLength(1));
      expect(
        db.topScores(balls: 2),
        isEmpty,
        reason: 'nothing was invented on the two-ball board',
      );
    });

    test('a migrated file takes runs on both boards and keeps them apart', () {
      writeV7Database(path, secretHash: hashPlayerSecret(secret));
      final db = Db.open(path);
      addTearDown(db.close);

      db.insertScore(
        ScoreRow(
          id: 'two-ball-run',
          name: 'Duo',
          score: 400,
          ticks: 2400,
          seed: 5,
          createdAt: Db.formatTimestamp(DateTime.utc(2026, 9, 26, 10)),
          ipHash: 'ip-hash-2',
          hash: 9,
          playerId: playerId,
          country: 'PL',
          balls: 2,
        ),
      );

      expect(
        [for (final r in db.topScores(balls: 1)) r.id],
        ['v3-owned', 'v3-anonymous'],
      );
      expect([for (final r in db.topScores(balls: 2)) r.id], ['two-ball-run']);
      // 400 is behind 820 on board one and ahead of nothing on board two, so
      // the same number is two different ranks — which is the whole point.
      expect(db.rank(400, balls: 1), 2);
      expect(db.rank(400, balls: 2), 1);
      final boards = db.playerBoards(playerId);
      expect([for (final b in boards) b.balls], [1, 2]);
      expect([for (final b in boards) b.bestScore], [820, 400]);
      expect([for (final b in boards) b.rank], [1, 1]);
    });

    test('the leaderboard keeps serving the old rows over HTTP', () async {
      writeV7Database(path, secretHash: hashPlayerSecret(secret));
      final server = await bootServer(dbPath: path);
      Future<Map<String, dynamic>> get(String p) async {
        final r = await http.get(Uri.parse('${server.baseUrl}$p'));
        expect(r.statusCode, 200, reason: r.body);
        return jsonDecode(r.body) as Map<String, dynamic>;
      }

      // A client that has never heard of boards asks the question it always
      // asked and gets every row it always got.
      final legacy = await get('/api/leaderboard');
      expect(legacy['balls'], 1);
      expect(
        [for (final e in legacy['entries'] as List<dynamic>) e['name']],
        ['Regular', 'Passer-by'],
      );
      // And naming the board explicitly is the same answer.
      final explicit = await get('/api/leaderboard?balls=1');
      expect(explicit, legacy);
      expect((await get('/api/leaderboard?balls=2'))['entries'], isEmpty);
      expect((await get('/api/leaderboard/rank?score=500'))['rank'], 2);
      expect(
        (await get('/api/leaderboard/rank?score=500&balls=2'))['rank'],
        1,
        reason: 'the two-ball board is empty, so any score leads it',
      );
    });

    test('the upgraded v7 file matches a fresh database exactly', () {
      writeV7Database(path, secretHash: hashPlayerSecret(secret));
      final upgraded = Db.open(path);
      addTearDown(upgraded.close);
      final freshPath = '${dir.path}/fresh-v8.db';
      final fresh = Db.open(freshPath);
      addTearDown(fresh.close);

      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      final rawFresh = sqlite3.open(freshPath);
      addTearDown(rawFresh.close);
      expect(tableNames(raw), tableNames(rawFresh));
      expect(columnNames(raw, 'scores'), columnNames(rawFresh, 'scores'));
      expect(indexNames(raw, 'scores'), indexNames(rawFresh, 'scores'));
      expect(
        indexNames(raw, 'scores'),
        containsAll(<String>['idx_scores_balls', 'idx_scores_balls_country']),
      );
      expect(
        raw.select('PRAGMA user_version').first.columnAt(0),
        Db.schemaVersion,
      );
    });
  });
}
