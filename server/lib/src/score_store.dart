/// Asynchronous access to the leaderboard storage of SPEC §4.3.
///
/// Every `sqlite3` call is synchronous C code: it occupies the isolate that
/// makes it until the C call returns. The isolate that answers HTTP requests
/// also drives the 60 Hz room tick (SPEC §3), so no query may run on it — a
/// handful of `GET /api/leaderboard` requests against a large table would
/// starve every live duel, and a single blocked write (another process holding
/// the write lock, `PRAGMA busy_timeout` in `db.dart`) would freeze the whole
/// server for as long as the lock is held.
///
/// [ScoreStore] therefore owns the [Db] on a dedicated long-lived isolate and
/// exposes it as futures. Requests are serialized in arrival order, which is
/// what a single SQLite writer allows anyway.
library;

import 'dart:async';
import 'dart:isolate';

import 'db.dart';

/// A storage call that failed inside the db isolate (SQLite error, closed
/// store, dead isolate). The HTTP error boundary turns it into a 500.
class ScoreStoreException implements Exception {
  const ScoreStoreException(this.message);

  final String message;

  @override
  String toString() => 'ScoreStoreException: $message';
}

/// The [Db] operations that can be requested from the worker.
enum _Op {
  insert,
  top,
  rank,
  count,
  createPlayer,
  playerById,
  playerByAccount,
  playerWithSecrets,
  canonicalPlayerId,
  addPlayerSecret,
  secretCount,
  touchPlayer,
  notePlayerScore,
  playerScores,
  playerCount,
  linkAccount,
  unlinkAccount,
  deletePlayer,
  tokenUseCount,
  inventory,
  ownsItem,
  isPremium,
  buyItem,
  equipItems,
  awardTokens,
  walletBalance,
  grantPurchase,
  revokePurchase,
  purchasesOf,
  purchaseByTransaction,
  purchaseCount,
  creditAdReward,
  adRewardState,
  adRewards,
  adReward,
  adRewardCount,
  close,
}

/// One request to the db isolate. Plain values only, so it can be sent.
class _DbRequest {
  const _DbRequest(
    this.id,
    this.op, {
    this.row,
    this.period = LeaderboardPeriod.all,
    this.limit = 0,
    this.now,
    this.score = 0,
    this.player,
    this.playerId,
    this.name,
    this.credentialId,
    this.secretHash,
    this.provider,
    this.subject,
    this.link,
    this.country,
    this.itemId,
    this.replayKey,
    this.scoreId,
    this.equip,
    this.purchase,
    this.transactionId,
    this.adReward,
  });

  final int id;
  final _Op op;
  final ScoreRow? row;
  final LeaderboardPeriod period;
  final int limit;
  final DateTime? now;
  final int score;
  final PlayerRow? player;
  final String? playerId;
  final String? name;
  final String? credentialId;
  final String? secretHash;
  final String? provider;
  final String? subject;
  final AccountLinkRequest? link;

  /// Validated ISO 3166-1 alpha-2 code the query is restricted to (SPEC §4.6),
  /// or null for the global board.
  final String? country;

  /// Catalogue item id a shop call is about (SPEC §4.8).
  final String? itemId;

  /// Digest of the run a token award is for, and the score row it stored.
  final String? replayKey;
  final String? scoreId;

  final EquipRequest? equip;

  /// One purchase grant (SPEC §4.9). It carries identifiers only — never what
  /// the purchase grants, which the db isolate decides from the product id.
  final PurchaseGrantRequest? purchase;

  /// The store transaction id a refund or a ledger lookup is about (SPEC §4.9),
  /// or the AdMob transaction id an ad-reward lookup is about (SPEC §4.10).
  final String? transactionId;

  /// One ad-reward crediting call (SPEC §4.10). Identifiers and timestamps only;
  /// the one amount it carries is the one the server never reads.
  final AdCreditRequest? adReward;
}

/// One answer from the db isolate: the result, or [error] when the call threw.
class _DbReply {
  const _DbReply(this.id, this.value, this.error);

  final int id;
  final Object? value;
  final String? error;
}

