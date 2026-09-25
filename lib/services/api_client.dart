import 'dart:async';
import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:http/http.dart' as http;

enum LeaderboardPeriod { all, week, day }

enum ApiErrorKind {
  network,
  timeout,
  badResponse,
  server,

  /// `401`: the credentials were missing or refused (SPEC §4.4). The call
  /// changed nothing server side.
  unauthorized,

  /// `429`: over the per-IP budget. [ApiException.retryAfter] carries the
  /// server's own `retry-after` when it sent one.
  rateLimited,
}

/// The server error code the client acts on rather than merely shows: a stored
/// secret that no longer works (SPEC §4.4).
const String invalidCredentialsError = 'invalid_credentials';

/// The nickname filter of SPEC §4.7 refused the name. The run itself was fine,
/// so the player is asked for another name rather than told their score is bad.
const String offensiveNameError = 'offensive_name';

/// Thrown for a call that produced no usable answer: a transport failure, a
/// timeout, a refused credential, rate limiting or a 5xx.
class ApiException implements Exception {
  const ApiException(
    this.kind,
    this.message, {
    this.statusCode,
    this.errorCode,
    this.detail,
    this.retryAfter,
  });

  final ApiErrorKind kind;
  final String message;
  final int? statusCode;

  /// The `error` field of the server's documented `{"ok":false,…}` body, when
  /// it sent one (`invalid_credentials`, `rate_limited`, `invalid_country`…).
  final String? errorCode;

  /// The one extra field a documented refusal carries next to its code: the
  /// `provider` of `409 already_linked`, the `reason` of `401 invalid_token`
  /// (SPEC §4.5) or a `detail` string. Null when the body carried none.
  final String? detail;

  /// How long the server asked us to wait, from its `retry-after` header.
  final Duration? retryAfter;

  bool get isOffline =>
      kind == ApiErrorKind.network || kind == ApiErrorKind.timeout;

  /// The credentials we sent are not usable: SPEC §4.4 answers `401` for a
  /// malformed header, an unknown player and a wrong secret alike, and stores
  /// nothing either way.
  bool get isUnauthorized => kind == ApiErrorKind.unauthorized;

  @override
  String toString() =>
      'ApiException($kind, $message, status=$statusCode, code=$errorCode)';
}

/// What `POST /api/account/link` did (SPEC §4.5). `unknown` covers an
/// `outcome` string a later server grows and this build has not heard of: the
/// link itself still happened, so it is reported as a plain success.
enum AccountLinkOutcome { created, linked, restored, merged, retried, unknown }

/// The `200` body of `POST /api/account/link` (SPEC §4.5).
///
/// [credentials] **replace** whatever the app had stored: a link always issues a
/// new credential, and a merge can answer with a different surviving player id
/// than the one that was sent.
class AccountLink {
  const AccountLink({
    required this.credentials,
    required this.provider,
    required this.outcome,
    this.name,
    this.movedScores = 0,
    this.bestScore,
    this.rank,
    this.games = 0,
    this.country,
    this.countryBestScore,
    this.countryRank,
    this.linkedAt,
    this.createdAt,
  });

  final PlayerCredentials credentials;

  /// `apple` or `google`, as the server named it back.
  final String provider;
  final AccountLinkOutcome outcome;
  final String? name;

  /// Runs carried over from the player this one absorbed; 0 unless [outcome] is
  /// [AccountLinkOutcome.merged].
  final int movedScores;

  final int? bestScore;
  final int? rank;
  final int games;
  final String? country;
  final int? countryBestScore;
  final int? countryRank;
  final DateTime? linkedAt;
  final DateTime? createdAt;

  /// The standing this answer carries, in the shape `GET /api/players/me`
  /// returns — a merge changes it, so it is worth taking from here instead of
  /// spending another round trip on it.
  PlayerProfile toProfile() => PlayerProfile(
    id: credentials.id,
    name: name,
    bestScore: bestScore,
    rank: rank,
    games: games,
    country: country,
    countryBestScore: countryBestScore,
    countryRank: countryRank,
    provider: provider,
    linkedAt: linkedAt,
    createdAt: createdAt,
  );

  /// Null when the body carries no usable credential, which is the one thing
  /// this answer exists to deliver.
  static AccountLink? fromJson(Map<String, dynamic> j) {
    final credentials = PlayerCredentials.fromJson(j);
    if (credentials == null) return null;
    final provider = j['provider'];
    if (provider is! String || provider.isEmpty) return null;
    return AccountLink(
      credentials: credentials,
      provider: provider,
      outcome: outcomeByName(j['outcome'] as String?),
      name: j['name'] as String?,
      movedScores: (j['movedScores'] as num?)?.toInt() ?? 0,
      bestScore: (j['bestScore'] as num?)?.toInt(),
      rank: (j['rank'] as num?)?.toInt(),
      games: (j['games'] as num?)?.toInt() ?? 0,
      country: j['country'] as String?,
      countryBestScore: (j['countryBestScore'] as num?)?.toInt(),
      countryRank: (j['countryRank'] as num?)?.toInt(),
      linkedAt: DateTime.tryParse(j['linkedAt'] as String? ?? ''),
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    );
  }

  static AccountLinkOutcome outcomeByName(String? name) {
    for (final outcome in AccountLinkOutcome.values) {
      if (outcome.name == name) return outcome;
    }
    return AccountLinkOutcome.unknown;
  }
}

/// A player identity issued by `POST /api/players` (SPEC §4.4).
///
/// The secret is returned exactly once and the server keeps only a salted
/// digest of it, so it is never logged and never put in `shared_preferences`
/// (see `SecretStore`). [toString] redacts it on purpose: an accidental
/// `print(credentials)` must not be the leak.
class PlayerCredentials {
  const PlayerCredentials({required this.id, required this.secret});

  /// 32 lowercase hex characters.
  final String id;

  /// base64url, 43 characters as issued (§4.4 accepts 16–128).
  final String secret;

  /// The `Authorization` header value: `Arco <playerId>:<secret>`.
  String get header => 'Arco $id:$secret';

