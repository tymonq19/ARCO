import 'package:arco/app/game_theme.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:arco/ui/widgets/shop_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// The shop screen (SPEC §4.8), against a fake server.
///
/// Every price, every balance and every ownership state on this screen is the
/// server's; the tests are written so that a client which shipped its own table
/// of items would fail the first one and pass none of the rest by accident.
void main() {
  /// Opens the shop and lets its first two requests settle.
  ///
  /// Not `pumpAndSettle`: while the catalogue is in flight the screen shows a
  /// progress indicator, which never settles.
  Future<void> openShop(
    WidgetTester tester,
    TestEnv env, {
    Widget? home,
  }) async {
    await tester.pumpWidget(home ?? wrapApp(env, const ShopScreen()));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// A device that has played before: it holds a credential and the server knows
  /// the player.
  ///
  /// The profile matters: without one the fake answers `401` to
  /// `GET /api/players/me`, which a real server does only for a credential it
  /// never issued — and which makes the app correctly forget its identity, so
  /// nothing after it would be authenticated.
  Future<TestEnv> shopEnv({
    int balance = 0,
    Set<String> owned = const <String>{},
    Map<String, Object> prefs = const <String, Object>{},
  }) async {
    final env = await createTestEnv(
      balance: balance,
      owned: owned,
      prefs: prefs,
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    env.api.profile = PlayerProfile(id: testPlayerId(1), games: 2);
    return env;
  }

  /// A viewport that holds the whole shop at once: a card below the fold is not
  /// built, and these tests are about what the screen *says*, not about
  /// scrolling.
  void useLargeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 2800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Finder cardFor(String itemId) => find.byWidgetPredicate(
    (w) => w is ShopCard && w.itemId == itemId,
    description: 'card for $itemId',
  );

  ShopCard card(WidgetTester tester, String itemId) =>
      tester.widget<ShopCard>(cardFor(itemId));

  /// Scrolls until [finder] is in the tree: a card or a panel below the fold is
  /// not built at all, so it cannot be found, let alone tapped.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      // Back to the top first: the wanted card may be above the fold as well.
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pump();
      for (var i = 0; i < 12 && finder.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pump();
      }
    }
    expect(finder, findsWidgets, reason: 'never scrolled to $finder');
    await tester.ensureVisible(finder.first);
    await tester.pump();
  }

  Future<void> tapCard(WidgetTester tester, String itemId) async {
    await scrollTo(tester, cardFor(itemId));
    await tester.tap(cardFor(itemId));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  testWidgets('lists exactly what the server returned', (tester) async {
    useTallPhone(tester);
    final env = await shopEnv();
    // A catalogue no build of this app ships: two items, at prices nobody would
    // hardcode.
    env.api.catalogueItems = [
      FakeApiClient.shopItem('ball.orb', 'ball', 0),
      FakeApiClient.shopItem('ball.comet', 'ball', 7),
    ];
    env.api.shopBalance = 13;

    await openShop(tester, env);

    expect(find.text('Orb'), findsOneWidget);
    expect(find.text('Comet'), findsOneWidget);
    expect(card(tester, 'ball.comet').priceTokens, 7);
    expect(find.text('7'), findsOneWidget, reason: "the server's price");
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('13')),
      findsOneWidget,
      reason: "the server's balance",
    );
    // Nothing the server did not send: no themes, no paddles, no other balls.
    expect(cardFor('ball.prism'), findsNothing);
    expect(cardFor('paddle.arc'), findsNothing);
    expect(cardFor('theme.glass'), findsNothing);
    expect(find.text('LOOKS'), findsNothing);
    expect(find.text('BALLS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the whole seeded catalogue with its real states', (
    tester,
  ) async {
    useLargeViewport(tester);
    final env = await shopEnv(balance: 100, owned: const {'ball.comet'});

    await openShop(tester, env);

    expect(find.byType(ShopCard), findsNWidgets(12));
    // Neon shouts its headings, which is the theme's own doing.
    expect(find.text('LOOKS'), findsOneWidget);
    expect(find.text('BALLS'), findsOneWidget);
    expect(find.text('PADDLES'), findsOneWidget);
    // Four states, each from the server's own answer: worn, owned, affordable
    // and out of reach.
    expect(card(tester, 'ball.orb').state, ShopCardState.worn);
    expect(card(tester, 'ball.comet').state, ShopCardState.owned);
    expect(card(tester, 'paddle.blade').state, ShopCardState.affordable);
    expect(card(tester, 'theme.glass').state, ShopCardState.unaffordable);
    expect(tester.takeException(), isNull);
  });

  testWidgets('buying asks first, then reports the new balance and wears it', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await shopEnv(balance: 200);

    await openShop(tester, env);
    await tapCard(tester, 'ball.comet');

    // Confirmed first, with the price and the wallet in front of the player.
    expect(find.text('Buy Comet?'), findsOneWidget);
    expect(find.textContaining('It costs 80 sparks'), findsOneWidget);
    expect(find.textContaining('200 sparks'), findsOneWidget);
    expect(
      env.api.shopBuyCalls,
      0,
      reason: 'nothing may be charged before the player says yes',
    );

    await tester.tap(find.text(Strings.en['shop.buy']!));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(env.api.shopBuyCalls, 1);
    expect(env.api.shopBuys, ['ball.comet']);
    expect(find.textContaining('Bought Comet'), findsOneWidget);
    expect(
      find.textContaining('120 sparks left'),
      findsOneWidget,
      reason: "the balance the server reported, not one worked out here",
    );
    expect(env.shop.equipped.ball.id, 'ball.comet');
    expect(card(tester, 'ball.comet').state, ShopCardState.worn);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('120')),
      findsOneWidget,
      reason: 'the app bar followed',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an item the wallet cannot cover says what is missing and buys '
      'nothing', (tester) async {
    useTallPhone(tester);
    final env = await shopEnv(balance: 10);

    await openShop(tester, env);
    await tapCard(tester, 'ball.comet');

    expect(find.textContaining('70 sparks to go'), findsOneWidget);
    expect(find.text(Strings.en['shop.buy']!), findsNothing);

    await tester.tap(find.text(Strings.en['common.ok']!));
    await tester.pump(const Duration(milliseconds: 40));

    expect(env.api.shopBuyCalls, 0);
    expect(env.api.shopBalance, 10);
    expect(env.shop.equipped.ball.id, 'ball.orb');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a purchase that fails mid-flight says nothing was taken', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await shopEnv(balance: 200);
    await openShop(tester, env);
    env.api.buyFailureOnce = const ApiException(
      ApiErrorKind.timeout,
      'request timed out',
    );

    await tapCard(tester, 'ball.comet');
    await tester.tap(find.text(Strings.en['shop.buy']!));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(find.textContaining('nothing was taken'), findsOneWidget);
    expect(env.api.shopBalance, 200);
    expect(env.shop.snapshot.owns('ball.comet'), isFalse);
    expect(card(tester, 'ball.comet').state, ShopCardState.affordable);

    // And the retry the server's idempotency makes safe.
    await tapCard(tester, 'ball.comet');
    await tester.tap(find.text(Strings.en['shop.buy']!));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.textContaining('Bought Comet'), findsOneWidget);
    expect(env.api.shopBalance, 120);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unowned item is never equipped from the shop', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await shopEnv(balance: 0);

    await openShop(tester, env);
    await tapCard(tester, 'paddle.halo');
    // The only thing a card for something unowned can do is offer to buy it.
    await tester.tap(find.text(Strings.en['common.ok']!));
    await tester.pump(const Duration(milliseconds: 40));

    expect(env.api.shopEquipCalls, 0);
    expect(env.shop.equipped.paddle.id, 'paddle.arc');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an owned item is worn with one tap, a look repaints the app', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await shopEnv(owned: const {'paddle.halo', 'theme.modernist'});

    await openShop(tester, env);
    await tapCard(tester, 'paddle.halo');

    expect(env.api.shopEquips, [
      {'paddle': 'paddle.halo'},
    ]);
    expect(env.shop.equipped.paddle.id, 'paddle.halo');
    expect(card(tester, 'paddle.halo').state, ShopCardState.worn);

    await tapCard(tester, 'theme.modernist');
    expect(env.settings.themeId, ThemeId.modernist);
    expect(
      Theme.of(tester.element(find.byType(ShopScreen))).scaffoldBackgroundColor,
      GameThemes.modernist.background,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline it says it needs a connection, and the game keeps its '
      'items', (tester) async {
    useLargeViewport(tester);
    final env = await shopEnv(owned: const {'ball.ember'});
    await env.shop.equip('ball.ember');
    env.api.offline = true;

    await openShop(tester, env);

    expect(find.textContaining('The shop needs a connection'), findsOneWidget);
    expect(find.byType(ShopCard), findsNothing);
    expect(find.text(Strings.en['common.retry']!), findsOneWidget);
    expect(
      env.shop.equipped.ball.id,
      'ball.ember',
      reason: 'what is worn keeps working with no network',
    );

    // And the retry works the moment the network is back.
    env.api.offline = false;
    await tester.tap(find.text(Strings.en['common.retry']!));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.byType(ShopCard), findsNWidgets(12));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a catalogue seen before still shows, marked as not confirmed', (
    tester,
  ) async {
    useLargeViewport(tester);
    final env = await shopEnv(balance: 300);
    await env.shop.refresh();
    env.api.offline = true;

    await openShop(tester, env);

    expect(find.byType(ShopCard), findsNWidgets(12));
    expect(find.textContaining('The shop needs a connection'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a server that refuses says so differently from a missing '
      'network', (tester) async {
    useTallPhone(tester);
    final env = await shopEnv();
    env.api.shopFailure = const ApiException(
      ApiErrorKind.rateLimited,
      'rate_limited',
      statusCode: 429,
      errorCode: 'rate_limited',
    );

    await openShop(tester, env);

    expect(find.textContaining('not answering right now'), findsOneWidget);
    expect(find.textContaining('Nothing has been charged'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the day\'s earning is shown, and the cap is explained', (
    tester,
  ) async {
    useTallPhone(tester);
    final env = await shopEnv();
    env.api.shopEarnedToday = 60;
    env.api.shopDailyCap = 200;

    await openShop(tester, env);
    await scrollTo(tester, find.text('60 of 200'));
    expect(find.text('60 of 200'), findsOneWidget);
    expect(find.textContaining('Sparks come from playing'), findsOneWidget);
    expect(find.textContaining('resets at midnight UTC'), findsNothing);

    // Once the day's allowance is spent, it is said plainly instead of leaving a
    // good run looking unpaid.
    env.api.shopEarnedToday = 200;
    await env.shop.refresh(force: true);
    await tester.pump();
    await scrollTo(tester, find.text('200 of 200'));

    expect(find.text('200 of 200'), findsOneWidget);
    expect(
      find.textContaining('You have earned today\'s 200 sparks'),
      findsOneWidget,
    );
    expect(find.textContaining('resets at midnight UTC'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('it works for an anonymous player, and mentions signing in once', (
    tester,
  ) async {
    useLargeViewport(tester);
    // No credential at all: the shop is the one screen allowed to issue the
    // anonymous identity of SPEC §4.4, because a wallet needs somebody to belong
    // to.
    final env = await createTestEnv();
    env.api.accounts = const ['apple', 'google'];
    env.api.profile = PlayerProfile(id: testPlayerId(1), games: 3);

    await openShop(tester, env);

    expect(env.api.createPlayerCalls, 1);
    expect(find.byType(ShopCard), findsNWidgets(12));
    await scrollTo(
      tester,
      find.textContaining('Signing in keeps what you have bought'),
    );
    expect(
      find.textContaining('Signing in keeps what you have bought'),
      findsOneWidget,
      reason: 'said once, at the bottom, with nothing to dismiss',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a signed-in player is not asked to sign in', (tester) async {
    useTallPhone(tester);
    final env = await shopEnv();
    env.api.accounts = const ['apple'];
    env.api.profile = PlayerProfile(
      id: testPlayerId(1),
      games: 3,
      provider: 'apple',
      linkedAt: DateTime.utc(2026, 9, 1),
    );

    await openShop(tester, env);

    expect(
      find.textContaining('Signing in keeps what you have bought'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an item this build cannot draw is not sold, it is explained', (
    tester,
  ) async {
    useLargeViewport(tester);
    final env = await shopEnv();
    env.api.catalogueItems = [
      ...FakeApiClient.defaultCatalogue(),
      FakeApiClient.shopItem('ball.supernova', 'ball', 300),
    ];

    await openShop(tester, env);

    expect(cardFor('ball.supernova'), findsNothing);
    expect(find.byType(ShopCard), findsNWidgets(12));
    await scrollTo(
      tester,
      find.textContaining('newer content than this version'),
    );
    expect(
      find.textContaining('newer content than this version'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('speaks Polish, declined', (tester) async {
    useTallPhone(tester);
    final env = await shopEnv(balance: 250, prefs: const {'language': 'pl'});

    await openShop(tester, env);
    expect(find.text('SKLEP'), findsOneWidget);
    expect(find.text('MOTYWY'), findsOneWidget);
    expect(find.text('PIŁKI'), findsOneWidget);
    expect(find.text('Kometa'), findsOneWidget);

    await tapCard(tester, 'ball.comet');
    // 80 → "iskier", not "iskry": the genitive plural Polish actually needs.
    expect(find.textContaining('Kosztuje 80 iskier'), findsOneWidget);
    expect(find.textContaining('masz teraz 250 iskier'), findsOneWidget);

    await tester.tap(find.text(Strings.pl['shop.buy']!));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    // 170 → "iskier" as well, and the item keeps its Polish name.
    expect(find.textContaining('Kupione: Kometa'), findsOneWidget);
    expect(find.textContaining('zostaje 170 iskier'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
