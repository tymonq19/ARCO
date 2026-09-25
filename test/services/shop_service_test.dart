import 'package:arco/app/cosmetics.dart';
import 'package:arco/app/game_theme.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/player_identity.dart';
import 'package:arco/services/shop_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// The cosmetic shop, client side (SPEC 4.8).
///
/// Everything here is checked against a fake server rather than against a table
/// in the app: the point of the feature is that the **server** decides prices,
/// balances and ownership, so every test states what the server answered and
/// then what the client did with it.
void main() {
  /// A second [ShopService] over the same storage: a restart.
  ShopService relaunch(TestEnv env, {FakeApiClient? api}) => ShopService(
    api: api ?? env.api,
    identity: PlayerIdentity(
      api: api ?? env.api,
      storage: env.storage,
      secrets: env.secrets,
      deviceCountry: () => null,
    ),
    storage: env.storage,
    settings: env.settings,
  );

  group('reading the server', () {
    test('a cold start knows nothing and asks nothing', () async {
      final env = await createTestEnv();

      expect(env.shop.status, ShopStatus.idle);
      expect(env.shop.balanceKnown, isFalse);
      expect(env.shop.snapshot.hasCatalogue, isFalse);
      expect(env.shop.equipped, Equipped.defaults);
      expect(env.api.shopCatalogueCalls, 0);
      expect(env.api.shopInventoryCalls, 0);
      expect(env.api.createPlayerCalls, 0);
    });

    test('the catalogue on screen is the one the server sent', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      // Deliberately not the seeded catalogue: a client that shipped its own
      // table would pass every other test in this file and fail this one.
      env.api.catalogueItems = [
        FakeApiClient.shopItem('ball.orb', 'ball', 0),
        FakeApiClient.shopItem('ball.comet', 'ball', 7),
        FakeApiClient.shopItem('paddle.arc', 'paddle', 0),
      ];
      env.api.shopBalance = 42;

      await env.shop.refresh();

      expect(env.shop.status, ShopStatus.ready);
      expect(
        [for (final i in env.shop.snapshot.items) i.id],
        ['ball.orb', 'ball.comet', 'paddle.arc'],
      );
      expect(env.shop.snapshot.item('ball.comet')!.priceTokens, 7);
      expect(env.shop.balance, 42);
      expect(env.shop.snapshot.slots, ['ball', 'paddle']);
      // The free items are owned without a row saying so, as on the server.
      expect(env.shop.snapshot.owns('ball.orb'), isTrue);
      expect(env.shop.snapshot.owns('ball.comet'), isFalse);
    });

    test('no player is created to look at a balance, but opening the shop '
        'creates one', () async {
      final env = await createTestEnv();

      await env.shop.refresh();
      expect(
        env.api.createPlayerCalls,
        0,
        reason: 'a balance is not worth issuing an identity for',
      );
      expect(
        env.shop.status,
        ShopStatus.idle,
        reason: 'nothing was asked, so there is nothing to report',
      );
      expect(env.api.shopCatalogueCalls, 0);

      // Opening the shop is the player asking for something that needs a wallet
      // (SPEC 4.4): anonymous players have a server-side identity, so the shop
      // works for them.
      await env.shop.refresh(issue: true, force: true);
      expect(env.api.createPlayerCalls, 1);
      expect(env.shop.status, ShopStatus.ready);
      expect(env.shop.snapshot.hasCatalogue, isTrue);
    });

    test('every shop call is authenticated', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(3)),
      );
      await env.shop.refresh();
      expect(env.api.shopCredentials, isNotEmpty);
      for (final credentials in env.api.shopCredentials) {
        expect(credentials?.id, testPlayerId(3));
      }
    });

    test('a fresh answer is reused, and force re-reads it', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.shop.refresh();
      await env.shop.refresh();
      expect(env.api.shopCatalogueCalls, 1);
      await env.shop.refresh(force: true);
      expect(env.api.shopCatalogueCalls, 2);
    });

    test('a refused credential puts the device back to anonymous', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.shopFailure = const ApiException(
        ApiErrorKind.unauthorized,
        'invalid_credentials',
        statusCode: 401,
        errorCode: 'invalid_credentials',
      );

      await env.shop.refresh();

      expect(env.shop.status, ShopStatus.unavailable);
      expect(env.identity.playerId, isNull);
    });
  });

  group('buying', () {
    test('takes the price the server charges and grants the item', () async {
      final env = await createTestEnv(
        balance: 200,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.shop.refresh();

      final result = await env.shop.buy('ball.comet');

      expect(result.outcome, ShopOutcome.bought);
      expect(result.purchase!.charged, 80);
      expect(env.shop.balance, 120, reason: "the server's number, not a sum");
      expect(env.api.shopBalance, 120);
      expect(env.shop.snapshot.owns('ball.comet'), isTrue);
      // Buying wears it: paying for something you cannot see is a receipt.
      expect(env.shop.equipped.ball, BallSkin.comet);
      expect(env.api.shopEquips, [
        {'ball': 'ball.comet'},
      ]);
    });

    test('a wallet that cannot cover it is refused, with the numbers to say '
        'why', () async {
      final env = await createTestEnv(
        balance: 10,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.shop.refresh();

      final result = await env.shop.buy('ball.comet');

      expect(result.outcome, ShopOutcome.insufficient);
      expect(result.missing, 70, reason: '80 - 10, both the server\'s figures');
      expect(env.shop.balance, 10);
      expect(env.shop.snapshot.owns('ball.comet'), isFalse);
      expect(env.shop.equipped.ball, BallSkin.orb);
      expect(env.api.shopEquipCalls, 0);
    });

    test('an item the server does not have is refused, not invented', () async {
      final env = await createTestEnv(
        balance: 500,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.shop.refresh();

      final result = await env.shop.buy('ball.supernova');

      expect(result.outcome, ShopOutcome.unknownItem);
      expect(env.shop.balance, 500);
      expect(env.api.shopBalance, 500);
    });

    test('a purchase that fails before it lands takes nothing, and the retry '
        'costs the price once', () async {
      final env = await createTestEnv(
        balance: 200,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.shop.refresh();
      env.api.buyFailureOnce = const ApiException(
        ApiErrorKind.timeout,
        'request timed out',
      );

      final failed = await env.shop.buy('ball.comet');

      expect(failed.ok, isFalse);
      expect(env.api.shopBalance, 200, reason: 'nothing may be taken');
      expect(env.shop.balance, 200);
      expect(env.shop.snapshot.owns('ball.comet'), isFalse);

      // Retrying is safe, which is the whole point of the server's idempotency.
      final second = await env.shop.buy('ball.comet');
      expect(second.outcome, ShopOutcome.bought);
      expect(env.shop.balance, 120);
      expect(env.api.shopBuys, ['ball.comet', 'ball.comet']);
    });

    test('a purchase whose answer is lost after it landed is reconciled, not '
        'charged twice', () async {
      final env = await createTestEnv(
        balance: 200,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.shop.refresh();
      // The server debited the wallet and wrote the item; the answer never came
      // back. The client must not guess in either direction — it asks.
      env.api.buyLandsBeforeFailure = true;
      env.api.buyFailureOnce = const ApiException(
        ApiErrorKind.network,
        'connection closed',
      );

      final result = await env.shop.buy('ball.comet');

      expect(result.outcome, ShopOutcome.bought);
      expect(env.shop.snapshot.owns('ball.comet'), isTrue);
      expect(env.shop.balance, 120, reason: 'charged exactly once');
      expect(env.api.shopBalance, 120);
      expect(env.shop.equipped.ball, BallSkin.comet);
    });

    test(
      'with no connection at all nothing is bought and nothing is taken',
      () async {
        final env = await createTestEnv(
          balance: 200,
          secrets: FakeSecretStore.withCredentials(testCredentials(1)),
        );
        await env.shop.refresh();
        env.api.offline = true;

        final result = await env.shop.buy('ball.comet');

        expect(result.outcome, ShopOutcome.offline);
        expect(env.api.shopBalance, 200);
        expect(env.shop.snapshot.owns('ball.comet'), isFalse);
      },
    );
  });

  group('equipping', () {
    test('an item the player does not own cannot be equipped', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.shop.refresh();

      expect(await env.shop.equip('ball.ember'), isFalse);
      expect(env.shop.equipped.ball, BallSkin.orb);
      expect(
        env.api.shopEquipCalls,
        0,
        reason: 'the request is not even made: equipping is not an entitlement',
      );
    });

    test(
      'a free item can always be worn, even before anything is known',
      () async {
        final env = await createTestEnv();
        expect(await env.shop.equip('paddle.arc'), isFalse);
        expect(env.shop.equipped.paddle, PaddleSkin.arc);
        expect(env.shop.snapshot.owns('theme.classic'), isTrue);
      },
    );

    test('what is worn survives a restart with no network', () async {
      final env = await createTestEnv(
        balance: 300,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.shop.refresh();
      await env.shop.buy('ball.ember');
      await env.shop.buy('paddle.halo');
      expect(
        env.shop.equipped,
        const Equipped(ball: BallSkin.ember, paddle: PaddleSkin.halo),
      );

      // A new launch over the same store, with the network gone.
      final offline = FakeApiClient(offline: true);
      final restarted = relaunch(env, api: offline);

      expect(
        restarted.equipped,
        const Equipped(ball: BallSkin.ember, paddle: PaddleSkin.halo),
        reason: 'the arena has to be dressed before any request finishes',
      );
      expect(restarted.snapshot.owns('ball.ember'), isTrue);
      await restarted.refresh();
      expect(restarted.status, ShopStatus.offline);
      expect(
        restarted.equipped.ball,
        BallSkin.ember,
        reason: 'a failed refresh must not undress anybody',
      );
      restarted.dispose();
    });

    test('the look follows the account to another device', () async {
      // A device that has synced before (so its own choice is not the newer
      // information) and a server that says this player wears Glass.
      final env = await createTestEnv(theme: ThemeId.neon);
      env.secrets.values.addAll({
        PlayerIdentity.idKey: testCredentials(1).id,
        PlayerIdentity.secretKey: testCredentials(1).secret,
      });
      env.api.shopOwned.add('theme.glass');
      env.api.shopEquipped['theme'] = 'theme.glass';

      await env.shop.refresh();

      expect(env.settings.themeId, ThemeId.glass);
      expect(env.shop.snapshot.equipped['theme'], 'theme.glass');
    });

    test('a look chosen before the server ever heard of it is pushed, not '
        'overwritten', () async {
      // No shop cache at all: this device's own choice is the newest information
      // there is, so installing the shop must not undress the player.
      final env = await createTestEnv(
        prefs: const {'theme': 'classic'},
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      expect(env.settings.themeId, ThemeId.classic);

      await env.shop.refresh();

      expect(env.settings.themeId, ThemeId.classic);
      expect(env.api.shopEquips, [
        {'theme': 'theme.classic'},
      ]);
      expect(env.api.shopEquipped['theme'], 'theme.classic');
    });

    test(
      'a paid look this player does not own is taken back on the first sync',
      () async {
        // The only way to be wearing one is a build that predates the shop, or a
        // choice made offline. The server is the answer, and it says no.
        final env = await createTestEnv(
          prefs: const {'theme': 'glass'},
          secrets: FakeSecretStore.withCredentials(testCredentials(1)),
        );
        expect(env.settings.themeId, ThemeId.glass);

        await env.shop.refresh();

        expect(env.settings.themeId, ThemeId.neon);
        expect(env.api.shopEquipCalls, 0);
      },
    );

    test(
      'a choice made offline is kept and pushed on the next refresh',
      () async {
        final env = await createTestEnv(
          theme: ThemeId.neon,
          owned: const {'theme.modernist'},
          secrets: FakeSecretStore.withCredentials(testCredentials(1)),
        );
        env.api.offline = true;

        expect(await env.shop.equip('theme.modernist'), isFalse);
        expect(
          env.settings.themeId,
          ThemeId.modernist,
          reason: 'switching between two owned looks has to work on a plane',
        );
        expect(env.shop.pendingEquip, {'theme': 'theme.modernist'});
        expect(env.storage.shopPendingEquip, {'theme': 'theme.modernist'});

        // And it survives the flight: a new launch still holds it, and the next
        // successful refresh pushes it instead of adopting the server's older one.
        final restarted = relaunch(env);
        expect(restarted.pendingEquip, {'theme': 'theme.modernist'});
        env.api.offline = false;
        await restarted.refresh();

        expect(env.api.shopEquips.first, {'theme': 'theme.modernist'});
        expect(env.api.shopEquipped['theme'], 'theme.modernist');
        expect(restarted.pendingEquip, isEmpty);
        expect(env.storage.shopPendingEquip, isEmpty);
        expect(env.settings.themeId, ThemeId.modernist);
        restarted.dispose();
      },
    );

    test(
      'a choice the server refuses is dropped rather than retried forever',
      () async {
        final env = await createTestEnv(
          owned: const {'ball.comet'},
          secrets: FakeSecretStore.withCredentials(testCredentials(1)),
        );
        // The cache says the player owns it; the server disagrees, which is what a
        // stale cache looks like. One refused request, no free item.
        env.api.shopOwned.clear();

        expect(await env.shop.equip('ball.comet'), isFalse);
        expect(env.api.shopEquipCalls, 1);
        expect(env.shop.pendingEquip, isEmpty);

        await env.shop.refresh(force: true);
        expect(
          env.shop.equipped.ball,
          BallSkin.orb,
          reason: "the server's answer wins",
        );
      },
    );
  });

  group('earning', () {
    test('a run pays the wallet the server reported', () async {
      final env = await createTestEnv(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.shopBalance = 124;
      env.api.shopEarnedToday = 24;

      await env.shop.noteRun(tokens: 24, balance: 124);

      expect(env.shop.balance, 124);
      expect(env.shop.balanceKnown, isTrue);
      expect(env.shop.snapshot.earnedToday, 24);
      expect(env.shop.snapshot.dailyCap, 200);
      expect(env.shop.snapshot.dailyCapReached, isFalse);
    });

    test(
      'the daily cap is two of the server\'s numbers, not a rule here',
      () async {
        final env = await createTestEnv(
          secrets: FakeSecretStore.withCredentials(testCredentials(1)),
        );
        env.api.shopEarnedToday = 200;
        env.api.shopDailyCap = 200;

        await env.shop.noteRun(tokens: 0, balance: 640);

        expect(env.shop.snapshot.dailyCapReached, isTrue);
        expect(env.shop.snapshot.earnedToday, 200);
        expect(env.shop.snapshot.dailyCap, 200);
      },
    );

    test('an anonymous run reports no wallet, so none is invented', () async {
      final env = await createTestEnv();
      await env.shop.noteRun(tokens: null, balance: null);
      expect(env.shop.balanceKnown, isFalse);
      expect(env.api.shopInventoryCalls, 0);
    });
  });

  group('the snapshot', () {
    test('round-trips through storage', () async {
      final env = await createTestEnv(
        balance: 60,
        owned: const {'ball.comet'},
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await env.shop.refresh();
      final saved = ShopSnapshot.fromJson(env.storage.shopCache)!;

      expect(saved.balance, 60);
      expect(saved.owns('ball.comet'), isTrue);
      expect(saved.items.length, env.shop.snapshot.items.length);
      expect(saved.known, isTrue);
      expect(saved.skins, env.shop.equipped);
    });

    test('a cache from another build is ignored, not crashed on', () async {
      final env = await createTestEnv();
      await env.storage.setShopCache({'v': 99, 'balance': 9000});
      final restarted = relaunch(env);
      expect(restarted.balanceKnown, isFalse);
      expect(restarted.balance, 0);
      restarted.dispose();
    });

    test('slots are read off the item id', () {
      expect(CosmeticSlot.of('theme.glass'), 'theme');
      expect(CosmeticSlot.of('ball.comet'), 'ball');
      expect(CosmeticSlot.of('paddle.halo'), 'paddle');
      expect(CosmeticSlot.of('trail.spark'), isNull);
      expect(CosmeticSlot.of('nonsense'), isNull);
      expect(CosmeticSlot.of('.glass'), isNull);
    });

    test('a look is identified by the same string in all three places', () {
      for (final theme in GameThemes.all) {
        final id = ShopSnapshot.idOfTheme(theme);
        expect(id, theme.nameKey);
        expect(GameThemes.byItemId(id), same(theme));
        expect(CosmeticSlot.of(id), CosmeticSlot.theme);
      }
      expect(GameThemes.byItemId('theme.aurora'), isNull);
      expect(GameThemes.byItemId(null), isNull);
    });
  });
}
