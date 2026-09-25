/// Locally signed identity tokens and a fake key server, so the account tests
/// exercise the real verification path (SPEC §4.5) without ever reaching Apple
/// or Google.
///
/// Nothing here is reachable from the server: the keys are fixtures, and the key
/// server binds a loopback port that only the test that started it knows.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:arco_server/arco_server.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart' show PrivateKeyParameter;
import 'package:pointycastle/asymmetric/api.dart'
    show RSAPrivateKey, RSAPublicKey;
import 'package:pointycastle/digests/sha256.dart' show SHA256Digest;
import 'package:pointycastle/signers/rsa_signer.dart' show RSASigner;
import 'package:test/test.dart';

/// `aud` values the tests configure the server with.
const String appleAudience = 'com.arco.game';
const String googleAudience =
    '1234567890-abcdefghijklmnop.apps.googleusercontent.com';

/// Issuers the providers actually use.
const String appleIssuer = 'https://appleid.apple.com';
const String googleIssuer = 'https://accounts.google.com';

/// One RSA keypair a test can sign tokens with.
class TestKey {
  TestKey({
    required this.kid,
    required this.modulus,
    required this.privateExponent,
    required this.p,
    required this.q,
  });

  final String kid;
  final BigInt modulus;
  final BigInt privateExponent;
  final BigInt p;
  final BigInt q;

  static final BigInt publicExponent = BigInt.from(65537);

  RSAPublicKey get publicKey => RSAPublicKey(modulus, publicExponent);
  RSAPrivateKey get privateKey => RSAPrivateKey(modulus, privateExponent, p, q);

  /// This key as a JWKS entry, the way a provider publishes it.
  Map<String, dynamic> jwk({String? kidOverride}) => {
    'kty': 'RSA',
    'use': 'sig',
    'alg': 'RS256',
    'kid': kidOverride ?? kid,
    'n': base64UrlNoPad(_bytes(modulus, 256)),
    'e': base64UrlNoPad(_bytes(publicExponent, 3)),
  };

  /// The modulus as bytes — what an `alg: HS256` confusion attack would use as
  /// its "shared secret".
  Uint8List get modulusBytes => _bytes(modulus, 256);

  static Uint8List _bytes(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }
}

/// A fixed 2048-bit RSA keypair. Generated once for these tests and used
/// nowhere else, so it is committed rather than generated: pure-Dart RSA key
/// generation takes seconds, and a fixture that changes per run would make a
/// signature failure impossible to tell from a flake.
final TestKey providerKey = TestKey(
  kid: 'arco-test-key-1',
  modulus: BigInt.parse(
    '19238892951734785241548675527450525949700171853713638303082635902582231858641057807667577952958161911803348461791638769345405224782947328611924859208204771830365183727060499546189594891574204533341709728428109113053702304127110970945939081010535850454118679417269291195874086877445213475072173166983610284476819572642255629410444248085868008652678898129868155713458537102567166837646999457006523460982384753511070561793487478477922103576821414207430265365744468115309813261198886891043972457714586029624861773429389000598685338447290421344008121573430802419231344308026219265257569246762540231733026745391699050644989',
  ),
  privateExponent: BigInt.parse(
    '1549397698998370332863785486578327905801570212916376748457667459508812117581022981046881554476298557616278944433469176565986370697535682140069569966597567568254076929237305897505053356695128729221318399478822037912895627831345525499376939279698616334236208400817054777176609099274544710948486045674039017371365633681109387992090180284075181851572405674566757350181395404952894133153328131006663728950675956435580289316334458590491354497837443200284858925618527294019547026161103782302866772805453102455030663117942128927364353926899533963802219523513916816429453057632070635083717492929796008895005570680670971084993',
  ),
  p: BigInt.parse(
    '139129930893700726717172584394710564087757596921778966683393072006944888197156291265553290429867625426794526920748117502723346195283853435909895193407089941217054360589628745299986012270865887878659343751940230852281707606034408872266693054657660013113709780556125580270510016729938507214578856124077536669461',
  ),
  q: BigInt.parse(
    '138280043899639779290897919541658640599334793256801820886907832303718955044828819059704387255728542082262881988197600337640610408295326020275807950234039169136515351249603242223149065877410938336701753519704680410920936012302856468386737174981636836140926486918177578226620932544909220738231882124928556037449',
  ),
);