  /// True for a well-formed id / secret pair. Checked before a stored value is
  /// used, so a truncated or corrupted keychain entry becomes an anonymous
  /// submission instead of a guaranteed `401`.
  static bool wellFormed(String? id, String? secret) {
    if (id == null || secret == null) return false;
    if (!_idPattern.hasMatch(id)) return false;
    if (secret.length < 16 || secret.length > 128) return false;
    return _secretPattern.hasMatch(secret);
  }

  /// 32 lowercase hex characters (SPEC §4.4).
  static final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');

  /// base64url without padding, which is why `:` can never occur in either half
  /// of the header.
  static final RegExp _secretPattern = RegExp(r'^[A-Za-z0-9_-]+$');

  /// Reads the `201` body of `POST /api/players` (or of `POST /api/account/link`,
  /// which issues a credential the same way); null when it is not usable.
  static PlayerCredentials? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final secret = j['secret'];
    if (id is! String || secret is! String) return null;
    if (!wellFormed(id, secret)) return null;
    return PlayerCredentials(id: id, secret: secret);
  }

  @override
  String toString() => 'PlayerCredentials($id, secret: <redacted>)';
}

/// `GET /api/players/me` (SPEC §4.4 / §4.6): what the player owns and where
/// they stand, globally and nationally.
class PlayerProfile {
  const PlayerProfile({
    required this.id,
    this.name,
    this.bestScore,
    this.rank,
    this.games = 0,
    this.country,
    this.countryBestScore,
    this.countryRank,
    this.provider,
    this.linkedAt,
    this.createdAt,
  });

  final String id;
  final String? name;

  /// Best verified score and its global all-time rank; both null exactly when
  /// [games] is 0.
  final int? bestScore;
  final int? rank;
  final int games;

  /// National standing (SPEC §4.6): the country of the player's newest run
  /// that carried one, their best score *that counts for it*, and its rank
  /// there. The three are null together.
  final String? country;
  final int? countryBestScore;
  final int? countryRank;

  /// The linked sign-in provider (`apple`/`google`), null while anonymous.
  final String? provider;
  final DateTime? linkedAt;
  final DateTime? createdAt;

  bool get hasAccount => provider != null;

  factory PlayerProfile.fromJson(Map<String, dynamic> j) => PlayerProfile(
    id: '${j['id'] ?? ''}',
    name: j['name'] as String?,
    bestScore: (j['bestScore'] as num?)?.toInt(),
    rank: (j['rank'] as num?)?.toInt(),
    games: (j['games'] as num?)?.toInt() ?? 0,
    country: j['country'] as String?,
    countryBestScore: (j['countryBestScore'] as num?)?.toInt(),
    countryRank: (j['countryRank'] as num?)?.toInt(),
    provider: j['provider'] as String?,
    linkedAt: DateTime.tryParse(j['linkedAt'] as String? ?? ''),
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
  );
}

class HealthInfo {
  const HealthInfo({
    required this.ok,
    required this.version,
    required this.rooms,
    this.accounts = const <String>[],
    this.purchases = false,
  });
  final bool ok;
  final String version;
  final int rooms;

  /// Sign-in providers this deployment actually accepts (SPEC §4.5); empty
  /// means the feature is off, so a client offers no sign-in at all.
  final List<String> accounts;

