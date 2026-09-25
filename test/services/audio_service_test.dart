import 'package:arco/app/game_theme.dart';
import 'package:arco/services/audio_service.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// A clock the test drives by hand, so the collapse and countdown windows can
/// be exercised without waiting for real time.
class _Clock {
  Duration now = Duration.zero;

  Duration call() => now;

  void advance(Duration d) => now += d;
  void advanceMs(int ms) => advance(Duration(milliseconds: ms));
}

/// A service with no players loaded: `play` still resolves the clip, applies
/// mute and the collapse window and counts the dispatch, which is everything
/// that is ours. The pool itself is the `audioplayers` plugin's job and is
/// exercised on the device.
({AudioService audio, _Clock clock}) _service({bool muted = false}) {
  final clock = _Clock();
  return (audio: AudioService(muted: muted, clock: clock.call), clock: clock);
}

void main() {
  group('clips', () {
    test('one clip per event, plus the hit tiers and the GO', () {
      expect(AudioService.clips, hasLength(Sfx.values.length + maxMultiplier));
      for (final sfx in Sfx.values) {
        expect(
          AudioService.clips,
          contains(AudioService.baseClip(sfx)),
          reason: '${sfx.name} has no base clip',
        );
      }
      for (var m = 2; m <= maxMultiplier; m++) {
        expect(AudioService.clips, contains('hit$m'));
      }
      expect(AudioService.clips, contains(AudioService.goClip));
      expect(AudioService.clips.toSet(), hasLength(AudioService.clips.length));
    });

    test('the short, constant sounds load before the long jingles', () {
      final order = AudioService.clips;
      expect(order.first, 'click');
      expect(order.indexOf('hit'), lessThan(order.indexOf('gameover')));
      expect(order.indexOf('serve'), lessThan(order.indexOf('win')));
      expect(order.last, 'win');
    });

    test('one set serves every theme: no theme-suffixed variants', () {
      // The decision recorded on AudioService.clips. A future per-theme set has
      // to change this test on purpose rather than drift into existence.
      for (final clip in AudioService.clips) {
        for (final theme in ThemeId.values) {
          expect(
            clip.endsWith('_${theme.name}'),
            isFalse,
            reason: '$clip looks theme-specific',
          );
        }
      }
    });

    test('asset paths sit under assets/sfx as wav', () {
      expect(AudioService.assetPathOf('hit'), 'sfx/hit.wav');
      expect(AudioService.assetPath(Sfx.star), 'sfx/star.wav');
    });
  });

  group('combo selects the hit variant', () {
    test(
      'multiplierFor matches the core multiplier for every rally length',
      () {
        for (var hits = 0; hits <= 120; hits++) {
          expect(
            AudioService.multiplierFor(hits),
            Player(paddle: Paddle(0), combo: hits).multiplier,
            reason: 'rally of $hits hits',
          );
        }
      },
    );

    test('hitClip names the tier', () {
      expect(AudioService.hitClip(1), 'hit');
      expect(AudioService.hitClip(2), 'hit2');
      expect(AudioService.hitClip(maxMultiplier), 'hit$maxMultiplier');
    });

    test('a long rally climbs the tiers and tops out', () {
      final s = _service().audio;
      final played = <String>[for (var i = 0; i < 60; i++) s.resolve(Sfx.hit)];
      expect(played.take(4), everyElement('hit'));
      expect(played[4], 'hit2', reason: 'the 5th hit is multiplier 2');
      expect(played[9], 'hit3');
      expect(played[34], 'hit$maxMultiplier');
      expect(played.last, 'hit$maxMultiplier', reason: 'never past the top');
      expect(played.toSet(), hasLength(maxMultiplier));
      expect(s.rallyHits, 60);
    });

    test('losing a life drops the rally back to the bottom tier', () {
      final s = _service().audio;
      for (var i = 0; i < 12; i++) {
        s.resolve(Sfx.hit);
      }
      expect(s.resolve(Sfx.hit), 'hit3');
      expect(s.resolve(Sfx.lose), 'lose');
      expect(s.resolve(Sfx.hit), 'hit');
    });

    test('a serve or the end of a game also resets it', () {
      for (final reset in <Sfx>[Sfx.serve, Sfx.gameover, Sfx.win]) {
        final s = _service().audio;
        for (var i = 0; i < 8; i++) {
          s.resolve(Sfx.hit);
        }
        expect(s.resolve(reset), reset.name);
        expect(s.resolve(Sfx.hit), 'hit', reason: '${reset.name} must reset');
      }
    });

    test('walls, pickups and taps do not break the rally', () {
      final s = _service().audio;
      for (var i = 0; i < 9; i++) {
        s.resolve(Sfx.hit);
      }
      for (final noise in <Sfx>[Sfx.wall, Sfx.star, Sfx.heart, Sfx.click]) {
        expect(s.resolve(noise), noise.name);
      }
      expect(s.resolve(Sfx.hit), 'hit3', reason: 'the combo survived');
    });

    test('the rally is counted while muted, so unmuting lands in tune', () {
      final s = _service(muted: true).audio;
      for (var i = 0; i < 10; i++) {
        s.play(Sfx.hit);
      }
      expect(s.dispatched, 0);
      s.muted = false;
      s.play(Sfx.hit);
      expect(s.dispatched, 1);
      expect(s.rallyHits, 11);
    });
  });

  group('countdown', () {
    test('one beep per second, then the GO', () {
      final (audio: s, clock: clock) = _service();
      final heard = <String>[];
      for (var i = 0; i < AudioService.countdownBeeps + 1; i++) {
        heard.add(s.resolve(Sfx.countdown));
        clock.advanceMs(1000);
      }
      expect(heard, <String>[
        ...List<String>.filled(AudioService.countdownBeeps, 'countdown'),
        AudioService.goClip,
      ]);
    });

    test('the beep count follows the core countdown length', () {
      expect(AudioService.countdownBeeps, countdownTicks ~/ tickRate);
      expect(AudioService.countdownBeeps, 3);
    });

    test('a rematch after the gap starts a new sequence, not a fifth beep', () {
      final (audio: s, clock: clock) = _service();
      for (var i = 0; i <= AudioService.countdownBeeps; i++) {
        s.resolve(Sfx.countdown);
        clock.advanceMs(1000);
      }
      clock.advance(AudioService.countdownGap);
      expect(s.resolve(Sfx.countdown), 'countdown');
    });

    test('a countdown resets the rally', () {
      final s = _service().audio;
      for (var i = 0; i < 7; i++) {
        s.resolve(Sfx.hit);
      }
      s.resolve(Sfx.countdown);
      expect(s.resolve(Sfx.hit), 'hit');
    });
  });

  group('mute', () {
    test('nothing is dispatched while muted', () {
      final s = _service(muted: true).audio;
      for (final sfx in Sfx.values) {
        s.play(sfx);
      }
      expect(s.dispatched, 0);
    });

    test('unmuting starts playing again', () {
      final s = _service(muted: true).audio;
      s.play(Sfx.click);
      expect(s.dispatched, 0);
      s.muted = false;
      s.play(Sfx.star);
      expect(s.dispatched, 1);
    });

    test('nothing is dispatched after dispose', () async {
      final s = _service().audio;
      await s.dispose();
      s.play(Sfx.click);
      expect(s.dispatched, 0);
    });
  });

  group('collapsing repeats', () {
    test('a second copy inside the window is dropped', () {
      final (audio: s, clock: clock) = _service();
      s.play(Sfx.wall);
      clock.advanceMs(10);
      s.play(Sfx.wall);
      expect(s.dispatched, 1, reason: 'two walls 10 ms apart are one event');
      clock.advance(AudioService.collapseWindow('wall'));
      s.play(Sfx.wall);
      expect(s.dispatched, 2);
    });

    test('a frame carrying a hit, a wall and a pickup plays all three', () {
      final s = _service().audio;
      s.play(Sfx.hit);
      s.play(Sfx.wall);
      s.play(Sfx.star);
      expect(s.dispatched, 3, reason: 'different clips never collapse');
    });

    test('two paddle hits in one frame are one hit', () {
      final (audio: s, clock: clock) = _service();
      s.play(Sfx.hit);
      clock.advanceMs(8); // half a frame at 60 Hz
      s.play(Sfx.hit);
      expect(s.dispatched, 1);
    });

    test('a hit that crosses a tier is not collapsed by the previous tier', () {
      final (audio: s, clock: clock) = _service();
      for (var i = 0; i < 4; i++) {
        s.play(Sfx.hit);
        clock.advanceMs(120);
      }
      final before = s.dispatched;
      s.play(Sfx.hit); // multiplier 2: a different clip
      expect(s.dispatched, before + 1);
    });

    test('a 30-second rally never machine-guns', () {
      final (audio: s, clock: clock) = _service();
      // The ball crosses the arena in at least ~115 ms; drive it faster than
      // the game ever can and count what gets through.
      var events = 0;
      for (var ms = 0; ms < 30000; ms += 20) {
        clock.advanceMs(20);
        s.play(Sfx.hit);
        events++;
      }
      expect(events, greaterThan(1000));
      // At 20 ms per event the 28 ms window has to drop roughly every other one.
      expect(s.dispatched, lessThan(events * 0.75));
      expect(s.dispatched, greaterThan(events * 0.4));
    });

    test(
      'every clip has a collapse window shorter than its own repeat rate',
      () {
        for (final clip in AudioService.clips) {
          final w = AudioService.collapseWindow(clip);
          expect(w, greaterThan(Duration.zero), reason: clip);
          expect(
            w,
            lessThan(const Duration(milliseconds: 400)),
            reason: '$clip would swallow real events',
          );
        }
        // A paddle hit can be 115 ms apart at the fastest ball speed.
        expect(
          AudioService.collapseWindow('hit'),
          lessThan(const Duration(milliseconds: 115)),
        );
        // Countdown beeps are a second apart.
        expect(
          AudioService.collapseWindow('countdown'),
          lessThan(const Duration(milliseconds: 1000)),
        );
      },
    );

    test('a burst of the same sound varies in level instead of stacking', () {
      final (audio: s, clock: clock) = _service();
      final full = AudioService.levelOf('wall');
      final levels = <double>[];
      for (var i = 0; i < 8; i++) {
        final l = s.levelFor('wall', 1.0);
        if (l != null) levels.add(l);
        clock.advance(AudioService.collapseWindow('wall'));
      }
      expect(levels, hasLength(8), reason: '45 ms apart, none collapsed');
      expect(levels.first, full);
      expect(levels, everyElement(lessThanOrEqualTo(full)));
      expect(
        levels.where((l) => l < full).length,
        greaterThanOrEqualTo(levels.length * 3 ~/ 4),
        reason: 'most of a burst has to duck',
      );
      for (var i = 1; i < levels.length; i++) {
        expect(
          levels[i],
          isNot(levels[i - 1]),
          reason: 'two repeats in a row at the same level, at $i',
        );
      }
      // The trim cycles rather than decaying away, so a long burst never fades
      // to nothing.
      expect(levels.sublist(4), levels.sublist(0, 4));
    });

    test('the trim is forgotten once the burst is over', () {
      final (audio: s, clock: clock) = _service();
      s.levelFor('wall', 1.0);
      clock.advanceMs(60);
      expect(s.levelFor('wall', 1.0), lessThan(AudioService.levelOf('wall')));
      clock.advance(AudioService.repeatWindow);
      expect(s.levelFor('wall', 1.0), AudioService.levelOf('wall'));
    });

    test('the caller volume scales the clip level', () {
      final s = _service().audio;
      expect(
        s.levelFor('star', 0.5),
        closeTo(AudioService.levelOf('star') * 0.5, 1e-9),
      );
    });
  });

  group('pools', () {
    test('every clip gets at least one player', () {
      for (final clip in AudioService.clips) {
        expect(
          AudioService.poolSizeFor(clip),
          greaterThanOrEqualTo(1),
          reason: clip,
        );
      }
    });

    test('the sounds that can overlap get more than one', () {
      for (final clip in <String>[
        'hit',
        'hit$maxMultiplier',
        'wall',
        'click',
      ]) {
        expect(
          AudioService.poolSizeFor(clip),
          greaterThanOrEqualTo(2),
          reason: clip,
        );
      }
    });

    // Whether a pool is deep enough for the real clip length is measured
    // against the assets in sfx_assets_test.dart.

    test('the long one-shots need only one player', () {
      for (final clip in <String>['gameover', 'win', AudioService.goClip]) {
        expect(AudioService.poolSizeFor(clip), 1, reason: clip);
      }
    });

    test('playersPerSfx caps the pool', () {
      final s = AudioService(playersPerSfx: 1);
      expect(s.playersPerSfx, 1);
      expect(AudioService.poolSizeFor('wall'), greaterThan(s.playersPerSfx));
    });
  });

  group('levels', () {
    test('every clip has a level inside unity', () {
      for (final clip in AudioService.clips) {
        final l = AudioService.levelOf(clip);
        expect(l, greaterThan(0.0), reason: clip);
        expect(l, lessThanOrEqualTo(1.0), reason: clip);
      }
    });

    test('the level is the balance under the bus headroom', () {
      expect(AudioService.headroom, lessThan(1.0));
      for (final clip in AudioService.clips) {
        expect(
          AudioService.levelOf(clip),
          closeTo(AudioService.headroom * AudioService.balanceOf(clip), 1e-12),
          reason: clip,
        );
      }
    });

    test('the constant sounds sit under the events they accompany', () {
      expect(
        AudioService.levelOf('click'),
        lessThan(AudioService.levelOf('hit')),
      );
      expect(
        AudioService.levelOf('serve'),
        lessThan(AudioService.levelOf('hit')),
      );
      expect(
        AudioService.levelOf('click'),
        lessThan(AudioService.levelOf('serve')),
      );
    });

    test('the end of a game is the loudest thing in the app', () {
      for (final clip in <String>['gameover', 'win', 'lose']) {
        expect(
          AudioService.levelOf(clip),
          greaterThan(AudioService.levelOf('hit')),
          reason: clip,
        );
      }
    });

    test('every hit tier plays at one level, so only pitch climbs', () {
      final levels = <double>{
        for (var m = 1; m <= maxMultiplier; m++)
          AudioService.levelOf(AudioService.hitClip(m)),
      };
      expect(levels, hasLength(1));
    });

    test('gain is the level of the event base clip', () {
      for (final sfx in Sfx.values) {
        expect(
          AudioService.gain(sfx),
          AudioService.levelOf(AudioService.baseClip(sfx)),
          reason: sfx.name,
        );
      }
    });
  });

  group('loading', () {
    // A real `init` cannot run here: `audioplayers` waits on a platform event
    // channel that flutter_test has nothing to answer with, which is exactly
    // why `init` is fire-and-forget and every call site tolerates an unloaded
    // service. Loading is verified on the simulator instead.
    test('a service that was never loaded still plays safely', () {
      final s = _service().audio;
      expect(s.ready, isFalse);
      for (final sfx in Sfx.values) {
        s.play(sfx);
      }
      expect(s.dispatched, Sfx.values.length);
    });

    test('init after dispose touches no plugin', () async {
      final s = _service().audio;
      await s.dispose();
      await s.init();
      expect(s.ready, isFalse);
    });

    test('dispose twice is harmless', () async {
      final s = _service().audio;
      await s.dispose();
      await s.dispose();
      expect(s.ready, isFalse);
    });
  });
}
