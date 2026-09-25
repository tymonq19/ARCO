/// Verification of the identity tokens Apple and Google hand the client
/// (SPEC §4.5).
///
/// The product flow is: the player plays anonymously, at some point taps "keep
/// my scores", the phone performs the native sign-in and receives a signed JWT,
/// and the app posts that token to us. Everything that decides *who* that token
/// belongs to is checked here, on the server, because the client half of the
/// flow runs on a device the player controls:
///
/// * the signature, against the provider's published keys, fetched over HTTPS
///   and cached (never a key the token itself points at, and never a bare
///   subject id the client claims),
/// * `alg`, pinned to RS256 — `none` and the HMAC algorithms are refused
///   outright rather than "unsupported", because accepting them *is* the
///   classic JWT forgery,
/// * `iss`, against the provider's own issuer(s),
/// * `aud`, against the client ids *we* configured (`APPLE_CLIENT_IDS` /
///   `GOOGLE_CLIENT_IDS`) — this is what stops a valid token minted for some
///   other app from signing anyone into Arco,
/// * `exp` (and `nbf`/`iat` when present) with a small clock skew, so a token
///   is unusable once it has run out.
///
/// What is deliberately *not* read: `email`, `email_verified`, `name`, and
/// Apple's private-relay address. The only claim kept anywhere is the opaque
/// `sub` (see SPEC §4.5 and `accounts.dart`).
///
/// Nothing here touches storage; linking lives in `accounts.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' show PublicKeyParameter;
import 'package:pointycastle/asymmetric/api.dart'
    show RSAPublicKey, RSASignature;
import 'package:pointycastle/digests/sha256.dart' show SHA256Digest;
import 'package:pointycastle/signers/rsa_signer.dart' show RSASigner;

import 'logging.dart';

/// The one JWS algorithm accepted for an identity token.
///
/// Both providers sign identity tokens with RS256 today. Pinning it means a
/// token header cannot talk us into a weaker check: `{"alg":"none"}` and
/// `{"alg":"HS256"}` (where the "key" would be public key material) are the two
/// standard ways JWT verification is broken, and both are refused before any
/// key lookup happens. Supporting ES256 as well would be a local change here
/// plus an `EC` branch in [parseJwks].
const String idTokenAlgorithm = 'RS256';

/// DER encoding of the SHA-256 algorithm identifier, as PKCS#1 v1.5 signatures
/// carry it (`2.16.840.1.101.3.4.2.1`). Passed to [RSASigner] so the digest in
/// the signature block must be a SHA-256 one.
const String sha256DigestIdentifier = '0609608648016503040201';

/// Smallest RSA modulus accepted from a provider's key document. Apple and
/// Google both publish 2048-bit keys; anything shorter is skipped rather than
/// trusted.
const int minRsaModulusBits = 2048;

/// Longest identity token accepted. Apple's are ~800 bytes and Google's ~1 KB;
/// this only stops a caller from making us base64-decode a megabyte.
const int maxIdTokenChars = 4096;

/// Longest `kid` accepted from a token header (Apple's are 10 characters,
/// Google's 40).
const int maxKeyIdChars = 128;

/// Longest provider subject accepted. Apple's is a 44-character opaque string,
/// Google's a 21-digit number.
const int maxSubjectChars = 255;

/// How far the provider's clock may run ahead of ours before a token that is
/// valid for them looks not-yet-valid (or freshly expired) to us.
const Duration idTokenClockSkew = Duration(seconds: 60);

/// A token that failed a check. [code] is what the HTTP layer reports as
/// `detail`; every code below means the same thing to the caller — the token is
/// not usable — and the distinction exists for operators, because "wrong
/// audience" is the shape of a configuration mistake and "bad signature" is
/// not.
class IdTokenException implements Exception {
  const IdTokenException(this.code, [this.detail]);

