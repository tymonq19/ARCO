import 'package:arco/app/settings.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/native_sign_in.dart';
import 'package:arco/services/player_identity.dart';
import 'package:arco/ui/leaderboard_screen.dart';
import 'package:arco/ui/solo_screen.dart';
import 'package:arco/ui/widgets/account_offer_card.dart';
import 'package:arco/ui/widgets/sign_in_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// The offer to keep a score safe (SPEC §4.5): where it appears, what it shows,
/// and that saying no is remembered.
void main() {
  Future<TestEnv> envWithAccounts({
    List<String> accounts = const ['apple', 'google'],
    FakeSecretStore? secrets,
    Map<String, Object> prefs = const {},
    FakeNativeSignIn? native,
  }) async {
    final env = await createTestEnv(
      secrets: secrets,
      prefs: prefs,
      native: native,
    );
    env.api.accounts = accounts;
    return env;
  }

  /// The card's title as the active theme sets it: the three dark looks shout
  /// their headings, Modernist does not.
  String title(TestEnv env, String text) => env.settings.theme.heading(text);

  Future<void> pumpCard(WidgetTester tester, TestEnv env) async {
    await tester.pumpWidget(
      wrapApp(
        env,
        const Scaffold(body: SingleChildScrollView(child: AccountOfferCard())),
      ),
    );
    // One frame to mount, one for the health answer the card waits on.
    await tester.pump();
    await tester.pump();
  }

  group('which buttons appear', () {
    testWidgets('only the ones the deployment advertises', (tester) async {
      final env = await envWithAccounts(accounts: const ['google']);
      await pumpCard(tester, env);

      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.text('Sign in with Apple'), findsNothing);
    });

    testWidgets('nothing at all when the list is empty', (tester) async {
      final env = await envWithAccounts(accounts: const []);
      await pumpCard(tester, env);

      expect(find.byType(SignInButton), findsNothing);
      expect(find.text(title(env, 'Keep this score safe')), findsNothing);
      // Truly nothing: the card takes no space, so a screen can place it
      // unconditionally.
      expect(tester.getSize(find.byType(AccountOfferCard)), Size.zero);
    });

    testWidgets('nothing while the server has not answered', (tester) async {
      final env = await envWithAccounts(accounts: const ['apple']);
      env.api.offline = true;
      await pumpCard(tester, env);
      expect(find.byType(SignInButton), findsNothing);
    });

    testWidgets('Apple first, per App Store review', (tester) async {
      final env = await envWithAccounts(accounts: const ['google', 'apple']);
      await pumpCard(tester, env);

      final buttons = tester
          .widgetList<SignInButton>(find.byType(SignInButton))
          .map((b) => b.provider)
          .toList();
      expect(buttons, [SignInProvider.apple, SignInProvider.google]);
    });

    testWidgets('nothing once the player has an account', (tester) async {
      final env = await envWithAccounts(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.profile = PlayerProfile(
        id: testPlayerId(1),
        games: 3,
        provider: 'apple',
        linkedAt: DateTime.utc(2026, 9, 21),
      );
      await env.identity.refreshProfile();
      await pumpCard(tester, env);

      expect(find.byType(SignInButton), findsNothing);
      // Not even a question was asked of the server about it.
      expect(env.api.healthCalls, 0);
    });
  });

  group('signing in from the card', () {
    testWidgets('a success swaps the stored credential and says what '
        'happened', (tester) async {
      final env = await envWithAccounts(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      await pumpCard(tester, env);

      await tester.tap(find.text('Sign in with Apple'));
      await tester.pump();
      await tester.pump();

      expect(env.api.linkCalls, 1);
      expect(env.identity.playerId, testCredentials(2).id);
      expect(
        env.secrets.values[PlayerIdentity.secretKey],
        testCredentials(2).secret,
      );
      expect(
        find.text('Done — your scores are on your account now.'),
        findsOneWidget,
      );
      // The offer is over: no buttons left, and nothing to dismiss.
      expect(find.byType(SignInButton), findsNothing);
    });

    testWidgets('a merge reports how many runs moved', (tester) async {
      final env = await envWithAccounts(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.linkResult = AccountLink(
        credentials: testCredentials(9),
        provider: 'google',
        outcome: AccountLinkOutcome.merged,
        movedScores: 12,
        games: 20,
        linkedAt: DateTime.utc(2026, 9, 21),
      );
      await pumpCard(tester, env);

      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Accounts merged — 12 of your runs moved across.'),
        findsOneWidget,
      );
    });

    testWidgets('a merge that moved nothing does not say "0 runs"', (
      tester,
    ) async {
      final env = await envWithAccounts();
      env.api.linkResult = AccountLink(
        credentials: testCredentials(9),
        provider: 'apple',
        outcome: AccountLinkOutcome.merged,
        linkedAt: DateTime.utc(2026, 9, 21),
      );
      await pumpCard(tester, env);

      await tester.tap(find.text('Sign in with Apple'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('0 of your runs'), findsNothing);
      expect(
        find.text('Done — your scores are on your account now.'),
        findsOneWidget,
      );
    });

    testWidgets('a restore on a second device says so', (tester) async {
      final env = await envWithAccounts();
      env.api.linkResult = AccountLink(
        credentials: testCredentials(9),
        provider: 'apple',
        outcome: AccountLinkOutcome.restored,
        bestScore: 4321,
        rank: 7,
        games: 9,
      );
      await pumpCard(tester, env);

      await tester.tap(find.text('Sign in with Apple'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Welcome back — your scores are on this device again.'),
        findsOneWidget,
      );
    });

    testWidgets('a cancel is silent', (tester) async {
      final env = await envWithAccounts(
        native: FakeNativeSignIn()..cancel = true,
      );
      await pumpCard(tester, env);

      await tester.tap(find.text('Sign in with Apple'));
      await tester.pump();
      await tester.pump();

      // The card is exactly as it was: no message, no dismissal, both buttons.
      expect(find.byType(SignInButton), findsNWidgets(2));
      expect(find.text(title(env, 'Keep this score safe')), findsOneWidget);
      expect(find.textContaining('did not finish'), findsNothing);
      expect(env.api.linkCalls, 0);
      expect(env.offer.dismissals, 0);
    });

    // Item 4 of the brief: every documented failure has a sentence a player can
    // act on, in both languages.
    for (final (String code, String message) in const [
      ('accounts_disabled', 'Sign-in is switched off on this server.'),
      (
        'invalid_token',
        'That sign-in could not be verified. Please try again.',
      ),
      ('invalid_provider', 'This server does not accept that sign-in.'),
      (
        'keys_unavailable',
        'The sign-in service cannot be reached right now — try again in a '
            'minute.',
      ),
      ('rate_limited', 'Too many attempts — try again in a minute.'),
    ]) {
      testWidgets('$code is explained', (tester) async {
        final env = await envWithAccounts();
        env.api.linkFailure = ApiException(
          ApiErrorKind.badResponse,
          code,
          statusCode: 400,
          errorCode: code,
        );
        await pumpCard(tester, env);

        await tester.tap(find.text('Sign in with Apple'));
        await tester.pump();
        await tester.pump();

        expect(find.text(message), findsOneWidget);
        // The offer is still there to try again with.
        expect(find.byType(SignInButton), findsNWidgets(2));
      });
    }

    testWidgets('already_linked names the provider it is linked with', (
      tester,
    ) async {
      final env = await envWithAccounts();
      env.api.linkFailure = const ApiException(
        ApiErrorKind.badResponse,
        'already_linked',
        statusCode: 409,
        errorCode: 'already_linked',
        detail: 'google',
      );
      await pumpCard(tester, env);

      await tester.tap(find.text('Sign in with Apple'));
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('already signed in with Google'),
        findsOneWidget,
      );
    });

    testWidgets('no network says so, in Polish too', (tester) async {
      final env = await envWithAccounts();
      env.settings.language = AppLanguage.pl;
      await pumpCard(tester, env);
      // Offline only once the provider list is in hand, so the buttons exist.
      env.api.offline = true;

      await tester.tap(find.text('Zaloguj się przez Apple'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text(
          'Brak połączenia — zaloguj się ponownie, gdy wrócisz online.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a provider that cannot run here says so', (tester) async {
      final env = await envWithAccounts(
        native: FakeNativeSignIn()..unavailable = true,
      );
      await pumpCard(tester, env);

      await tester.tap(find.text('Sign in with Apple'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('That sign-in is not available on this device.'),
        findsOneWidget,
      );
    });

    testWidgets('and its button goes, instead of being tapped again', (
      tester,
    ) async {
      final native = FakeNativeSignIn();
      final env = await envWithAccounts(native: native);
      await pumpCard(tester, env);
      expect(find.byType(SignInButton), findsNWidgets(2));

      // The sheet reports that it cannot run here at all — which, on a real
      // device, is the only moment a missing client id shows up.
      native.unavailable = true;
      native.available = {SignInProvider.apple};
      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('That sign-in is not available on this device.'),
        findsOneWidget,
      );
      expect(
        find.text('Sign in with Google'),
        findsNothing,
        reason: 'the button that cannot work is still on screen',
      );
      expect(
        find.text('Sign in with Apple'),
        findsOneWidget,
        reason: 'the other provider was taken away with it',
      );
    });
  });

  group('saying no', () {
    testWidgets('is remembered, and silences the offer for a week', (
      tester,
    ) async {
      final env = await envWithAccounts();
      await pumpCard(tester, env);
      expect(find.byType(SignInButton), findsNWidgets(2));

      await tester.tap(find.text('NOT NOW'));
      await tester.pump();

      expect(find.byType(SignInButton), findsNothing);
      expect(env.offer.dismissals, 1);
      expect(env.offer.silenced, isTrue);
      expect(env.offer.remaining!.inHours, 7 * 24 - 1);
    });

    testWidgets('a dismissed offer does not come back on the next screen', (
      tester,
    ) async {
      final env = await envWithAccounts(
        prefs: {
          'accountOfferDismissals': 1,
          'accountOfferDismissedAt': DateTime.now()
              .toUtc()
              .millisecondsSinceEpoch,
        },
      );
      await pumpCard(tester, env);

      expect(find.byType(SignInButton), findsNothing);
      // A silenced offer costs no request either.
      expect(env.api.healthCalls, 0);
    });

    testWidgets('once the week is up it is offered again', (tester) async {
      final env = await envWithAccounts(
        prefs: {
          'accountOfferDismissals': 1,
          'accountOfferDismissedAt': DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 8))
              .millisecondsSinceEpoch,
        },
      );
      await pumpCard(tester, env);

      expect(find.byType(SignInButton), findsNWidgets(2));
    });
  });

  group('the moment it appears', () {
    testWidgets('after a personal best, beside the new score', (tester) async {
      useTallPhone(tester);
      final env = await envWithAccounts();
      await tester.pumpWidget(wrapApp(env, const SoloScreen()));
      await tester.tap(find.text('TAP TO START').last);

      // No input at all: the paddle never moves, the three lives go quickly and
      // the game ends on its own. A few seconds of survival still beats a
      // stored best of zero, which is what a first game is.
      for (var i = 0; i < 6000 && env.api.submitCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(env.api.submitCalls, 1, reason: 'the game never ended');
      await pumpFrames(tester, 4);

      expect(find.text('NEW BEST!'), findsOneWidget);
      expect(find.text(title(env, 'Keep this score safe')), findsOneWidget);
      expect(find.byType(SignInButton), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('and not after an ordinary game', (tester) async {
      useTallPhone(tester);
      final env = await envWithAccounts(prefs: const {'bestScore': 9999});
      await tester.pumpWidget(wrapApp(env, const SoloScreen()));
      await tester.tap(find.text('TAP TO START').last);

      for (var i = 0; i < 6000 && env.api.submitCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(env.api.submitCalls, 1, reason: 'the game never ended');
      await pumpFrames(tester, 4);

      expect(find.text('GAME OVER'), findsOneWidget);
      expect(find.text(title(env, 'Keep this score safe')), findsNothing);
      expect(find.byType(AccountOfferCard), findsNothing);
      // Nothing was even asked about sign-in.
      expect(env.api.healthCalls, 0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('on the leaderboard when the player is on it', (tester) async {
      useTallPhone(tester);
      final env = await envWithAccounts(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.entries = [
        LeaderboardEntry(
          rank: 1,
          name: 'Tester',
          score: 900,
          seconds: 120,
          createdAt: DateTime.utc(2026, 9, 22),
          playerId: testPlayerId(1),
        ),
      ];
      await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.text(title(env, 'Keep this score safe')),
        findsOneWidget,
        reason: 'the player owns a row on the open board',
      );
      expect(find.byType(SignInButton), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('and not when somebody else holds every row', (tester) async {
      useTallPhone(tester);
      final env = await envWithAccounts(
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.entries = [
        LeaderboardEntry(
          rank: 1,
          name: 'Somebody',
          score: 900,
          seconds: 120,
          createdAt: DateTime.utc(2026, 9, 22),
          playerId: testPlayerId(42),
        ),
      ];
      await tester.pumpWidget(wrapApp(env, const LeaderboardScreen()));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(AccountOfferCard), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('the card says its piece in Polish', (tester) async {
    final env = await envWithAccounts();
    env.settings.language = AppLanguage.pl;
    await pumpCard(tester, env);

    expect(find.text(title(env, 'Zachowaj ten wynik')), findsOneWidget);
    expect(find.text('NIE TERAZ'), findsOneWidget);
    expect(
      find.text(const Strings('pl').t('account.offerBody')),
      findsOneWidget,
    );
  });
}
