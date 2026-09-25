/// Sign in with Apple and Google, server side (SPEC §4.5).
///
/// Token verification lives in `id_token.dart`; the storage transaction lives in
/// `Db.linkAccount`. This file is the part in between: it decides which
/// provider a request means, turns a verified token into the one operation that
/// links, restores or merges, and shapes the answer.
///
/// The product flow it serves: the player plays anonymously and at some point
/// is offered "keep your scores and play on any device". The phone performs the
/// native sign-in, receives a signed JWT, and posts it here together with the
/// anonymous credentials it already holds. From then on the runs belong to a
/// real account, and signing in on a second phone restores them there — without
/// signing the first phone out.
///
/// What is stored: the provider name and its opaque subject id, nothing else.
/// The tokens carry an address (Apple's is often a private-relay alias) and
/// frequently a real name; both are dropped in `id_token.dart` and there is no
/// column to put them in (SPEC §4.5). The privacy policy this feature needs is
/// therefore one sentence long, and that is the point.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'config.dart';
import 'db.dart';
import 'id_token.dart';
import 'logging.dart';
import 'players.dart';
import 'score_store.dart';

/// `POST /api/account/*` bodies larger than this are rejected with 413.
///
/// An identity token is under 1 KB from both providers and
/// [maxIdTokenChars] caps it at 4 KB; this bounds the JSON around it.
const int maxAccountBodyBytes = 8 * 1024;

/// The body named a provider this server does not accept tokens for — either an
/// unknown name, or one with no client ids configured.
const String invalidProviderError = 'invalid_provider';

/// The token failed verification. The coarse reason is reported as `reason`;
/// the detail goes to the log only.
const String invalidTokenError = 'invalid_token';

/// The whole feature is switched off (`ACCOUNTS_ENABLED` unset or `off`).
const String accountsDisabledError = 'accounts_disabled';

/// Outcome of an account operation: an HTTP status plus a JSON body, the same
/// shape `LeaderboardService.submit` returns, so `api.dart` stays routing only.
class AccountResult {
  const AccountResult(this.status, this.body);

  /// A refusal, plus whatever extra fields the client can act on.
  factory AccountResult.error(
    int status,
    String code, {
    Map<String, dynamic>? extra,
  }) => AccountResult(status, {'ok': false, 'error': code, ...?extra});

  final int status;
  final Map<String, dynamic> body;

  bool get ok => status == 200;
}

/// Builds the providers named by [config], or an empty map when the feature is
/// off.
///
/// [fetch] and the `…JwksUri` overrides exist so the tests can point a provider
/// at a fake key server on loopback: no test ever reaches Apple or Google.
Map<String, AccountProvider> accountProvidersFor(
  AccountsConfig config, {
  required Logger log,
  JwksFetcher? fetch,
  Uri? appleJwksUri,
  Uri? googleJwksUri,
}) {
  if (!config.enabled) return const <String, AccountProvider>{};
  return {
    if (config.appleClientIds.isNotEmpty)
      appleProviderName: AccountProvider.apple(
        audiences: config.appleClientIds,
        log: log,
        fetch: fetch,
        jwksUri: appleJwksUri,
      ),
    if (config.googleClientIds.isNotEmpty)
      googleProviderName: AccountProvider.google(
        audiences: config.googleClientIds,
        log: log,
        fetch: fetch,
        jwksUri: googleJwksUri,
      ),
  };
}

