/// HTTP surface: the REST endpoints of SPEC §4 plus the `/ws` upgrade.
///
/// Response shaping, CORS and the error boundary live in `http_util.dart`;
/// leaderboard rules live in `leaderboard.dart`. This file only routes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import 'accounts.dart';
import 'ads.dart';
import 'catalogue.dart';
import 'country.dart';
import 'db.dart';
import 'http_util.dart';
import 'leaderboard.dart';
import 'logging.dart';
import 'name_filter.dart';
import 'players.dart';
import 'purchases.dart';
import 'rate_limit.dart';
import 'rooms.dart';
import 'shop.dart';
import 'version.dart';
import 'ws_frame_guard.dart';

/// `POST /api/scores` bodies larger than this are rejected with 413 (SPEC §4).
///
/// It is a coarse transport guard, not the bound on verification work: that is
/// `ReplayVerifier.maxTicks` (one hour of play, tens of milliseconds to
/// re-simulate) together with the per-tick entry bound checked in
/// `leaderboard.dart`.
///
/// It does, however, bound the *length* of a submittable solo game, because a
/// replay carries one `[tick, input]` pair per input change (~13 bytes each).
/// A game whose input changes on almost every tick - Follow controls with the
/// finger in motion - fits about 160 700 ticks (~45 min) into this cap, short
/// of SPEC's one-hour `maxTicks`. The cap is SPEC §4, so it is not raised
/// here; instead the 413 names the limit and says the replay is too long, so
/// the client can tell the player why the game was not stored rather than
/// report an opaque transport failure.
const int maxScoreBodyBytes = 2 * 1024 * 1024;

/// Submissions allowed per IP per minute (SPEC §4).
const int scoreSubmissionsPerMinute = 10;

/// `POST /api/players` calls allowed per IP per minute (SPEC §4.4).
///
/// A client issues a player once per install and then keeps the secret, so the
/// honest rate is one call ever. The budget exists to stop a loop from filling
/// the table with unusable rows, and matches [scoreSubmissionsPerMinute] so a
/// NAT'd group installing the game together is never refused.
const int playerIssuesPerMinute = 10;

/// `POST /api/account/*` and `DELETE /api/players/me` calls allowed per IP per
/// minute (SPEC §4.5).
///
/// A player signs in once per device, so the honest rate is a call or two ever.
/// The budget is what bounds the RSA verification an unauthenticated caller can
/// ask for: one costs ~0.2 ms (measured, 2048-bit RS256 in pointycastle), so an
/// IP at the limit buys 2 ms of CPU per minute and the signature check can stay
/// on the isolate that also drives the 60 Hz room tick.
const int accountCallsPerMinute = 10;

/// `/api/shop/*` calls allowed per IP per minute (SPEC §4.8).
///
/// Higher than the other per-IP budgets because these are the calls a player
/// makes while *using* a screen rather than once per install: opening the shop
/// reads the catalogue and the inventory, and picking a look writes a slot. Each
/// one is a single indexed query or a one-row upsert, so 30 a minute costs
/// nothing and leaves a whole NAT'd household room to browse. A buy is metered
/// by the same budget, which is deliberate: there is no cheaper call an attacker
/// could use to probe the wallet.
const int shopCallsPerMinute = 30;

/// `POST /api/purchases/webhook` calls allowed per IP per minute (SPEC §4.9).
///
/// Every legitimate one of these comes from RevenueCat, so the whole of
/// RevenueCat shares one bucket — which is why the number is large rather than
/// careful. Ten a second is far beyond what a game of this size produces, and the
/// work per call is one constant-time comparison plus one indexed insert. A
/// refused webhook is retried by RevenueCat, so even hitting the limit loses
/// nothing; what the limit actually stops is an unauthenticated flood of bodies
/// from anywhere else.
const int purchaseWebhooksPerMinute = 600;

/// `GET /api/ads/callback` calls allowed per IP per minute (SPEC §4.10).
///
/// Every legitimate one comes from Google's ad servers, which is why the number is
/// large rather than careful: they arrive from many addresses and a busy minute is
/// a good sign. The work per call is one string comparison plus — only once the
/// shape and the optional URL key are right — one ECDSA verification, which is
/// ~0.5 ms. An IP at the limit therefore buys well under a second of CPU per
/// minute. AdMob retries a `429` like any other non-2xx, so the limit cannot lose
/// a reward; what it stops is an unauthenticated flood of query strings from
/// anywhere else.
const int adCallbacksPerMinute = 600;

