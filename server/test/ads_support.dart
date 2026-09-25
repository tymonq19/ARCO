/// Helpers for the rewarded-ad tests (SPEC §4.10): a stand-in for AdMob's
/// published verifier keys, and a signer that mints callbacks exactly as Google's
/// ad servers do.
///
/// **Nothing here is a stub of the thing under test.** The signature the server
/// verifies is a real ECDSA/SHA-256 signature over the real query string, made
/// with a real P-256 keypair generated in the test and published in the real
/// document shape. That is what makes these tests worth having: the whole
/// verification path — the DER `SubjectPublicKeyInfo`, the named-curve OID, the
/// split at `&signature=`, the DER `SEQUENCE { r, s }` — runs, and it runs without
/// an AdMob account and without ever reaching gstatic.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arco_server/arco_server.dart';
import 'package:pointycastle/api.dart'
    show
        KeyGenerator,
        KeyParameter,
        ParametersWithRandom,
        PrivateKeyParameter,
        SecureRandom;
import 'package:pointycastle/digests/sha256.dart' show SHA256Digest;
import 'package:pointycastle/ecc/api.dart'
    show ECPrivateKey, ECPublicKey, ECSignature;
import 'package:pointycastle/ecc/curves/prime256v1.dart'
    show ECCurve_prime256v1;
import 'package:pointycastle/key_generators/api.dart'
    show ECKeyGeneratorParameters;
import 'package:pointycastle/key_generators/ec_key_generator.dart'
    show ECKeyGenerator;
import 'package:pointycastle/random/fortuna_random.dart' show FortunaRandom;
import 'package:pointycastle/signers/ecdsa_signer.dart' show ECDSASigner;
import 'package:test/test.dart';

/// An `AdsConfig` with the feature on, pointed at [keysUrl].
///
/// Unlike purchases, there is no secret this needs in order to start: what
/// authenticates a callback is Google's signature. [callbackKey] is the optional
/// extra of SPEC §4.10.
AdsConfig testAdsConfig({required Uri keysUrl, String callbackKey = ''}) =>
    AdsConfig(
      enabled: true,
      callbackKey: callbackKey,
      keysUrl: keysUrl.toString(),
    );

/// One P-256 keypair, in the two shapes the feature needs it: the DER
/// `SubjectPublicKeyInfo` Google publishes, and the private key that signs.
class TestVerifierKey {
  TestVerifierKey._(this.keyId, this._public, this._private);

  /// Generates a fresh keypair. [keyId] is the `keyId` the document publishes and
  /// the `key_id` a callback names — a number in Google's document, so it is one
  /// here too.
  factory TestVerifierKey.generate({int keyId = 3335741209}) {
    final generator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(ECCurve_prime256v1()),
          _seededRandom(keyId),
        ),
      );
    final pair = (generator as KeyGenerator).generateKeyPair();
    return TestVerifierKey._(
      '$keyId',
      pair.publicKey as ECPublicKey,
      pair.privateKey as ECPrivateKey,
    );
  }

  final String keyId;
  final ECPublicKey _public;
  final ECPrivateKey _private;

  /// `k` for the signature. Seeded from the key id, so the same test run produces
  /// the same signature twice — a signature that changes between runs would make
  /// a failure impossible to read.
  final SecureRandom _random = _seededRandom(20260924);

  /// The public key as the published document carries it: base64 of the DER
  /// `SubjectPublicKeyInfo`, which is exactly what Google's `base64` field holds.
  String get base64Spki => base64.encode(_encodeSpki());

  /// One entry of the `{"keys":[…]}` document, in Google's own shape — `keyId` as
  /// a number, and both the `pem` and `base64` encodings, so the parser is tested
  /// against a document that looks like the real one rather than the minimum it
  /// happens to read.
  Map<String, dynamic> get published => <String, dynamic>{
    'keyId': int.parse(keyId),
    'pem':
        '-----BEGIN PUBLIC KEY-----\n'
        '$base64Spki\n'
        '-----END PUBLIC KEY-----',
    'base64': base64Spki,
  };

  /// Signs [content] the way AdMob's servers do: ECDSA over SHA-256, DER-encoded,
  /// then base64url without padding.
  String sign(String content) {
    final signer = ECDSASigner(SHA256Digest())
      ..init(
        true,
        ParametersWithRandom(
          PrivateKeyParameter<ECPrivateKey>(_private),
          _random,
        ),
      );
    final signature =
        signer.generateSignature(Uint8List.fromList(ascii.encode(content)))
            as ECSignature;
    return base64Url
        .encode(_encodeDerSignature(signature.r, signature.s))
        .replaceAll('=', '');
  }

  /// DER: `SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING }`.
  Uint8List _encodeSpki() {
    final point = _public.Q!.getEncoded(false);
    final algorithm = _derSequence([
      ..._derOid('1.2.840.10045.2.1'),
      ..._derOid('1.2.840.10045.3.1.7'),
    ]);
    final bitString = <int>[
      0x03,
      ..._derLength(point.length + 1),
      0x00,
      ...point,
    ];
    return Uint8List.fromList(_derSequence([...algorithm, ...bitString]));
  }

  static List<int> _encodeDerSignature(BigInt r, BigInt s) =>
      Uint8List.fromList(_derSequence([..._derInteger(r), ..._derInteger(s)]));

  static List<int> _derSequence(List<int> contents) => <int>[
    0x30,
    ..._derLength(contents.length),
    ...contents,
  ];

  static List<int> _derInteger(BigInt value) {
    var bytes = <int>[];
    var v = value;
    while (v > BigInt.zero) {
      bytes.insert(0, (v & BigInt.from(0xff)).toInt());
      v >>= 8;
    }
    if (bytes.isEmpty) bytes = <int>[0];
    // A leading high bit would read as a negative two's-complement integer.
    if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
    return <int>[0x02, ..._derLength(bytes.length), ...bytes];
  }

  static List<int> _derOid(String oid) {
    final parts = oid.split('.').map(int.parse).toList();
    final body = <int>[parts[0] * 40 + parts[1]];
    for (final part in parts.skip(2)) {
      final chunks = <int>[part & 0x7f];
      var rest = part >> 7;
      while (rest > 0) {
        chunks.insert(0, (rest & 0x7f) | 0x80);
        rest >>= 7;
      }
      body.addAll(chunks);
    }
    return <int>[0x06, ..._derLength(body.length), ...body];
  }

  static List<int> _derLength(int length) {
    if (length < 0x80) return <int>[length];
    final bytes = <int>[];
    var rest = length;
    while (rest > 0) {
      bytes.insert(0, rest & 0xff);
      rest >>= 8;
    }
    return <int>[0x80 | bytes.length, ...bytes];
  }
}

