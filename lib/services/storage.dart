import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A solo game recorded while offline (or whose upload failed), kept until the
/// leaderboard accepts or definitively rejects it.
class PendingReplay {
  const PendingReplay({required this.name, required this.replay});

  final String name;
  final Replay replay;

  Map<String, dynamic> toJson() => {'name': name, 'replay': replay.toJson()};

  factory PendingReplay.fromJson(Map<String, dynamic> j) => PendingReplay(
    name: j['name'] as String,
    replay: Replay.fromJson(j['replay'] as Map<String, dynamic>),
  );
}

/// Thin synchronous wrapper over shared_preferences. Loaded once at startup;
/// writes are fire-and-forget (the in-memory cache updates immediately).
class Storage {
  Storage._(this._prefs);

  static const String _kPendingReplay = 'pendingReplay';
  static const String _kOwnScoreIds = 'ownScoreIds';
  static const String _kOwnScoreKeys = 'ownScoreKeys';
  static const String _kPlayerCountry = 'playerCountry';
  static const String _kOfferDismissals = 'accountOfferDismissals';
  static const String _kOfferDismissedAt = 'accountOfferDismissedAt';
  static const String _kShopCache = 'shopCache';
  static const String _kShopPendingEquip = 'shopPendingEquip';

  /// Keep only the most recent own entries; more than this never matters for
  /// a top-100 highlight.
  static const int maxOwnEntries = 200;

  final SharedPreferences _prefs;

  static Future<Storage> load() async =>
      Storage._(await SharedPreferences.getInstance());

