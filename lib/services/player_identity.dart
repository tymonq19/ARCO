import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'device_country.dart';
import 'secret_store.dart';
import 'storage.dart';

/// Who the player is, as far as the leaderboard is concerned (SPEC §4.4), and
/// where they play (SPEC §4.6).
///
/// The identity is **invisible plumbing**: there is no sign-in, no prompt and
/// nothing to agree to. A player is issued lazily — the first time a score is
/// actually submitted, never at launch — so a player who only ever plays offline
/// costs the server nothing, and every failure on this path degrades to an
/// anonymous submission instead of an error the player has to read.
///
/// A [ChangeNotifier] because two screens watch it: the leaderboard highlights
/// the rows the player owns, and the home screen shows the standing that
/// [profile] carries.
class PlayerIdentity extends ChangeNotifier {
  PlayerIdentity({
    required this.api,
    required this.storage,
    required SecretStore secrets,
    String? Function()? deviceCountry,
    DateTime Function()? now,
    this.profileTtl = const Duration(minutes: 5),
  }) : _secrets = secrets,
       _deviceCountry = deviceCountry ?? DeviceCountry.current,
       _now = now ?? DateTime.now;

  /// Keychain keys. The id is not a secret, but it lives beside the secret it
  /// belongs to so the two can never drift apart across a reinstall.
  static const String idKey = 'arco.player.id';
  static const String secretKey = 'arco.player.secret';

  /// How long to wait after an issue that failed for a reason of its own
  /// (offline, 5xx, a malformed answer) before trying again. Long enough that a
  /// string of finished games cannot turn into a request loop.
  static const Duration issueBackoff = Duration(seconds: 30);

  /// Fallback wait for a `429` that carried no `retry-after`; SPEC §4.4 budgets
  /// 10 issues per IP per minute.
  static const Duration rateLimitedBackoff = Duration(minutes: 1);

  final ApiClient api;
  final Storage storage;
  final SecretStore _secrets;
  final String? Function() _deviceCountry;
  final DateTime Function() _now;

  /// How long a fetched [profile] is reused before a screen re-reads it. There
  /// is no polling: it is refreshed when a screen that shows it opens, and
  /// invalidated when a score is accepted.
  final Duration profileTtl;

  PlayerCredentials? _credentials;

  /// Bumped by every deliberate change to who this device is: a sign-out, a
  /// link, a merged id.
  ///
  /// A keychain read and a server call are both answered long after they are
  /// made, and a platform keychain answers **in call order** — so the read
  /// issued a moment before a sign-out comes back *after* it, still carrying
  /// the credential the player just asked to be rid of. Applying that answer
  /// would leave the phone signed out on screen and signed in on the wire, and
  /// the mirror image loses a sign-in that the server has already accepted. An
  /// answer whose epoch has moved on describes a player we are no longer, so it
  /// is dropped rather than applied.
  int _epoch = 0;
  bool _loaded = false;
  bool _secretsUsable = true;
  Future<void>? _loading;
  Future<PlayerCredentials?>? _issuing;
  DateTime? _issueBlockedUntil;
  PlayerProfile? _profile;
  DateTime? _profileAt;
  Future<PlayerProfile?>? _profileCall;
  String? _refusedCountry;

  /// The stored player id once it is known, null while the player is anonymous.
  String? get playerId => _credentials?.id;

  bool get isIdentified => _credentials != null;

  /// False once the keychain has turned out to be unusable (the web build, a
  /// platform without the plugin, a keychain that refuses to be written). No
  /// identity is issued then: a credential we cannot keep is worse than none,
  /// and the submission simply goes out anonymously.
  bool get canStoreSecret => _secretsUsable;

  /// The player's standing, from the last `GET /api/players/me`; null until one
  /// has succeeded.
  PlayerProfile? get profile => _profile;

  /// The country whose leaderboard is this player's own (SPEC §4.6): the code
  /// the server has accepted for one of their runs, or the device's own until
  /// one has been. Null hides everything national.
  String? get country {
    final remembered = storage.playerCountry;
    if (remembered != null) return remembered;
    final derived = _deviceCountry();
    return derived == null || derived == _refusedCountry ? null : derived;
  }

  /// The code to attach to a submission, re-derived from the device locale every
  /// time (SPEC §4.6): it is a hint about where this run was played, so a phone
  /// that has moved country reports the new one. Null sends none.
  String? countryForSubmission() => _deviceCountry();

