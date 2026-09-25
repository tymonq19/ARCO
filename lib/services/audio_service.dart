import 'dart:math' as math;

import 'package:arco_core/arco_core.dart'
    show countdownTicks, maxMultiplier, tickRate;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// What just happened in the game (SPEC §5.7).
///
/// Events, not files: [AudioService] decides which clip an event plays, so a
/// paddle hit can climb in pitch with the combo and the last beep of a duel
/// countdown can be a GO, without every call site having to know.
enum Sfx {
  hit,
  wall,
  star,
  heart,
  lose,
  serve,
  gameover,
  win,
  click,
  countdown,
}

/// Low-latency sound effects backed by `audioplayers`.
///
/// Each clip gets a small pool of pre-loaded players so rapid repeats can
/// overlap, repeats that land too close together are collapsed instead of
/// machine-gunning, and every clip is played at a level from [levelOf] — the
/// assets are all normalised to the same loudness by `tool/gen_sfx.dart`, so
/// that table *is* the mix.
///
/// [init] is best-effort: when the platform plugin is unavailable (tests,
/// unsupported platform) the service silently no-ops.
class AudioService {
  AudioService({
    this.muted = false,
    this.playersPerSfx = 3,
    Duration Function()? clock,
  }) : _clock = clock ?? _monotonic();

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// Upper bound on the players kept per clip; see [poolSizeFor].
  final int playersPerSfx;

  final Duration Function() _clock;
  final Map<String, _SfxPool> _pools = {};
  final Map<String, Duration> _lastPlay = {};
  final Map<String, int> _repeats = {};

  /// When true [play] does nothing; mirrors the Settings sound switch.
  bool muted;
  bool _initialized = false;
  bool _disposed = false;
  int _rallyHits = 0;
  int _countdownIndex = 0;
  Duration? _lastCountdown;
  int _dispatched = 0;

  /// True once at least one clip has loaded.
  bool get ready => _pools.isNotEmpty;

  /// Clips whose pool loaded. Only a device can say whether the platform plugin
  /// accepted all of them, so `integration_test/audio_test.dart` asserts on it.
  @visibleForTesting
  int get loadedClips => _pools.length;

  /// Players actually held open across every pool.
  @visibleForTesting
  int get loadedPlayers =>
      _pools.values.fold<int>(0, (sum, pool) => sum + pool.size);

  // ------------------------------------------------------------------- clips

  /// The GO that ends the countdown.
  static const String goClip = 'countdown_go';

  /// The paddle-hit clip for a score multiplier: `hit` at ×1, then one
  /// pre-rendered pitch tier per step up to `maxMultiplier`.
  static String hitClip(int multiplier) =>
      multiplier <= 1 ? 'hit' : 'hit$multiplier';

  /// The clip an event plays when nothing else is going on.
  static String baseClip(Sfx sfx) => sfx.name;

  /// Every clip, in load order: what the player can hear first loads first, so
  /// a menu tap or the opening serve is never silent while the long jingles are
  /// still being decoded.
  ///
  /// One set, all four themes. Neon, Classic, Modernist and Glass are palette
  /// and stroke systems (`GameTheme`), not different materials: the ball and the
  /// paddle are the same simulated objects in each, so there is nothing for a
  /// timbre to follow. And these effects are information before they are
  /// decoration — `wall` sits an octave and a fifth under `hit` so the ear can
  /// tell a wall from a paddle without looking, `star` and `heart` are built as
  /// opposites in register and attack so a pickup is identifiable in peripheral
  /// hearing, and the eight `hit` tiers are the combo read-out. A cosmetic that
  /// can be equipped between two rallies must not retune that. See README
  /// "Sound" for the cost of the alternative.
  static List<String> get clips => <String>[
    'click',
    'hit',
    'wall',
    'serve',
    'star',
    'heart',
    'lose',
    'countdown',
    goClip,
    for (var m = 2; m <= maxMultiplier; m++) hitClip(m),
    'gameover',
    'win',
  ];

  /// Asset path (relative to `assets/`) of a clip.
  static String assetPathOf(String clip) => 'sfx/$clip.wav';

  /// Asset path of an event's base clip.
  static String assetPath(Sfx sfx) => assetPathOf(baseClip(sfx));

  // --------------------------------------------------------------------- mix