  /// Whether this deployment can take money at all (SPEC §4.9). False means the
  /// shop offers no unlock, for the same reason an empty [accounts] means no
  /// sign-in buttons: the app offers exactly what will work.
  final bool purchases;
}

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.rank,
    required this.name,
    required this.score,
    required this.seconds,
    required this.createdAt,
    this.id,
    this.playerId,
    this.country,
  });

  final int rank;
  final String name;
  final int score;
  final int seconds;
  final DateTime? createdAt;

  /// Server id of the entry when the server includes it (optional in SPEC).
  final String? id;

  /// The player this run belongs to (SPEC §4.4), or null for an anonymous run —
  /// which is what every row stored before player identity existed is. This is
  /// how own entries are highlighted; the locally remembered submissions stay
  /// as the fallback for the anonymous ones.
  final String? playerId;

  /// Country the run counts for (SPEC §4.6); absent means unknown.
  final String? country;

  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) => LeaderboardEntry(
    rank: (j['rank'] as num).toInt(),
    name: j['name'] as String,
    score: (j['score'] as num).toInt(),
    seconds: (j['seconds'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    id: j['id'] as String?,
    playerId: j['playerId'] as String?,
    country: j['country'] as String?,
  );
}

/// Result of `POST /api/scores`. [ok] is true for a 201; otherwise [error]
/// carries the server's error code (or a synthetic one for 413/429 and for an
/// answer that cannot be read as a verdict).
class SubmitResult {
  const SubmitResult.accepted({
    required this.id,
    required this.score,
    required this.rank,
    this.playerId,
    this.country,
    this.countryRank,
    this.tokens,
    this.tokenBalance,
  }) : ok = true,
       error = null,
       statusCode = 201,
       shouldRetryLater = false;

  /// The server's own verdict on the replay: SPEC §4 documents a 400 with an
  /// error code, 413 for an oversized body and the temporary 429.
  const SubmitResult.rejected({required this.error, required this.statusCode})
    : ok = false,
      id = null,
      score = 0,
      rank = 0,
      playerId = null,
      country = null,
      countryRank = null,
      tokens = null,
      tokenBalance = null,
      shouldRetryLater = statusCode == 429;

  /// `401 invalid_credentials` (SPEC §4.4): the credentials we sent are not
  /// usable and **nothing was stored**. The run is untouched, so the caller
  /// re-issues an identity and submits it again rather than losing the score.
  const SubmitResult.unauthorized({required this.error})
    : ok = false,
      id = null,
      score = 0,
      rank = 0,
      playerId = null,
      country = null,
      countryRank = null,
      tokens = null,
      tokenBalance = null,
      statusCode = 401,
      shouldRetryLater = true;

  /// An answer that says nothing about the replay: a 2xx or 4xx that did not
  /// come from the server at all (a captive portal answering with HTML, an
  /// authenticating proxy, a mistyped server URL in Settings). The score is
  /// still good, so it is kept and retried — SPEC §5.1 promises
  /// "saved locally, will retry".
  const SubmitResult.indeterminate({
    required this.error,
    required this.statusCode,
  }) : ok = false,
       id = null,
       score = 0,
       rank = 0,
       playerId = null,
       country = null,
       countryRank = null,
       tokens = null,
       tokenBalance = null,
       shouldRetryLater = true;

  final bool ok;
  final String? id;
  final int score;
  final int rank;
  final String? error;
  final int statusCode;

  /// The player the run was filed under (SPEC §4.4). Absent when the submission
  /// was anonymous — and, on a merge, possibly a different id than the one we
  /// authenticated with, which the client then stores in its place (§4.5).
  final String? playerId;

  /// The country the run was filed under and its rank there (SPEC §4.6). Both
  /// present exactly when the country hint we sent was accepted, which is how
  /// the client learns it was sending something unusable.
  final String? country;
  final int? countryRank;

  /// What this run paid into the shop wallet and what the wallet holds
  /// afterwards (SPEC §4.8). Both null for an anonymous submission, which has no
  /// wallet — and both are the **server's** numbers, computed from the score it
  /// verified rather than from the score that was claimed.
  final int? tokens;
  final int? tokenBalance;

  /// The stored secret is stale: discard it, issue a new identity and submit
  /// this same replay once more.
  bool get isUnauthorized =>
      statusCode == 401 && error == invalidCredentialsError;

  /// The name was refused by the filter of SPEC §4.7. The replay is good; only
  /// the nickname has to change.
  bool get isOffensiveName => error == offensiveNameError;

  /// The answer does not settle the replay's fate (rate limiting, or a reply
  /// we cannot interpret); the replay should be kept and retried later.
  final bool shouldRetryLater;
}

/// One catalogue entry, exactly as `GET /api/shop/catalogue` reports it
/// (SPEC §4.8, `server/lib/src/catalogue.dart`).
///
/// **Everything here is cosmetic.** There is no field an item could use to
/// change the simulation, and there must never be one: the server re-verifies
/// every solo replay, so an item that moved a paddle would make honest runs fail
/// verification, and a leaderboard money can climb is worth nothing.
///
/// Nothing in this class is computed on the phone. The price, the free flag and
/// the ownership come from the server, which is also the only place they can be
/// trusted.
class ShopItem {
  const ShopItem({
    required this.id,
    required this.kind,
    required this.priceTokens,
    required this.free,
    required this.nameKey,
    required this.owned,
  });

  /// The stable catalogue id: `theme.glass`, `ball.comet`, `paddle.halo`.
  final String id;

  /// `theme`, `ball` or `paddle` — the slot this item goes in. Kept as the
  /// server's own string so a kind this build has never heard of is still
  /// readable rather than a crash.
  final String kind;

  /// Price in tokens. The server's number; the client never invents one.
  final int priceTokens;

  /// Costs nothing and is therefore owned by everybody.
  final bool free;

  /// `Strings` key of the display name; the server sets it to the item id, so
  /// `Strings.t(item.nameKey)` is the translated name.
  final String nameKey;

  /// Whether the caller owns it (free items included).
  final bool owned;

  static ShopItem? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final kind = j['kind'];
    if (id is! String || id.isEmpty || kind is! String || kind.isEmpty) {
      return null;
    }
    return ShopItem(
      id: id,
      kind: kind,
      priceTokens: (j['priceTokens'] as num?)?.toInt() ?? 0,
      free: j['free'] == true,
      nameKey: j['nameKey'] as String? ?? id,
      owned: j['owned'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'priceTokens': priceTokens,
    'free': free,
    'nameKey': nameKey,
    'owned': owned,
  };
}

/// The one-time unlock as the server advertises it (SPEC §4.9): a **store
/// product**, priced in money by Apple or Google.
///
/// **There is no price here, and there must never be one.** The only honest price
/// is the one the device's own store reports — localised, tax-inclusive, per
/// market, and changeable without a deploy. What the server owns is the other half
/// of the deal: *what the purchase grants*, which is not a number at all. A price
/// in this class would be a number this app invented about somebody's money.
///
/// The catalogue carries no unlock at all when the deployment sells nothing, and
/// none once the player is already premium — in both cases there is nothing to
/// offer, and the shop draws no offer rather than a button that cannot work.
class UnlockProduct {
  const UnlockProduct({required this.productId, required this.nameKey});

  /// The store product identifier: the same string in App Store Connect, in the
  /// Play Console and in RevenueCat. It is what the store is asked for, and what
  /// the server's own table turns into premium.
  final String productId;

  /// `Strings` key of the display name (`unlock.full`).
  final String nameKey;

  static UnlockProduct? fromJson(Map<String, dynamic> j) {
    final productId = j['productId'];
    if (productId is! String || productId.isEmpty) return null;
    return UnlockProduct(
      productId: productId,
      nameKey: j['nameKey'] as String? ?? productId,
    );
  }

  Map<String, dynamic> toJson() => {'productId': productId, 'nameKey': nameKey};
}

/// One row of the purchase ledger, as `POST /api/purchases/sync` reports it
/// (SPEC §4.9).
///
/// It exists so that "why is everything unlocked" has an answer on the device
/// asking the question, and so Restore Purchases can show something true instead
/// of a spinner and a shrug.
class PurchaseRecord {
  const PurchaseRecord({
    required this.transactionId,
    required this.productId,
    required this.refunded,
    this.store = '',
    this.purchasedAt,
  });

  /// The store's own transaction id — what a player reads off their receipt.
  final String transactionId;

  final String productId;

  /// Whether a refund or a chargeback has revoked it. A refunded row stays in
  /// the ledger: it is a record of a payment that happened, not of an
  /// entitlement.
  final bool refunded;

  final String store;
  final DateTime? purchasedAt;

  static PurchaseRecord? fromJson(Map<String, dynamic> j) {
    final transactionId = j['transactionId'];
    if (transactionId is! String || transactionId.isEmpty) return null;
    return PurchaseRecord(
      transactionId: transactionId,
      productId: j['productId'] as String? ?? '',
      refunded: j['refunded'] == true,
      store: j['store'] as String? ?? '',
      purchasedAt: DateTime.tryParse(j['purchasedAt'] as String? ?? ''),
    );
  }
}

/// The `200` body of `POST /api/purchases/sync` (SPEC §4.9).
///
/// The request carried nothing: the server asked RevenueCat with its own key.
/// Everything here is therefore the server's answer about what the server holds —
/// which is the whole reason this endpoint exists in this shape.
class PurchaseSync {
  const PurchaseSync({
    required this.premium,
    required this.granted,
    required this.owned,
    required this.balance,
    this.purchases = const <PurchaseRecord>[],
  });

  /// **The answer the client acts on**: everything is unlocked, or it is not.
  final bool premium;

  /// How many purchases this call turned into premium. Usually 0, and that is the
  /// healthy case: it means the webhook got there first, or there was nothing to
  /// restore.
  final int granted;

  /// Whether RevenueCat knows of the unlock for this store account at all.
  ///
  /// This is what separates "restored" from "there was nothing to restore" — the
  /// one sentence a Restore button has to be able to say truthfully. It can be
  /// true while [premium] is false: a refunded purchase the store still reports.
  final bool owned;

  /// The wallet afterwards, from the server. A premium player still earns Sparks
  /// by playing; they simply have nothing left to spend them on.
  final int balance;

  /// The ledger, newest first.
  final List<PurchaseRecord> purchases;

  static PurchaseSync fromJson(Map<String, dynamic> j) => PurchaseSync(
    premium: j['premium'] == true,
    granted: (j['granted'] as num?)?.toInt() ?? 0,
    owned: j['owned'] == true,
    balance: (j['balance'] as num?)?.toInt() ?? 0,
    purchases: <PurchaseRecord>[
      for (final raw in (j['purchases'] as List?) ?? const [])
        if (raw is Map<String, dynamic>) ?PurchaseRecord.fromJson(raw),
    ],
  );
}

/// The `200` body of `GET /api/ads/offer` (SPEC §4.10): whether this player may
/// watch a rewarded ad for Sparks, and what their allowance looks like.
///
/// **Every number here is the server's.** The client does not hold an ad's worth,
/// a daily cap or a cooldown: it asks, and it draws what it is told. That is not
/// tidiness — the reward is credited by our server on Google's signed callback, so
/// a client-side copy of any of these numbers could only ever be a second opinion
/// that disagrees.
///
/// It doubles as the poll after an ad: [adTotal] can only move one way and only
/// for one reason, so watching it is how the app learns the credit landed.
class AdOffer {
  const AdOffer({
    required this.available,
    required this.sparks,
    required this.earnedToday,
    required this.dailyCap,
    required this.remaining,
    required this.cooldownSeconds,
    required this.waitSeconds,
    required this.balance,
    required this.adTotal,
    this.premium = false,
    this.placements = const <String>[],
  });

  /// A deployment that credits no ads, or a client that could not ask. The app
  /// shows no ad button, which is also what every build gets before a human has
  /// configured AdMob.
  static const AdOffer none = AdOffer(
    available: false,
    sparks: 0,
    earnedToday: 0,
    dailyCap: 0,
    remaining: 0,
    cooldownSeconds: 0,
    waitSeconds: 0,
    balance: 0,
    adTotal: 0,
  );

  /// The one flag the app acts on: there is allowance left and the cooldown has
  /// passed. Everything else is for the sentence beside the button.
  final bool available;

  /// What the next ad would pay, from the server's own table.
  final int sparks;

  /// Sparks earned from ads today, and the day's ceiling — both the server's
  /// numbers, so the shop can say "20 of 60 today" instead of leaving a player
  /// wondering why the button went away.
  final int earnedToday;
  final int dailyCap;

  /// What is left of the day's ad allowance.
  final int remaining;

  /// The configured cooldown, and how much of it is still to run.
  final int cooldownSeconds;
  final int waitSeconds;

  /// The wallet and the lifetime ad total, from the server.
  final int balance;
  final int adTotal;

  /// This player bought the one-time unlock (SPEC §4.9), so they are offered **no
  /// ads at all** — not fewer, none. The allowance is untouched and [available]
  /// is false, which is why this flag is worth carrying: it is the difference
  /// between "no ads, ever, because you paid" and "come back tomorrow".
  final bool premium;

  /// Placement names this server knows (`shop`, `gameOver`), so a build newer or
  /// older than the server can tell.
  final List<String> placements;

  /// Whether the day is spent rather than the cooldown running — the difference
  /// between "come back in a few minutes" and "come back tomorrow".
  bool get dayFull => remaining <= 0;

  static AdOffer fromJson(Map<String, dynamic> j) => AdOffer(
    available: j['available'] == true,
    sparks: (j['sparks'] as num?)?.toInt() ?? 0,
    earnedToday: (j['earnedToday'] as num?)?.toInt() ?? 0,
    dailyCap: (j['dailyCap'] as num?)?.toInt() ?? 0,
    remaining: (j['remaining'] as num?)?.toInt() ?? 0,
    cooldownSeconds: (j['cooldownSeconds'] as num?)?.toInt() ?? 0,
    waitSeconds: (j['waitSeconds'] as num?)?.toInt() ?? 0,
    balance: (j['balance'] as num?)?.toInt() ?? 0,
    adTotal: (j['adTotal'] as num?)?.toInt() ?? 0,
    premium: j['premium'] == true,
    placements: <String>[
      for (final p in (j['placements'] as List?) ?? const []) '$p',
    ],
  );
}

/// The `200` body of `GET /api/shop/catalogue` (SPEC §4.8): what can be owned,
/// what it costs, what the caller already has, and what they are wearing.
class ShopCatalogue {
  const ShopCatalogue({
    required this.version,
    required this.latestVersion,
    required this.kinds,
    required this.items,
    required this.balance,
    required this.equipped,
    this.premium = false,
    this.unlock,
  });

  /// The catalogue version this answer speaks, i.e. the one that was asked for.
  final int version;

  /// The newest version the **server** has. Higher than [version] means there is
  /// content this build cannot draw — worth saying in the UI, not worth hiding.
  final int latestVersion;

  /// The slots present in this version, in the order a shop should show them.
  final List<String> kinds;

  final List<ShopItem> items;

  /// The wallet, from the server. Never computed here.
  final int balance;

  /// Slot name → item id, defaults already filled in by the server.
  final Map<String, String> equipped;

  /// Whether this player holds the one-time unlock (SPEC §4.9). Every item then
  /// comes back `owned`, with no row anywhere — which is what makes a cosmetic
  /// added next year covered the moment it is added.
  final bool premium;

  /// The one-time unlock this deployment sells (SPEC §4.9), or null.
  ///
  /// Null in two completely different cases the shop treats the same way: the
  /// deployment sells nothing, and the player has already bought it. In both there
  /// is nothing left to offer, so the shop draws no offer rather than a button
  /// that cannot work. [premium] is what tells the two apart.
  final UnlockProduct? unlock;

  static ShopCatalogue fromJson(Map<String, dynamic> j) => ShopCatalogue(
    version: (j['version'] as num?)?.toInt() ?? 1,
    latestVersion: (j['latestVersion'] as num?)?.toInt() ?? 1,
    kinds: <String>[for (final k in (j['kinds'] as List?) ?? const []) '$k'],
    items: <ShopItem>[
      for (final raw in (j['items'] as List?) ?? const [])
        if (raw is Map<String, dynamic>) ?ShopItem.fromJson(raw),
    ],
    balance: (j['balance'] as num?)?.toInt() ?? 0,
    equipped: _equippedFrom(j['equipped']),
    premium: j['premium'] == true,
    unlock: switch (j['unlock']) {
      final Map<String, dynamic> raw => UnlockProduct.fromJson(raw),
      _ => null,
    },
  );
}

/// The `200` body of `GET /api/shop/inventory` (SPEC §4.8): the wallet, what is
/// owned, what is worn, and how much of today's earning allowance is gone.
class ShopInventory {
  const ShopInventory({
    required this.version,
    required this.latestVersion,
    required this.balance,
    required this.owned,
    required this.equipped,
    required this.earnedToday,
    required this.dailyCap,
    this.earnedTotal = 0,
    this.spentTotal = 0,
    this.purchasedTotal = 0,
    this.adTotal = 0,
    this.premium = false,
  });

  final int version;
  final int latestVersion;
  final int balance;

  /// Everything the player may wear, free items included.
  final List<String> owned;
  final Map<String, String> equipped;

  /// Tokens earned from play in the current UTC day, and the day's ceiling —
  /// both the server's own numbers, so the client can say "200 of 200 today"
  /// instead of leaving a good run looking unpaid.
  final int earnedToday;
  final int dailyCap;

  final int earnedTotal;
  final int spentTotal;

  /// Purchases ever made with money (SPEC §4.9). One, for a player who bought the
  /// unlock; more than one only where two stores each hold a record of it.
  final int purchasedTotal;

  /// Whether this player holds the one-time unlock (SPEC §4.9): every cosmetic is
  /// theirs, present and future, and no ad is ever offered.
  final bool premium;

  /// Sparks ever earned from watching rewarded ads (SPEC §4.10), kept apart from
  /// both — because the ad allowance is its own daily cap and must never consume
  /// the play one.
  final int adTotal;

  static ShopInventory fromJson(Map<String, dynamic> j) => ShopInventory(
    version: (j['version'] as num?)?.toInt() ?? 1,
    latestVersion: (j['latestVersion'] as num?)?.toInt() ?? 1,
    balance: (j['balance'] as num?)?.toInt() ?? 0,
    owned: <String>[for (final id in (j['owned'] as List?) ?? const []) '$id'],
    equipped: _equippedFrom(j['equipped']),
    earnedToday: (j['earnedToday'] as num?)?.toInt() ?? 0,
    dailyCap: (j['dailyCap'] as num?)?.toInt() ?? 0,
    earnedTotal: (j['earnedTotal'] as num?)?.toInt() ?? 0,
    spentTotal: (j['spentTotal'] as num?)?.toInt() ?? 0,
    purchasedTotal: (j['purchasedTotal'] as num?)?.toInt() ?? 0,
    adTotal: (j['adTotal'] as num?)?.toInt() ?? 0,
    premium: j['premium'] == true,
  );
}

/// What `POST /api/shop/buy` did (SPEC §4.8).
///
/// A refusal the server documents — "you cannot afford it", "no such item" — is
/// an ordinary answer here, exactly as a rejected replay is on a submission:
/// those are facts about the wallet and the catalogue, not failures of the call.
/// Anything that leaves the outcome unknown (a timeout, a 5xx, a refused
/// credential) throws [ApiException] instead, because then the honest thing to do
/// is ask the server again rather than tell the player anything.
class ShopPurchase {
  const ShopPurchase.done({
    required this.itemId,
    required this.priceTokens,
    required this.charged,
    required this.alreadyOwned,
    required this.balance,
    required this.owned,
    this.premium = false,
  }) : error = null;

  const ShopPurchase.refused({
    required this.error,
    required this.itemId,
    required this.priceTokens,
    required this.balance,
  }) : charged = 0,
       alreadyOwned = false,
       owned = const <String>[],
       // A refusal is a short wallet, and the server sends no `premium` with one:
       // a premium player is never refused, because every item reads as already
       // owned and costs 0.
       premium = false;

  /// `insufficient_tokens` or `unknown_item`; null on success.
  final String? error;

  final String itemId;

  /// The catalogue price the server charged against.
  final int priceTokens;

  /// What this call actually took: **0** when the item was already owned, which
  /// is what makes a retry after a lost answer safe — the same request twice
  /// costs the price once.
  final int charged;

  final bool alreadyOwned;

  /// The wallet afterwards (on a refusal: the wallet that was too small).
  final int balance;

  /// Everything owned after the purchase.
  final List<String> owned;

  /// Whether the player holds the one-time unlock (SPEC §4.9). Only ever read off
  /// a successful answer — see the `refused` constructor.
  final bool premium;

  bool get ok => error == null;

  /// The wallet is short. [missing] says by how much, from the server's two
  /// numbers.
  bool get insufficient => error == insufficientTokensError;

  /// Tokens still needed; 0 unless [insufficient].
  int get missing =>
      insufficient && priceTokens > balance ? priceTokens - balance : 0;

  static const String insufficientTokensError = 'insufficient_tokens';
  static const String unknownItemError = 'unknown_item';
}

/// The server's stored slot choices, `{"theme":"theme.neon","ball":…}`.
Map<String, String> _equippedFrom(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in raw.entries)
      if (entry.value is String && (entry.value as String).isNotEmpty)
        '${entry.key}': entry.value as String,
  };
}

