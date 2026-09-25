/// Rewarded ads that pay Sparks, server side (SPEC §4.10).
///
/// The shape of the deal, and the only shape that is safe: **a client that says
/// "I watched an ad, give me Sparks" is a Spark printer.** So no client is ever
/// asked. The reward is credited on exactly one signal — AdMob's *server-side
/// verification* callback, a `GET` Google's servers make directly to us, carrying
/// an ECDSA signature over its own query string that we check against the keys
/// Google publishes. Nothing the phone says reaches the wallet, and the phone's
/// only power is to read its own balance afterwards.
///
/// That is the same division of labour as SPEC §4.9: an outside system attests
/// that something happened, **our server remains the only source of truth for the
/// balance**, and the amount comes from our own table rather than from the
/// message. AdMob's callback does carry a `reward_amount` — a number a human
/// typed into the AdMob dashboard — and this file never reads it. What an ad pays
/// is [AdRate.sparksPerAd], applied inside the crediting transaction.
///
/// **Two ways in, and the difference between them is the whole design:**
///
/// * **`GET /api/ads/callback`** — Google pushes a signed reward to us. This is
///   the *only* crediting path. It carries no player credentials, because the
///   caller is Google; what authenticates it is the signature, verified before
///   anything is written. Callbacks can be retried and can arrive out of order,
///   so crediting is idempotent on AdMob's own `transaction_id`.
/// * **`GET /api/ads/offer`** — the phone asks what its allowance is. Read-only.
///   It is what lets the app hide the ad button instead of offering an ad that
///   would pay nothing, and it is what the app polls after an ad to notice the
///   credit land. It cannot credit anything; there is no code path from it to a
///   balance.
///
/// **The bounds** live in [AdRate] and are applied in [Db.creditAdReward], where
/// a transaction can make "read the day, decide, write" atomic: a separate daily
/// cap for ads, deliberately smaller than the play one so that playing always
/// dominates, and a cooldown measured on Google's own signed timestamps so the
/// shop cannot be sat in and farmed.
///
/// The iron rule is untouched. What an ad pays is **Sparks**, which are earnable
/// by playing anyway; nothing in this file reaches `arco_core`, nothing it does
/// can change a simulation, and no leaderboard position can be watched into
/// existence.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' show PublicKeyParameter;
import 'package:pointycastle/digests/sha256.dart' show SHA256Digest;
import 'package:pointycastle/ecc/api.dart'
    show ECDomainParameters, ECPublicKey, ECSignature;
import 'package:pointycastle/ecc/curves/prime256v1.dart'
    show ECCurve_prime256v1;
import 'package:pointycastle/ecc/curves/secp256k1.dart' show ECCurve_secp256k1;
import 'package:pointycastle/signers/ecdsa_signer.dart' show ECDSASigner;

import 'config.dart';
import 'db.dart';
import 'id_token.dart';
import 'logging.dart';
import 'players.dart';
import 'score_store.dart';
import 'tokens.dart';

/// Longest `GET /api/ads/callback` query string this server will look at.
///
/// A real callback is about 400 characters. This is a transport guard with an
/// order of magnitude of headroom, not a tuned limit — and it is a cheap one,
/// because it is checked before any signature verification.
const int maxCallbackQueryChars = 2048;

/// The whole feature is switched off (`ADS_ENABLED` unset or `off`).
const String adsDisabledError = 'ads_disabled';

/// The callback's query string was not one AdMob sends.
const String invalidCallbackError = 'invalid_callback';

/// The signature did not verify against the key it names.
///
/// Deliberately one code for a missing signature, a malformed one and a wrong
/// one, exactly as SPEC §4.4 answers one code for a missing and a wrong
/// credential: telling a caller which half it got right is telling it how to get
/// closer.
const String invalidAdSignatureError = 'invalid_signature';

/// `ADMOB_CALLBACK_KEY` is configured and the callback did not carry it.
const String invalidAdKeyError = 'invalid_key';

/// The callback names a player that is not one of this server's.
const String unknownAdPlayerError = 'unknown_player';

/// Google's verifier keys could not be fetched and none is cached. Our problem,
/// worth a retry — the same class as `keys_unavailable` on a sign-in, and the
/// reason it is a `503` rather than a rejected reward: the callback may well be
/// perfectly good.
const String adKeysUnavailableError = 'admob_keys_unavailable';

