import 'package:arco_core/arco_core.dart';

import 'api_client.dart';
import 'player_identity.dart';
import 'storage.dart';

/// Outcome of a leaderboard submission.
sealed class SubmitOutcome {
  const SubmitOutcome();
}

class SubmitAccepted extends SubmitOutcome {
  const SubmitAccepted({
    required this.id,
    required this.score,
    required this.rank,
    this.country,
    this.countryRank,
    this.tokens,
    this.tokenBalance,
  });
  final String id;
  final int score;
  final int rank;

  /// The country the run was filed under and its rank there (SPEC §4.6); both
  /// null when the submission carried no usable country.
  final String? country;
  final int? countryRank;

  /// What this run earned for the shop and what the wallet holds afterwards
  /// (SPEC §4.8). Both null when the run went up anonymously — there is no
  /// wallet then, and saying "+0" would be a different claim from saying
  /// nothing. The numbers are the server's, from the score **it** verified.
  final int? tokens;
  final int? tokenBalance;
}

/// The server could not be reached; the replay is stored for a later retry.
class SubmitDeferred extends SubmitOutcome {
  const SubmitDeferred();
}

class SubmitRejected extends SubmitOutcome {
  const SubmitRejected(this.error, {this.canRetryUnderNewName = false});
  final String error;

  /// The replay is still stored and a different nickname is all it needs: the
  /// name filter of SPEC §4.7 refused this one. Use
  /// [ScoreSubmitter.retryPendingAs].
  final bool canRetryUnderNewName;
}

/// Submits solo replays and keeps a single pending replay while offline.
class ScoreSubmitter {
  ScoreSubmitter({
    required this.api,
    required this.storage,
    required this.identity,
  });

  /// The pending-replay upload currently in flight, per [Storage].
  ///
  /// SPEC §5.1 retries the pending replay at app start and whenever the solo
  /// screen or the leaderboard opens; each of those call sites builds its own
  /// submitter over the same storage, so the guard has to be shared by the
  /// pending slot they share. Without it a retry that is still in flight (the
  /// API times out only after 8 s) is started a second time and the same game
  /// lands on the leaderboard twice.
  static final Map<Storage, Future<SubmitOutcome?>> _retriesInFlight =
      <Storage, Future<SubmitOutcome?>>{};

  final ApiClient api;
  final Storage storage;

  /// Who the run belongs to and where it was played (SPEC §4.4 / §4.6). The
  /// identity is issued here, on the first submission, and nowhere else.
  final PlayerIdentity identity;

  bool get hasPending => storage.pendingReplay != null;

  /// Submits [replay]. Offline → stored as pending (replacing any older one
  /// with a lower score). Only the server's own verdict (SPEC §4) drops the
  /// replay; rate limiting and anything we cannot interpret keep it.
  Future<SubmitOutcome> submit(String name, Replay replay) async {
    try {
      final r = await _upload(name, replay);
      if (r.ok) {
        await _recordAccepted(name, r);
        return SubmitAccepted(
          id: r.id ?? '',
          score: r.score,
          rank: r.rank,
          country: r.country,
          countryRank: r.countryRank,
          tokens: r.tokens,
          tokenBalance: r.tokenBalance,
        );
      }
      if (r.isOffensiveName) {
        // The run itself was verified; only the nickname was refused (SPEC
        // §4.7). Keeping the replay means a different name is all it takes to
        // put this game on the board.
        await _defer(name, replay);
        return const SubmitRejected(
          offensiveNameError,
          canRetryUnderNewName: true,
        );
      }
      if (r.isUnsupportedVersion) {
        // Never judged: the server does not read this build's replay format
        // (SPEC §2.5). Keeping the game is what makes "update Arco to submit
        // this score" true — after an update the very same run goes up.
        await _defer(name, replay);
        return const SubmitRejected(unsupportedVersionError);
      }
      if (r.shouldRetryLater) {
        await _defer(name, replay);
        return const SubmitDeferred();
      }
      return SubmitRejected(r.error ?? 'invalid_replay');
    } on ApiException {
      // An [ApiException] means no usable answer came back (transport failure,
      // timeout, 5xx), so the score is kept for a retry rather than lost.
      await _defer(name, replay);
      return const SubmitDeferred();
    }
  }