/// REST client for the Arco server (SPEC §4). Every call times out
/// after [timeout] and throws [ApiException] on transport errors.
class ApiClient {
  ApiClient({
    required String Function() baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _baseUrl = baseUrl,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String Function() _baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  String get baseUrl => _baseUrl();

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$basePath$path', queryParameters: query);
  }

  Future<HealthInfo> health() async {
    final j = await _getJson(_uri('/api/health'));
    return HealthInfo(
      ok: j['ok'] == true,
      version: '${j['version'] ?? ''}',
      rooms: (j['rooms'] as num?)?.toInt() ?? 0,
      accounts: <String>[
        for (final p in (j['accounts'] as List?) ?? const []) '$p',
      ],
      purchases: j['purchases'] == true,
    );
  }

  /// Top [limit] for [period], optionally restricted to one country — which
  /// composes with the period rather than replacing it (SPEC §4.6). An unusable
  /// code is the server's `400 invalid_country`, surfaced as an [ApiException]
  /// carrying that [ApiException.errorCode].
  Future<List<LeaderboardEntry>> leaderboard(
    LeaderboardPeriod period, {
    int limit = 100,
    String? country,
  }) async {
    final j = await _getJson(
      _uri('/api/leaderboard', {
        'period': period.name,
        'limit': '$limit',
        'country': ?country,
      }),
    );
    final entries = j['entries'];
    if (entries is! List) {
      throw const ApiException(ApiErrorKind.badResponse, 'missing entries');
    }
    try {
      return [
        for (final e in entries)
          LeaderboardEntry.fromJson(e as Map<String, dynamic>),
      ];
    } on Object catch (e) {
      throw ApiException(ApiErrorKind.badResponse, 'bad entry: $e');
    }
  }

  /// Submits a solo replay. Returns a rejected [SubmitResult] only for the
  /// answers SPEC §4 documents (400 with an error code, 413, 429); any other
  /// reply is indeterminate (see [SubmitResult.indeterminate]) and throwing
  /// [ApiException] is reserved for 5xx and for not reaching the server.
  /// [credentials] attach the run to a player (SPEC §4.4) and are optional;
  /// without them the submission is anonymous. [country] is the optional hint
  /// of SPEC §4.6, dropped server side when it is not a usable alpha-2 code.
  Future<SubmitResult> submitScore(
    String name,
    Replay replay, {
    PlayerCredentials? credentials,
    String? country,
  }) async {
    final body = jsonEncode({
      'name': name,
      'replay': replay.toJson(),
      'country': ?country,
    });
    final res = await _send(
      () => _client.post(
        _uri('/api/scores'),
        headers: {
          'content-type': 'application/json',
          if (credentials != null) 'authorization': credentials.header,
        },
        body: body,
      ),
    );
    final j = _tryDecode(res.body);
    switch (res.statusCode) {
      case 201:
      case 200:
        if (j == null || j['ok'] != true) {
          // A 2xx without the documented body did not come from the server
          // (a captive portal, a proxy interstitial): the replay is intact.
          return SubmitResult.indeterminate(
            error: 'unexpected_body',
            statusCode: res.statusCode,
          );
        }
        return SubmitResult.accepted(
          id: '${j['id'] ?? ''}',
          score: (j['score'] as num?)?.toInt() ?? replay.claimedScore,
          rank: (j['rank'] as num?)?.toInt() ?? 0,
          playerId: j['playerId'] as String?,
          country: j['country'] as String?,
          countryRank: (j['countryRank'] as num?)?.toInt(),
          tokens: (j['tokens'] as num?)?.toInt(),
          tokenBalance: (j['tokenBalance'] as num?)?.toInt(),
        );
      case 400:
        // Only the documented `{"ok":false,"error":"…"}` body is the server
        // judging the replay; a bare 400 from something in between is not.
        final code = j?['error'];
        if (j?['ok'] == false && code is String && code.isNotEmpty) {
          return SubmitResult.rejected(error: code, statusCode: 400);
        }
        return const SubmitResult.indeterminate(
          error: 'unexpected_body',
          statusCode: 400,
        );
      case 401:
        // SPEC §4.4 fails closed on credentials that are present but wrong, and
        // stores nothing. Only the documented body is that verdict: a bare 401
        // is an authenticating proxy, which says nothing about the replay.
        final authCode = j?['error'];
        if (j?['ok'] == false && authCode is String && authCode.isNotEmpty) {
          return SubmitResult.unauthorized(error: authCode);
        }
        return const SubmitResult.indeterminate(
          error: 'unexpected_body',
          statusCode: 401,
        );
      case 413:
        return const SubmitResult.rejected(error: 'too_large', statusCode: 413);
      case 429:
        return const SubmitResult.rejected(
          error: 'rate_limited',
          statusCode: 429,
        );
      default:
        if (res.statusCode >= 400 && res.statusCode < 500) {
          // 401/403/404/407…: an authenticating proxy or a wrong server URL,
          // never a verdict on the replay (SPEC §4 answers 400/413/429).
          return SubmitResult.indeterminate(
            error: 'http_${res.statusCode}',
            statusCode: res.statusCode,
          );
        }
        throw ApiException(
          ApiErrorKind.server,
          'HTTP ${res.statusCode}',
          statusCode: res.statusCode,
        );
    }
  }

  /// Optional endpoint: rank a score would have right now.
  Future<int> rank(int score) async {
    final j = await _getJson(
      _uri('/api/leaderboard/rank', {'score': '$score'}),
    );
    return (j['rank'] as num?)?.toInt() ?? 0;
  }

  /// `POST /api/players` — issues an anonymous player identity (SPEC §4.4).
  ///
  /// The secret comes back exactly once, so the caller has to store it before
  /// doing anything else with it. Throws [ApiException]: `rateLimited` (with
  /// the server's `retry-after`) when the per-IP budget is spent, and the usual
  /// transport kinds otherwise. No name is sent: the display name follows the
  /// last name a score was actually submitted under (§4.4), so posting one here
  /// would only add a way for the issue itself to be refused (§4.7).
  Future<PlayerCredentials> createPlayer({String? name}) async {
    final res = await _send(
      () => _client.post(
        _uri('/api/players'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'name': ?name}),
      ),
    );
    final j = _tryDecode(res.body);
    if (res.statusCode == 201 && j?['ok'] == true) {
      final credentials = PlayerCredentials.fromJson(j!);
      if (credentials != null) return credentials;
      throw const ApiException(
        ApiErrorKind.badResponse,
        'player issued without a usable id/secret',
        statusCode: 201,
      );
    }
    throw _failure(res, j);
  }

