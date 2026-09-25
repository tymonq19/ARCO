/// Leaderboard logic: submission validation, replay verification and queries.
/// HTTP concerns (status codes, body parsing, IPs) live in `api.dart`.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:arco_core/arco_core.dart';
import 'package:crypto/crypto.dart';

import 'country.dart';
import 'db.dart';
import 'logging.dart';
import 'name_filter.dart';
import 'players.dart';
import 'score_store.dart';

/// Outcome of a score submission: an HTTP status plus a JSON body.
class SubmitResult {
  const SubmitResult._(this.status, this.body);

  factory SubmitResult.error(String code, {String? detail}) =>
      SubmitResult._(400, {'ok': false, 'error': code, 'detail': ?detail});

  factory SubmitResult.created({
    required String id,
    required int score,
    required int rank,
    String? playerId,
    String? country,
    int? countryRank,
    int? tokens,
    int? tokenBalance,
  }) => SubmitResult._(201, {
    'ok': true,
    'id': id,
    'score': score,
    'rank': rank,
    // Echoed back so a client can confirm the run was attached to it before
    // the row shows up on the leaderboard. Absent for anonymous submissions.
    'playerId': ?playerId,
    // The country the run was filed under and the rank it took there
    // (SPEC §4.6). Both present exactly when the submission carried a usable
    // code, which is also how a client learns its hint was accepted — an
    // unusable one is dropped silently rather than failing the submission.
    'country': ?country,
    'countryRank': ?countryRank,
    // What the run paid into the player's wallet and what the wallet holds
    // afterwards (SPEC §4.8), so the game-over screen can show "+24" without a
    // second request. Both are computed from the score **this server** just
    // verified, and both are absent for an anonymous submission, which has no
    // wallet to pay into.
    'tokens': ?tokens,
    'tokenBalance': ?tokenBalance,
  });

  final int status;
  final Map<String, dynamic> body;

  bool get ok => status == 201;
}

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.rank,
    required this.name,
    required this.score,
    required this.seconds,
    required this.createdAt,
    this.playerId,
    this.country,
  });

  final int rank;
  final String name;
  final int score;
  final int seconds;
  final String createdAt;

  /// Country the run counts for on the national board (SPEC §4.6), or null when
  /// it carried no usable code.
  final String? country;

  /// Owning player (SPEC §4.4), absent for an anonymous run — which is what
  /// every row stored before player identity existed is.
  ///
  /// This is how a client highlights its own entries: it compares this against
  /// the player id it holds, instead of remembering the ids it once submitted
  /// (which a reinstall loses).
  final String? playerId;

  Map<String, dynamic> toJson() => {
    'rank': rank,
    'name': name,
    'score': score,
    'seconds': seconds,
    'createdAt': createdAt,
    'playerId': ?playerId,
    // Present only when the run carried a country (SPEC §4.6), so a client can
    // show a flag on the global board and knows an absent key means "unknown",
    // which is what every run stored before national ranking existed is.
    'country': ?country,
  };
}

/// Everything about a submission that has to be decided before storage: the
/// parse, the SPEC §4 validation and (unless disabled) the re-simulation.
/// Computed on a helper isolate, so it carries plain values only.
class CheckedSubmission {
  const CheckedSubmission._({
    this.error,
    this.detail,
    this.name = '',
    this.claimedScore = 0,
    this.score = 0,
    this.ticks = 0,
    this.hash = 0,
    this.seed = 0,
    this.country,
    this.replayKey = '',
  });

  /// [error] is the SPEC §4 error code; [name] and [claimedScore] are filled in
  /// once they are known, for the rejection log.
  const CheckedSubmission.rejected(
    String error, {
    String? detail,
    String name = '',
    int claimedScore = 0,
  }) : this._(
         error: error,
         detail: detail,
         name: name,
         claimedScore: claimedScore,
       );

  /// The values to store: the score comes from the verification, not the claim.
  const CheckedSubmission.accepted({
    required String name,
    required int score,
    required int ticks,
    required int hash,
    required int seed,
    required String replayKey,
    String? country,
  }) : this._(
         name: name,
         score: score,
         ticks: ticks,
         hash: hash,
         seed: seed,
         country: country,
         replayKey: replayKey,
       );

  /// Error code, or null when the submission may be stored.
  final String? error;
  final String? detail;

