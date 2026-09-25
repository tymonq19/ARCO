/// Anonymous player identity (SPEC §4.4): issuing a player, authenticating one
/// and reporting what it owns.
///
/// The product rule this exists to serve is that the game stays fully playable
/// with no account and no sign-in prompt. A player is therefore *issued*, not
/// registered: the client asks for one whenever it decides it wants its scores
/// to survive (typically after a run worth keeping, never on first launch),
/// stores the returned secret, and from then on submits with it. Nothing about
/// a player is supplied by the user except, optionally, the display name they
/// were already typing into the leaderboard.
///
/// The secret is treated as a password: generated from [Random.secure], stored
/// only as a salted digest, compared in constant time, and returned exactly
/// once — at issue time — because the server cannot recover it afterwards.
///
/// A player may hold **several** credentials, one per device: signing in to an
/// account on a second phone issues a credential there and leaves the first
/// phone's alone (SPEC §4.5), which is the only way both can go on playing as
/// the same person. Authentication therefore checks the offered secret against
/// every credential the named player holds.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'db.dart';
import 'logging.dart';
import 'score_store.dart';

/// `Authorization` scheme carrying player credentials (SPEC §4.4).
///
/// A custom scheme rather than `Bearer`: the credential is a pair, it is not an
/// OAuth token, and naming it plainly keeps the account layer free to add a
/// real `Bearer` token later without either meaning the other.
const String playerAuthScheme = 'Arco';

/// No credentials at all on an endpoint that requires them.
const String missingCredentialsError = 'missing_credentials';

/// Credentials that are malformed, name no player, or carry a wrong secret.
/// The three are deliberately indistinguishable to the caller.
const String invalidCredentialsError = 'invalid_credentials';

/// `Authorization: Arco <playerId>:<secret>`.
///
/// One header covers reads and writes, leaves request bodies alone (the score
/// body is a replay and is parsed on another isolate), and keeps the secret out
/// of the URL, where it would end up in access logs. `<playerId>` is 32
/// lowercase hex characters; `<secret>` is base64url without padding, so the
/// `:` separator can never occur inside either half.
class PlayerCredentials {
  const PlayerCredentials({required this.id, required this.secret});

  final String id;
  final String secret;

  static final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');
  static final RegExp _secretPattern = RegExp(r'^[A-Za-z0-9_-]{16,128}$');

  /// Whether [id] has the shape a server-issued player id has: 32 lowercase hex
  /// characters.
  ///
  /// Exposed so that the one other place that has to recognise a player id —
  /// mapping a RevenueCat app user id back to a player (SPEC §4.9) — asks this
  /// rather than carrying a second copy of the pattern that could drift from it.
  static bool isPlayerId(String id) => _idPattern.hasMatch(id);

  /// Parses the header value, or returns null when it is not credentials of
  /// this scheme in the exact documented shape. Nothing is looked up here, so
  /// a junk header costs no database work.
  static PlayerCredentials? parse(String? header) {
    if (header == null) return null;
    final raw = header.trim();
    final space = raw.indexOf(' ');
    if (space < 0) return null;
    if (raw.substring(0, space).toLowerCase() !=
        playerAuthScheme.toLowerCase()) {
      return null;
    }
    final token = raw.substring(space + 1).trim();
    final sep = token.indexOf(':');
    if (sep < 0) return null;
    final id = token.substring(0, sep);
    final secret = token.substring(sep + 1);
    if (!_idPattern.hasMatch(id)) return null;
    if (!_secretPattern.hasMatch(secret)) return null;
    return PlayerCredentials(id: id, secret: secret);
  }

  /// The header value these credentials are sent as.
  String get header => '$playerAuthScheme $id:$secret';
}

/// Result of [PlayerService.authenticate]: authenticated, absent, or refused.
///
/// "Absent" is a first-class outcome rather than a failure because
/// `POST /api/scores` accepts anonymous submissions; a *present but wrong*
/// credential, in contrast, always fails closed.
class PlayerAuth {
  const PlayerAuth.absent() : player = null, error = null;
  const PlayerAuth.failed(this.error) : player = null;
  const PlayerAuth.ok(PlayerRow this.player) : error = null;