/// A fixed 2048-bit RSA keypair. Generated once for these tests and used
/// nowhere else, so it is committed rather than generated: pure-Dart RSA key
/// generation takes seconds, and a fixture that changes per run would make a
/// signature failure impossible to tell from a flake.
final TestKey strangerKey = TestKey(
  kid: 'arco-test-key-2',
  modulus: BigInt.parse(
    '26435894982800917494932057807151408275393635817038523792956419843079316913223418666769060645058099017347288270792612551718456052204643236058453194753321282383442365007159190499002050701186683407321556934453830376298957338642623397945700988632777922610873914675269437383932582299345026360323036704193479244571076755504132618382521198750755273242539806224509631215441397043158368805639534707389475529525982336769442701194184601770361470425266943259929610416517485435053988246300258174530051279141726820884089618043959268409094152175509307097734060475364043012463470266501806274926276712881531386732058727730538754961531',
  ),
  privateExponent: BigInt.parse(
    '18090498774564834334997221852314362243234413829173500695279147918312116894643390456799347419161170403436092350405222816416212475842254601991997022724521306625762900130324478927922302971555310396441051396865669541118080454147189742451879059740342467205585750421235084422457672016739028979168523888943179534621802430533540362420746897768371951982714469193441639614118204138934540131308415892463678083782564949938810602687000620472780320932822914621579842324863182150888969720657266633812296280873553156299455306359797075553039818058890225652940430768288546408429650832377839470129639257903548857754902586605184606563329',
  ),
  p: BigInt.parse(
    '164147330226564477253563178804921559953348174021751451543410345835300652874577375893879787533296353573057741990195681964777398850245566322481600273572455830922852406786431760794230538475721969068180244073779248659418918989669705921742665548845335442240445571769393007789535849595967089576690702888724219546529',
  ),
  q: BigInt.parse(
    '161049801701390777179661993512235889437194593241520162790585148684266944560362871444042259633205981320273862426028706107657655837989282851770206752725658202445209854348037897410533964006843836733912352633620508946081526529456067492956320647591520940512579934619443561600570509084153275689905778624726068586139',
  ),
);

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String _segment(Map<String, dynamic> json) =>
    base64UrlNoPad(utf8.encode(jsonEncode(json)));

/// Seconds-since-epoch, the way a JWT date claim is written.
int _epoch(DateTime t) => t.toUtc().millisecondsSinceEpoch ~/ 1000;

/// Builds and signs an identity token.
///
/// [key] signs it; [kid] overrides the `kid` in the header, which is how a
/// "signed by the wrong key" token is built (announce the provider's kid, sign
/// with another key). [alg] overrides the algorithm, which is how `none` and the
/// HMAC confusion attack are built — both produce a token whose signature
/// segment is *not* an RS256 signature, exactly as an attacker would send it.
/// [swapPayloadFor] signs [claims] and then ships a different payload, which is
/// a token carrying a real provider signature over something else.
String signIdToken({
  required TestKey key,
  required Map<String, dynamic> claims,
  String? kid,
  bool omitKid = false,
  String alg = 'RS256',
  Map<String, dynamic>? swapPayloadFor,
}) {
  final header = <String, dynamic>{
    'alg': alg,
    if (!omitKid) 'kid': kid ?? key.kid,
  };
  final signingInput = '${_segment(header)}.${_segment(claims)}';
  final String signature;
  switch (alg) {
    case 'none':
      signature = '';
    case 'HS256':
      // The classic forgery: claim the token is HMAC-signed and use the
      // provider's *public* key material as the shared secret, which is
      // something an attacker has.
      signature = base64UrlNoPad(
        Hmac(sha256, key.modulusBytes).convert(utf8.encode(signingInput)).bytes,
      );
    default:
      final signer = RSASigner(SHA256Digest(), sha256DigestIdentifier)
        ..init(true, PrivateKeyParameter<RSAPrivateKey>(key.privateKey));
      signature = base64UrlNoPad(
        signer
            .generateSignature(Uint8List.fromList(utf8.encode(signingInput)))
            .bytes,
      );
  }
  if (swapPayloadFor == null) return '$signingInput.$signature';
  // Signed over [claims], sent with another payload: the signature is genuine
  // but does not cover what the server will read.
  return '${_segment(header)}.${_segment(swapPayloadFor)}.$signature';
}