  /// Normalized name; empty when the body never got that far.
  final String name;

  /// Score the client claimed (rejection log only).
  final int claimedScore;

  final int score;
  final int ticks;
  final int hash;
  final int seed;

  /// Validated country of the run, or null when the body carried none — or
  /// carried something that is not an ISO 3166-1 alpha-2 code (SPEC §4.6).
  final String? country;

  /// Fingerprint of the run, for token deduplication (SPEC §4.8); empty on a
  /// rejected submission, which never reaches the wallet. See
  /// [replayFingerprint].
  final String replayKey;

  bool get ok => error == null;
}

/// A digest that identifies one recorded **run**, for the token ledger of
/// SPEC §4.8.
///
/// Why not hash the request body: the same run re-encoded with different
/// whitespace, key order or redundant input entries is the same run, and would
/// get a different digest — so a body digest would be trivial to defeat. This
/// hashes the run as the server *parsed* it: the mode, the seed, the tick the
/// game ended on, and every surviving input entry. `InputLog.fromJson` already
/// drops entries that do not change the input, so padding a log cannot mint a
/// new fingerprint either.
///
/// Why not the verified score or `GameState.hash`: both are 32-bit-ish functions
/// of this same data, so they would collide between genuinely different runs.
/// What is hashed here *is* the run, and the score is a consequence of it.
///
/// The key is global rather than per player, so a replay that leaks is worth
/// nothing to whoever copies it — the first submission of a run is the only one
/// that can ever pay.
String replayFingerprint(Replay replay) {
  final canonical = StringBuffer()
    ..write('arco-run-v1|')
    ..write(replay.config.mode.index)
    ..write('|')
    ..write(replay.config.seed)
    ..write('|')
    ..write(replay.finalTick);
  for (final log in replay.inputs) {
    canonical.write('|');
    var first = true;
    for (final entry in log.toJson()) {
      if (!first) canonical.write(',');
      first = false;
      canonical
        ..write(entry[0])
        ..write(':')
        ..write(entry[1]);
    }
  }
  return sha256.convert(utf8.encode(canonical.toString())).toString();
}

/// Checks a raw `POST /api/scores` body on a helper isolate so that the event
/// loop keeps serving rooms and requests.
///
/// Both halves of the work are synchronous and CPU-bound: decoding up to 2 MB
/// of JSON and rebuilding the input logs costs tens of milliseconds, the
/// re-simulation up to [ReplayVerifier.maxTicks] steps. The isolate that
/// answers requests also drives the 60 Hz room tick, so neither half may run
/// on it — a handful of concurrent submissions would otherwise starve every
/// live duel.
Future<CheckedSubmission> checkSubmissionInIsolate(
  Uint8List body, {
  required bool verifyReplays,
}) => Isolate.run(() => checkSubmission(body, verifyReplays: verifyReplays));