class AccountService {
  AccountService({
    required this.store,
    required this.players,
    required this.providers,
    required this.log,
    IdTokenVerifier? verifier,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       verifier =
           verifier ?? IdTokenVerifier(log: log, clock: clock ?? DateTime.now);

  final ScoreStore store;

  /// Used to mint credentials; the secret must exist before the transaction
  /// that stores its digest runs.
  final PlayerService players;

  /// Providers this server accepts tokens for, by name.
  final Map<String, AccountProvider> providers;

  final IdTokenVerifier verifier;
  final Logger log;
  final DateTime Function() _clock;

  /// Whether the account endpoints are live. False switches them all to
  /// [accountsDisabledError] without touching anything else the server does.
  bool get enabled => providers.isNotEmpty;

  /// Provider names to advertise on `GET /api/health`, so a client knows which
  /// sign-in buttons to show instead of guessing.
  List<String> get providerNames => providers.keys.toList(growable: false);

  /// Verifies [idToken] and attaches the account it proves to a player
  /// (SPEC §4.5).
  ///
  /// [caller] is the already-authenticated anonymous player, or null when the
  /// request carried no credentials — a fresh install signing in, which is how
  /// an account is restored onto a second device.
  ///
  /// Nothing is written until the token has passed every check in
  /// [IdTokenVerifier.verify], and the subject is taken from the verified
  /// payload, never from anything the caller said.
  Future<AccountResult> signIn({
    required String provider,
    required String idToken,
    PlayerRow? caller,
  }) async {
    final target = providers[provider];
    if (target == null) {
      return AccountResult.error(
        400,
        invalidProviderError,
        extra: {'providers': providerNames},
      );
    }

    final VerifiedIdToken token;
    try {
      token = await verifier.verify(target, idToken);
    } on IdTokenException catch (e) {
      // Every failure is the same thing to the caller — this token is not
      // usable — but the coarse reason is reported because it tells an honest
      // client what to do next: `expired_token` means run the native sign-in
      // again, `wrong_audience` means the build is misconfigured. The free-text
      // detail stays in the log.
      log.warn('rejected $provider identity token: $e');
      if (e.isServerSide) {
        return AccountResult.error(503, IdTokenException.keysUnavailableCode);
      }
      return AccountResult.error(
        401,
        invalidTokenError,
        extra: {'reason': e.code},
      );
    }

    final credential = players.mintCredential();
    final result = await store.linkAccount(
      AccountLinkRequest(
        provider: token.provider,
        subject: token.subject,
        callerPlayerId: caller?.id,
        // The token is identified by its digest and never stored: the ledger
        // has to recognise a retry, not be able to reconstruct a credential.
        tokenHash: hashIdToken(idToken),
        tokenExpiresAt: token.expiresAt,
        newPlayerId: players.newId(),
        credentialId: credential.id,
        secretHash: credential.secretHash,
        now: _clock(),
      ),
    );

    if (!result.ok) {
      log.info(
        'refused ${token.provider} link for player ${caller?.id}: '
        '${result.error}',
      );
      return AccountResult.error(
        409,
        result.error!,
        extra: {'provider': ?result.conflictProvider},
      );
    }

    final playerId = result.playerId!;
    final stats = await store.playerScores(playerId);
    log.info(
      'account ${result.kind!.name} provider=${token.provider} '
      'player=$playerId'
      '${result.movedScores > 0 ? ' moved=${result.movedScores}' : ''}',
    );
    return AccountResult(200, {
      'ok': true,
      'id': playerId,
      'secret': credential.secret,
      'name': result.name,
      'provider': token.provider,
      'outcome': result.kind!.name,
      'linkedAt': result.linkedAt,
      'createdAt': result.createdAt,
      // Runs carried over from the absorbed player; 0 unless `outcome` is
      // `merged`, so a client can say "your 12 runs are now on this account".
      'movedScores': result.movedScores,
      'bestScore': stats.bestScore,
      'rank': stats.rank,
      'games': stats.games,
      // The same national standing `GET /api/players/me` reports (SPEC §4.6).
      // Worth having here because a merge changes it: the runs of both halves
      // are now one player's, so the country rank the phone was showing a moment
      // ago is stale.
      'country': stats.country,
      'countryBestScore': stats.countryBestScore,
      'countryRank': stats.countryRank,
    });
  }

  /// Detaches the provider account from [player], keeping the player and every
  /// score it owns (SPEC §4.5).
  ///
  /// Idempotent: unlinking a player that has no account is a `200` saying so.
  /// The player's other devices keep their credentials and go on playing as the
  /// same, now anonymous, player.
  Future<AccountResult> unlink(PlayerRow player) async {
    final unlinked = await store.unlinkAccount(player.id);
    if (unlinked) log.info('account unlinked player=${player.id}');
    return AccountResult(200, {
      'ok': true,
      'id': player.id,
      'unlinked': unlinked,
      'provider': ?player.accountProvider,
    });
  }

  /// SHA-256 of a raw identity token, hex — the replay ledger's key.
  ///
  /// A digest rather than the token, because the ledger only has to answer "has
  /// this exact token been presented before?", and a table of live identity
  /// tokens would be worth stealing.
  static String hashIdToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();
}