/// Where a rewarded ad may be offered (SPEC §4.10).
///
/// Exactly two, and the list is short on purpose. An ad is offered only where it
/// answers something the player already wants: in the shop, as a way to earn
/// Sparks, and on the game-over screen, as an optional extra on a run that has
/// just ended. There is no placement for a launch, for a duel, or for an
/// interstitial anywhere — those are ads shown *at* somebody rather than *for*
/// them, and adding one would need a new value here and a new argument for it.
enum AdPlacement {
  /// The shop's earning panel: "watch an ad for Sparks".
  shop,

  /// The solo game-over overlay: an optional extra reward on the run just
  /// finished.
  gameOver;

  /// Parses the wire name; null for anything that is not a placement of this
  /// build — which is what a newer client talking to an older server looks like.
  static AdPlacement? parse(String? raw) {
    for (final placement in values) {
      if (placement.name == raw) return placement;
    }
    return null;
  }

  /// The names a client may send, in the order the app offers them.
  static List<String> get names => [for (final p in values) p.name];
}

/// The `custom_data` an ad carries to the callback (SPEC §4.10).
///
/// `<playerId>:<placement>`, and it is deliberately the plainest thing that
/// works. It travels through AdMob's SDK, Google's ad servers and a URL-encoded
/// query parameter before it reaches us, so it has no JSON to mis-escape and no
/// separator that percent-encoding could swallow.
///
/// **It is signed**, which is what makes it usable at all: the player id in here
/// is part of the content Google's signature covers, so a caller cannot move
/// somebody else's reward to their own wallet by editing a query string. What it
/// is *not* is a secret — anybody can put their own player id in their own ad, and
/// the worst that buys them is crediting their own wallet within the daily cap,
/// which is what the button is for.
///
/// The format is pinned on both sides by a test (`ads_test.dart` here,
/// `ad_pin_test.dart` in the app), because the two halves cannot share code.
abstract final class AdCustomData {
  static const String separator = ':';

  /// What the app sets on the ad before showing it.
  static String encode(String playerId, AdPlacement placement) =>
      '$playerId$separator${placement.name}';

  /// The player id and placement in [raw], with either null when it is not one.
  ///
  /// A placement this build does not know reads as null rather than refusing the
  /// whole callback: the reward is real and the placement is a label, so an app
  /// newer than the server still gets paid and the row records `unknown`.
  static ({String? playerId, AdPlacement? placement}) decode(String raw) {
    final cut = raw.indexOf(separator);
    final id = cut < 0 ? raw : raw.substring(0, cut);
    return (
      playerId: PlayerCredentials.isPlayerId(id) ? id : null,
      placement: cut < 0 ? null : AdPlacement.parse(raw.substring(cut + 1)),
    );
  }
}

/// Outcome of an ad call: an HTTP status plus a JSON body — the same shape
/// `ShopService` and `PurchaseService` return, so `api.dart` stays routing only.
class AdResult {
  const AdResult(this.status, this.body);

  factory AdResult.error(
    int status,
    String code, {
    String? detail,
    Map<String, dynamic>? extra,
  }) => AdResult(status, {
    'ok': false,
    'error': code,
    'detail': ?detail,
    ...?extra,
  });

  final int status;
  final Map<String, dynamic> body;

  bool get ok => status == 200;
}

/// One of Google's published rewarded-ad verifier keys.
class AdMobVerifierKey {
  const AdMobVerifierKey({required this.keyId, required this.key});

  /// `keyId` as the document publishes it and as the callback's `key_id`
  /// parameter repeats it. A number in the JSON, compared as a string, because
  /// that is what arrives in a query string.
  final String keyId;

  final ECPublicKey key;
}

/// What one AdMob server-side verification callback says (SPEC §4.10).
///
/// Only these fields are read. The callback also carries `reward_amount` and
/// `reward_item`, which are recorded and never consulted (see [AdRewardRow]), and
/// may carry others this server ignores entirely.
class AdCallback {
  const AdCallback({
    required this.transactionId,
    required this.playerId,
    required this.placement,
    required this.rewardAmount,
    required this.rewardItem,
    required this.adUnit,
    required this.adNetwork,
    required this.keyId,
    required this.signature,
    required this.signedContent,
    required this.rewardedAt,
    required this.callbackKey,
  });

  /// AdMob's own id for this reward — the idempotency key, and part of the signed
  /// content, so a caller cannot choose it.
  final String transactionId;

  /// Our player, from the signed `custom_data` (or `user_id`).
  final String playerId;

  /// Where the ad was offered, or null for a placement this build has no name
  /// for.
  final AdPlacement? placement;

  /// What AdMob's dashboard advertises. Recorded, never read.
  final int rewardAmount;
  final String rewardItem;