/// `POST /api/players` bodies larger than this are rejected with 413.
///
/// The body is optional and carries at most a display name; anything bigger is
/// not a client of this endpoint.
const int maxPlayerBodyBytes = 4 * 1024;

/// `/ws` upgrades allowed per IP per minute.
///
/// [maxLiveSessionsPerIp] bounds how many sockets one IP may hold *at once*, not
/// how fast it may churn through them: a reconnect loop measured ~4900 room-code
/// guesses per second from a single IP because nothing metered the upgrade
/// itself. The per-IP join budget ([joinMissesPerIp]) is what stops the
/// enumeration; this cap stops the churn, so the loop cannot burn handshakes,
/// file descriptors and log lines either.
///
/// It is deliberately larger than [maxLiveSessionsPerIp] (64): a whole NAT'd
/// group has to be able to connect at once and then reconnect once more within
/// the same minute after, say, a Wi-Fi hiccup. Two players behind one router
/// never come close. Refused upgrades get `429` with `retry-after`, before any
/// WebSocket handshake happens.
const int wsUpgradesPerIpPerMinute = 2 * maxLiveSessionsPerIp;

/// How often an otherwise idle WebSocket is probed with a ping frame.
///
/// Without it dart:io never checks the peer, so a half-open TCP connection (a
/// phone that lost coverage, a blackholed route) keeps its session - and the
/// room it sits in - alive until the OS TCP timeout, hours later.
const Duration webSocketPingInterval = Duration(seconds: 15);

class ApiHandler {
  ApiHandler({
    required this.leaderboard,
    required this.players,
    required this.accounts,
    required this.shop,
    required this.purchases,
    required this.ads,
    required this.rooms,
    required this.log,
    RateLimiter? submitLimiter,
    RateLimiter? upgradeLimiter,
    RateLimiter? playerLimiter,
    RateLimiter? accountLimiter,
    RateLimiter? shopLimiter,
    RateLimiter? purchaseLimiter,
    RateLimiter? adLimiter,
    this.sweepInterval = const Duration(seconds: 30),
    this.pingInterval = webSocketPingInterval,
  }) : submitLimiter =
           submitLimiter ??
           RateLimiter(
             limit: scoreSubmissionsPerMinute,
             window: const Duration(minutes: 1),
           ),
       upgradeLimiter =
           upgradeLimiter ??
           RateLimiter(
             limit: wsUpgradesPerIpPerMinute,
             window: const Duration(minutes: 1),
           ),
       playerLimiter =
           playerLimiter ??
           RateLimiter(
             limit: playerIssuesPerMinute,
             window: const Duration(minutes: 1),
           ),
       accountLimiter =
           accountLimiter ??
           RateLimiter(
             limit: accountCallsPerMinute,
             window: const Duration(minutes: 1),
           ),
       shopLimiter =
           shopLimiter ??
           RateLimiter(
             limit: shopCallsPerMinute,
             window: const Duration(minutes: 1),
           ),
       purchaseLimiter =
           purchaseLimiter ??
           RateLimiter(
             limit: purchaseWebhooksPerMinute,
             window: const Duration(minutes: 1),
           ),
       adLimiter =
           adLimiter ??
           RateLimiter(
             limit: adCallbacksPerMinute,
             window: const Duration(minutes: 1),
           );

  final LeaderboardService leaderboard;
  final PlayerService players;

  /// Sign in with Apple / Google (SPEC §4.5). Always present; when it reports
  /// `enabled == false` the account routes answer [accountsDisabledError] and
  /// nothing else about the server changes.
  final AccountService accounts;

  /// The cosmetic shop (SPEC §4.8): catalogue, wallet, ownership, equipping.
  final ShopService shop;

  /// The one-time unlock (SPEC §4.9). Always present; when it reports
  /// `enabled == false` the two purchase routes answer [purchasesDisabledError],
  /// the catalogue advertises no product, and nothing else about the server
  /// changes.
  final PurchaseService purchases;

  /// Rewarded ads that pay Sparks (SPEC §4.10). Always present; when it reports
  /// `enabled == false` the two ad routes answer [adsDisabledError], no client
  /// ever offers an ad button, and nothing else about the server changes.
  final AdsService ads;

  final RoomRegistry rooms;
  final Logger log;

  /// Counts every submission attempt, valid or not, so that a client cannot
  /// brute-force the verifier for free.
  final RateLimiter submitLimiter;

  /// Counts every `/ws` upgrade attempt per IP ([wsUpgradesPerIpPerMinute]).
  final RateLimiter upgradeLimiter;

