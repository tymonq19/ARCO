import 'package:arco/app/settings.dart';
import 'package:arco/services/haptics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// A clock the test drives by hand, so the per-strength rate limits can be
/// exercised without waiting.
class _Clock {
  Duration now = Duration.zero;

  Duration call() => now;

  void advance(Duration d) => now += d;
  void advanceMs(int ms) => advance(Duration(milliseconds: ms));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> fired;

  setUp(() {
    fired = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            fired.add(
              (call.arguments as String?) ?? 'HapticFeedbackType.vibrate',
            );
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<({Haptics haptics, _Clock clock, Settings settings})> build({
    bool enabled = true,
  }) async {
    final env = await createTestEnv(haptics: enabled);
    final clock = _Clock();
    return (
      haptics: Haptics(env.settings, clock: clock.call),
      clock: clock,
      settings: env.settings,
    );
  }

  test('each strength reaches the platform once it is due', () async {
    final (haptics: h, clock: clock, settings: _) = await build();
    h.light();
    h.medium();
    h.heavy();
    h.selection();
    expect(fired, hasLength(4), reason: 'four distinct strengths');
    expect(fired.toSet(), hasLength(4));
    clock.advanceMs(1000);
    h.light();
    expect(fired, hasLength(5));
  });

  test('the switch gates everything', () async {
    final (haptics: h, clock: _, settings: settings) = await build(
      enabled: false,
    );
    expect(h.enabled, isFalse);
    h.light();
    h.medium();
    h.heavy();
    h.selection();
    expect(fired, isEmpty);
    settings.haptics = true;
    expect(h.enabled, isTrue);
    h.light();
    expect(fired, hasLength(1));
  });

  test('a fast rally does not turn the phone into a buzzer', () async {
    final (haptics: h, clock: clock, settings: _) = await build();
    // A paddle hit every 20 ms, far faster than the game can deliver.
    for (var ms = 0; ms < 2000; ms += 20) {
      clock.advanceMs(20);
      h.light();
    }
    expect(fired, isNotEmpty);
    expect(
      fired.length,
      lessThanOrEqualTo(2000 ~/ Haptics.lightGap.inMilliseconds + 1),
      reason: 'the light impact outran its own gap',
    );
    expect(fired.length, greaterThan(2000 ~/ 200));
  });

  test('a pickup in the middle of a rally is never swallowed', () async {
    final (haptics: h, clock: clock, settings: _) = await build();
    h.light();
    clock.advanceMs(5);
    h.light(); // suppressed
    expect(fired, hasLength(1));
    h.medium(); // a different strength: must get through
    h.heavy();
    expect(fired, hasLength(3));
  });

  test(
    'a selection click and a light impact do not suppress each other',
    () async {
      final (haptics: h, clock: _, settings: _) = await build();
      expect(Haptics.selectionGap, Haptics.lightGap);
      h.light();
      h.selection();
      expect(fired, hasLength(2));
    },
  );

  test('the gaps grow with the strength', () async {
    expect(Haptics.lightGap, lessThan(Haptics.mediumGap));
    expect(Haptics.mediumGap, lessThan(Haptics.heavyGap));
    // The heaviest one must still allow one per life lost in a fast game.
    expect(Haptics.heavyGap, lessThan(const Duration(milliseconds: 500)));
  });

  test('each strength is limited on its own clock', () async {
    final (haptics: h, clock: clock, settings: _) = await build();
    h.heavy();
    clock.advance(Haptics.lightGap);
    h.light();
    expect(fired, hasLength(2));
    h.heavy(); // still inside the heavy gap
    expect(fired, hasLength(2));
    clock.advance(Haptics.heavyGap);
    h.heavy();
    expect(fired, hasLength(3));
  });
}