  final String adUnit;
  final String adNetwork;

  /// Which published key signed this.
  final String keyId;

  /// The DER-encoded ECDSA signature, already base64url-decoded.
  final Uint8List signature;

  /// Exactly the bytes the signature covers: the raw query string up to
  /// `&signature=`. Kept as the caller's own bytes rather than re-encoded from
  /// parsed parameters — a signature is over a byte string, and re-encoding one
  /// is how a verifier accidentally verifies something else.
  final Uint8List signedContent;

  /// Google's signed timestamp for the reward. Both the cooldown and the day the
  /// cap is measured over come from this rather than from our clock.
  final DateTime rewardedAt;

  /// The `arco_key` parameter, when the URL was configured with one.
  final String? callbackKey;

  /// The placement name for the ledger: the parsed one, or `unknown`.
  String get placementName => placement?.name ?? 'unknown';

  /// Parses a callback's **raw** query string.
  ///
  /// Returns null, with a reason, for anything that is not one. The signed
  /// content is taken as the substring before the last `&signature=`, which is
  /// the layout Google documents: the last two parameters are always `signature`
  /// and `key_id`, in that order. Getting that split wrong cannot be exploited —
  /// a wrong split simply fails verification — but getting it right is what makes
  /// a genuine callback verify.
  static ({AdCallback? callback, String? reason}) parse(String rawQuery) {
    if (rawQuery.isEmpty) return (callback: null, reason: 'empty query');
    if (rawQuery.length > maxCallbackQueryChars) {
      return (
        callback: null,
        reason: 'query over $maxCallbackQueryChars characters',
      );
    }
    final cut = rawQuery.lastIndexOf('&signature=');
    if (cut <= 0) {
      return (
        callback: null,
        reason:
            'no "&signature=" parameter; AdMob always sends signature '
            'and key_id last',
      );
    }
    final Map<String, String> params;
    try {
      params = Uri.splitQueryString(rawQuery);
    } catch (e) {
      return (callback: null, reason: 'query is not decodable: $e');
    }
    final signatureRaw = params['signature'];
    final keyId = params['key_id'];
    if (signatureRaw == null || signatureRaw.isEmpty) {
      return (callback: null, reason: 'no signature');
    }
    if (keyId == null || keyId.isEmpty) {
      return (callback: null, reason: 'no key_id');
    }
    final Uint8List signature;
    try {
      signature = base64Url.decode(base64.normalize(signatureRaw));
    } on FormatException catch (e) {
      return (callback: null, reason: 'signature is not base64url: $e');
    }
    final transactionId = params['transaction_id'];
    if (transactionId == null || transactionId.isEmpty) {
      return (callback: null, reason: 'no transaction_id');
    }
    // The custom data is where our player id rides; `user_id` is the other field
    // AdMob offers for the same purpose, and it is accepted as a fallback so that
    // a human wiring the SDK either way gets a working reward.
    final custom = params['custom_data'] ?? '';
    final decoded = AdCustomData.decode(custom);
    final playerId =
        decoded.playerId ??
        (PlayerCredentials.isPlayerId(params['user_id'] ?? '')
            ? params['user_id']
            : null);
    if (playerId == null) {
      return (callback: null, reason: 'custom_data carries no Arco player id');
    }
    final millis = int.tryParse(params['timestamp'] ?? '');
    if (millis == null || millis <= 0) {
      return (callback: null, reason: 'no usable timestamp');
    }
    return (
      callback: AdCallback(
        transactionId: transactionId,
        playerId: playerId,
        placement: decoded.placement,
        // Parsed so a malformed one is 0 rather than a throw, because it is never
        // used for anything: see [AdRewardRow.rewardAmount].
        rewardAmount: int.tryParse(params['reward_amount'] ?? '') ?? 0,
        rewardItem: params['reward_item'] ?? '',
        adUnit: params['ad_unit'] ?? '',
        adNetwork: params['ad_network'] ?? '',
        keyId: keyId,
        signature: signature,
        signedContent: Uint8List.fromList(
          ascii.encode(rawQuery.substring(0, cut)),
        ),
        rewardedAt: DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
        callbackKey: params['arco_key'],
      ),
      reason: null,
    );
  }
}

/// Raised when there are no verifier keys at all: the first fetch failed and
/// there is nothing cached to fall back on.
class AdKeysUnavailableException implements Exception {
  const AdKeysUnavailableException(this.uri, this.reason);

  final Uri uri;
  final String reason;