  /// `POST /api/account/link` — signs in with Apple or Google (SPEC §4.5).
  ///
  /// [credentials] are **optional** and decide which half of the flow this is:
  /// with them the player we already are gains the account (or is merged into
  /// it), without them the account is restored onto a device that holds none.
  ///
  /// Throws [ApiException] carrying the server's own [ApiException.errorCode] —
  /// `accounts_disabled` (404), `invalid_provider` / `invalid_json` (400),
  /// `invalid_credentials` / `invalid_token` (401), `already_linked` (409),
  /// `rate_limited` (429), `keys_unavailable` (503) — plus the one extra field
  /// each of those carries in [ApiException.detail].
  Future<AccountLink> linkAccount({
    required String provider,
    required String idToken,
    PlayerCredentials? credentials,
  }) async {
    final res = await _send(
      () => _client.post(
        _uri('/api/account/link'),
        headers: {
          'content-type': 'application/json',
          if (credentials != null) 'authorization': credentials.header,
        },
        body: jsonEncode({'provider': provider, 'idToken': idToken}),
      ),
    );
    final j = _tryDecode(res.body);
    if (res.statusCode == 200 && j?['ok'] == true) {
      final link = AccountLink.fromJson(j!);
      if (link != null) return link;
      throw const ApiException(
        ApiErrorKind.badResponse,
        'account linked without a usable id/secret',
        statusCode: 200,
      );
    }
    throw _failure(res, j);
  }

