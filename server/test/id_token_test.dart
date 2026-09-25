/// Identity token verification (SPEC §4.5).
///
/// The threat model these cases encode: the token arrives from a device the
/// player controls, so *everything* that decides whose account it is has to be
/// checked here. A token that fails any single check is refused — there is no
/// "mostly valid".
///
/// Every key is a local fixture and every document comes from a loopback server
/// ([FakeKeyServer]), so nothing in this file talks to Apple or Google.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arco_server/arco_server.dart';
import 'package:test/test.dart';

import 'id_token_support.dart';
import 'support.dart';

void main() {
  late FakeKeyServer keyServer;
  late Logger log;

  setUp(() async {
    log = silentLogger();
    keyServer = await FakeKeyServer.start();
  });

  /// An Apple provider whose keys come from the fake server.
  AccountProvider apple({Set<String>? audiences, Uri? jwksUri}) =>
      AccountProvider.apple(
        audiences: audiences ?? const {appleAudience},
        log: log,
        jwksUri: jwksUri ?? keyServer.uri,
      );

  AccountProvider google({Set<String>? audiences}) => AccountProvider.google(
    audiences: audiences ?? const {googleAudience},
    log: log,
    jwksUri: keyServer.uri,
  );

  IdTokenVerifier verifier({DateTime? now, Duration? skew}) => IdTokenVerifier(
    log: log,
    clockSkew: skew ?? idTokenClockSkew,
    clock: now == null ? null : () => now,
  );

  /// Verifies [token] and returns the failure code, failing the test if it was
  /// accepted.
  Future<String> refusalOf(AccountProvider provider, String token) async {
    try {
      final ok = await verifier().verify(provider, token);
      fail('token was accepted (subject ${ok.subject}) but should not be');
    } on IdTokenException catch (e) {
      return e.code;
    }
  }

  group('a well-formed token', () {
    test('is accepted and yields only the provider and the subject', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(subject: 'apple.42'),
      );
      final result = await verifier().verify(apple(), token);
      expect(result.provider, 'apple');
      expect(result.subject, 'apple.42');
      expect(result.expiresAt.isAfter(DateTime.now().toUtc()), isTrue);
    });

    test('from Google is accepted under either issuer spelling', () async {
      for (final issuer in [
        'https://accounts.google.com',
        'accounts.google.com',
      ]) {
        final token = signIdToken(
          key: providerKey,
          claims: googleClaims(subject: 'g-1', issuer: issuer),
        );
        final result = await verifier().verify(google(), token);
        expect(result.provider, 'google', reason: issuer);
        expect(result.subject, 'g-1', reason: issuer);
      }
    });

    test('is accepted when aud is an array containing our client id', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(
          audienceClaim: ['someone.elses.app', appleAudience],
        ),
      );
      expect((await verifier().verify(apple(), token)).subject, isNotEmpty);
    });

    test('is accepted for any one of several configured client ids', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(audience: 'com.arco.game.services'),
      );
      final result = await verifier().verify(
        apple(audiences: const {appleAudience, 'com.arco.game.services'}),
        token,
      );
      expect(result.subject, isNotEmpty);
    });

    test('is still accepted just inside the clock skew after expiry', () async {
      final issued = DateTime.utc(2026, 9, 23, 12);
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(now: issued, life: const Duration(minutes: 10)),
      );
      // 30 s past exp, with a 60 s skew: the provider's clock may run ahead.
      final justAfter = issued.add(const Duration(minutes: 10, seconds: 30));
      expect(
        (await verifier(now: justAfter).verify(apple(), token)).subject,
        isNotEmpty,
      );
    });
  });

  group('a forged signature is refused', () {
    test(
      'when the token is signed with a key that is not the provider\'s',
      () async {
        // Announces the provider's kid, so the right key is looked up and the
        // signature is what fails.
        final token = signIdToken(
          key: strangerKey,
          kid: providerKey.kid,
          claims: appleClaims(),
        );
        expect(await refusalOf(apple(), token), 'bad_signature');
      },
    );

    test('when the payload is changed after signing', () async {
      final honest = appleClaims(subject: 'the-victim');
      final token = signIdToken(
        key: providerKey,
        claims: honest,
        // A real provider signature, over a payload that is not the one sent.
        swapPayloadFor: {...honest, 'sub': 'the-attacker'},
      );
      expect(await refusalOf(apple(), token), 'bad_signature');
    });

    test('when alg is "none"', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(),
        alg: 'none',
      );
      expect(await refusalOf(apple(), token), 'unsupported_algorithm');
    });

    test('when alg is HS256 keyed on the public modulus', () async {
      // The classic JWT forgery: downgrade to a symmetric algorithm whose
      // "secret" is the provider's published key material.
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(),
        alg: 'HS256',
      );
      expect(await refusalOf(apple(), token), 'unsupported_algorithm');
    });

    test('when the signature is the right length but random', () async {
      final token = signIdToken(key: providerKey, claims: appleClaims());
      final parts = token.split('.');
      final flipped = base64UrlNoPad(
        List<int>.generate(256, (i) => (i * 7 + 3) & 0xff),
      );
      expect(
        await refusalOf(apple(), '${parts[0]}.${parts[1]}.$flipped'),
        'bad_signature',
      );
    });
  });

  group('claims are checked', () {
    test('a wrong audience is refused', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(audience: 'com.somebody.else'),
      );
      expect(await refusalOf(apple(), token), 'wrong_audience');
    });

    test('an aud array with none of our client ids is refused', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(audienceClaim: ['a.b.c', 'd.e.f']),
      );
      expect(await refusalOf(apple(), token), 'wrong_audience');
    });

    test('a missing aud is refused', () async {
      final claims = appleClaims()..remove('aud');
      expect(
        await refusalOf(apple(), signIdToken(key: providerKey, claims: claims)),
        'wrong_audience',
      );
    });

    test('a wrong issuer is refused', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(issuer: 'https://evil.example'),
      );
      expect(await refusalOf(apple(), token), 'wrong_issuer');
    });

    test("an Apple-issued token is refused by the Google provider", () async {
      // Same signing key, so only `iss`/`aud` can catch this.
      final token = signIdToken(key: providerKey, claims: appleClaims());
      expect(await refusalOf(google(), token), 'wrong_issuer');
    });

    test('an expired token is refused', () async {
      final issued = DateTime.utc(2026, 9, 23, 12);
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(now: issued, life: const Duration(minutes: 10)),
      );
      final wellAfter = issued.add(const Duration(hours: 1));
      try {
        await verifier(now: wellAfter).verify(apple(), token);
        fail('an expired token was accepted');
      } on IdTokenException catch (e) {
        expect(e.code, 'expired_token');
      }
    });

    test('a missing exp is refused', () async {
      final claims = appleClaims()..remove('exp');
      expect(
        await refusalOf(apple(), signIdToken(key: providerKey, claims: claims)),
        'expired_token',
      );
    });

    test('an nbf in the future is refused', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(notBefore: const Duration(hours: 2)),
      );
      expect(await refusalOf(apple(), token), 'token_not_yet_valid');
    });

    test('an iat in the future is refused', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(issuedIn: const Duration(hours: 2)),
      );
      expect(await refusalOf(apple(), token), 'token_not_yet_valid');
    });

    test('a missing or unusable sub is refused', () async {
      for (final sub in <Object?>[null, '', 123, 'x' * 300]) {
        final claims = appleClaims();
        if (sub == null) {
          claims.remove('sub');
        } else {
          claims['sub'] = sub;
        }
        expect(
          await refusalOf(
            apple(),
            signIdToken(key: providerKey, claims: claims),
          ),
          'missing_subject',
          reason: 'sub = $sub',
        );
      }
    });
  });

  group('malformed input is refused before any key is used', () {
    test('a token that is not three segments', () async {
      for (final token in ['', 'a', 'a.b', 'a.b.c.d']) {
        final code = await refusalOf(apple(), token);
        expect(code, 'malformed_token', reason: 'token "$token"');
      }
    });

    test('segments that are not base64url, or not JSON', () async {
      expect(await refusalOf(apple(), '!!!.???.***'), 'malformed_token');
      final notJson =
          '${base64UrlNoPad(utf8.encode('hello'))}.'
          '${base64UrlNoPad(utf8.encode('{}'))}.x';
      expect(await refusalOf(apple(), notJson), 'malformed_token');
    });

    test('a token with no kid', () async {
      final token = signIdToken(
        key: providerKey,
        claims: appleClaims(),
        omitKid: true,
      );
      expect(await refusalOf(apple(), token), 'malformed_token');
    });

    test('a token naming a kid the provider does not publish', () async {
      final token = signIdToken(
        key: providerKey,
        kid: 'no-such-key',
        claims: appleClaims(),
      );
      expect(await refusalOf(apple(), token), 'unknown_key');
    });

    test('a token longer than the cap, without decoding it', () async {
      final huge = signIdToken(
        key: providerKey,
        claims: appleClaims(extra: {'padding': 'x' * (maxIdTokenChars + 100)}),
      );
      expect(huge.length, greaterThan(maxIdTokenChars));
      expect(await refusalOf(apple(), huge), 'malformed_token');
      expect(
        keyServer.requests,
        0,
        reason: 'an oversized token must not cost a key fetch',
      );
    });
  });

  group('the signing keys are cached', () {
    test('one document serves many verifications', () async {
      final provider = apple();
      for (var i = 0; i < 5; i++) {
        final token = signIdToken(
          key: providerKey,
          claims: appleClaims(subject: 'sub-$i'),
        );
        await verifier().verify(provider, token);
      }
      expect(keyServer.requests, 1);
    });

    test(
      'an unknown kid triggers exactly one refresh, then rotation works',
      () async {
        // The refresh budget is what decides *when* a rotation is noticed, so
        // it is opened up here and measured on its own in the next case.
        final provider = AccountProvider(
          name: appleProviderName,
          issuers: const {appleIssuer},
          audiences: const {appleAudience},
          keys: JwksCache(
            uri: keyServer.uri,
            log: log,
            minRefreshInterval: Duration.zero,
          ),
        );
        // Warm the cache on the old document.
        await verifier().verify(
          provider,
          signIdToken(key: providerKey, claims: appleClaims()),
        );
        expect(keyServer.requests, 1);

        // The provider rotates: a second key appears under a new kid.
        keyServer.keys = [providerKey, strangerKey];
        final rotated = signIdToken(key: strangerKey, claims: appleClaims());
        expect(
          (await verifier().verify(provider, rotated)).subject,
          isNotEmpty,
        );
        expect(keyServer.requests, 2, reason: 'one refresh, not a flood');

        // And the key that was there all along still verifies.
        final old = signIdToken(
          key: providerKey,
          claims: appleClaims(subject: 'unrotated'),
        );
        expect((await verifier().verify(provider, old)).subject, 'unrotated');
        expect(keyServer.requests, 2, reason: 'a known kid needs no fetch');
      },
    );

    test(
      'a rotation is not noticed before the refresh budget allows it',
      () async {
        // The production setting: at most one fetch attempt per minute, so a
        // freshly rotated kid is briefly unknown rather than a lever for making
        // us re-fetch on demand.
        final provider = apple();
        await verifier().verify(
          provider,
          signIdToken(key: providerKey, claims: appleClaims()),
        );
        keyServer.keys = [providerKey, strangerKey];
        final rotated = signIdToken(key: strangerKey, claims: appleClaims());
        expect(await refusalOf(provider, rotated), 'unknown_key');
        expect(keyServer.requests, 1);
      },
    );

    test('a flood of unknown kids cannot hammer the provider', () async {
      final provider = AccountProvider.apple(
        audiences: const {appleAudience},
        log: log,
        jwksUri: keyServer.uri,
      );
      for (var i = 0; i < 25; i++) {
        final token = signIdToken(
          key: providerKey,
          kid: 'made-up-$i',
          claims: appleClaims(),
        );
        expect(await refusalOf(provider, token), 'unknown_key');
      }
      // The first call loads the document; every later miss is inside
      // minRefreshInterval, so it is answered from cache.
      expect(keyServer.requests, lessThanOrEqualTo(2));
    });

    test(
      'a provider outage does not sign anyone out while keys are cached',
      () async {
        final provider = apple();
        await verifier().verify(
          provider,
          signIdToken(key: providerKey, claims: appleClaims()),
        );
        keyServer.status = HttpStatus.internalServerError;
        // The cached document is still good, so this never reaches the server.
        final later = await verifier().verify(
          provider,
          signIdToken(
            key: providerKey,
            claims: appleClaims(subject: 'later'),
          ),
        );
        expect(later.subject, 'later');
      },
    );

    test(
      'no keys at all is a server-side failure, not a rejected token',
      () async {
        keyServer.status = HttpStatus.serviceUnavailable;
        final token = signIdToken(key: providerKey, claims: appleClaims());
        try {
          await verifier().verify(apple(), token);
          fail('a token was accepted with no signing keys');
        } on IdTokenException catch (e) {
          expect(e.code, IdTokenException.keysUnavailableCode);
          expect(
            e.isServerSide,
            isTrue,
            reason: 'this is a 503: the token may well be fine',
          );
        }
      },
    );

    test(
      'a cached document is refetched once its max-age has passed',
      () async {
        var now = DateTime.utc(2026, 9, 23, 12);
        final cache = JwksCache(
          uri: keyServer.uri,
          log: log,
          minRefreshInterval: Duration.zero,
          clock: () => now,
        );
        keyServer.maxAge = 600;
        expect(await cache.keyFor(providerKey.kid), isNotNull);
        expect(keyServer.requests, 1);

        now = now.add(const Duration(minutes: 5));
        expect(await cache.keyFor(providerKey.kid), isNotNull);
        expect(keyServer.requests, 1, reason: 'still inside max-age');

        now = now.add(const Duration(minutes: 6));
        expect(await cache.keyFor(providerKey.kid), isNotNull);
        expect(keyServer.requests, 2, reason: 'max-age expired');
      },
    );

    test('concurrent callers on a cold cache share one fetch', () async {
      // A burst of sign-ins on a just-started server. Each must get the key,
      // and between them they must cost exactly one request: checking the
      // refresh budget before joining the fetch already in flight would
      // instead refuse everyone who arrived while the first one was running.
      final cache = JwksCache(uri: keyServer.uri, log: log);
      final keys = await Future.wait([
        for (var i = 0; i < 8; i++) cache.keyFor(providerKey.kid),
      ]);
      expect(keys.every((k) => k != null), isTrue);
      expect(cache.attempts, 1);
      expect(keyServer.requests, 1);
    });

    test('concurrent verifications on a cold cache all succeed', () async {
      final provider = apple();
      final results = await Future.wait([
        for (var i = 0; i < 8; i++)
          verifier().verify(
            provider,
            signIdToken(
              key: providerKey,
              claims: appleClaims(subject: 's$i'),
            ),
          ),
      ]);
      expect(
        [for (final r in results) r.subject],
        [for (var i = 0; i < 8; i++) 's$i'],
      );
      expect(keyServer.requests, 1);
    });
  });

  group('the key document is parsed defensively', () {
    test('entries this build cannot verify with are skipped, not fatal', () {
      final keys = parseJwks(
        jsonEncode({
          'keys': [
            // An EC key: a provider adding one must not take sign-in down.
            {'kty': 'EC', 'kid': 'ec-1', 'crv': 'P-256', 'x': 'AA', 'y': 'BB'},
            // Encryption key, not a signing key.
            {...providerKey.jwk(kidOverride: 'enc-1'), 'use': 'enc'},
            // Another algorithm.
            {...providerKey.jwk(kidOverride: 'ps-1'), 'alg': 'PS256'},
            // A 512-bit modulus: too short to trust.
            {
              'kty': 'RSA',
              'kid': 'short-1',
              'use': 'sig',
              'alg': 'RS256',
              'n': base64UrlNoPad(List<int>.filled(64, 0xff)),
              'e': 'AQAB',
            },
            // An even exponent is not a usable RSA exponent.
            {...providerKey.jwk(kidOverride: 'even-1'), 'e': 'AQAC'},
            providerKey.jwk(),
          ],
        }),
        log: log,
      );
      expect(keys.keys, [providerKey.kid]);
      expect(keys[providerKey.kid]!.signatureBytes, 256);
    });

    test('a document with no usable key is a failure', () {
      expect(
        () => parseJwks('{"keys":[]}', log: log),
        returnsNormally,
        reason: 'parsing is not where emptiness is rejected',
      );
      expect(parseJwks('{"keys":[]}', log: log), isEmpty);
      expect(() => parseJwks('{}', log: log), throwsFormatException);
      expect(() => parseJwks('[]', log: log), throwsFormatException);
      expect(() => parseJwks('not json', log: log), throwsA(isA<Object>()));
    });

    test('at most maxKeys entries are read', () {
      final keys = parseJwks(
        jsonEncode({
          'keys': [
            for (var i = 0; i < JwksCache.maxKeys + 10; i++)
              providerKey.jwk(kidOverride: 'k-$i'),
          ],
        }),
        log: log,
      );
      expect(keys, hasLength(JwksCache.maxKeys));
    });
  });

  group('keys are only ever fetched over a channel we trust', () {
    test('HTTPS anywhere, plain HTTP only on loopback', () {
      expect(
        isFetchableJwksUri(Uri.parse('https://appleid.apple.com/x')),
        isTrue,
      );
      expect(isFetchableJwksUri(Uri.parse('http://127.0.0.1:1/x')), isTrue);
      expect(isFetchableJwksUri(Uri.parse('http://localhost:1/x')), isTrue);
      expect(isFetchableJwksUri(Uri.parse('http://[::1]:1/x')), isTrue);
      expect(
        isFetchableJwksUri(Uri.parse('http://appleid.apple.com/x')),
        isFalse,
      );
      expect(isFetchableJwksUri(Uri.parse('http://10.0.0.1/x')), isFalse);
      expect(isFetchableJwksUri(Uri.parse('file:///etc/passwd')), isFalse);
    });

    test('a plain-HTTP provider URL is refused rather than fetched', () {
      expect(
        fetchJwksOverHttps(Uri.parse('http://appleid.apple.com/auth/keys')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('HTTPS only'),
          ),
        ),
      );
    });

    test('a document over the size cap is refused', () async {
      expect(
        fetchJwksOverHttps(keyServer.uri, maxBytes: 8),
        throwsA(isA<StateError>()),
      );
    });

    test('a non-200 answer is a failure', () async {
      keyServer.status = HttpStatus.notFound;
      expect(fetchJwksOverHttps(keyServer.uri), throwsA(isA<StateError>()));
    });

    test('max-age is read from cache-control', () async {
      keyServer.maxAge = 1234;
      final document = await fetchJwksOverHttps(keyServer.uri);
      expect(document.maxAge, const Duration(seconds: 1234));
      keyServer.maxAge = null;
      expect((await fetchJwksOverHttps(keyServer.uri)).maxAge, isNull);
    });
  });
}