  /// Summing headroom for the whole effect bus, -3.1 dB.
  ///
  /// `audioplayers` offers a per-player volume and nothing else: there is no bus
  /// to put a limiter across, so the only way to keep two events that land in
  /// the same frame out of the converter's ceiling is to leave room. One core
  /// tick can carry a wall bounce, a paddle hit *and* a pickup — three
  /// independent checks in `Simulation.step` — and at the raw [balanceOf]
  /// balance those three sum to +2.2 dBFS, measured on the real assets. 0.7
  /// puts the worst reachable stack at -0.9 dBFS. `sfx_assets_test.dart` re-runs
  /// that measurement, so a change to the table or to an asset that spends the
  /// headroom fails the suite.
  static const double headroom = 0.7;

  /// Playback level per clip: [headroom] times [balanceOf].
  static double levelOf(String clip) => headroom * balanceOf(clip);

  /// Relative balance per clip, before [headroom].
  ///
  /// Every asset is normalised to the same perceived loudness, so this is the
  /// entire mix. The numbers come from measuring each file twice — full band
  /// and through a 450 Hz high-pass that stands in for a phone speaker — and
  /// then choosing how loud the event should *feel* on a phone relative to a
  /// paddle hit: the dull ones (`wall`, `lose`, `gameover`) lose low end a
  /// phone cannot reproduce and are given it back here, while `click` and
  /// `serve` are pushed well down because they fire constantly and must never
  /// draw attention.
  @visibleForTesting
  static double balanceOf(String clip) {
    if (clip.startsWith('hit')) return 0.62;
    return switch (clip) {
      'wall' => 0.9,
      'star' => 0.78,
      'heart' => 0.78,
      'lose' => 1.0,
      'serve' => 0.42,
      'gameover' => 1.0,
      'win' => 0.95,
      'click' => 0.3,
      'countdown' => 0.5,
      goClip => 0.62,
      _ => 0.7,
    };
  }

  /// Per-effect gain, keyed by event rather than clip.
  static double gain(Sfx sfx) => levelOf(baseClip(sfx));

  /// Players kept for a clip.
  ///
  /// A rally cannot overlap two paddle hits of the *same* tier by much — the
  /// ball crosses the arena in at least ~115 ms and the clip is 86 ms — but in
  /// a duel both paddles can be struck within a few frames, so the hit tiers
  /// get two. The walls and the UI click can genuinely double up; the long
  /// one-shots (`gameover`, `win`, the GO) can only ever play alone.
  static int poolSizeFor(String clip) {
    if (clip.startsWith('hit')) return 2;
    return switch (clip) {
      'wall' || 'click' => 3,
      'star' || 'heart' || 'serve' || 'countdown' || 'lose' => 2,
      _ => 1,
    };
  }

  /// Two of the same clip closer together than this are one event to the ear,
  /// so the second is dropped. Without it a frame that lands two paddle hits
  /// and a wall bounce sounds like a machine gun (and stacks 6 dB of level).
  static Duration collapseWindow(String clip) {
    if (clip.startsWith('hit')) return const Duration(milliseconds: 28);
    return switch (clip) {
      'wall' => const Duration(milliseconds: 45),
      'click' => const Duration(milliseconds: 55),
      'star' || 'heart' || 'serve' => const Duration(milliseconds: 90),
      'lose' || 'countdown' => const Duration(milliseconds: 140),
      goClip => const Duration(milliseconds: 200),
      _ => const Duration(milliseconds: 300),
    };
  }

  /// A repeat inside this window is trimmed by [_repeatTrim] so a burst of the
  /// same sound does not build up, and two identical samples never play at
  /// exactly the same level twice in a row.
  static const Duration repeatWindow = Duration(milliseconds: 350);
  static const List<double> _repeatTrim = <double>[1.0, 0.92, 0.85, 0.92];

  /// The score multiplier a rally of [hits] consecutive paddle hits is worth:
  /// the same formula as `Player.multiplier` in the core.
  static int multiplierFor(int hits) => math.min(1 + hits ~/ 5, maxMultiplier);

  /// Beeps before the GO: the duel countdown is [countdownTicks] core ticks and
  /// the controller plays one beep per whole second left, then one more at zero.
  static const int countdownBeeps = countdownTicks ~/ tickRate;

  /// A countdown beep this long after the previous one starts a new sequence
  /// (a rematch), rather than continuing the old one.
  static const Duration countdownGap = Duration(milliseconds: 1600);

  /// Consecutive paddle hits heard since the rally started.
  @visibleForTesting
  int get rallyHits => _rallyHits;

  /// How many clips have actually been handed to a pool. Test-only window on
  /// the mute and collapse decisions.
  @visibleForTesting
  int get dispatched => _dispatched;

  // ------------------------------------------------------------------ playing