class ScoreStore {
  ScoreStore._(
    this._isolate,
    this._commands,
    this._replies,
    this._exited,
    this._pending,
  );

  /// Opens the database at [path] on a new isolate (see [Db.open] for the
  /// accepted paths, including `:memory:`) and waits until it is ready, so a
  /// failure to open surfaces before the server starts serving.
  ///
  /// [busyTimeout] is forwarded to `PRAGMA busy_timeout`; the default matches
  /// [Db.open]. Tests lower it to keep a lock-contention case short.
  static Future<ScoreStore> open(
    String path, {
    Duration busyTimeout = Db.defaultBusyTimeout,
  }) async {
    final replies = ReceivePort();
    final exited = Completer<void>();
    final bootstrap = Completer<Object?>();
    final pending = <int, Completer<Object?>>{};

    replies.listen((Object? message) {
      switch (message) {
        // The worker isolate is gone (normal exit or a crash after onError).
        case null:
          if (!exited.isCompleted) exited.complete();
          final failed = List<Completer<Object?>>.of(pending.values);
          pending.clear();
          for (final c in failed) {
            c.completeError(const ScoreStoreException('db isolate exited'));
          }
          if (!bootstrap.isCompleted) {
            bootstrap.completeError(
              const ScoreStoreException('db isolate exited before opening'),
            );
          }
          replies.close();
        // An uncaught error in the worker: [error, stackTrace].
        case final List<Object?> error:
          final failure = ScoreStoreException('db isolate failed: ${error[0]}');
          final failed = List<Completer<Object?>>.of(pending.values);
          pending.clear();
          for (final c in failed) {
            c.completeError(failure);
          }
          if (!bootstrap.isCompleted) bootstrap.completeError(failure);
        case final _DbReply reply:
          final waiter = reply.id == _bootstrapId
              ? bootstrap
              : pending.remove(reply.id);
          if (waiter == null || waiter.isCompleted) return;
          final error = reply.error;
          if (error == null) {
            waiter.complete(reply.value);
          } else {
            waiter.completeError(ScoreStoreException(error));
          }
        default:
          return;
      }
    });

    final isolate = await Isolate.spawn(
      _dbWorker,
      <Object?>[replies.sendPort, path, busyTimeout.inMilliseconds],
      onError: replies.sendPort,
      onExit: replies.sendPort,
      debugName: 'arco_db',
    );
    final SendPort commands;
    try {
      commands = await bootstrap.future as SendPort;
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      replies.close();
      rethrow;
    }
    return ScoreStore._(isolate, commands, replies, exited, pending);
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;

  /// Completed once the worker isolate is gone, so that calls made afterwards
  /// fail fast instead of waiting for an answer that can never arrive.
  final Completer<void> _exited;

  /// Calls waiting for an answer, by request id.
  final Map<int, Completer<Object?>> _pending;
  int _nextId = 0;
  bool _closed = false;

  /// Request id reserved for the "database is open" handshake.
  static const int _bootstrapId = -1;

  bool get isClosed => _closed;

  /// Number of calls waiting for the db isolate (diagnostics / tests).
  int get inFlight => _pending.length;

  Future<Object?> _send(_DbRequest request) {
    if (_closed) {
      return Future<Object?>.error(const ScoreStoreException('store closed'));
    }
    if (_exited.isCompleted) {
      return Future<Object?>.error(
        const ScoreStoreException('db isolate is gone'),
      );
    }
    final completer = Completer<Object?>();
    _pending[request.id] = completer;
    _commands.send(request);
    return completer.future;
  }

  /// Stores one score row.
  Future<void> insert(ScoreRow row) async {
    await _send(_DbRequest(_nextId++, _Op.insert, row: row));
  }

  /// Top scores of [period], ordered by score desc then createdAt asc, and
  /// restricted to [country] when one is given (SPEC §4.6).
  Future<List<ScoreRow>> topScores({
    LeaderboardPeriod period = LeaderboardPeriod.all,
    int limit = 100,
    DateTime? now,
    String? country,
  }) async {
    final rows = await _send(
      _DbRequest(
        _nextId++,
        _Op.top,
        period: period,
        limit: limit,
        now: now,
        country: country,
      ),
    );
    return (rows as List<Object?>).cast<ScoreRow>();
  }

  /// `1 + number of scores > [score]` within [period], and within [country]
  /// when one is given (SPEC §4.6).
  Future<int> rank(
    int score, {
    LeaderboardPeriod period = LeaderboardPeriod.all,
    DateTime? now,
    String? country,
  }) async {
    final value = await _send(
      _DbRequest(
        _nextId++,
        _Op.rank,
        score: score,
        period: period,
        now: now,
        country: country,
      ),
    );
    return value as int;
  }

  /// Total number of stored scores.
  Future<int> count() async =>
      await _send(_DbRequest(_nextId++, _Op.count)) as int;

  /// Stores one player together with its first credential (SPEC §4.4).
  Future<void> createPlayer(
    PlayerRow player, {
    required String credentialId,
    required String secretHash,
  }) async {
    await _send(
      _DbRequest(
        _nextId++,
        _Op.createPlayer,
        player: player,
        credentialId: credentialId,
        secretHash: secretHash,
      ),
    );
  }

  /// The player with [id], or null when there is none.
  Future<PlayerRow?> playerById(String id) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.playerById, playerId: id),
    );
    return value as PlayerRow?;
  }

  /// The player holding the provider account ([provider], [subject]), or null
  /// (SPEC §4.5).
  Future<PlayerRow?> playerByAccount(String provider, String subject) async {
    final value = await _send(
      _DbRequest(
        _nextId++,
        _Op.playerByAccount,
        provider: provider,
        subject: subject,
      ),
    );
    return value as PlayerRow?;
  }

  /// [id]'s row plus every credential digest it may authenticate with, in one
  /// hop, or null when there is no such player.
  Future<StoredPlayer?> playerWithSecrets(String id) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.playerWithSecrets, playerId: id),
    );
    return value as StoredPlayer?;
  }

  /// [id] itself, or the player that absorbed it in a merge (SPEC §4.5).
  Future<String> canonicalPlayerId(String id) async =>
      await _send(_DbRequest(_nextId++, _Op.canonicalPlayerId, playerId: id))
          as String;

  /// Adds one credential to [playerId] without revoking the others.
  Future<void> addPlayerSecret({
    required String playerId,
    required String credentialId,
    required String secretHash,
    required DateTime now,
  }) async {
    await _send(
      _DbRequest(
        _nextId++,
        _Op.addPlayerSecret,
        playerId: playerId,
        credentialId: credentialId,
        secretHash: secretHash,
        now: now,
      ),
    );
  }

  /// Credentials [playerId] currently holds (diagnostics / tests).
  Future<int> secretCount(String playerId) async =>
      await _send(_DbRequest(_nextId++, _Op.secretCount, playerId: playerId))
          as int;

  /// Moves the player's `last_seen_at` forward to [now], coalesced by
  /// [Db.lastSeenResolution]; returns whether it wrote.
  Future<bool> touchPlayer(String id, DateTime now) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.touchPlayer, playerId: id, now: now),
    );
    return value as bool;
  }

  /// Records a submission by [id] under [name] (display name + activity).
  Future<void> notePlayerScore(String id, String name, DateTime now) async {
    await _send(
      _DbRequest(
        _nextId++,
        _Op.notePlayerScore,
        playerId: id,
        name: name,
        now: now,
      ),
    );
  }

  /// Games submitted, best score and global rank for [id].
  Future<PlayerStats> playerScores(String id) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.playerScores, playerId: id),
    );
    return value as PlayerStats;
  }

  /// Total number of issued players.
  Future<int> playerCount() async =>
      await _send(_DbRequest(_nextId++, _Op.playerCount)) as int;

  /// Links, restores or merges a verified provider account, atomically
  /// (SPEC §4.5). See [Db.linkAccount].
  Future<AccountLinkResult> linkAccount(AccountLinkRequest request) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.linkAccount, link: request),
    );
    return value as AccountLinkResult;
  }

  /// Detaches the provider account from [playerId]; returns whether one was
  /// attached.
  Future<bool> unlinkAccount(String playerId) async =>
      await _send(_DbRequest(_nextId++, _Op.unlinkAccount, playerId: playerId))
          as bool;

  /// Deletes [playerId], anonymising the scores it owned; returns how many
  /// score rows were anonymised (SPEC §4.5).
  Future<int> deletePlayer(String playerId) async =>
      await _send(_DbRequest(_nextId++, _Op.deletePlayer, playerId: playerId))
          as int;

  /// Identity-token uses still on record (diagnostics / tests).
  Future<int> tokenUseCount() async =>
      await _send(_DbRequest(_nextId++, _Op.tokenUseCount)) as int;

  /// Balance, bought items, slot choices and today's earnings for [playerId]
  /// (SPEC §4.8), in one hop. [now] fixes the UTC day the daily cap counts over.
  Future<PlayerInventory> inventory(String playerId, {DateTime? now}) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.inventory, playerId: playerId, now: now),
    );
    return value as PlayerInventory;
  }

  /// Whether [playerId] may use [itemId] — free items and premium included
  /// (SPEC §4.8, §4.9).
  Future<bool> ownsItem(String playerId, String itemId) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.ownsItem, playerId: playerId, itemId: itemId),
    );
    return value as bool;
  }

  /// Whether [playerId] holds the one-time unlock (SPEC §4.9): every cosmetic
  /// there is, and no ads. See [Db.isPremium].
  Future<bool> isPremium(String playerId) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.isPremium, playerId: playerId),
    );
    return value as bool;
  }

  /// Buys [itemId] for [playerId] atomically; the price comes from the server's
  /// catalogue, never from a request (SPEC §4.8). See [Db.buyItem].
  Future<BuyOutcome> buyItem({
    required String playerId,
    required String itemId,
    DateTime? now,
  }) async {
    final value = await _send(
      _DbRequest(
        _nextId++,
        _Op.buyItem,
        playerId: playerId,
        itemId: itemId,
        now: now,
      ),
    );
    return value as BuyOutcome;
  }

  /// Stores the player's slot choices, refusing anything unowned (SPEC §4.8).
  Future<EquipOutcome> equipItems(EquipRequest request) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.equipItems, equip: request),
    );
    return value as EquipOutcome;
  }

  /// Credits [playerId] for a run **the server verified** at [score]
  /// (SPEC §4.8). There is no parameter for a token amount; see [Db.awardTokens].
  Future<TokenAward> awardTokens({
    required String playerId,
    required String scoreId,
    required int score,
    required String replayKey,
    DateTime? now,
  }) async {
    final value = await _send(
      _DbRequest(
        _nextId++,
        _Op.awardTokens,
        playerId: playerId,
        scoreId: scoreId,
        score: score,
        replayKey: replayKey,
        now: now,
      ),
    );
    return value as TokenAward;
  }

  /// Records a store payment RevenueCat confirmed and grants premium with it
  /// (SPEC §4.9), idempotently on the store transaction id. What the purchase
  /// grants is decided server side; see [Db.grantPurchase].
  Future<PurchaseGrant> grantPurchase(PurchaseGrantRequest request) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.grantPurchase, purchase: request),
    );
    return value as PurchaseGrant;
  }

  /// Revokes a refunded or charged-back purchase (SPEC §4.9). See
  /// [Db.revokePurchase] for why a cosmetic the player also bought with Sparks
  /// survives it.
  Future<PurchaseRevoke> revokePurchase({
    required String transactionId,
    DateTime? now,
  }) async {
    final value = await _send(
      _DbRequest(
        _nextId++,
        _Op.revokePurchase,
        transactionId: transactionId,
        now: now,
      ),
    );
    return value as PurchaseRevoke;
  }

  /// [playerId]'s purchases, newest first (SPEC §4.9).
  Future<List<PurchaseRecord>> purchasesOf(
    String playerId, {
    int limit = 50,
  }) async {
    final rows = await _send(
      _DbRequest(_nextId++, _Op.purchasesOf, playerId: playerId, limit: limit),
    );
    return (rows as List<Object?>).cast<PurchaseRecord>();
  }

  /// The ledger row for one store transaction, or null (support / tests).
  Future<PurchaseRecord?> purchaseByTransaction(String transactionId) async {
    final value = await _send(
      _DbRequest(
        _nextId++,
        _Op.purchaseByTransaction,
        transactionId: transactionId,
      ),
    );
    return value as PurchaseRecord?;
  }

  /// Rows in `spark_purchases` (diagnostics / tests).
  Future<int> purchaseCount() async =>
      await _send(_DbRequest(_nextId++, _Op.purchaseCount)) as int;

  // ------------------------------------------- rewarded ads (SPEC §4.10)

  /// Credits a rewarded ad AdMob's signed callback confirmed (SPEC §4.10),
  /// idempotently on AdMob's transaction id. The Sparks, the daily cap and the
  /// cooldown are all applied server side; see [Db.creditAdReward].
  Future<AdCredit> creditAdReward(AdCreditRequest request) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.creditAdReward, adReward: request),
    );
    return value as AdCredit;
  }

  /// [playerId]'s ad allowance right now (SPEC §4.10).
  Future<AdRewardState> adRewardState(String playerId, {DateTime? now}) async {
    final value = await _send(
      _DbRequest(
        _nextId++,
        _Op.adRewardState,
        playerId: playerId,
        now: now ?? DateTime.now(),
      ),
    );
    return value as AdRewardState;
  }

  /// [playerId]'s ad rewards, newest first (SPEC §4.10).
  Future<List<AdRewardRow>> adRewards(String playerId, {int limit = 50}) async {
    final rows = await _send(
      _DbRequest(_nextId++, _Op.adRewards, playerId: playerId, limit: limit),
    );
    return (rows as List<Object?>).cast<AdRewardRow>();
  }

  /// The ledger row for one AdMob transaction, or null (support / tests).
  Future<AdRewardRow?> adReward(String transactionId) async {
    final value = await _send(
      _DbRequest(_nextId++, _Op.adReward, transactionId: transactionId),
    );
    return value as AdRewardRow?;
  }

  /// Rows in `ad_rewards` (diagnostics / tests).
  Future<int> adRewardCount() async =>
      await _send(_DbRequest(_nextId++, _Op.adRewardCount)) as int;

  /// [playerId]'s spendable balance (diagnostics / tests).
  Future<int> walletBalance(String playerId) async =>
      await _send(_DbRequest(_nextId++, _Op.walletBalance, playerId: playerId))
          as int;

  /// Closes the database and shuts the worker isolate down. In-flight calls are
  /// answered first; a worker stuck inside SQLite is killed after [timeout].
  Future<void> close({Duration timeout = const Duration(seconds: 3)}) async {
    if (_closed) return;
    final request = _DbRequest(_nextId++, _Op.close);
    final done = _send(request);
    _closed = true;
    try {
      await done.timeout(timeout);
      await _exited.future.timeout(timeout);
    } on TimeoutException {
      // A blocked SQLite call cannot be interrupted; drop the isolate.
    } catch (_) {
      // The worker died on its own; nothing left to close.
    }
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _replies.close();
    final abandoned = List<Completer<Object?>>.of(_pending.values);
    _pending.clear();
    for (final c in abandoned) {
      if (!c.isCompleted) {
        c.completeError(const ScoreStoreException('store closed'));
      }
    }
  }
}

