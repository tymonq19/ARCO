import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:arco/services/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/gen_sfx.dart';
// The same library again, prefixed, so its `main` can be called from a test
// that has a `main` of its own.
import '../../tool/gen_sfx.dart' as gen;

/// `tool/gen_sfx.dart` is the source of the assets, so the assets in the repo
/// have to be exactly what it writes today. If the staleness test fails, run
/// `dart run tool/gen_sfx.dart` and listen to the result.
void main() {
  group('the file set', () {
    test('is the ten effects, the eight hit tiers and the GO', () {
      expect(effects.keys, <String>[
        'hit',
        'hit2',
        'hit3',
        'hit4',
        'hit5',
        'hit6',
        'hit7',
        'hit8',
        'wall',
        'star',
        'heart',
        'lose',
        'serve',
        'gameover',
        'win',
        'click',
        'countdown',
        'countdown_go',
      ]);
      expect(effects, hasLength(18));
    });

    test('covers every event the service can play', () {
      for (final sfx in Sfx.values) {
        expect(effects.keys, contains(sfx.name), reason: sfx.name);
      }
      expect(effects.keys, contains(AudioService.goClip));
    });

    test('renders at 44.1 kHz, which is what the assets are', () {
      expect(sampleRate, 44100);
    });
  });

  group('determinism', () {
    test('two renders of the same effect are byte-identical', () {
      for (final name in <String>['hit', 'click', 'star', 'win']) {
        expect(
          effects[name]!().toWav(),
          effects[name]!().toWav(),
          reason: '$name is not reproducible',
        );
      }
    });

    test('the seeded noise is what makes it reproducible', () {
      final a = Rng(7);
      final b = Rng(7);
      final c = Rng(8);
      final first = List<double>.generate(64, (_) => a.next());
      expect(first, List<double>.generate(64, (_) => b.next()));
      expect(first, isNot(List<double>.generate(64, (_) => c.next())));
      expect(first.toSet(), hasLength(64), reason: 'a constant, not noise');
      final r = Rng(1);
      for (var i = 0; i < 2000; i++) {
        final v = r.next();
        expect(v, greaterThanOrEqualTo(-1.0));
        expect(v, lessThan(1.0));
      }
    });

    test('running the tool writes the whole set', () {
      final out = Directory.systemTemp.createTempSync('arco_sfx');
      addTearDown(() => out.deleteSync(recursive: true));
      gen.main(<String>[out.path]);
      final written = out
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet();
      expect(written, effects.keys.map((k) => '$k.wav').toSet());
      for (final f in out.listSync().whereType<File>()) {
        expect(f.lengthSync(), greaterThan(44), reason: f.path);
      }
    });

    test('a second run over the same directory changes nothing', () {
      final out = Directory.systemTemp.createTempSync('arco_sfx');
      addTearDown(() => out.deleteSync(recursive: true));
      gen.main(<String>[out.path]);
      final first = <String, List<int>>{
        for (final f in out.listSync().whereType<File>())
          f.uri.pathSegments.last: f.readAsBytesSync(),
      };
      gen.main(<String>[out.path]);
      for (final f in out.listSync().whereType<File>()) {
        expect(
          f.readAsBytesSync(),
          first[f.uri.pathSegments.last],
          reason: f.path,
        );
      }
    });
  });

  test('the checked-in assets are exactly what the generator writes', () {
    final stale = <String>[];
    final recorded = recordedIn(Directory('assets/sfx'));
    effects.forEach((name, build) {
      final file = File('assets/sfx/$name.wav');
      expect(file.existsSync(), isTrue, reason: '${file.path} is missing');
      // A recording is not the generator's output and is not expected to match;
      // sfx_assets_test.dart measures it like any other file.
      if (recorded.contains(name)) return;
      final fresh = build().toWav();
      final onDisk = file.readAsBytesSync();
      if (onDisk.length != fresh.length) {
        stale.add('$name (${onDisk.length} vs ${fresh.length} bytes)');
        return;
      }
      for (var i = 0; i < fresh.length; i++) {
        if (onDisk[i] != fresh[i]) {
          stale.add('$name (byte $i)');
          return;
        }
      }
    });
    expect(
      stale,
      isEmpty,
      reason: 'stale assets: run `dart run tool/gen_sfx.dart`',
    );
  });

  group('recorded drop-ins', () {
    test('no manifest means every effect is synthesised', () {
      final out = Directory.systemTemp.createTempSync('arco_sfx');
      addTearDown(() => out.deleteSync(recursive: true));
      expect(recordedIn(out), isEmpty);
    });

    test('a manifest holds a file back instead of overwriting it', () {
      final out = Directory.systemTemp.createTempSync('arco_sfx');
      addTearDown(() => out.deleteSync(recursive: true));
      gen.main(<String>[out.path]);
      final mine = <int>[...File('${out.path}/click.wav').readAsBytesSync()];
      // Stand in for a bought recording: any bytes that are not ours.
      final recording = Uint8List.fromList(<int>[...mine, 0, 0, 0, 0]);
      File('${out.path}/click.wav').writeAsBytesSync(recording);
      File(
        '${out.path}/$recordedManifest',
      ).writeAsStringSync('# bought from a library\nclick.wav\n');
      expect(recordedIn(out), <String>{'click'});
      gen.main(<String>[out.path]);
      expect(
        File('${out.path}/click.wav').readAsBytesSync(),
        recording,
        reason: 'the recording was overwritten',
      );
      expect(
        File('${out.path}/hit.wav').readAsBytesSync(),
        isNot(recording),
        reason: 'everything else is still generated',
      );
    });

    test('the manifest tolerates comments, blanks and bare names', () {
      final out = Directory.systemTemp.createTempSync('arco_sfx');
      addTearDown(() => out.deleteSync(recursive: true));
      File('${out.path}/$recordedManifest').writeAsStringSync(
        '\n# a comment\nclick\n  win.wav  \nstar # trailing note\n\n',
      );
      expect(recordedIn(out), <String>{'click', 'win', 'star'});
    });
  });

  group('mastering', () {
    late Map<String, Buffer> rendered;

    setUpAll(() {
      rendered = <String, Buffer>{
        for (final e in effects.entries) e.key: e.value(),
      };
    });

    test('every effect lands within 0.6 dB of the target loudness', () {
      rendered.forEach((name, b) {
        expect(
          b.loudness(),
          closeTo(targetLoudness, 0.6),
          reason: '$name at ${b.loudness().toStringAsFixed(2)} LUFS',
        );
      });
    });

    test('every effect stays under the peak ceiling and is not silent', () {
      rendered.forEach((name, b) {
        expect(b.peak, lessThanOrEqualTo(peakCeiling), reason: name);
        expect(b.peak, greaterThan(0.3), reason: '$name is too quiet');
      });
    });

    test('every effect is faded at both ends, so nothing can click', () {
      rendered.forEach((name, b) {
        for (final ch in <Float64List>[b.left, if (b.channels == 2) b.right]) {
          expect(ch.first.abs(), lessThan(0.001), reason: '$name starts hot');
          expect(ch.last.abs(), lessThan(0.001), reason: '$name ends hot');
        }
      });
    });

    test('the WAV header describes the data that follows it', () {
      rendered.forEach((name, b) {
        final bytes = b.toWav();
        final v = ByteData.view(
          bytes.buffer,
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
        expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF', reason: name);
        expect(
          String.fromCharCodes(bytes.sublist(8, 12)),
          'WAVE',
          reason: name,
        );
        expect(v.getUint32(4, Endian.little) + 8, bytes.length, reason: name);
        expect(v.getUint16(20, Endian.little), 1, reason: '$name is not PCM');
        expect(v.getUint16(22, Endian.little), b.channels, reason: name);
        expect(v.getUint32(24, Endian.little), sampleRate, reason: name);
        expect(v.getUint16(34, Endian.little), 16, reason: name);
        expect(
          v.getUint32(40, Endian.little),
          b.frames * b.channels * 2,
          reason: name,
        );
        expect(bytes.length, 44 + b.frames * b.channels * 2, reason: name);
      });
    });

    test('the impacts are mono and the long moments are stereo', () {
      for (final name in <String>[
        'hit',
        'hit8',
        'wall',
        'serve',
        'click',
        'countdown',
        'countdown_go',
      ]) {
        expect(rendered[name]!.channels, 1, reason: name);
      }
      for (final name in <String>['star', 'heart', 'lose', 'gameover', 'win']) {
        expect(rendered[name]!.channels, 2, reason: name);
      }
    });
  });

  group('the hit ladder', () {
    test('there is one tier per score multiplier', () {
      expect(hitTiers, 8);
      for (var t = 1; t <= hitTiers; t++) {
        expect(effects.keys, contains(AudioService.hitClip(t)));
      }
    });

    test('each tier is shorter than the one below it', () {
      var previous = double.infinity;
      for (var t = 1; t <= hitTiers; t++) {
        final s = hit(t).seconds;
        expect(s, lessThan(previous), reason: 'tier $t');
        expect(s * 1000, lessThan(115), reason: 'tier $t would overlap itself');
        previous = s;
      }
    });

    test('a tier above the top clamps instead of throwing', () {
      expect(hit(hitTiers + 4).seconds, closeTo(hit(hitTiers).seconds, 1e-9));
    });
  });

  group('the building blocks', () {
    test('an envelope is silent outside its own duration', () {
      const e = Env(attack: 0.01, decay: 0.1, release: 0.02);
      expect(e.at(-0.001, 0.2), 0);
      expect(e.at(0.2, 0.2), 0);
      expect(e.at(0, 0.2), 0);
      expect(e.at(0.01, 0.2), closeTo(1.0, 1e-9), reason: 'peak at the attack');
      expect(e.at(0.05, 0.2), lessThan(1.0));
      expect(e.at(0.199, 0.2), lessThan(0.01), reason: 'the release closes it');
    });

    test('scaling a decay leaves the rest of the envelope alone', () {
      const e = Env(attack: 0.01, decay: 0.1, sustain: 0.2, release: 0.02);
      final s = e.scaleDecay(0.5);
      expect(s.attack, e.attack);
      expect(s.sustain, e.sustain);
      expect(s.release, e.release);
      expect(s.decay, closeTo(0.05, 1e-12));
      expect(s.at(0.03, 0.2), lessThan(e.at(0.03, 0.2)), reason: 'dies sooner');
    });

    test('the filters pass the band they are tuned to and stop the rest', () {
      double through(FilterKind kind, double cutoff, double tone) {
        final f = Biquad()..tune(kind, cutoff, 0.707);
        var peak = 0.0;
        for (var i = 0; i < 4410; i++) {
          final y = f.process(math.sin(2 * math.pi * tone * i / sampleRate));
          if (i > 2205 && y.abs() > peak) peak = y.abs();
        }
        return peak;
      }

      expect(through(FilterKind.lowpass, 1000, 200), greaterThan(0.8));
      expect(through(FilterKind.lowpass, 1000, 8000), lessThan(0.1));
      expect(through(FilterKind.highpass, 1000, 200), lessThan(0.15));
      expect(through(FilterKind.highpass, 1000, 8000), greaterThan(0.8));
      expect(through(FilterKind.bandpass, 1000, 1000), greaterThan(0.8));
      expect(through(FilterKind.bandpass, 1000, 60), lessThan(0.15));
    });

    test('semitone arithmetic is an octave at twelve steps', () {
      expect(semitone(440, 12), closeTo(880, 1e-9));
      expect(semitone(440, 0), 440);
      expect(semitone(440, -12), closeTo(220, 1e-9));
    });

    test('a partial above Nyquist is dropped, not folded back down', () {
      final b = Buffer(0.05);
      b.addVoice(
        freq: 18000,
        duration: 0.05,
        partials: const <Partial>[Partial(4, 1)],
        amp: 0.5,
      );
      expect(b.peak, 0, reason: '72 kHz aliased into the audible band');
    });

    test('mastering a silent buffer does not divide by zero', () {
      final b = Buffer(0.05);
      b.master();
      expect(b.peak, 0);
      expect(b.loudness(), -120);
      expect(b.toWav(), hasLength(44 + b.frames * 2));
    });

    test('a stereo buffer pans, and a mono one sums into one channel', () {
      final s = Buffer(0.05, stereo: true);
      s.addVoice(freq: 440, duration: 0.05, amp: 0.5, pan: -1);
      expect(s.channels, 2);
      expect(s.left.reduce((a, b) => a.abs() + b.abs()), greaterThan(0));
      expect(
        s.right.map((v) => v.abs()).reduce(math.max),
        lessThan(1e-9),
        reason: 'hard left should be silent on the right',
      );
      final m = Buffer(0.05);
      m.addVoice(freq: 440, duration: 0.05, amp: 0.5, pan: -1);
      expect(m.channels, 1);
      expect(m.left.map((v) => v.abs()).reduce(math.max), greaterThan(0.1));
    });
  });
}
