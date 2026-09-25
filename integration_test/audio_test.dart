import 'package:arco/services/audio_service.dart';
import 'package:arco_core/arco_core.dart' show maxMultiplier;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The sound effects on a real device, which is the only place the
/// `audioplayers` plugin actually runs: the unit tests can check the clip the
/// service picks and the shipped bytes, but nothing on the host can say whether
/// 18 clips and 35 low-latency players load and fire.
///
/// It is also audible. Run it on the simulator with the volume up and listen:
/// the rally should climb a pentatonic scale over about fifteen seconds without
/// ever sounding like a machine gun, the wall should be clearly a different
/// object from the paddle, and the star and the heart should be impossible to
/// confuse.
///
/// `flutter test integration_test/audio_test.dart -d <device>`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every clip loads a real pool on the device', (tester) async {
    final audio = AudioService();
    addTearDown(audio.dispose);
    await audio.init();
    expect(audio.ready, isTrue, reason: 'the audio plugin loaded nothing');
    expect(
      audio.loadedClips,
      AudioService.clips.length,
      reason:
          'only ${audio.loadedClips} of ${AudioService.clips.length} clips '
          'loaded; check the log for "could not load"',
    );
    expect(
      audio.loadedPlayers,
      AudioService.clips
          .map(AudioService.poolSizeFor)
          .fold<int>(0, (a, b) => a + b),
    );
  });

  testWidgets('init can be called twice without doubling the players', (
    tester,
  ) async {
    final audio = AudioService();
    addTearDown(audio.dispose);
    await audio.init();
    final players = audio.loadedPlayers;
    await audio.init();
    expect(audio.loadedPlayers, players);
  });

  testWidgets('a long rally plays out, climbing every tier', (tester) async {
    final audio = AudioService();
    addTearDown(audio.dispose);
    await audio.init();

    Future<void> wait(int ms) =>
        tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

    audio.play(Sfx.click);
    await wait(500);
    // The duel countdown: three beeps and a GO.
    for (var i = 0; i <= AudioService.countdownBeeps; i++) {
      audio.play(Sfx.countdown);
      await wait(1000);
    }
    audio.play(Sfx.serve);
    await wait(400);

    // 46 paddle hits, the gap shrinking the way the ball speeds up, with walls
    // and both pickups landing in between — enough to reach the top tier.
    var gap = 300;
    for (var i = 0; i < 46; i++) {
      audio.play(Sfx.hit);
      if (i == 11) audio.play(Sfx.star);
      if (i == 27) audio.play(Sfx.heart);
      if (i % 8 == 6) audio.play(Sfx.wall);
      if (i == 19) audio.play(Sfx.hit); // two paddles in one frame
      await wait(gap);
      gap = gap > 120 ? gap - 4 : 120;
    }
    expect(audio.rallyHits, 47, reason: 'the rally lost count');

    audio.play(Sfx.lose);
    await wait(1000);
    audio.play(Sfx.gameover);
    await wait(1500);
    audio.play(Sfx.win);
    await wait(1500);

    // 1 tap + 3 beeps + the GO + the serve + 46 hits + a star + a heart +
    // 5 walls + lose + game over + win = 62. The extra hit that landed in the
    // same frame as its neighbour is not in there: it was collapsed, which is
    // the whole point of the window.
    expect(audio.dispatched, 62);
  });

  testWidgets('the rally state survives a mute in the middle of it', (
    tester,
  ) async {
    final audio = AudioService();
    addTearDown(audio.dispose);
    await audio.init();
    for (var i = 0; i < 5 * (maxMultiplier - 1); i++) {
      audio.play(Sfx.hit);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
    }
    final before = audio.dispatched;
    audio.muted = true;
    for (var i = 0; i < 10; i++) {
      audio.play(Sfx.hit);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
    }
    expect(audio.dispatched, before, reason: 'muted and still playing');
    audio.muted = false;
    audio.play(Sfx.hit);
    expect(audio.dispatched, before + 1);
    expect(
      AudioService.multiplierFor(audio.rallyHits),
      maxMultiplier,
      reason: 'the combo should have kept climbing while muted',
    );
  });
}
