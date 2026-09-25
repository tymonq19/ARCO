import 'dart:async';

import 'package:arco/services/api_client.dart';
import 'package:arco/services/player_identity.dart';
import 'package:arco/services/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_env.dart';

/// SPEC §4.4: the identity is invisible plumbing. It is issued lazily, stored
/// where a secret belongs, and every failure on the way degrades to an anonymous
/// submission instead of something the player has to read.
void main() {
  test('reading the store issues nothing', () async {
    final env = await createTestEnv();
    expect(await env.identity.load(), isNull);
    expect(env.identity.playerId, isNull);
    expect(env.identity.isIdentified, isFalse);
    expect(
      env.api.createPlayerCalls,
      0,
      reason: 'a player must never be created just because the app looked',
    );
  });

  test('an identity is issued once and then reused', () async {
    final env = await createTestEnv();
    final first = await env.identity.ensureIssued();
    final second = await env.identity.ensureIssued();

    expect(first, isNotNull);
    expect(first!.id, testPlayerId(1));
    expect(second!.id, first.id);
    expect(env.api.createPlayerCalls, 1);
    expect(env.identity.playerId, testPlayerId(1));
  });

  test('concurrent first submissions share the one issue', () async {
    final env = await createTestEnv();
    final results = await Future.wait([
      env.identity.ensureIssued(),
      env.identity.ensureIssued(),
      env.identity.ensureIssued(),
    ]);
    expect(env.api.createPlayerCalls, 1);
    expect(results.map((c) => c!.id).toSet(), {testPlayerId(1)});
  });

  test(
    'the secret goes to the keychain and never to shared_preferences',
    () async {
      final env = await createTestEnv();
      final issued = (await env.identity.ensureIssued())!;

      expect(env.secrets.values[PlayerIdentity.idKey], issued.id);
      expect(env.secrets.values[PlayerIdentity.secretKey], issued.secret);

      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect(
          '${prefs.get(key)}',
          isNot(contains(issued.secret)),
          reason: 'the secret leaked into shared_preferences under "$key"',
        );
      }
      // Nor is it in what the credential prints, which is where a stray log line
      // would find it.
      expect(issued.toString(), isNot(contains(issued.secret)));
      expect(issued.toString(), contains(issued.id));
    },
  );

  test('a stored credential is picked up on the next launch', () async {
    final env = await createTestEnv(
      secrets: FakeSecretStore.withCredentials(testCredentials(7)),
    );
    final loaded = await env.identity.ensureIssued();
    expect(loaded!.id, testPlayerId(7));
    expect(env.api.createPlayerCalls, 0);
  });

  test('half a stored credential is dropped rather than used', () async {
    final env = await createTestEnv(
      secrets: FakeSecretStore(
        initial: {PlayerIdentity.idKey: testPlayerId(3)},
      ),
    );
    final issued = await env.identity.ensureIssued();
    expect(issued!.id, testPlayerId(1), reason: 'a fresh identity is issued');
    expect(env.secrets.deletes, greaterThan(0));
  });

  test('a truncated secret is not offered to the server', () async {
    final env = await createTestEnv(
      secrets: FakeSecretStore(
        initial: {
          PlayerIdentity.idKey: testPlayerId(3),
          PlayerIdentity.secretKey: 'short',
        },
      ),
    );
    expect((await env.identity.ensureIssued())!.id, testPlayerId(1));
  });

  test('no keychain means no identity and no error', () async {
    final env = await createTestEnv(secrets: FakeSecretStore(failing: true));
    expect(await env.identity.ensureIssued(), isNull);
    expect(env.identity.canStoreSecret, isFalse);
    expect(
      env.api.createPlayerCalls,
      0,
      reason: 'a credential that cannot be kept must not be issued',
    );
  });

  test('a rate-limited issue waits for as long as the server asked', () async {
    var clock = DateTime.utc(2026, 9, 23, 12);
    final env = await createTestEnv(now: () => clock);
    env.api.createPlayerFailure = const ApiException(
      ApiErrorKind.rateLimited,
      'rate_limited',
      statusCode: 429,
      errorCode: 'rate_limited',
      retryAfter: Duration(seconds: 60),
    );

    expect(await env.identity.ensureIssued(), isNull);
    expect(env.api.createPlayerCalls, 1);

    // Still inside the window: no second attempt, no loop.
    clock = clock.add(const Duration(seconds: 59));
    expect(await env.identity.ensureIssued(), isNull);
    expect(env.api.createPlayerCalls, 1);

    clock = clock.add(const Duration(seconds: 2));
    env.api.createPlayerFailure = null;
    expect((await env.identity.ensureIssued())!.id, testPlayerId(1));
    expect(env.api.createPlayerCalls, 2);
  });

  test('an issue that fails for another reason backs off too', () async {
    var clock = DateTime.utc(2026, 9, 23, 12);
    final env = await createTestEnv(now: () => clock);
    env.api.offline = true;

    expect(await env.identity.ensureIssued(), isNull);
    expect(await env.identity.ensureIssued(), isNull);
    expect(env.api.createPlayerCalls, 1);

    clock = clock.add(PlayerIdentity.issueBackoff + const Duration(seconds: 1));
    env.api.offline = false;
    expect(await env.identity.ensureIssued(), isNotNull);
    expect(env.api.createPlayerCalls, 2);
  });

  test(
    'reissuing discards the stale credential and stores the new one',
    () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      env.api.issued = testCredentials(9);
      expect((await env.identity.load())!.id, testPlayerId(7));

      final fresh = await env.identity.reissue();
      expect(fresh!.id, testPlayerId(9));
      expect(env.identity.playerId, testPlayerId(9));
      expect(env.secrets.values[PlayerIdentity.secretKey], fresh.secret);
      expect(env.secrets.values[PlayerIdentity.idKey], testPlayerId(9));
    },
  );

  // SPEC 4.5: what sign-in will hand back - a brand new credential, possibly
  // for a different (surviving) player.
  test(
    'an adopted credential replaces both halves and the cached standing',
    () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      env.api.profile = PlayerProfile(id: testPlayerId(7), games: 1, rank: 5);
      await env.identity.refreshProfile();
      expect(env.identity.profile, isNotNull);

      await env.identity.adopt(testCredentials(9));

      expect(env.identity.playerId, testPlayerId(9));
      expect(env.secrets.values[PlayerIdentity.idKey], testPlayerId(9));
      expect(env.secrets.values[PlayerIdentity.secretKey], testPlayerSecret(9));
      expect(
        env.identity.profile,
        isNull,
        reason: 'the standing belonged to the old identity',
      );
    },
  );

  group('country (SPEC 4.6)', () {
    test('comes from the device locale', () async {
      final env = await createTestEnv(deviceCountry: 'PL');
      expect(env.identity.countryForSubmission(), 'PL');
      expect(env.identity.country, 'PL');
    });

    test('an unusable locale sends none and shows no national board', () async {
      final env = await createTestEnv();
      expect(env.identity.countryForSubmission(), isNull);
      expect(env.identity.country, isNull);
    });

    test('a code the server accepted is remembered across launches', () async {
      final env = await createTestEnv(deviceCountry: 'DE');
      await env.identity.rememberCountry('PL');
      expect(env.storage.playerCountry, 'PL');
      // The remembered code wins over the device, which is the board the
      // player's own runs are actually on.
      expect(env.identity.country, 'PL');
      // ...but a new run is still filed where the phone says it was played.
      expect(env.identity.countryForSubmission(), 'DE');
    });

    test('a refused code hides the national board', () async {
      final env = await createTestEnv(deviceCountry: 'ZZ');
      expect(env.identity.country, 'ZZ');
      env.identity.countryRefused('ZZ');
      expect(env.identity.country, isNull);
      expect(env.identity.countryForSubmission(), 'ZZ');
    });
  });

  group('profile (GET /api/players/me)', () {
    test('is not fetched for an anonymous player', () async {
      final env = await createTestEnv();
      expect(await env.identity.refreshProfile(), isNull);
      expect(env.api.profileCalls, 0);
      expect(env.api.createPlayerCalls, 0);
    });

    test('is cached and refreshed only when forced', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      env.api.profile = PlayerProfile(
        id: testPlayerId(7),
        name: 'Tester',
        bestScore: 900,
        rank: 12,
        games: 3,
        country: 'PL',
        countryBestScore: 900,
        countryRank: 2,
      );

      final first = await env.identity.refreshProfile();
      expect(first!.rank, 12);
      expect(await env.identity.refreshProfile(), isNotNull);
      expect(env.api.profileCalls, 1, reason: 'the profile is not polled');

      await env.identity.refreshProfile(force: true);
      expect(env.api.profileCalls, 2);
      // The national standing is remembered, so the leaderboard can offer the
      // right board before anything else is asked of the server.
      expect(env.storage.playerCountry, 'PL');
    });

    test('a refused credential is forgotten', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      env.api.profile = null; // answers 401 invalid_credentials
      expect(await env.identity.refreshProfile(), isNull);
      expect(env.identity.playerId, isNull);
      expect(env.secrets.values, isEmpty);
    });

    test('a merged player id replaces the stored one', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      // SPEC 4.4: the id we sent was absorbed by a merge and resolves to the
      // survivor, which is what a client stores from then on.
      env.api.profile = PlayerProfile(id: testPlayerId(8), games: 1, rank: 4);
      await env.identity.refreshProfile();
      expect(env.identity.playerId, testPlayerId(8));
      expect(env.secrets.values[PlayerIdentity.idKey], testPlayerId(8));
      expect(
        env.secrets.values[PlayerIdentity.secretKey],
        testPlayerSecret(7),
        reason: 'the secret still belongs to this device',
      );
    });
  });

  group('leaderboard ownership', () {
    LeaderboardEntry entry({String? playerId, String name = 'Tester'}) =>
        LeaderboardEntry(
          rank: 2,
          name: name,
          score: 500,
          seconds: 61,
          createdAt: DateTime.utc(2026, 9, 2),
          playerId: playerId,
        );

    test('a row the server attributes to this player is ours', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      await env.identity.load();
      expect(env.identity.owns(entry(playerId: testPlayerId(7))), isTrue);
      expect(env.identity.owns(entry(playerId: testPlayerId(8))), isFalse);
    });

    test('an anonymous row falls back to what this device submitted', () async {
      final env = await createTestEnv(
        prefs: const {
          'ownScoreKeys': <String>['Tester|500'],
        },
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      await env.identity.load();
      expect(env.identity.owns(entry()), isTrue);
      expect(env.identity.owns(entry(name: 'Ada')), isFalse);
    });

    test(
      'another player\'s row is not ours even under the same name and score',
      () async {
        final env = await createTestEnv(
          prefs: const {
            'ownScoreKeys': <String>['Tester|500'],
          },
          secrets: FakeSecretStore.withCredentials(testCredentials(7)),
        );
        await env.identity.load();
        expect(env.identity.owns(entry(playerId: testPlayerId(8))), isFalse);
      },
    );
  });

  group('a deliberate change outruns a keychain read already in flight', () {
    // A platform keychain is a method channel: calls are answered in the order
    // they were made, and an answer arrives long after the call. So a read
    // issued before a sign-out can come back *after* it, carrying exactly the
    // credential the player just asked to be rid of. Putting that back would
    // leave the phone signed out on screen and signed in on the wire.
    test(
      'signing out while the first read is in flight really forgets',
      () async {
        final store = _ChannelSecretStore(testCredentials(5));
        final env = await createTestEnv();
        final identity = PlayerIdentity(
          api: env.api,
          storage: env.storage,
          secrets: store,
        );

        // The first read is out on the channel...
        final loading = identity.load();
        await pumpEventQueue();
        // ...and the player signs out before it comes back.
        final forgetting = identity.forget();
        await pumpEventQueue();
        await store.drain();
        await loading;
        await forgetting;

        expect(
          identity.playerId,
          isNull,
          reason: 'the forgotten credential came back with the stale read',
        );
        expect(identity.isIdentified, isFalse);
        expect(store.values, isEmpty, reason: 'the keychain still holds it');
        expect(
          await identity.load(),
          isNull,
          reason: 'the next screen was handed the forgotten credential',
        );
      },
    );

    test('adopting a linked credential survives an in-flight read', () async {
      // The other half of the same race: `POST /api/account/link` answers while
      // the first keychain read is still out, and its answer must win.
      final store = _ChannelSecretStore(testCredentials(5));
      final env = await createTestEnv();
      final identity = PlayerIdentity(
        api: env.api,
        storage: env.storage,
        secrets: store,
      );
      final linked = testCredentials(9);

      final loading = identity.load();
      await pumpEventQueue();
      final adopting = identity.adopt(linked);
      await pumpEventQueue();
      await store.drain();
      await loading;
      await adopting;

      expect(identity.playerId, linked.id);
      expect(store.values[PlayerIdentity.idKey], linked.id);
      expect(store.values[PlayerIdentity.secretKey], linked.secret);
      expect((await identity.load())!.secret, linked.secret);
    });

    test('a half credential is not wiped on top of a fresh one', () async {
      // The read finds only an id (a torn write from an older build), the link
      // lands while it is in flight, and the cleanup that half a credential
      // deserves must not take the new one with it.
      final store = _ChannelSecretStore.raw({
        PlayerIdentity.idKey: testPlayerId(5),
      });
      final env = await createTestEnv();
      final identity = PlayerIdentity(
        api: env.api,
        storage: env.storage,
        secrets: store,
      );
      final linked = testCredentials(9);

      final loading = identity.load();
      await pumpEventQueue();
      final adopting = identity.adopt(linked);
      await pumpEventQueue();
      await store.drain();
      await loading;
      await adopting;

      expect(identity.playerId, linked.id);
      expect(store.values[PlayerIdentity.secretKey], linked.secret);
    });

    test('an issue that lands after a sign-out is dropped', () async {
      // `POST /api/players` is in flight when the player signs out: the answer
      // is a player nobody asked to be, and storing it would sign them back in.
      final api = FakeApiClient()..createPlayerDelay = Completer<void>();
      final env = await createTestEnv(api: api);
      final issuing = env.identity.ensureIssued();
      await pumpEventQueue();
      await env.identity.forget();
      api.createPlayerDelay!.complete();
      expect(await issuing, isNull);
      expect(env.identity.playerId, isNull);
      expect(env.secrets.values, isEmpty);
    });

    test('a profile that lands after a sign-out is dropped', () async {
      final api = FakeApiClient()..playerMeDelay = Completer<void>();
      final env = await createTestEnv(
        api: api,
        secrets: FakeSecretStore.withCredentials(testCredentials(5)),
      );
      await env.identity.load();
      final fetching = env.identity.refreshProfile();
      await pumpEventQueue();
      await env.identity.forget();
      api.playerMeDelay!.complete();
      expect(await fetching, isNull);
      expect(
        env.identity.profile,
        isNull,
        reason: 'the home screen would show a rank for a forgotten player',
      );
    });
  });
}

/// A [SecretStore] that answers in the order it was called, and only when the
/// test says so — which is what a platform keychain behind a method channel
/// does, and what an in-memory map cannot reproduce.
class _ChannelSecretStore implements SecretStore {
  _ChannelSecretStore(PlayerCredentials credentials)
    : values = {
        PlayerIdentity.idKey: credentials.id,
        PlayerIdentity.secretKey: credentials.secret,
      };

  _ChannelSecretStore.raw(Map<String, String> initial) : values = {...initial};

  final Map<String, String> values;
  final List<void Function()> _queue = <void Function()>[];

  Future<T> _call<T>(T Function() op) {
    final completer = Completer<T>();
    _queue.add(() => completer.complete(op()));
    return completer.future;
  }

  /// Answers every queued call, and everything queued behind it, in order.
  Future<void> drain() async {
    var guard = 0;
    while (_queue.isNotEmpty && guard++ < 100) {
      _queue.removeAt(0)();
      await pumpEventQueue();
    }
  }

  @override
  Future<String?> read(String key) => _call(() => values[key]);

  @override
  Future<void> write(String key, String value) =>
      _call(() => values[key] = value);

  @override
  Future<void> delete(String key) => _call(() => values.remove(key));
}
