/// The account offer woven into the score screen (SPEC §4.5).
///
/// The brief this defends, in the owner's words: after every game the chance to
/// create an account has to be visible, not as a rude popup but worked into the
/// result screen, so that it does not irritate and yet is always there.
///
/// Three properties follow, and each has a test here:
///
/// * **It is never silenced.** The heavier [AccountOfferCard] stops asking after
///   three refusals, because a panel with two large buttons shown after every game
///   is nagging. This is one line, so it can keep the promise: even with the card
///   silenced for good, the line is still offered.
/// * **It is not a popup.** Nothing is raised until the player taps. The provider
///   buttons are not on the score screen at all until then.
/// * **It disappears completely when it has nothing to offer** — no account to
///   make, or one already made — and takes no space at all when it does, so the
///   screen can place it unconditionally.
library;

import 'package:arco/app/settings.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/ui/widgets/account_inline_offer.dart';
import 'package:arco/ui/widgets/sign_in_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

void main() {
  const en = Strings('en');

  Future<TestEnv> offerEnv({
    List<String> accounts = const ['apple', 'google'],
    Map<String, Object> prefs = const {},
    bool linked = false,
    FakeNativeSignIn? native,
  }) async {
    final env = await createTestEnv(
      prefs: prefs,
      native: native,
      secrets: FakeSecretStore.withCredentials(testCredentials(1)),
    );
    env.api.accounts = accounts;
    if (linked) {
      env.api.profile = PlayerProfile(
        id: testPlayerId(1),
        games: 3,
        provider: 'apple',
        linkedAt: DateTime.utc(2026, 9, 21),
      );
      await env.identity.refreshProfile();
    }
    return env;
  }

  Future<void> pumpOffer(WidgetTester tester, TestEnv env) async {
    await tester.pumpWidget(
      wrapApp(
        env,
        const Scaffold(
          body: Center(
            child: SingleChildScrollView(child: AccountInlineOffer()),
          ),
        ),
      ),
    );
    // One frame to mount, one for the health answer the line waits on.
    await tester.pump();
    await tester.pump();
  }

  group('it is always there', () {
    testWidgets('offered even with the card silenced for good', (tester) async {
      // Three refusals is "never again" for AccountOfferCard. The line does not
      // read that counter at all, which is the whole point of it being a line.
      final env = await offerEnv(
        prefs: {
          'accountOfferDismissals': 3,
          'accountOfferDismissedAt': DateTime.now()
              .toUtc()
              .millisecondsSinceEpoch,
        },
      );
      expect(env.offer.silenced, isTrue, reason: 'the card would keep quiet');
      await pumpOffer(tester, env);

      expect(find.text(en.t('account.inlineOffer')), findsOneWidget);
    });

    testWidgets('and after a first refusal too', (tester) async {
      final env = await offerEnv(
        prefs: {
          'accountOfferDismissals': 1,
          'accountOfferDismissedAt': DateTime.now()
              .toUtc()
              .millisecondsSinceEpoch,
        },
      );
      await pumpOffer(tester, env);
      expect(find.text(en.t('account.inlineOffer')), findsOneWidget);
    });
  });

  group('it is not a popup', () {
    testWidgets('no buttons until the line is tapped', (tester) async {
      final env = await offerEnv();
      await pumpOffer(tester, env);

      expect(find.byType(SignInButton), findsNothing);

      await tester.tap(find.text(en.t('account.inlineOffer')));
      await tester.pumpAndSettle();

      expect(find.byType(SignInButton), findsNWidgets(2));
      expect(find.text('NOT NOW'), findsOneWidget);
    });

    testWidgets('backing out leaves the line and records nothing', (
      tester,
    ) async {
      final env = await offerEnv();
      await pumpOffer(tester, env);
      await tester.tap(find.text(en.t('account.inlineOffer')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('NOT NOW'));
      await tester.pumpAndSettle();

      expect(find.byType(SignInButton), findsNothing);
      expect(
        find.text(en.t('account.inlineOffer')),
        findsOneWidget,
        reason: 'the chance is there again next game, and this one',
      );
      expect(
        env.offer.dismissals,
        0,
        reason: 'ignoring the line must cost the player nothing',
      );
      expect(env.api.linkCalls, 0);
    });

    testWidgets('signing in says what happened, in place of the line', (
      tester,
    ) async {
      final env = await offerEnv();
      await pumpOffer(tester, env);
      await tester.tap(find.text(en.t('account.inlineOffer')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign in with Apple'));
      await tester.pumpAndSettle();

      expect(env.api.linkCalls, 1);
      expect(find.text(en.t('account.inlineOffer')), findsNothing);
      expect(
        find.text('Done — your scores are on your account now.'),
        findsOneWidget,
        reason: 'the line must not simply vanish without a word',
      );
    });
  });

  group('it renders nothing when it has nothing to offer', () {
    testWidgets('no sign-in on this deployment', (tester) async {
      final env = await offerEnv(accounts: const []);
      await pumpOffer(tester, env);

      expect(find.text(en.t('account.inlineOffer')), findsNothing);
      expect(
        tester.getSize(find.byType(AccountInlineOffer)),
        Size.zero,
        reason:
            'and takes no space, so the screen can place it unconditionally',
      );
    });

    testWidgets('nothing while the server has not answered', (tester) async {
      final env = await offerEnv();
      env.api.offline = true;
      await pumpOffer(tester, env);

      expect(find.text(en.t('account.inlineOffer')), findsNothing);
      expect(tester.getSize(find.byType(AccountInlineOffer)), Size.zero);
    });

    testWidgets('the player already has an account', (tester) async {
      final env = await offerEnv(linked: true);
      await pumpOffer(tester, env);

      expect(find.text(en.t('account.inlineOffer')), findsNothing);
      expect(tester.getSize(find.byType(AccountInlineOffer)), Size.zero);
      expect(
        env.api.healthCalls,
        0,
        reason: 'and it does not even ask the server about it',
      );
    });
  });

  testWidgets('it says its piece in Polish', (tester) async {
    final env = await offerEnv();
    env.settings.language = AppLanguage.pl;
    await pumpOffer(tester, env);

    expect(
      find.text(const Strings('pl').t('account.inlineOffer')),
      findsOneWidget,
    );
  });
}