  /// The authenticated player, or null when [ok] is false.
  final PlayerRow? player;

  /// [missingCredentialsError] / [invalidCredentialsError], or null.
  final String? error;

  bool get ok => player != null;

  /// No credentials were offered: allowed where identity is optional.
  bool get isAbsent => player == null && error == null;
}

/// A credential to be stored: the row id, the secret to hand out once, and the
/// digest that is all the database keeps.
class NewCredential {
  const NewCredential({
    required this.id,
    required this.secret,
    required this.secretHash,
  });

  /// Identifies the stored credential so it can later be rotated or evicted on
  /// its own. Not a secret and never returned.
  final String id;

  final String secret;
  final String secretHash;
}

/// A freshly issued player. [secret] is visible here and nowhere else, ever.
class IssuedPlayer {
  const IssuedPlayer({required this.id, required this.secret, this.name});

  final String id;
  final String secret;
  final String? name;

  /// Body of `201 POST /api/players`. `name` is always present, null when the
  /// player has no display name yet: the two player endpoints describe one
  /// player and have a fixed shape, so a client reads `name as String?`.
  Map<String, dynamic> toJson() => {
    'ok': true,
    'id': id,
    'secret': secret,
    'name': name,
  };

  /// The `Authorization` value a client built from this response sends.
  String get authorizationHeader =>
      PlayerCredentials(id: id, secret: secret).header;
}

class PlayerService {
  PlayerService({
    required this.store,
    required this.log,
    Random? random,
    DateTime Function()? clock,
  }) : _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  final ScoreStore store;
  final Logger log;
  final Random _random;
  final DateTime Function() _clock;

  /// Issues a new player with a fresh secret. [name] must already be
  /// normalized (see `normalizeName`) or null.
  Future<IssuedPlayer> issue({String? name}) async {
    final now = _clock();
    final stamp = Db.formatTimestamp(now);
    final id = randomHexId(_random);
    final credential = mintCredential();
    await store.createPlayer(
      PlayerRow(id: id, createdAt: stamp, lastSeenAt: stamp, name: name),
      credentialId: credential.id,
      secretHash: credential.secretHash,
    );
    log.info('player issued id=$id');
    return IssuedPlayer(id: id, secret: credential.secret, name: name);
  }

  /// A credential that has not been stored yet.
  ///
  /// The account layer needs the secret in hand *before* the transaction that
  /// links it runs, so minting and storing are separate steps; the db isolate
  /// never generates randomness of its own.
  NewCredential mintCredential() {
    final secret = newPlayerSecret(_random);
    return NewCredential(
      id: randomHexId(_random),
      secret: secret,
      secretHash: hashPlayerSecret(secret, random: _random),
    );
  }

  /// A fresh 32-hex id of the shape every server-generated id has.
  String newId() => randomHexId(_random);

  /// Verifies an `Authorization` header value.
  ///
  /// A successful authentication also moves `last_seen_at` forward, coalesced
  /// by [Db.lastSeenResolution] so that a client polling an authenticated
  /// endpoint cannot turn every read into a write.
  Future<PlayerAuth> authenticate(String? authorization) async {
    if (authorization == null || authorization.trim().isEmpty) {
      return const PlayerAuth.absent();
    }
    final credentials = PlayerCredentials.parse(authorization);
    if (credentials == null) {
      return const PlayerAuth.failed(invalidCredentialsError);
    }
    final stored = await store.playerWithSecrets(credentials.id);
    // An unknown id and a wrong secret get the same answer: which half was
    // wrong is not the caller's business, and neither is guessable. The secret
    // is checked against every credential the player holds, because each of
    // its devices has its own (SPEC §4.5); how many it holds is not a secret,
    // so trying them in turn leaks nothing.
    if (stored == null ||
        !stored.secretHashes.any(
          (hash) => verifyPlayerSecret(credentials.secret, hash),
        )) {
      log.info('refused credentials for player ${credentials.id}');
      return const PlayerAuth.failed(invalidCredentialsError);
    }
    await store.touchPlayer(stored.player.id, _clock());
    return PlayerAuth.ok(stored.player);
  }

