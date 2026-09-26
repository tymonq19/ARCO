// The second half of the device check for SPEC §4.8: a fresh launch still wears
// what was bought, and the server still says so.
//
//   flutter test integration_test/shop_restart_test.dart -d <device-id> \
//       --dart-define=SERVER_URL=http://127.0.0.1:<port>
//
// Run this **after** `shop_tour_test.dart`, in its own process: that is what
// makes it a restart rather than a rebuild. It asserts two different things,
// both of which have to hold — the phone is dressed from its own cache before
// any request finishes, and the server, asked afresh, names the same item. The
// first is what makes the app work on a plane; the second is what makes a
// purchase follow the player to another phone.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:arco/game/arena_geometry.dart';
import 'package:arco/game/input/joystick_input.dart';
import 'package:arco/game/render/game_view.dart';
import 'package:arco/main.dart' as app;
import 'package:arco/app/cosmetics.dart';
import 'package:arco/app/settings.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/services/api_client.dart';
import 'package:arco/services/player_identity.dart';
import 'package:arco/services/shop_service.dart';
import 'package:arco/ui/home_screen.dart';
import 'package:arco/ui/onboarding_screen.dart';
import 'package:arco/ui/widgets/neon_button.dart';

const Duration _frame = Duration(milliseconds: 16);
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

T serviceOf<T>(WidgetTester tester) =>
    Provider.of<T>(tester.element(find.byType(MaterialApp)), listen: false);

Finder neonButton(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(NeonButton));

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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'what was bought is still worn after a restart',
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
      );
      final s = Strings.read(tester.element(find.byType(MaterialApp)));
      final shop = serviceOf<ShopService>(tester);
      final identity = serviceOf<PlayerIdentity>(tester);
      final api = serviceOf<ApiClient>(tester);

      // What the phone knew before any request was answered. `flutter test`
      // reinstalls the app, which empties its preferences — so this is sometimes
      // a restart (the cache is there) and sometimes a *new device carrying the
      // same account* (it is not). Both have to end up wearing the bought skin,
      // and which one this was is said out loud rather than assumed.
      final fromCache = shop.equipped;
      final hadCache = shop.balanceKnown;
      say(
        'at launch: equipped=$fromCache known=$hadCache '
        'balance=${shop.balance} '
        'welcome=${find.byType(OnboardingScreen).evaluate().isNotEmpty}',
      );
      if (hadCache) {
        expect(
          fromCache.ball,
          BallSkin.comet,
          reason: 'the phone forgot what it was wearing',
        );
      }

      // A wiped container opens on the welcome screen; continue through it.
      if (find.byType(OnboardingScreen).evaluate().isNotEmpty) {
        final start = find.ancestor(
          of: find.text(s.t('onboarding.start')),
          matching: find.byType(NeonButton),
        );
        await tester.ensureVisible(start.first);
        await hold(tester, const Duration(milliseconds: 300));
        await tester.tap(start.first);
        await hold(tester, const Duration(seconds: 1));
        expect(await waitFor(tester, find.byType(HomeScreen)), isTrue);
      }

      // The server is the authority, and it is why a purchase survives a lost
      // phone: asked afresh, it names the same item, and the app puts it on.
      final credentials = await identity.ensureIssued();
      expect(
        credentials,
        isNotNull,
        reason: 'the keychain lost the credential',
      );
      final inventory = await api.shopInventory(
        credentials!,
        version: ShopService.clientCatalogueVersion,
      );
      say(
        'from server: equipped=${inventory.equipped} owned=${inventory.owned} '
        'balance=${inventory.balance} playerId=${identity.playerId}',
      );
      expect(inventory.equipped['ball'], _wanted);
      expect(inventory.owned, contains(_wanted));

      await shop.refresh(force: true);
      say('after a refresh: equipped=${shop.equipped} balance=${shop.balance}');
      expect(
        shop.equipped.ball,
        BallSkin.comet,
        reason: 'the bought skin did not come back',
      );

      await hold(tester, const Duration(seconds: 3)); // home, with the wallet

      // The bought skin in play, so a screenshot can show what was paid for.
      await tester.tap(neonButton(s.t('home.solo')).first);
      await hold(tester, const Duration(milliseconds: 800));
      await tester.tap(neonButton(s.t('solo.tapToStart')).first);
      await hold(tester, const Duration(milliseconds: 400));
      await playFor(tester, const Duration(seconds: 10));
      await hold(tester, const Duration(seconds: 2));
      // Out of the arena the app's own way, and quietly: the pause panel, then
      // its MENU button. (It also lets every sound finish before the test ends,
      // which the audio plugin's frame callback insists on.)
      await tester.tap(find.byType(NeonIconButton).first);
      await hold(tester, const Duration(milliseconds: 600));
      await tester.tap(neonButton(s.t('common.home')).first);
      await hold(tester, const Duration(seconds: 2));
      expect(await waitFor(tester, find.byType(HomeScreen)), isTrue);

      // --- and now with nothing listening -----------------------------------
      //
      // The same app, pointed at a port nobody is on: what a phone in a lift
      // looks like. The game must not care, the items must stay on, and the shop
      // must say it needs a connection instead of breaking.
      final settings = serviceOf<Settings>(tester);
      settings.serverUrl = 'http://127.0.0.1:1';
      await shop.refresh(force: true);
      say(
        'offline: status=${shop.status} equipped=${shop.equipped} '
        'balance=${shop.balance} known=${shop.balanceKnown}',
      );
      expect(shop.failed, isTrue, reason: 'nothing is listening there');
      expect(
        shop.equipped.ball,
        BallSkin.comet,
        reason: 'a failed refresh must not undress anybody',
      );
      expect(shop.balanceKnown, isTrue, reason: 'the last known wallet stays');

      await tester.tap(find.text(s.t('shop.open')).first);
      await hold(tester, const Duration(seconds: 2));
      expect(
        find.textContaining(s.t('shop.offline').substring(0, 20)),
        findsWidgets,
        reason: 'the offline shop said nothing about needing a connection',
      );
      say('offline shop shows the last known catalogue and says why');
      await hold(tester, const Duration(seconds: 3)); // the offline shop

      await tester.tap(find.byType(BackButton).first);
      await hold(tester, const Duration(seconds: 1));

      // --- a fresh app shell, built from what the phone stored ---------------
      //
      // `flutter test` reinstalls the app, so the launch above could not be a
      // restart. This is the closest thing the harness allows and it asserts the
      // same thing: the whole shell is built again — a new [Storage], a new
      // [Settings], a new [ShopService] — out of what shared_preferences
      // actually holds, while the server is still a port nobody is on. Anything
      // it is wearing came off this phone.
      final storedBalance = shop.balance;
      app.main();
      expect(
        await waitFor(
          tester,
          find.byWidgetPredicate(
            (w) => w is HomeScreen || w is OnboardingScreen,
          ),
        ),
        isTrue,
      );
      final relaunched = serviceOf<ShopService>(tester);
      say(
        'relaunched with no server: equipped=${relaunched.equipped} '
        'balance=${relaunched.balance} known=${relaunched.balanceKnown}',
      );
      expect(
        relaunched.equipped.ball,
        BallSkin.comet,
        reason: 'a relaunch has to come up wearing what was bought',
      );
      expect(relaunched.balance, storedBalance);
      expect(relaunched.balanceKnown, isTrue);
      await hold(tester, const Duration(seconds: 3)); // home, from the cache

      // Put the server back where the next run expects it.
      serviceOf<Settings>(tester).serverUrl = '';
      await hold(tester, const Duration(seconds: 1));
      say('done');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