  /// `malformed_token`, `unsupported_algorithm`, `unknown_key`,
  /// `bad_signature`, `wrong_issuer`, `wrong_audience`, `expired_token`,
  /// `token_not_yet_valid`, `missing_subject` or `keys_unavailable`.
  final String code;
  final String? detail;

  /// True when the failure is ours (we could not reach the provider's keys),
  /// not the caller's — a `503`, not a `401`.
  bool get isServerSide => code == keysUnavailableCode;

  static const String keysUnavailableCode = 'keys_unavailable';

  @override
  String toString() => detail == null ? code : '$code ($detail)';
}

/// A token that passed every check in [IdTokenVerifier.verify].
class VerifiedIdToken {
  const VerifiedIdToken({
    required this.provider,
    required this.subject,
    required this.expiresAt,
  });

  /// Provider name the token was verified against (`apple`, `google`).
  final String provider;

  /// The provider's opaque, stable identifier for this person *for this app*.
  /// The only piece of the token that is ever stored.
  final String subject;

  final DateTime expiresAt;
}

/// One published RSA signing key.
class SigningKey {
  const SigningKey({required this.kid, required this.key});

  final String kid;
  final RSAPublicKey key;

  /// Length a PKCS#1 v1.5 signature made with this key must have, in bytes.
  int get signatureBytes => (key.modulus!.bitLength + 7) >> 3;
}

/// A fetched key document: the body plus the `max-age` the provider asked us to
/// cache it for, if any.
class JwksDocument {
  const JwksDocument(this.body, {this.maxAge});

  final String body;
  final Duration? maxAge;
}

/// How a key document is fetched. Production uses [fetchJwksOverHttps]; tests
/// pass a fetcher that answers from a local fake key server, so no test ever
/// depends on Apple or Google being reachable.
typedef JwksFetcher = Future<JwksDocument> Function(Uri uri);

/// Raised by [JwksCache.keyFor] when there are no keys at all: the first fetch
/// failed and there is nothing cached to fall back on. This is a `503`, not a
/// rejected token — the token may well be fine.
class JwksUnavailableException implements Exception {
  const JwksUnavailableException(this.uri, this.reason);

  final Uri uri;
  final String reason;

  @override
  String toString() => 'no signing keys from $uri: $reason';
}

/// The provider's published signing keys, cached.
///
/// Refresh policy, in one place because every part of it is a trade-off between
/// following a key rotation quickly and not turning a token flood into a flood
/// of outbound requests:
///
/// * a document is used until [ttl] (the provider's `max-age`, clamped to
///   [minTtl]..[maxTtl]) has passed,
/// * a token naming an *unknown* `kid` triggers one immediate refresh, because
///   that is what a just-rotated key looks like,
/// * but no more than one fetch attempt per [minRefreshInterval], and
///   concurrent callers share the one in-flight fetch, so a caller cannot make
///   us hammer the provider by sending tokens with random `kid`s,
/// * a refresh that fails while keys are cached keeps the cached keys and logs;
///   a provider outage must not log everyone out.
class JwksCache {
  JwksCache({
    required this.uri,
    required this.log,
    JwksFetcher? fetch,
    this.minRefreshInterval = const Duration(minutes: 1),
    Duration? ttl,
    DateTime Function()? clock,
  }) : _fetch = fetch ?? fetchJwksOverHttps,
       _ttl = ttl ?? defaultTtl,
       _fixedTtl = ttl,
       _clock = clock ?? DateTime.now;

  /// Used when the provider sends no usable `cache-control: max-age`.
  static const Duration defaultTtl = Duration(hours: 1);

  /// Bounds on a provider-supplied `max-age`: long enough that a rotation is
  /// picked up within a day, short enough that a silly value cannot pin us to a
  /// document for a minute or a year.
  static const Duration minTtl = Duration(minutes: 5);
  static const Duration maxTtl = Duration(hours: 24);

