import 'dart:math' as math;

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
    _bestScore = _storage.getInt(_kBestScore) ?? 0;
  }

  static const String _kLanguage = 'language';
  static const String _kSound = 'sound';
  static const String _kHaptics = 'haptics';
  static const String _kControlMode = 'controlMode';
  static const String _kTiltSensitivity = 'tiltSensitivity';
  static const String _kTiltBaseline = 'tiltBaseline';
  static const String _kJoystickSide = 'joystickSide';
  static const String _kServerUrl = 'serverUrl';
  static const String _kTheme = 'theme';
  static const String _kPlayerName = 'playerName';
  static const String _kOnboarded = 'onboarded';
  static const String _kBestScore = 'bestScore';

  static const double minTiltSensitivity = 0.5;
  static const double maxTiltSensitivity = 2.5;

  final Storage _storage;

  late AppLanguage _language;
  late bool _sound;
  late bool _haptics;
  late ControlMode _controlMode;
  late double _tiltSensitivity;
  late double _tiltBaseline;
  late JoystickSide _joystickSide;
  late String _serverUrl;
  late GameTheme _theme;
  late String _playerName;
  late bool _onboarded;
  late int _bestScore;

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

  int get bestScore => _bestScore;
  set bestScore(int v) {
    if (v == _bestScore) return;
    _bestScore = v;
    _storage.setInt(_kBestScore, v);
    notifyListeners();
  }

  /// Records [score] as the personal best when it beats the current one.
  /// Returns true when a new best was set.
  bool recordScore(int score) {
    if (score <= _bestScore) return false;
    bestScore = score;
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