  /// Counts every `POST /api/players` per IP ([playerIssuesPerMinute]).
  final RateLimiter playerLimiter;

  /// Counts every account call per IP ([accountCallsPerMinute]).
  final RateLimiter accountLimiter;

  /// Counts every `/api/shop/*` call per IP ([shopCallsPerMinute]).
  final RateLimiter shopLimiter;

  /// Counts every purchase webhook per IP ([purchaseWebhooksPerMinute]).
  final RateLimiter purchaseLimiter;

  /// Counts every AdMob reward callback per IP ([adCallbacksPerMinute]).
  final RateLimiter adLimiter;

  /// How often [start] sweeps the per-IP limiters.
  final Duration sweepInterval;

  /// Keep-alive ping period for upgraded WebSockets ([webSocketPingInterval]).
  final Duration pingInterval;

  Timer? _sweepTimer;

  /// Starts the periodic sweep of the per-IP limiters: without it every
  /// distinct key would stay in its map forever and memory would grow with the
  /// number of clients ever seen.
  void start() {
    _sweepTimer ??= Timer.periodic(sweepInterval, (_) {
      submitLimiter.sweep();
      upgradeLimiter.sweep();
      playerLimiter.sweep();
      accountLimiter.sweep();
      shopLimiter.sweep();
      purchaseLimiter.sweep();
      adLimiter.sweep();
    });
  }

  /// Cancels the sweeper (server shutdown).
  void close() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  /// The complete shelf handler: error boundary → request log → CORS → routes.
  Handler get handler => const Pipeline()
      .addMiddleware(errorMiddleware(log))
      .addMiddleware(
        logRequests(
          logger: (msg, isError) => isError ? log.warn(msg) : log.debug(msg),
        ),
      )
      .addMiddleware(corsMiddleware())
      .addHandler(router.call);

  late final Router router =
      Router(notFoundHandler: (_) => errorResponse(404, 'not_found'))
        ..get('/api/health', _health)
        ..get('/api/leaderboard', _leaderboard)
        ..get('/api/leaderboard/rank', _rank)
        ..post('/api/scores', _submitScore)
        ..post('/api/players', _createPlayer)
        ..get('/api/players/me', _playerMe)
        ..delete('/api/players/me', _deletePlayer)
        ..post('/api/account/link', _accountLink)
        ..post('/api/account/unlink', _accountUnlink)
        ..get('/api/shop/catalogue', _shopCatalogue)
        ..get('/api/shop/inventory', _shopInventory)
        ..post('/api/shop/buy', _shopBuy)
        ..post('/api/shop/equip', _shopEquip)
        ..post('/api/purchases/webhook', _purchaseWebhook)
        ..post('/api/purchases/sync', _purchaseSync)
        ..get('/api/ads/callback', _adCallback)
        ..get('/api/ads/offer', _adOffer)
        ..get('/ws', _webSocket);

  Response _health(Request request) => jsonResponse(200, {
    'ok': true,
    'version': serverVersion,
    'rooms': rooms.roomCount,
    // Which sign-ins this deployment accepts, so the client shows exactly the
    // buttons that will work instead of guessing. Empty when accounts are off.
    'accounts': accounts.providerNames,
    // Catalogue version this build serves (SPEC §4.8), so a client learns from
    // the call it already makes whether the shop has a kind it cannot draw.
    'catalogue': Catalogue.version,
    // Whether this deployment can take money at all (SPEC §4.9) — i.e. whether
    // the one-time unlock can be bought or restored — for the same reason
    // `accounts` is here: the app shows exactly what will work instead of
    // offering a button that cannot be pressed. It says nothing about any one
    // player; whether *this* player is premium is `GET /api/shop/inventory`.
    'purchases': purchases.enabled,
    // Whether this deployment credits rewarded ads (SPEC §4.10), for the same
    // reason `purchases` is here: the app offers exactly what will work instead
    // of a button that cannot pay.
    'ads': ads.enabled,
  });

  /// The `country` query parameter of SPEC §4.6: the validated code, or the
  /// `400` to answer with. An absent or empty parameter is the global board.
  ({String? country, Response? refusal}) _countryFilter(Request request) {
    final raw = request.url.queryParameters['country'];
    if (raw == null || raw.trim().isEmpty) {
      return (country: null, refusal: null);
    }
    final code = normalizeCountryCode(raw);
    if (code == null) {
      return (
        country: null,
        refusal: errorResponse(
          400,
          invalidCountryError,
          detail: 'country must be an ISO 3166-1 alpha-2 code',
        ),
      );
    }
    return (country: code, refusal: null);
  }