/// The synchronous body of [checkSubmissionInIsolate]: decode, validate and
/// (when [verifyReplays]) re-simulate. Pure, so it can also be called directly.
CheckedSubmission checkSubmission(
  Uint8List body, {
  required bool verifyReplays,
}) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(body));
  } on FormatException catch (e) {
    return CheckedSubmission.rejected('invalid_json', detail: e.message);
  }
  if (json is! Map<String, dynamic>) {
    return const CheckedSubmission.rejected(
      'invalid_json',
      detail: 'body must be a JSON object',
    );
  }

  final rawName = json['name'];
  final name = rawName is String ? normalizeName(rawName) : null;
  if (name == null) return const CheckedSubmission.rejected('invalid_name');
  // SPEC §4.2 only asks whether a name is well-formed; SPEC §4.7 asks whether it
  // belongs on a board children see. The matched pattern travels in `detail` for
  // the server log and is dropped before the response: telling the author which
  // entry fired is tuning help for the next attempt.
  final blocked = offensiveNamePattern(name);
  if (blocked != null) {
    return CheckedSubmission.rejected(
      offensiveNameError,
      detail: 'matched "$blocked"',
      name: name,
    );
  }

  // A hint the client derives from the device locale (SPEC §4.6), never a claim
  // this server verifies. Anything that is not a currently assigned ISO 3166-1
  // alpha-2 code is dropped and the run is stored without a country: a locale
  // oddity must not cost somebody a verified score.
  final country = normalizeCountryCode(json['country']);

  final rawReplay = json['replay'];
  if (rawReplay is! Map<String, dynamic>) {
    return CheckedSubmission.rejected(
      'invalid_replay',
      detail: 'replay must be an object',
      name: name,
    );
  }
  final Replay replay;
  try {
    replay = Replay.fromJson(rawReplay);
  } catch (e) {
    return CheckedSubmission.rejected(
      'invalid_replay',
      detail: 'malformed replay: $e',
      name: name,
    );
  }
  if (replay.formatVersion != Replay.version) {
    return CheckedSubmission.rejected(
      'unsupported_version',
      detail:
          'replay version ${replay.formatVersion}, server supports ${Replay.version}',
      name: name,
    );
  }
  if (replay.config.mode != GameMode.solo) {
    return CheckedSubmission.rejected(
      'invalid_replay',
      detail: 'only solo replays can be submitted',
      name: name,
    );
  }
  if (replay.inputs.length != replay.config.playerCount) {
    return CheckedSubmission.rejected(
      'invalid_replay',
      detail: 'expected ${replay.config.playerCount} input log(s)',
      name: name,
    );
  }
  if (replay.finalTick < 0 || replay.claimedScore < 0) {
    return CheckedSubmission.rejected(
      'invalid_replay',
      detail: 'negative finalTick or claimedScore',
      name: name,
    );
  }
  if (replay.finalTick > ReplayVerifier.maxTicks) {
    return CheckedSubmission.rejected(
      'replay_mismatch',
      detail: 'too_long',
      name: name,
      claimedScore: replay.claimedScore,
    );
  }
  // A log holds at most one entry per simulated tick (ticks strictly increase
  // and only 0..finalTick-1 are ever applied), so a longer log is padding the
  // verifier could never read. Checking it here bounds a submission by its
  // tick count rather than leaving the request-body cap
  // (`maxScoreBodyBytes`) as the only bound on the work it can ask for.
  for (final log in replay.inputs) {
    if (log.length > replay.finalTick) {
      return CheckedSubmission.rejected(
        'invalid_replay',
        detail:
            'input log has ${log.length} entries for '
            '${replay.finalTick} tick(s)',
        name: name,
        claimedScore: replay.claimedScore,
      );
    }
  }

  // Computed here rather than on the request isolate: this function already
  // runs on a helper isolate because it is CPU-bound, and a digest over a long
  // input log belongs with the rest of that work.
  final replayKey = replayFingerprint(replay);

  if (!verifyReplays) {
    return CheckedSubmission.accepted(
      name: name,
      score: replay.claimedScore,
      ticks: replay.finalTick,
      hash: 0,
      seed: replay.config.seed,
      country: country,
      replayKey: replayKey,
    );
  }
  final result = ReplayVerifier.verify(replay);
  if (!result.ok) {
    return CheckedSubmission.rejected(
      'replay_mismatch',
      detail: result.reason ?? 'verification failed',
      name: name,
      claimedScore: replay.claimedScore,
    );
  }
  return CheckedSubmission.accepted(
    name: name,
    score: result.score,
    ticks: result.ticks,
    hash: result.hash,
    seed: replay.config.seed,
    country: country,
    replayKey: replayKey,
  );
}

class LeaderboardService {
  LeaderboardService({
    required this.store,
    required this.verifyReplays,
    required this.log,
    Random? random,
    DateTime Function()? clock,
  }) : _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  /// Storage, reached asynchronously: every SQLite call runs on the store's
  /// own isolate so that neither a large query nor a locked database can stall
  /// the tick driver (see [ScoreStore]).
  final ScoreStore store;

  /// When false (`VERIFY_REPLAYS=off`) the claimed score is stored unverified.
  final bool verifyReplays;
  final Logger log;
  final Random _random;
  final DateTime Function() _clock;

  static const int maxLimit = 100;

