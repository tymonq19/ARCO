import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/foundation.dart';

import '../services/storage.dart';
import 'game_theme.dart';
import 'server_config.dart';

enum AppLanguage { system, en, pl }

enum ControlMode { joystick, tilt, follow }

enum JoystickSide { float, left, right }

/// User preferences, persisted through [Storage]. Every setter writes through
/// and notifies listeners so screens rebuild immediately.
class Settings extends ChangeNotifier {
  Settings(this._storage) {
    _language = _enumFromName(
      AppLanguage.values,
      _storage.getString(_kLanguage),
      AppLanguage.system,
    );
    _sound = _storage.getBool(_kSound) ?? true;
    _haptics = _storage.getBool(_kHaptics) ?? true;
    _menuMotion = _storage.getBool(_kMenuMotion) ?? true;
    _controlMode = _enumFromName(
      ControlMode.values,
      _storage.getString(_kControlMode),
      ControlMode.joystick,
    );
    _tiltSensitivity = (_storage.getDouble(_kTiltSensitivity) ?? 1.0).clamp(
      minTiltSensitivity,
      maxTiltSensitivity,
    );
    _tiltBaseline = _storage.getDouble(_kTiltBaseline) ?? 0.0;
    _joystickSide = _enumFromName(
      JoystickSide.values,
      _storage.getString(_kJoystickSide),
      JoystickSide.float,
    );
    _serverUrl = _storage.getString(_kServerUrl) ?? '';
    // An unknown or missing value resolves to the default look, so an old or
    // corrupt preference can never break a launch.
    _theme = GameThemes.byName(_storage.getString(_kTheme));
    final storedName = _storage.getString(_kPlayerName);
    _playerName = storedName ?? _randomName();
    if (storedName == null) {
      // SPEC 5.1: the nickname is persisted. Write the generated default
      // back immediately, otherwise every launch invents a new name and
      // leaderboard submissions from a player who never edits it differ.
      _storage.setString(_kPlayerName, _playerName);
    }
    // A build that predates the first-launch screen stored a nickname without
    // ever writing this flag, so a missing flag next to a name that was already
    // in the store means "already named themselves" — that player must not be
    // walked through the welcome screen now. The name generated a few lines
    // above does not count: it is written on this very launch, so reading it
    // back later would mark a player onboarded who only ever saw the welcome
    // screen and quit. That is why the answer is written back either way — a
    // first launch persists an explicit `false`, so the next launch reads a
    // decision instead of guessing again from a nickname this build invented.
    final storedOnboarded = _storage.getBool(_kOnboarded);
    _onboarded = storedOnboarded ?? storedName != null;
    if (storedOnboarded == null) {
      _storage.setBool(_kOnboarded, _onboarded);
    }
    // One ball unless the player has asked for two; a stored value from a build
    // that did not have the toggle, or one outside the range the simulation
    // accepts, resolves to the classic game rather than refusing to launch.
    _ballCount = (_storage.getInt(_kBallCount) ?? minBallCount).clamp(
      minBallCount,
      maxBallCount,
    );
    _bestScore = _storage.getInt(_kBestScore) ?? 0;
    _bestScoreTwoBall = _storage.getInt(_kBestScoreTwoBall) ?? 0;
    _playedTwoBall = _storage.getBool(_kPlayedTwoBall) ?? false;
  }

  static const String _kLanguage = 'language';
  static const String _kSound = 'sound';
  static const String _kHaptics = 'haptics';
  static const String _kMenuMotion = 'menuMotion';
  static const String _kControlMode = 'controlMode';
  static const String _kTiltSensitivity = 'tiltSensitivity';
  static const String _kTiltBaseline = 'tiltBaseline';
  static const String _kJoystickSide = 'joystickSide';
  static const String _kServerUrl = 'serverUrl';
  static const String _kTheme = 'theme';
  static const String _kPlayerName = 'playerName';
  static const String _kOnboarded = 'onboarded';
  static const String _kBestScore = 'bestScore';

  /// Balls the next game is played with (SPEC §2.3). Not a look and not a
  /// convenience: it goes into `GameConfig`, so it is part of the replay the
  /// server re-simulates, and it decides which leaderboard a run lands on.
  static const String _kBallCount = 'ballCount';