  /// `DELETE /api/players/me` — deletes the player, its account, its credentials
  /// and every link between the person and their runs (SPEC §4.5). Returns the
  /// number of score rows that were anonymised rather than deleted: a verified
  /// run stays on the board, because removing it would restate everybody else's
  /// rank.
  ///
  /// Never gated on the account feature switch, so it works for a player that
  /// only ever had the anonymous identity of §4.4.
  Future<int> deletePlayer(PlayerCredentials credentials) async {
    final res = await _send(
      () => _client.delete(
        _uri('/api/players/me'),
        headers: {'authorization': credentials.header},
      ),
    );
    final j = _tryDecode(res.body);
    if (res.statusCode == 200 && j?['ok'] == true) {
      return (j!['scoresAnonymised'] as num?)?.toInt() ?? 0;
    }
    throw _failure(res, j);
  }

  /// `GET /api/players/me` — the player's own standing (SPEC §4.4 / §4.6).
  ///
  /// Throws an `unauthorized` [ApiException] when the stored credential is no
  /// longer accepted, which is the caller's signal to forget it.
  Future<PlayerProfile> playerMe(PlayerCredentials credentials) async {
    final j = await _getJson(_uri('/api/players/me'), credentials: credentials);
    return PlayerProfile.fromJson(j);
  }

