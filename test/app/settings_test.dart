import 'package:arco/app/game_theme.dart';
import 'package:arco/app/settings.dart';
import 'package:arco/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simulates a fresh app launch over the same preferences store: drops the
/// cached [SharedPreferences] singleton so the next load re-reads the backing
/// store instead of the in-memory cache.
Future<Settings> relaunch() async {
  SharedPreferences.resetStatic();
  return Settings(await Storage.load());
}

void main() {
  test('generates a Player### nickname and keeps it across launches', () async {
    SharedPreferences.setMockInitialValues(const {});

    final first = Settings(await Storage.load());
    final generated = first.playerName;
    expect(generated, matches(RegExp(r'^Player\d{3}$')));
    await Future<void>.delayed(Duration.zero);

    final second = await relaunch();
    expect(second.playerName, generated);

    final third = await relaunch();
    expect(third.playerName, generated);
  });

  test('keeps an existing stored nickname untouched', () async {
    SharedPreferences.setMockInitialValues(const {'playerName': 'Neo_99'});

    final settings = Settings(await Storage.load());
    expect(settings.playerName, 'Neo_99');
    await Future<void>.delayed(Duration.zero);

    final next = await relaunch();
    expect(next.playerName, 'Neo_99');
  });

  test('an edited nickname survives a launch', () async {
    SharedPreferences.setMockInitialValues(const {});

    final settings = Settings(await Storage.load());
    settings.playerName = 'Rival';
    await Future<void>.delayed(Duration.zero);

    final next = await relaunch();
    expect(next.playerName, 'Rival');
  });

  test('a first launch is not onboarded', () async {
    SharedPreferences.setMockInitialValues(const {});

    final settings = Settings(await Storage.load());
    expect(settings.onboarded, isFalse);
  });

  test('quitting the welcome screen does not count as onboarding', () async {
    // The first launch generates a nickname and writes it through. If that
    // write were allowed to answer the flag, a player who opened the app,
    // looked at the welcome screen and killed it would never see it again.
    SharedPreferences.setMockInitialValues(const {});

    final first = Settings(await Storage.load());
    expect(first.onboarded, isFalse);
    expect(first.playerName, matches(RegExp(r'^Player\d{3}$')));
    await Future<void>.delayed(Duration.zero);

    final second = await relaunch();
    expect(
      second.onboarded,
      isFalse,
      reason: 'the generated nickname is not a choice the player made',
    );

    final third = await relaunch();
    expect(third.onboarded, isFalse);
  });

  test('a stored nickname without the flag counts as onboarded', () async {
    // What every build before the welcome screen left behind.
    SharedPreferences.setMockInitialValues(const {'playerName': 'Neo_99'});

    final settings = Settings(await Storage.load());
    expect(settings.onboarded, isTrue);
    await Future<void>.delayed(Duration.zero);

    // Written back, so the answer cannot change under a later build.
    final next = await relaunch();
    expect(next.onboarded, isTrue);
  });

  test('an explicit false is not overridden by a stored nickname', () async {
    SharedPreferences.setMockInitialValues(const {
      'playerName': 'Neo_99',
      'onboarded': false,
    });

    expect(Settings(await Storage.load()).onboarded, isFalse);
  });

  test(
    'completing onboarding persists the look, the name and the flag',
    () async {
      SharedPreferences.setMockInitialValues(const {});

      final settings = Settings(await Storage.load());
      var notifications = 0;
      settings.addListener(() => notifications++);
      settings.completeOnboarding(theme: GameThemes.glass, name: 'Neo 99');

      expect(
        notifications,
        1,
        reason: 'one rebuild of the app shell, not three',
      );
      expect(settings.themeId, ThemeId.glass);
      expect(settings.playerName, 'Neo 99');
      expect(settings.onboarded, isTrue);
      await Future<void>.delayed(Duration.zero);

      final next = await relaunch();
      expect(next.themeId, ThemeId.glass);
      expect(next.playerName, 'Neo 99');
      expect(next.onboarded, isTrue);
    },
  );
}