  /// The two-ball personal best. A separate key, because the two counts are two
  /// games and two boards; `bestScore` keeps meaning the classic one, so a
  /// player upgrading from a build without the toggle keeps their record.
  static const String _kBestScoreTwoBall = 'bestScore2';

  /// Whether a two-ball game has ever been finished on this device. Recorded
  /// rather than inferred from the best score, because a two-ball game that
  /// ended on nought is still a game that was played — and it is what keeps the
  /// leaderboard from opening a newcomer on a board they have no runs on.
  static const String _kPlayedTwoBall = 'played2';

  static const double minTiltSensitivity = 0.5;
  static const double maxTiltSensitivity = 2.5;

  final Storage _storage;

  late AppLanguage _language;
  late bool _sound;
  late bool _haptics;
  late bool _menuMotion;
  late ControlMode _controlMode;
  late double _tiltSensitivity;
  late double _tiltBaseline;
  late JoystickSide _joystickSide;
  late String _serverUrl;
  late GameTheme _theme;
  late String _playerName;
  late bool _onboarded;
  late int _ballCount;
  late int _bestScore;
  late int _bestScoreTwoBall;
  late bool _playedTwoBall;

  AppLanguage get language => _language;
  set language(AppLanguage v) {
    if (v == _language) return;
    _language = v;
    _storage.setString(_kLanguage, v.name);
    notifyListeners();
  }

  bool get sound => _sound;
  set sound(bool v) {
    if (v == _sound) return;
    _sound = v;
    _storage.setBool(_kSound, v);
    notifyListeners();
  }

  bool get haptics => _haptics;
  set haptics(bool v) {
    if (v == _haptics) return;
    _haptics = v;
    _storage.setBool(_kHaptics, v);
    notifyListeners();
  }

  /// Whether the title screen's background moves: the equipped ball drifting
  /// behind the menu, leaning the way the phone is leaned.
  ///
  /// On by default, because an asleep menu is what this is for. Off is a real
  /// answer and not a grudging one: movement behind text is unpleasant for some
  /// people and makes others unwell, and with it off nothing runs and no sensor
  /// is opened. The platform's own reduced-motion request is honoured on top of
  /// this without anybody having to find the switch (see `MenuBallBackdrop`).
  bool get menuMotion => _menuMotion;
  set menuMotion(bool v) {
    if (v == _menuMotion) return;
    _menuMotion = v;
    _storage.setBool(_kMenuMotion, v);
    notifyListeners();
  }

  ControlMode get controlMode => _controlMode;
  set controlMode(ControlMode v) {
    if (v == _controlMode) return;
    _controlMode = v;
    _storage.setString(_kControlMode, v.name);
    notifyListeners();
  }

  /// 0.5 (gentle) … 2.5 (twitchy); 1.0 = ±0.35 rad for full deflection.
  double get tiltSensitivity => _tiltSensitivity;
  set tiltSensitivity(double v) {
    final c = v.clamp(minTiltSensitivity, maxTiltSensitivity);
    if (c == _tiltSensitivity) return;
    _tiltSensitivity = c;
    _storage.setDouble(_kTiltSensitivity, c);
    notifyListeners();
  }

  /// Roll (radians) that counts as "level"; set by CALIBRATE.
  double get tiltBaseline => _tiltBaseline;
  set tiltBaseline(double v) {
    if (v == _tiltBaseline) return;
    _tiltBaseline = v;
    _storage.setDouble(_kTiltBaseline, v);
    notifyListeners();
  }

  JoystickSide get joystickSide => _joystickSide;
  set joystickSide(JoystickSide v) {
    if (v == _joystickSide) return;
    _joystickSide = v;
    _storage.setString(_kJoystickSide, v.name);
    notifyListeners();
  }

  /// The look every screen and the arena renderer draw in.
  GameTheme get theme => _theme;
  set theme(GameTheme v) {
    if (v.id == _theme.id) return;
    _theme = v;
    _storage.setString(_kTheme, v.id.name);
    notifyListeners();
  }