  /// Retries the stored replay, if any. Returns null when nothing is pending
  /// or the server is still unreachable (the replay stays stored).
  ///
  /// Concurrent calls (from any submitter over the same [Storage]) join the
  /// upload already in flight instead of starting a second one.
  Future<SubmitOutcome?> retryPending() {
    final inFlight = _retriesInFlight[storage];
    if (inFlight != null) return inFlight;
    if (storage.pendingReplay == null) return Future<SubmitOutcome?>.value();
    final upload = _uploadPending();
    _retriesInFlight[storage] = upload;
    // Cleared once the upload settles rather than inside it, so the entry
    // cannot outlive an upload that fails before its first suspension.
    return upload.whenComplete(() => _retriesInFlight.remove(storage));
  }

  /// Re-files the stored replay under [name] and uploads it again — what happens
  /// after a nickname was refused by the filter of SPEC §4.7 and the player
  /// picked another one.
  Future<SubmitOutcome?> retryPendingAs(String name) async {
    await storage.renamePendingReplay(name);
    return retryPending();
  }

  /// One submission, with whatever identity the player has.
  ///
  /// SPEC §4.4: a `401` means the credentials were refused and **nothing was
  /// stored**, so a stale secret costs a round trip and not the score — it is
  /// discarded, a fresh identity is issued and the same replay goes up once
  /// more, anonymously if issuing fails.
  Future<SubmitResult> _upload(String name, Replay replay) async {
    final country = identity.countryForSubmission();
    final credentials = await identity.ensureIssued();
    final first = await api.submitScore(
      name,
      replay,
      credentials: credentials,
      country: country,
    );
    if (!first.isUnauthorized) return first;
    final reissued = await identity.reissue();
    return api.submitScore(
      name,
      replay,
      credentials: reissued,
      country: country,
    );
  }

  Future<SubmitOutcome?> _uploadPending() async {
    final pending = storage.pendingReplay;
    if (pending == null) return null;
    try {
      final r = await _upload(pending.name, pending.replay);
      if (r.ok) {
        await storage.setPendingReplay(null);
        await _recordAccepted(pending.name, r);
        return SubmitAccepted(
          id: r.id ?? '',
          score: r.score,
          rank: r.rank,
          country: r.country,
          countryRank: r.countryRank,
          tokens: r.tokens,
          tokenBalance: r.tokenBalance,
        );
      }
      if (r.shouldRetryLater) return null;
      if (r.isOffensiveName) {
        // Kept, not dropped: see [submit].
        return const SubmitRejected(
          offensiveNameError,
          canRetryUnderNewName: true,
        );
      }
      // Also kept, and for the same reason: no verdict was reached on the run.
      if (r.isUnsupportedVersion) {
        return const SubmitRejected(unsupportedVersionError);
      }
      // Cleared only on the server's own verdict; everything else leaves the
      // stored replay alone so it can be retried (SPEC §5.1).
      await storage.setPendingReplay(null);
      return SubmitRejected(r.error ?? 'invalid_replay');
    } on ApiException {
      return null;
    }
  }

  /// Everything an accepted score changes locally: the player it was filed
  /// under and the country it counts for (SPEC §4.4 / §4.6), plus the legacy
  /// "ids I submitted" memory that still highlights anonymous rows.
  Future<void> _recordAccepted(String name, SubmitResult result) async {
    await identity.applySubmission(result);
    await storage.addOwnScore(
      id: result.id ?? '',
      name: name,
      score: result.score,
    );
  }

  Future<void> _defer(String name, Replay replay) async {
    final existing = storage.pendingReplay;
    if (existing != null &&
        existing.replay.claimedScore > replay.claimedScore) {
      return;
    }
    await storage.setPendingReplay(PendingReplay(name: name, replay: replay));
  }
}
