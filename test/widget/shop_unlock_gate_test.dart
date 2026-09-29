/// The account gate in front of the payment sheet (SPEC §4.5, §4.9).
///
/// Why it exists: the unlock is recorded against a player, and a player with no
/// account lives only in this phone's keychain. Delete the app and that player is
/// gone, so somebody who genuinely paid would be left holding nothing while
/// "Restore purchases" truthfully reported that there was nothing to restore. An
/// account is what makes the purchase findable again.
///
/// What these tests defend, in order of how much damage getting them wrong does:
///
/// * **A deployment with no sign-in still takes money.** This is the one that
///   matters most, because it is today's deployment: accounts are switched off, so
///   the gate has to be invisible. A gate nobody can pass is not a gate, it is a
///   shop that refuses payment.
/// * **One account covers everything.** Somebody who signed in to put a score on
///   the board is never asked again at the till, and somebody who signed in at the
///   till is never asked again on the board.
/// * **Asked, and said no: nothing happens.** No payment sheet, and nothing
///   remembered either, so the next tap asks again. The player has lost a tap.
/// * **Asked, and signed in: straight through to the payment sheet**, with no
///   congratulation screen in the way of a person who is trying to pay.
/// * **The gate is in front of the store, not behind it.** Nothing may reach the
///   store before the account exists, because the whole point is that the purchase
///   has somewhere to live.
library;

import 'package:arco/app/strings.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:arco/ui/widgets/sign_in_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  const en = Strings('en');

  void useLargeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 3600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> settle(WidgetTester tester, [int frames = 25]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// A shop that sells the unlock. [accounts] is what `GET /api/health`
  /// advertises, and [linked] gives the player an account already.
  Future<TestEnv> shopEnv({
    List<String> accounts = const <String>[],
    bool linked = false,
    FakePurchaseGateway? store,
    FakeNativeSignIn? native,
  }) async {
    final env = await createTestEnv(
      sellsUnlock: true,
      store: store,
      native: native,
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    env.api.accounts = accounts;
    env.api.profile = PlayerProfile(
      id: testPlayerId(1),
      games: 2,
      provider: linked ? 'apple' : null,
      linkedAt: linked ? DateTime.utc(2026, 9, 21) : null,
    );
    if (linked) await env.identity.refreshProfile();
    return env;
  }

  /// The gate's title as the active theme renders it: the dark looks shout their
  /// headings, Modernist does not.
  String gateTitle(TestEnv env) =>
      env.settings.theme.heading(en.t('account.gateTitle'));

  Future<void> openShop(WidgetTester tester, TestEnv env) async {
    await tester.pumpWidget(wrapApp(env, const ShopScreen()));
    await settle(tester);
  }

  Future<void> tapUnlock(WidgetTester tester) async {
    await tester.ensureVisible(find.text(en.t('shop.unlockButton')));
    await tester.tap(find.text(en.t('shop.unlockButton')));
    await settle(tester);
  }

  group('a deployment with no sign-in', () {
    testWidgets('sells the unlock with no gate at all', (tester) async {
      // Today's deployment. If this test ever fails, the shop has stopped being
      // able to take money.
      useLargeViewport(tester);
      final store = FakePurchaseGateway();
      final env = await shopEnv(store: store);
      await openShop(tester, env);

      await tapUnlock(tester);

      expect(
        store.bought,
        [testUnlockProductId],
        reason: 'the payment sheet must open when there is nothing to ask for',
      );
      expect(find.byType(SignInButton), findsNothing);
      expect(find.text(gateTitle(env)), findsNothing);
    });
  });

  group('a player with an account already', () {
    testWidgets('is not asked a second time', (tester) async {
      useLargeViewport(tester);
      final store = FakePurchaseGateway();
      final env = await shopEnv(
        accounts: const ['apple', 'google'],
        linked: true,
        store: store,
      );
      await openShop(tester, env);

      await tapUnlock(tester);

      expect(store.bought, [testUnlockProductId]);
      expect(
        find.text(gateTitle(env)),
        findsNothing,
        reason: 'the account that put them on the board is the same account',
      );
    });
  });

  group('a player with no account, on a deployment that offers one', () {
    testWidgets('is asked before the store is touched', (tester) async {
      useLargeViewport(tester);
      final store = FakePurchaseGateway();
      final env = await shopEnv(
        accounts: const ['apple', 'google'],
        store: store,
      );
      await openShop(tester, env);

      await tapUnlock(tester);

      expect(find.text(gateTitle(env)), findsOneWidget);
      expect(find.byType(SignInButton), findsNWidgets(2));
      expect(
        store.bought,
        isEmpty,
        reason: 'nothing may reach the store before the purchase has a home',
      );
      // The reason is on screen, not just in the code.
      expect(find.textContaining('not to this phone'), findsOneWidget);
    });

    testWidgets('saying no buys nothing and remembers nothing', (tester) async {
      useLargeViewport(tester);
      final store = FakePurchaseGateway();
      final env = await shopEnv(
        accounts: const ['apple', 'google'],
        store: store,
      );
      await openShop(tester, env);
      await tapUnlock(tester);

      await tester.tap(find.text(en.t('account.notNow')));
      await settle(tester);

      expect(store.bought, isEmpty);
      expect(find.text(gateTitle(env)), findsNothing);
      expect(
        env.offer.dismissals,
        0,
        reason: 'declining the till must not silence the board offer',
      );

      // And the next tap asks again rather than giving up on the sale.
      await tapUnlock(tester);
      expect(find.text(gateTitle(env)), findsOneWidget);
    });

    testWidgets('signing in goes straight on to the payment sheet', (
      tester,
    ) async {
      useLargeViewport(tester);
      final store = FakePurchaseGateway();
      final env = await shopEnv(
        accounts: const ['apple', 'google'],
        store: store,
      );
      await openShop(tester, env);
      await tapUnlock(tester);

      await tester.tap(find.text('Sign in with Apple'));
      await settle(tester);

      expect(env.api.linkCalls, 1);
      expect(
        store.bought,
        [testUnlockProductId],
        reason: 'one tap on UNLOCK, one purchase — the sign-in is on the way',
      );
      expect(find.text(gateTitle(env)), findsNothing);
    });

    testWidgets('cancelling the provider sheet leaves the gate up', (
      tester,
    ) async {
      // Backing out of Apple's own sheet is not backing out of the purchase:
      // the other provider is still worth offering.
      useLargeViewport(tester);
      final store = FakePurchaseGateway();
      final env = await shopEnv(
        accounts: const ['apple', 'google'],
        store: store,
        native: FakeNativeSignIn()..cancel = true,
      );
      await openShop(tester, env);
      await tapUnlock(tester);

      await tester.tap(find.text('Sign in with Apple'));
      await settle(tester);

      expect(find.text(gateTitle(env)), findsOneWidget);
      expect(find.byType(SignInButton), findsNWidgets(2));
      expect(env.api.linkCalls, 0);
      expect(store.bought, isEmpty);
    });
  });
}
