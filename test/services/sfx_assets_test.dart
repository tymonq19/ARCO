import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:arco/services/audio_service.dart';
import 'package:arco_core/arco_core.dart' show maxMultiplier;
import 'package:flutter_test/flutter_test.dart';

import '../../tool/gen_sfx.dart' as sfx;

/// The shipped effects, measured rather than assumed: every clip the code asks
/// for exists, is bundled, is a 44.1 kHz 16-bit WAV, is neither silent nor
/// clipped nor cut off, sits at the same perceived loudness as the rest of the
/// set, and — with `AudioService.levelOf` applied — leaves room for the events
/// the simulation can land on a single tick.
///
/// The loudness meter is the generator's own ([sfx.Buffer.loudness]), fed from
/// the bytes on disk, so this measures the assets rather than restating the
/// generator.
void main() {
  final dir = Directory('assets/sfx');
  final decoded = <String, _Wav>{};

  _Wav wav(String clip) =>
      decoded[clip] ??= _Wav.parse(File('${dir.path}/$clip.wav'));

  setUpAll(() {
    expect(
      dir.existsSync(),
      isTrue,
      reason: 'run `dart run tool/gen_sfx.dart` first',
    );
  });

  group('bundling', () {
    test('every clip the service plays has a file', () {
      for (final clip in AudioService.clips) {
        final file = File('assets/${AudioService.assetPathOf(clip)}');
        expect(file.existsSync(), isTrue, reason: '${file.path} is missing');
        expect(file.lengthSync(), greaterThan(44), reason: 'only a header');
      }
    });

    test('nothing in assets/sfx is orphaned', () {
      final onDisk =
          dir
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .where((n) => n.endsWith('.wav'))
              .map((n) => n.substring(0, n.length - 4))
              .toSet()
            ..removeAll(AudioService.clips);
      expect(onDisk, isEmpty, reason: 'no code plays these');
    });

    test('the generator and the service agree on the file set', () {
      expect(sfx.effects.keys.toSet(), AudioService.clips.toSet());
    });

    test('the hit tiers cover every multiplier the core can reach', () {
      expect(sfx.hitTiers, maxMultiplier);
      for (var m = 1; m <= maxMultiplier; m++) {
        expect(sfx.effects.keys, contains(AudioService.hitClip(m)));
      }
    });

    test('pubspec bundles every clip', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final assets = pubspec
          .split('\n')
          .skipWhile((l) => l.trim() != 'assets:')
          .skip(1)
          .takeWhile((l) => l.trimLeft().startsWith('- '))
          .map((l) => l.trim().substring(2).trim())
          .toList();
      expect(assets, isNotEmpty, reason: 'no asset list in pubspec.yaml');
      for (final clip in AudioService.clips) {
        final path = 'assets/${AudioService.assetPathOf(clip)}';
        expect(
          assets.any(
            (a) => a == path || (a.endsWith('/') && path.startsWith(a)),
          ),
          isTrue,
          reason: '$path is not covered by $assets',
        );
      }
    });
  });

  group('format', () {
    test('every file is a 44.1 kHz 16-bit PCM WAV', () {
      for (final clip in AudioService.clips) {
        final w = wav(clip);
        expect(w.sampleRate, sfx.sampleRate, reason: clip);
        expect(w.bitsPerSample, 16, reason: clip);
        expect(w.channels, anyOf(1, 2), reason: clip);
      }
    });

    test('every header agrees with the file on disk', () {
      for (final clip in AudioService.clips) {
        final w = wav(clip);
        expect(w.riffSize + 8, w.fileLength, reason: '$clip RIFF size');
        expect(
          w.dataBytes,
          w.frames * w.channels * 2,
          reason: '$clip data chunk',
        );
      }
    });

    test('the long, spatial moments are stereo and the impacts are mono', () {
      for (final clip in <String>['star', 'heart', 'lose', 'gameover', 'win']) {
        expect(wav(clip).channels, 2, reason: clip);
      }
      for (final clip in <String>[
        'hit',
        'wall',
        'click',
        'countdown',
        'serve',
      ]) {
        expect(wav(clip).channels, 1, reason: clip);
      }
    });

    test('nothing is longer than it needs to be', () {
      for (final clip in AudioService.clips) {
        final ms = wav(clip).seconds * 1000;
        expect(ms, greaterThan(20), reason: '$clip is suspiciously short');
        expect(ms, lessThan(1500), reason: '$clip is too long for a one-shot');
      }
      expect(wav('click').seconds * 1000, lessThan(80));
      // A paddle hit is heard every ~115 ms at the fastest ball speed.
      for (var m = 1; m <= maxMultiplier; m++) {
        expect(
          wav(AudioService.hitClip(m)).seconds * 1000,
          lessThan(115),
          reason: 'hit tier $m would overlap itself',
        );
      }
    });

    test('the total asset load stays small', () {
      final kb =
          dir
              .listSync()
              .whereType<File>()
              .map((f) => f.lengthSync())
              .fold<int>(0, (a, b) => a + b) /
          1024;
      expect(kb, lessThan(1024), reason: '${kb.toStringAsFixed(1)} KB of sfx');
    });
  });

  group('the sound itself', () {
    test('nothing is silent', () {
      for (final clip in AudioService.clips) {
        expect(
          wav(clip).peak,
          greaterThan(0.2),
          reason: '$clip is near-silent',
        );
      }
    });

    test('nothing clips', () {
      for (final clip in AudioService.clips) {
        final w = wav(clip);
        expect(w.peak, lessThanOrEqualTo(sfx.peakCeiling), reason: clip);
        expect(w.samplesAtFullScale, 0, reason: '$clip touches full scale');
        expect(w.clippedPlateaus, 0, reason: '$clip has a flat-topped peak');
      }
    });

    test('nothing is truncated: every tail has faded out', () {
      for (final clip in AudioService.clips) {
        final w = wav(clip);
        final tail = w.peakOverLast(const Duration(milliseconds: 3));
        expect(
          tail,
          lessThan(w.peak / 16),
          reason:
              '$clip ends at ${(tail / w.peak * 100).toStringAsFixed(1)}% of '
              'its peak and would click',
        );
      }
    });

    test('the whole set lands at one perceived loudness', () {
      final measured = <String, double>{
        for (final clip in AudioService.clips) clip: wav(clip).loudness(),
      };
      measured.forEach((clip, lufs) {
        expect(
          lufs,
          closeTo(sfx.targetLoudness, 0.6),
          reason: '$clip is at ${lufs.toStringAsFixed(2)} LUFS',
        );
      });
      final values = measured.values.toList()..sort();
      expect(
        values.last - values.first,
        lessThan(1.0),
        reason:
            'the set spans ${(values.last - values.first).toStringAsFixed(2)} dB',
      );
    });

    test('the hit tiers climb in pitch and shorten', () {
      var previous = 0.0;
      var previousLength = double.infinity;
      for (var m = 1; m <= maxMultiplier; m++) {
        final w = wav(AudioService.hitClip(m));
        final f = w.dominantFrequency();
        expect(f, greaterThan(previous), reason: 'tier $m did not climb');
        expect(w.seconds, lessThan(previousLength), reason: 'tier $m');
        previous = f;
        previousLength = w.seconds;
      }
      // Eight steps of a major pentatonic from C5: C5 up to E6, 16 semitones.
      final low = wav('hit').dominantFrequency();
      final high = wav(AudioService.hitClip(maxMultiplier)).dominantFrequency();
      expect(high / low, closeTo(2.52, 0.12), reason: '$low Hz -> $high Hz');
    });

    test('a wall never sounds like a paddle', () {
      // A fifth and an octave apart, so the ear separates them without looking.
      expect(
        wav('wall').dominantFrequency(),
        lessThan(wav('hit').dominantFrequency() / 1.8),
      );
    });

    test('the GO is an octave above the tick', () {
      expect(
        wav(AudioService.goClip).dominantFrequency() /
            wav('countdown').dominantFrequency(),
        closeTo(2.0, 0.15),
      );
    });

    test('the pickups are opposites, so neither can be mistaken', () {
      expect(
        wav('star').dominantFrequency(),
        greaterThan(wav('heart').dominantFrequency() * 2),
      );
    });
  });

  group('the mix leaves room for a busy frame', () {
    // One `Simulation.step` runs the wall, paddle and pickup checks
    // independently, so all three can fire on the same tick. `audioplayers`
    // has no bus to put a limiter across, so the level table has to hold the
    // sum down itself.
    const stacks = <String, List<String>>{
      'a paddle hit over a wall bounce': <String>['hit', 'wall'],
      'a hit, a wall and a star in one tick': <String>['hit', 'wall', 'star'],
      'a hit, a wall and a heart in one tick': <String>['hit', 'wall', 'heart'],
      'a wall and a star as the ball escapes': <String>['wall', 'star', 'lose'],
      'the top tier over a wall and a star': <String>['hit8', 'wall', 'star'],
      'the serve cue over a wall': <String>['serve', 'wall'],
      'game over on top of the life lost': <String>['lose', 'gameover'],
      'a tap during the countdown': <String>['click', 'countdown'],
    };

    stacks.forEach((name, clips) {
      test('$name stays inside 0 dBFS', () {
        final peak = _stackPeak(clips.map(wav).toList(), clips);
        final db = 20 * math.log(peak) / math.ln10;
        expect(
          peak,
          lessThan(1.0),
          reason: '$clips sums to ${db.toStringAsFixed(2)} dBFS',
        );
      });
    });

    test('the headroom is what makes that true', () {
      // Without it the same frame would go over, which is why the constant
      // exists. If someone raises it, this test says what it was buying.
      final clips = <String>['hit', 'wall', 'star'];
      final withHeadroom = _stackPeak(clips.map(wav).toList(), clips);
      final raw = withHeadroom / AudioService.headroom;
      expect(withHeadroom, lessThan(1.0));
      expect(raw, greaterThan(1.0), reason: 'the headroom is doing nothing');
    });

    test('every pool is deep enough for the cadence the game delivers', () {
      // With a pool of N players, a spacing of C between two copies and a clip
      // of length L, the Nth copy steals a player that is still sounding unless
      // N * C >= L. C is what the game can actually deliver, not the collapse
      // window: a serve or a countdown beep is at least a second apart however
      // fast the ball is moving.
      const cadenceMs = <String, int>{
        'hit': 115, // the fastest ball crossing
        'wall': 45, // two different walls in quick succession
        'click': 55, // taps
        'star': 1000, // pickups spawn seconds apart
        'heart': 1000,
        'serve': 1000, // one per rally
        'countdown': 1000, // one per second
        'lose': 1000,
        'gameover': 2000,
        'win': 2000,
        AudioService.goClip: 2000,
      };
      for (final clip in AudioService.clips) {
        final cadence = cadenceMs[clip.startsWith('hit') ? 'hit' : clip];
        expect(cadence, isNotNull, reason: '$clip has no cadence recorded');
        final lengthMs = (wav(clip).seconds * 1000).round();
        expect(
          AudioService.poolSizeFor(clip) * cadence!,
          greaterThanOrEqualTo(lengthMs),
          reason:
              '$clip is $lengthMs ms at one per $cadence ms, so '
              '${AudioService.poolSizeFor(clip)} players is not enough',
        );
      }
    });

    test('every level is inside unity so a single clip cannot clip', () {
      for (final clip in AudioService.clips) {
        expect(
          wav(clip).peak * AudioService.levelOf(clip),
          lessThan(1.0),
          reason: clip,
        );
      }
    });
  });
}