  ThemeId get themeId => _theme.id;
  set themeId(ThemeId v) => theme = GameThemes.byId(v);

  /// Raw override typed in Settings → Advanced; empty = compile-time default.
  String get serverUrl => _serverUrl;
  set serverUrl(String v) {
    final t = v.trim();
    if (t == _serverUrl) return;
    _serverUrl = t;
    _storage.setString(_kServerUrl, t);
    notifyListeners();
  }

  /// Effective HTTP base URL after defaults and platform mapping.
  String get effectiveBaseUrl => ServerConfig.resolveBaseUrl(_serverUrl);

  Uri get wsUrl => ServerConfig.wsUrl(effectiveBaseUrl);

  String get playerName => _playerName;
  set playerName(String v) {
    if (v == _playerName) return;
    _playerName = v;
    _storage.setString(_kPlayerName, v);
    notifyListeners();
  }

  /// False only until the player has been through the first-launch screen,
  /// where they pick a look and a nickname.
  bool get onboarded => _onboarded;
  set onboarded(bool v) {
    if (v == _onboarded) return;
    _onboarded = v;
    _storage.setBool(_kOnboarded, v);
    notifyListeners();
  }

  /// Applies a first-launch choice: the look, the nickname and the flag that
  /// keeps the welcome screen from coming back.
  ///
  /// One notification for the three, so the app shell rebuilds once — and one
  /// place where the three writes cannot drift apart. [name] must already be
  /// normalized (see `normalizeName`).
  void completeOnboarding({required GameTheme theme, required String name}) {
    _theme = theme;
    _storage.setString(_kTheme, theme.id.name);
    _playerName = name;
    _storage.setString(_kPlayerName, name);
    _onboarded = true;
    _storage.setBool(_kOnboarded, true);
    notifyListeners();
  }

  /// Balls the next game is played with, [minBallCount]..[maxBallCount]
  /// (SPEC §2.3).
  ///
  /// It reaches [GameConfig] and therefore the replay, so it is remembered
  /// between launches like a control scheme is — but unlike one it changes the
  /// game, which is why it is offered where a game is about to start and not in
  /// Settings.
  int get ballCount => _ballCount;
  set ballCount(int v) {
    final c = v.clamp(minBallCount, maxBallCount);
    if (c == _ballCount) return;
    _ballCount = c;
    _storage.setInt(_kBallCount, c);
    notifyListeners();
  }

  /// The personal best on the classic, one-ball board.
  int get bestScore => _bestScore;
  set bestScore(int v) {
    if (v == _bestScore) return;
    _bestScore = v;
    _storage.setInt(_kBestScore, v);
    notifyListeners();
  }

  /// The personal best for [balls] balls — one record per board, because a
  /// two-ball run is not competing with a one-ball one.
  int bestScoreFor(int balls) => balls >= 2 ? _bestScoreTwoBall : _bestScore;

  /// True once a game of [balls] balls has been finished on this device. One
  /// ball is always true: it is the game every player has played.
  bool hasPlayed(int balls) => balls >= 2 ? _playedTwoBall : true;

  /// Records that a game of [balls] balls was played to the end, whatever it
  /// scored. Called by the solo controller on game over.
  void notePlayed(int balls) {
    if (balls < 2 || _playedTwoBall) return;
    _playedTwoBall = true;
    _storage.setBool(_kPlayedTwoBall, true);
    notifyListeners();
  }

  /// Records [score] as the personal best for [balls] balls when it beats the
  /// current one. Returns true when a new best was set.
  bool recordScore(int score, {int balls = minBallCount}) {
    if (balls < 2) {
      if (score <= _bestScore) return false;
      bestScore = score;
      return true;
    }
    if (score <= _bestScoreTwoBall) return false;
    _bestScoreTwoBall = score;
    _storage.setInt(_kBestScoreTwoBall, score);
    notifyListeners();
    return true;
  }

  static String _randomName() {
    final r = math.Random();
    return 'Player${r.nextInt(900) + 100}';
  }

  static T _enumFromName<T extends Enum>(List<T> values, String? name, T def) {
    if (name == null) return def;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return def;
  }
}