  // ------------------------------------------- cosmetic shop (SPEC §4.8)

  /// `GET /api/shop/catalogue?v=N` — what can be owned, what it costs, what
  /// [credentials] already own, and what they are wearing (SPEC §4.8).
  ///
  /// [version] is the catalogue version **this build** can draw. The server
  /// serves nothing newer, so an app that shipped before a kind of item existed
  /// is never handed one it would have to render as a blank card.
  Future<ShopCatalogue> shopCatalogue(
    PlayerCredentials credentials, {
    required int version,
  }) async {
    final j = await _getJson(
      _uri('/api/shop/catalogue', {'v': '$version'}),
      credentials: credentials,
    );
    return ShopCatalogue.fromJson(j);
  }

  /// `GET /api/shop/inventory?v=N` — the wallet, what is owned, what is worn and
  /// how much of today's earning allowance is spent (SPEC §4.8).
  Future<ShopInventory> shopInventory(
    PlayerCredentials credentials, {
    required int version,
  }) async {
    final j = await _getJson(
      _uri('/api/shop/inventory', {'v': '$version'}),
      credentials: credentials,
    );
    return ShopInventory.fromJson(j);
  }

  /// `POST /api/shop/buy` body `{"itemId":"ball.comet"}` (SPEC §4.8).
  ///
  /// The request carries an item id and nothing else — no price, no quantity,
  /// nothing the server would have to decide whether to believe.
  ///
  /// Returns a refused [ShopPurchase] for the two answers the server documents
  /// (`402 insufficient_tokens`, `404 unknown_item`) and throws [ApiException]
  /// for everything that leaves the purchase unsettled. That split is the whole
  /// safety property: a caller that catches the exception knows only that it must
  /// ask again, and asking again is free, because buying the same item twice
  /// charges once.
  Future<ShopPurchase> shopBuy(
    PlayerCredentials credentials,
    String itemId, {
    required int version,
  }) async {
    final res = await _send(
      () => _client.post(
        _uri('/api/shop/buy', {'v': '$version'}),
        headers: {
          'content-type': 'application/json',
          'authorization': credentials.header,
        },
        body: jsonEncode({'itemId': itemId}),
      ),
    );
    final j = _tryDecode(res.body);
    if (res.statusCode == 200 && j?['ok'] == true) {
      return ShopPurchase.done(
        itemId: j!['itemId'] as String? ?? itemId,
        priceTokens: (j['priceTokens'] as num?)?.toInt() ?? 0,
        charged: (j['charged'] as num?)?.toInt() ?? 0,
        alreadyOwned: j['alreadyOwned'] == true,
        balance: (j['balance'] as num?)?.toInt() ?? 0,
        owned: <String>[
          for (final id in (j['owned'] as List?) ?? const []) '$id',
        ],
        premium: j['premium'] == true,
      );
    }
    final code = j?['error'];
    if (j?['ok'] == false &&
        code is String &&
        (code == ShopPurchase.insufficientTokensError ||
            code == ShopPurchase.unknownItemError)) {
      return ShopPurchase.refused(
        error: code,
        itemId: j!['itemId'] as String? ?? itemId,
        priceTokens: (j['priceTokens'] as num?)?.toInt() ?? 0,
        balance: (j['balance'] as num?)?.toInt() ?? 0,
      );
    }
    throw _failure(res, j);
  }