/// Peak of [wavs] played together at their mix levels with their onsets
/// aligned — the worst case for a set of events that land on the same tick.
double _stackPeak(List<_Wav> wavs, List<String> clips) {
  final length = wavs.map((w) => w.frames).reduce(math.max);
  var peak = 0.0;
  for (var c = 0; c < 2; c++) {
    for (var i = 0; i < length; i++) {
      var sum = 0.0;
      for (var k = 0; k < wavs.length; k++) {
        sum += wavs[k].sampleAt(c, i) * AudioService.levelOf(clips[k]);
      }
      final a = sum.abs();
      if (a > peak) peak = a;
    }
  }
  return peak;
}

/// A decoded 16-bit PCM WAV file. Mono is expanded to the dual mono it becomes
/// on playback, so every measurement here is of what the player hears.
class _Wav {
  _Wav._({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.riffSize,
    required this.dataBytes,
    required this.fileLength,
    required this.left,
    required this.right,
    required this.samplesAtFullScale,
    required this.clippedPlateaus,
  });

  static _Wav parse(File file) {
    final bytes = file.readAsBytesSync();
    final view = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw StateError('${file.path} is not a RIFF/WAVE file');
    }
    var channels = 0, rate = 0, bits = 0, dataAt = -1, dataBytes = 0;
    var at = 12;
    while (at + 8 <= bytes.length) {
      final id = tag(at);
      final size = view.getUint32(at + 4, Endian.little);
      if (id == 'fmt ') {
        if (view.getUint16(at + 8, Endian.little) != 1) {
          throw StateError('${file.path} is not uncompressed PCM');
        }
        channels = view.getUint16(at + 10, Endian.little);
        rate = view.getUint32(at + 12, Endian.little);
        bits = view.getUint16(at + 22, Endian.little);
      } else if (id == 'data') {
        dataAt = at + 8;
        dataBytes = size;
      }
      at += 8 + size + (size.isOdd ? 1 : 0);
    }
    if (dataAt < 0 || bits != 16 || channels == 0) {
      throw StateError('${file.path} has no usable 16-bit data chunk');
    }
    final frames = dataBytes ~/ (2 * channels);
    final left = Float64List(frames);
    final right = Float64List(frames);
    var full = 0;
    var plateaus = 0;
    final run = List<int>.filled(channels, 0);
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < channels; c++) {
        final raw = view.getInt16(
          dataAt + (i * channels + c) * 2,
          Endian.little,
        );
        final v = raw / 32768.0;
        if (c == 0) {
          left[i] = v;
          if (channels == 1) right[i] = v;
        } else {
          right[i] = v;
        }
        if (raw.abs() >= 32767) full++;
        if (raw.abs() >= 32440) {
          run[c]++;
          if (run[c] == 3) plateaus++;
        } else {
          run[c] = 0;
        }
      }
    }
    return _Wav._(
      sampleRate: rate,
      channels: channels,
      bitsPerSample: bits,
      riffSize: view.getUint32(4, Endian.little),
      dataBytes: dataBytes,
      fileLength: bytes.length,
      left: left,
      right: right,
      samplesAtFullScale: full,
      clippedPlateaus: plateaus,
    );
  }

  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int riffSize;
  final int dataBytes;
  final int fileLength;
  final Float64List left;
  final Float64List right;
  final int samplesAtFullScale;
  final int clippedPlateaus;

  int get frames => left.length;
  double get seconds => frames / sampleRate;

  double sampleAt(int channel, int i) {
    if (i >= frames) return 0;
    return channel == 0 ? left[i] : right[i];
  }

  double get peak {
    var max = 0.0;
    for (var i = 0; i < frames; i++) {
      final a = left[i].abs();
      if (a > max) max = a;
      final b = right[i].abs();
      if (b > max) max = b;
    }
    return max;
  }

  double peakOverLast(Duration window) {
    final n = (window.inMicroseconds * sampleRate / 1000000).round();
    var max = 0.0;
    for (var i = math.max(0, frames - n); i < frames; i++) {
      final a = left[i].abs();
      if (a > max) max = a;
      final b = right[i].abs();
      if (b > max) max = b;
    }
    return max;
  }

  /// Momentary loudness through the generator's own meter, so the shipped bytes
  /// are measured the way they were mastered.
  double loudness() {
    final b = sfx.Buffer(frames / sfx.sampleRate, stereo: channels == 2);
    for (var i = 0; i < frames && i < b.frames; i++) {
      b.left[i] = left[i];
      if (channels == 2) b.right[i] = right[i];
    }
    return b.loudness();
  }

  /// The strongest partial, found by Goertzel over a 1/48-octave grid on the
  /// first 60 ms — enough to tell C5 from E6, or a wall from a paddle.
  double dominantFrequency({double from = 80, double to = 6000}) {
    final n = math.min(frames, (0.06 * sampleRate).round());
    final step = math.pow(2, 1 / 48).toDouble();
    var best = -1.0;
    var bestFreq = 0.0;
    for (var f = from; f < to; f *= step) {
      final coeff = 2 * math.cos(2 * math.pi * f / sampleRate);
      var s1 = 0.0, s2 = 0.0;
      for (var i = 0; i < n; i++) {
        final s = (left[i] + right[i]) * 0.5 + coeff * s1 - s2;
        s2 = s1;
        s1 = s;
      }
      final mag = s1 * s1 + s2 * s2 - coeff * s1 * s2;
      if (mag > best) {
        best = mag;
        bestFreq = f;
      }
    }
    return bestFreq;
  }
}