  @override
  String toString() => 'no AdMob verifier keys from $uri: $reason';
}

/// Google's published rewarded-ad verifier keys, cached.
///
/// The refresh policy is [JwksCache]'s, deliberately: this is the same problem
/// (a provider publishes signing keys, rotates them without telling us, and must
/// not be hammered), so it gets the same answer rather than a second one.
///
/// * a document is used until [ttl] has passed,
/// * a callback naming an *unknown* `key_id` triggers one immediate refresh,
///   because that is what a just-rotated key looks like,
/// * but at most one fetch per [minRefreshInterval], with concurrent callers
///   sharing the one in flight, so a flood of callbacks with random key ids
///   cannot make us hammer Google,
/// * a refresh that fails while keys are cached keeps the cached keys and logs: a
///   gstatic hiccup must not lose everybody's rewards.
class AdMobKeyCache {
  AdMobKeyCache({
    required this.uri,
    required this.log,
    JwksFetcher? fetch,
    this.minRefreshInterval = const Duration(minutes: 1),
    Duration? ttl,
    DateTime Function()? clock,
  }) : _fetch = fetch ?? fetchJwksOverHttps,
       _ttl = ttl ?? defaultTtl,
       _clock = clock ?? DateTime.now;

  /// Google's keys rotate rarely and the document is tiny; a day between
  /// scheduled fetches is plenty, and an unknown key id refreshes out of band
  /// anyway.
  static const Duration defaultTtl = Duration(hours: 12);

  /// At most 32 keys per document; Google publishes one or two.
  static const int maxKeys = 32;

  final Uri uri;
  final Logger log;
  final Duration minRefreshInterval;
  final JwksFetcher _fetch;
  final Duration _ttl;
  final DateTime Function() _clock;

  Map<String, AdMobVerifierKey> _keys = const <String, AdMobVerifierKey>{};
  DateTime? _loadedAt;
  DateTime? _attemptedAt;
  Future<void>? _inFlight;
  String _lastFailure = 'not fetched yet';

  /// Fetch attempts made (diagnostics and tests).
  int attempts = 0;

  bool get hasKeys => _keys.isNotEmpty;

  /// Key ids currently cached (diagnostics and tests).
  Set<String> get keyIds => _keys.keys.toSet();

  bool get _isFresh {
    final loaded = _loadedAt;
    return loaded != null && _clock().difference(loaded) < _ttl;
  }

  bool get _mayFetch {
    final attempted = _attemptedAt;
    return attempted == null ||
        _clock().difference(attempted) >= minRefreshInterval;
  }

  /// The key published under [keyId], or null when Google does not publish one
  /// (which is a rejected callback, not an outage).
  ///
  /// Throws [AdKeysUnavailableException] when no document could be obtained at
  /// all.
  Future<AdMobVerifierKey?> keyFor(String keyId) async {
    if (!hasKeys || !_isFresh) await _loadIfUseful();
    if (!hasKeys) throw AdKeysUnavailableException(uri, _lastFailure);
    var key = _keys[keyId];
    if (key == null) {
      // A key id we have never seen is what a rotation looks like.
      await _loadIfUseful();
      key = _keys[keyId];
    }
    return key;
  }

  /// Joins the fetch already under way, or starts one when the refresh budget
  /// allows, or does nothing. Never throws.
  Future<void> _loadIfUseful() {
    final running = _inFlight;
    if (running != null) return running;
    if (!_mayFetch) return Future<void>.value();
    final started = _loadOnce();
    _inFlight = started;
    return started.whenComplete(() {
      if (identical(_inFlight, started)) _inFlight = null;
    });
  }

  Future<void> _loadOnce() async {
    attempts++;
    _attemptedAt = _clock();
    try {
      final document = await _fetch(uri);
      final keys = parseAdMobVerifierKeys(document.body, log: log, source: uri);
      if (keys.isEmpty) {
        throw const FormatException('document publishes no usable EC key');
      }
      _keys = keys;
      _loadedAt = _clock();
      log.info(
        'AdMob verifier keys loaded from $uri: ${keys.length} key(s) '
        '(${keys.keys.join(', ')})',
      );
    } catch (e) {
      _lastFailure = '$e';
      if (hasKeys) {
        // Slightly stale keys beat losing every reward while gstatic or our
        // egress is having a bad minute.
        log.warn('keeping cached AdMob verifier keys: refresh failed: $e');
      } else {
        log.error('cannot load AdMob verifier keys from $uri', e);
      }
    }
  }
}