  /// `POST /api/shop/equip` body `{"ball":"ball.comet"}` (SPEC §4.8).
  ///
  /// A slot that is not named is left alone; a null value puts that slot back to
  /// the free default. Answers with the stored choices afterwards, every slot
  /// filled in.
  ///
  /// Equipping is a preference, not an entitlement: naming an item the player
  /// does not own is `403 item_not_owned`, which arrives here as an
  /// [ApiException] carrying that code. A UI that only offers what is owned never
  /// sees it, which is exactly why it is worth having.
  Future<Map<String, String>> shopEquip(
    PlayerCredentials credentials,
    Map<String, String?> slots, {
    required int version,
  }) async {
    final res = await _send(
      () => _client.post(
        _uri('/api/shop/equip', {'v': '$version'}),
        headers: {
          'content-type': 'application/json',
          'authorization': credentials.header,
        },
        body: jsonEncode(slots),
      ),
    );
    final j = _tryDecode(res.body);
    if (res.statusCode == 200 && j?['ok'] == true) {
      return _equippedFrom(j!['equipped']);
    }
    throw _failure(res, j);
  }

  // --------------------------------------- the one-time unlock (SPEC §4.9)

  /// `POST /api/purchases/sync` — asks the server to re-check with RevenueCat
  /// (SPEC §4.9). This is what **Restore Purchases** is.
  ///
  /// **The request carries nothing.** Not a product id, not a transaction id, and
  /// certainly not an amount: the server asks RevenueCat with its own secret key
  /// and credits from that answer, so there is nothing this phone could say that
  /// would be believed. The body is `{}` only because the call is a POST.
  ///
  /// It serves two cases with one shape. The impatient one: the webhook is
  /// authoritative but can be a few seconds late, and a player who has just paid
  /// is looking at the screen. And the genuine restore: the unlock is a
  /// **non-consumable**, so a reinstall or a second device really does have
  /// something to recover, and the server grants it keyed on the store's own
  /// transaction id — which is what makes running this any number of times safe.
  Future<PurchaseSync> purchasesSync(PlayerCredentials credentials) async {
    final res = await _send(
      () => _client.post(
        _uri('/api/purchases/sync'),
        headers: {
          'content-type': 'application/json',
          'authorization': credentials.header,
        },
        body: '{}',
      ),
    );
    final j = _tryDecode(res.body);
    if (res.statusCode == 200 && j?['ok'] == true) {
      return PurchaseSync.fromJson(j!);
    }
    throw _failure(res, j);
  }

  // ------------------------------------------- rewarded ads (SPEC §4.10)

  /// `GET /api/ads/offer` — whether this player may watch an ad for Sparks
  /// (SPEC §4.10).
  ///
  /// **Read-only, and it cannot credit anything.** The reward is credited by our
  /// server when Google's signed server-side verification callback arrives, so
  /// there is deliberately no endpoint a client could call to claim one. This is
  /// the two things a client legitimately needs: whether to draw a button at all,
  /// and — called again afterwards — whether the credit has landed.
  ///
  /// A deployment with ads switched off answers `404 ads_disabled`, which surfaces
  /// as an [ApiException]; the caller treats that as [AdOffer.none] and shows
  /// nothing.
  Future<AdOffer> adsOffer(PlayerCredentials credentials) async {
    final j = await _getJson(_uri('/api/ads/offer'), credentials: credentials);
    if (j['ok'] != true) {
      throw ApiException(
        ApiErrorKind.badResponse,
        '${j['error'] ?? 'not ok'}',
        errorCode: j['error'] as String?,
      );
    }
    return AdOffer.fromJson(j);
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, dynamic>> _getJson(
    Uri uri, {
    PlayerCredentials? credentials,
  }) async {
    final res = await _send(
      () => _client.get(
        uri,
        headers: credentials == null
            ? null
            : {'authorization': credentials.header},
      ),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _failure(res, _tryDecode(res.body));
    }
    final j = _tryDecode(res.body);
    if (j == null) {
      throw ApiException(
        ApiErrorKind.badResponse,
        'not a JSON object',
        statusCode: res.statusCode,
      );
    }
    return j;
  }

  /// The [ApiException] for a non-2xx answer: the documented `error` code when
  /// the server sent one, the status's own meaning otherwise.
  static ApiException _failure(http.Response res, Map<String, dynamic>? body) {
    final code = body?['error'];
    final errorCode = code is String && code.isNotEmpty ? code : null;
    final kind = switch (res.statusCode) {
      401 => ApiErrorKind.unauthorized,
      429 => ApiErrorKind.rateLimited,
      // 503 keys_unavailable is the provider's keys being unreachable, which is
      // the server's problem and worth a retry — the same class as a 5xx.
      >= 500 => ApiErrorKind.server,
      _ => ApiErrorKind.badResponse,
    };
    final extra = body?['provider'] ?? body?['reason'] ?? body?['detail'];
    return ApiException(
      kind,
      errorCode ?? 'HTTP ${res.statusCode}',
      statusCode: res.statusCode,
      errorCode: errorCode,
      detail: extra is String && extra.isNotEmpty ? extra : null,
      retryAfter: _retryAfter(res),
    );
  }

  /// The `retry-after` header as a duration; SPEC §4.4 sends delta-seconds.
  static Duration? _retryAfter(http.Response res) {
    final raw = res.headers['retry-after'];
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(timeout);
    } on TimeoutException {
      throw const ApiException(ApiErrorKind.timeout, 'request timed out');
    } on http.ClientException catch (e) {
      throw ApiException(ApiErrorKind.network, e.message);
    } on ApiException {
      rethrow;
    } on Object catch (e) {
      // SocketException and friends live in dart:io, which is not available
      // on the web; treat anything else as a network failure.
      throw ApiException(ApiErrorKind.network, '$e');
    }
  }

  static Map<String, dynamic>? _tryDecode(String body) {
    try {
      final j = jsonDecode(body);
      return j is Map<String, dynamic> ? j : null;
    } on FormatException {
      return null;
    }
  }
}