  /// At most 32 keys per document; Apple publishes 3, Google 2-3.
  static const int maxKeys = 32;

  final Uri uri;
  final Logger log;
  final Duration minRefreshInterval;
  final JwksFetcher _fetch;
  final Duration? _fixedTtl;
  final DateTime Function() _clock;

  Duration _ttl;
  Map<String, SigningKey> _keys = const <String, SigningKey>{};
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

  /// The key published under [kid], or null when the provider does not publish
  /// one (which is a rejected token, not an outage).
  ///
  /// Throws [JwksUnavailableException] when no key document could be obtained
  /// at all.
  Future<SigningKey?> keyFor(String kid) async {
    if (!hasKeys || !_isFresh) await _loadIfUseful();
    if (!hasKeys) throw JwksUnavailableException(uri, _lastFailure);
    var key = _keys[kid];
    if (key == null) {
      // A kid we have never seen is what a key rotation looks like.
      await _loadIfUseful();
      key = _keys[kid];
    }
    return key;
  }

  /// Joins the fetch already under way, or starts one when the refresh budget
  /// allows, or does nothing. Never throws.
  ///
  /// Joining first is what makes a burst of sign-ins on a cold cache cost one
  /// fetch and succeed for all of them: checking the budget first instead would
  /// let the first caller start the fetch and then refuse everyone who arrived
  /// while it was in flight, because a fetch had just been *attempted*.
  Future<void> _loadIfUseful() {
    final running = _inFlight;
    if (running != null) return running;
    if (!_mayFetch) return Future<void>.value();
    return _load();
  }

  /// Loads the document, coalescing concurrent callers onto one fetch. Never
  /// throws: a failure leaves whatever was cached in place.
  Future<void> _load() {
    final running = _inFlight;
    if (running != null) return running;
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
      final keys = parseJwks(document.body, log: log, source: uri);
      if (keys.isEmpty) {
        throw const FormatException('document publishes no usable RSA key');
      }
      _keys = keys;
      _loadedAt = _clock();
      _ttl = _fixedTtl ?? _clampTtl(document.maxAge);
      log.info(
        'signing keys loaded from $uri: ${keys.length} key(s), '
        'good for ${_ttl.inMinutes} min',
      );
    } catch (e) {
      _lastFailure = '$e';
      if (hasKeys) {
        // Serving slightly stale keys beats refusing every sign-in while the
        // provider (or our egress) is having a bad minute.
        log.warn('keeping cached signing keys: refresh of $uri failed: $e');
      } else {
        log.error('cannot load signing keys from $uri', e);
      }
    }
  }

  static Duration _clampTtl(Duration? maxAge) {
    if (maxAge == null) return defaultTtl;
    if (maxAge < minTtl) return minTtl;
    if (maxAge > maxTtl) return maxTtl;
    return maxAge;
  }
}

/// Parses a JWKS document into RSA signing keys by `kid`.
///
/// Anything this build cannot verify with is skipped rather than failing the
/// whole document, so a provider adding an EC key (or a key for a different
/// use) does not take sign-in down.
Map<String, SigningKey> parseJwks(
  String body, {
  required Logger log,
  Uri? source,
}) {
  final Object? json = jsonDecode(body);
  if (json is! Map<String, dynamic>) {
    throw const FormatException('key document is not a JSON object');
  }
  final entries = json['keys'];
  if (entries is! List) {
    throw const FormatException('key document has no "keys" array');
  }
  final keys = <String, SigningKey>{};
  var skipped = 0;
  for (final entry in entries.take(JwksCache.maxKeys)) {
    if (entry is! Map<String, dynamic>) {
      skipped++;
      continue;
    }
    final kid = entry['kid'];
    final use = entry['use'];
    final alg = entry['alg'];
    if (entry['kty'] != 'RSA' ||
        kid is! String ||
        kid.isEmpty ||
        kid.length > maxKeyIdChars ||
        (use is String && use != 'sig') ||
        (alg is String && alg != idTokenAlgorithm)) {
      skipped++;
      continue;
    }
    final modulus = _base64UrlBigInt(entry['n']);
    final exponent = _base64UrlBigInt(entry['e']);
    if (modulus == null ||
        exponent == null ||
        modulus.bitLength < minRsaModulusBits ||
        exponent <= BigInt.two ||
        exponent.isEven) {
      skipped++;
      continue;
    }
    keys[kid] = SigningKey(kid: kid, key: RSAPublicKey(modulus, exponent));
  }
  if (skipped > 0) {
    log.info(
      'skipped $skipped key(s) this build cannot verify with'
      '${source == null ? '' : ' in $source'}',
    );
  }
  return keys;
}