  /// Validates and (unless disabled) verifies a submission, stores the
  /// verified score and returns the response.
  ///
  /// [body] is the raw request body (already size-capped by the HTTP layer):
  /// it is handed to a helper isolate unparsed, because decoding it is as
  /// CPU-bound as the re-simulation and must not block the tick driver.
  /// [ip] identifies the submitter (hashed before storage). [playerId] is the
  /// already-authenticated owner, or null for an anonymous submission — which
  /// must keep working exactly as it did before player identity existed.
  Future<SubmitResult> submit(
    Uint8List body, {
    required String ip,
    String? playerId,
  }) async {
    final checked = await checkSubmissionInIsolate(
      body,
      verifyReplays: verifyReplays,
    );
    if (!checked.ok) {
      if (checked.error == 'replay_mismatch') {
        log.info(
          'replay rejected (${checked.detail}) name="${checked.name}" claimed=${checked.claimedScore}',
        );
      }
      if (checked.error == offensiveNameError) {
        // Logged with the entry that fired, so the list can be tuned; answered
        // without it, so the author is not handed the filter's rule book.
        log.info('name rejected (${checked.detail}) name="${checked.name}"');
        return SubmitResult.error(offensiveNameError);
      }
      return SubmitResult.error(checked.error!, detail: checked.detail);
    }

    final id = newId();
    final now = _clock();
    await store.insert(
      ScoreRow(
        id: id,
        name: checked.name,
        score: checked.score,
        ticks: checked.ticks,
        seed: checked.seed,
        createdAt: Db.formatTimestamp(now),
        ipHash: hashIp(ip),
        hash: checked.hash,
        playerId: playerId,
        country: checked.country,
      ),
    );
    TokenAward? award;
    if (playerId != null) {
      // The display name follows the name the player last actually played
      // under, so `GET /api/players/me` agrees with the leaderboard.
      await store.notePlayerScore(playerId, checked.name, now);
      // Tokens for the cosmetic shop (SPEC §4.8). The only number that goes in
      // is `checked.score` — the score this server just computed by
      // re-simulating the replay — and the rate, the daily cap and the
      // deduplication all live inside that one transaction. An anonymous
      // submission has no wallet and earns nothing, which is also the honest
      // answer: there is nobody to pay.
      award = await store.awardTokens(
        playerId: playerId,
        scoreId: id,
        score: checked.score,
        replayKey: checked.replayKey,
        now: now,
      );
    }
    final rank = await store.rank(checked.score);
    // The point of the national board: this number is reachable, and the client
    // can show it the moment the run is stored instead of making the player go
    // looking for it.
    final countryRank = checked.country == null
        ? null
        : await store.rank(checked.score, country: checked.country);
    log.info(
      'score stored id=$id name="${checked.name}" score=${checked.score} '
      'ticks=${checked.ticks} rank=$rank player=${playerId ?? '-'} '
      'country=${checked.country ?? '-'}'
      '${award == null ? '' : ' tokens=${award.tokens}'
                '${award.duplicate ? ' (duplicate run)' : ''}'
                '${award.cappedByDay ? ' (daily cap)' : ''}'}',
    );
    return SubmitResult.created(
      id: id,
      score: checked.score,
      rank: rank,
      playerId: playerId,
      country: checked.country,
      countryRank: countryRank,
      tokens: award?.tokens,
      tokenBalance: award?.balance,
    );
  }

  /// The board for [period], restricted to [country] when one is given.
  ///
  /// The two filters compose (SPEC §4.6): "this week in Poland" is one query,
  /// and `rank` is the position **within the returned slice**, so the national
  /// board is numbered 1..N of its own and not by global position. A player who
  /// is 4 000th in the world can be 12th at home, which is the only reason to
  /// show a ranking at all.
  Future<List<LeaderboardEntry>> list({
    LeaderboardPeriod period = LeaderboardPeriod.all,
    int limit = maxLimit,
    String? country,
  }) async {
    final rows = await store.topScores(
      period: period,
      limit: limit.clamp(1, maxLimit),
      now: _clock(),
      country: country,
    );
    return [
      for (var i = 0; i < rows.length; i++)
        LeaderboardEntry(
          rank: i + 1,
          name: rows[i].name,
          score: rows[i].score,
          seconds: rows[i].ticks ~/ tickRate,
          createdAt: rows[i].createdAt,
          playerId: rows[i].playerId,
          country: rows[i].country,
        ),
    ];
  }

  Future<int> rank(
    int score, {
    LeaderboardPeriod period = LeaderboardPeriod.all,
    String? country,
  }) => store.rank(score, period: period, now: _clock(), country: country);

  /// 128 random bits as 32 hex characters — the same id shape players use.
  String newId() => randomHexId(_random);

  static String hashIp(String ip) => sha256.convert(utf8.encode(ip)).toString();
}