/// Parses Google's `{"keys":[{"keyId":…,"pem":…,"base64":…}]}` document.
///
/// Reads the `base64` field, which is the DER `SubjectPublicKeyInfo` the `pem`
/// field wraps — one less thing to unwrap, and no PEM parser to get wrong. A key
/// that cannot be read is skipped with a warning rather than failing the
/// document: one unreadable key must not stop the other from verifying rewards.
Map<String, AdMobVerifierKey> parseAdMobVerifierKeys(
  String body, {
  required Logger log,
  required Uri source,
}) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } catch (e) {
    throw FormatException('verifier key document from $source is not JSON: $e');
  }
  if (json is! Map<String, dynamic>) {
    throw FormatException(
      'verifier key document from $source is not an object',
    );
  }
  final raw = json['keys'];
  if (raw is! List) {
    throw FormatException('verifier key document from $source has no "keys"');
  }
  final keys = <String, AdMobVerifierKey>{};
  for (final entry in raw) {
    if (keys.length >= AdMobKeyCache.maxKeys) break;
    if (entry is! Map) continue;
    final keyId = entry['keyId'];
    if (keyId == null) continue;
    final id = '$keyId';
    final encoded = entry['base64'];
    if (encoded is! String || encoded.isEmpty) {
      log.warn('AdMob verifier key $id from $source has no "base64"');
      continue;
    }
    try {
      keys[id] = AdMobVerifierKey(
        keyId: id,
        key: parseEcPublicKey(base64.decode(encoded)),
      );
    } catch (e) {
      log.warn('AdMob verifier key $id from $source is unusable: $e');
    }
  }
  return keys;
}

/// Reads a DER `SubjectPublicKeyInfo` holding an EC public key.
///
/// The curve is taken from the key's own named-curve OID rather than assumed.
/// Google currently publishes P-256 (`prime256v1`), and the OID is right there in
/// the document — reading it means a future rotation onto another supported curve
/// verifies instead of silently failing, and an unsupported one throws with a
/// name a human can act on rather than producing wrong answers.
ECPublicKey parseEcPublicKey(List<int> der) {
  final reader = _Der(Uint8List.fromList(der));
  final outer = reader.readSequence();
  final algorithm = outer.readSequence();
  final algorithmOid = algorithm.readOid();
  if (algorithmOid != _ecPublicKeyOid) {
    throw FormatException('not an EC public key (algorithm $algorithmOid)');
  }
  final curveOid = algorithm.readOid();
  final domain = _curvesByOid[curveOid];
  if (domain == null) {
    throw FormatException('unsupported EC curve $curveOid');
  }
  final point = outer.readBitString();
  final q = domain.curve.decodePoint(point);
  if (q == null || q.isInfinity) {
    throw const FormatException('EC public key is not a point on the curve');
  }
  return ECPublicKey(q, domain);
}

/// `1.2.840.10045.2.1` — `id-ecPublicKey`.
const String _ecPublicKeyOid = '1.2.840.10045.2.1';

/// The named curves this server will verify with, by OID.
///
/// `prime256v1` is what Google publishes today. `secp256k1` is here because it is
/// the other curve AdMob documentation has named over the years and supporting it
/// costs one map entry; anything else throws by name.
final Map<String, ECDomainParameters> _curvesByOid =
    <String, ECDomainParameters>{
      '1.2.840.10045.3.1.7': ECCurve_prime256v1(),
      '1.3.132.0.10': ECCurve_secp256k1(),
    };

/// Whether [signature] is a valid ECDSA/SHA-256 signature over [content].
///
/// [signature] is the DER `SEQUENCE { INTEGER r, INTEGER s }` AdMob sends,
/// base64url-decoded. Returns false for anything malformed rather than throwing:
/// a callback with a corrupt signature is a refused callback, not a server fault.
bool verifyAdMobSignature(
  ECPublicKey key,
  Uint8List content,
  Uint8List signature,
) {
  final ECSignature parsed;
  try {
    final reader = _Der(signature).readSequence();
    final r = reader.readInteger();
    final s = reader.readInteger();
    if (r.sign <= 0 || s.sign <= 0) return false;
    parsed = ECSignature(r, s);
  } catch (_) {
    return false;
  }
  try {
    final signer = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(key));
    return signer.verifySignature(content, parsed);
  } catch (_) {
    return false;
  }
}