class IdTokenVerifier {
  IdTokenVerifier({
    required this.log,
    this.clockSkew = idTokenClockSkew,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Logger log;
  final Duration clockSkew;
  final DateTime Function() _clock;

  /// Verifies [token] as an identity token issued by [provider] for this app.
  ///
  /// Throws [IdTokenException] on any failure. The signature is checked
  /// *before* a single payload claim is read, so nothing the caller wrote is
  /// acted on until it is known to come from the provider.
  Future<VerifiedIdToken> verify(AccountProvider provider, String token) async {
    if (token.isEmpty) {
      throw const IdTokenException('malformed_token', 'empty token');
    }
    if (token.length > maxIdTokenChars) {
      throw IdTokenException(
        'malformed_token',
        'token longer than $maxIdTokenChars characters',
      );
    }
    final parts = token.split('.');
    if (parts.length != 3) {
      throw const IdTokenException(
        'malformed_token',
        'expected three dot-separated segments',
      );
    }

    final header = _decodeJsonSegment(parts[0], 'header');
    final alg = header['alg'];
    if (alg != idTokenAlgorithm) {
      throw IdTokenException(
        'unsupported_algorithm',
        'header alg ${alg is String ? '"$alg"' : alg}, '
            'only $idTokenAlgorithm is accepted',
      );
    }
    final kid = header['kid'];
    if (kid is! String || kid.isEmpty || kid.length > maxKeyIdChars) {
      throw const IdTokenException(
        'malformed_token',
        'header carries no usable kid',
      );
    }

    final SigningKey? key;
    try {
      key = await provider.keys.keyFor(kid);
    } on JwksUnavailableException catch (e) {
      throw IdTokenException(IdTokenException.keysUnavailableCode, '$e');
    }
    if (key == null) {
      throw const IdTokenException(
        'unknown_key',
        'the provider publishes no key with the token\'s kid',
      );
    }

    final signature = _decodeBase64Url(parts[2], 'signature');
    if (signature.length != key.signatureBytes) {
      throw IdTokenException(
        'bad_signature',
        'signature is ${signature.length} bytes, '
            'the key signs ${key.signatureBytes}',
      );
    }
    final signed = utf8.encode('${parts[0]}.${parts[1]}');
    if (!verifyRs256(key.key, signed, signature)) {
      throw const IdTokenException(
        'bad_signature',
        'signature does not match the provider key',
      );
    }

    // Past this line the payload is the provider's word, not the caller's.
    final payload = _decodeJsonSegment(parts[1], 'payload');

    final issuer = payload['iss'];
    if (issuer is! String || !provider.issuers.contains(issuer)) {
      throw IdTokenException(
        'wrong_issuer',
        'iss ${issuer is String ? '"$issuer"' : issuer} is not '
            '${provider.name}',
      );
    }

    final audiences = _audiences(payload['aud']);
    if (audiences.isEmpty) {
      throw const IdTokenException('wrong_audience', 'token has no aud claim');
    }
    if (!audiences.any(provider.audiences.contains)) {
      // The likeliest cause is a missing or stale client id in the
      // environment, so name what the token asked for.
      log.warn(
        'refused ${provider.name} token for aud ${audiences.join(', ')}: '
        'not one of the ${provider.audiences.length} configured client id(s)',
      );
      throw IdTokenException(
        'wrong_audience',
        'aud ${audiences.join(', ')} is not a configured client id',
      );
    }

    final now = _clock().toUtc();
    final exp = _secondsClaim(payload['exp']);
    if (exp == null) {
      throw const IdTokenException('expired_token', 'token has no exp claim');
    }
    if (!now.isBefore(exp.add(clockSkew))) {
      throw IdTokenException(
        'expired_token',
        'expired at ${exp.toIso8601String()}',
      );
    }
    final notBefore = _secondsClaim(payload['nbf']);
    if (notBefore != null && now.add(clockSkew).isBefore(notBefore)) {
      throw IdTokenException(
        'token_not_yet_valid',
        'nbf ${notBefore.toIso8601String()}',
      );
    }
    final issuedAt = _secondsClaim(payload['iat']);
    if (issuedAt != null && now.add(clockSkew).isBefore(issuedAt)) {
      throw IdTokenException(
        'token_not_yet_valid',
        'iat ${issuedAt.toIso8601String()} is in the future',
      );
    }

    final subject = payload['sub'];
    if (subject is! String ||
        subject.isEmpty ||
        subject.length > maxSubjectChars) {
      throw const IdTokenException(
        'missing_subject',
        'token has no usable sub claim',
      );
    }

    // `email`, `name` and Apple's private-relay address are present in some of
    // these tokens and are deliberately dropped here (SPEC §4.5).
    return VerifiedIdToken(
      provider: provider.name,
      subject: subject,
      expiresAt: exp,
    );
  }

  Map<String, dynamic> _decodeJsonSegment(String segment, String what) {
    final bytes = _decodeBase64Url(segment, what);
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } catch (e) {
      throw IdTokenException('malformed_token', '$what is not JSON');
    }
    if (json is! Map<String, dynamic>) {
      throw IdTokenException('malformed_token', '$what is not a JSON object');
    }
    return json;
  }

  Uint8List _decodeBase64Url(String segment, String what) {
    try {
      return base64Url.decode(base64.normalize(segment));
    } on FormatException {
      throw IdTokenException('malformed_token', '$what is not base64url');
    }
  }

  static Set<String> _audiences(Object? claim) {
    if (claim is String) return claim.isEmpty ? const {} : {claim};
    if (claim is List) {
      return {
        for (final value in claim)
          if (value is String && value.isNotEmpty) value,
      };
    }
    return const {};
  }

  /// A numeric date claim (`exp`, `iat`, `nbf`) as a UTC instant.
  static DateTime? _secondsClaim(Object? claim) {
    if (claim is int) {
      return DateTime.fromMillisecondsSinceEpoch(claim * 1000, isUtc: true);
    }
    if (claim is double && claim.isFinite) {
      return DateTime.fromMillisecondsSinceEpoch(
        (claim * 1000).round(),
        isUtc: true,
      );
    }
    return null;
  }
}

/// One identity provider we accept tokens from: who signs them, who they may be
/// addressed to, and where the signing keys come from.
class AccountProvider {
  AccountProvider({
    required this.name,
    required this.issuers,
    required this.audiences,
    required this.keys,
  });