/// Entry point of the db isolate: opens the database, then answers requests
/// until it receives [_Op.close].
Future<void> _dbWorker(List<Object?> init) async {
  final replies = init[0] as SendPort;
  final path = init[1] as String;
  final busyTimeoutMs = init[2] as int;

  final Db db;
  try {
    db = Db.open(path, busyTimeout: Duration(milliseconds: busyTimeoutMs));
  } catch (e) {
    replies.send(_DbReply(ScoreStore._bootstrapId, null, '$e'));
    return;
  }
  final commands = ReceivePort();
  replies.send(_DbReply(ScoreStore._bootstrapId, commands.sendPort, null));

  await for (final message in commands) {
    if (message is! _DbRequest) continue;
    if (message.op == _Op.close) {
      db.close();
      commands.close();
      replies.send(_DbReply(message.id, null, null));
      return;
    }
    try {
      replies.send(_DbReply(message.id, _execute(db, message), null));
    } catch (e) {
      replies.send(_DbReply(message.id, null, '$e'));
    }
  }
  db.close();
}

Object? _execute(Db db, _DbRequest request) {
  switch (request.op) {
    case _Op.insert:
      db.insertScore(request.row!);
      return null;
    case _Op.top:
      return db.topScores(
        period: request.period,
        limit: request.limit,
        now: request.now,
        country: request.country,
      );
    case _Op.rank:
      return db.rank(
        request.score,
        period: request.period,
        now: request.now,
        country: request.country,
      );
    case _Op.count:
      return db.count;
    case _Op.createPlayer:
      db.createPlayer(
        request.player!,
        credentialId: request.credentialId!,
        secretHash: request.secretHash!,
      );
      return null;
    case _Op.playerByAccount:
      return db.playerByAccount(request.provider!, request.subject!);
    case _Op.playerWithSecrets:
      return db.playerWithSecrets(request.playerId!);
    case _Op.canonicalPlayerId:
      return db.canonicalPlayerId(request.playerId!);
    case _Op.addPlayerSecret:
      db.addPlayerSecret(
        playerId: request.playerId!,
        credentialId: request.credentialId!,
        secretHash: request.secretHash!,
        now: request.now!,
      );
      return null;
    case _Op.secretCount:
      return db.secretCount(request.playerId!);
    case _Op.linkAccount:
      return db.linkAccount(request.link!);
    case _Op.unlinkAccount:
      return db.unlinkAccount(request.playerId!);
    case _Op.deletePlayer:
      return db.deletePlayer(request.playerId!);
    case _Op.tokenUseCount:
      return db.tokenUseCount;
    case _Op.inventory:
      return db.inventoryOf(
        request.playerId!,
        now: request.now ?? DateTime.now(),
      );
    case _Op.ownsItem:
      return db.ownsItem(request.playerId!, request.itemId!);
    case _Op.isPremium:
      return db.isPremium(request.playerId!);
    case _Op.buyItem:
      return db.buyItem(
        playerId: request.playerId!,
        itemId: request.itemId!,
        now: request.now ?? DateTime.now(),
      );
    case _Op.equipItems:
      return db.equipItems(request.equip!);
    case _Op.awardTokens:
      return db.awardTokens(
        playerId: request.playerId!,
        scoreId: request.scoreId!,
        score: request.score,
        replayKey: request.replayKey!,
        now: request.now ?? DateTime.now(),
      );
    case _Op.walletBalance:
      return db.walletBalance(request.playerId!);
    case _Op.grantPurchase:
      return db.grantPurchase(request.purchase!);
    case _Op.revokePurchase:
      return db.revokePurchase(
        transactionId: request.transactionId!,
        now: request.now ?? DateTime.now(),
      );
    case _Op.purchasesOf:
      return db.purchasesOf(request.playerId!, limit: request.limit);
    case _Op.purchaseByTransaction:
      return db.purchaseByTransaction(request.transactionId!);
    case _Op.purchaseCount:
      return db.purchaseCount;
    case _Op.creditAdReward:
      return db.creditAdReward(request.adReward!);
    case _Op.adRewardState:
      return db.adRewardState(
        request.playerId!,
        now: request.now ?? DateTime.now(),
      );
    case _Op.adRewards:
      return db.adRewards(request.playerId!, limit: request.limit);
    case _Op.adReward:
      return db.adReward(request.transactionId!);
    case _Op.adRewardCount:
      return db.adRewardCount;
    case _Op.playerById:
      return db.playerById(request.playerId!);
    case _Op.touchPlayer:
      return db.touchPlayer(request.playerId!, request.now!);
    case _Op.notePlayerScore:
      db.notePlayerScore(request.playerId!, request.name!, request.now!);
      return null;
    case _Op.playerScores:
      return db.playerScores(request.playerId!);
    case _Op.playerCount:
      return db.playerCount;
    case _Op.close:
      return null;
  }
}