  /// The `balls` query parameter of SPEC §4.6: the board to answer about, or the
  /// `400` to answer with. Absent or empty is [defaultBallCount], the one-ball
  /// board — never the two boards mixed together, which this server does not
  /// serve at all.
  ({int balls, Response? refusal}) _ballFilter(Request request) {
    final balls = parseBallCount(request.url.queryParameters['balls']);
    if (balls == null) {
      return (
        balls: defaultBallCount,
        refusal: errorResponse(
          400,
          invalidBallCountError,
          detail: 'balls must be between $minBallCount and $maxBallCount',
        ),
      );
    }
    return (balls: balls, refusal: null);
  }

  Future<Response> _leaderboard(Request request) async {
    final period = LeaderboardPeriod.parse(
      request.url.queryParameters['period'],
    );
    if (period == null) return errorResponse(400, 'invalid_period');
    // All three filters compose rather than replacing one another: "this week in
    // Poland, two balls" is `?period=week&country=PL&balls=2` (SPEC §4.6).
    final (country: country, refusal: refusal) = _countryFilter(request);
    if (refusal != null) return refusal;
    final (balls: balls, refusal: ballRefusal) = _ballFilter(request);
    if (ballRefusal != null) return ballRefusal;
    final rawLimit = request.url.queryParameters['limit'];
    final limit = (int.tryParse(rawLimit ?? '') ?? LeaderboardService.maxLimit)
        .clamp(1, LeaderboardService.maxLimit);
    final entries = await leaderboard.list(
      period: period,
      limit: limit,
      country: country,
      balls: balls,
    );
    return jsonResponse(200, {
      // Named once in the envelope rather than repeated on every row: every
      // entry is on this board, and a client that omitted the parameter learns
      // from the answer which board it got.
      'balls': balls,
      'entries': [for (final e in entries) e.toJson()],
    });
  }

  Future<Response> _rank(Request request) async {
    final score = int.tryParse(request.url.queryParameters['score'] ?? '');
    if (score == null || score < 0) return errorResponse(400, 'invalid_score');
    final period = LeaderboardPeriod.parse(
      request.url.queryParameters['period'],
    );
    if (period == null) return errorResponse(400, 'invalid_period');
    final (country: country, refusal: refusal) = _countryFilter(request);
    if (refusal != null) return refusal;
    final (balls: balls, refusal: ballRefusal) = _ballFilter(request);
    if (ballRefusal != null) return ballRefusal;
    final rank = await leaderboard.rank(
      score,
      period: period,
      country: country,
      balls: balls,
    );
    return jsonResponse(200, {'rank': rank, 'balls': balls});
  }

  Future<Response> _submitScore(Request request) async {
    final ip = clientIp(request);
    if (!submitLimiter.allow(ip)) {
      return errorResponse(
        429,
        'rate_limited',
      ).change(headers: {'retry-after': '60'});
    }
    // Optional identity: no credentials submits anonymously exactly as before,
    // but credentials that are present and wrong fail closed rather than
    // quietly storing the run under nobody.
    final auth = await players.authenticate(request.headers['authorization']);
    if (auth.error != null) return errorResponse(401, auth.error!);

    final bytes = await readBodyCapped(request, maxScoreBodyBytes);
    if (bytes == null) {
      final declared = request.contentLength;
      log.info(
        'submission rejected: body over $maxScoreBodyBytes bytes'
        '${declared == null ? '' : ' (content-length $declared)'}',
      );
      return errorResponse(
        413,
        'payload_too_large',
        detail:
            'replay body over $maxScoreBodyBytes bytes: the game is too long '
            'to submit - a solo game whose input changes on almost every tick '
            'reaches the cap after roughly 45 minutes of play',
        extra: {'limit': maxScoreBodyBytes},
      );
    }

    // The body is passed on unparsed: decoding up to `maxScoreBodyBytes` of
    // JSON is CPU-bound, and this isolate also drives the 60 Hz room tick, so
    // the decode happens inside the verification isolate.
    final result = await leaderboard.submit(
      bytes,
      ip: ip,
      playerId: auth.player?.id,
    );
    return jsonResponse(result.status, result.body);
  }