  /// Sign in with Apple. `aud` is the app's bundle id on iOS, or the Services
  /// ID when the sign-in went through the web flow — hence a set.
  factory AccountProvider.apple({
    required Set<String> audiences,
    required Logger log,
    JwksFetcher? fetch,
    Uri? jwksUri,
  }) => AccountProvider(
    name: appleProviderName,
    issuers: const {'https://appleid.apple.com'},
    audiences: audiences,
    keys: JwksCache(
      uri: jwksUri ?? Uri.parse('https://appleid.apple.com/auth/keys'),
      log: log,
      fetch: fetch,
    ),
  );

  /// Google Sign-In. `aud` is the OAuth client id the token was minted for:
  /// the iOS client id, the Android one, or the web/server client id when the
  /// app asks for one — hence a set.
  factory AccountProvider.google({
    required Set<String> audiences,
    required Logger log,
    JwksFetcher? fetch,
    Uri? jwksUri,
  }) => AccountProvider(
    name: googleProviderName,
    // Google mints both spellings and has for years.
    issuers: const {'https://accounts.google.com', 'accounts.google.com'},
    audiences: audiences,
    keys: JwksCache(
      uri: jwksUri ?? Uri.parse('https://www.googleapis.com/oauth2/v3/certs'),
      log: log,
      fetch: fetch,
    ),
  );