  /// Reads the stored credential. Cheap and idempotent; concurrent callers share
  /// the one read.
  Future<PlayerCredentials?> load() async {
    if (_loaded) return _credentials;
    await (_loading ??= _load());
    return _credentials;
  }

  Future<void> _load() async {
    final epoch = _epoch;
    try {
      final id = await _secrets.read(idKey);
      final secret = await _secrets.read(secretKey);
      // Answered after a sign-out or a link: see [_epoch]. The half-credential
      // cleanup below is skipped with it, because by now that half may be the
      // new credential's.
      if (epoch != _epoch) return;
      if (PlayerCredentials.wellFormed(id, secret)) {
        _credentials = PlayerCredentials(id: id!, secret: secret!);
      } else if (id != null || secret != null) {
        // Half a credential authenticates nothing, and a truncated secret only
        // buys a guaranteed 401: drop it and let the next submission issue a
        // fresh identity.
        await _wipe();
      }
    } on Object {
      // No keychain here. Nothing is said to the player: they keep playing and
      // their scores go to the board anonymously, which SPEC §4.4 allows.
      _secretsUsable = false;
    } finally {
      _loaded = true;
      _loading = null;
    }
    if (_credentials != null) notifyListeners();
  }

  /// The credential to submit with, issuing one on first use.
  ///
  /// Returns null — meaning "submit anonymously" — when there is nowhere to keep
  /// a secret, when an earlier issue asked us to wait, or when this one failed.
  /// The player is never told about any of that.
  Future<PlayerCredentials?> ensureIssued() async {
    await load();
    if (_credentials != null) return _credentials;
    if (!_secretsUsable) return null;
    final pending = _issuing;
    if (pending != null) return pending;
    final blockedUntil = _issueBlockedUntil;
    if (blockedUntil != null && _now().isBefore(blockedUntil)) return null;
    final call = _issue();
    _issuing = call;
    return call.whenComplete(() => _issuing = null);
  }

  Future<PlayerCredentials?> _issue() async {
    final epoch = _epoch;
    try {
      final issued = await api.createPlayer();
      // Signed out (or signed in) while this was in flight: the player just
      // issued is one nobody asked to be, so it is abandoned rather than stored.
      if (epoch != _epoch) return null;
      _credentials = issued;
      await _store(issued);
      notifyListeners();
      return issued;
    } on ApiException catch (e) {
      // A 429 waits exactly as long as the server asked; everything else waits
      // [issueBackoff], so a retry is a retry and never a loop.
      _issueBlockedUntil = _now().add(
        e.kind == ApiErrorKind.rateLimited
            ? (e.retryAfter ?? rateLimitedBackoff)
            : issueBackoff,
      );
      return null;
    } on Object {
      _issueBlockedUntil = _now().add(issueBackoff);
      return null;
    }
  }

  /// The stored secret was refused (`401 invalid_credentials`): forget it and
  /// issue a fresh identity. Null means the resubmission goes out anonymously —
  /// the score still lands, which is the only thing that matters here.
  Future<PlayerCredentials?> reissue() async {
    await forget();
    return ensureIssued();
  }

  /// Drops the stored credential and everything derived from it.
  Future<void> forget() async {
    _epoch++;
    _credentials = null;
    _profile = null;
    _profileAt = null;
    _loaded = true;
    await _wipe();
    notifyListeners();
  }

  /// Stores [credentials] as this device's identity, replacing whatever is
  /// there.
  ///
  /// SPEC §4.5: `POST /api/account/link` always issues a **new** credential, and
  /// on a merge the surviving player may be a different id than the one that was
  /// sent — so both halves are replaced together and everything derived from the
  /// old identity (the cached standing) is dropped.
  Future<void> adopt(PlayerCredentials credentials) async {
    _epoch++;
    _credentials = credentials;
    _loaded = true;
    _profile = null;
    _profileAt = null;
    await _store(credentials);
    notifyListeners();
  }

  /// Installs a standing the app already has in hand as the cached one.
  ///
  /// `POST /api/account/link` answers with the same figures `GET /api/players/me`
  /// would (SPEC §4.5), so a link costs no extra round trip — and its answer is
  /// the only correct one after a merge, which moved runs between two players.
  /// Ignored when it describes somebody else.
  void adoptProfile(PlayerProfile profile) {
    if (profile.id != _credentials?.id) return;
    _profile = profile;
    _profileAt = _now();
    notifyListeners();
  }