  /// `POST /api/players` — issues an anonymous player (SPEC §4.4).
  ///
  /// The body is optional; `{"name":"…"}` presets the display name, which a
  /// score submission later overwrites with whatever the player played under.
  Future<Response> _createPlayer(Request request) async {
    final ip = clientIp(request);
    if (!playerLimiter.allow(ip)) {
      return errorResponse(
        429,
        'rate_limited',
      ).change(headers: {'retry-after': '60'});
    }
    final bytes = await readBodyCapped(request, maxPlayerBodyBytes);
    if (bytes == null) {
      return errorResponse(
        413,
        'payload_too_large',
        extra: {'limit': maxPlayerBodyBytes},
      );
    }

    String? name;
    if (bytes.isNotEmpty) {
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(bytes));
      } catch (e) {
        return errorResponse(400, 'invalid_json', detail: '$e');
      }
      if (json is! Map<String, dynamic>) {
        return errorResponse(
          400,
          'invalid_json',
          detail: 'body must be a JSON object',
        );
      }
      final rawName = json['name'];
      if (rawName != null) {
        if (rawName is! String) return errorResponse(400, 'invalid_name');
        name = normalizeName(rawName);
        if (name == null) return errorResponse(400, 'invalid_name');
        // Same rule as a submission (SPEC §4.7): a name the player could never
        // actually play under is refused here rather than accepted and then
        // rejected later, and the matched entry stays in the log.
        final blocked = offensiveNamePattern(name);
        if (blocked != null) {
          log.info('name rejected (matched "$blocked") name="$name"');
          return errorResponse(400, offensiveNameError);
        }
      }
    }

    final issued = await players.issue(name: name);
    return jsonResponse(201, issued.toJson());
  }

  /// Authenticates a request that *requires* credentials: either the player, or
  /// the `401` to answer with. Absent credentials and wrong ones are separate
  /// codes, but a wrong id and a wrong secret are not (SPEC §4.4).
  Future<({PlayerRow? player, Response? refusal})> _requirePlayer(
    Request request,
  ) async {
    final header = request.headers['authorization'];
    if (header == null || header.trim().isEmpty) {
      return (
        player: null,
        refusal: errorResponse(401, missingCredentialsError),
      );
    }
    final auth = await players.authenticate(header);
    if (!auth.ok) {
      return (player: null, refusal: errorResponse(401, auth.error!));
    }
    return (player: auth.player, refusal: null);
  }

  /// Refuses the call unless the per-IP account budget allows it.
  Response? _accountBudget(Request request) =>
      accountLimiter.allow(clientIp(request))
      ? null
      : errorResponse(
          429,
          'rate_limited',
        ).change(headers: {'retry-after': '60'});

  /// `GET /api/players/me` — what the authenticated player owns (SPEC §4.4).
  Future<Response> _playerMe(Request request) async {
    final (player: player, refusal: refusal) = await _requirePlayer(request);
    if (refusal != null) return refusal;
    // One hop for every board the player has runs on (SPEC §4.6). The
    // top-level numbers stay the one-ball board, which is the board they always
    // described — every run stored before ball counts existed was a one-ball run
    // — so a client that knows nothing about boards keeps reading a true number
    // instead of one averaged over two different games.
    final boards = await players.boards(player!.id);
    final classic = boards.firstWhere(
      (b) => b.balls == defaultBallCount,
      orElse: () => const PlayerStats(games: 0),
    );
    var games = 0;
    for (final b in boards) {
      games += b.games;
    }
    return jsonResponse(200, {
      'ok': true,
      'id': player.id,
      'name': player.name,
      'bestScore': classic.bestScore,
      'rank': classic.rank,
      // Every run the player has submitted, on either board: a count is a count
      // and does not belong to a ranking.
      'games': games,
      // The national standing (SPEC §4.6). The country is the one the player's
      // newest run carried, the same rule the display name follows; all three
      // are explicitly null when there is no such run, like `bestScore`.
      'country': classic.country,
      'countryBestScore': classic.countryBestScore,
      'countryRank': classic.countryRank,
      // The same numbers per board, one entry per board the player has actually
      // played — so a two-ball best and its rank can be shown without the client
      // having to guess which board `bestScore` came from. A player who has
      // submitted nothing gets `[]` rather than two empty boards.
      'boards': [
        for (final b in boards)
          {
            'balls': b.balls,
            'games': b.games,
            'bestScore': b.bestScore,
            'rank': b.rank,
            'countryBestScore': b.countryBestScore,
            'countryRank': b.countryRank,
          },
      ],
      'createdAt': player.createdAt,
      // The linked account, so a client can show "signed in with Apple" and
      // offer sign-out. Absent while the player is anonymous.
      'provider': ?player.accountProvider,
      'linkedAt': ?player.accountLinkedAt,
    });
  }

  /// `POST /api/account/link` — sign in with Apple or Google (SPEC §4.5).
  ///
  /// The `Authorization` header is **optional** and decides which half of the
  /// flow this is: with it, the authenticated anonymous player gains the
  /// account (or is merged into it); without it, the account is restored onto a
  /// device that holds no credentials yet.
  Future<Response> _accountLink(Request request) async {
    if (!accounts.enabled) return errorResponse(404, accountsDisabledError);
    final refusedByBudget = _accountBudget(request);
    if (refusedByBudget != null) return refusedByBudget;

    // Credentials that are present and wrong fail closed here exactly as they
    // do on a submission: linking an account to the wrong player would be a
    // great deal worse than refusing.
    final auth = await players.authenticate(request.headers['authorization']);
    if (auth.error != null) return errorResponse(401, auth.error!);

    final bytes = await readBodyCapped(request, maxAccountBodyBytes);
    if (bytes == null) {
      return errorResponse(
        413,
        'payload_too_large',
        extra: {'limit': maxAccountBodyBytes},
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } catch (e) {
      return errorResponse(400, 'invalid_json', detail: '$e');
    }
    if (json is! Map<String, dynamic>) {
      return errorResponse(
        400,
        'invalid_json',
        detail: 'body must be a JSON object',
      );
    }
    final provider = json['provider'];
    if (provider is! String || !accounts.providers.containsKey(provider)) {
      return errorResponse(
        400,
        invalidProviderError,
        extra: {'providers': accounts.providerNames},
      );
    }
    final idToken = json['idToken'];
    if (idToken is! String || idToken.isEmpty) {
      return errorResponse(
        400,
        'invalid_json',
        detail: 'idToken must be a non-empty string',
      );
    }

    final result = await accounts.signIn(
      provider: provider,
      idToken: idToken,
      caller: auth.player,
    );
    return jsonResponse(result.status, result.body);
  }

  /// `POST /api/account/unlink` — detach the provider account (SPEC §4.5).
  /// The player and every score it owns stay; it is anonymous again.
  Future<Response> _accountUnlink(Request request) async {
    if (!accounts.enabled) return errorResponse(404, accountsDisabledError);
    final refusedByBudget = _accountBudget(request);
    if (refusedByBudget != null) return refusedByBudget;
    final (player: player, refusal: refusal) = await _requirePlayer(request);
    if (refusal != null) return refusal;
    final result = await accounts.unlink(player!);
    return jsonResponse(result.status, result.body);
  }

  /// `DELETE /api/players/me` — delete the caller's player (SPEC §4.5).
  ///
  /// Deliberately *not* gated on the account feature switch: Apple requires an
  /// app that offers account creation to offer account deletion, and an
  /// anonymous player deserves the same.
  Future<Response> _deletePlayer(Request request) async {
    final refusedByBudget = _accountBudget(request);
    if (refusedByBudget != null) return refusedByBudget;
    final (player: player, refusal: refusal) = await _requirePlayer(request);
    if (refusal != null) return refusal;
    final anonymised = await players.delete(player!);
    return jsonResponse(200, {
      'ok': true,
      'deleted': true,
      'scoresAnonymised': anonymised,
    });
  }

  // ---------------------------------------------- cosmetic shop (SPEC §4.8)

  /// Refuses the call unless the per-IP shop budget allows it.
  Response? _shopBudget(Request request) => shopLimiter.allow(clientIp(request))
      ? null
      : errorResponse(
          429,
          'rate_limited',
        ).change(headers: {'retry-after': '60'});

  /// The catalogue version the client asks for (`?v=`), or the `400`.
  ({int? version, Response? refusal}) _clientVersion(Request request) {
    final parsed = ShopService.parseClientVersion(
      request.url.queryParameters['v'],
    );
    if (parsed.error != null) {
      return (
        version: null,
        refusal: errorResponse(
          400,
          parsed.error!,
          detail: 'v must be a catalogue version, 1 or greater',
          extra: {'latestVersion': Catalogue.version},
        ),
      );
    }
    return (version: parsed.version, refusal: null);
  }

  /// `GET /api/shop/catalogue?v=1` — what can be owned and what it costs, with
  /// an `owned` flag per item (SPEC §4.8).
  ///
  /// Credentials are **required**, like `GET /api/players/me`: `owned` is a fact
  /// about a player, and the balance and the equipped slots that ride along are
  /// too. A client opens the shop for somebody, and it has to have issued that
  /// somebody first (SPEC §4.4) — which it must do anyway to have a wallet.
  Future<Response> _shopCatalogue(Request request) async {
    final refusedByBudget = _shopBudget(request);
    if (refusedByBudget != null) return refusedByBudget;
    final (version: version, refusal: badVersion) = _clientVersion(request);
    if (badVersion != null) return badVersion;
    final (player: player, refusal: refusal) = await _requirePlayer(request);
    if (refusal != null) return refusal;
    final result = await shop.catalogue(player!, clientVersion: version!);
    return jsonResponse(result.status, result.body);
  }

  /// `GET /api/shop/inventory?v=1` — the caller's balance, items and slots
  /// (SPEC §4.8).
  Future<Response> _shopInventory(Request request) async {
    final refusedByBudget = _shopBudget(request);
    if (refusedByBudget != null) return refusedByBudget;
    final (version: version, refusal: badVersion) = _clientVersion(request);
    if (badVersion != null) return badVersion;
    final (player: player, refusal: refusal) = await _requirePlayer(request);
    if (refusal != null) return refusal;
    final result = await shop.inventory(player!, clientVersion: version!);
    return jsonResponse(result.status, result.body);
  }

  /// `POST /api/shop/buy` body `{"itemId":"ball.comet"}` (SPEC §4.8).
  ///
  /// The body carries an item id and nothing else: a price or a balance in a
  /// request would be a number the server had to decide whether to believe, and
  /// the answer would always be no.
  Future<Response> _shopBuy(Request request) async {
    final refusedByBudget = _shopBudget(request);
    if (refusedByBudget != null) return refusedByBudget;
    final (version: version, refusal: badVersion) = _clientVersion(request);
    if (badVersion != null) return badVersion;
    final (player: player, refusal: refusal) = await _requirePlayer(request);
    if (refusal != null) return refusal;
    final bytes = await readBodyCapped(request, maxShopBodyBytes);
    if (bytes == null) {
      return errorResponse(
        413,
        'payload_too_large',
        extra: {'limit': maxShopBodyBytes},
      );
    }
    final result = await shop.buy(player!, bytes, clientVersion: version!);
    return jsonResponse(result.status, result.body);
  }

  /// `POST /api/shop/equip` body `{"theme":"theme.glass","ball":null}`
  /// (SPEC §4.8). A slot that is not named is left alone; a null puts that slot
  /// back to the free default.
  Future<Response> _shopEquip(Request request) async {
    final refusedByBudget = _shopBudget(request);
    if (refusedByBudget != null) return refusedByBudget;
    final (version: version, refusal: badVersion) = _clientVersion(request);
    if (badVersion != null) return badVersion;
    final (player: player, refusal: refusal) = await _requirePlayer(request);
    if (refusal != null) return refusal;
    final bytes = await readBodyCapped(request, maxShopBodyBytes);
    if (bytes == null) {
      return errorResponse(
        413,
        'payload_too_large',
        extra: {'limit': maxShopBodyBytes},
      );
    }
    final result = await shop.equip(player!, bytes, clientVersion: version!);
    return jsonResponse(result.status, result.body);
  }

  // --------------------------------------- the one-time unlock (SPEC §4.9)

  /// `POST /api/purchases/webhook` — RevenueCat's authoritative purchase signal
  /// (SPEC §4.9).
  ///
  /// No player credentials: the caller is RevenueCat, and what authenticates it
  /// is the shared secret it sends in `Authorization`, checked in
  /// `PurchaseService.webhook` in constant time before the body is even decoded.
  ///
  /// Metered per IP ([purchaseWebhooksPerMinute]) so that an unauthenticated
  /// flood costs a rejected request rather than a JSON decode each; RevenueCat
  /// retries a `429` like any other non-2xx, so the limit cannot lose a purchase.
  Future<Response> _purchaseWebhook(Request request) async {
    final ip = clientIp(request);
    if (!purchaseLimiter.allow(ip)) {
      return errorResponse(
        429,
        'rate_limited',
      ).change(headers: {'retry-after': '60'});
    }
    final bytes = await readBodyCapped(request, maxWebhookBodyBytes);
    if (bytes == null) {
      return errorResponse(
        413,
        'payload_too_large',
        extra: {'limit': maxWebhookBodyBytes},
      );
    }
    final result = await purchases.webhook(
      bytes,
      authorization: request.headers['authorization'],
    );
    return jsonResponse(result.status, result.body);
  }

  /// `POST /api/purchases/sync` — the client's nudge after a purchase, and
  /// **Restore purchases** (SPEC §4.9).
  ///
  /// Requires the credentials of SPEC §4.4, because it is a question about one
  /// player's entitlement. The body is **read and discarded**: nothing a phone
  /// could put in it is used, and the server asks RevenueCat instead. The cap
  /// exists only so an oversized body is answered rather than streamed.
  ///
  /// This is also **Restore purchases**: the unlock is a non-consumable, so the
  /// store still holds it after a reinstall and this call is how it comes back.
  ///
  /// Metered by the shop budget, since it is one of the calls a player makes
  /// while looking at the shop screen.
  Future<Response> _purchaseSync(Request request) async {
    final refusedByBudget = _shopBudget(request);
    if (refusedByBudget != null) return refusedByBudget;
    final (player: player, refusal: refusal) = await _requirePlayer(request);
    if (refusal != null) return refusal;
    final bytes = await readBodyCapped(request, maxSyncBodyBytes);
    if (bytes == null) {
      return errorResponse(
        413,
        'payload_too_large',
        extra: {'limit': maxSyncBodyBytes},
      );
    }
    final result = await purchases.sync(player!);
    return jsonResponse(result.status, result.body);
  }

  // ------------------------------------------- rewarded ads (SPEC §4.10)

  /// `GET /api/ads/callback` — AdMob's server-side verification, the only path in
  /// this server that turns a watched ad into Sparks (SPEC §4.10).
  ///
  /// No player credentials and no request body: the caller is Google, the method
  /// is the `GET` AdMob makes, and what authenticates it is the ECDSA signature
  /// over the query string, checked in `AdsService.callback` before anything is
  /// looked up or written.
  ///
  /// The **raw** query string is handed over rather than the parsed parameters:
  /// the signature covers those exact bytes, and `Request.url` has already
  /// percent-decoded them. `requestedUri` is what preserves them.
  ///
  /// Metered per IP ([adCallbacksPerMinute]) so an unauthenticated flood costs a
  /// rejected request rather than a signature verification each; AdMob retries a
  /// `429` like any other non-2xx, so the limit cannot lose a reward.
  Future<Response> _adCallback(Request request) async {
    final ip = clientIp(request);
    if (!adLimiter.allow(ip)) {
      return errorResponse(
        429,
        'rate_limited',
      ).change(headers: {'retry-after': '60'});
    }
    final result = await ads.callback(request.requestedUri.query);
    return jsonResponse(result.status, result.body);
  }

  /// `GET /api/ads/offer` — the caller's ad allowance (SPEC §4.10).
  ///
  /// Requires the credentials of SPEC §4.4, because it is a question about one
  /// player's allowance and wallet. It is read-only and cannot credit anything;
  /// the app calls it to decide whether to offer an ad at all, and again
  /// afterwards to notice the credit arrive.
  ///
  /// Metered by the shop budget, since it is one of the calls a player makes while
  /// looking at a screen.
  Future<Response> _adOffer(Request request) async {
    final refusedByBudget = _shopBudget(request);
    if (refusedByBudget != null) return refusedByBudget;
    final (player: player, refusal: refusal) = await _requirePlayer(request);
    if (refusal != null) return refusal;
    final result = await ads.offer(player!);
    return jsonResponse(result.status, result.body);
  }

  /// Upgrades to a WebSocket and hands the channel to the room registry.
  /// `webSocketHandler` throws [HijackException] on success, which shelf_io
  /// turns into the upgrade response.
  ///
  /// The upgrade runs through [guardClientFrames]: `dart:io` buffers a whole
  /// message before the session can check its size, so the wire-level cap has
  /// to be applied to the socket itself.
  Future<Response> _webSocket(Request request) {
    final ip = clientIp(request);
    // Metered before the upgrade, so socket churn costs the peer a rejected
    // request instead of a WebSocket handshake and a session slot.
    if (!upgradeLimiter.allow(ip)) {
      log.warn(
        'refusing /ws upgrade from $ip: more than $wsUpgradesPerIpPerMinute '
        'per minute',
      );
      return Future<Response>.value(
        errorResponse(
          429,
          'rate_limited',
        ).change(headers: {'retry-after': '60'}),
      );
    }
    final upgrade = webSocketHandler(
      (channel, _) => rooms.accept(channel, ip),
      pingInterval: pingInterval,
    );
    return Future<Response>.sync(
      () => upgrade(guardClientFrames(request, log: log)),
    );
  }
}