  final String name;
  final Set<String> issuers;
  final Set<String> audiences;
  final JwksCache keys;
}

const String appleProviderName = 'apple';
const String googleProviderName = 'google';

/// Provider names this build knows how to verify tokens for.
const List<String> supportedProviderNames = [
  appleProviderName,
  googleProviderName,
];

/// Whether [signature] is a PKCS#1 v1.5 SHA-256 signature of [message] under
/// [key].
///
/// Malformed input (a signature that is not a valid block, a number larger than
/// the modulus) makes the underlying signer throw; that is a rejected
/// signature, not a server error.
bool verifyRs256(RSAPublicKey key, List<int> message, Uint8List signature) {
  final signer = RSASigner(SHA256Digest(), sha256DigestIdentifier)
    ..init(false, PublicKeyParameter<RSAPublicKey>(key));
  try {
    return signer.verifySignature(
      Uint8List.fromList(message),
      RSASignature(signature),
    );
  } catch (_) {
    return false;
  }
}

/// Fetches a key document over HTTPS.
///
/// Guards, because this is the one place the server talks to the outside world:
/// HTTPS only (bar a loopback host, which is how the tests point it at their
/// own fake key server), no redirects — a redirect could move the trust anchor
/// to another host — a response-size cap, and a timeout on every step so a
/// hanging provider cannot pile up requests.
Future<JwksDocument> fetchJwksOverHttps(
  Uri uri, {
  Duration timeout = const Duration(seconds: 5),
  int maxBytes = 256 * 1024,
}) async {
  if (!isFetchableJwksUri(uri)) {
    throw StateError('refusing to fetch signing keys from $uri: HTTPS only');
  }
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = timeout;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw StateError('HTTP ${response.statusCode} from $uri');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      if (builder.length + chunk.length > maxBytes) {
        throw StateError('key document from $uri is over $maxBytes bytes');
      }
      builder.add(chunk);
    }
    return JwksDocument(
      utf8.decode(builder.takeBytes()),
      maxAge: _maxAge(response.headers),
    );
  } finally {
    client.close(force: true);
  }
}

/// HTTPS anywhere, plain HTTP only against loopback (the tests' fake key
/// server). A provider key document must never be fetched over a channel an
/// attacker on the path could rewrite.
bool isFetchableJwksUri(Uri uri) {
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  final host = uri.host;
  if (host == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  return address != null && address.isLoopback;
}

Duration? _maxAge(HttpHeaders headers) {
  final value = headers.value(HttpHeaders.cacheControlHeader);
  if (value == null) return null;
  for (final directive in value.split(',')) {
    final parts = directive.trim().split('=');
    if (parts.length != 2 || parts[0].toLowerCase() != 'max-age') continue;
    final seconds = int.tryParse(parts[1].trim());
    if (seconds != null && seconds > 0) return Duration(seconds: seconds);
  }
  return null;
}

BigInt? _base64UrlBigInt(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final Uint8List bytes;
  try {
    bytes = base64Url.decode(base64.normalize(value));
  } on FormatException {
    return null;
  }
  if (bytes.isEmpty) return null;
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}