/// A [FortunaRandom] seeded from [seed].
///
/// Deterministic on purpose: key generation and `k` selection here prove nothing
/// about entropy, and a signature that changed between runs would make a failing
/// assertion impossible to read.
SecureRandom _seededRandom(int seed) {
  final source = Random(seed);
  return FortunaRandom()..seed(
    KeyParameter(
      Uint8List.fromList(List<int>.generate(32, (_) => source.nextInt(256))),
    ),
  );
}

/// A stand-in for `https://www.gstatic.com/admob/reward/verifier-keys.json`, on
/// loopback.
///
/// Serves whatever [keys] currently holds, in Google's own document shape, so a
/// test can rotate a key and watch the cache pick it up.
class FakeAdMobKeyServer {
  FakeAdMobKeyServer._(this._server) {
    _server.listen((request) async {
      requests++;
      await request.drain<void>();
      final response = request.response;
      final failWith = status;
      if (failWith != null) {
        response.statusCode = failWith;
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'keys': [for (final key in keys) key.published],
        }),
      );
      await response.close();
    });
  }

  final HttpServer _server;

  static Future<FakeAdMobKeyServer> start({List<TestVerifierKey>? keys}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeAdMobKeyServer._(server)
      ..keys = keys ?? <TestVerifierKey>[TestVerifierKey.generate()];
    addTearDown(fake.stop);
    return fake;
  }

  /// Keys the document publishes; reassign to simulate a rotation.
  List<TestVerifierKey> keys = const <TestVerifierKey>[];

  /// Set to make every request fail with this status (gstatic having a bad day).
  int? status;

  /// Requests served, so a test can assert the document is cached.
  int requests = 0;

  Uri get uri =>
      Uri.parse('http://127.0.0.1:${_server.port}/admob/verifier-keys.json');

  Future<void> stop() => _server.close(force: true);
}

/// Builds the query string of one AdMob server-side verification callback, signed
/// by [key] (SPEC §4.10).
///
/// The parameter order matters and is Google's: everything else first, then
/// `signature`, then `key_id`. The signed content is the query string up to
/// `&signature=`, which is what the server reconstructs — so a test that builds it
/// this way is testing the split, not agreeing with it.
///
/// [tamperCustomData] rewrites `custom_data` **after** signing: the shape of every
/// "somebody edited the query string" attack, and the one thing the signature
/// exists to stop.
String adCallbackQuery({
  required TestVerifierKey key,
  required String playerId,
  String placement = 'shop',
  String transactionId = 'admob-txn-1',
  String adUnit = 'ca-app-pub-3940256099942544/1712485313',
  String adNetwork = '5450213213286189855',
  int rewardAmount = 10,
  String rewardItem = 'sparks',
  DateTime? rewardedAt,
  String? customData,
  String? userId,
  String? callbackKey,
  String? tamperCustomData,
  String? signature,
  String? keyId,
}) {
  final at = rewardedAt ?? DateTime.utc(2026, 9, 24, 12);
  final data =
      customData ?? AdCustomData.encode(playerId, _placement(placement));
  final params = <String, String>{
    'arco_key': ?callbackKey,
    'ad_network': adNetwork,
    'ad_unit': adUnit,
    'custom_data': data,
    'reward_amount': '$rewardAmount',
    'reward_item': rewardItem,
    'timestamp': '${at.millisecondsSinceEpoch}',
    'transaction_id': transactionId,
    'user_id': ?userId,
  };
  var content = params.entries
      .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  final signed = signature ?? key.sign(content);
  if (tamperCustomData != null) {
    content = content.replaceFirst(
      'custom_data=${Uri.encodeQueryComponent(data)}',
      'custom_data=${Uri.encodeQueryComponent(tamperCustomData)}',
    );
  }
  return '$content&signature=$signed&key_id=${keyId ?? key.keyId}';
}

AdPlacement _placement(String name) =>
    AdPlacement.parse(name) ?? AdPlacement.shop;
