import 'package:arco/services/api_client.dart';
import 'package:arco/services/storage.dart';
import 'package:arco/ui/leaderboard_screen.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

List<LeaderboardEntry> _entries() => [
  LeaderboardEntry(
    rank: 1,
    name: 'Ada',
    score: 9000,
    seconds: 300,
    createdAt: DateTime.utc(2026, 9, 1),
  ),
  LeaderboardEntry(
    rank: 2,
    name: 'Tester',
    score: 500,
    seconds: 61,
    createdAt: DateTime.utc(2026, 9, 2),
  ),
];

List<LeaderboardEntry> _ownedEntries() => [
  LeaderboardEntry(
    rank: 1,
    name: 'Ada',
    score: 9000,
    seconds: 300,
    createdAt: DateTime.utc(2026, 9, 1),
    playerId: testPlayerId(8),
  ),
  LeaderboardEntry(
    rank: 2,
    name: 'Tester',
    score: 500,
    seconds: 61,
    createdAt: DateTime.utc(2026, 9, 2),
    playerId: testPlayerId(7),
  ),
];

Replay _replay({int score = 1234}) => Replay(
  config: const GameConfig(mode: GameMode.solo, seed: 99),
  inputs: <InputLog>[InputLog()..record(0, const PlayerInput(move: 4))],
  finalTick: 600,
  claimedScore: score,
);

