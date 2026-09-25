/// Sound design for Arco: synthesises every effect in `assets/sfx` (SPEC §5.7)
/// as 16-bit 44.1 kHz WAV files. No external assets, no dependencies.
///
/// Each effect is built the way a sound designer would layer one — a transient,
/// a body and a tail — out of:
///
/// * curved ADSR envelopes (per layer, and per partial: high partials decay
///   faster, which is what makes a struck object sound struck),
/// * additive partials instead of a bare oscillator, inharmonic where the
///   physical object would be,
/// * a short exponential pitch drop on every impact,
/// * filtered noise (sweepable band-pass / low-pass) for the contact click and
///   for air,
/// * a small damped Schroeder reverb on the long moments, with a slightly
///   different delay set per channel for stereo width.
///
/// Every file is then DC-blocked, softly saturated, normalised to a common
/// perceived loudness ([targetLoudness], K-weighted per ITU-R BS.1770 over the
/// loudest 100 ms), peak-capped at [peakCeiling] and faded at both ends, so the
/// relative mix lives in `AudioService.gain` and never in the assets.
///
/// Deterministic: every noise layer comes from a seeded LCG, so two runs write
/// byte-identical files.
///
/// Usage: `dart run tool/gen_sfx.dart [outputDir]` (default `assets/sfx`).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// 44.1 kHz. The effects now carry real high-frequency transients, and at
/// 22.05 kHz everything above 11 kHz folded back into the audible band.
const int sampleRate = 44100;

/// Common momentary loudness of every asset, in LUFS. Mono files are measured
/// as the dual-mono they become on playback, so mono and stereo assets land at
/// the same perceived level. -11.5 is as hot as the set can go before the
/// peakiest effect (`click`, 50 ms and almost all transient) runs into
/// [peakCeiling]; the mix lives in `AudioService.gain`, well below unity.
const double targetLoudness = -11.5;

/// Peak ceiling, -1 dBFS. Headroom for the mixer and for the device limiter;
/// a file that would clip is scaled down instead.
const double peakCeiling = 0.891;

/// Edge fades. The tail gets 6 ms, which is what stops a truncated decay from
/// clicking. The head gets 0.3 ms and no more: every layer's envelope already
/// starts at zero, so the head fade is only insurance against a DC step, and a
/// "few milliseconds" there would swallow the attack transient of a 50 ms tick
/// (measured: a 1.5 ms head fade cost `click` 1.2 dB of level and most of its
/// snap).
const double fadeInSeconds = 0.0003;
const double fadeOutSeconds = 0.006;

/// Paddle-hit pitch steps, one per score multiplier (`min(1 + combo ~/ 5, 8)`
/// in the core), so a long rally climbs a pentatonic scale.
const int hitTiers = 8;

// ---------------------------------------------------------------------- noise

/// Deterministic 31-bit LCG, so the generated assets are reproducible.
class Rng {
  Rng(int seed) : _state = (seed & 0x7FFFFFFF) | 1;

  int _state;

  /// White noise in [-1, 1).
  double next() {
    _state = (1103515245 * _state + 12345) & 0x7FFFFFFF;
    return _state / 1073741824.0 - 1.0;
  }
}

// --------------------------------------------------------------------- filter

enum FilterKind { lowpass, highpass, bandpass }

/// Retunable biquad (RBJ cookbook), direct form I so sweeping the cutoff
/// mid-stream stays stable.
class Biquad {
  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  void tune(FilterKind kind, double freq, double q) {
    final f = freq.clamp(10.0, sampleRate * 0.47);
    final w0 = 2 * math.pi * f / sampleRate;
    final cw = math.cos(w0);
    final sw = math.sin(w0);
    final alpha = sw / (2 * math.max(q, 0.05));
    final a0 = 1 + alpha;
    double b0, b1, b2;
    switch (kind) {
      case FilterKind.lowpass:
        b0 = (1 - cw) / 2;
        b1 = 1 - cw;
        b2 = (1 - cw) / 2;
      case FilterKind.highpass:
        b0 = (1 + cw) / 2;
        b1 = -(1 + cw);
        b2 = (1 + cw) / 2;
      case FilterKind.bandpass:
        // Constant 0 dB peak gain.
        b0 = alpha;
        b1 = 0;
        b2 = -alpha;
    }
    _b0 = b0 / a0;
    _b1 = b1 / a0;
    _b2 = b2 / a0;
    _a1 = -2 * cw / a0;
    _a2 = (1 - alpha) / a0;
  }

