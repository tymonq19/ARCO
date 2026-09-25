import 'dart:async';

import 'package:arco/services/api_client.dart';
import 'package:arco/services/score_submitter.dart';
import 'package:arco/services/storage.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_env.dart';

Replay replay({int score = 1234}) => Replay(
  config: const GameConfig(mode: GameMode.solo, seed: 99),
  inputs: <InputLog>[InputLog()..record(0, const PlayerInput(move: 4))],
  finalTick: 600,
  claimedScore: score,
);

void main() {
  test(
    'accepted submissions are remembered for the leaderboard highlight',
    () async {
      final env = await createTestEnv();
      final submitter = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );
      final outcome = await submitter.submit('Tester', replay());
      expect(outcome, isA<SubmitAccepted>());
      expect((outcome as SubmitAccepted).rank, 7);
      expect(env.storage.pendingReplay, isNull);
      expect(env.storage.isOwnScore(name: 'Tester', score: 1234), isTrue);
      expect(env.storage.ownScoreIds, contains('id-1'));
    },
  );

  test('offline submissions are kept and retried later', () async {
    final env = await createTestEnv(api: FakeApiClient(offline: true));
    final submitter = ScoreSubmitter(
      api: env.api,
      storage: env.storage,
      identity: env.identity,
    );
    expect(await submitter.submit('Tester', replay()), isA<SubmitDeferred>());
    expect(env.storage.pendingReplay, isNotNull);
    expect(env.storage.pendingReplay!.replay.claimedScore, 1234);
    expect(submitter.hasPending, isTrue);

    // A weaker offline game must not replace a stronger pending one.
    await submitter.submit('Tester', replay(score: 10));
    expect(env.storage.pendingReplay!.replay.claimedScore, 1234);

    env.api.offline = false;
    final retried = await submitter.retryPending();
    expect(retried, isA<SubmitAccepted>());
    expect(env.storage.pendingReplay, isNull);
    expect(await submitter.retryPending(), isNull);
  });

  test(
    'a pending replay is uploaded once even if two submitters retry',
    () async {
      final api = GatedApiClient();
      final env = await createTestEnv(api: api);
      await env.storage.setPendingReplay(
        PendingReplay(name: 'Tester', replay: replay()),
      );

      // App start, the solo screen and the leaderboard each build their own
      // submitter over the same storage (SPEC 5.1) and may overlap on a slow link.
      final a = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );
      final b = ScoreSubmitter(
        api: env.api,
        storage: env.storage,
        identity: env.identity,
      );
      final first = a.retryPending();
      final second = b.retryPending();
      api.gate.complete();
      final outcomes = await Future.wait(<Future<SubmitOutcome?>>[
        first,
        second,
      ]);

      expect(api.started, 1, reason: 'the replay must be uploaded once');
      expect(outcomes[0], isA<SubmitAccepted>());
      expect(
        (outcomes[1] as SubmitAccepted).id,
        (outcomes[0] as SubmitAccepted).id,
      );
      expect(env.storage.ownScoreIds, <String>['id-1']);
      expect(env.storage.pendingReplay, isNull);
    },
  );

  test('a rejected replay is dropped', () async {
    final env = await createTestEnv(
      api: FakeApiClient(
        submitResult: const SubmitResult.rejected(
          error: 'replay_mismatch',
          statusCode: 400,
        ),
      ),
    );
    final submitter = ScoreSubmitter(
      api: env.api,
      storage: env.storage,
      identity: env.identity,
    );
    final outcome = await submitter.submit('Tester', replay());
    expect(outcome, isA<SubmitRejected>());
    expect((outcome as SubmitRejected).error, 'replay_mismatch');
    expect(env.storage.pendingReplay, isNull);
  });

  // SPEC §4 lets the server answer `POST /api/scores` with 201, a 400
  // carrying an error code, 413 or 429 — nothing else is its verdict on the
  // replay. A reply from something in between (a captive portal, an
  // authenticating proxy, a mistyped server URL in Settings) must not be read
  // as "rejected": SPEC §5.1 promises the score is "saved locally, will
  // retry". These go through the real [ApiClient] over a mocked transport so
  // the status-code mapping is covered together with the submitter.
  group('a reply that is not the server\'s verdict keeps the score', () {
    final notVerdicts = <String, http.Response>{
      'a captive portal answering 200 + HTML': http.Response(
        '<html>please sign in</html>',
        200,
      ),
      'a mistyped server URL (404)': http.Response('Not Found', 404),
      'an authenticating proxy (407)': http.Response(
        'Proxy Auth Required',
        407,
      ),
      'a 400 without the documented body': http.Response('Bad Request', 400),
    };

    for (final entry in notVerdicts.entries) {
      test('${entry.key} defers a fresh submission', () async {
        final env = await createTestEnv();
        final submitter = ScoreSubmitter(
          api: alwaysAnswering(entry.value),
          storage: env.storage,
          identity: env.identity,
        );
        expect(
          await submitter.submit('Tester', replay()),
          isA<SubmitDeferred>(),
        );
        expect(env.storage.pendingReplay, isNotNull);
        expect(env.storage.pendingReplay!.replay.claimedScore, 1234);
      });

      test('${entry.key} leaves a stored replay pending', () async {
        final env = await createTestEnv();
        await env.storage.setPendingReplay(
          PendingReplay(name: 'Tester', replay: replay()),
        );
        final submitter = ScoreSubmitter(
          api: alwaysAnswering(entry.value),
          storage: env.storage,
          identity: env.identity,
        );
        expect(await submitter.retryPending(), isNull);
        expect(env.storage.pendingReplay, isNotNull);
      });
    }

    test('but a 400 carrying an error code does drop it', () async {
      final env = await createTestEnv();
      await env.storage.setPendingReplay(
        PendingReplay(name: 'Tester', replay: replay()),
      );
      final submitter = ScoreSubmitter(
        api: alwaysAnswering(
          http.Response('{"ok":false,"error":"replay_mismatch"}', 400),
        ),
        storage: env.storage,
        identity: env.identity,
      );
      final outcome = await submitter.retryPending();
      expect((outcome as SubmitRejected).error, 'replay_mismatch');
      expect(env.storage.pendingReplay, isNull);
    });
  });

  test('rate limiting defers instead of dropping', () async {
    final env = await createTestEnv(
      api: FakeApiClient(
        submitResult: const SubmitResult.rejected(
          error: 'rate_limited',
          statusCode: 429,
        ),
      ),
    );
    final submitter = ScoreSubmitter(
      api: env.api,
      storage: env.storage,
      identity: env.identity,
    );
    expect(await submitter.submit('Tester', replay()), isA<SubmitDeferred>());
    expect(env.storage.pendingReplay, isNotNull);
    expect(await submitter.retryPending(), isNull);
    expect(env.storage.pendingReplay, isNotNull);
  });
}

/// [FakeApiClient] whose submit only answers once [gate] is completed, so a
/// second upload can be started while the first is still in flight.
class GatedApiClient extends FakeApiClient {
  final Completer<void> gate = Completer<void>();
  int started = 0;

  @override
  Future<SubmitResult> submitScore(
    String name,
    Replay replay, {
    PlayerCredentials? credentials,
    String? country,
  }) async {
    started++;
    final n = started;
    await gate.future;
    if (offline) throw const ApiException(ApiErrorKind.network, 'offline');
    return SubmitResult.accepted(
      id: 'id-$n',
      score: replay.claimedScore,
      rank: n,
    );
  }
}

/// A real [ApiClient] whose transport answers every request with [response].
ApiClient alwaysAnswering(http.Response response) => ApiClient(
  baseUrl: () => 'http://fake.local',
  client: MockClient((_) async => response),
);