/// Claims of a well-formed Apple identity token for this app.
Map<String, dynamic> appleClaims({
  String subject = 'apple.000123.abcdef',
  String? audience,
  Object? audienceClaim,
  String issuer = appleIssuer,
  DateTime? now,
  Duration life = const Duration(minutes: 10),
  Duration? notBefore,
  Duration? issuedIn,
  Map<String, dynamic> extra = const {},
}) {
  final issued = (now ?? DateTime.now()).toUtc();
  return {
    'iss': issuer,
    'aud': audienceClaim ?? audience ?? appleAudience,
    'sub': subject,
    'iat': _epoch(issued.add(issuedIn ?? Duration.zero)),
    'exp': _epoch(issued.add(life)),
    if (notBefore != null) 'nbf': _epoch(issued.add(notBefore)),
    // Both providers send these and the server must drop them (SPEC §4.5);
    // every happy-path test therefore ships them.
    'email': 'nobody@privaterelay.appleid.com',
    'email_verified': 'true',
    'is_private_email': 'true',
    'name': 'Ada Lovelace',
    ...extra,
  };
}

/// Claims of a well-formed Google identity token for this app.
Map<String, dynamic> googleClaims({
  String subject = '107123456789012345678',
  String? audience,
  Object? audienceClaim,
  String issuer = googleIssuer,
  DateTime? now,
  Duration life = const Duration(hours: 1),
  Map<String, dynamic> extra = const {},
}) => appleClaims(
  subject: subject,
  audience: audience ?? googleAudience,
  audienceClaim: audienceClaim,
  issuer: issuer,
  now: now,
  life: life,
  extra: {
    'email': 'ada@example.com',
    'email_verified': true,
    'name': 'Ada Lovelace',
    'picture': 'https://example.invalid/ada.jpg',
    ...extra,
  },
);

/// An HTTP server on loopback that serves a JWKS document, standing in for
/// `https://appleid.apple.com/auth/keys`.
///
/// A real socket rather than a stubbed fetcher, so the tests also cover
/// [fetchJwksOverHttps] itself: its HTTPS-or-loopback rule, its `max-age`
/// parsing and its size cap.
class FakeKeyServer {
  FakeKeyServer._(this._server) {
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
      response.statusCode = 200;
      response.headers.contentType = ContentType.json;
      if (maxAge != null) {
        response.headers.set('cache-control', 'public, max-age=$maxAge');
      }
      response.write(
        jsonEncode({
          'keys': [for (final k in keys) k.jwk()],
        }),
      );
      await response.close();
    });
  }

  static Future<FakeKeyServer> start({List<TestKey>? keys, int? maxAge}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeKeyServer._(server)
      ..keys = keys ?? [providerKey]
      ..maxAge = maxAge;
    addTearDown(fake.stop);
    return fake;
  }

  final HttpServer _server;

  /// Keys the document currently publishes; reassign to simulate a rotation.
  List<TestKey> keys = const [];

  /// `cache-control: max-age` to advertise, or null for no header.
  int? maxAge;

  /// Set to make every request fail with this status (a provider outage).
  int? status;

  /// Requests served, so a test can assert the document is cached.
  int requests = 0;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/auth/keys');

  Future<void> stop() => _server.close(force: true);
}