  /// Stores [id] in place of the one we hold, keeping the secret.
  ///
  /// SPEC §4.4: an id absorbed by a merge (§4.5) still authenticates, and
  /// resolves to the surviving player — so whatever the server calls us is what
  /// we store from then on.
  Future<void> adoptServerId(String? id) async {
    final current = _credentials;
    if (id == null || current == null || id == current.id) return;
    if (!PlayerCredentials.wellFormed(id, current.secret)) return;
    _epoch++;
    _credentials = PlayerCredentials(id: id, secret: current.secret);
    try {
      await _secrets.write(idKey, id);
    } on Object {
      _secretsUsable = false;
    }
    notifyListeners();
  }

  /// Remembers a country the **server** filed a run under; an unusable hint is
  /// dropped server side and therefore never remembered here.
  Future<void> rememberCountry(String? code) async {
    if (code == null || code == storage.playerCountry) return;
    if (_refusedCountry == code) _refusedCountry = null;
    await storage.setPlayerCountry(code);
    notifyListeners();
  }

  /// `GET /api/leaderboard?country=…` refused [code] as not an ISO 3166-1
  /// alpha-2 code (SPEC §4.6). The national board is hidden rather than shown
  /// broken, and the code is not asked about again.
  void countryRefused(String code) {
    if (_refusedCountry == code) return;
    _refusedCountry = code;
    notifyListeners();
  }

  /// Applies what a `201` from `POST /api/scores` says about identity: the
  /// player the run was filed under (which a merge may have changed), the
  /// country it counts for, and the fact that the standing has moved.
  Future<void> applySubmission(SubmitResult result) async {
    if (!result.ok) return;
    await adoptServerId(result.playerId);
    await rememberCountry(result.country);
    // Invalidate rather than re-read: the next screen that shows a rank fetches
    // it, and a screen that shows none costs nothing.
    _profileAt = null;
  }

  /// Fetches the player's standing, reusing a fetch younger than [profileTtl].
  /// Returns null while the player is anonymous — there is nothing to ask about
  /// yet, and asking must never issue an identity.
  Future<PlayerProfile?> refreshProfile({bool force = false}) async {
    await load();
    final credentials = _credentials;
    if (credentials == null) return null;
    final at = _profileAt;
    if (!force && at != null && _now().difference(at) < profileTtl) {
      return _profile;
    }
    final pending = _profileCall;
    if (pending != null) return pending;
    final call = _fetchProfile(credentials);
    _profileCall = call;
    return call.whenComplete(() => _profileCall = null);
  }

  Future<PlayerProfile?> _fetchProfile(PlayerCredentials credentials) async {
    final epoch = _epoch;
    try {
      final profile = await api.playerMe(credentials);
      // The standing of a player this device has since stopped being: showing
      // it would put a rank on the home screen for somebody who signed out.
      if (epoch != _epoch) return null;
      _profile = profile;
      _profileAt = _now();
      await adoptServerId(profile.id);
      await rememberCountry(profile.country);
      notifyListeners();
      return profile;
    } on ApiException catch (e) {
      // A refused credential is the one answer worth acting on: the secret is
      // gone (a deleted account, a rebuilt database), so the device goes back to
      // being anonymous and the next submission issues a new identity.
      if (e.isUnauthorized) await forget();
      return null;
    } on Object {
      return null;
    }
  }

  /// Whether [entry] is one of this device's runs (SPEC §4.4).
  ///
  /// The server's `playerId` decides whenever it is there — a row it says
  /// belongs to another player is not ours even when the name and the score
  /// coincide. A row without one is anonymous: every row stored before player
  /// identity existed, and this device's own runs from before it had one. Those
  /// fall back to the submissions [Storage] remembers.
  bool owns(LeaderboardEntry entry) {
    final entryPlayer = entry.playerId;
    if (entryPlayer != null) {
      final mine = playerId;
      return mine != null && entryPlayer == mine;
    }
    return storage.isOwnScore(
      id: entry.id,
      name: entry.name,
      score: entry.score,
    );
  }

  Future<void> _store(PlayerCredentials credentials) async {
    try {
      await _secrets.write(idKey, credentials.id);
      await _secrets.write(secretKey, credentials.secret);
    } on Object {
      // The write failed: this run still counts for the player just issued (the
      // credential is in memory), but nothing is promised past this launch, and
      // no second player is issued in the meantime.
      _secretsUsable = false;
    }
  }

  Future<void> _wipe() async {
    try {
      await _secrets.delete(idKey);
      await _secrets.delete(secretKey);
    } on Object {
      _secretsUsable = false;
    }
  }
}