/// The smallest DER reader that reads a `SubjectPublicKeyInfo` and an ECDSA
/// signature, and nothing else.
///
/// Written out rather than pulled from `package:pointycastle/asn1.dart` because
/// the whole of what is needed is four primitives, and a parser that accepts
/// exactly what it must is a parser with nowhere to hide. Every length and every
/// tag is checked; anything unexpected is a [FormatException].
class _Der {
  _Der(this._bytes, [this._at = 0, int? end]) : _end = end ?? _bytes.length;

  final Uint8List _bytes;
  int _at;
  final int _end;

  static const int _sequenceTag = 0x30;
  static const int _integerTag = 0x02;
  static const int _oidTag = 0x06;
  static const int _bitStringTag = 0x03;

  /// The contents of a `SEQUENCE`, as its own reader.
  _Der readSequence() {
    final (start, end) = _readHeader(_sequenceTag);
    return _Der(_bytes, start, end);
  }

  /// An `INTEGER` as a non-negative [BigInt].
  BigInt readInteger() {
    final (start, end) = _readHeader(_integerTag);
    if (start == end) throw const FormatException('empty DER INTEGER');
    // A leading 0x80 bit means a negative two's-complement integer, which no
    // field of either structure may be.
    if (_bytes[start] & 0x80 != 0) {
      throw const FormatException('negative DER INTEGER');
    }
    var value = BigInt.zero;
    for (var i = start; i < end; i++) {
      value = (value << 8) | BigInt.from(_bytes[i]);
    }
    return value;
  }

  /// An `OBJECT IDENTIFIER` in dotted-decimal form.
  String readOid() {
    final (start, end) = _readHeader(_oidTag);
    if (start == end) throw const FormatException('empty DER OID');
    final parts = <int>[_bytes[start] ~/ 40, _bytes[start] % 40];
    var value = 0;
    for (var i = start + 1; i < end; i++) {
      final byte = _bytes[i];
      value = (value << 7) | (byte & 0x7f);
      if (byte & 0x80 == 0) {
        parts.add(value);
        value = 0;
      }
    }
    return parts.join('.');
  }

  /// A `BIT STRING`'s bytes, with the unused-bits octet stripped.
  Uint8List readBitString() {
    final (start, end) = _readHeader(_bitStringTag);
    if (start == end) throw const FormatException('empty DER BIT STRING');
    if (_bytes[start] != 0) {
      throw const FormatException(
        'DER BIT STRING is not a whole number of bytes',
      );
    }
    return Uint8List.sublistView(_bytes, start + 1, end);
  }

  (int, int) _readHeader(int tag) {
    if (_at >= _end) throw const FormatException('DER ended early');
    if (_bytes[_at] != tag) {
      throw FormatException(
        'expected DER tag 0x${tag.toRadixString(16)}, got '
        '0x${_bytes[_at].toRadixString(16)}',
      );
    }
    _at++;
    if (_at >= _end) throw const FormatException('DER ended in a length');
    var length = _bytes[_at++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 4) {
        throw const FormatException('unsupported DER length');
      }
      if (_at + count > _end) throw const FormatException('DER ended early');
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | _bytes[_at++];
      }
    }
    final start = _at;
    final end = start + length;
    if (end > _end) throw const FormatException('DER length overruns the data');
    _at = end;
    return (start, end);
  }
}