/// Lets the post-frame load, the pending retry and the first fetch settle.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('lists the entries and highlights own scores', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv(
      prefs: const {
        'ownScoreKeys': <String>['Tester|500'],
        'ownScoreIds': <String>['id-1'],
      },
      api: FakeApiClient(entries: _entries()),
    );
    await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('All time'), findsOneWidget);
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('9000'), findsOneWidget);
    expect(find.text('Tester'), findsOneWidget);
    expect(find.text('(you)'), findsOneWidget);
    expect(find.text('300 s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the whole Polish period label on a 320-pt phone', (
    tester,
  ) async {
    // The three tabs split the width evenly, so "Wszech czasow" gets a third
    // of 320 pt. Material's default tab label fades the tail away when it
    // does not fit, which left the user reading "Wszech czaso".
    useNarrowPhone(tester);
    final env = await createTestEnv(
      prefs: const {'language': 'pl'},
      api: FakeApiClient(entries: _entries()),
    );
    await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    const label = 'Wszech czasów';
    expect(find.text(label), findsOneWidget);
    final slot = tester.getRect(
      find.ancestor(of: find.text(label), matching: find.byType(Tab)),
    );
    // The paragraph lays itself out at its natural width and is painted
    // scaled down inside the tab; without that it would be clamped to the
    // tab and the two widths would be equal, tail faded off.
    final natural = tester.getSize(find.text(label)).width;
    final painted = tester.getRect(find.text(label)).width;
    expect(
      natural,
      greaterThan(painted),
      reason: 'the label is not being scaled to fit',
    );
    expect(painted, lessThanOrEqualTo(slot.width + 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the offline state with a retry button', (tester) async {
    useIPhoneSe(tester);
    final api = FakeApiClient(offline: true);
    final env = await createTestEnv(api: api);
    await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Could not load the leaderboard'), findsOneWidget);
    expect(find.text('RETRY'), findsOneWidget);

    api
      ..offline = false
      ..entries = _entries();
    await tester.tap(find.text('RETRY'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Ada'), findsOneWidget);
    expect(api.leaderboardCalls, 2);
  });

  testWidgets('shows the empty state', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv();
    await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('No scores yet — be the first!'), findsOneWidget);
  });

  // SPEC 4.4: a run the server attributes to this player is highlighted by
  // player id, which survives a reinstall - the remembered submissions do not.
  testWidgets('highlights own rows by player id', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv(
      api: FakeApiClient(entries: _ownedEntries()),
      secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      // Deliberately empty: nothing local says which rows are ours.
      playerName: 'Somebody else',
    );
    await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
    await _settle(tester);

    expect(find.text('Tester'), findsOneWidget);
    expect(find.text('(you)'), findsOneWidget);
    final you = tester.getRect(find.text('(you)'));
    final mine = tester.getRect(find.text('Tester'));
    expect(
      you.top,
      closeTo(mine.top, 20),
      reason: 'the badge belongs to the row the server says is ours',
    );
  });

  testWidgets('a row owned by another player is never ours', (tester) async {
    useIPhoneSe(tester);
    final env = await createTestEnv(
      // The legacy memory would match this name and score...
      prefs: const {
        'ownScoreKeys': <String>['Ada|9000'],
      },
      api: FakeApiClient(entries: _ownedEntries()),
      secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      playerName: 'Nobody',
    );
    await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
    await _settle(tester);

    // ...but the server says row 1 belongs to player 8, so only row 2 is ours.
    expect(find.text('(you)'), findsOneWidget);
    final you = tester.getRect(find.text('(you)'));
    expect(you.top, closeTo(tester.getRect(find.text('Tester')).top, 20));
  });

  testWidgets('older anonymous rows still fall back to the local memory', (
    tester,
  ) async {
    useIPhoneSe(tester);
    final env = await createTestEnv(
      prefs: const {
        'ownScoreKeys': <String>['Tester|500'],
      },
      // No playerId on either row: every row stored before player identity
      // existed looks like this.
      api: FakeApiClient(entries: _entries()),
      playerName: 'Nobody',
    );
    await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
    await _settle(tester);

    expect(find.text('(you)'), findsOneWidget);
  });

  group('the national board (SPEC 4.6)', () {
    testWidgets('is a fourth tab labelled with the player own country', (
      tester,
    ) async {
      useIPhoneSe(tester);
      final api = FakeApiClient(entries: _entries());
      api.countryEntries['PL'] = [
        LeaderboardEntry(
          rank: 1,
          name: 'Marek',
          score: 700,
          seconds: 90,
          createdAt: DateTime.utc(2026, 9, 3),
          country: 'PL',
        ),
      ];
      final env = await createTestEnv(api: api, deviceCountry: 'PL');
      await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
      await _settle(tester);

      expect(find.text('All time'), findsOneWidget);
      expect(find.text('\u{1F1F5}\u{1F1F1} PL'), findsOneWidget);
      expect(api.leaderboardCountries, <String?>[null]);

      await tester.tap(find.text('\u{1F1F5}\u{1F1F1} PL'));
      await tester.pumpAndSettle();

      expect(api.leaderboardCountries, <String?>[null, 'PL']);
      expect(find.text('Marek'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is absent when the device names no country', (tester) async {
      useIPhoneSe(tester);
      final env = await createTestEnv(api: FakeApiClient(entries: _entries()));
      await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
      await _settle(tester);

      expect(find.byType(Tab), findsNWidgets(3));
      expect(env.api.leaderboardCountries, <String?>[null]);
    });

    testWidgets('disappears when the server refuses the code', (tester) async {
      useIPhoneSe(tester);
      final api = _InvalidCountryApi(entries: _entries());
      final env = await createTestEnv(api: api, deviceCountry: 'ZZ');
      await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
      await _settle(tester);
      expect(find.byType(Tab), findsNWidgets(4));

      await tester.tap(find.text('\u{1F1FF}\u{1F1FF} ZZ'));
      await tester.pumpAndSettle();

      expect(find.byType(Tab), findsNWidgets(3));
      expect(find.text('Could not load the leaderboard'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('a nickname the filter refuses (SPEC 4.7)', () {
    Future<TestEnv> envWithRefusedName({String language = 'en'}) async {
      final env = await createTestEnv(
        prefs: {'language': language},
        api: FakeApiClient(entries: _entries()),
      );
      env.api.submitResults.add(
        const SubmitResult.rejected(error: offensiveNameError, statusCode: 400),
      );
      await env.storage.setPendingReplay(
        PendingReplay(name: 'Tester', replay: _replay()),
      );
      return env;
    }

    testWidgets('is explained in English and the name can be changed', (
      tester,
    ) async {
      useTallPhone(tester);
      final env = await envWithRefusedName();
      await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
      await _settle(tester);

      expect(
        find.textContaining('That nickname cannot go on the leaderboard'),
        findsOneWidget,
      );

      // Let the snackbar finish sliding in before its action is tapped.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('CHANGE NICKNAME'));
      await tester.pumpAndSettle();
      // The heading is set in the theme own case, so the dialog is identified
      // by its field and its button rather than by that string.
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Nickname'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Polite');
      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();

      // The same verified game goes up under the new name.
      expect(env.api.submitCalls, 2);
      expect(env.settings.playerName, 'Polite');
      expect(env.storage.pendingReplay, isNull);
      expect(env.storage.isOwnScore(name: 'Polite', score: 1234), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is explained in Polish too', (tester) async {
      useTallPhone(tester);
      final env = await envWithRefusedName(language: 'pl');
      await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
      await _settle(tester);

      expect(
        find.textContaining('Tego pseudonimu nie można umieścić'),
        findsOneWidget,
      );
      expect(find.text('ZMIEŃ PSEUDONIM'), findsOneWidget);
    });
  });
}

/// Answers `400 invalid_country` for a national board, the way SPEC 4.6 does
/// for a code that is not an ISO 3166-1 alpha-2.
class _InvalidCountryApi extends FakeApiClient {
  _InvalidCountryApi({super.entries});

  @override
  Future<List<LeaderboardEntry>> leaderboard(
    LeaderboardPeriod period, {
    int limit = 100,
    String? country,
  }) async {
    if (country != null) {
      leaderboardCountries.add(country);
      leaderboardCalls++;
      throw const ApiException(
        ApiErrorKind.badResponse,
        'invalid_country',
        statusCode: 400,
        errorCode: 'invalid_country',
      );
    }
    return super.leaderboard(period, limit: limit, country: country);
  }
}