  /// Preloads every clip. Safe to call more than once. Not awaited by `main`,
  /// so the first frame never waits on the audio plugin.
  Future<void> init() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContextConfig(
          focus: AudioContextConfigFocus.mixWithOthers,
        ).build(),
      );
    } on Object catch (e) {
      debugPrint('AudioService: audio context not applied: $e');
    }
    for (final clip in clips) {
      if (_disposed) return;
      try {
        final size = math.min(poolSizeFor(clip), playersPerSfx);
        _pools[clip] = await _SfxPool.create(assetPathOf(clip), size);
      } on Object catch (e) {
        debugPrint('AudioService: could not load $clip: $e');
      }
    }
  }

  /// Plays an effect (fire-and-forget). No-op while muted or not loaded.
  void play(Sfx sfx, {double volume = 1.0}) {
    if (_disposed) return;
    // The rally and countdown are tracked even while muted, so unmuting
    // mid-game lands on the right pitch instead of restarting the build.
    final clip = resolve(sfx);
    if (muted) return;
    final level = levelFor(clip, volume);
    if (level == null) return;
    _dispatched++;
    _pools[clip]?.play(level);
  }

  /// The clip [sfx] plays right now, advancing the rally and countdown state.
  ///
  /// A paddle hit climbs a pentatonic scale with the score multiplier, so a
  /// long rally audibly builds; the controllers call `play(Sfx.hit)` with no
  /// context, so the rally is counted here and reset by exactly what resets the
  /// combo in the core — a life lost, a serve, the end of a game. (In a duel
  /// both paddles feed the same counter, so the pitch tracks the rally rather
  /// than one player's multiplier, which is what a duel rally sounds like.)
  @visibleForTesting
  String resolve(Sfx sfx) {
    switch (sfx) {
      case Sfx.hit:
        _rallyHits++;
        return hitClip(multiplierFor(_rallyHits));
      case Sfx.countdown:
        final now = _clock();
        final last = _lastCountdown;
        if (last == null || now - last > countdownGap) _countdownIndex = 0;
        _lastCountdown = now;
        _rallyHits = 0;
        final index = _countdownIndex++;
        return index < countdownBeeps ? 'countdown' : goClip;
      case Sfx.serve:
      case Sfx.lose:
      case Sfx.gameover:
      case Sfx.win:
        _rallyHits = 0;
        return sfx.name;
      case Sfx.wall:
      case Sfx.star:
      case Sfx.heart:
      case Sfx.click:
        return sfx.name;
    }
  }

  /// The volume [clip] should play at now, or null when it is a repeat close
  /// enough to the previous one to collapse into it.
  @visibleForTesting
  double? levelFor(String clip, double volume) {
    final now = _clock();
    final last = _lastPlay[clip];
    if (last != null && now - last < collapseWindow(clip)) return null;
    var trim = 1.0;
    if (last != null && now - last < repeatWindow) {
      final index = (_repeats[clip] ?? 0) + 1;
      _repeats[clip] = index;
      trim = _repeatTrim[index % _repeatTrim.length];
    } else {
      _repeats[clip] = 0;
    }
    _lastPlay[clip] = now;
    return (levelOf(clip) * volume * trim).clamp(0.0, 1.0);
  }

  Future<void> dispose() async {
    _disposed = true;
    final pools = _pools.values.toList();
    _pools.clear();
    for (final p in pools) {
      await p.dispose();
    }
  }
}

class _SfxPool {
  _SfxPool._(this._players);

  final List<AudioPlayer> _players;
  int _next = 0;

  int get size => _players.length;

  static Future<_SfxPool> create(String asset, int count) async {
    final players = <AudioPlayer>[];
    try {
      for (var i = 0; i < count; i++) {
        final p = AudioPlayer();
        await p.setPlayerMode(PlayerMode.lowLatency);
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setSource(AssetSource(asset));
        players.add(p);
      }
    } on Object {
      for (final p in players) {
        await p.dispose();
      }
      rethrow;
    }
    return _SfxPool._(players);
  }

  void play(double volume) {
    final p = _players[_next];
    _next = (_next + 1) % _players.length;
    _trigger(p, volume);
  }

  Future<void> _trigger(AudioPlayer p, double volume) async {
    try {
      await p.stop();
      await p.setVolume(volume);
      await p.resume();
    } on Object catch (e) {
      debugPrint('AudioService: play failed: $e');
    }
  }

  Future<void> dispose() async {
    for (final p in _players) {
      try {
        await p.dispose();
      } on Object {
        // Ignore disposal errors; the app is shutting down.
      }
    }
  }
}
