/// SQLite storage for the leaderboard (SPEC §4.3).
///
/// Every call here is a synchronous `sqlite3` C call, so it must not run on
/// the isolate that serves requests and drives the room tick: reach it through
/// [ScoreStore] (`score_store.dart`) instead.
///
/// Schema (SPEC §4.3): `scores(id TEXT PK, name TEXT, score INT, ticks INT,
/// seed INT, created_at TEXT ISO-8601 UTC, ip_hash TEXT, hash INT,
/// player_id TEXT NULL, country TEXT NULL, balls INT NOT NULL DEFAULT 1)` with
/// indexes on `(score DESC, created_at)`, `(player_id, score DESC, created_at)`,
/// `(country, score DESC, created_at)`, `(balls, score DESC, created_at)` and
/// `(balls, country, score DESC, created_at)`, plus `players` and `player_secrets`
/// (SPEC §4.4), `id_token_uses` (SPEC §4.5) and the cosmetic tables
/// `player_wallets`, `player_items`, `player_equipped` and `token_awards`
/// (SPEC §4.8), `purchases` (SPEC §4.9) and `ad_rewards` (SPEC §4.10).
///
/// The schema is versioned through SQLite's `user_version` and upgraded in
/// place by [Db.migrate]: a file written by an older build keeps every row and
/// gains the new tables and columns on open.
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'catalogue.dart';
import 'tokens.dart';

enum LeaderboardPeriod {
  all,
  week,
  day;

  /// Parses the `period` query parameter; null/empty → [all], unknown → null.
  static LeaderboardPeriod? parse(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case null:
      case '':
      case 'all':
        return LeaderboardPeriod.all;
      case 'week':
        return LeaderboardPeriod.week;
      case 'day':
        return LeaderboardPeriod.day;
      default:
        return null;
    }
  }

  /// Rolling window length; null = unbounded.
  Duration? get window {
    switch (this) {
      case LeaderboardPeriod.all:
        return null;
      case LeaderboardPeriod.week:
        return const Duration(days: 7);
      case LeaderboardPeriod.day:
        return const Duration(days: 1);
    }
  }
}

class ScoreRow {
  const ScoreRow({
    required this.id,
    required this.name,
    required this.score,
    required this.ticks,
    required this.seed,
    required this.createdAt,
    required this.ipHash,
    required this.hash,
    this.playerId,
    this.country,
    this.balls = 1,
  });

  final String id;
  final String name;
  final int score;
  final int ticks;
  final int seed;

  /// ISO-8601 UTC timestamp, e.g. `2026-09-22T12:00:00Z`.
  final String createdAt;
  final String ipHash;
  final int hash;

  /// Owning player (SPEC §4.4), or null for an anonymous run — which is what
  /// every row stored before player identity existed looks like, and what a
  /// row becomes again when its owner deletes their account (SPEC §4.5).
  final String? playerId;

  /// ISO 3166-1 alpha-2 code the run counts for on the national board
  /// (SPEC §4.6), or null when the submission carried none — or carried
  /// something that was not a country code, which is dropped rather than
  /// refused. Every row stored before national ranking existed is null.
  final String? country;

  /// Balls the run was played with — the board it belongs to (SPEC §4.3,
  /// §4.6). Two balls score at a different rate, so one board holding both
  /// would make the one-ball board meaningless; every query therefore names a
  /// ball count.
  ///
  /// Unlike [country], this is never unknown. A row stored before ball counts
  /// existed was played with one ball, because that was the only game there
  /// was — so the column is `NOT NULL DEFAULT 1` and every legacy row reads 1,
  /// which is the truth about it rather than a backfill.
  ///
  /// The default here, and on every query below, is written as a literal `1`
  /// rather than `minBallCount`: this layer is storage and stays free of the
  /// simulation package, and the SQL default it has to agree with is a literal
  /// too. The range is enforced where a ball count enters the server — by
  /// `GameConfig` when a replay is decoded, and by `parseBallCount` on a query.
  final int balls;
}

/// One row of `players` (SPEC §4.4).
///
/// Credentials are **not** here: a player may hold several (one per device, see
/// `player_secrets` and [Db.playerWithSecrets]), and none of them ever leaves
/// storage in any form but a salted digest — see `players.dart`.
class PlayerRow {
  const PlayerRow({
    required this.id,
    required this.createdAt,
    required this.lastSeenAt,
    this.name,
    this.accountProvider,
    this.accountSubject,
    this.accountLinkedAt,
  });

  final String id;

  /// ISO-8601 UTC timestamps, as [Db.formatTimestamp] writes them.
  final String createdAt;
  final String lastSeenAt;

  /// Display name: the last name the player submitted a score under, or the
  /// one passed when the player was issued. Null until either happens.
  final String? name;

  /// The linked provider account (SPEC §4.5): the provider name (`apple`,
  /// `google`) and that provider's opaque subject id for this app, plus when
  /// the link was made. All null for an anonymous player, which is every
  /// player until someone signs in.
  ///
  /// There is deliberately no column for an address or a real name: the
  /// verified identity token carries `email` and often a name, and both are
  /// dropped before they reach storage (SPEC §4.5).
  final String? accountProvider;
  final String? accountSubject;
  final String? accountLinkedAt;

  bool get hasAccount => accountSubject != null;
}

/// A player together with the digests of every credential it may authenticate
/// with (SPEC §4.4).
///
/// A player holds one credential per device: signing in on a second phone adds
/// one rather than replacing the first, which is the only way both devices can
/// keep playing as the same person (SPEC §4.5).
class StoredPlayer {
  const StoredPlayer({required this.player, required this.secretHashes});

  final PlayerRow player;

  /// Salted digests, newest first. Never a secret, never part of a response.
  final List<String> secretHashes;
}

/// What `GET /api/players/me` reports about one player's runs (SPEC §4.4).
///
/// [bestScore] and [rank] are null exactly when [games] is 0: a player who has
/// submitted nothing has no rank rather than the worst one.
class PlayerStats {
  const PlayerStats({
    required this.games,
    this.balls = 1,
    this.bestScore,
    this.rank,
    this.country,
    this.countryBestScore,
    this.countryRank,
  });

  /// Number of stored scores owned by the player **on this board**.
  final int games;

  /// The board these numbers are about: the ball count the runs were played
  /// with (SPEC §4.3, §4.6). Every rank is a position on one board, because a
  /// rank across both would be a position in a race nobody ran.
  final int balls;
  final int? bestScore;
  final int? rank;

  /// The player's country (SPEC §4.6): the code of the most recent run that
  /// carried one, which is the same rule the display name follows (SPEC §4.4).
  /// Null until the player submits a run with a valid country.
  final String? country;

  /// Best score and rank **within [country]**, null together with it.
  ///
  /// [countryBestScore] is the player's best run *that counts for that country*,
  /// not [bestScore]: someone who played in one country and then moved would
  /// otherwise be given a national rank their rows do not support, and the
  /// number next to their name would not match the board they are on.
  final int? countryBestScore;
  final int? countryRank;
}

/// What [Db.linkAccount] did, for the log and the response (SPEC §4.5).
enum AccountLinkKind {
  /// Nobody was authenticated and the provider account was unknown here: a
  /// fresh player was created for it. The first sign-in from a new install
  /// that never issued an anonymous player.
  created,

  /// The authenticated anonymous player gained the account.
  linked,

  /// The account already existed and was handed back with a new credential:
  /// signing in on a second device, or re-signing-in on the same one.
  restored,

  /// The authenticated player and the account's player were two different
  /// rows; they are now one (SPEC §4.5).
  merged,

  /// This exact token had been presented before, and the outcome recorded then
  /// was replayed instead of being recomputed.
  retried,
}

/// Everything [Db.linkAccount] needs, as one sendable value.
///
/// The credential and the new player id are generated by the caller rather than
/// inside the transaction, so the db isolate needs no cryptographic randomness
/// and the operation stays a pure function of its inputs.
class AccountLinkRequest {
  const AccountLinkRequest({
    required this.provider,
    required this.subject,
    required this.callerPlayerId,
    required this.tokenHash,
    required this.tokenExpiresAt,
    required this.newPlayerId,
    required this.credentialId,
    required this.secretHash,
    required this.now,
  });

  final String provider;

  /// The provider's opaque subject id. The only claim from the token that is
  /// ever stored (SPEC §4.5).
  final String subject;

  /// The already-authenticated anonymous player, or null when the caller sent
  /// no credentials — which is how an account is restored onto a new device.
  final String? callerPlayerId;

  /// SHA-256 of the raw token, and the token's own `exp`: together the replay
  /// ledger entry. The token itself is never stored.
  final String tokenHash;
  final DateTime tokenExpiresAt;

  /// Used only when the account turns out to be unknown and there is no caller
  /// to attach it to.
  final String newPlayerId;

  final String credentialId;
  final String secretHash;
  final DateTime now;
}

/// Outcome of [Db.linkAccount].
///
/// Failures are returned rather than thrown: `already_linked` is an ordinary
/// answer the HTTP layer turns into a `409`, not a storage fault.
class AccountLinkResult {
  const AccountLinkResult._({
    this.kind,
    this.playerId,
    this.name,
    this.createdAt,
    this.linkedAt,
    this.movedScores = 0,
    this.error,
    this.conflictProvider,
  });

  const AccountLinkResult.done({
    required AccountLinkKind kind,
    required String playerId,
    required String createdAt,
    required String linkedAt,
    String? name,
    int movedScores = 0,
  }) : this._(
         kind: kind,
         playerId: playerId,
         createdAt: createdAt,
         linkedAt: linkedAt,
         name: name,
         movedScores: movedScores,
       );

  /// The authenticated player already carries a *different* provider account,
  /// so attaching this one would silently detach that one.
  const AccountLinkResult.alreadyLinked(String provider)
    : this._(error: alreadyLinkedError, conflictProvider: provider);

  static const String alreadyLinkedError = 'already_linked';

  final AccountLinkKind? kind;
  final String? playerId;
  final String? name;
  final String? createdAt;
  final String? linkedAt;

  /// Score rows moved from the absorbed player in a merge; 0 otherwise.
  final int movedScores;

  final String? error;

  /// On [alreadyLinkedError]: the provider the caller is already linked with,
  /// so the client can say which sign-in to use.
  final String? conflictProvider;

  bool get ok => error == null;
}

/// What one player owns and holds (SPEC §4.8), in one hop to the db isolate.
///
/// [ownedItemIds] lists only the rows in `player_items`, i.e. the items that
/// were **bought with Sparks**. Free items are owned implicitly and are
/// deliberately not written to every player's row: an entitlement that is true
/// for everybody is not a fact worth storing a million times, and a new free
/// item would otherwise need a backfill. [premium] is the same argument taken all
/// the way — it is true for everything at once, so it too is a fact answered
/// rather than a set of rows. The service layer adds both back when it answers.
class PlayerInventory {
  const PlayerInventory({
    required this.balance,
    required this.earnedTotal,
    required this.spentTotal,
    required this.ownedItemIds,
    required this.equipped,
    required this.earnedToday,
    this.premium = false,
    this.purchasedTotal = 0,
    this.adTotal = 0,
  });

  /// Tokens the player can spend. Never negative (a CHECK constraint and the
  /// conditional debit of [Db.buyItem] both see to that).
  final int balance;

  /// Lifetime totals, for the shop to show and for support questions.
  final int earnedTotal;
  final int spentTotal;

  /// Items bought with Sparks, ascending by id. Free items are not here (they
  /// are owned by everybody) and neither is anything [premium] covers.
  final List<String> ownedItemIds;

  /// Stored slot choices: [CosmeticKind] name → item id. A kind the player
  /// never chose is absent rather than defaulted here, so the default lives in
  /// one place ([Catalogue.defaultFor]).
  final Map<String, String> equipped;

  /// Tokens already earned from play in the current UTC day, for the daily cap
  /// ([TokenRate.dailyCap]) and for the client to show what is left.
  final int earnedToday;

  /// Whether the player holds the one-time unlock (SPEC §4.9): **every** cosmetic
  /// in the catalogue, including every one added to it later, and no ads offered.
  ///
  /// Answered from the purchase ledger by [Db.isPremium], never from a set of
  /// `player_items` rows. That is the whole reason a new cosmetic needs no
  /// backfill and a refund needs no sweep: there is nothing to write when the
  /// entitlement is granted and nothing to unpick when it is taken back — and
  /// the items this player bought with Sparks are untouched either way, because
  /// those are rows and this is not.
  final bool premium;

  /// Sparks ever bought with money, net of refunds that were recovered.
  ///
  /// Money no longer buys Sparks — it buys the one-time unlock, which credits
  /// none (SPEC §4.9) — so this is 0 for every wallet written from now on. It is
  /// still reported, and the column still exists, because a wallet that *did*
  /// buy Sparks before that change would otherwise have Sparks in it that the
  /// server could no longer explain.
  final int purchasedTotal;

  /// Sparks ever earned from watching rewarded ads (SPEC §4.10). Kept apart from
  /// both [earnedTotal] and [purchasedTotal], because the ad allowance is its own
  /// daily cap ([AdRate.dailyCap]) and it must not consume the play one.
  ///
  /// The identity this completes:
  /// `balance == earnedTotal + purchasedTotal + adTotal - spentTotal`, with a
  /// non-duplicable ledger row behind each of the three positive terms.
  final int adTotal;
}

/// Outcome of [Db.buyItem].
///
/// Refusals are ordinary answers rather than exceptions: "you cannot afford it"
/// is a fact about the wallet, not a storage fault.
class BuyOutcome {
  const BuyOutcome._({
    this.error,
    this.itemId = '',
    this.price = 0,
    this.charged = 0,
    this.alreadyOwned = false,
    this.balance = 0,
    this.ownedItemIds = const <String>[],
    this.premium = false,
  });

  const BuyOutcome.done({
    required String itemId,
    required int price,
    required int charged,
    required bool alreadyOwned,
    required int balance,
    required List<String> ownedItemIds,
    required bool premium,
  }) : this._(
         itemId: itemId,
         price: price,
         charged: charged,
         alreadyOwned: alreadyOwned,
         balance: balance,
         ownedItemIds: ownedItemIds,
         premium: premium,
       );

  const BuyOutcome.insufficient({
    required String itemId,
    required int price,
    required int balance,
  }) : this._(
         error: insufficientTokensError,
         itemId: itemId,
         price: price,
         balance: balance,
       );

  const BuyOutcome.unknownItem(String itemId)
    : this._(error: unknownItemError, itemId: itemId);

  /// The wallet holds less than the price. Answered with the price and the
  /// balance, because both are the server's own numbers and the client needs
  /// them to say "you need 40 more".
  static const String insufficientTokensError = 'insufficient_tokens';

  /// No item of this build has that id.
  static const String unknownItemError = 'unknown_item';

  final String? error;
  final String itemId;

  /// Catalogue price, from the server's table — never from the request.
  final int price;

  /// What was actually taken from the wallet: 0 on a repeat purchase.
  final int charged;

  /// The item was already owned (or is free, or the player is [premium]). The
  /// call is then a no-op that reports success, which is what makes a retried buy
  /// safe — and what makes a premium player tapping an old client's buy button
  /// harmless rather than a `402`.
  final bool alreadyOwned;

  final int balance;
  final List<String> ownedItemIds;

  /// Whether the player holds the one-time unlock (SPEC §4.9), so the service
  /// layer can report everything as owned without asking again.
  final bool premium;

  bool get ok => error == null;
}

/// One `POST /api/shop/equip` call: the slots it names, by [CosmeticKind] name.
///
/// A null value means "back to the free default", which is why the map is
/// `String?`-valued: an absent key leaves that slot alone, a null one clears it.
class EquipRequest {
  const EquipRequest({
    required this.playerId,
    required this.slots,
    required this.now,
  });

  final String playerId;
  final Map<String, String?> slots;
  final DateTime now;
}

