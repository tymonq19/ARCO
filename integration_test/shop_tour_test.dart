// The cosmetic shop on a real device, against a real server (SPEC §4.8).
//
//   flutter test integration_test/shop_tour_test.dart -d <device-id> \
//       --dart-define=SERVER_URL=http://127.0.0.1:<port>
//
// What only a device and a live server can show: that a hand-played run earns
// the sparks the server recorded for it, that the number on the game-over panel
// is that same number, that a purchase debits the wallet once and puts the item
// on, and that all of it is stored server side rather than on the phone.
//
// It holds on each interesting screen for [_screenHold] so an external
// screenshot loop (`xcrun simctl io <udid> screenshot …`) catches it, and it
// prints every figure it reads with an `ARCO-SHOP:` prefix so the run can be
// checked against the server's own database afterwards.
//
// The one thing it does not do by hand is grind: a hand-played run pays a few
// sparks and the cheapest item costs 80, so the wallet is topped up with
// **genuinely verified** runs — replays recorded here by a tracking bot and
// submitted through the app's own client, re-simulated and scored by the server
// exactly like any other. Nothing is granted; every spark is earned.
import 'dart:math' as math;

import 'package:arco_core/arco_core.dart' hide Simulation;
import 'package:arco_core/arco_core.dart' as core show Simulation;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:arco/app/settings.dart';
import 'package:arco/game/arena_geometry.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/game/input/joystick_input.dart';
import 'package:arco/game/render/game_view.dart';
import 'package:arco/main.dart' as app;
import 'package:arco/services/api_client.dart';
import 'package:arco/services/player_identity.dart';
import 'package:arco/services/shop_service.dart';
import 'package:arco/ui/home_screen.dart';
import 'package:arco/ui/onboarding_screen.dart';
import 'package:arco/ui/shop_screen.dart';
import 'package:arco/ui/widgets/neon_button.dart';
import 'package:arco/ui/widgets/shop_card.dart';

const Duration _frame = Duration(milliseconds: 16);
const Duration _screenHold = Duration(seconds: 4);
const Duration _transition = Duration(milliseconds: 700);

/// The item this run buys: the cheapest ball, so one evening of play could pay
/// for it.
const String _wanted = 'ball.comet';

void say(Object? message) {
  // ignore: avoid_print
  print('ARCO-SHOP: $message');
}

Future<void> hold(WidgetTester tester, Duration duration) async {
  final clock = tester.binding.clock;
  final end = clock.now().add(duration);
  final maxFrames = duration.inMilliseconds ~/ _frame.inMilliseconds + 240;
  var frames = 0;
  while (frames < maxFrames && clock.now().isBefore(end)) {
    await tester.pump(_frame);
    frames++;
  }
}

Future<bool> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final clock = tester.binding.clock;
  final end = clock.now().add(timeout);
  final maxFrames = timeout.inMilliseconds ~/ _frame.inMilliseconds + 240;
  var frames = 0;
  while (frames < maxFrames && clock.now().isBefore(end)) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.pump(_frame);
    frames++;
  }
  return finder.evaluate().isNotEmpty;
}

/// Pumps until [ready] answers true, or [timeout] passes.
Future<bool> waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final clock = tester.binding.clock;
  final end = clock.now().add(timeout);
  final maxFrames = timeout.inMilliseconds ~/ _frame.inMilliseconds + 400;
  var frames = 0;
  while (frames < maxFrames && clock.now().isBefore(end)) {
    if (ready()) return true;
    await tester.pump(_frame);
    frames++;
  }
  return ready();
}

Strings stringsOf(WidgetTester tester) =>
    Strings.read(tester.element(find.byType(MaterialApp)));

T serviceOf<T>(WidgetTester tester) =>
    Provider.of<T>(tester.element(find.byType(MaterialApp)), listen: false);

Finder neonButton(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(NeonButton));

Future<void> tapAndWait(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  Duration settle = _transition,
}) async {
  expect(finder, findsWidgets, reason: reason);
  await tester.tap(finder.first);
  await hold(tester, settle);
}

/// Plays the arena for [duration] with the app's own floating joystick, aiming
/// the paddle at the ball each frame.
Future<void> playFor(WidgetTester tester, Duration duration) async {
  final view = find.byType(GameView);
  final rect = tester.getRect(view);
  final anchor = Offset(rect.center.dx, rect.bottom - rect.height * 0.18);
  final gesture = await tester.startGesture(anchor);
  final clock = tester.binding.clock;
  final end = clock.now().add(duration);
  final maxFrames = duration.inMilliseconds ~/ _frame.inMilliseconds + 600;
  var frames = 0;
  try {
    while (frames < maxFrames && clock.now().isBefore(end)) {
      final state = tester.widget<GameView>(view).stateOf();
      var deflection = 0.0;
      // The first ball: a game can have two (SPEC 2.3), and a bot that has to
      // pick one picks the one the simulation resolves first.
      final ball = state?.balls.first;
      if (ball != null && ball.active && state!.players.isNotEmpty) {
        final error = angleDelta(
          math.atan2(ball.y, ball.x),
          state.players.first.paddle.angle,
        );
        deflection = (error / 0.25).clamp(-1.0, 1.0) * JoystickInput.maxOffset;
      }
      await gesture.moveTo(anchor + Offset(deflection, 0));
      await tester.pump(_frame);
      frames++;
    }
  } finally {
    await gesture.up();
    await tester.pump(_frame);
  }
}