  String? getString(String key) => _prefs.getString(key);
  int? getInt(String key) => _prefs.getInt(key);
  bool? getBool(String key) => _prefs.getBool(key);
  double? getDouble(String key) => _prefs.getDouble(key);

  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);
  Future<void> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);
  Future<void> remove(String key) => _prefs.remove(key);

  // ---------------------------------------------------------------- pending

  PendingReplay? get pendingReplay {
    final raw = _prefs.getString(_kPendingReplay);
    if (raw == null) return null;
    try {
      return PendingReplay.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      // Corrupt entry from an older build: drop it rather than crash forever.
      _prefs.remove(_kPendingReplay);
      return null;
    }
  }

  Future<void> setPendingReplay(PendingReplay? pending) {
    if (pending == null) return _prefs.remove(_kPendingReplay);
    return _prefs.setString(_kPendingReplay, jsonEncode(pending.toJson()));
  }

  /// Re-files the stored replay under [name], keeping the game itself.
  ///
  /// The one thing that can be wrong with a replay the server refused is the
  /// nickname on it (SPEC §4.7): the run was verified, so the player picks
  /// another name and the same game goes up under it.
  Future<void> renamePendingReplay(String name) async {
    final pending = pendingReplay;
    if (pending == null || pending.name == name) return;
    await setPendingReplay(PendingReplay(name: name, replay: pending.replay));
  }

  // ---------------------------------------------------------------- country

  /// The country the server has filed one of this player's runs under
  /// (SPEC §4.6), or null while none is known. Not a secret and not a claim
  /// about where anybody is - it is the ISO 3166-1 alpha-2 code derived from
  /// the device locale that a submission was accepted with.
  String? get playerCountry => _prefs.getString(_kPlayerCountry);

  Future<void> setPlayerCountry(String? code) => code == null || code.isEmpty
      ? _prefs.remove(_kPlayerCountry)
      : _prefs.setString(_kPlayerCountry, code);

  // ------------------------------------------------------------- account offer

  /// How many times the player has waved the sign-in offer away (SPEC §4.5).
  /// The count, not just the date: the second refusal means something different
  /// from the first, and a third means "never".
  int get accountOfferDismissals => _prefs.getInt(_kOfferDismissals) ?? 0;

  /// When the last dismissal happened, in milliseconds since the epoch (UTC).
  DateTime? get accountOfferDismissedAt {
    final raw = _prefs.getInt(_kOfferDismissedAt);
    return raw == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
  }

  Future<void> setAccountOfferDismissal(int count, DateTime at) async {
    await _prefs.setInt(_kOfferDismissals, count);
    await _prefs.setInt(_kOfferDismissedAt, at.toUtc().millisecondsSinceEpoch);
  }

  // ----------------------------------------------------------------- shop

  /// The last thing the **server** said about the wallet, the items and the
  /// equipped slots (SPEC §4.8), as `ShopSnapshot` writes it.
  ///
  /// It is a cache, not a source of truth: the server decides what is owned and
  /// what a token buys, and this is only what it last answered. It exists so the
  /// game opens wearing the right skin before any request finishes — and so it
  /// keeps wearing it on a phone that has no network at all.
  Map<String, dynamic>? get shopCache {
    final raw = _prefs.getString(_kShopCache);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? json : null;
    } on Object {
      // Written by an older build, or truncated: drop it rather than fail every
      // launch from now on. The next successful call rewrites it.
      _prefs.remove(_kShopCache);
      return null;
    }
  }

  Future<void> setShopCache(Map<String, dynamic>? snapshot) => snapshot == null
      ? _prefs.remove(_kShopCache)
      : _prefs.setString(_kShopCache, jsonEncode(snapshot));

  /// Slot choices made while the server could not be reached, waiting to be
  /// pushed (`kind` → item id).
  ///
  /// Switching between two looks the player already owns has to work on a plane,
  /// and it has to survive the flight: without this the next successful sync
  /// would hand back the server's older choice and silently undress them.
  Map<String, String> get shopPendingEquip {
    final raw = _prefs.getString(_kShopPendingEquip);
    if (raw == null) return const <String, String>{};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const <String, String>{};
      return <String, String>{
        for (final entry in json.entries)
          if (entry.value is String && (entry.value as String).isNotEmpty)
            '${entry.key}': entry.value as String,
      };
    } on Object {
      _prefs.remove(_kShopPendingEquip);
      return const <String, String>{};
    }
  }

  Future<void> setShopPendingEquip(Map<String, String> slots) => slots.isEmpty
      ? _prefs.remove(_kShopPendingEquip)
      : _prefs.setString(_kShopPendingEquip, jsonEncode(slots));

  // ---------------------------------------------------------------- own scores

  /// Ids returned by `POST /api/scores` for this device's submissions.
  List<String> get ownScoreIds =>
      List.unmodifiable(_prefs.getStringList(_kOwnScoreIds) ?? const []);

  /// `name|score` keys of own submissions; used to highlight leaderboard rows
  /// when the server does not echo entry ids.
  List<String> get ownScoreKeys =>
      List.unmodifiable(_prefs.getStringList(_kOwnScoreKeys) ?? const []);

  static String scoreKey(String name, int score) => '$name|$score';

  Future<void> addOwnScore({
    required String id,
    required String name,
    required int score,
  }) async {
    final ids = [...ownScoreIds, id];
    final keys = [...ownScoreKeys, scoreKey(name, score)];
    if (ids.length > maxOwnEntries) {
      ids.removeRange(0, ids.length - maxOwnEntries);
    }
    if (keys.length > maxOwnEntries) {
      keys.removeRange(0, keys.length - maxOwnEntries);
    }
    await _prefs.setStringList(_kOwnScoreIds, ids);
    await _prefs.setStringList(_kOwnScoreKeys, keys);
  }

  /// Drops the memory of which leaderboard rows this device submitted.
  ///
  /// Part of deleting a player (SPEC §4.5): the server anonymises the rows, and
  /// this is the other half of the same promise — the phone stops claiming them
  /// too. The rows themselves stay on the board, as they must.
  Future<void> forgetOwnScores() async {
    await _prefs.remove(_kOwnScoreIds);
    await _prefs.remove(_kOwnScoreKeys);
  }

  bool isOwnScore({String? id, required String name, required int score}) {
    if (id != null && ownScoreIds.contains(id)) return true;
    return ownScoreKeys.contains(scoreKey(name, score));
  }
}
