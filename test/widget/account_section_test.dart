import 'package:arco/app/settings.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/ui/settings_screen.dart';
import 'package:arco/ui/widgets/account_section.dart';
import 'package:arco/ui/widgets/sign_in_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// The Account block in Settings (SPEC §4.5): what it says when signed in, the
/// way out of it on this device, and the two-step deletion Apple requires.
void main() {
  Future<TestEnv> envWith({
    List<String> accounts = const ['apple', 'google'],
    bool linked = false,
    bool identified = false,
  }) async {
    final env = await createTestEnv(
      secrets: identified || linked
          ? FakeSecretStore.withCredentials(testCredentials(1))
          : null,
    );
    env.api.accounts = accounts;
    if (linked) {
      env.api.profile = PlayerProfile(
        id: testPlayerId(1),
        name: 'Tester',
        bestScore: 900,
        rank: 12,
        games: 4,
        provider: 'apple',
        linkedAt: DateTime.utc(2026, 9, 21, 10),
        createdAt: DateTime.utc(2026, 9, 1),
      );
    } else if (identified) {
      env.api.profile = PlayerProfile(id: testPlayerId(1), games: 2);
    }
    return env;
  }

  Future<void> pumpSection(WidgetTester tester, TestEnv env) async {
    await tester.pumpWidget(
      wrapApp(
        env,
        const Scaffold(body: SingleChildScrollView(child: AccountSection())),
      ),
    );
    // Mount, then the profile and the provider list it waits on.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('it lives in Settings', (tester) async {
    useTallPhone(tester);
    final env = await envWith();
    await tester.pumpWidget(wrapApp(env, const SettingsScreen()));
    await tester.pump();
    await tester.pump();

    // Two scrollables on this screen: the settings list and the theme picker's
    // own horizontal strip, so the list has to be named.
    await tester.dragUntilVisible(
      find.byType(AccountSection),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.byType(SignInButton), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a build with sign-in switched off and no player shows no '
      'section at all', (tester) async {
    final env = await envWith(accounts: const []);
    await pumpSection(tester, env);

    expect(find.text('ACCOUNT'), findsNothing);
    expect(tester.getSize(find.byType(AccountSection)), Size.zero);
  });

  testWidgets('an anonymous player is still offered deletion, because the '
      'server keeps it working for them', (tester) async {
    final env = await envWith(accounts: const [], identified: true);
    await pumpSection(tester, env);

    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.byType(SignInButton), findsNothing);
    expect(find.text('DELETE MY ACCOUNT'), findsOneWidget);
  });

  testWidgets('signed in: which provider, since when, and the way out', (
    tester,
  ) async {
    final env = await envWith(linked: true);
    await pumpSection(tester, env);

    expect(find.text('Signed in with Apple'), findsOneWidget);
    expect(find.text('Since 2026-09-21'), findsOneWidget);
    expect(find.text('SIGN OUT ON THIS DEVICE'), findsOneWidget);
    expect(find.text('DELETE MY ACCOUNT'), findsOneWidget);
    // Nothing to offer any more.
    expect(find.byType(SignInButton), findsNothing);
  });

  testWidgets('the same, in Polish', (tester) async {
    final env = await envWith(linked: true);
    env.settings.language = AppLanguage.pl;
    await pumpSection(tester, env);

    expect(find.text('KONTO'), findsOneWidget);
    expect(find.text('Zalogowano przez Apple'), findsOneWidget);
    expect(find.text('WYLOGUJ NA TYM URZĄDZENIU'), findsOneWidget);
    expect(find.text('USUŃ MOJE KONTO'), findsOneWidget);
  });

  testWidgets('signing out drops this device credential and leaves the '
      'account standing', (tester) async {
    final env = await envWith(linked: true);
    await pumpSection(tester, env);

    await tester.tap(find.text('SIGN OUT ON THIS DEVICE'));
    await tester.pump();
    await tester.pump();

    expect(env.identity.isIdentified, isFalse);
    expect(env.secrets.values, isEmpty);
    expect(env.native.forgetCalls, 1);
    // Nothing was detached server side: the other phone keeps the account.
    expect(env.api.deletePlayerCalls, 0);
    expect(
      find.textContaining('Your scores stay on the leaderboard'),
      findsOneWidget,
    );
  });

  group('deleting the account', () {
    testWidgets('takes two deliberate steps', (tester) async {
      useTallPhone(tester);
      final env = await envWith(linked: true);
      env.api.scoresAnonymised = 4;
      await pumpSection(tester, env);

      await tester.tap(find.text('DELETE MY ACCOUNT'));
      await tester.pumpAndSettle();

      // Step one explains, in plain words, what disappears and what does not.
      expect(find.text('DELETE YOUR ACCOUNT?'), findsOneWidget);
      expect(
        find.textContaining('every link between you and the runs'),
        findsOneWidget,
      );
      expect(
        find.textContaining('scores themselves stay on the leaderboard'),
        findsOneWidget,
      );
      expect(
        env.api.deletePlayerCalls,
        0,
        reason: 'opening the dialog must not delete anything',
      );

      await tester.tap(find.text('CONTINUE'));
      await tester.pumpAndSettle();

      // Step two is the one that cannot be undone.
      expect(find.text('THIS CANNOT BE UNDONE'), findsOneWidget);
      expect(env.api.deletePlayerCalls, 0);

      await tester.tap(find.text('DELETE PERMANENTLY'));
      await tester.pumpAndSettle();

      expect(env.api.deletePlayerCalls, 1);
      expect(env.identity.isIdentified, isFalse);
      expect(env.secrets.values, isEmpty);
      expect(
        find.text('Account deleted — 4 runs stay without an owner'),
        findsOneWidget,
      );
    });

    testWidgets('backing out of the first step deletes nothing', (
      tester,
    ) async {
      useTallPhone(tester);
      final env = await envWith(linked: true);
      await pumpSection(tester, env);

      await tester.tap(find.text('DELETE MY ACCOUNT'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();

      expect(env.api.deletePlayerCalls, 0);
      expect(env.identity.isIdentified, isTrue);
      expect(env.secrets.values, isNotEmpty);
    });

    testWidgets('backing out of the second step deletes nothing', (
      tester,
    ) async {
      useTallPhone(tester);
      final env = await envWith(linked: true);
      await pumpSection(tester, env);

      await tester.tap(find.text('DELETE MY ACCOUNT'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CONTINUE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('KEEP MY ACCOUNT'));
      await tester.pumpAndSettle();

      expect(env.api.deletePlayerCalls, 0);
      expect(env.identity.isIdentified, isTrue);
      expect(env.secrets.values, isNotEmpty);
    });

    testWidgets('a server that cannot be reached keeps the account', (
      tester,
    ) async {
      useTallPhone(tester);
      final env = await envWith(linked: true);
      await pumpSection(tester, env);
      env.api.deleteFailure = const ApiException(
        ApiErrorKind.network,
        'offline',
      );

      await tester.tap(find.text('DELETE MY ACCOUNT'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CONTINUE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DELETE PERMANENTLY'));
      await tester.pumpAndSettle();

      expect(env.identity.isIdentified, isTrue);
      expect(env.secrets.values, isNotEmpty);
      expect(
        find.text('No connection — sign in again when you are back online.'),
        findsOneWidget,
      );
    });
  });

  testWidgets('signing in from Settings shows what happened and flips the '
      'section', (tester) async {
    final env = await envWith();
    await pumpSection(tester, env);

    await tester.tap(find.text('Sign in with Apple'));
    await tester.pump();
    await tester.pump();

    expect(env.identity.playerId, testCredentials(2).id);
    expect(find.text('Signed in with Apple'), findsOneWidget);
    expect(find.text('SIGN OUT ON THIS DEVICE'), findsOneWidget);
  });
}