  /// High shelf, used by the loudness meter's K-weighting stage.
  void tuneHighShelf(double freq, double q, double gainDb) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * freq / sampleRate;
    final cw = math.cos(w0);
    final sw = math.sin(w0);
    final alpha = sw / (2 * q);
    final sa = 2 * math.sqrt(a) * alpha;
    final b0 = a * ((a + 1) + (a - 1) * cw + sa);
    final b1 = -2 * a * ((a - 1) + (a + 1) * cw);
    final b2 = a * ((a + 1) + (a - 1) * cw - sa);
    final a0 = (a + 1) - (a - 1) * cw + sa;
    final a1 = 2 * ((a - 1) - (a + 1) * cw);
    final a2 = (a + 1) - (a - 1) * cw - sa;
    _b0 = b0 / a0;
    _b1 = b1 / a0;
    _b2 = b2 / a0;
    _a1 = a1 / a0;
    _a2 = a2 / a0;
  }

  double process(double x) {
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

// ------------------------------------------------------------------- envelope

/// Attack / decay / sustain / release with curved segments.
///
/// [decay] is the time to fall [decayCurve] nepers towards [sustain] (at the
/// default 3.2 that is about -28 dB), [attackCurve] below 1 makes the attack
/// snap and above 1 makes it swell, and the release is a squared ramp so a
/// truncated tail can never click.
class Env {
  const Env({
    this.attack = 0.001,
    this.decay = 0.08,
    this.sustain = 0.0,
    this.release = 0.012,
    this.decayCurve = 3.2,
    this.attackCurve = 0.7,
  });

  final double attack;
  final double decay;
  final double sustain;
  final double release;
  final double decayCurve;
  final double attackCurve;

  Env scaleDecay(double k) => Env(
    attack: attack,
    decay: decay * k,
    sustain: sustain,
    release: release,
    decayCurve: decayCurve,
    attackCurve: attackCurve,
  );

  /// Gain at [t] seconds for a layer that lasts [duration] seconds.
  double at(double t, double duration) {
    if (t < 0 || t >= duration) return 0;
    double g;
    if (attack > 0 && t < attack) {
      g = math.pow(t / attack, attackCurve).toDouble();
    } else {
      final d = t - attack;
      g = decay <= 0
          ? sustain
          : sustain + (1 - sustain) * math.exp(-decayCurve * d / decay);
    }
    final releaseStart = duration - release;
    if (release > 0 && t > releaseStart) {
      final k = (duration - t) / release;
      g *= k * k;
    }
    return g;
  }
}

// -------------------------------------------------------------------- partial

/// One additive partial: [ratio] of the fundamental, relative [amp], a
/// [decay] multiplier for its own envelope (< 1 = dies sooner, which is what
/// real bright partials do), plus optional detune and pan offset.
class Partial {
  const Partial(
    this.ratio,
    this.amp, {
    this.decay = 1.0,
    this.pan = 0.0,
    this.detuneCents = 0.0,
  });

  final double ratio;
  final double amp;
  final double decay;
  final double pan;
  final double detuneCents;
}

/// Struck plastic/wood: a strong fundamental with a slightly stretched octave
/// and two inharmonic partials that die fast. The paddle.
const List<Partial> struck = <Partial>[
  Partial(1, 1.0),
  Partial(2.02, 0.34, decay: 0.55),
  Partial(3.11, 0.15, decay: 0.34),
  Partial(4.72, 0.07, decay: 0.22),
];

/// Low knock: mostly fundamental, a little mid rattle. The walls.
const List<Partial> knock = <Partial>[
  Partial(1, 1.0),
  Partial(1.97, 0.46, decay: 0.55),
  Partial(3.42, 0.22, decay: 0.32),
  Partial(5.1, 0.08, decay: 0.2),
];

/// Bell/glockenspiel, for the star: inharmonic, bright, long fundamental.
const List<Partial> bell = <Partial>[
  Partial(1, 1.0),
  Partial(2.76, 0.4, decay: 0.45),
  Partial(5.4, 0.18, decay: 0.24),
  Partial(8.93, 0.07, decay: 0.15),
];

/// Warm, dark, almost a soft organ: the heart.
const List<Partial> warm = <Partial>[
  Partial(0.5, 0.3, decay: 1.1),
  Partial(1, 1.0),
  Partial(2, 0.17, decay: 0.8),
  Partial(3, 0.05, decay: 0.5),
];

/// Hollow and harmonic, no sub-octave: the low notes of `gameover` have to
/// project through a phone speaker that rolls off below ~500 Hz, and a partial
/// under 150 Hz would only eat headroom.
const List<Partial> hollow = <Partial>[
  Partial(1, 1.0),
  Partial(2, 0.38, decay: 0.85),
  Partial(3, 0.16, decay: 0.6),
  Partial(4, 0.07, decay: 0.4),
];

/// Terse arcade edge: odd harmonics only, i.e. a band-limited square. Used
/// sparingly on top of the impacts so they keep some 8-bit DNA.
const List<Partial> squareish = <Partial>[
  Partial(1, 1.0),
  Partial(3, 0.33, decay: 0.7),
  Partial(5, 0.2, decay: 0.5),
  Partial(7, 0.14, decay: 0.35),
  Partial(9, 0.11, decay: 0.25),
];

/// Bright chime for the win / go moments: harmonic, with a shimmering fifth.
const List<Partial> chime = <Partial>[
  Partial(1, 1.0),
  Partial(2, 0.42, decay: 0.7),
  Partial(3, 0.18, decay: 0.5),
  Partial(4, 0.1, decay: 0.38),
  Partial(6, 0.05, decay: 0.24),
];

// --------------------------------------------------------------------- buffer

/// Float render target: mono writes [left] only, stereo pans into both.
class Buffer {
  Buffer(double seconds, {this.stereo = false})
    : left = Float64List(math.max(1, (sampleRate * seconds).round())),
      right = Float64List(math.max(1, (sampleRate * seconds).round()));

  final Float64List left;
  final Float64List right;
  final bool stereo;

  int get frames => left.length;
  double get seconds => frames / sampleRate;
  int get channels => stereo ? 2 : 1;

  void _add(int i, double v, double pan) {
    if (!stereo) {
      left[i] += v;
      return;
    }
    final theta = (pan.clamp(-1.0, 1.0) + 1) * math.pi / 4;
    left[i] += v * math.cos(theta);
    right[i] += v * math.sin(theta);
  }

  /// One additive voice: [partials] over [freq], optionally gliding from
  /// [glideFrom] (exponential in pitch, so it reads as a bend in semitones).
  void addVoice({
    required double freq,
    required double duration,
    double at = 0,
    double? glideFrom,
    double glideTime = 0.02,
    List<Partial> partials = const <Partial>[Partial(1, 1)],
    Env env = const Env(),
    double amp = 0.5,
    double pan = 0,
    double vibratoHz = 0,
    double vibratoDepth = 0,
  }) {
    final first = (at * sampleRate).round();
    final count = (duration * sampleRate).round();
    const nyquist = sampleRate * 0.47;
    for (final p in partials) {
      final pEnv = env.scaleDecay(p.decay);
      final ratio = p.ratio * math.pow(2, p.detuneCents / 1200).toDouble();
      var phase = 0.0;
      for (var i = 0; i < count; i++) {
        final t = i / sampleRate;
        var f = freq;
        if (glideFrom != null && glideTime > 0 && glideFrom > 0) {
          final x = math.min(1.0, t / glideTime);
          final shaped = 1 - (1 - x) * (1 - x);
          f = glideFrom * math.pow(freq / glideFrom, shaped).toDouble();
        }
        if (vibratoHz > 0) {
          f *= 1 + vibratoDepth * math.sin(2 * math.pi * vibratoHz * t);
        }
        final pf = f * ratio;
        phase += 2 * math.pi * pf / sampleRate;
        final index = first + i;
        if (index < 0 || index >= left.length) continue;
        if (pf > nyquist) continue; // never alias a high partial back down
        final g = pEnv.at(t, duration);
        if (g == 0) continue;
        _add(index, math.sin(phase) * p.amp * amp * g, pan + p.pan);
      }
    }
  }

  /// Filtered noise: the contact click of an impact, or air. [from] / [to]
  /// sweep the filter exponentially; [wide] renders two decorrelated streams
  /// hard-ish panned, which is what makes a whoosh feel big.
  void addNoise({
    required double duration,
    required double from,
    double at = 0,
    double? to,
    FilterKind kind = FilterKind.bandpass,
    double q = 1.0,
    Env env = const Env(),
    double amp = 0.3,
    double pan = 0,
    bool wide = false,
    int seed = 1,
  }) {
    final first = (at * sampleRate).round();
    final count = (duration * sampleRate).round();
    final streams = wide && stereo ? 2 : 1;
    for (var s = 0; s < streams; s++) {
      final rng = Rng(seed + s * 7919);
      final filter = Biquad()..tune(kind, from, q);
      final spread = streams == 1 ? pan : (s == 0 ? -0.8 : 0.8);
      var tuned = from;
      for (var i = 0; i < count; i++) {
        final t = i / sampleRate;
        if (to != null && count > 1) {
          final x = i / (count - 1);
          final f = from * math.pow(to / from, x).toDouble();
          // Retune every 16 samples: inaudible stepping, a third of the cost.
          if (i % 16 == 0 || i == count - 1) {
            tuned = f;
            filter.tune(kind, tuned, q);
          }
        }
        final v = filter.process(rng.next());
        final index = first + i;
        if (index < 0 || index >= left.length) continue;
        final g = env.at(t, duration);
        if (g == 0) continue;
        _add(index, v * amp * g / streams, spread);
      }
    }
  }

  /// Four damped feedback combs into two allpasses, Freeverb's delay tuning,
  /// with the right channel offset by 23 samples for width. Short and dark by
  /// design: this is a tail, not a hall.
  void reverb({
    double mix = 0.2,
    double rt60 = 0.4,
    double damping = 6000,
    double predelay = 0.008,
    double width = 0.7,
  }) {
    final n = frames;
    final send = Float64List(n);
    for (var i = 0; i < n; i++) {
      send[i] = stereo ? (left[i] + right[i]) * 0.5 : left[i];
    }
    final pre = (predelay * sampleRate).round();
    final damp = math.exp(-2 * math.pi * damping / sampleRate);
    final wet = <Float64List>[Float64List(n), Float64List(n)];
    const combs = <int>[1116, 1188, 1277, 1356];
    const allpasses = <int>[556, 441];
    for (var ch = 0; ch < 2; ch++) {
      final offset = ch == 0 ? 0 : 23;
      final lines = <Float64List>[];
      final gains = <double>[];
      final lp = List<double>.filled(combs.length, 0);
      final cursor = List<int>.filled(combs.length, 0);
      for (final d in combs) {
        final len = d + offset;
        lines.add(Float64List(len));
        gains.add(math.pow(10, -3 * len / (rt60 * sampleRate)).toDouble());
      }
      final apLines = <Float64List>[];
      final apCursor = List<int>.filled(allpasses.length, 0);
      for (final d in allpasses) {
        apLines.add(Float64List(d + offset));
      }
      for (var i = 0; i < n; i++) {
        final src = i - pre >= 0 ? send[i - pre] : 0.0;
        var acc = 0.0;
        for (var c = 0; c < lines.length; c++) {
          final line = lines[c];
          final out = line[cursor[c]];
          lp[c] = out * (1 - damp) + lp[c] * damp;
          line[cursor[c]] = src + lp[c] * gains[c];
          cursor[c] = (cursor[c] + 1) % line.length;
          acc += out;
        }
        acc *= 0.25;
        for (var a = 0; a < apLines.length; a++) {
          final line = apLines[a];
          final buffered = line[apCursor[a]];
          final out = buffered - acc;
          line[apCursor[a]] = acc + buffered * 0.5;
          apCursor[a] = (apCursor[a] + 1) % line.length;
          acc = out;
        }
        wet[ch][i] = acc;
      }
    }
    final side = 0.5 - 0.5 * width;
    final main = 0.5 + 0.5 * width;
    for (var i = 0; i < n; i++) {
      if (stereo) {
        left[i] += mix * (wet[0][i] * main + wet[1][i] * side);
        right[i] += mix * (wet[1][i] * main + wet[0][i] * side);
      } else {
        left[i] += mix * (wet[0][i] + wet[1][i]) * 0.5;
      }
    }
  }

  /// Removes the DC a strongly asymmetric layer can leave behind; DC eats
  /// headroom and thumps a phone speaker for nothing.
  void dcBlock() {
    for (final ch in _activeChannels) {
      var x1 = 0.0, y1 = 0.0;
      for (var i = 0; i < ch.length; i++) {
        final x = ch[i];
        final y = x - x1 + 0.9985 * y1;
        ch[i] = y;
        x1 = x;
        y1 = y;
      }
    }
  }

  /// Gentle tanh saturation: glues the transient to the body and rounds the
  /// odd peak instead of letting the quantiser clip it.
  void saturate(double drive) {
    if (drive <= 0) return;
    final norm = _tanh(drive);
    for (final ch in _activeChannels) {
      for (var i = 0; i < ch.length; i++) {
        ch[i] = _tanh(ch[i] * drive) / norm;
      }
    }
  }

  void gain(double g) {
    for (final ch in _activeChannels) {
      for (var i = 0; i < ch.length; i++) {
        ch[i] *= g;
      }
    }
  }

  double get peak {
    var max = 0.0;
    for (final ch in _activeChannels) {
      for (final v in ch) {
        final a = v.abs();
        if (a > max) max = a;
      }
    }
    return max;
  }

  /// Momentary K-weighted loudness in LUFS: the loudest [window] seconds.
  ///
  /// BS.1770's gated integration needs 400 ms blocks, which a 90 ms one-shot
  /// does not have, so the effects are matched on the loudest 100 ms instead.
  /// A mono file is measured as the dual-mono it becomes on playback, so mono
  /// and stereo assets end up equally loud in the game.
  double loudness({double window = 0.1}) {
    final n = frames;
    final power = Float64List(n);
    for (final ch in _activeChannels) {
      final shelf = Biquad()
        ..tuneHighShelf(1681.974450955533, 0.7071752369554196, 3.999843853973);
      final hp = Biquad()
        ..tune(FilterKind.highpass, 38.13547087602444, 0.5003270373238773);
      for (var i = 0; i < n; i++) {
        final y = hp.process(shelf.process(ch[i]));
        power[i] += y * y;
      }
    }
    if (!stereo) {
      for (var i = 0; i < n; i++) {
        power[i] *= 2; // plays out of both speakers
      }
    }
    final win = math.min(n, math.max(1, (window * sampleRate).round()));
    var sum = 0.0;
    for (var i = 0; i < win; i++) {
      sum += power[i];
    }
    var best = sum;
    for (var i = win; i < n; i++) {
      sum += power[i] - power[i - win];
      if (sum > best) best = sum;
    }
    final mean = best / win;
    if (mean <= 1e-18) return -120;
    return -0.691 + 10 * (math.log(mean) / math.ln10);
  }

  /// Static soft-knee peak limiter. Everything under [knee] passes untouched;
  /// above it the curve bends asymptotically into [peakCeiling], so the top of
  /// a transient is rounded instead of the whole file being turned down. Flat
  /// gain reduction cost `click` 2.4 dB of loudness against the rest of the
  /// set, which is exactly the inconsistency the mastering step exists to
  /// remove.
  void limit({double knee = 0.55}) {
    final span = peakCeiling - knee;
    if (span <= 0) return;
    for (final ch in _activeChannels) {
      for (var i = 0; i < ch.length; i++) {
        final v = ch[i];
        final a = v.abs();
        if (a <= knee) continue;
        final shaped = knee + span * _tanh((a - knee) / span);
        ch[i] = v.isNegative ? -shaped : shaped;
      }
    }
  }

  /// Loudness match into the limiter, then the edge fades. Two or three passes
  /// converge because the limiter only moves the loudest samples.
  void master({double target = targetLoudness, double drive = 1.6}) {
    dcBlock();
    gain(0.92 / math.max(peak, 1e-9)); // into the saturator at a known level
    saturate(drive);
    for (var pass = 0; pass < 4; pass++) {
      final measured = loudness();
      if (measured < -119) break;
      final delta = target - measured;
      gain(math.pow(10, delta / 20).toDouble());
      limit();
      if (delta.abs() < 0.05) break;
    }
    _fade();
  }

  void _fade() {
    final inN = math.min(frames, (fadeInSeconds * sampleRate).round());
    final outN = math.min(frames, (fadeOutSeconds * sampleRate).round());
    for (final ch in _activeChannels) {
      for (var i = 0; i < inN; i++) {
        ch[i] *= i / inN;
      }
      for (var i = 0; i < outN; i++) {
        ch[ch.length - 1 - i] *= i / outN;
      }
    }
  }

  List<Float64List> get _activeChannels =>
      stereo ? <Float64List>[left, right] : <Float64List>[left];

  /// 16-bit little-endian PCM with a 44-byte RIFF header.
  Uint8List toWav() {
    final ch = channels;
    final bytes = Uint8List(44 + frames * 2 * ch);
    final view = ByteData.view(bytes.buffer);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes[offset + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    view.setUint32(4, 36 + frames * 2 * ch, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    view.setUint32(16, 16, Endian.little); // PCM chunk size
    view.setUint16(20, 1, Endian.little); // format: PCM
    view.setUint16(22, ch, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, sampleRate * 2 * ch, Endian.little); // byte rate
    view.setUint16(32, 2 * ch, Endian.little); // block align
    view.setUint16(34, 16, Endian.little); // bits per sample
    ascii(36, 'data');
    view.setUint32(40, frames * 2 * ch, Endian.little);
    var offset = 44;
    for (var i = 0; i < frames; i++) {
      for (final c in _activeChannels) {
        var v = c[i];
        if (v > 1) v = 1;
        if (v < -1) v = -1;
        view.setInt16(offset, (v * 32767).round(), Endian.little);
        offset += 2;
      }
    }
    return bytes;
  }
}

double _tanh(double x) {
  if (x > 12) return 1;
  if (x < -12) return -1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// Semitones above [freq] — pitch arithmetic that reads as music.
double semitone(double freq, double steps) =>
    freq * math.pow(2, steps / 12).toDouble();

// -------------------------------------------------------------------- effects

/// The paddle hit, one per score multiplier tier (1 = no combo).
///
/// The sound the player hears most, so: 70-85 ms total, a soft contact click,
/// a struck body with a fast pitch drop, a whisper of square for arcade edge,
/// and no reverb at all. Higher tiers climb a pentatonic scale, shorten and
/// brighten a little, so a long rally audibly builds.
Buffer hit(int rawTier) {
  const scale = <double>[0, 2, 4, 7, 9, 12, 14, 16]; // major pentatonic
  // Clamp the tier itself, not just the scale index: a tier past the top has to
  // come out identical to the top. Clamping only the note would leave the clip
  // still shortening and brightening under a pitch that had stopped climbing,
  // which is the kind of divergence nobody notices until the ladder is extended.
  // Indexing [scale] directly then means raising [hitTiers] past the scale
  // fails loudly at generation time instead of silently repeating a note.
  final tier = rawTier.clamp(1, hitTiers);
  final step = scale[tier - 1];
  final f = semitone(523.25, step); // C5 .. E6
  final t01 = (tier - 1) / (hitTiers - 1);
  final duration = 0.086 - 0.016 * t01;
  final b = Buffer(duration);
  // Contact click: a short band of noise, brighter with the combo.
  b.addNoise(
    duration: duration * 0.5,
    from: 3000 + 1300 * t01,
    to: 1700 + 700 * t01,
    q: 0.7,
    amp: 1.55,
    env: const Env(attack: 0.0003, decay: 0.006, release: 0.004),
    seed: 21 + tier,
  );
  // Body: struck plastic, pitched up 7 semitones for the first ~14 ms.
  b.addVoice(
    freq: f,
    glideFrom: semitone(f, 7),
    glideTime: 0.014,
    duration: duration,
    partials: struck,
    amp: 0.8,
    env: Env(
      attack: 0.0006,
      decay: 0.052 - 0.012 * t01,
      release: 0.01,
      attackCurve: 0.5,
    ),
  );
  // Arcade edge: two cycles of square, low enough to be felt not heard.
  b.addVoice(
    freq: f * 2,
    duration: duration * 0.35,
    partials: squareish,
    amp: 0.15,
    env: const Env(attack: 0.0004, decay: 0.009, release: 0.006),
  );
  b.master(drive: 2.0);
  return b;
}

/// A wall bounce: lower, duller, heavier than a paddle hit, and clearly not
/// the same object. Low-passed noise thud, a knocked body that drops a fifth,
/// and a short sub for weight.
Buffer wall() {
  const duration = 0.135;
  final b = Buffer(duration);
  b.addNoise(
    duration: 0.03,
    from: 2200,
    to: 600,
    kind: FilterKind.lowpass,
    q: 0.8,
    amp: 1.5,
    env: const Env(attack: 0.0004, decay: 0.008, release: 0.006),
    seed: 77,
  );
  b.addVoice(
    freq: 233.08, // A#3: a fifth and an octave under the paddle's C5
    glideFrom: 380,
    glideTime: 0.028,
    duration: duration,
    partials: knock,
    amp: 0.8,
    env: const Env(attack: 0.001, decay: 0.07, release: 0.014),
  );
  // Weight for headphones. A phone speaker cannot reproduce it, which is why
  // the knock's own harmonics have to carry the sound.
  b.addVoice(
    freq: 116.54,
    duration: 0.1,
    amp: 0.22,
    env: const Env(attack: 0.002, decay: 0.05, release: 0.012),
  );
  b.master(drive: 1.8);
  return b;
}

/// Star pickup: bright, fast, sparkling, panned left to right, with a short
/// bright tail. Deliberately the opposite of [heart] in every dimension —
/// register, attack, timbre and movement — so the two can never be confused.
Buffer star() {
  const duration = 0.42;
  final b = Buffer(duration, stereo: true);
  const notes = <double>[1046.5, 1318.5, 1568.0, 2093.0]; // C6 E6 G6 C7
  for (var i = 0; i < notes.length; i++) {
    final last = i == notes.length - 1;
    final at = i * 0.036;
    final pan = -0.35 + 0.23 * i;
    b.addVoice(
      freq: notes[i],
      duration: duration - at,
      at: at,
      partials: bell,
      amp: last ? 0.5 : 0.34,
      pan: pan,
      env: Env(
        attack: 0.0015,
        decay: last ? 0.19 : 0.075,
        release: 0.02,
        attackCurve: 0.6,
      ),
    );
    // Shimmer: a detuned octave above, panned the other way.
    b.addVoice(
      freq: notes[i] * 2,
      duration: duration - at,
      at: at,
      amp: last ? 0.1 : 0.06,
      pan: -pan,
      env: Env(attack: 0.002, decay: last ? 0.1 : 0.05, release: 0.02),
      partials: const <Partial>[Partial(1, 1, detuneCents: 8)],
    );
  }
  // A pinch of air on the first note, so the run starts with a "tink".
  b.addNoise(
    duration: 0.05,
    from: 5200,
    to: 8000,
    q: 0.8,
    amp: 0.95,
    wide: true,
    env: const Env(attack: 0.0006, decay: 0.012, release: 0.01),
    seed: 303,
  );
  b.reverb(mix: 0.2, rt60: 0.3, damping: 9000, predelay: 0.006, width: 0.85);
  b.master(drive: 1.4);
  return b;
}

/// Extra life: warm, soft, low, two notes rising a fifth. No click, slow
/// attack, dark timbre, gentle vibrato — the star's opposite.
Buffer heart() {
  const duration = 0.58;
  final b = Buffer(duration, stereo: true);
  b.addVoice(
    freq: 440.0, // A4
    duration: 0.3,
    partials: warm,
    amp: 0.55,
    pan: -0.2,
    vibratoHz: 5.5,
    vibratoDepth: 0.004,
    env: const Env(attack: 0.018, decay: 0.22, release: 0.06, attackCurve: 1.4),
  );
  b.addVoice(
    freq: 659.25, // E5, a fifth up
    duration: 0.42,
    at: 0.14,
    partials: warm,
    amp: 0.6,
    pan: 0.2,
    vibratoHz: 5.0,
    vibratoDepth: 0.004,
    env: const Env(attack: 0.022, decay: 0.3, release: 0.08, attackCurve: 1.4),
  );
  b.reverb(mix: 0.26, rt60: 0.5, damping: 3200, predelay: 0.012, width: 0.6);
  b.master(drive: 1.2);
  return b;
}

/// A life lost. Not a buzz: the pitch sags a minor third and keeps falling,
/// a detuned second voice beats against it, the air drains out through a
/// closing low-pass, and a soft low thud lands at the end.
Buffer lose() {
  const duration = 0.72;
  final b = Buffer(duration, stereo: true);
  b.addVoice(
    freq: 220.0, // A3
    glideFrom: 392.0, // G4
    glideTime: 0.4,
    duration: 0.62,
    partials: const <Partial>[
      Partial(1, 1.0),
      Partial(2, 0.42, decay: 0.8),
      Partial(3.02, 0.2, decay: 0.55),
      Partial(4.1, 0.08, decay: 0.35),
    ],
    amp: 0.6,
    pan: -0.15,
    env: const Env(attack: 0.004, decay: 0.42, release: 0.08),
  );
  // The queasy one: a touch flat, so the two beat against each other.
  b.addVoice(
    freq: 220.0,
    glideFrom: 369.99,
    glideTime: 0.4,
    duration: 0.5,
    partials: const <Partial>[
      Partial(1, 1, detuneCents: -18),
      Partial(2, 0.3, decay: 0.7),
    ],
    amp: 0.22,
    pan: 0.2,
    env: const Env(attack: 0.006, decay: 0.3, release: 0.06),
  );
  // Air draining away.
  b.addNoise(
    duration: 0.5,
    from: 3000,
    to: 600,
    kind: FilterKind.lowpass,
    q: 0.9,
    amp: 0.7,
    wide: true,
    env: const Env(attack: 0.01, decay: 0.34, release: 0.08),
    seed: 513,
  );
  // Landing.
  b.addVoice(
    freq: 98.0,
    glideFrom: 123.47,
    glideTime: 0.05,
    duration: 0.3,
    at: 0.3,
    amp: 0.4,
    env: const Env(attack: 0.003, decay: 0.17, release: 0.05),
    partials: const <Partial>[
      Partial(1, 1.0),
      Partial(2, 0.45, decay: 0.6),
      Partial(3, 0.15, decay: 0.4),
    ],
  );
  b.reverb(mix: 0.22, rt60: 0.55, damping: 2600, predelay: 0.014, width: 0.5);
  b.master(drive: 1.3);
  return b;
}

/// The serve: a short rising whoosh. Quiet on purpose — it is a cue, not an
/// event, and it fires at the start of every rally.
Buffer serve() {
  const duration = 0.2;
  final b = Buffer(duration);
  b.addNoise(
    duration: 0.16,
    from: 600,
    to: 3400,
    q: 0.85,
    amp: 1.0,
    env: const Env(attack: 0.05, decay: 0.07, release: 0.05, attackCurve: 1.6),
    seed: 91,
  );
  b.addVoice(
    freq: 659.25,
    glideFrom: 329.63,
    glideTime: 0.13,
    duration: 0.18,
    partials: const <Partial>[Partial(1, 1.0), Partial(2, 0.14, decay: 0.6)],
    amp: 0.34,
    env: const Env(attack: 0.012, decay: 0.1, release: 0.04, attackCurve: 1.2),
  );
  b.master(drive: 1.4);
  return b;
}

/// Solo game over: a descending minor tetrachord whose last note sags and
/// spreads into a dark tail. It should feel like the air leaving the room.
Buffer gameover() {
  const duration = 1.15;
  final b = Buffer(duration, stereo: true);
  // Transposed a fourth up from where it started: a descending minor line
  // is sombre because of the motion, not the register, and A3 (220 Hz) was
  // 10 dB down on a phone speaker.
  const notes = <double>[587.33, 466.16, 392.0, 293.66]; // D5 A#4 G4 D4
  for (var i = 0; i < notes.length; i++) {
    final last = i == notes.length - 1;
    final at = i * 0.155;
    b.addVoice(
      freq: last ? 277.18 : notes[i], // the last note sags a semitone
      glideFrom: last ? notes[i] : null,
      glideTime: 0.28,
      duration: (last ? 0.6 : 0.34).clamp(0.0, duration - at),
      at: at,
      partials: hollow,
      amp: last ? 0.6 : 0.45,
      pan: -0.25 + 0.17 * i,
      env: Env(
        attack: last ? 0.008 : 0.004,
        decay: last ? 0.42 : 0.24,
        release: 0.06,
        attackCurve: 0.9,
      ),
    );
  }
  b.addVoice(
    freq: 146.83,
    duration: 0.5,
    at: 0.465,
    amp: 0.18,
    env: const Env(attack: 0.01, decay: 0.34, release: 0.08),
    partials: const <Partial>[Partial(1, 1.0), Partial(2, 0.15, decay: 0.5)],
  );
  b.reverb(mix: 0.28, rt60: 0.6, damping: 2400, predelay: 0.016, width: 0.55);
  b.master(drive: 1.2);
  return b;
}

/// Duel won: a rising major arpeggio that lands on a wide chord, with a bell
/// shimmer an octave up and a bright tail.
Buffer win() {
  const duration = 1.2;
  final b = Buffer(duration, stereo: true);
  const notes = <double>[523.25, 659.25, 784.0, 1046.5]; // C5 E5 G5 C6
  for (var i = 0; i < notes.length; i++) {
    final at = i * 0.105;
    b.addVoice(
      freq: notes[i],
      duration: 0.34,
      at: at,
      partials: chime,
      amp: 0.4,
      pan: 0.3 - 0.2 * i,
      env: const Env(attack: 0.003, decay: 0.2, release: 0.05),
    );
    // A detuned unison the other side of the field: chorus width.
    b.addVoice(
      freq: notes[i],
      duration: 0.3,
      at: at,
      partials: const <Partial>[Partial(1, 1, detuneCents: 9)],
      amp: 0.12,
      pan: -0.3 + 0.2 * i,
      env: const Env(attack: 0.004, decay: 0.16, release: 0.05),
    );
  }
  // The landing chord: C major, wide, held.
  const chord = <double>[523.25, 659.25, 784.0];
  for (var i = 0; i < chord.length; i++) {
    b.addVoice(
      freq: chord[i],
      duration: 0.72,
      at: 0.42,
      partials: chime,
      amp: 0.3,
      pan: -0.4 + 0.4 * i,
      env: const Env(attack: 0.005, decay: 0.45, release: 0.1),
    );
  }
  b.addVoice(
    freq: 2093.0,
    duration: 0.6,
    at: 0.44,
    partials: bell,
    amp: 0.1,
    pan: 0.15,
    env: const Env(attack: 0.004, decay: 0.3, release: 0.08),
  );
  b.reverb(mix: 0.22, rt60: 0.55, damping: 7000, predelay: 0.012, width: 0.8);
  b.master(drive: 1.25);
  return b;
}

/// UI tick: 45 ms, crisp, no pitch to speak of. It must never be the loudest
/// thing in the app.
Buffer click() {
  const duration = 0.05;
  final b = Buffer(duration);
  b.addNoise(
    duration: 0.02,
    from: 3400,
    to: 2200,
    q: 0.8,
    amp: 1.9,
    env: const Env(attack: 0.0002, decay: 0.004, release: 0.004),
    seed: 41,
  );
  b.addVoice(
    freq: 1180,
    glideFrom: 1560,
    glideTime: 0.006,
    duration: 0.04,
    partials: const <Partial>[Partial(1, 1.0), Partial(2.4, 0.18, decay: 0.5)],
    amp: 0.5,
    env: const Env(attack: 0.0004, decay: 0.016, release: 0.008),
  );
  b.master(drive: 1.8);
  return b;
}

/// Countdown tick (3, 2, 1). Dry, neutral, identical each time so the GO can
/// be the thing that changes.
Buffer countdown() {
  const duration = 0.17;
  final b = Buffer(duration);
  b.addNoise(
    duration: 0.012,
    from: 3000,
    q: 0.8,
    amp: 0.8,
    env: const Env(attack: 0.0003, decay: 0.004, release: 0.004),
    seed: 65,
  );
  b.addVoice(
    freq: 880,
    glideFrom: 932,
    glideTime: 0.008,
    duration: 0.16,
    partials: const <Partial>[
      Partial(1, 1.0),
      Partial(2, 0.2, decay: 0.55),
      Partial(3, 0.06, decay: 0.3),
    ],
    amp: 0.6,
    env: const Env(attack: 0.0015, decay: 0.09, release: 0.02),
  );
  b.master(drive: 1.5);
  return b;
}

/// GO: an octave above the tick, a fifth on top, longer, with a tail. Nobody
/// can mistake it for a fourth tick.
Buffer countdownGo() {
  const duration = 0.42;
  final b = Buffer(duration);
  b.addNoise(
    duration: 0.04,
    from: 4200,
    to: 6500,
    q: 0.9,
    amp: 0.8,
    env: const Env(attack: 0.0006, decay: 0.012, release: 0.01),
    seed: 67,
  );
  b.addVoice(
    freq: 1760,
    glideFrom: 1600,
    glideTime: 0.02,
    duration: 0.38,
    partials: chime,
    amp: 0.55,
    env: const Env(attack: 0.0015, decay: 0.2, release: 0.05),
  );
  b.addVoice(
    freq: 2637,
    duration: 0.3,
    partials: const <Partial>[Partial(1, 1, detuneCents: 6)],
    amp: 0.12,
    env: const Env(attack: 0.002, decay: 0.14, release: 0.04),
  );
  b.reverb(mix: 0.16, rt60: 0.32, damping: 8000, predelay: 0.006, width: 0.6);
  b.master(drive: 1.35);
  return b;
}

/// Every file the generator writes, keyed by basename. `hit` is multiplier 1;
/// `hit2` .. `hit8` are the combo tiers (see `AudioService`).
Map<String, Buffer Function()> get effects => <String, Buffer Function()>{
  'hit': () => hit(1),
  for (var tier = 2; tier <= hitTiers; tier++) 'hit$tier': _tier(tier),
  'wall': wall,
  'star': star,
  'heart': heart,
  'lose': lose,
  'serve': serve,
  'gameover': gameover,
  'win': win,
  'click': click,
  'countdown': countdown,
  'countdown_go': countdownGo,
};

Buffer Function() _tier(int tier) =>
    () => hit(tier);

// ------------------------------------------------------------------- recorded

/// A list of effect names the generator must not overwrite, one per line, `#`
/// for a comment. It lives beside the assets it describes and does not exist
/// until somebody replaces a synthesised effect with a recording — see README
/// "Sound".
const String recordedManifest = 'RECORDED';

/// The effect names held back by [recordedManifest] in [dir].
///
/// Unknown names are returned too: [main] reports them, because a typo here
/// would silently overwrite the recording it was meant to protect.
/// Reads a 16-bit PCM WAV back into a [Buffer], so a recording dropped into the
/// asset directory is reported on the same meters as everything the generator
/// writes — which is the whole point of being able to drop one in.
///
/// Returns null when the file is missing, is not a RIFF/WAVE, is not
/// uncompressed 16-bit PCM, or has no frames. [rateOf] reports the file's own
/// sample rate, which [main] checks against [sampleRate].
Buffer? readWav(File file) {
  if (!file.existsSync()) return null;
  final bytes = file.readAsBytesSync();
  if (bytes.length < 44) return null;
  final view = ByteData.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  var channels = 0, bits = 0, dataAt = -1, dataBytes = 0;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final id = tag(at);
    final size = view.getUint32(at + 4, Endian.little);
    if (id == 'fmt ') {
      if (view.getUint16(at + 8, Endian.little) != 1) return null;
      channels = view.getUint16(at + 10, Endian.little);
      bits = view.getUint16(at + 22, Endian.little);
    } else if (id == 'data') {
      dataAt = at + 8;
      dataBytes = math.min(size, bytes.length - at - 8);
    }
    at += 8 + size + (size.isOdd ? 1 : 0);
  }
  if (dataAt < 0 || bits != 16 || channels < 1 || channels > 2) return null;
  final frames = dataBytes ~/ (2 * channels);
  if (frames == 0) return null;
  final b = Buffer(frames / sampleRate, stereo: channels == 2);
  for (var i = 0; i < frames && i < b.frames; i++) {
    final base = dataAt + i * channels * 2;
    b.left[i] = view.getInt16(base, Endian.little) / 32768.0;
    if (channels == 2) {
      b.right[i] = view.getInt16(base + 2, Endian.little) / 32768.0;
    }
  }
  return b;
}

/// The sample rate declared by a WAV file, or null when it cannot be read.
int? rateOf(File file) {
  if (!file.existsSync()) return null;
  final bytes = file.readAsBytesSync();
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') {
    return null;
  }
  return ByteData.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  ).getUint32(24, Endian.little);
}

Set<String> recordedIn(Directory dir) {
  final file = File('${dir.path}/$recordedManifest');
  if (!file.existsSync()) return const <String>{};
  return file
      .readAsLinesSync()
      .map((l) => l.split('#').first.trim())
      .where((l) => l.isNotEmpty)
      .map((l) => l.endsWith('.wav') ? l.substring(0, l.length - 4) : l)
      .toSet();
}

void main(List<String> args) {
  final dir = Directory(args.isNotEmpty ? args.first : 'assets/sfx');
  dir.createSync(recursive: true);
  final recorded = recordedIn(dir);
  final unknown = recorded.difference(effects.keys.toSet());
  final problems = <String>[];
  var total = 0;
  var kept = 0;
  stdout.writeln(
    '${'name'.padRight(13)}${'ch'.padLeft(3)}${'ms'.padLeft(7)}'
    '${'KB'.padLeft(8)}${'peak dB'.padLeft(9)}${'LUFS'.padLeft(8)}',
  );
  effects.forEach((name, build) {
    final file = File('${dir.path}/$name.wav');
    final Buffer buffer;
    final int size;
    final String mark;
    if (recorded.contains(name)) {
      kept++;
      // Measured, not trusted: a dropped-in recording is reported on the same
      // meters as the rest of the set, so it is obvious when it does not match.
      final read = readWav(file);
      if (read == null) {
        problems.add(
          '$name: $recordedManifest holds it back, but '
          '${file.path} is missing or is not a 16-bit PCM WAV',
        );
        stdout.writeln('${name.padRight(13)}${'unreadable'.padLeft(35)}');
        return;
      }
      final rate = rateOf(file);
      if (rate != sampleRate) {
        problems.add('$name: $rate Hz, not $sampleRate Hz');
      }
      buffer = read;
      size = file.lengthSync();
      mark = ' *';
    } else {
      buffer = build();
      final bytes = buffer.toWav();
      file.writeAsBytesSync(bytes);
      size = bytes.length;
      mark = '';
    }
    total += size;
    final peakDb = 20 * math.log(math.max(buffer.peak, 1e-9)) / math.ln10;
    stdout.writeln(
      '${name.padRight(13)}${buffer.channels.toString().padLeft(3)}'
      '${(buffer.seconds * 1000).round().toString().padLeft(7)}'
      '${(size / 1024).toStringAsFixed(1).padLeft(8)}'
      '${peakDb.toStringAsFixed(2).padLeft(9)}'
      '${buffer.loudness().toStringAsFixed(2).padLeft(8)}$mark',
    );
  });
  stdout.writeln(
    '${effects.length} files, ${(total / 1024).toStringAsFixed(1)} KB total, '
    '$sampleRate Hz / 16-bit, target ${targetLoudness.toStringAsFixed(1)} LUFS.',
  );
  if (kept > 0) {
    stdout.writeln(
      '$kept marked * kept from $recordedManifest and measured in place; '
      'target ${targetLoudness.toStringAsFixed(1)} LUFS, peak '
      '${(20 * math.log(peakCeiling) / math.ln10).toStringAsFixed(1)} dBFS.',
    );
  }
  for (final p in problems) {
    stderr.writeln('warning: $p');
  }
  if (unknown.isNotEmpty) {
    stderr.writeln(
      'warning: $recordedManifest names effects that do not exist: '
      '${(unknown.toList()..sort()).join(', ')}',
    );
  }
  // A ladder that is half recorded and half synthesised changes timbre in the
  // middle of a rally, which is worse than either set on its own.
  final tiers = <String>{'hit', for (var t = 2; t <= hitTiers; t++) 'hit$t'};
  final recordedTiers = recorded.intersection(tiers);
  if (recordedTiers.isNotEmpty && recordedTiers.length != tiers.length) {
    stderr.writeln(
      'warning: ${recordedTiers.length} of ${tiers.length} hit tiers are '
      'recorded. Supply all of them or none, or the rally will change timbre '
      'as the combo climbs (README "Sound").',
    );
  }
}