  /// Games submitted, best score and global rank for [playerId].
  Future<PlayerStats> stats(String playerId) => store.playerScores(playerId);

  /// Deletes [player] and anonymises the runs it owned, returning how many
  /// score rows were anonymised (SPEC §4.5).
  ///
  /// Never gated on the account feature switch: an anonymous player deserves
  /// deletion too, and Apple requires an app that offers account creation to
  /// offer account deletion, so this must not be switchable off.
  ///
  /// The runs themselves stay on the leaderboard as anonymous rows — see
  /// [Db.deletePlayer] for why erasing them instead would be the wrong trade.
  Future<int> delete(PlayerRow player) async {
    final anonymised = await store.deletePlayer(player.id);
    log.info(
      'player deleted id=${player.id} scores anonymised=$anonymised '
      'account=${player.accountProvider ?? "-"}',
    );
    return anonymised;
  }
}

/// [bytes] random bytes as lowercase hex: the shape of every id the server
/// generates (players and score rows alike), 128 bits by default.
String randomHexId(Random random, {int bytes = 16}) =>
    _hex(List<int>.generate(bytes, (_) => random.nextInt(256)));

/// Bits of entropy in a player secret.
///
/// 256 bits from a CSPRNG is the whole reason a fast digest is enough below:
/// there is no dictionary to try and no birthday shortcut, so an attacker who
/// stole the table gains nothing to grind on.
const int playerSecretBits = 256;

/// A new player secret: [playerSecretBits] from [Random.secure] (pass another
/// [random] only in tests), base64url without padding — 43 URL- and
/// header-safe characters containing no `:`.
String newPlayerSecret([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = Uint8List.fromList(
    List<int>.generate(playerSecretBits ~/ 8, (_) => source.nextInt(256)),
  );
  return base64UrlEncode(bytes).replaceAll('=', '');
}

/// Version tag of the stored digest format, so the account layer can introduce
/// a slower KDF for user-chosen passwords without rewriting existing rows.
const String playerSecretHashVersion = 'v1';

/// `v1$<salt hex>$<sha256(salt || secret) hex>`.
///
/// SHA-256 with a 128-bit salt, not a work-factor KDF: the secret is 256
/// random bits the server generated, so stretching it would buy nothing an
/// attacker could not already skip — while costing the request isolate real
/// time on every authenticated call, and that isolate also drives the 60 Hz
/// room tick. The salt keeps the digests of two players with (impossibly) the
/// same secret distinct and makes precomputation meaningless. A user-chosen
/// password would need a real KDF, which is what [playerSecretHashVersion] is
/// there for.
String hashPlayerSecret(String secret, {List<int>? salt, Random? random}) {
  final bytes =
      salt ??
      List<int>.generate(16, (_) => (random ?? Random.secure()).nextInt(256));
  final digest = sha256.convert([...bytes, ...utf8.encode(secret)]).bytes;
  return '$playerSecretHashVersion\$${_hex(bytes)}\$${_hex(digest)}';
}

/// Whether [secret] is the secret [stored] was made from. Constant time in the
/// digest comparison; false for any stored value this build cannot read.
bool verifyPlayerSecret(String secret, String stored) {
  final parts = stored.split(r'$');
  if (parts.length != 3 || parts[0] != playerSecretHashVersion) return false;
  final salt = _unhex(parts[1]);
  final expected = _unhex(parts[2]);
  if (salt == null || expected == null || expected.isEmpty) return false;
  final actual = sha256.convert([...salt, ...utf8.encode(secret)]).bytes;
  return constantTimeEquals(actual, expected);
}

/// Compares two byte sequences without an early exit, so the time it takes
/// does not reveal how many leading bytes matched.
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String _hex(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

Uint8List? _unhex(String hex) {
  if (hex.isEmpty || hex.length.isOdd) return null;
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}