/// Outcome of [Db.equipItems].
class EquipOutcome {
  const EquipOutcome._({
    this.error,
    this.itemId,
    this.equipped = const <String, String>{},
    this.ownedItemIds = const <String>[],
    this.premium = false,
  });

  const EquipOutcome.done({
    required Map<String, String> equipped,
    required List<String> ownedItemIds,
    required bool premium,
  }) : this._(equipped: equipped, ownedItemIds: ownedItemIds, premium: premium);

  const EquipOutcome.notOwned(String itemId)
    : this._(error: notOwnedError, itemId: itemId);

  const EquipOutcome.unknownItem(String itemId)
    : this._(error: unknownItemError, itemId: itemId);

  const EquipOutcome.unknownKind(String kind)
    : this._(error: unknownKindError, itemId: kind);

  const EquipOutcome.wrongKind(String itemId)
    : this._(error: wrongKindError, itemId: itemId);

  /// The player does not own the item they asked to wear. Equipping is a
  /// preference, not an entitlement: it may only name what is already owned.
  static const String notOwnedError = 'item_not_owned';
  static const String unknownItemError = 'unknown_item';

  /// The body named a slot this build has no kind for — a newer client talking
  /// to an older server.
  static const String unknownKindError = 'unknown_kind';

  /// A real item, in the wrong slot (`{"ball":"paddle.halo"}`).
  static const String wrongKindError = 'wrong_kind';

  final String? error;

  /// The item (or kind name) the refusal is about.
  final String? itemId;

  /// Stored slot choices after the call; empty on a refusal.
  final Map<String, String> equipped;

  /// What the player owns afterwards, so the service layer can answer a slot the
  /// player has stored but no longer owns with that kind's default instead of
  /// with an item they cannot use. That case is real: premium can be revoked
  /// while a cosmetic it covered is still equipped (SPEC §4.9).
  final List<String> ownedItemIds;
  final bool premium;

  bool get ok => error == null;
}

/// Outcome of [Db.awardTokens] (SPEC §4.8).
class TokenAward {
  const TokenAward({
    required this.tokens,
    required this.balance,
    required this.earnedToday,
    this.duplicate = false,
    this.cappedByDay = false,
  });

  /// Tokens this run is worth: what was credited now, or what it was credited
  /// the first time it was submitted (see [duplicate]).
  final int tokens;

  /// Balance after the award.
  final int balance;

  /// Tokens earned in the current UTC day after the award.
  final int earnedToday;

  /// This exact run had already been recorded, so nothing was credited. A retry
  /// by the same player reports the original award; anyone else's copy of the
  /// replay reports 0.
  final bool duplicate;

  /// The daily cap ([TokenRate.dailyCap]) clipped what the run would otherwise
  /// have paid.
  final bool cappedByDay;
}

/// One row of the purchase ledger (SPEC §4.9): a payment a store confirmed, what
/// it bought, and whether a refund has since taken it back.
///
/// The ledger exists so that **an entitlement can always be explained**. A player
/// is premium because of a row here — one row, naming the store transaction that
/// paid for it — and stops being premium because that row carries a
/// [refundedAt]. "Why does this person have everything", "I was charged twice"
/// and "I refunded and it is still unlocked" are then queries rather than
/// guesses. Alongside `token_awards` and `ad_rewards`, which explain the Spark
/// balance, this is the third thing a support question can be answered from.
///
/// Nothing here is an amount. The unlock credits no Sparks, so what the row
/// records is *that* a product was bought and by whom, which is exactly what
/// deciding premium needs. (The table itself still carries the `sparks` and
/// `clawed_back` columns of the Spark packs this build no longer sells, so that a
/// database written before the change keeps every number that explains its
/// wallets; nothing reads them to decide anything.)
class PurchaseRecord {
  const PurchaseRecord({
    required this.transactionId,
    required this.playerId,
    required this.productId,
    required this.store,
    required this.environment,
    required this.source,
    required this.purchasedAt,
    required this.creditedAt,
    this.eventId,
    this.refundedAt,
  });

  /// The **store's** transaction id (Apple's `transaction_id`, Google's
  /// `orderId`), as RevenueCat reports it. It is the primary key, and it is the
  /// whole of idempotency: webhooks are retried, the client asks about the same
  /// purchase again on every restore, and both can be in flight at once.
  final String transactionId;

  final String playerId;

  /// The store product identifier. [FullUnlock.productId] for a row that grants
  /// premium; anything else is a product this build no longer sells, kept for the
  /// record and granting nothing.
  final String productId;

  /// `app_store`, `play_store`, … as RevenueCat named it.
  final String store;

  /// `PRODUCTION` or `SANDBOX`. Recorded even when a sandbox purchase is granted
  /// (a staging deployment), so a row always says which money it was.
  final String environment;

  /// `webhook` or `sync` — which path wrote it. Worth keeping: a deployment whose
  /// ledger is all `sync` has a broken webhook, and that is a thing to notice
  /// before a refund arrives with nowhere to land.
  final String source;

  /// When the store took the money, and when we recorded it.
  final String purchasedAt;
  final String creditedAt;

  /// RevenueCat's own event id, when a webhook carried one.
  final String? eventId;

  /// When a refund or chargeback revoked this purchase; null while it stands.
  ///
  /// This one column is the entitlement. A live row for [FullUnlock.productId] is
  /// premium; the same row stamped is not. Nothing else is written either way —
  /// see [Db.revokePurchase] for why a refund never touches a cosmetic the player
  /// also bought with Sparks.
  final String? refundedAt;

  bool get refunded => refundedAt != null;

  /// Whether this row is a live unlock, i.e. whether it is on its own enough to
  /// make its player premium.
  bool get grantsPremium => !refunded && FullUnlock.isUnlock(productId);

  /// The row as `POST /api/purchases/sync` reports it. The transaction id is
  /// included because it is what a player reads off their store receipt when
  /// they write in, and it is not a secret — it identifies a payment they made.
  Map<String, dynamic> toJson() => {
    'transactionId': transactionId,
    'productId': productId,
    'store': store,
    'purchasedAt': purchasedAt,
    'creditedAt': creditedAt,
    'refunded': refunded,
    'refundedAt': ?refundedAt,
  };
}

/// One grant, as it crosses to the db isolate (SPEC §4.9).
///
/// Everything in here is an **identifier or a timestamp**, and that is the point:
/// there is nothing a caller could hand in that would change *what* the purchase
/// grants. What it grants is decided by [Db.grantPurchase] from the product id
/// alone, against [FullUnlock] — so neither the webhook handler, nor the sync
/// handler, nor a future one can pass an entitlement in.
class PurchaseGrantRequest {
  const PurchaseGrantRequest({
    required this.playerId,
    required this.productId,
    required this.transactionId,
    required this.store,
    required this.environment,
    required this.source,
    required this.purchasedAt,
    required this.now,
    this.eventId,
  });

  final String playerId;
  final String productId;

  /// The store's own transaction id — the idempotency key.
  final String transactionId;

  final String store;
  final String environment;

  /// `webhook` or `sync`.
  final String source;

  final DateTime purchasedAt;
  final DateTime now;
  final String? eventId;
}

/// Outcome of [Db.grantPurchase] (SPEC §4.9).
///
/// Refusals are ordinary answers, as everywhere else in this file: "no such
/// product" and "no such player" are facts about the request, not storage
/// faults.
class PurchaseGrant {
  const PurchaseGrant._({
    this.error,
    this.duplicate = false,
    this.premium = false,
    this.productId = '',
    this.transactionId = '',
  });

  const PurchaseGrant.done({
    required bool premium,
    required String productId,
    required String transactionId,
  }) : this._(
         premium: premium,
         productId: productId,
         transactionId: transactionId,
       );

  /// This exact store transaction was already in the ledger, so nothing was
  /// written again.
  ///
  /// [premium] is the **asking player's** state, not the row's: a transaction
  /// already recorded against somebody else must not unlock anything for the
  /// caller, so this reports them as they are — which for a player who bought
  /// nothing is `false`. A repeat of the buyer's own purchase reports them
  /// premium, because they are.
  const PurchaseGrant.alreadyRecorded({
    required bool premium,
    required String productId,
    required String transactionId,
  }) : this._(
         duplicate: true,
         premium: premium,
         productId: productId,
         transactionId: transactionId,
       );

  const PurchaseGrant.unknownProduct(String productId)
    : this._(error: unknownProductError, productId: productId);

  const PurchaseGrant.unknownPlayer() : this._(error: unknownPlayerError);

  /// The product identifier is not one this build sells. Never granted at a
  /// guess: the entitlement is [FullUnlock]'s product or there is no entitlement.
  static const String unknownProductError = 'unknown_product';

  /// The purchase names an app user id that is not a player of this server.
  static const String unknownPlayerError = 'unknown_player';

  final String? error;

  /// The call found the transaction already recorded and wrote nothing.
  final bool duplicate;

  /// Whether the player is premium **after** this call (SPEC §4.9).
  final bool premium;

  final String productId;
  final String transactionId;

  bool get ok => error == null;

  /// Whether this call actually wrote a ledger row.
  bool get granted => ok && !duplicate;
}

/// Outcome of [Db.revokePurchase] (SPEC §4.9).
class PurchaseRevoke {
  const PurchaseRevoke._({
    this.error,
    this.duplicate = false,
    this.premium = false,
    this.productId = '',
    this.playerId,
  });

  const PurchaseRevoke.done({
    required String playerId,
    required String productId,
    required bool premium,
  }) : this._(playerId: playerId, productId: productId, premium: premium);

  /// The refund had already been applied. Idempotent for the same reason a grant
  /// is: a refund webhook is retried too, and a second pass must not re-date a
  /// revocation that already happened.
  const PurchaseRevoke.alreadyRevoked({
    required String playerId,
    required String productId,
    required bool premium,
  }) : this._(
         duplicate: true,
         playerId: playerId,
         productId: productId,
         premium: premium,
       );

  /// No ledger row for that store transaction — a refund for something this
  /// server never recorded. Nothing to do, and not an error worth retrying.
  const PurchaseRevoke.unknownTransaction()
    : this._(error: unknownTransactionError);

  static const String unknownTransactionError = 'unknown_transaction';

  final String? error;
  final bool duplicate;

  /// Whether the player is **still** premium after the revoke. Normally false —
  /// but a player who bought the unlock on two stores holds two live rows, and
  /// refunding one of them does not take the other away.
  final bool premium;

  /// What was revoked, for the log line.
  final String productId;

  final String? playerId;

  bool get ok => error == null;

  /// Whether this call actually stamped the row.
  bool get revoked => ok && !duplicate;
}

// --------------------------------------------- rewarded ads (SPEC §4.10)

/// One row of the ad-reward ledger (SPEC §4.10): an ad Google's server-side
/// verification callback confirmed, what it paid, and what bounded it.
///
/// The ledger exists for the same reason the paid one does: **a balance can
/// always be explained.** Every Spark in a wallet came from exactly one of three
/// places — a verified run in `token_awards`, a store payment in
/// `purchases`, or a watched ad here — and each of them is a row with a
/// timestamp and a key that cannot be duplicated.
///
/// A row is written **even when it paid nothing**. That is not bookkeeping
/// pedantry: the row is the idempotency key, so a callback that arrived once
/// against a full daily cap must leave a trace or its retry would find nothing
/// and pay after all.
class AdRewardRow {
  const AdRewardRow({
    required this.transactionId,
    required this.playerId,
    required this.placement,
    required this.sparks,
    required this.rewardAmount,
    required this.rewardItem,
    required this.adUnit,
    required this.adNetwork,
    required this.keyId,
    required this.day,
    required this.rewardedAt,
    required this.creditedAt,
    this.refused,
  });

  /// AdMob's `transaction_id`: a hex string Google mints per reward and signs
  /// alongside everything else. It is the primary key, and it is the whole of
  /// idempotency — the same reasoning as `purchases.transaction_id`, and
  /// the same consequence if it were missing.
  final String transactionId;

  final String playerId;

  /// Where the ad was offered (`shop`, `gameOver`) — from the signed
  /// `custom_data`, so it is a fact about the ad that was actually watched. Kept
  /// for the product question "does anybody use the game-over one", never for the
  /// amount.
  final String placement;

  /// Sparks credited. The server's number, from [AdRate] inside the crediting
  /// transaction. 0 when the daily cap or the cooldown bounded it.
  final int sparks;

  /// What AdMob's dashboard says the ad is worth, and in what unit. **Recorded
  /// and never read.** It is a number a human typed into a web form; the economy
  /// lives in [AdRate]. Keeping it makes a dashboard that has drifted from the
  /// code visible in a query instead of invisible.
  final int rewardAmount;
  final String rewardItem;

  /// The AdMob ad unit and the mediated network that filled it.
  final String adUnit;
  final String adNetwork;

  /// Which of Google's published keys signed the callback. Worth keeping: after a
  /// key rotation, a ledger still naming the old key id is a cache that is not
  /// refreshing.
  final String keyId;

  /// The UTC day the *ad* falls in, from [rewardedAt] — so a callback that
  /// arrives after midnight still counts against the day it was watched.
  final String day;

  /// Google's own signed timestamp for the reward, and when we credited it.
  final String rewardedAt;
  final String creditedAt;

  /// Why this reward paid less than [AdRate.sparksPerAd], or null when it paid in
  /// full: [dailyCapRefusal] or [cooldownRefusal].
  final String? refused;

  /// The day's allowance was used up (possibly leaving a partial payment).
  static const String dailyCapRefusal = 'daily_cap';

  /// Another ad paid less than [AdRate.cooldown] ago.
  static const String cooldownRefusal = 'cooldown';

  bool get paid => sparks > 0;

  /// The row as `GET /api/ads/offer` reports it. The transaction id is included
  /// because it is what a player quotes when they write in, and it is not a
  /// secret — it identifies an ad they watched.
  Map<String, dynamic> toJson() => {
    'transactionId': transactionId,
    'placement': placement,
    'sparks': sparks,
    'rewardedAt': rewardedAt,
    'creditedAt': creditedAt,
    'refused': ?refused,
  };
}

/// One ad-crediting call, as it crosses to the db isolate (SPEC §4.10).
///
/// Everything here is an **identifier or a timestamp**, exactly as in
/// [PurchaseGrantRequest]. There is deliberately no Sparks field: the amount is
/// [AdRate.forAdWithinDay], applied inside [Db.creditAdReward], so no caller —
/// not the callback handler, not a future one — can hand in a number. The one
/// amount that *is* carried, [rewardAmount], is the one that is never read.
class AdCreditRequest {
  const AdCreditRequest({
    required this.playerId,
    required this.placement,
    required this.transactionId,
    required this.rewardAmount,
    required this.rewardItem,
    required this.adUnit,
    required this.adNetwork,
    required this.keyId,
    required this.rewardedAt,
    required this.now,
  });

  final String playerId;
  final String placement;

  /// AdMob's own id for the reward — the idempotency key.
  final String transactionId;

  /// AdMob's advertised reward, recorded and not read (see [AdRewardRow]).
  final int rewardAmount;
  final String rewardItem;

  final String adUnit;
  final String adNetwork;
  final String keyId;

  /// Google's signed timestamp for the reward: both the cooldown and the day the
  /// cap is measured over come from this, never from our clock.
  final DateTime rewardedAt;

  final DateTime now;
}

/// Outcome of [Db.creditAdReward] (SPEC §4.10).
///
/// Bounded is **not** a refusal: an ad that ran into the daily cap or the
/// cooldown is an `ok` outcome that paid 0 or a part, because the player has
/// already watched it and the callback is Google telling us so. The only genuine
/// refusal is a reward for a player that does not exist.
class AdCredit {
  const AdCredit._({
    this.error,
    this.sparks = 0,
    this.balance = 0,
    this.duplicate = false,
    this.earnedToday = 0,
    this.placement = '',
    this.transactionId = '',
    this.refused,
  });