/// Rewarded ads (SPEC §4.10): verifying AdMob's callback, crediting the wallet,
/// and telling the client what its allowance is.
///
/// Always constructed, even when the feature is off — [enabled] is then false, the
/// two routes answer [adsDisabledError] and nothing else about the server changes.
/// The same shape `AccountService` and `PurchaseService` have, and it is what makes
/// the switch a genuine switch rather than a conditionally wired server.
class AdsService {
  AdsService({
    required this.store,
    required this.config,
    required this.log,
    AdMobKeyCache? keys,
    JwksFetcher? fetchKeys,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _keys =
           keys ??
           (config.enabled
               ? AdMobKeyCache(uri: config.keysUri, log: log, fetch: fetchKeys)
               : null);

  final ScoreStore store;
  final AdsConfig config;
  final Logger log;
  final DateTime Function() _clock;
  final AdMobKeyCache? _keys;

  bool get enabled => config.enabled;

  /// `GET /api/ads/callback` — AdMob's server-side verification, and the **only**
  /// path in this server that can turn a watched ad into Sparks (SPEC §4.10).
  ///
  /// [query] is the request's **raw** query string, not its parsed parameters:
  /// the signature covers those bytes, and re-encoding them from a parsed map is
  /// how a verifier ends up verifying something the caller never sent.
  ///
  /// The order of the checks is the design. The cheap, local ones come first — the
  /// switch, the optional URL key, the shape — so that an unauthenticated flood
  /// costs a string comparison rather than an elliptic-curve verification; the
  /// signature comes before any lookup, so a caller cannot use the endpoint to
  /// probe which player ids exist; and nothing is written until the signature has
  /// verified.
  ///
  /// Everything the server has genuinely handled is answered `200`, including a
  /// reward the daily cap or the cooldown bounded to nothing: AdMob retries a
  /// non-2xx, and "seen, and it paid 0 for a documented reason" is not something
  /// to retry. `unknown_player` is deliberately a `404` — a reward for a player
  /// that does not exist means the app and this deployment disagree about who is
  /// playing, and that should surface rather than be swallowed.
  Future<AdResult> callback(String query) async {
    if (!enabled) return AdResult.error(404, adsDisabledError);
    final keys = _keys;
    if (keys == null) return AdResult.error(503, adKeysUnavailableError);
    if (query.length > maxCallbackQueryChars) {
      return AdResult.error(
        400,
        invalidCallbackError,
        detail: 'query over $maxCallbackQueryChars characters',
      );
    }
    final (callback: callback, reason: reason) = AdCallback.parse(query);
    if (callback == null) {
      log.warn('ad callback refused: $reason');
      return AdResult.error(400, invalidCallbackError, detail: reason);
    }
    // The optional URL key, before any cryptography: it is the cheap filter, and
    // it is checked in constant time because it is a value that gates crediting.
    if (config.requiresKey && !_keyMatches(callback.callbackKey)) {
      log.warn(
        'ad callback refused: arco_key does not match ADMOB_CALLBACK_KEY '
        '(txn=${callback.transactionId})',
      );
      return AdResult.error(401, invalidAdKeyError);
    }
    final AdMobVerifierKey? key;
    try {
      key = await keys.keyFor(callback.keyId);
    } on AdKeysUnavailableException catch (e) {
      // Not the caller's fault and not a rejected reward: we cannot tell. A 503
      // makes AdMob retry, which is exactly what should happen.
      log.warn('ad callback cannot be verified: ${e.reason}');
      return AdResult.error(503, adKeysUnavailableError);
    }
    if (key == null) {
      log.warn(
        'ad callback refused: Google publishes no key "${callback.keyId}" '
        '(cached: ${keys.keyIds.join(', ')})',
      );
      return AdResult.error(401, invalidAdSignatureError);
    }
    if (!verifyAdMobSignature(
      key.key,
      callback.signedContent,
      callback.signature,
    )) {
      log.warn(
        'ad callback refused: signature does not verify '
        '(key=${callback.keyId}, txn=${callback.transactionId})',
      );
      return AdResult.error(401, invalidAdSignatureError);
    }

    // Verified. From here the callback is Google's word, and the only remaining
    // questions are whose wallet and how much — and the second of those is not
    // asked of the callback at all.
    final playerId = await store.canonicalPlayerId(callback.playerId);
    if (await store.playerById(playerId) == null) {
      log.warn(
        'ad callback refused: no player ${callback.playerId} '
        '(txn=${callback.transactionId})',
      );
      return AdResult.error(
        404,
        unknownAdPlayerError,
        extra: {'playerId': callback.playerId},
      );
    }
    final credit = await store.creditAdReward(
      AdCreditRequest(
        playerId: playerId,
        placement: callback.placementName,
        transactionId: callback.transactionId,
        rewardAmount: callback.rewardAmount,
        rewardItem: callback.rewardItem,
        adUnit: callback.adUnit,
        adNetwork: callback.adNetwork,
        keyId: callback.keyId,
        rewardedAt: callback.rewardedAt,
        now: _clock(),
      ),
    );
    if (!credit.ok) {
      // Cannot happen (the player was resolved above); this is the race where it
      // was deleted between the two.
      return AdResult.error(404, credit.error!);
    }
    if (credit.duplicate) {
      // The ordinary retry. Answered 200 so AdMob stops, and logged at debug
      // because a callback arriving twice is normal operation, not news.
      log.debug(
        'ad reward already credited txn=${credit.transactionId} '
        'player=$playerId',
      );
    } else if (credit.sparks > 0) {
      log.info(
        'sparks credited (ad) player=$playerId sparks=${credit.sparks} '
        'placement=${credit.placement} txn=${credit.transactionId} '
        'network=${callback.adNetwork} balance=${credit.balance}'
        '${credit.refused == null ? '' : ' (${credit.refused})'}',
      );
    } else {
      // Watched and paid nothing, for a documented reason. Info rather than warn:
      // both bounds are supposed to be reached, and the client is supposed to
      // have hidden the button before it happened.
      log.info(
        'ad reward paid nothing (${credit.refused}) player=$playerId '
        'txn=${credit.transactionId} earnedToday=${credit.earnedToday}',
      );
    }
    return AdResult(200, {
      'ok': true,
      'credited': credit.duplicate ? 0 : credit.sparks,
      'duplicate': credit.duplicate,
      'refused': ?credit.refused,
      'playerId': playerId,
      'placement': credit.placement,
      'earnedToday': credit.earnedToday,
      'dailyCap': AdRate.dailyCap,
      'balance': credit.balance,
    });
  }

  /// `GET /api/ads/offer` — what [player]'s ad allowance is (SPEC §4.10).
  ///
  /// Read-only, and it credits nothing: there is no code path from this method to
  /// a balance. It exists so the app can do the one thing a rewarded ad must never
  /// get wrong — **not offer an ad that would pay nothing.** A player inside the
  /// cooldown or at the day's cap is shown no button at all, rather than a button
  /// that takes thirty seconds and hands over nothing.
  ///
  /// It doubles as the poll after an ad, which is why it carries the wallet: the
  /// credit arrives through Google, so the app's only way to learn about it is to
  /// ask us, and [AdRewardState.adTotal] moving is the unambiguous signal that it
  /// landed.
  ///
  /// **A premium player is offered nothing here** (SPEC §4.9): no ads is half of
  /// what the one-time unlock grants, and the honest place to enforce it is the
  /// one call that decides whether the button exists. `available` is false and
  /// `premium` says why, so a client shows no ad button rather than one that is
  /// technically payable.
  Future<AdResult> offer(PlayerRow player) async {
    if (!enabled) return AdResult.error(404, adsDisabledError);
    final state = await store.adRewardState(player.id, now: _clock());
    final remaining = AdRate.dailyCap - state.earnedToday;
    final wait = _waitFor(state.lastRewardedAt);
    return AdResult(200, {
      'ok': true,
      // What the next ad pays, from the server's own table — so the button can say
      // "+10" without the app holding a number that could drift.
      'sparks': AdRate.forAdWithinDay(alreadyEarnedToday: state.earnedToday),
      'earnedToday': state.earnedToday,
      'dailyCap': AdRate.dailyCap,
      'remaining': remaining < 0 ? 0 : remaining,
      'cooldownSeconds': AdRate.cooldown.inSeconds,
      // Whole seconds, rounded up: a client that waits this long is out of the
      // cooldown, which a truncated value would not guarantee.
      'waitSeconds': (wait.inMilliseconds / 1000).ceil(),
      // The one flag the client actually acts on. Everything else above is for
      // the sentence beside the button.
      'available': !state.premium && remaining > 0 && wait <= Duration.zero,
      // Whether this player bought the one-time unlock (SPEC §4.9). They are
      // offered no ads at all — not as a courtesy but as the other half of what
      // they paid for — and this is the field that says so, rather than leaving a
      // client to guess why `available` is false while the allowance is full.
      'premium': state.premium,
      'balance': state.balance,
      // Sparks this player has ever earned from ads: the poll after an ad watches
      // this number, because it can only move one way and only for this reason.
      'adTotal': state.adTotal,
      // The placements this server knows, so an app built against a newer or older
      // build sends one that will be recorded rather than `unknown`.
      'placements': AdPlacement.names,
    });
  }

  Duration _waitFor(DateTime? lastRewardedAt) {
    if (lastRewardedAt == null) return Duration.zero;
    final elapsed = _clock().toUtc().difference(lastRewardedAt);
    // A negative elapsed time is a clock that disagrees with Google's; treat the
    // whole cooldown as remaining rather than handing out a free ad.
    if (elapsed.isNegative) return AdRate.cooldown;
    final left = AdRate.cooldown - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether [value] is the configured `ADMOB_CALLBACK_KEY`.
  ///
  /// Constant time in the length of the key, so a wrong value cannot be tuned one
  /// character at a time by measuring the reply. `constantTimeEquals` is the one
  /// `players.dart` already uses to compare a credential digest: one
  /// implementation of this in the server, not three.
  bool _keyMatches(String? value) {
    final expected = config.callbackKey;
    if (expected.isEmpty) return false;
    final candidate = value ?? '';
    if (candidate.isEmpty) return false;
    return constantTimeEquals(utf8.encode(candidate), utf8.encode(expected));
  }
}