/// The `+N` chip on the game-over panel, or null when there is none.
int? earnedOnScreen(WidgetTester tester) {
  final pattern = RegExp(r'^\+(\d+)$');
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final match = pattern.firstMatch(text.data ?? '');
    if (match != null) return int.parse(match.group(1)!);
  }
  return null;
}

/// A verified solo run, recorded here: the paddle tracks the ball until the
/// score passes [targetScore], then stops, so the game really ends.
///
/// This is the same recording the game does (`SoloController._stepOnce`): the
/// input is logged at the tick it is handed to the simulation, so the server
/// re-simulating it gets the same game back.
Replay botRun({required int seed, int targetScore = 5200}) {
  final state = GameState.initial(
    GameConfig(mode: GameMode.solo, seed: seed & 0xFFFFFFFF),
  );
  final log = InputLog();
  final inputs = <PlayerInput>[PlayerInput.none];
  while (state.phase != Phase.gameOver && state.tick < 40000) {
    final player = state.players.first;
    final ball = state.balls.first;
    final chase = player.score < targetScore && ball.active;
    final input = chase
        ? PlayerInput.aimAngle(math.atan2(ball.y, ball.x))
        : PlayerInput.none;
    log.record(state.tick, input);
    inputs[0] = input;
    core.Simulation.step(state, inputs);
  }
  return Replay(
    config: state.config,
    inputs: <InputLog>[log],
    finalTick: state.tick,
    claimedScore: state.players.first.score,
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'shop: a played run earns sparks, and the sparks buy a skin',
    (tester) async {
      app.main();
      expect(
        await waitFor(
          tester,
          find.byWidgetPredicate(
            (w) => w is HomeScreen || w is OnboardingScreen,
          ),
        ),
        isTrue,
        reason: 'the app did not reach its first screen',
      );
      final s = stringsOf(tester);

      // --- Welcome, if this is a clean install -------------------------------
      if (find.byType(OnboardingScreen).evaluate().isNotEmpty) {
        await hold(tester, _screenHold); // the locked looks
        final start = neonButton(s.t('onboarding.start'));
        await tester.ensureVisible(start.first);
        await tapAndWait(tester, start, reason: 'no start button');
        expect(await waitFor(tester, find.byType(HomeScreen)), isTrue);
      }
      await hold(tester, _screenHold); // home, wallet unknown

      final shop = serviceOf<ShopService>(tester);
      final api = serviceOf<ApiClient>(tester);
      final identity = serviceOf<PlayerIdentity>(tester);
      say('server=${api.baseUrl}');

      // --- A real game, played to game over ---------------------------------
      await tapAndWait(
        tester,
        neonButton(s.t('home.solo')),
        reason: 'no SOLO button',
      );
      await tapAndWait(
        tester,
        neonButton(s.t('solo.tapToStart')),
        reason: 'no start overlay button',
        settle: const Duration(milliseconds: 300),
      );
      // Play until the three lives are gone: the run has to *end* to be
      // submitted, so this plays well and then stops steering.
      await playFor(tester, const Duration(seconds: 22));
      // The panel says NEW BEST on a first run and GAME OVER afterwards; both
      // are the same moment.
      final over = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data == s.t('solo.gameOver') || w.data == s.t('solo.newBest')),
      );
      expect(
        await waitFor(tester, over, timeout: const Duration(seconds: 45)),
        isTrue,
        reason: 'the game never ended',
      );
      final played = tester
          .widget<GameView>(find.byType(GameView))
          .stateOf()
          ?.players
          .first
          .score;
      // The submission is a round trip; the reward appears when it lands.
      final paid = await waitUntil(
        tester,
        () => earnedOnScreen(tester) != null,
        timeout: const Duration(seconds: 25),
      );
      await hold(tester, _screenHold); // game over, with the reward beside it

      final onScreen = earnedOnScreen(tester);
      say(
        'played run: score=$played earnedOnScreen=$onScreen paid=$paid '
        'balance=${shop.balance} '
        'earnedToday=${shop.snapshot.earnedToday}/${shop.snapshot.dailyCap}',
      );
      if (!paid) {
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          if ((text.data ?? '').isNotEmpty) say('on screen: ${text.data}');
        }
      }
      final playerId = identity.playerId;
      say('playerId=$playerId');
      expect(playerId, isNotNull, reason: 'the run went up anonymously');
      expect(
        onScreen,
        isNotNull,
        reason: 'a verified run must show what it earned',
      );
      expect(onScreen, greaterThan(0));
      expect(
        shop.balance,
        greaterThanOrEqualTo(onScreen!),
        reason: 'the wallet the server reported must include this run',
      );

      // --- Enough sparks for the cheapest item, from verified runs -----------
      final credentials = await identity.ensureIssued();
      expect(credentials, isNotNull);
      var funded = shop.balance;
      for (var seed = 1; seed < 8 && funded < 140; seed++) {
        final replay = botRun(seed: 20260924 + seed);
        final result = await api.submitScore(
          'Tester',
          replay,
          credentials: credentials,
        );
        say(
          'bot run seed=${replay.config.seed} claimed=${replay.claimedScore} '
          'ticks=${replay.finalTick} accepted=${result.ok} '
          'serverScore=${result.score} tokens=${result.tokens} '
          'balance=${result.tokenBalance}',
        );
        expect(result.ok, isTrue, reason: 'the server refused a real replay');
        funded = result.tokenBalance ?? funded;
      }
      await shop.refresh(force: true);
      say('wallet before buying: ${shop.balance}');
      expect(shop.balance, greaterThanOrEqualTo(80));

      // --- The shop ---------------------------------------------------------
      await tapAndWait(
        tester,
        find.byType(BackButton).evaluate().isNotEmpty
            ? find.byType(BackButton)
            : neonButton(s.t('common.home')),
        reason: 'could not leave the arena',
      );
      expect(await waitFor(tester, find.byType(HomeScreen)), isTrue);
      await hold(tester, _screenHold); // home, wallet visible

      await tapAndWait(
        tester,
        find.text(s.t('shop.open')),
        reason: 'no way into the shop from the title screen',
      );
      expect(await waitFor(tester, find.byType(ShopScreen)), isTrue);
      await hold(tester, _screenHold); // the shop

      final card = find.byWidgetPredicate(
        (w) => w is ShopCard && w.itemId == _wanted,
      );
      for (var i = 0; i < 10 && card.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -260));
        await hold(tester, const Duration(milliseconds: 200));
      }
      await tester.ensureVisible(card.first);
      await hold(tester, const Duration(milliseconds: 400));
      final before = shop.balance;
      final price = shop.snapshot.item(_wanted)!.priceTokens;
      say('buying $_wanted at $price with $before');

      await tapAndWait(tester, card, reason: 'no card for $_wanted');
      expect(
        find.text(s.f('shop.buyTitle', {'item': s.item(_wanted)})),
        findsOneWidget,
        reason: 'buying did not ask first',
      );
      await hold(tester, _screenHold); // the confirmation

      await tapAndWait(
        tester,
        neonButton(s.t('shop.buy')),
        reason: 'no buy button',
        settle: const Duration(seconds: 2),
      );
      await hold(tester, _screenHold); // the receipt, and the item worn

      say(
        'after buying: balance=${shop.balance} owned=${shop.snapshot.owns(_wanted)} '
        'equipped=${shop.snapshot.equipped}',
      );
      expect(shop.snapshot.owns(_wanted), isTrue);
      expect(shop.balance, before - price, reason: 'charged exactly the price');
      expect(shop.equipped.ball.id, _wanted, reason: 'it was not put on');

      // And the server agrees, which is the only place it counts.
      final inventory = await api.shopInventory(
        credentials!,
        version: ShopService.clientCatalogueVersion,
      );
      say(
        'server inventory: balance=${inventory.balance} '
        'owned=${inventory.owned} equipped=${inventory.equipped} '
        'earnedToday=${inventory.earnedToday}/${inventory.dailyCap}',
      );
      expect(inventory.owned, contains(_wanted));
      expect(inventory.equipped['ball'], _wanted);
      expect(inventory.balance, shop.balance);

      // --- The bought skin, in play -----------------------------------------
      await tapAndWait(
        tester,
        find.byType(BackButton),
        reason: 'no way back from the shop',
      );
      expect(await waitFor(tester, find.byType(HomeScreen)), isTrue);
      await tapAndWait(
        tester,
        neonButton(s.t('home.solo')),
        reason: 'no SOLO button',
      );
      await tapAndWait(
        tester,
        neonButton(s.t('solo.tapToStart')),
        reason: 'no start overlay button',
        settle: const Duration(milliseconds: 300),
      );
      await playFor(tester, const Duration(seconds: 8));
      await hold(tester, const Duration(seconds: 2)); // the comet, mid-rally
      say('theme=${serviceOf<Settings>(tester).themeId.name}');
      say('done');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