  const AdCredit.done({
    required int sparks,
    required int balance,
    required int earnedToday,
    required String placement,
    required String transactionId,
    String? refused,
  }) : this._(
         sparks: sparks,
         balance: balance,
         earnedToday: earnedToday,
         placement: placement,
         transactionId: transactionId,
         refused: refused,
       );

  /// This exact AdMob transaction had already been recorded, so nothing was
  /// credited again. [sparks] reports what it paid the first time when the row is
  /// this player's, and 0 when it belongs to somebody else — the same shape
  /// [PurchaseGrant.alreadyRecorded] and [TokenAward] use, and for the same reason:
  /// a reward that has paid one player must never pay a second.
  const AdCredit.alreadyCredited({
    required int sparks,
    required int balance,
    required int earnedToday,
    required String placement,
    required String transactionId,
    String? refused,
  }) : this._(
         sparks: sparks,
         balance: balance,
         earnedToday: earnedToday,
         duplicate: true,
         placement: placement,
         transactionId: transactionId,
         refused: refused,
       );

  const AdCredit.unknownPlayer() : this._(error: unknownPlayerError);

  /// The callback names a player this server does not have.
  static const String unknownPlayerError = 'unknown_player';

  final String? error;

  /// Sparks credited by this call; 0 on a refusal, on a duplicate, and on a
  /// reward the cooldown or a full day bounded to nothing.
  final int sparks;

  final int balance;
  final bool duplicate;

  /// Sparks earned from ads in the reward's own UTC day, after this call.
  final int earnedToday;

  final String placement;
  final String transactionId;

  /// [AdRewardRow.dailyCapRefusal] / [AdRewardRow.cooldownRefusal], or null.
  final String? refused;

  bool get ok => error == null;

  /// Whether this call actually moved the balance.
  bool get credited => ok && !duplicate && sparks > 0;
}

/// What one player's ad allowance looks like right now (SPEC §4.10).
///
/// Answered to the client so it can decide whether to offer an ad *before*
/// loading one — which is the whole point of the cooldown living here rather than
/// only in the crediting path. A player who is inside the cooldown is shown no
/// button at all, instead of watching an ad that pays nothing.
class AdRewardState {
  const AdRewardState({
    required this.earnedToday,
    required this.balance,
    required this.adTotal,
    this.lastRewardedAt,
    this.premium = false,
  });

  /// Sparks earned from ads in the current UTC day.
  final int earnedToday;

  /// The wallet, so one call answers both questions the client has after an ad.
  final int balance;

  /// Sparks this player has ever earned from ads.
  final int adTotal;

  /// Google's signed timestamp of the newest **paying** ad, or null when there
  /// has never been one. Null is why a first ad is always immediately available.
  final DateTime? lastRewardedAt;

  /// Whether the player holds the one-time unlock (SPEC §4.9), which is the other
  /// half of what it grants: **no ads are offered**, ever.
  ///
  /// It rides on the ad state rather than being a second question, because the
  /// one call that decides whether to show the button has to know both — and
  /// because the answer comes from the same db isolate hop as the cooldown.
  final bool premium;
}

class Db {
  Db._(this._db)
    : _insert = _db.prepare(
        'INSERT INTO scores '
        '(id, name, score, ticks, seed, created_at, ip_hash, hash, player_id, '
        ' country, balls) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ),
      // Every board query names a ball count (SPEC §4.6): `balls = ?` leads so
      // that idx_scores_balls hands back one board's slice already ordered by
      // score, leaving the period bound as a residual test rather than a sort.
      // There is deliberately no statement that spans ball counts — a board
      // mixing them would rank runs that were not playing the same game.
      _top = _db.prepare(
        'SELECT id, name, score, ticks, seed, created_at, ip_hash, hash, '
        'player_id, country, balls FROM scores '
        'WHERE balls = ? AND created_at >= ? '
        'ORDER BY score DESC, created_at ASC LIMIT ?',
      ),
      // The national board (SPEC §4.6), inside one ball count.
      _topInCountry = _db.prepare(
        'SELECT id, name, score, ticks, seed, created_at, ip_hash, hash, '
        'player_id, country, balls FROM scores '
        'WHERE balls = ? AND country = ? AND created_at >= ? '
        'ORDER BY score DESC, created_at ASC LIMIT ?',
      ),
      _rank = _db.prepare(
        'SELECT COUNT(*) AS c FROM scores '
        'WHERE balls = ? AND score > ? AND created_at >= ?',
      ),
      _rankInCountry = _db.prepare(
        'SELECT COUNT(*) AS c FROM scores '
        'WHERE balls = ? AND country = ? AND score > ? AND created_at >= ?',
      ),
      _count = _db.prepare('SELECT COUNT(*) AS c FROM scores'),
      _countOnBoard = _db.prepare(
        'SELECT COUNT(*) AS c FROM scores WHERE balls = ?',
      ),
      _insertPlayer = _db.prepare(
        'INSERT INTO players (id, created_at, last_seen_at, name) '
        'VALUES (?, ?, ?, ?)',
      ),
      _playerById = _db.prepare(
        'SELECT id, created_at, last_seen_at, name, '
        'account_provider, account_subject, account_linked_at '
        'FROM players WHERE id = ?',
      ),
      _playerBySubject = _db.prepare(
        'SELECT id, created_at, last_seen_at, name, '
        'account_provider, account_subject, account_linked_at '
        'FROM players WHERE account_provider = ? AND account_subject = ?',
      ),
      // Coalesced: a read that happens within [lastSeenResolution] of the
      // stored value writes nothing, so a client polling an authenticated
      // endpoint cannot turn every request into a database write.
      _touchPlayer = _db.prepare(
        'UPDATE players SET last_seen_at = ? WHERE id = ? AND last_seen_at < ?',
      ),
      _notePlayerScore = _db.prepare(
        'UPDATE players SET name = ?, last_seen_at = ? WHERE id = ?',
      ),
      // Unconditional, unlike [_touchPlayer]: signing in is a rare, certain
      // piece of activity, so it is not worth coalescing away.
      _setLastSeen = _db.prepare(
        'UPDATE players SET last_seen_at = ? WHERE id = ?',
      ),
      // Served entirely by idx_scores_player: the count is an index scan of
      // one player's slice and the best score is its first entry.
      // One row per board the player has runs on, which is why it groups
      // rather than filters: a player with one-ball and two-ball runs gets both
      // in one statement, and a player with neither gets no rows at all.
      _playerBoards = _db.prepare(
        'SELECT balls, COUNT(*) AS c, MAX(score) AS best FROM scores '
        'WHERE player_id = ? GROUP BY balls ORDER BY balls',
      ),
      // The same, restricted to the player's country (SPEC §4.6): a residual
      // test over that same one-player slice, which is tens of rows.
      _playerScoresInCountry = _db.prepare(
        'SELECT COUNT(*) AS c, MAX(score) AS best FROM scores '
        'WHERE player_id = ? AND balls = ? AND country = ?',
      ),
      // A player's country is the one their newest run carried, exactly as the
      // display name is the one their newest run used (SPEC §4.4). Runs without
      // a country are skipped rather than clearing it, so a build that sends no
      // country does not erase where someone plays.
      _playerCountry = _db.prepare(
        'SELECT country FROM scores '
        'WHERE player_id = ? AND country IS NOT NULL '
        'ORDER BY created_at DESC, id DESC LIMIT 1',
      ),
      _playerCount = _db.prepare('SELECT COUNT(*) AS c FROM players'),
      _addSecret = _db.prepare(
        'INSERT INTO player_secrets (id, player_id, secret_hash, created_at) '
        'VALUES (?, ?, ?, ?)',
      ),
      // Newest first, by insertion order. `rowid` rather than `created_at`
      // because the stored timestamp has one-second resolution, which leaves
      // credentials added in the same second in an arbitrary order — and "the
      // oldest" then means nothing. SQLite hands out `max(rowid) + 1`, so this
      // is exactly the order the rows were written in.
      _secretsOf = _db.prepare(
        'SELECT secret_hash FROM player_secrets WHERE player_id = ? '
        'ORDER BY rowid DESC',
      ),
      // Keeps the newest [maxPlayerSecrets] credentials and drops the rest.
      _trimSecrets = _db.prepare(
        'DELETE FROM player_secrets WHERE player_id = ? AND rowid NOT IN '
        '(SELECT rowid FROM player_secrets WHERE player_id = ? '
        ' ORDER BY rowid DESC LIMIT ?)',
      ),
      _deleteSecret = _db.prepare('DELETE FROM player_secrets WHERE id = ?'),
      _deleteSecretsOf = _db.prepare(
        'DELETE FROM player_secrets WHERE player_id = ?',
      ),
      _secretCount = _db.prepare(
        'SELECT COUNT(*) AS c FROM player_secrets WHERE player_id = ?',
      ),
      _alias = _db.prepare(
        'SELECT player_id FROM player_aliases WHERE old_id = ?',
      ),
      _addAlias = _db.prepare(
        'INSERT INTO player_aliases (old_id, player_id, merged_at) '
        'VALUES (?, ?, ?) '
        'ON CONFLICT(old_id) DO UPDATE SET player_id = excluded.player_id',
      ),
      // Keeps every alias one hop from the player it names: merging a player
      // that had itself absorbed others moves their aliases along too.
      _repointAliases = _db.prepare(
        'UPDATE player_aliases SET player_id = ? WHERE player_id = ?',
      ),
      _deleteAliasesOf = _db.prepare(
        'DELETE FROM player_aliases WHERE player_id = ? OR old_id = ?',
      ),
      _tokenUse = _db.prepare(
        'SELECT player_id, credential_id FROM id_token_uses '
        'WHERE token_hash = ?',
      ),
      _recordTokenUse = _db.prepare(
        'INSERT INTO id_token_uses '
        '(token_hash, provider, subject, player_id, credential_id, used_at, '
        ' expires_at) VALUES (?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(token_hash) DO UPDATE SET '
        ' player_id = excluded.player_id, '
        ' credential_id = excluded.credential_id, '
        ' used_at = excluded.used_at',
      ),
      // The bound is `now - tokenUseRetention`, not `now`: see that constant.
      _pruneTokenUses = _db.prepare(
        'DELETE FROM id_token_uses WHERE expires_at < ?',
      ),
      _deleteTokenUsesOf = _db.prepare(
        'DELETE FROM id_token_uses WHERE player_id = ?',
      ),
      _tokenUseCount = _db.prepare('SELECT COUNT(*) AS c FROM id_token_uses'),
      _linkAccount = _db.prepare(
        'UPDATE players SET account_provider = ?, account_subject = ?, '
        'account_linked_at = ?, last_seen_at = ? WHERE id = ?',
      ),
      _unlinkAccount = _db.prepare(
        'UPDATE players SET account_provider = NULL, account_subject = NULL, '
        'account_linked_at = NULL '
        // The subject test is what makes `updatedRows` mean "an account was
        // detached" rather than "the row exists": setting NULL over NULL still
        // counts as an updated row.
        'WHERE id = ? AND account_subject IS NOT NULL',
      ),
      _moveScores = _db.prepare(
        'UPDATE scores SET player_id = ? WHERE player_id = ?',
      ),
      // A merge carries the absorbed player's credentials and ledger rows over
      // instead of dropping them, so the device that was playing as it keeps
      // authenticating — now as the surviving account.
      _moveSecrets = _db.prepare(
        'UPDATE player_secrets SET player_id = ? WHERE player_id = ?',
      ),
      _moveTokenUses = _db.prepare(
        'UPDATE id_token_uses SET player_id = ? WHERE player_id = ?',
      ),
      _anonymiseScores = _db.prepare(
        'UPDATE scores SET player_id = NULL WHERE player_id = ?',
      ),
      _newestScoreName = _db.prepare(
        'SELECT name FROM scores WHERE player_id = ? '
        'ORDER BY created_at DESC, id DESC LIMIT 1',
      ),
      _setPlayerFacts = _db.prepare(
        'UPDATE players SET name = ?, created_at = ?, last_seen_at = ? '
        'WHERE id = ?',
      ),
      // ------------------------------------------- cosmetic items (SPEC §4.8)
      _wallet = _db.prepare(
        'SELECT balance, earned_total, spent_total, purchased_total, ad_total '
        'FROM player_wallets WHERE player_id = ?',
      ),
      // One upsert serves crediting a run's tokens, crediting a watched ad
      // (SPEC §4.10) and carrying an absorbed player's wallet across in a merge,
      // so there is exactly one statement in the whole server that can move a
      // balance upwards. Each new source of Sparks adds an amount to this
      // statement rather than a second upsert beside it: two places that can
      // credit is two places to audit. Money is not one of those sources — what
      // it buys is the unlock, which credits no Sparks at all (SPEC §4.9).
      _creditWallet = _db.prepare(
        'INSERT INTO player_wallets '
        '(player_id, balance, earned_total, spent_total, purchased_total, '
        ' ad_total, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(player_id) DO UPDATE SET '
        ' balance = balance + excluded.balance, '
        ' earned_total = earned_total + excluded.earned_total, '
        ' spent_total = spent_total + excluded.spent_total, '
        ' purchased_total = purchased_total + excluded.purchased_total, '
        ' ad_total = ad_total + excluded.ad_total, '
        ' updated_at = excluded.updated_at',
      ),
      // The only statement that takes tokens out, and the whole guard against a
      // negative balance: `balance >= ?` makes it match only while the row
      // still holds enough, so a purchase either debits exactly once or changes
      // nothing and reports no updated row.
      _debitWallet = _db.prepare(
        'UPDATE player_wallets SET balance = balance - ?, '
        'spent_total = spent_total + ?, updated_at = ? '
        'WHERE player_id = ? AND balance >= ?',
      ),
      _deleteWalletOf = _db.prepare(
        'DELETE FROM player_wallets WHERE player_id = ?',
      ),
      _itemsOf = _db.prepare(
        'SELECT item_id FROM player_items WHERE player_id = ? '
        'ORDER BY item_id',
      ),
      _ownsItem = _db.prepare(
        'SELECT 1 FROM player_items WHERE player_id = ? AND item_id = ?',
      ),
      // OR IGNORE, so a buy that is retried after its response was lost writes
      // nothing the second time instead of failing on the primary key.
      _addItem = _db.prepare(
        'INSERT OR IGNORE INTO player_items '
        '(player_id, item_id, acquired_at, price_paid) VALUES (?, ?, ?, ?)',
      ),
      // A merge carries the absorbed player's purchases to the survivor; both
      // halves may own the same item, which is why collisions are ignored.
      _copyItems = _db.prepare(
        'INSERT OR IGNORE INTO player_items '
        '(player_id, item_id, acquired_at, price_paid) '
        'SELECT ?, item_id, acquired_at, price_paid FROM player_items '
        'WHERE player_id = ?',
      ),
      _deleteItemsOf = _db.prepare(
        'DELETE FROM player_items WHERE player_id = ?',
      ),
      _equippedOf = _db.prepare(
        'SELECT kind, item_id FROM player_equipped WHERE player_id = ?',
      ),
      _setEquipped = _db.prepare(
        'INSERT INTO player_equipped (player_id, kind, item_id, updated_at) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(player_id, kind) DO UPDATE SET '
        ' item_id = excluded.item_id, updated_at = excluded.updated_at',
      ),
      // Going back to the free default is the absence of a row, not a row
      // naming the default: the default then lives in exactly one place
      // ([Catalogue.defaultFor]) and can be changed without a migration.
      _clearEquipped = _db.prepare(
        'DELETE FROM player_equipped WHERE player_id = ? AND kind = ?',
      ),
      // The survivor's own choices win a merge; the absorbed player's fill only
      // the slots the survivor never set.
      _copyEquipped = _db.prepare(
        'INSERT OR IGNORE INTO player_equipped '
        '(player_id, kind, item_id, updated_at) '
        'SELECT ?, kind, item_id, ? FROM player_equipped WHERE player_id = ?',
      ),
      _deleteEquippedOf = _db.prepare(
        'DELETE FROM player_equipped WHERE player_id = ?',
      ),
      // Replay deduplication (SPEC §4.8): the fingerprint of a run, and what it
      // paid the first time it arrived.
      _awardByKey = _db.prepare(
        'SELECT player_id, tokens FROM token_awards WHERE replay_key = ?',
      ),
      _insertAward = _db.prepare(
        'INSERT INTO token_awards '
        '(replay_key, player_id, score_id, score, tokens, day, awarded_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
      ),
      // Served by idx_token_awards_player_day: one day of one player is a
      // prefix scan of a handful of rows.
      _earnedOnDay = _db.prepare(
        'SELECT COALESCE(SUM(tokens), 0) AS t FROM token_awards '
        'WHERE player_id = ? AND day = ?',
      ),
      _moveAwards = _db.prepare(
        'UPDATE token_awards SET player_id = ? WHERE player_id = ?',
      ),
      _deleteAwardsOf = _db.prepare(
        'DELETE FROM token_awards WHERE player_id = ?',
      ),
      // How far one player's ledger exceeds the daily cap, summed over days.
      // After a merge the two halves are one person, so a day on which they
      // each earned an allowance is a day on which one person earned two.
      _dayExcess = _db.prepare(
        'SELECT COALESCE(SUM(over), 0) AS excess FROM '
        '(SELECT SUM(tokens) - ? AS over FROM token_awards '
        ' WHERE player_id = ? GROUP BY day HAVING SUM(tokens) > ?)',
      ),
      _clawBackTokens = _db.prepare(
        'UPDATE player_wallets SET balance = max(balance - ?, 0), '
        'earned_total = max(earned_total - ?, 0), updated_at = ? '
        'WHERE player_id = ?',
      ),
      // --------------------------------------- the one-time unlock (SPEC §4.9)
      _purchaseByTransaction = _db.prepare(
        'SELECT transaction_id, player_id, product_id, store, environment, '
        ' source, event_id, purchased_at, credited_at, refunded_at '
        'FROM purchases WHERE transaction_id = ?',
      ),
      // `sparks` and `clawed_back` are the Spark-pack columns this build no
      // longer sells into; a new row writes the zero they mean rather than
      // leaving a NOT NULL column to guess at. See [PurchaseRecord].
      _insertPurchase = _db.prepare(
        'INSERT INTO purchases '
        '(transaction_id, player_id, product_id, sparks, store, environment, '
        ' source, event_id, purchased_at, credited_at) '
        'VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, ?)',
      ),
      // A revoke stamps the row and writes nothing else anywhere. There is no
      // wallet to debit (the unlock credits no Sparks) and no item row to
      // delete (premium was never rows), which is exactly why a refund cannot
      // reach a cosmetic the player bought with Sparks — see [revokePurchase].
      _markRefunded = _db.prepare(
        'UPDATE purchases SET refunded_at = ? WHERE transaction_id = ?',
      ),
      // The entitlement, in one statement: a live row for the unlock product.
      // Served by idx_purchases_player, whose leading column is the player, so
      // this is a prefix scan of the handful of rows one person can have.
      _liveUnlockOf = _db.prepare(
        'SELECT 1 FROM purchases '
        'WHERE player_id = ? AND product_id = ? AND refunded_at IS NULL '
        'LIMIT 1',
      ),
      _purchasesOf = _db.prepare(
        'SELECT transaction_id, player_id, product_id, store, environment, '
        ' source, event_id, purchased_at, credited_at, refunded_at '
        'FROM purchases WHERE player_id = ? '
        'ORDER BY credited_at DESC, transaction_id DESC LIMIT ?',
      ),
      _movePurchases = _db.prepare(
        'UPDATE purchases SET player_id = ? WHERE player_id = ?',
      ),
      _deletePurchasesOf = _db.prepare(
        'DELETE FROM purchases WHERE player_id = ?',
      ),
      _purchaseCount = _db.prepare('SELECT COUNT(*) AS c FROM purchases'),
      // ------------------------------------------ rewarded ads (SPEC §4.10)
      _adRewardByTransaction = _db.prepare(
        'SELECT transaction_id, player_id, placement, sparks, reward_amount, '
        ' reward_item, ad_unit, ad_network, key_id, day, rewarded_at, '
        ' credited_at, refused '
        'FROM ad_rewards WHERE transaction_id = ?',
      ),
      _insertAdReward = _db.prepare(
        'INSERT INTO ad_rewards '
        '(transaction_id, player_id, placement, sparks, reward_amount, '
        ' reward_item, ad_unit, ad_network, key_id, day, rewarded_at, '
        ' credited_at, refused) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ),
      // The ad daily cap is a sum over one player's rows for one UTC day, which
      // idx_ad_rewards_player_day turns into a prefix scan of a handful.
      _adSparksOnDay = _db.prepare(
        'SELECT COALESCE(SUM(sparks), 0) AS t FROM ad_rewards '
        'WHERE player_id = ? AND day = ?',
      ),
      // The newest ad that actually **paid**, for the cooldown. Rows that paid
      // nothing are skipped on purpose: a reward the cooldown already bounced
      // must not extend the cooldown, or one refused ad would lock a player out
      // for a rolling five minutes at a time.
      _newestPaidAdReward = _db.prepare(
        'SELECT rewarded_at FROM ad_rewards '
        'WHERE player_id = ? AND sparks > 0 '
        'ORDER BY rewarded_at DESC LIMIT 1',
      ),
      _adRewardsOf = _db.prepare(
        'SELECT transaction_id, player_id, placement, sparks, reward_amount, '
        ' reward_item, ad_unit, ad_network, key_id, day, rewarded_at, '
        ' credited_at, refused '
        'FROM ad_rewards WHERE player_id = ? '
        'ORDER BY rewarded_at DESC, transaction_id DESC LIMIT ?',
      ),
      _moveAdRewards = _db.prepare(
        'UPDATE ad_rewards SET player_id = ? WHERE player_id = ?',
      ),
      _deleteAdRewardsOf = _db.prepare(
        'DELETE FROM ad_rewards WHERE player_id = ?',
      ),
      _adRewardCount = _db.prepare('SELECT COUNT(*) AS c FROM ad_rewards'),
      // How far one player's ad ledger exceeds the ad daily cap, summed over
      // days — the same shape as [_dayExcess] for play, and used for the same
      // reason after a merge.
      _adDayExcess = _db.prepare(
        'SELECT COALESCE(SUM(over), 0) AS excess FROM '
        '(SELECT SUM(sparks) - ? AS over FROM ad_rewards '
        ' WHERE player_id = ? GROUP BY day HAVING SUM(sparks) > ?)',
      ),
      _clawBackAdSparks = _db.prepare(
        'UPDATE player_wallets SET balance = max(balance - ?, 0), '
        'ad_total = max(ad_total - ?, 0), updated_at = ? '
        'WHERE player_id = ?',
      ),
      _itemRowCount = _db.prepare('SELECT COUNT(*) AS c FROM player_items'),
      _awardCount = _db.prepare('SELECT COUNT(*) AS c FROM token_awards'),
      _deletePlayer = _db.prepare('DELETE FROM players WHERE id = ?');

  /// How long a blocked SQLite call waits for another writer to release the
  /// lock before failing (`PRAGMA busy_timeout`). The wait happens inside the
  /// C call, which is why the database is owned by a dedicated isolate
  /// ([ScoreStore]) instead of the isolate that serves requests and ticks.
  static const Duration defaultBusyTimeout = Duration(seconds: 5);

  /// Opens (creating if needed) the database at [path]. `:memory:` opens an
  /// in-memory database (tests). Parent directories are created.
  factory Db.open(String path, {Duration busyTimeout = defaultBusyTimeout}) {
    final Database db;
    if (path == ':memory:') {
      db = sqlite3.openInMemory();
    } else {
      final dir = File(path).parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      db = sqlite3.open(path);
    }
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}');
    try {
      migrate(db);
    } catch (_) {
      db.close();
      rethrow;
    }
    return Db._(db);
  }

  /// Schema version stored in SQLite's `user_version`.
  ///
  /// 0 is both an empty file and every database written before player
  /// identity existed (`user_version` was never set, so it reads as 0);
  /// [migrate] brings either to [schemaVersion].
  static const int schemaVersion = 8;

  /// Oldest SQLite that can run [migrate]: `ALTER TABLE … DROP COLUMN` is
  /// 3.35.0 (2021-03). Debian bookworm, which the image is built on, ships
  /// 3.40. Checked explicitly so an old library fails with this sentence
  /// instead of a syntax error from the middle of a transaction.
  static const int minSqliteVersionNumber = 3035000;

  /// How stale `players.last_seen_at` may get before [touchPlayer] writes.
  static const Duration lastSeenResolution = Duration(minutes: 1);

  /// How long a spent identity token stays in the replay ledger *after* its own
  /// `exp` (SPEC §4.5).
  ///
  /// It must comfortably exceed the verifier's clock skew
  /// ([idTokenClockSkew], 60 s), because a token is still *accepted* for that
  /// long past `exp`. Dropping its row any earlier would reopen the window this
  /// ledger exists to close: a replayed token would stop resolving to the
  /// recorded outcome and be treated as a fresh sign-in, which for an attacker
  /// holding a captured token and their own anonymous player means a merge into
  /// somebody else's account.
  static const Duration tokenUseRetention = Duration(minutes: 10);

  /// Credentials one player may hold at once — one per device, plus room to
  /// spare (SPEC §4.4).
  ///
  /// Signing in never revokes another device, so the set grows with devices
  /// and with reinstalls. The cap bounds that; over it the credential added
  /// longest ago is evicted, which signs out the device that has not signed in
  /// for longest.
  static const int maxPlayerSecrets = 10;

  /// Brings [db] up to [schemaVersion], in one transaction, preserving every
  /// existing row. Idempotent: running it on a current database does nothing.
  ///
  /// A file from a *newer* build is refused rather than opened, because the
  /// prepared statements below would fail in less obvious ways.
  static void migrate(Database db) {
    final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version > schemaVersion) {
      throw StateError(
        'database schema version $version is newer than this server '
        'supports ($schemaVersion)',
      );
    }
    if (version == schemaVersion) return;
    final library = sqlite3.version;
    if (library.versionNumber < minSqliteVersionNumber) {
      throw StateError(
        'SQLite ${library.libVersion} is too old to migrate this database: '
        'ALTER TABLE ... DROP COLUMN needs 3.35.0 or newer',
      );
    }
    db.execute('BEGIN');
    try {
      if (version < 1) _migrateToV1(db);
      if (version < 2) _migrateToV2(db);
      if (version < 3) _migrateToV3(db);
      if (version < 4) _migrateToV4(db);
      if (version < 5) _migrateToV5(db);
      if (version < 6) _migrateToV6(db);
      if (version < 7) _migrateToV7(db);
      if (version < 8) _migrateToV8(db);
      db.execute('PRAGMA user_version = $schemaVersion');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// v0 → v1: the `players` table, `scores.player_id` and its index.
  ///
  /// The `scores` table is created in its original shape and `player_id` is
  /// then added with `ALTER TABLE`, so a fresh database and one that already
  /// holds anonymous rows take exactly the same code path — the second case is
  /// the one that has to keep working, and it is the one that runs in
  /// production.
  static void _migrateToV1(Database db) {
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
    db.execute('''
      CREATE TABLE IF NOT EXISTS players (
        id TEXT PRIMARY KEY,
        secret_hash TEXT NOT NULL,
        created_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL,
        name TEXT,
        account_provider TEXT,
        account_subject TEXT,
        account_email TEXT,
        account_linked_at TEXT
      )
    ''');
    // Nullable with no default, so every row already in `scores` stays valid
    // and keeps appearing on the leaderboard as an anonymous run.
    if (!_hasColumn(db, 'scores', 'player_id')) {
      db.execute(
        'ALTER TABLE scores ADD COLUMN player_id TEXT REFERENCES players (id)',
      );
    }
    // "This player's entries" and "this player's best" are both a prefix scan
    // of one player's slice; created_at keeps that slice ordered the same way
    // the leaderboard is.
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scores_player '
      'ON scores (player_id, score DESC, created_at)',
    );
    // One provider account maps to at most one player. Partial, so the
    // anonymous majority (NULL subject) is not indexed.
    db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_players_account '
      'ON players (account_provider, account_subject) '
      'WHERE account_subject IS NOT NULL',
    );
  }

