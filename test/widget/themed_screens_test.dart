import 'package:arco/app/game_theme.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/game/controllers/duel_controller.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/game/render/game_view.dart';
import 'package:arco/services/duel_client.dart';
import 'package:arco/ui/duel_lobby_screen.dart';
import 'package:arco/ui/duel_screen.dart';
import 'package:arco/ui/home_screen.dart';
import 'package:arco/ui/leaderboard_screen.dart';
import 'package:arco/ui/onboarding_screen.dart';
import 'package:arco/ui/settings_screen.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:arco/ui/solo_screen.dart';
import 'package:arco/ui/widgets/shop_card.dart';
import 'package:arco/ui/widgets/account_offer_card.dart';
import 'package:arco/ui/widgets/account_section.dart';
import 'package:arco/ui/widgets/nickname_dialog.dart';
import 'package:arco/ui/widgets/sign_in_buttons.dart';
import 'package:arco/ui/widgets/unlock_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/contrast.dart';
import '../helpers/test_env.dart';

/// Every screen the app can show, built on the narrowest supported phone under
/// every theme: a theme must never change a layout enough to overflow, and the
/// light theme must not leave a screen unreadable.
void main() {
  for (final theme in GameThemes.all) {
    final name = theme.id.name;

    testWidgets('every menu screen builds at 320x568 ($name)', (tester) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(theme: theme.id);
      // Never connected, so the transport is only here to keep the lobby from
      // reaching for a real socket. Closing it would wait for a listener that
      // never arrives.
      final server = FakeDuelServer();

      for (final entry in <String, Widget>{
        'welcome': const OnboardingScreen(),
        'home': const HomeScreen(),
        'leaderboard': const LeaderboardScreen(),
        'settings': const SettingsScreen(),
        'shop': const ShopScreen(),
        'duel lobby': DuelLobbyScreen(connector: server.connect),
      }.entries) {
        await tester.pumpWidget(wrapApp(env, entry.value));
        await tester.pump(const Duration(milliseconds: 50));
        final context = tester.element(find.byType(Scaffold).first);
        expect(
          Theme.of(context).scaffoldBackgroundColor,
          theme.background,
          reason: '${entry.key} is not painted in the $name background',
        );
        expect(
          GameTheme.read(context).id,
          theme.id,
          reason: '${entry.key} did not receive the theme',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.key} overflowed or threw under $name',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    // The two things player identity added to the UI: the standing on the title
    // screen and the dialog that gets a refused nickname changed (SPEC 4.7).
    testWidgets('the standing and the nickname dialog build at 320x568 '
        '($name)', (tester) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(
        theme: theme.id,
        prefs: const {'bestScore': 900},
        secrets: FakeSecretStore.withCredentials(testCredentials(7)),
      );
      env.api.profile = PlayerProfile(
        id: testPlayerId(7),
        bestScore: 900,
        rank: 12,
        games: 3,
        country: 'PL',
        countryBestScore: 900,
        countryRank: 2,
      );

      await tester.pumpWidget(wrapApp(env, const HomeScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('#12'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the standing overflowed under $name',
      );

      final home = tester.element(find.byType(HomeScreen));
      final s = Strings.read(home);
      showNicknameDialog(
        home,
        initial: 'Tester',
        message: s.t('error.offensive_name'),
      );
      await tester.pumpAndSettle();

      final dialog = tester.element(find.byType(Dialog));
      expect(GameTheme.read(dialog).id, theme.id);
      expect(find.text(s.t('name.save')), findsOneWidget);
      expect(
        find.textContaining(s.t('error.offensive_name').substring(0, 20)),
        findsOneWidget,
      );
      // The explanation is body text on the theme own panel, so it has to clear
      // the 4.5:1 floor on the light look as well as the three dark ones.
      expect(
        contrastRatio(
          theme.textDim,
          Color.alphaBlend(
            theme.panelFill.withValues(alpha: theme.panelOpacity),
            theme.background,
          ),
        ),
        greaterThanOrEqualTo(4.5),
        reason: 'the dialog explanation is unreadable under $name',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'the nickname dialog overflowed under $name',
      );
      await tester.pumpWidget(const SizedBox());
    });

    // Everything sign-in added (SPEC 4.5), on the narrowest phone at the text
    // scale a player with poor eyesight actually uses. The brand buttons carry
    // the providers' own colours, so what is checked here is that they fit and
    // that the panels around them are still the theme's.
    testWidgets('the account offer and the account section build at 320x568 '
        'and 1.6 text scale ($name)', (tester) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(
        theme: theme.id,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.accounts = const ['apple', 'google'];
      env.api.profile = PlayerProfile(id: testPlayerId(1), games: 2);

      for (final entry in <String, Widget>{
        'offer card': const AccountOfferCard(),
        'account section': const AccountSection(),
      }.entries) {
        await tester.pumpWidget(
          wrapApp(
            env,
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.6)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: entry.value,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(SignInButton),
          findsNWidgets(2),
          reason: '${entry.key} lost its buttons under $name',
        );
        final context = tester.element(find.byType(Scaffold).first);
        expect(GameTheme.read(context).id, theme.id);
        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.key} overflowed under $name at 1.6 text scale',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('the leaderboard still fits its board beside the offer at '
        '320x568 and 1.6 text scale ($name)', (tester) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(
        theme: theme.id,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.accounts = const ['apple', 'google'];
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

      await tester.pumpWidget(
        wrapApp(
          env,
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: const LeaderboardScreen(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(AccountOfferCard), findsOneWidget);
      expect(
        find.text('900'),
        findsOneWidget,
        reason: 'the board itself was pushed off the screen under $name',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'the leaderboard overflowed under $name with the offer up',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('both deletion steps build at 320x568 ($name)', (tester) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(
        theme: theme.id,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.profile = PlayerProfile(
        id: testPlayerId(1),
        games: 2,
        provider: 'apple',
        linkedAt: DateTime.utc(2026, 9, 21),
      );
      await tester.pumpWidget(
        wrapApp(
          env,
          const Scaffold(body: SingleChildScrollView(child: AccountSection())),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text(Strings.en['account.delete']!));
      await tester.pumpAndSettle();
      // The explanation is long by design, so on the narrowest phone the panel
      // scrolls and the button that continues can start below the fold.
      await tester.ensureVisible(
        find.text(Strings.en['account.deleteContinue']!),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        GameTheme.read(tester.element(find.byType(Dialog))).id,
        theme.id,
        reason: 'the first deletion step is not in the $name look',
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text(Strings.en['account.deleteContinue']!));
      await tester.pumpAndSettle();
      expect(
        find.text(Strings.en['account.deleteConfirm']!),
        findsOneWidget,
        reason: 'the second deletion step is missing under $name',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'a deletion step overflowed under $name',
      );
      await tester.pumpWidget(const SizedBox());
    });

    // SPEC 4.8: the shop is a grid of real arena paintings plus prices, which is
    // the densest screen in the app — on the narrowest phone, at the text scale
    // a player with poor eyesight actually uses, in every look.
    testWidgets('the shop builds at 320x568 and 1.6 text scale ($name)', (
      tester,
    ) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(
        theme: theme.id,
        balance: 160,
        owned: const {'ball.comet'},
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.profile = PlayerProfile(id: testPlayerId(1), games: 4);
      env.api.shopEarnedToday = 160;

      await tester.pumpWidget(
        wrapApp(
          env,
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: const ShopScreen(),
            ),
          ),
        ),
      );
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final context = tester.element(find.byType(Scaffold).first);
      expect(GameTheme.read(context).id, theme.id);
      expect(
        Theme.of(context).scaffoldBackgroundColor,
        theme.background,
        reason: 'the shop is not painted in the $name background',
      );
      expect(find.byType(ShopCard), findsWidgets);
      expect(find.text('160'), findsWidgets, reason: 'the balance is shown');
      expect(
        tester.takeException(),
        isNull,
        reason: 'the shop overflowed under $name at 1.6 text scale',
      );

      // Two cards per row on a 320 pt phone, and never wider than the previews
      // are designed for.
      for (final card in tester.widgetList<ShopCard>(find.byType(ShopCard))) {
        expect(card.width, lessThanOrEqualTo(ShopCard.defaultWidth));
        expect(card.width, greaterThanOrEqualTo(120));
      }

      // And the whole screen is reachable by scrolling, ending on the earning
      // panel and its explanation of the daily cap.
      final scrollable = tester.firstState<ScrollableState>(
        find.byType(Scrollable),
      );
      for (var i = 0; i < 12; i++) {
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pump();
      }
      expect(find.textContaining('160 of'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'scrolling the shop overflowed under $name',
      );
      await tester.pumpWidget(const SizedBox());
    });

    // SPEC 4.9: the one-time unlock is the densest panel in the app — a title, a
    // three-line list, a price and a button — and the price is a string the store
    // chose, so it can be longer than anything we sized for. On the narrowest
    // phone, at the text scale a player with poor eyesight uses, in every look.
    testWidgets('the unlock card builds at 320x568 and 1.6 text scale '
        '($name)', (tester) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(
        theme: theme.id,
        balance: 160,
        sellsUnlock: true,
        // A long price string in a currency with a long code, which is what the
        // store hands back in several markets.
        store: FakePurchaseGateway(
          prices: <String, String>{testUnlockProductId: '1 199,00 HUF'},
        ),
        adOffer: testAdOffer(),
        adsGateway: FakeAdsGateway(),
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.profile = PlayerProfile(id: testPlayerId(1), games: 4);

      await tester.pumpWidget(
        wrapApp(
          env,
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: const ShopScreen(),
            ),
          ),
        ),
      );
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final scrollable = tester.firstState<ScrollableState>(
        find.byType(Scrollable),
      );
      for (var i = 0; i < 14; i++) {
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pump();
      }

      final s = Strings.read(tester.element(find.byType(ShopScreen)));
      expect(find.byType(UnlockSection), findsOneWidget);
      expect(
        find.text('1 199,00 HUF'),
        findsOneWidget,
        reason: 'the store\'s own string, whatever its length',
      );
      expect(find.text(s.t('shop.unlockPerk.ads')), findsOneWidget);
      expect(find.text(s.t('shop.restore')), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the unlock card overflowed under $name at 1.6 text scale',
      );
      // The price and the button have to be readable, not merely present: the
      // whole panel is body text on the theme's own surface, and the light
      // Modernist look is where a dim token stops clearing 4.5:1.
      expect(
        contrastRatio(
          tester.widget<Text>(find.text('1 199,00 HUF')).style!.color!,
          theme.panelFill,
        ),
        greaterThanOrEqualTo(3.0),
        reason: 'the price is unreadable on $name',
      );
      await tester.pumpWidget(const SizedBox());
    });

    // And the same screen for a player who has paid: the confirmation, no price,
    // no ad row, no earning panel, and the app bar carrying what they own.
    testWidgets('the shop after the unlock builds at 320x568 and 1.6 text '
        'scale ($name)', (tester) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(
        theme: theme.id,
        balance: 160,
        premium: true,
        adOffer: testAdOffer(),
        adsGateway: FakeAdsGateway(),
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.profile = PlayerProfile(id: testPlayerId(1), games: 4);

      await tester.pumpWidget(
        wrapApp(
          env,
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: const ShopScreen(),
            ),
          ),
        ),
      );
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final s = Strings.read(tester.element(find.byType(ShopScreen)));
      final context = tester.element(find.byType(Scaffold).first);
      expect(GameTheme.read(context).id, theme.id);
      // The app bar says what they have, in place of a figure with nothing to buy.
      expect(find.text(s.t('shop.premiumBadge')), findsWidgets);
      expect(find.text('160'), findsNothing);
      expect(find.text(s.t('shop.earnHint')), findsNothing);
      expect(find.byType(ShopCard), findsWidgets);
      for (final card in tester.widgetList<ShopCard>(find.byType(ShopCard))) {
        expect(card.state, anyOf(ShopCardState.owned, ShopCardState.worn));
      }

      final scrollable = tester.firstState<ScrollableState>(
        find.byType(Scrollable),
      );
      for (var i = 0; i < 14; i++) {
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pump();
      }
      expect(find.text(s.t('shop.unlockedHeading')), findsOneWidget);
      expect(find.text(s.t('shop.unlockedBody')), findsOneWidget);
      expect(find.text(s.t('shop.restore')), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the confirmation overflowed under $name at 1.6 text scale',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the buy confirmation builds at 320x568 ($name)', (
      tester,
    ) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(
        theme: theme.id,
        balance: 90,
        secrets: FakeSecretStore.withCredentials(testCredentials(1)),
      );
      env.api.profile = PlayerProfile(id: testPlayerId(1), games: 4);
      await tester.pumpWidget(wrapApp(env, const ShopScreen()));
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final card = find.byWidgetPredicate(
        (w) => w is ShopCard && w.itemId == 'ball.comet',
      );
      // A card below the fold is not built at all on a 320 pt phone.
      for (var i = 0; i < 10 && card.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -260));
        await tester.pump();
      }
      await tester.ensureVisible(card);
      await tester.pump();
      await tester.tap(card);
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(
        GameTheme.read(tester.element(find.byType(Dialog))).id,
        theme.id,
        reason: 'the confirmation is not in the $name look',
      );
      expect(find.textContaining('It costs 80 sparks'), findsOneWidget);
      // The one thing every player deserves to be told before spending: this
      // changes nothing about the game.
      expect(
        find.textContaining('no item in this shop changes how the game plays'),
        findsOneWidget,
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'the confirmation overflowed under $name',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the solo arena builds and runs at 320x568 ($name)', (
      tester,
    ) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(theme: theme.id);
      await tester.pumpWidget(wrapApp(env, const SoloScreen()));
      expect(find.byType(GameView), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Start it and let the simulation run: every theme has to survive live
      // frames, not just the static start overlay.
      await tester.tap(find.text('TAP TO START').last);
      await pumpFrames(tester, 90);
      expect(tester.takeException(), isNull);

      // The arena itself is never blurred, whatever the theme asks for.
      expect(
        find.descendant(
          of: find.byType(GameView),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
        reason: 'a BackdropFilter inside the animating arena ($name)',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the duel arena builds at 320x568 ($name)', (tester) async {
      useNarrowPhone(tester);
      final env = await createTestEnv(theme: theme.id);
      final server = FakeDuelServer();
      final controller = DuelController(
        client: DuelClient(
          wsUri: () => Uri.parse('ws://fake.local/ws'),
          connector: server.connect,
        ),
        settings: env.settings,
        audio: env.audio,
        haptics: env.haptics,
        input: FakeInput(),
      );
      await tester.pumpWidget(wrapApp(env, DuelScreen(controller: controller)));
      await pumpFrames(tester, 20);
      expect(find.byType(GameView), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GameView),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('only the glass theme blurs, and only its panels', (
    tester,
  ) async {
    useNarrowPhone(tester);

    for (final theme in GameThemes.all) {
      final env = await createTestEnv(theme: theme.id);
      await tester.pumpWidget(wrapApp(env, const SoloScreen()));
      await tester.pump(const Duration(milliseconds: 50));
      final blurs = find.byType(BackdropFilter);
      if (theme.blurPanels) {
        // The tap-to-start overlay is a panel, so the glass look blurs it.
        expect(
          blurs,
          findsWidgets,
          reason: 'the glass overlay panel should be blurred',
        );
      } else {
        expect(
          blurs,
          findsNothing,
          reason: '${theme.id.name} must not blur anything',
        );
      }
      await tester.pumpWidget(const SizedBox());
    }
  });
}