  /// v1 → v2 (SPEC §4.5): credentials move to their own table so one player
  /// can hold several, `players.account_email` is dropped, and the identity
  /// token ledger is added.
  ///
  /// Why the column goes away rather than merely staying NULL: SPEC §4.5 says
  /// the server stores no address for a linked account, and a schema with
  /// nowhere to put one is a claim that can be checked with
  /// `PRAGMA table_info(players)` instead of by auditing every write. It was
  /// reserved by the anonymous-identity layer and never written, so nothing is
  /// lost.
  static void _migrateToV2(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS player_secrets (
        id TEXT PRIMARY KEY,
        player_id TEXT NOT NULL REFERENCES players (id),
        secret_hash TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_player_secrets_player '
      'ON player_secrets (player_id, created_at)',
    );
    // Every existing player keeps working: its one secret becomes its first
    // credential, digest unchanged, so a client that stored the secret at
    // issue time still authenticates with it.
    if (_hasColumn(db, 'players', 'secret_hash')) {
      db.execute(
        'INSERT INTO player_secrets (id, player_id, secret_hash, created_at) '
        'SELECT lower(hex(randomblob(16))), id, secret_hash, created_at '
        'FROM players',
      );
      db.execute('ALTER TABLE players DROP COLUMN secret_hash');
    }
    if (_hasColumn(db, 'players', 'account_email')) {
      db.execute('ALTER TABLE players DROP COLUMN account_email');
    }
    // Where a merged-away player id now points (SPEC §4.5). The credential a
    // client stores is `<playerId>:<secret>`, so absorbing a player would
    // otherwise break the calling device's stored credential the moment the
    // merge it asked for succeeded — including the retry of that very call.
    db.execute('''
      CREATE TABLE IF NOT EXISTS player_aliases (
        old_id TEXT PRIMARY KEY,
        player_id TEXT NOT NULL REFERENCES players (id),
        merged_at TEXT NOT NULL
      )
    ''');
    // Walked when a player is deleted, to drop the aliases aimed at it.
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_player_aliases_player '
      'ON player_aliases (player_id)',
    );
    // The replay ledger of SPEC §4.5: which identity tokens have already been
    // spent, and what they resolved to, so a retry cannot land on a different
    // account than the call it is retrying.
    db.execute('''
      CREATE TABLE IF NOT EXISTS id_token_uses (
        token_hash TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        subject TEXT NOT NULL,
        player_id TEXT NOT NULL,
        credential_id TEXT,
        used_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
      )
    ''');
    // A row is useless once the token it describes can no longer be presented
    // at all (its `exp` plus [tokenUseRetention]); this index is what makes
    // dropping them a range delete instead of a scan.
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_id_token_uses_expiry '
      'ON id_token_uses (expires_at)',
    );
  }

  /// v2 → v3 (SPEC §4.6): `scores.country` and the index the national board is
  /// served from.
  ///
  /// Nullable with no default, so every row already stored keeps its values and
  /// simply counts for no country — which is the truth about it: nobody asked
  /// those players where they were playing. They stay on the global board
  /// exactly as they were, and a national board is a strictly smaller slice of
  /// it, never a re-ranking of anything.
  static void _migrateToV3(Database db) {
    if (!_hasColumn(db, 'scores', 'country')) {
      db.execute('ALTER TABLE scores ADD COLUMN country TEXT');
    }
    // Mirrors idx_scores_rank inside one country: the equality on `country`
    // makes the score ordering usable, so a national top 100 is a prefix scan
    // and needs no sort. Nulls are indexed too, which costs one entry per
    // pre-v3 row and keeps the index a plain one rather than a partial index
    // that a `country = ?` lookup could not use.
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scores_country '
      'ON scores (country, score DESC, created_at)',
    );
  }

  /// v3 → v4 (SPEC §4.8): the cosmetic item tables — a token wallet, the items
  /// a player bought, what they have equipped, and the ledger of which runs
  /// have already paid tokens.
  ///
  /// Four new tables and not one change to an existing one, which is the point:
  /// every score, player and credential stays exactly as it was, and a
  /// deployment that upgrades gets a shop where every player starts with an
  /// empty wallet, the free items, and no stored preference. There is nothing to
  /// backfill, because free items are owned implicitly and an unset slot means
  /// "the default" (see [Catalogue.defaultFor]).
  static void _migrateToV4(Database db) {
    // One row per player, created on the first token earned rather than when
    // the player is issued: a wallet of zero is not a fact worth a row, and
    // `POST /api/players` stays a single insert.
    //
    // The CHECK is the last line of defence on the balance. The conditional
    // debit in [buyItem] is what actually keeps it non-negative; this makes a
    // future code path that forgets the condition fail loudly instead of
    // quietly handing out free items.
    db.execute('''
      CREATE TABLE IF NOT EXISTS player_wallets (
        player_id TEXT PRIMARY KEY REFERENCES players (id),
        balance INTEGER NOT NULL DEFAULT 0 CHECK (balance >= 0),
        earned_total INTEGER NOT NULL DEFAULT 0,
        spent_total INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
    // Only **bought** items are rows here; free ones are owned implicitly by
    // everybody (SPEC §4.8). The primary key is also the index that answers
    // "what does this player own" and "does this player own that item", both of
    // which are prefix lookups of one player's slice.
    db.execute('''
      CREATE TABLE IF NOT EXISTS player_items (
        player_id TEXT NOT NULL REFERENCES players (id),
        item_id TEXT NOT NULL,
        acquired_at TEXT NOT NULL,
        price_paid INTEGER NOT NULL,
        PRIMARY KEY (player_id, item_id)
      )
    ''');
    // One row per occupied slot, keyed by the *kind* rather than a column per
    // kind, so a catalogue version that adds a kind needs no migration at all.
    // An absent row means the free default, which is why nothing has to be
    // written when a player is issued.
    db.execute('''
      CREATE TABLE IF NOT EXISTS player_equipped (
        player_id TEXT NOT NULL REFERENCES players (id),
        kind TEXT NOT NULL,
        item_id TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (player_id, kind)
      )
    ''');
    // The earning ledger, and the whole of replay deduplication: `replay_key`
    // is a digest of the run itself (see `replayFingerprint` in
    // `leaderboard.dart`), so re-submitting a recorded game cannot pay twice.
    // A row is written even when the run paid **nothing**, because a run that
    // earned zero against a full daily cap would otherwise be worth
    // re-submitting tomorrow.
    db.execute('''
      CREATE TABLE IF NOT EXISTS token_awards (
        replay_key TEXT PRIMARY KEY,
        player_id TEXT NOT NULL REFERENCES players (id),
        score_id TEXT NOT NULL,
        score INTEGER NOT NULL,
        tokens INTEGER NOT NULL,
        day TEXT NOT NULL,
        awarded_at TEXT NOT NULL
      )
    ''');
    // The daily cap is a sum over one player's rows for one UTC day; this makes
    // it a prefix scan of a handful of them instead of a table scan.
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_token_awards_player_day '
      'ON token_awards (player_id, day)',
    );
  }

  /// v4 → v5 (SPEC §4.9): the paid-Spark ledger, and the wallet column that
  /// separates bought Sparks from played-for ones.
  ///
  /// Nothing that already exists changes shape. The new wallet column is added
  /// with a default of 0, so every wallet written by v4 stays valid and reads as
  /// "none of this was bought" — which is exactly true, because before this
  /// version there was no way to buy any.
  static void _migrateToV5(Database db) {
    if (!_hasColumn(db, 'player_wallets', 'purchased_total')) {
      db.execute(
        'ALTER TABLE player_wallets '
        'ADD COLUMN purchased_total INTEGER NOT NULL DEFAULT 0',
      );
    }
    // The ledger, and the whole of purchase idempotency. The primary key is the
    // **store's** transaction id, not RevenueCat's event id and not anything the
    // phone chooses: RevenueCat retries a webhook until it gets a 2xx, the client
    // nudges the same purchase from `POST /api/purchases/sync`, and Apple can
    // deliver the same transaction through both paths at once. Every one of those
    // is the same payment, so every one of them must credit exactly once — a
    // second credit is money we were never paid.
    //
    // A refund does not delete the row. It stamps `refunded_at` and records in
    // `clawed_back` how much could actually be taken off the balance, because a
    // balance cannot go negative and the Sparks may already be a paddle skin.
    // Deleting instead would lose both the audit and the idempotency: the next
    // retry of the refund webhook would find nothing and fall through to
    // crediting again.
    db.execute('''
      CREATE TABLE IF NOT EXISTS spark_purchases (
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
    // "Explain this player's balance" is one player's slice, newest first.
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_spark_purchases_player '
      'ON spark_purchases (player_id, credited_at DESC)',
    );
  }

  /// v5 → v6 (SPEC §4.10): the ad-reward ledger, and the wallet column that
  /// separates Sparks earned from ads from both the played-for and the bought
  /// ones.
  ///
  /// Nothing that already exists changes shape. The new wallet column defaults to
  /// 0, so every wallet written by v5 stays valid and reads as "none of this came
  /// from an ad" — which is exactly true, because before this version there were
  /// no ads.
  ///
  /// **Why a third column rather than folding ads into `earned_total`.** The two
  /// daily caps are deliberately separate (see [AdRate]), and they can only stay
  /// separate if the two kinds of Spark are countable separately: a Spark from an
  /// ad must never look like one that consumed a play allowance, or six ads would
  /// quietly make an evening of good runs pay nothing.
  static void _migrateToV6(Database db) {
    if (!_hasColumn(db, 'player_wallets', 'ad_total')) {
      db.execute(
        'ALTER TABLE player_wallets '
        'ADD COLUMN ad_total INTEGER NOT NULL DEFAULT 0',
      );
    }
    // The ledger, and the whole of ad idempotency. The primary key is AdMob's
    // own `transaction_id`, which arrives inside the content Google signs: a
    // caller cannot choose it, and a retried callback carries the same one. A
    // second credit for one watched ad is a Spark nobody earned.
    //
    // `sparks` is what was actually credited and `refused` says why it was less
    // than [AdRate.sparksPerAd] — a row exists even for a reward that paid 0,
    // because the row *is* the idempotency key. Deleting or skipping those would
    // mean a callback that hit the daily cap on its first delivery would pay on
    // its retry.
    //
    // `reward_amount` and `reward_item` are what AdMob's dashboard advertises.
    // They are recorded and never read; the amount comes from [AdRate].
    db.execute('''
      CREATE TABLE IF NOT EXISTS ad_rewards (
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
    // The daily cap: one player's slice of one UTC day.
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ad_rewards_player_day '
      'ON ad_rewards (player_id, day)',
    );
    // The cooldown, and "explain this player's ad Sparks": one player's slice,
    // newest reward first.
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ad_rewards_player_time '
      'ON ad_rewards (player_id, rewarded_at DESC)',
    );
  }

  /// v6 → v7 (SPEC §4.9): the paid-Spark ledger becomes the **purchase** ledger,
  /// because what money buys is no longer Sparks but the one-time unlock.
  ///
  /// A rename and nothing else. Every row keeps every column — including the
  /// `sparks` and `clawed_back` numbers of the Spark packs that are gone, so a
  /// wallet that bought Sparks before this release is still explainable by the
  /// rows behind it. Nothing is dropped, nothing is rewritten, and no row is
  /// backfilled: the entitlement this ledger now answers is *derived* from it
  /// ([isPremium]), so a database that was upgraded and one that was created
  /// today answer the same way.
  ///
  /// A legacy `arco.sparks.*` row is therefore still there and still grants
  /// nothing, which is the correct reading of it: it paid in Sparks, and those
  /// Sparks are already in the wallet.
  ///
  /// The index is dropped and recreated rather than carried over, because
  /// `ALTER TABLE … RENAME TO` keeps an index pointing at the renamed table under
  /// its **old** name, and an index called `idx_spark_purchases_player` on a table
  /// called `purchases` is a lie the next reader has to untangle.
  static void _migrateToV7(Database db) {
    if (_hasTable(db, 'spark_purchases') && !_hasTable(db, 'purchases')) {
      db.execute('ALTER TABLE spark_purchases RENAME TO purchases');
    }
    // Reached with no table at all by every database older than v5, which never
    // had one to rename.
    db.execute('''
      CREATE TABLE IF NOT EXISTS purchases (
        transaction_id TEXT PRIMARY KEY,
        player_id TEXT NOT NULL REFERENCES players (id),
        product_id TEXT NOT NULL,
        sparks INTEGER NOT NULL DEFAULT 0,
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
    db.execute('DROP INDEX IF EXISTS idx_spark_purchases_player');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_purchases_player '
      'ON purchases (player_id, credited_at DESC)',
    );
  }

  /// v7 → v8 (SPEC §4.3, §4.6): `scores.balls` — which board a run belongs to —
  /// and the two indexes that make a board a prefix scan.
  ///
  /// **One column, `NOT NULL DEFAULT 1`, and nothing else changes shape.** Every
  /// existing row therefore reads `balls = 1`, and that is not a backfill: until
  /// this version the simulation had exactly one ball, so every run that was ever
  /// stored *was* a one-ball run. This is the one place where a new column may
  /// honestly claim a value for old rows — unlike `country` (v3), which was
  /// genuinely unknown and stayed NULL. The consequence that matters is that no
  /// row disappears: the one-ball board after the upgrade is the whole
  /// leaderboard as it was, in the same order, and a client that never asks for a
  /// board still gets that one (§4.6).
  ///
  /// Two indexes rather than one, mirroring the pair that already exists for the
  /// global and the national board: `(balls, score DESC, created_at)` answers one
  /// board's top 100 without a sort, and `(balls, country, score DESC,
  /// created_at)` does the same inside one country. The older
  /// `(country, score DESC, created_at)` is kept — it is still the index behind
  /// "this player's country" and behind any country query that does not name a
  /// board — and `(score DESC, created_at)` is kept because it is the only index
  /// that orders the whole table, which `count` and the ad-hoc queries an
  /// operator runs still want.
  static void _migrateToV8(Database db) {
    if (!_hasColumn(db, 'scores', 'balls')) {
      db.execute(
        'ALTER TABLE scores ADD COLUMN balls INTEGER NOT NULL DEFAULT 1',
      );
    }
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scores_balls '
      'ON scores (balls, score DESC, created_at)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scores_balls_country '
      'ON scores (balls, country, score DESC, created_at)',
    );
  }

  static bool _hasTable(Database db, String table) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    [table],
  ).isNotEmpty;

  static bool _hasColumn(Database db, String table, String column) => db
      .select('PRAGMA table_info($table)')
      .any((row) => row['name'] == column);

  final Database _db;
  final PreparedStatement _insert;
  final PreparedStatement _top;
  final PreparedStatement _topInCountry;
  final PreparedStatement _rank;
  final PreparedStatement _rankInCountry;
  final PreparedStatement _count;
  final PreparedStatement _countOnBoard;
  final PreparedStatement _insertPlayer;
  final PreparedStatement _playerById;
  final PreparedStatement _playerBySubject;
  final PreparedStatement _touchPlayer;
  final PreparedStatement _notePlayerScore;
  final PreparedStatement _setLastSeen;
  final PreparedStatement _playerBoards;
  final PreparedStatement _playerScoresInCountry;
  final PreparedStatement _playerCountry;
  final PreparedStatement _playerCount;
  final PreparedStatement _addSecret;
  final PreparedStatement _secretsOf;
  final PreparedStatement _trimSecrets;
  final PreparedStatement _deleteSecret;
  final PreparedStatement _deleteSecretsOf;
  final PreparedStatement _secretCount;
  final PreparedStatement _alias;
  final PreparedStatement _addAlias;
  final PreparedStatement _repointAliases;
  final PreparedStatement _deleteAliasesOf;
  final PreparedStatement _tokenUse;
  final PreparedStatement _recordTokenUse;
  final PreparedStatement _pruneTokenUses;
  final PreparedStatement _deleteTokenUsesOf;
  final PreparedStatement _tokenUseCount;
  final PreparedStatement _linkAccount;
  final PreparedStatement _unlinkAccount;
  final PreparedStatement _moveScores;
  final PreparedStatement _moveSecrets;
  final PreparedStatement _moveTokenUses;
  final PreparedStatement _anonymiseScores;
  final PreparedStatement _newestScoreName;
  final PreparedStatement _setPlayerFacts;
  final PreparedStatement _deletePlayer;
  final PreparedStatement _wallet;
  final PreparedStatement _creditWallet;
  final PreparedStatement _debitWallet;
  final PreparedStatement _deleteWalletOf;
  final PreparedStatement _itemsOf;
  final PreparedStatement _ownsItem;
  final PreparedStatement _addItem;
  final PreparedStatement _copyItems;
  final PreparedStatement _deleteItemsOf;
  final PreparedStatement _equippedOf;
  final PreparedStatement _setEquipped;
  final PreparedStatement _clearEquipped;
  final PreparedStatement _copyEquipped;
  final PreparedStatement _deleteEquippedOf;
  final PreparedStatement _awardByKey;
  final PreparedStatement _insertAward;
  final PreparedStatement _earnedOnDay;
  final PreparedStatement _moveAwards;
  final PreparedStatement _deleteAwardsOf;
  final PreparedStatement _dayExcess;
  final PreparedStatement _clawBackTokens;
  final PreparedStatement _purchaseByTransaction;
  final PreparedStatement _insertPurchase;
  final PreparedStatement _markRefunded;
  final PreparedStatement _liveUnlockOf;
  final PreparedStatement _purchasesOf;
  final PreparedStatement _movePurchases;
  final PreparedStatement _deletePurchasesOf;
  final PreparedStatement _purchaseCount;
  final PreparedStatement _adRewardByTransaction;
  final PreparedStatement _insertAdReward;
  final PreparedStatement _adSparksOnDay;
  final PreparedStatement _newestPaidAdReward;
  final PreparedStatement _adRewardsOf;
  final PreparedStatement _moveAdRewards;
  final PreparedStatement _deleteAdRewardsOf;
  final PreparedStatement _adRewardCount;
  final PreparedStatement _adDayExcess;
  final PreparedStatement _clawBackAdSparks;
  final PreparedStatement _itemRowCount;
  final PreparedStatement _awardCount;
  bool _closed = false;

  bool get isClosed => _closed;

  void insertScore(ScoreRow row) {
    _insert.execute([
      row.id,
      row.name,
      row.score,
      row.ticks,
      row.seed,
      row.createdAt,
      row.ipHash,
      row.hash,
      row.playerId,
      row.country,
      row.balls,
    ]);
  }

  /// Top scores of one board, ordered by score desc then createdAt asc.
  ///
  /// [balls] names the board (SPEC §4.6): a run played with two balls is not
  /// competing with a one-ball run, so there is no query that returns both.
  /// [country] restricts the board to one country's runs; it composes with
  /// [period] and [balls] rather than replacing either, so "this week in
  /// Poland, two balls" is one query. It must already be a validated code
  /// (see `country.dart`).
  List<ScoreRow> topScores({
    LeaderboardPeriod period = LeaderboardPeriod.all,
    int limit = 100,
    DateTime? now,
    String? country,
    int balls = 1,
  }) {
    final since = periodLowerBound(period, now);
    final rows = country == null
        ? _top.select([balls, since, limit])
        : _topInCountry.select([balls, country, since, limit]);
    return [
      for (final r in rows)
        ScoreRow(
          id: r['id'] as String,
          name: r['name'] as String,
          score: r['score'] as int,
          ticks: r['ticks'] as int,
          seed: r['seed'] as int,
          createdAt: r['created_at'] as String,
          ipHash: r['ip_hash'] as String,
          hash: r['hash'] as int,
          playerId: r['player_id'] as String?,
          country: r['country'] as String?,
          balls: r['balls'] as int,
        ),
    ];
  }

  /// `1 + number of scores > [score]` on the [balls] board within [period], and
  /// within [country] when one is given (SPEC §4.6).
  int rank(
    int score, {
    LeaderboardPeriod period = LeaderboardPeriod.all,
    DateTime? now,
    String? country,
    int balls = 1,
  }) {
    final since = periodLowerBound(period, now);
    final rows = country == null
        ? _rank.select([balls, score, since])
        : _rankInCountry.select([balls, country, score, since]);
    return 1 + (rows.first['c'] as int);
  }

  /// Stored scores in total, across every board (diagnostics / tests).
  int get count => _count.select().first['c'] as int;

  /// Stored scores on the [balls] board (diagnostics / tests).
  int countOnBoard(int balls) =>
      _countOnBoard.select([balls]).first['c'] as int;

  int get playerCount => _playerCount.select().first['c'] as int;

  /// Recorded uses of identity tokens not yet pruned (diagnostics / tests).
  int get tokenUseCount => _tokenUseCount.select().first['c'] as int;

  /// Credentials [playerId] currently holds (diagnostics / tests).
  int secretCount(String playerId) =>
      _secretCount.select([playerId]).first['c'] as int;

  /// Stores one player together with its first credential, atomically: a
  /// player row with no credential could never be authenticated and would be
  /// dead weight, so the two are never written apart.
  ///
  /// Throws on a duplicate id (a 128-bit collision).
  void createPlayer(
    PlayerRow row, {
    required String credentialId,
    required String secretHash,
  }) {
    _transact(() {
      _insertPlayer.execute([row.id, row.createdAt, row.lastSeenAt, row.name]);
      _addSecret.execute([credentialId, row.id, secretHash, row.createdAt]);
    });
  }

  /// Adds one credential to [playerId] without revoking the others, then
  /// evicts down to [maxPlayerSecrets] oldest-first.
  void addPlayerSecret({
    required String playerId,
    required String credentialId,
    required String secretHash,
    required DateTime now,
  }) {
    _transact(() {
      _addSecret.execute([
        credentialId,
        playerId,
        secretHash,
        formatTimestamp(now),
      ]);
      _trimSecrets.execute([playerId, playerId, maxPlayerSecrets]);
    });
  }

  /// The player with [id], or null when there is none.
  PlayerRow? playerById(String id) => _readPlayer(_playerById.select([id]));

  /// The player holding the provider account ([provider], [subject]), or null.
  /// At most one can, by `idx_players_account`.
  PlayerRow? playerByAccount(String provider, String subject) =>
      _readPlayer(_playerBySubject.select([provider, subject]));

  /// [id]'s row plus every credential digest it may authenticate with, or null
  /// when there is no such player.
  ///
  /// One call rather than two so authenticating a request costs a single hop to
  /// this isolate.
  ///
  /// [id] may be a player that was absorbed by a merge, in which case the
  /// surviving player is returned ([canonicalPlayerId]): the credential a client
  /// stores names a player id, and a merge must not invalidate it. The caller
  /// therefore has to read the player's id from the row rather than assume it is
  /// the one that was asked for.
  StoredPlayer? playerWithSecrets(String id) {
    final player = playerById(canonicalPlayerId(id));
    if (player == null) return null;
    return StoredPlayer(
      player: player,
      secretHashes: [
        for (final r in _secretsOf.select([player.id]))
          r['secret_hash'] as String,
      ],
    );
  }

  /// [id] itself, or the player that absorbed it in a merge (SPEC §4.5).
  ///
  /// Aliases are kept one hop deep by [linkAccount], so this is a single lookup
  /// and cannot loop.
  String canonicalPlayerId(String id) {
    final rows = _alias.select([id]);
    return rows.isEmpty ? id : rows.first['player_id'] as String;
  }

  PlayerRow? _readPlayer(ResultSet rows) {
    if (rows.isEmpty) return null;
    final r = rows.first;
    return PlayerRow(
      id: r['id'] as String,
      createdAt: r['created_at'] as String,
      lastSeenAt: r['last_seen_at'] as String,
      name: r['name'] as String?,
      accountProvider: r['account_provider'] as String?,
      accountSubject: r['account_subject'] as String?,
      accountLinkedAt: r['account_linked_at'] as String?,
    );
  }

  /// Moves `last_seen_at` forward to [now], but only when the stored value is
  /// more than [lastSeenResolution] behind it. Returns whether it wrote.
  bool touchPlayer(String id, DateTime now) {
    final cutoff = formatTimestamp(now.toUtc().subtract(lastSeenResolution));
    _touchPlayer.execute([formatTimestamp(now), id, cutoff]);
    return _db.updatedRows > 0;
  }

  /// Records that [id] submitted a score under [name]: the display name
  /// follows the last name the player actually played under, and the
  /// submission always counts as activity.
  void notePlayerScore(String id, String name, DateTime now) {
    _notePlayerScore.execute([name, formatTimestamp(now), id]);
  }

  /// One [PlayerStats] per board [playerId] has runs on, in ball-count order
  /// (SPEC §4.3, §4.6).
  ///
  /// A player who has submitted nothing gets an empty list; a player with
  /// one-ball runs only gets one entry. Boards are never invented, so an entry
  /// always carries a real [PlayerStats.bestScore] and a real rank — there is no
  /// "you are last on a board you never played" row.
  List<PlayerStats> playerBoards(String playerId) {
    final country = playerCountry(playerId);
    final out = <PlayerStats>[];
    for (final row in _playerBoards.select([playerId])) {
      final games = row['c'] as int;
      if (games == 0) continue;
      final balls = row['balls'] as int;
      final best = row['best'] as int;
      int? countryBest;
      int? countryRank;
      if (country != null) {
        final national = _playerScoresInCountry.select([
          playerId,
          balls,
          country,
        ]).first;
        if ((national['c'] as int) > 0) {
          countryBest = national['best'] as int;
          countryRank = rank(countryBest, country: country, balls: balls);
        }
      }
      out.add(
        PlayerStats(
          games: games,
          balls: balls,
          bestScore: best,
          rank: rank(best, balls: balls),
          country: country,
          countryBestScore: countryBest,
          countryRank: countryRank,
        ),
      );
    }
    return out;
  }

  /// Games submitted, best score and rank for [playerId] on the [balls] board,
  /// plus the same within the player's own country (SPEC §4.6).
  ///
  /// An empty board is `games: 0` with no rank, exactly as a player who has
  /// submitted nothing at all is.
  PlayerStats playerScores(String playerId, {int balls = 1}) {
    for (final board in playerBoards(playerId)) {
      if (board.balls == balls) return board;
    }
    return PlayerStats(games: 0, balls: balls);
  }

  /// The country of [playerId]'s most recent run that carried one, or null
  /// (SPEC §4.6).
  String? playerCountry(String playerId) {
    final rows = _playerCountry.select([playerId]);
    return rows.isEmpty ? null : rows.first['country'] as String?;
  }

  /// Attaches the verified provider account ([provider], [subject]) to a
  /// player and hands back credentials for it — the whole of SPEC §4.5's
  /// link / restore / merge, in one transaction.
  ///
  /// [callerPlayerId] is the already-authenticated anonymous player, or null
  /// when the caller has no credentials (a fresh install signing in, which is
  /// how an account is restored onto a second device). [tokenHash] and
  /// [tokenExpiresAt] identify the identity token in the replay ledger;
  /// [credentialId] and [secretHash] are the credential to issue, generated by
  /// the caller so that no randomness is needed on this isolate.
  ///
  /// Retry safety, which matters because a phone on a flaky network will retry:
  ///
  /// * the ledger is consulted first, so presenting the same token twice
  ///   resolves to the same player both times — even if the second call carries
  ///   somebody else's credentials, which is what a replayed token looks like;
  /// * the second call rotates the credential the first one issued rather than
  ///   piling up a new one;
  /// * a merge moves the absorbed player's credentials to the survivor, so the
  ///   caller's stored secret still authenticates afterwards and a retry that
  ///   uses it is an ordinary restore rather than a `401`.
  AccountLinkResult linkAccount(AccountLinkRequest request) {
    final provider = request.provider;
    final subject = request.subject;
    final tokenHash = request.tokenHash;
    final credentialId = request.credentialId;
    final secretHash = request.secretHash;
    final stamp = formatTimestamp(request.now);
    return _transact(() {
      _pruneTokenUses.execute([
        formatTimestamp(request.now.toUtc().subtract(tokenUseRetention)),
      ]);

      final replay = _tokenUse.select([tokenHash]);
      if (replay.isNotEmpty) {
        final pinned = replay.first['player_id'] as String;
        final previous = replay.first['credential_id'] as String?;
        final survivor = playerById(pinned);
        if (survivor != null) {
          // Rotate rather than accumulate: the credential the earlier use
          // issued was, by definition, not received by the caller.
          if (previous != null) _deleteSecret.execute([previous]);
          _addSecret.execute([credentialId, pinned, secretHash, stamp]);
          _trimSecrets.execute([pinned, pinned, maxPlayerSecrets]);
          _recordTokenUse.execute([
            tokenHash,
            provider,
            subject,
            pinned,
            credentialId,
            stamp,
            formatTimestamp(request.tokenExpiresAt),
          ]);
          _setLastSeen.execute([stamp, pinned]);
          return AccountLinkResult.done(
            kind: AccountLinkKind.retried,
            playerId: pinned,
            createdAt: survivor.createdAt,
            linkedAt: survivor.accountLinkedAt ?? stamp,
            name: survivor.name,
          );
        }
        // The pinned player has since been deleted; the ledger row is stale.
        _deleteTokenUsesOf.execute([pinned]);
      }

      final owner = playerByAccount(provider, subject);
      final callerId = request.callerPlayerId;
      final caller = callerId == null ? null : playerById(callerId);

      final AccountLinkKind kind;
      final String survivorId;
      var moved = 0;

      if (caller == null && owner == null) {
        // Nobody to attach to and nobody owns the account yet.
        final fresh = request.newPlayerId;
        _insertPlayer.execute([fresh, stamp, stamp, null]);
        _linkAccount.execute([provider, subject, stamp, stamp, fresh]);
        survivorId = fresh;
        kind = AccountLinkKind.created;
      } else if (caller == null) {
        // Restore: the account exists, the caller just has no credential yet.
        survivorId = owner!.id;
        kind = AccountLinkKind.restored;
      } else if (owner == null) {
        if (caller.hasAccount) {
          return AccountLinkResult.alreadyLinked(caller.accountProvider!);
        }
        _linkAccount.execute([provider, subject, stamp, stamp, caller.id]);
        survivorId = caller.id;
        kind = AccountLinkKind.linked;
      } else if (owner.id == caller.id) {
        survivorId = caller.id;
        kind = AccountLinkKind.restored;
      } else {
        // Two rows, one person. The account's player survives: it is the
        // identity the player's other devices already authenticate as, while
        // the caller is this install's local anonymous player.
        if (caller.hasAccount) {
          return AccountLinkResult.alreadyLinked(caller.accountProvider!);
        }
        _moveScores.execute([owner.id, caller.id]);
        moved = _db.updatedRows;
        // The absorbed player's credentials move across rather than dying with
        // it. Without this, a merge would silently invalidate the secret the
        // calling device had stored, and a retry after a lost response — the
        // thing a phone on a flaky network does — would be refused at
        // authentication before the replay ledger was ever consulted. They
        // belong to the same person either way.
        _moveSecrets.execute([owner.id, caller.id]);
        _moveTokenUses.execute([owner.id, caller.id]);
        // The wallet, the purchases, the slot choices and the earning ledger
        // belong to the person, not to the row (SPEC §4.8).
        _mergeShopState(owner.id, caller.id, stamp);
        // The absorbed id keeps resolving to the survivor, so the calling
        // device's stored `<playerId>:<secret>` goes on working and the retry of
        // this very call authenticates instead of being refused.
        _repointAliases.execute([owner.id, caller.id]);
        _addAlias.execute([caller.id, owner.id, stamp]);
        _deletePlayer.execute([caller.id]);
        // Nothing is chosen between the two best scores because no row is
        // dropped: every run moves across, so the surviving best is the better
        // of the two by construction. The display name keeps following the
        // last name actually played under (SPEC §4.4), now across the union,
        // and the account is as old as the older of the two halves.
        final newest = _newestScoreName.select([owner.id]);
        _setPlayerFacts.execute([
          newest.isNotEmpty
              ? newest.first['name'] as String
              : (owner.name ?? caller.name),
          _earlier(owner.createdAt, caller.createdAt),
          stamp,
          owner.id,
        ]);
        survivorId = owner.id;
        kind = AccountLinkKind.merged;
      }

      _addSecret.execute([credentialId, survivorId, secretHash, stamp]);
      _trimSecrets.execute([survivorId, survivorId, maxPlayerSecrets]);
      _recordTokenUse.execute([
        tokenHash,
        provider,
        subject,
        survivorId,
        credentialId,
        stamp,
        formatTimestamp(request.tokenExpiresAt),
      ]);
      if (kind != AccountLinkKind.created) {
        _setLastSeen.execute([stamp, survivorId]);
      }

      final survivor = playerById(survivorId)!;
      return AccountLinkResult.done(
        kind: kind,
        playerId: survivorId,
        createdAt: survivor.createdAt,
        linkedAt: survivor.accountLinkedAt ?? stamp,
        name: survivor.name,
        movedScores: moved,
      );
    });
  }

  /// Detaches the provider account from [playerId]. The player and every score
  /// it owns stay exactly as they are; it is simply anonymous again.
  ///
  /// Its ledger rows go too, so a token captured before the unlink cannot walk
  /// back in through the retry path. Returns whether an account was attached.
  bool unlinkAccount(String playerId) => _transact(() {
    _unlinkAccount.execute([playerId]);
    final unlinked = _db.updatedRows > 0;
    _deleteTokenUsesOf.execute([playerId]);
    return unlinked;
  });

  /// Deletes [playerId] and anonymises the scores it owned (SPEC §4.5).
  ///
  /// The runs stay on the leaderboard with `player_id = NULL`, exactly like a
  /// row submitted without credentials: deleting them instead would silently
  /// restate everyone else's rank, and a verified score is a fact about the
  /// board rather than a fact about the person. What goes is every link
  /// between the person and those rows — the account, the credentials and the
  /// ledger.
  ///
  /// Returns the number of score rows anonymised.
  int deletePlayer(String playerId) => _transact(() {
    _anonymiseScores.execute([playerId]);
    final anonymised = _db.updatedRows;
    _deleteSecretsOf.execute([playerId]);
    _deleteTokenUsesOf.execute([playerId]);
    // The shop state goes with the player (SPEC §4.8): a wallet, a shelf of
    // cosmetics and a record of which runs paid for them are all links between
    // the person and their play, and this is the request to remove those.
    _deleteWalletOf.execute([playerId]);
    _deleteItemsOf.execute([playerId]);
    _deleteEquippedOf.execute([playerId]);
    _deleteAwardsOf.execute([playerId]);
    // The purchase ledger goes with the player as well (SPEC §4.9), and with it
    // premium, because premium *is* that ledger. It is a record of what this
    // person bought, and a deletion request is a request to remove it. The store
    // keeps its own receipt, so nothing is lost that matters: a refund still
    // works through Apple or Google, a refund webhook that arrives afterwards
    // finds no row and is acknowledged with nothing to do, and the person can
    // recover the unlock on a new player with "restore purchases", which asks
    // RevenueCat rather than us.
    _deletePurchasesOf.execute([playerId]);
    // The ad-reward ledger goes too (SPEC §4.10), for the same reason: it is a
    // record of what this person watched and when. A callback that arrives
    // afterwards finds no player and is refused, which is the right answer —
    // there is no wallet left to credit.
    _deleteAdRewardsOf.execute([playerId]);
    // Both directions: the aliases aimed at this player, and its own alias if
    // it was itself absorbed by someone.
    _deleteAliasesOf.execute([playerId, playerId]);
    _deletePlayer.execute([playerId]);
    return anonymised;
  });

  // --------------------------------------------- cosmetic items (SPEC §4.8)

  /// Everything the shop needs about one player, in a single hop to this
  /// isolate: balance, lifetime totals, bought items, stored slot choices and
  /// what the player has already earned today.
  ///
  /// [now] decides which UTC day the daily cap is measured over; it is passed in
  /// rather than read here so the whole operation stays a pure function of its
  /// inputs and a test can move the clock.
  PlayerInventory inventoryOf(String playerId, {required DateTime now}) {
    final wallet = _wallet.select([playerId]);
    return PlayerInventory(
      balance: wallet.isEmpty ? 0 : wallet.first['balance'] as int,
      earnedTotal: wallet.isEmpty ? 0 : wallet.first['earned_total'] as int,
      spentTotal: wallet.isEmpty ? 0 : wallet.first['spent_total'] as int,
      purchasedTotal: wallet.isEmpty
          ? 0
          : wallet.first['purchased_total'] as int,
      adTotal: wallet.isEmpty ? 0 : wallet.first['ad_total'] as int,
      ownedItemIds: _boughtItems(playerId),
      equipped: _equippedSlots(playerId),
      earnedToday: _earnedOn(playerId, utcDay(now)),
      premium: isPremium(playerId),
    );
  }

  /// Whether [playerId] holds the one-time unlock (SPEC §4.9).
  ///
  /// **Premium is ownership, answered rather than stored.** It is one lookup for a
  /// live (un-refunded) row of [FullUnlock.productId] in the purchase ledger, and
  /// it is deliberately *not* a set of `player_items` rows written when the
  /// purchase lands. Three things follow from that, and all three are the reason
  /// for it:
  ///
  /// * a cosmetic added to [Catalogue.items] next year is covered the moment it
  ///   exists, with nothing to backfill for anybody who already paid;
  /// * a refund is one stamped column, not a sweep of rows to unpick — so it
  ///   cannot possibly take away an item the player *also* bought with Sparks,
  ///   because it never looks at `player_items` at all;
  /// * there is exactly one place that decides the entitlement, so the shop, the
  ///   equip check and the ad offer cannot drift apart.
  bool isPremium(String playerId) =>
      _liveUnlockOf.select([playerId, FullUnlock.productId]).isNotEmpty;

  /// Whether [playerId] may use [itemId]: every free item, everything at all if
  /// they are premium, plus whatever they bought. False for an id this build does
  /// not have.
  bool ownsItem(String playerId, String itemId) {
    final item = Catalogue.byId(itemId);
    if (item == null) return false;
    if (item.free) return true;
    if (isPremium(playerId)) return true;
    return _ownsItem.select([playerId, itemId]).isNotEmpty;
  }

  /// Buys [itemId] for [playerId], atomically (SPEC §4.8).
  ///
  /// The **price is looked up here**, from the server's own catalogue, inside
  /// the transaction. Nothing in the request can carry a price or a balance, so
  /// there is no number a client could send that this method would believe.
  ///
  /// Four outcomes, all of them ordinary answers:
  ///
  /// * already owned (free, premium, or bought before) → success, nothing
  ///   charged, nothing written, so a buy retried after a lost response is safe
  ///   and does not charge twice — and so a premium player who reaches a buy
  ///   button at all (an old build, a stale cache) is told they own it rather
  ///   than being charged for something they already have;
  /// * balance short → [BuyOutcome.insufficientTokensError] with the price and
  ///   the balance, both the server's numbers;
  /// * unknown id → [BuyOutcome.unknownItemError];
  /// * otherwise the wallet is debited and the row written, in one transaction.
  ///
  /// The balance cannot go negative even under a burst of simultaneous buys:
  /// the debit is a conditional `UPDATE … WHERE balance >= price`, the db
  /// isolate runs one transaction at a time, and the column carries a CHECK as
  /// a backstop. Two concurrent buys therefore serialize, and the second sees
  /// the balance the first left behind.
  BuyOutcome buyItem({
    required String playerId,
    required String itemId,
    required DateTime now,
  }) {
    final item = Catalogue.byId(itemId);
    if (item == null) return BuyOutcome.unknownItem(itemId);
    return _transact(() {
      final stamp = formatTimestamp(now);
      final premium = isPremium(playerId);
      if (item.free ||
          premium ||
          _ownsItem.select([playerId, itemId]).isNotEmpty) {
        return BuyOutcome.done(
          itemId: itemId,
          price: item.priceTokens,
          charged: 0,
          alreadyOwned: true,
          balance: _balanceOf(playerId),
          ownedItemIds: _boughtItems(playerId),
          premium: premium,
        );
      }
      _debitWallet.execute([
        item.priceTokens,
        item.priceTokens,
        stamp,
        playerId,
        item.priceTokens,
      ]);
      if (_db.updatedRows == 0) {
        // No wallet row at all, or not enough in it: the same answer either
        // way, because "you have 0" and "you have 40 of 80" are the same fact.
        return BuyOutcome.insufficient(
          itemId: itemId,
          price: item.priceTokens,
          balance: _balanceOf(playerId),
        );
      }
      _addItem.execute([playerId, itemId, stamp, item.priceTokens]);
      return BuyOutcome.done(
        itemId: itemId,
        price: item.priceTokens,
        charged: item.priceTokens,
        alreadyOwned: false,
        balance: _balanceOf(playerId),
        ownedItemIds: _boughtItems(playerId),
        premium: premium,
      );
    });
  }

  /// Stores the player's slot choices (SPEC §4.8).
  ///
  /// Equipping is a **preference, not an entitlement**: it may only name items
  /// the player owns, and it grants nothing. Every named slot is validated
  /// before anything is written, so a call that names three slots and gets the
  /// third wrong changes none of them — a partial equip would leave the player
  /// wearing half of what they asked for.
  EquipOutcome equipItems(EquipRequest request) {
    final playerId = request.playerId;
    final premium = isPremium(playerId);
    for (final entry in request.slots.entries) {
      final kind = CosmeticKind.parse(entry.key);
      if (kind == null) return EquipOutcome.unknownKind(entry.key);
      final itemId = entry.value;
      if (itemId == null) continue; // back to the default: nothing to own.
      final item = Catalogue.byId(itemId);
      if (item == null) return EquipOutcome.unknownItem(itemId);
      if (item.kind != kind) return EquipOutcome.wrongKind(itemId);
      if (!item.free &&
          !premium &&
          _ownsItem.select([playerId, itemId]).isEmpty) {
        return EquipOutcome.notOwned(itemId);
      }
    }
    return _transact(() {
      final stamp = formatTimestamp(request.now);
      for (final entry in request.slots.entries) {
        final kind = CosmeticKind.parse(entry.key)!;
        final itemId = entry.value;
        if (itemId == null) {
          _clearEquipped.execute([playerId, kind.name]);
        } else {
          _setEquipped.execute([playerId, kind.name, itemId, stamp]);
        }
      }
      return EquipOutcome.done(
        equipped: _equippedSlots(playerId),
        ownedItemIds: _boughtItems(playerId),
        premium: premium,
      );
    });
  }

  /// Credits [playerId] for a run the server verified at [score] (SPEC §4.8).
  ///
  /// [score] is the score **this server computed** by re-simulating the replay;
  /// there is no parameter for a token amount, so no caller — present or future
  /// — can hand one in. The conversion is [TokenRate.forScoreWithinDay].
  ///
  /// [replayKey] is a digest of the run itself (`replayFingerprint`). It is the
  /// primary key of the ledger, which is what stops the same recorded game from
  /// being submitted for tokens over and over:
  ///
  /// * the same player re-submitting a run is told what that run earned the
  ///   first time and nothing is credited, so a phone retrying a lost response
  ///   sees the number it would have seen rather than a sudden 0;
  /// * anybody else submitting a copy of somebody's replay earns 0, because the
  ///   key is global — a leaked replay is worth nothing to whoever leaked it.
  ///
  /// A row is written **even when the award is 0**: a run that paid nothing
  /// because the day's cap was already full would otherwise still be worth
  /// re-submitting tomorrow.
  TokenAward awardTokens({
    required String playerId,
    required String scoreId,
    required int score,
    required String replayKey,
    required DateTime now,
  }) => _transact(() {
    final day = utcDay(now);
    final recorded = _awardByKey.select([replayKey]);
    if (recorded.isNotEmpty) {
      final owner = recorded.first['player_id'] as String;
      return TokenAward(
        tokens: owner == playerId ? recorded.first['tokens'] as int : 0,
        balance: _balanceOf(playerId),
        earnedToday: _earnedOn(playerId, day),
        duplicate: true,
      );
    }
    final earnedToday = _earnedOn(playerId, day);
    final tokens = TokenRate.forScoreWithinDay(
      score,
      alreadyEarnedToday: earnedToday,
    );
    final stamp = formatTimestamp(now);
    _insertAward.execute([
      replayKey,
      playerId,
      scoreId,
      score,
      tokens,
      day,
      stamp,
    ]);
    if (tokens > 0) {
      // Earned by playing, not bought and not watched: purchased_total and
      // ad_total are 0, and there is no argument to this method that could ever
      // make them anything else.
      _creditWallet.execute([playerId, tokens, tokens, 0, 0, 0, stamp]);
    }
    return TokenAward(
      tokens: tokens,
      balance: _balanceOf(playerId),
      earnedToday: earnedToday + tokens,
      cappedByDay: tokens < TokenRate.forScore(score),
    );
  });

  // ------------------------------------------- the one-time unlock (SPEC §4.9)

  /// Records a store payment RevenueCat confirmed, and with it grants premium
  /// (SPEC §4.9).
  ///
  /// **There is no parameter for what the purchase grants.** What it grants is
  /// decided here, from the product identifier, against [FullUnlock] — exactly as
  /// [buyItem] looks up a price rather than believing one. A product this build
  /// does not sell is refused rather than granted at a guess, so nothing a webhook
  /// body or a phone could say can unlock the catalogue; the caller supplies only
  /// identifiers and the two things the store decides (which product, which
  /// transaction).
  ///
  /// **The row *is* the entitlement.** Nothing else is written: no wallet, no
  /// `player_items`, no per-item backfill. [isPremium] answers from this row, so
  /// the grant covers every cosmetic that exists and every one added later, and
  /// taking it back is one column (see [revokePurchase]).
  ///
  /// **Idempotent on [PurchaseGrantRequest.transactionId]**, which is the store's
  /// own id for the payment. That is the property the whole feature rests on:
  /// RevenueCat retries a webhook until it is answered with a 2xx,
  /// `POST /api/purchases/sync` asks about the same purchase again on every
  /// restore, and both can be in flight at once. A second call therefore writes
  /// nothing and reports [PurchaseGrant.alreadyRecorded].
  ///
  /// A transaction already recorded against **another** player unlocks nothing for
  /// the caller. The unlock stays with the player who bought it, and the way a
  /// person moves it to another device is to sign in (SPEC §4.5) — which carries
  /// the player, and the ledger with it.
  ///
  /// Four outcomes, all ordinary answers: granted, already recorded, unknown
  /// product, unknown player.
  PurchaseGrant grantPurchase(PurchaseGrantRequest request) {
    final productId = request.productId;
    final playerId = request.playerId;
    if (!FullUnlock.isUnlock(productId)) {
      return PurchaseGrant.unknownProduct(productId);
    }
    return _transact(() {
      final existing = _purchaseByTransaction.select([request.transactionId]);
      if (existing.isNotEmpty) {
        return PurchaseGrant.alreadyRecorded(
          premium: isPremium(playerId),
          productId: existing.first['product_id'] as String,
          transactionId: request.transactionId,
        );
      }
      // Foreign keys are not enforced (no `PRAGMA foreign_keys`), so the player
      // is checked rather than assumed: a ledger row pointing at nobody is an
      // entitlement that can never be explained, and granting one to a player
      // that does not exist unlocks a catalogue for nobody while looking, from
      // RevenueCat's side, exactly like a success.
      if (_playerById.select([playerId]).isEmpty) {
        return const PurchaseGrant.unknownPlayer();
      }
      _insertPurchase.execute([
        request.transactionId,
        playerId,
        productId,
        request.store,
        request.environment,
        request.source,
        request.eventId,
        formatTimestamp(request.purchasedAt),
        formatTimestamp(request.now),
      ]);
      return PurchaseGrant.done(
        premium: isPremium(playerId),
        productId: productId,
        transactionId: request.transactionId,
      );
    });
  }

  /// Revokes a refunded or charged-back purchase (SPEC §4.9).
  ///
  /// One column: `refunded_at` is stamped, the row stops being a live unlock, and
  /// [isPremium] answers false from the next call on. Nothing else moves.
  ///
  /// **What happens to cosmetics the player also bought with Sparks**, which is
  /// the decision this method encodes: *nothing*. They stay. Those were paid for
  /// separately, with Sparks earned by playing or credited from a watched ad, and
  /// a refund of the unlock is not a claim on them. This is not a rule applied
  /// carefully — it is a rule that cannot be broken, because premium was never
  /// rows in `player_items` and this method does not so much as read that table.
  /// A player who paid, bought two extra looks with earned Sparks and then
  /// refunded keeps exactly those two looks and loses the rest.
  ///
  /// The wallet is not touched either, because the unlock never credited a Spark.
  /// There is no clawback, no shortfall and no floored balance to reason about —
  /// the whole class of problem that a refunded *currency* pack created is simply
  /// absent from this design, which is one of the better reasons for it.
  ///
  /// An equipped item the revoke has just made un-owned is **not** cleared here.
  /// The stored preference stays, and the service layer answers that slot with its
  /// free default while the player cannot use it (see `shop.dart`), exactly as it
  /// does for an item a client is too old to draw — so the choice comes back
  /// intact if the player buys the item with Sparks or buys the unlock again.
  ///
  /// Idempotent on the row for the same reason granting is: refund webhooks are
  /// retried, and a second pass must not re-date a revocation that already
  /// happened.
  PurchaseRevoke revokePurchase({
    required String transactionId,
    required DateTime now,
  }) => _transact(() {
    final rows = _purchaseByTransaction.select([transactionId]);
    if (rows.isEmpty) return const PurchaseRevoke.unknownTransaction();
    final row = rows.first;
    final playerId = row['player_id'] as String;
    final productId = row['product_id'] as String;
    if (row['refunded_at'] != null) {
      return PurchaseRevoke.alreadyRevoked(
        playerId: playerId,
        productId: productId,
        premium: isPremium(playerId),
      );
    }
    _markRefunded.execute([formatTimestamp(now), transactionId]);
    return PurchaseRevoke.done(
      playerId: playerId,
      productId: productId,
      // Read *after* the stamp, and deliberately not assumed to be false: a
      // player who bought the unlock on two stores holds two live rows, and
      // refunding one of them leaves the other standing.
      premium: isPremium(playerId),
    );
  });

  /// [playerId]'s purchases, newest first (SPEC §4.9).
  ///
  /// This is what makes premium explainable — "you have everything because of
  /// this payment, on this date, through this store" — and what a restore has to
  /// show instead of a spinner. Bounded by [limit] because it is answered to a
  /// phone.
  List<PurchaseRecord> purchasesOf(String playerId, {int limit = 50}) => [
    for (final row in _purchasesOf.select([playerId, limit]))
      _readPurchase(row),
  ];

  /// The ledger row for one store transaction, or null (support / tests).
  PurchaseRecord? purchaseByTransaction(String transactionId) {
    final rows = _purchaseByTransaction.select([transactionId]);
    return rows.isEmpty ? null : _readPurchase(rows.first);
  }

  /// Rows in `purchases` (diagnostics / tests).
  int get purchaseCount => _purchaseCount.select().first['c'] as int;

  static PurchaseRecord _readPurchase(Row row) => PurchaseRecord(
    transactionId: row['transaction_id'] as String,
    playerId: row['player_id'] as String,
    productId: row['product_id'] as String,
    store: row['store'] as String,
    environment: row['environment'] as String,
    source: row['source'] as String,
    eventId: row['event_id'] as String?,
    purchasedAt: row['purchased_at'] as String,
    creditedAt: row['credited_at'] as String,
    refundedAt: row['refunded_at'] as String?,
  );

  // ------------------------------------------- rewarded ads (SPEC §4.10)

  /// Credits [AdCreditRequest.playerId] for a rewarded ad Google's server-side
  /// verification callback confirmed (SPEC §4.10).
  ///
  /// **There is no parameter for an amount that is read.** The Sparks come from
  /// [AdRate], applied here, inside the transaction — exactly as
  /// [grantPurchase] reads the product rather than believing an event, and as
  /// [awardTokens] converts a score the server computed. The request does carry
  /// [AdCreditRequest.rewardAmount], and it is written to the ledger and never
  /// consulted: it is a number a human typed into the AdMob dashboard, and the
  /// economy is not configured from a web form.
  ///
  /// **Idempotent on [AdCreditRequest.transactionId]**, AdMob's own id for the
  /// reward and part of the content Google signs. A second call credits nothing
  /// and reports [AdCredit.alreadyCredited] — with what the reward paid when the
  /// row is this player's, and 0 when the row belongs to somebody else, because a
  /// reward that has paid one player must never pay a second.
  ///
  /// **The two bounds, both applied here rather than in the handler**, because
  /// only a transaction can make "read the day's total, decide, write" atomic:
  ///
  /// * the **daily cap** clips to what is left of [AdRate.dailyCap] for the UTC
  ///   day the ad was *watched* ([AdCreditRequest.rewardedAt], which Google
  ///   signed) rather than the day the callback arrived — so a late callback
  ///   counts against the right day and midnight cannot be farmed by delaying
  ///   one;
  /// * the **cooldown** pays 0 when the newest paying ad is less than
  ///   [AdRate.cooldown] away, measured as an absolute difference between two
  ///   signed timestamps. Absolute, so callbacks arriving out of order give the
  ///   same answer as callbacks arriving in order; on the signed timestamp, so a
  ///   network delay can never cost a player a reward they waited for.
  ///
  /// Either bound is an **ok** outcome, not an error: the ad has been watched,
  /// the callback is Google telling us so, and the honest record is a row saying
  /// what it paid and why. The client's job is to not offer an ad inside the
  /// cooldown in the first place ([adRewardState]); this is what makes a client
  /// that ignores that gain nothing by it.
  AdCredit creditAdReward(AdCreditRequest request) {
    final playerId = request.playerId;
    return _transact(() {
      final existing = _adRewardByTransaction.select([request.transactionId]);
      if (existing.isNotEmpty) {
        final row = existing.first;
        final owner = row['player_id'] as String;
        final mine = owner == playerId;
        return AdCredit.alreadyCredited(
          sparks: mine ? row['sparks'] as int : 0,
          balance: _balanceOf(playerId),
          earnedToday: _adSparksOn(playerId, row['day'] as String),
          placement: row['placement'] as String,
          transactionId: request.transactionId,
          refused: row['refused'] as String?,
        );
      }
      // Foreign keys are not enforced, so the player is checked rather than
      // assumed: a ledger row pointing at nobody is a balance that can never be
      // explained. Same reasoning as [grantPurchase].
      if (_playerById.select([playerId]).isEmpty) {
        return const AdCredit.unknownPlayer();
      }
      final day = utcDay(request.rewardedAt);
      final earnedToday = _adSparksOn(playerId, day);
      final int sparks;
      final String? refused;
      if (_withinAdCooldown(playerId, request.rewardedAt)) {
        sparks = 0;
        refused = AdRewardRow.cooldownRefusal;
      } else {
        sparks = AdRate.forAdWithinDay(alreadyEarnedToday: earnedToday);
        refused = sparks < AdRate.sparksPerAd
            ? AdRewardRow.dailyCapRefusal
            : null;
      }
      final stamp = formatTimestamp(request.now);
      _insertAdReward.execute([
        request.transactionId,
        playerId,
        request.placement,
        sparks,
        request.rewardAmount,
        request.rewardItem,
        request.adUnit,
        request.adNetwork,
        request.keyId,
        day,
        formatTimestamp(request.rewardedAt),
        stamp,
        refused,
      ]);
      if (sparks > 0) {
        // Watched, not played for and not bought: the fifth amount (ad_total) is
        // the only one that moves besides the balance, which is what keeps the
        // two daily caps from ever touching each other.
        _creditWallet.execute([playerId, sparks, 0, 0, 0, sparks, stamp]);
      }
      return AdCredit.done(
        sparks: sparks,
        balance: _balanceOf(playerId),
        earnedToday: earnedToday + sparks,
        placement: request.placement,
        transactionId: request.transactionId,
        refused: refused,
      );
    });
  }

  /// [playerId]'s ad allowance as of [now] (SPEC §4.10).
  ///
  /// Read-only, and the whole reason the client can hide the ad button instead of
  /// offering one that pays nothing.
  AdRewardState adRewardState(String playerId, {required DateTime now}) {
    final wallet = _wallet.select([playerId]);
    final newest = _newestPaidAdReward.select([playerId]);
    return AdRewardState(
      earnedToday: _adSparksOn(playerId, utcDay(now)),
      balance: wallet.isEmpty ? 0 : wallet.first['balance'] as int,
      adTotal: wallet.isEmpty ? 0 : wallet.first['ad_total'] as int,
      lastRewardedAt: newest.isEmpty
          ? null
          : DateTime.tryParse(newest.first['rewarded_at'] as String)?.toUtc(),
      // A premium player is offered no ads at all (SPEC §4.9). Answered from the
      // purchase ledger in the same hop, so there is one question and one place
      // that decides it.
      premium: isPremium(playerId),
    );
  }

  /// [playerId]'s ad rewards, newest first (SPEC §4.10).
  ///
  /// The third of the three halves of "explain this balance"; the others are
  /// `token_awards` and `purchases`. Bounded by [limit] because it is
  /// answered to a phone.
  List<AdRewardRow> adRewards(String playerId, {int limit = 50}) => [
    for (final row in _adRewardsOf.select([playerId, limit]))
      _readAdReward(row),
  ];

  /// The ledger row for one AdMob transaction, or null (support / tests).
  AdRewardRow? adReward(String transactionId) {
    final rows = _adRewardByTransaction.select([transactionId]);
    return rows.isEmpty ? null : _readAdReward(rows.first);
  }

  /// Rows in `ad_rewards` (diagnostics / tests).
  int get adRewardCount => _adRewardCount.select().first['c'] as int;

  static AdRewardRow _readAdReward(Row row) => AdRewardRow(
    transactionId: row['transaction_id'] as String,
    playerId: row['player_id'] as String,
    placement: row['placement'] as String,
    sparks: row['sparks'] as int,
    rewardAmount: row['reward_amount'] as int,
    rewardItem: row['reward_item'] as String,
    adUnit: row['ad_unit'] as String,
    adNetwork: row['ad_network'] as String,
    keyId: row['key_id'] as String,
    day: row['day'] as String,
    rewardedAt: row['rewarded_at'] as String,
    creditedAt: row['credited_at'] as String,
    refused: row['refused'] as String?,
  );

  int _adSparksOn(String playerId, String day) =>
      _adSparksOnDay.select([playerId, day]).first['t'] as int;

  /// Whether [rewardedAt] falls inside [AdRate.cooldown] of the newest ad that
  /// paid this player.
  bool _withinAdCooldown(String playerId, DateTime rewardedAt) {
    final rows = _newestPaidAdReward.select([playerId]);
    if (rows.isEmpty) return false;
    final previous = DateTime.tryParse(rows.first['rewarded_at'] as String);
    if (previous == null) return false;
    return rewardedAt.difference(previous.toUtc()).abs() < AdRate.cooldown;
  }

  /// [playerId]'s spendable balance; 0 when they have no wallet row yet.
  int walletBalance(String playerId) => _balanceOf(playerId);

  /// Rows in `player_items` / `token_awards` (diagnostics / tests).
  int get itemRowCount => _itemRowCount.select().first['c'] as int;
  int get awardCount => _awardCount.select().first['c'] as int;

  int _balanceOf(String playerId) {
    final rows = _wallet.select([playerId]);
    return rows.isEmpty ? 0 : rows.first['balance'] as int;
  }

  int _earnedOn(String playerId, String day) =>
      _earnedOnDay.select([playerId, day]).first['t'] as int;

  List<String> _boughtItems(String playerId) => [
    for (final row in _itemsOf.select([playerId])) row['item_id'] as String,
  ];

  Map<String, String> _equippedSlots(String playerId) => {
    for (final row in _equippedOf.select([playerId]))
      row['kind'] as String: row['item_id'] as String,
  };

  /// Carries an absorbed player's shop state to the survivor of a merge
  /// (SPEC §4.5, §4.8). Runs inside [linkAccount]'s transaction.
  ///
  /// Purchases and wallets belong to the **person**, and after a merge the two
  /// rows are one person, so both move across rather than dying with the
  /// absorbed player: someone who bought a theme on a second phone before
  /// signing in would otherwise watch it vanish the moment they did.
  ///
  /// The ledger moves too, and then the daily cap is re-applied to the union.
  /// Two halves that each earned a day's allowance are one person who earned
  /// two, so the excess is taken back off the balance. It is floored at 0 rather
  /// than carried as a debt, because a negative balance is not representable —
  /// which does leave a residue: tokens already **spent** cannot be reclaimed,
  /// so a determined farmer can concentrate a little more than a day's cap per
  /// absorbed player. That is bounded, it costs real play per player, and what
  /// it buys is a cosmetic: nothing here can move a leaderboard position, which
  /// is exactly why the economy is worth defending against casual abuse and not
  /// worth building a bank for.
  void _mergeShopState(String survivorId, String absorbedId, String stamp) {
    _copyItems.execute([survivorId, absorbedId]);
    _deleteItemsOf.execute([absorbedId]);

    final absorbed = _wallet.select([absorbedId]);
    if (absorbed.isNotEmpty) {
      _creditWallet.execute([
        survivorId,
        absorbed.first['balance'],
        absorbed.first['earned_total'],
        absorbed.first['spent_total'],
        absorbed.first['purchased_total'],
        absorbed.first['ad_total'],
        stamp,
      ]);
    }
    _deleteWalletOf.execute([absorbedId]);

    _copyEquipped.execute([survivorId, stamp, absorbedId]);
    _deleteEquippedOf.execute([absorbedId]);

    // The purchase ledger moves with the person too (SPEC §4.9), which is how
    // premium follows them: a player who paid on one phone and signs in on
    // another ends up with the live unlock row on the surviving id, and the
    // entitlement is answered from it with nothing to migrate. It also has to
    // move or a refund would later arrive for a row whose player no longer
    // exists.
    _movePurchases.execute([survivorId, absorbedId]);

    _moveAwards.execute([survivorId, absorbedId]);
    final excess =
        _dayExcess.select([
              TokenRate.dailyCap,
              survivorId,
              TokenRate.dailyCap,
            ]).first['excess']
            as int;
    if (excess > 0) {
      _clawBackTokens.execute([excess, excess, stamp, survivorId]);
    }

    // Ad rewards move with the person too (SPEC §4.10), and the ad daily cap is
    // re-applied to the union exactly as the play one is: two halves that each
    // watched a day of ads are one person who watched two days' worth, and the
    // cap is per person. Money is the deliberate exception above — what was paid
    // for stays paid for, and premium follows the person — but an ad allowance is
    // metered by the day precisely so that more devices cannot buy more of it.
    _moveAdRewards.execute([survivorId, absorbedId]);
    final adExcess =
        _adDayExcess.select([
              AdRate.dailyCap,
              survivorId,
              AdRate.dailyCap,
            ]).first['excess']
            as int;
    if (adExcess > 0) {
      _clawBackAdSparks.execute([adExcess, adExcess, stamp, survivorId]);
    }
  }

  /// Runs [body] in a transaction, rolling back if it throws.
  ///
  /// Reentrant, because SQLite has no nested `BEGIN`: an outer transaction
  /// simply carries the inner one, so a method that wraps itself can still be
  /// called from inside a larger operation.
  T _transact<T>(T Function() body) {
    if (_inTransaction) return body();
    _inTransaction = true;
    _db.execute('BEGIN');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      _inTransaction = false;
    }
  }

  bool _inTransaction = false;

  void close() {
    if (_closed) return;
    _closed = true;
    for (final statement in [
      _insert,
      _top,
      _topInCountry,
      _rank,
      _rankInCountry,
      _count,
      _playerCount,
      _insertPlayer,
      _playerById,
      _playerBySubject,
      _touchPlayer,
      _notePlayerScore,
      _setLastSeen,
      _playerBoards,
      _playerScoresInCountry,
      _playerCountry,
      _addSecret,
      _secretsOf,
      _trimSecrets,
      _deleteSecret,
      _deleteSecretsOf,
      _secretCount,
      _alias,
      _addAlias,
      _repointAliases,
      _deleteAliasesOf,
      _tokenUse,
      _recordTokenUse,
      _pruneTokenUses,
      _deleteTokenUsesOf,
      _tokenUseCount,
      _linkAccount,
      _unlinkAccount,
      _moveScores,
      _moveSecrets,
      _moveTokenUses,
      _anonymiseScores,
      _newestScoreName,
      _setPlayerFacts,
      _deletePlayer,
      _wallet,
      _creditWallet,
      _debitWallet,
      _deleteWalletOf,
      _itemsOf,
      _ownsItem,
      _addItem,
      _copyItems,
      _deleteItemsOf,
      _equippedOf,
      _setEquipped,
      _clearEquipped,
      _copyEquipped,
      _deleteEquippedOf,
      _awardByKey,
      _insertAward,
      _earnedOnDay,
      _moveAwards,
      _deleteAwardsOf,
      _dayExcess,
      _clawBackTokens,
      _purchaseByTransaction,
      _insertPurchase,
      _markRefunded,
      _liveUnlockOf,
      _purchasesOf,
      _movePurchases,
      _deletePurchasesOf,
      _purchaseCount,
      _adRewardByTransaction,
      _insertAdReward,
      _adSparksOnDay,
      _newestPaidAdReward,
      _adRewardsOf,
      _moveAdRewards,
      _deleteAdRewardsOf,
      _adRewardCount,
      _adDayExcess,
      _clawBackAdSparks,
      _itemRowCount,
      _awardCount,
    ]) {
      statement.close();
    }
    _db.close();
  }

  /// `YYYY-MM-DDTHH:MM:SSZ` (UTC, no fractional seconds) so that timestamps
  /// compare correctly as strings.
  static String formatTimestamp(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
        'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
  }

  /// The earlier of two [formatTimestamp] stamps; they are fixed-width UTC, so
  /// a string comparison is a chronological one.
  static String _earlier(String a, String b) => a.compareTo(b) <= 0 ? a : b;

  /// Inclusive lower bound on `created_at` for [period]; the empty string for
  /// [LeaderboardPeriod.all] (every timestamp sorts after it).
  static String periodLowerBound(LeaderboardPeriod period, [DateTime? now]) {
    final window = period.window;
    if (window == null) return '';
    return formatTimestamp((now ?? DateTime.now()).toUtc().subtract(window));
  }
}
