/// Server configuration read from environment variables (SPEC §4.3, §4.5, §4.9,
/// §4.10).
library;

import 'id_token.dart';
import 'logging.dart';

/// Sign in with Apple / Google, as configured (SPEC §4.5).
///
/// The whole feature is off unless [enabled], and a provider is offered only
/// when at least one client id is configured for it — so an Apple-only build
/// simply leaves `GOOGLE_CLIENT_IDS` unset and the Google endpoint answers
/// `invalid_provider`.
///
/// The client ids are the `aud` values a token may carry. They are the check
/// that stops a perfectly valid token minted for somebody else's app from
/// signing its bearer into Arco, which is why the server refuses to start with
/// accounts enabled and none of them set.
class AccountsConfig {
  const AccountsConfig({
    this.enabled = false,
    this.appleClientIds = const <String>{},
    this.googleClientIds = const <String>{},
  });

  /// `ACCOUNTS_ENABLED=on`. Off by default, so a deployment that has not been
  /// given client ids keeps running exactly as it did.
  final bool enabled;

  /// `aud` values accepted from Apple: the app's bundle id, plus the Services
  /// ID when sign-in goes through the web flow.
  final Set<String> appleClientIds;

  /// `aud` values accepted from Google: the iOS, Android and web OAuth client
  /// ids, whichever the app asks tokens for.
  final Set<String> googleClientIds;

  /// Longest accepted client id, and how many may be listed per provider.
  static const int maxClientIdChars = 255;
  static const int maxClientIdsPerProvider = 8;

  /// Provider names this server will accept tokens for, in the order clients
  /// should offer them. Empty when the feature is off.
  List<String> get providers => [
    if (enabled && appleClientIds.isNotEmpty) appleProviderName,
    if (enabled && googleClientIds.isNotEmpty) googleProviderName,
  ];

  /// Whether [provider] is configured and usable.
  bool offers(String provider) => providers.contains(provider);

  /// Accepted `aud` values for [provider]; empty for an unknown one.
  Set<String> audiencesFor(String provider) => switch (provider) {
    appleProviderName => appleClientIds,
    googleProviderName => googleClientIds,
    _ => const <String>{},
  };

  /// Client ids were configured but the feature is switched off, which is
  /// almost always a mistake worth a line in the log at startup.
  bool get hasUnusedClientIds =>
      !enabled && (appleClientIds.isNotEmpty || googleClientIds.isNotEmpty);

  @override
  String toString() => enabled
      ? 'AccountsConfig(providers: ${providers.join(', ')}, '
            'apple: ${appleClientIds.length}, google: ${googleClientIds.length})'
      : 'AccountsConfig(disabled)';

  /// Parses `ACCOUNTS_ENABLED`, `APPLE_CLIENT_IDS` and `GOOGLE_CLIENT_IDS`.
  ///
  /// Throws [FormatException] when accounts are enabled with no client id for
  /// any provider: that configuration would accept a token from anybody's app,
  /// so it must not start.
  factory AccountsConfig.fromEnvironment(String? Function(String key) read) {
    var enabled = false;
    final raw = read('ACCOUNTS_ENABLED')?.toLowerCase();
    if (raw != null) {
      switch (raw) {
        case 'on':
          enabled = true;
        case 'off':
          enabled = false;
        default:
          throw FormatException(
            'ACCOUNTS_ENABLED must be "on" or "off", got "$raw"',
          );
      }
    }
    final config = AccountsConfig(
      enabled: enabled,
      appleClientIds: _clientIds('APPLE_CLIENT_IDS', read),
      googleClientIds: _clientIds('GOOGLE_CLIENT_IDS', read),
    );
    if (enabled && config.providers.isEmpty) {
      throw const FormatException(
        'ACCOUNTS_ENABLED=on needs APPLE_CLIENT_IDS and/or '
        'GOOGLE_CLIENT_IDS: without a client id to check "aud" against, a '
        'token minted for any other app would be accepted',
      );
    }
    return config;
  }

  static Set<String> _clientIds(String key, String? Function(String key) read) {
    final raw = read(key);
    if (raw == null) return const <String>{};
    final ids = <String>{};
    for (final part in raw.split(',')) {
      final id = part.trim();
      if (id.isEmpty) continue;
      if (id.length > maxClientIdChars) {
        throw FormatException(
          '$key holds a client id longer than $maxClientIdChars characters',
        );
      }
      // A client id is an ASCII identifier (a bundle id, or
      // `1234-abc.apps.googleusercontent.com`); whitespace or a control
      // character in there is a quoting accident, not a client id.
      if (id.codeUnits.any((c) => c <= 0x20 || c == 0x7f)) {
        throw FormatException('$key holds a client id with whitespace: "$id"');
      }
      ids.add(id);
    }
    if (ids.length > maxClientIdsPerProvider) {
      throw FormatException(
        '$key lists ${ids.length} client ids, at most '
        '$maxClientIdsPerProvider are accepted',
      );
    }
    return ids;
  }
}

/// The one-time unlock, through RevenueCat (SPEC §4.9).
///
/// The whole feature is off unless [enabled], and it refuses to start enabled
/// without its two secrets, for the same reason accounts refuse to start without
/// client ids: a granting path with nothing to verify against is a granting path
/// anybody can drive.
///
/// **What each secret is for**, because they are not interchangeable:
///
/// * [webhookSecret] is the value RevenueCat is configured to send in the
///   `Authorization` header of every webhook it posts to us. It is the *only*
///   thing that makes `POST /api/purchases/webhook` trustworthy — the endpoint is
///   otherwise unauthenticated, and a body claiming a purchase unlocks the whole
///   catalogue.
/// * [apiKey] is a RevenueCat **secret** API key, used by the server to ask
///   RevenueCat what a player actually bought. It is what makes the client nudge
///   and **Restore purchases** (`POST /api/purchases/sync`) safe: the phone says
///   "look again", and the answer comes from RevenueCat, never from the phone.
///
/// Neither ever leaves the server, and neither is the *public* SDK key the app is
/// built with — that one is not a secret and is not configured here.
class PurchasesConfig {
  const PurchasesConfig({
    this.enabled = false,
    this.webhookSecret = '',
    this.apiKey = '',
    this.creditSandbox = false,
  });

  /// `PURCHASES_ENABLED=on`. Off by default, so a deployment that has not been
  /// given keys keeps running exactly as it did: the two endpoints answer
  /// `404 purchases_disabled` and the catalogue advertises no product to buy.
  final bool enabled;

  /// `REVENUECAT_WEBHOOK_SECRET` — the exact `Authorization` header value
  /// RevenueCat is told to send. Compared in constant time.
  final String webhookSecret;

  /// `REVENUECAT_API_KEY` — a RevenueCat secret API key (`sk_…`), for the
  /// server-to-RevenueCat re-verification of the sync path.
  final String apiKey;

  /// `PURCHASES_SANDBOX=on` grants premium from **sandbox** purchases too.
  ///
  /// Off in production, and that is not a detail: a sandbox purchase costs
  /// nothing, and a StoreKit sandbox account can make them all day. A staging
  /// deployment turns it on so a human can walk the whole flow — buy, reinstall,
  /// restore, refund — on TestFlight before any real money exists. Sandbox events
  /// are otherwise acknowledged and ignored: acknowledged, so RevenueCat stops
  /// retrying them.
  final bool creditSandbox;

  /// Longest accepted secret, generous enough for any key either side issues.
  static const int maxSecretChars = 512;

  /// Whether keys were configured while the feature is switched off — almost
  /// always a mistake worth a line in the log at startup, exactly as with
  /// accounts.
  bool get hasUnusedKeys =>
      !enabled && (webhookSecret.isNotEmpty || apiKey.isNotEmpty);

  @override
  String toString() => enabled
      ? 'PurchasesConfig(enabled, sandbox: ${creditSandbox ? 'granted' : 'ignored'})'
      : 'PurchasesConfig(disabled)';

  /// Parses `PURCHASES_ENABLED`, `REVENUECAT_WEBHOOK_SECRET`,
  /// `REVENUECAT_API_KEY` and `PURCHASES_SANDBOX`.
  ///
  /// Throws [FormatException] when the feature is enabled without either secret.
  factory PurchasesConfig.fromEnvironment(String? Function(String key) read) {
    final enabled = _flag('PURCHASES_ENABLED', read) ?? false;
    final config = PurchasesConfig(
      enabled: enabled,
      webhookSecret: _secret('REVENUECAT_WEBHOOK_SECRET', read),
      apiKey: _secret('REVENUECAT_API_KEY', read),
      creditSandbox: _flag('PURCHASES_SANDBOX', read) ?? false,
    );
    if (!enabled) return config;
    final missing = <String>[
      if (config.webhookSecret.isEmpty) 'REVENUECAT_WEBHOOK_SECRET',
      if (config.apiKey.isEmpty) 'REVENUECAT_API_KEY',
    ];
    if (missing.isNotEmpty) {
      throw FormatException(
        'PURCHASES_ENABLED=on needs ${missing.join(' and ')}: without the '
        'webhook secret any caller could claim a purchase, and without the API '
        'key the server cannot re-verify one for itself',
      );
    }
    return config;
  }

  static String _secret(String key, String? Function(String key) read) {
    final raw = read(key);
    if (raw == null) return '';
    if (raw.length > maxSecretChars) {
      throw FormatException('$key is longer than $maxSecretChars characters');
    }
    // A key is an ASCII token. Whitespace or a control character in there is a
    // quoting accident, and one that would make every comparison fail silently.
    if (raw.codeUnits.any((c) => c <= 0x20 || c == 0x7f)) {
      throw FormatException('$key holds whitespace or a control character');
    }
    return raw;
  }

  static bool? _flag(String key, String? Function(String key) read) {
    final raw = read(key)?.toLowerCase();
    return switch (raw) {
      null => null,
      'on' => true,
      'off' => false,
      _ => throw FormatException('$key must be "on" or "off", got "$raw"'),
    };
  }
}

/// Rewarded ads that pay Sparks, through AdMob (SPEC §4.10).
///
/// The whole feature is off unless [enabled], and — unlike purchases — it needs
/// **no secret to be trustworthy**. What authenticates AdMob's server-side
/// verification callback is Google's own ECDSA signature over the query string,
/// checked against the keys Google publishes at [defaultKeysUrl]. There is
/// nothing shared to leak and nothing to rotate on our side, which is the whole
/// reason this is the design the task asks for: a client saying "I watched an ad"
/// is a Spark printer, and a signed callback from Google is not.
///
/// [callbackKey] is therefore **optional defence in depth**, not the
/// authentication. AdMob appends its own parameters to whatever URL is typed into
/// the dashboard, so a key put in that URL arrives inside the signed content and
/// cannot be stripped or forged. What it buys is a revocable URL: if the SSV URL
/// leaks, a caller still cannot forge a reward, but it can make us verify
/// signatures — and changing one environment variable makes every such call a
/// `401` before any cryptography runs.
class AdsConfig {
  const AdsConfig({
    this.enabled = false,
    this.callbackKey = '',
    this.keysUrl = '',
  });

  /// `ADS_ENABLED=on`. Off by default, so a deployment that has not been
  /// configured for ads keeps running exactly as it did: the two ad routes answer
  /// `404 ads_disabled` and no client ever offers an ad button.
  final bool enabled;

  /// `ADMOB_CALLBACK_KEY` — an opaque value that must appear as the
  /// `arco_key` query parameter of every callback. Empty (the default) means the
  /// parameter is not required. Compared in constant time.
  final String callbackKey;

  /// `ADMOB_SSV_KEYS_URL` — where Google's verification keys are published.
  /// Overridable so the tests can point it at a fake key server on loopback and
  /// so a staging deployment can be pinned; production leaves it unset.
  final String keysUrl;

  /// Google's published rewarded-ad verifier keys (ECDSA P-256).
  ///
  /// Documented at
  /// <https://developers.google.com/admob/android/rewarded-video-ssv>; the same
  /// document serves both platforms, because the signature is minted by AdMob's
  /// servers rather than by the SDK.
  static const String defaultKeysUrl =
      'https://www.gstatic.com/admob/reward/verifier-keys.json';

  /// Longest accepted callback key / URL.
  static const int maxValueChars = 512;

  /// Where the keys are actually fetched from.
  Uri get keysUri => Uri.parse(keysUrl.isEmpty ? defaultKeysUrl : keysUrl);

  /// Whether the callback must carry [callbackKey].
  bool get requiresKey => callbackKey.isNotEmpty;

  /// A callback key or a keys URL was configured while the feature is switched
  /// off — almost always a mistake worth a line in the log at startup, exactly as
  /// with accounts and purchases.
  bool get hasUnusedSettings =>
      !enabled && (callbackKey.isNotEmpty || keysUrl.isNotEmpty);

  /// Never prints [callbackKey]: a value that gates a crediting path does not
  /// belong in a log line, a crash report or a `/api/health` body.
  @override
  String toString() => enabled
      ? 'AdsConfig(enabled, key: ${requiresKey ? 'required' : 'none'}, '
            'keys: $keysUri)'
      : 'AdsConfig(disabled)';

  /// Parses `ADS_ENABLED`, `ADMOB_CALLBACK_KEY` and `ADMOB_SSV_KEYS_URL`.
  ///
  /// Throws [FormatException] for a keys URL that is not an absolute HTTP(S) one:
  /// a relative or malformed URL would make every reward fail at the moment a
  /// player had already watched an ad, and that is worth refusing to start over.
  factory AdsConfig.fromEnvironment(String? Function(String key) read) {
    final config = AdsConfig(
      enabled: _flag('ADS_ENABLED', read) ?? false,
      callbackKey: _opaque('ADMOB_CALLBACK_KEY', read),
      keysUrl: _opaque('ADMOB_SSV_KEYS_URL', read),
    );
    if (config.keysUrl.isNotEmpty) {
      final uri = Uri.tryParse(config.keysUrl);
      if (uri == null ||
          !uri.isAbsolute ||
          (uri.scheme != 'https' && uri.scheme != 'http')) {
        throw FormatException(
          'ADMOB_SSV_KEYS_URL must be an absolute http(s) URL, got '
          '"${config.keysUrl}"',
        );
      }
    }
    return config;
  }

  static String _opaque(String key, String? Function(String key) read) {
    final raw = read(key);
    if (raw == null) return '';
    if (raw.length > maxValueChars) {
      throw FormatException('$key is longer than $maxValueChars characters');
    }
    // Whitespace or a control character is a quoting accident, and one that
    // would make every comparison fail silently.
    if (raw.codeUnits.any((c) => c <= 0x20 || c == 0x7f)) {
      throw FormatException('$key holds whitespace or a control character');
    }
    return raw;
  }

  static bool? _flag(String key, String? Function(String key) read) {
    final raw = read(key)?.toLowerCase();
    return switch (raw) {
      null => null,
      'on' => true,
      'off' => false,
      _ => throw FormatException('$key must be "on" or "off", got "$raw"'),
    };
  }
}

/// Immutable runtime configuration.
///
/// Environment variables (SPEC §4.3):
/// `PORT` (8080), `DB_PATH` (`data/arco.db`),
/// `VERIFY_REPLAYS` (`strict`|`off`), `LOG_LEVEL` (`debug|info|warn|error`)
/// plus the optional `HOST` bind address, `ACCOUNTS_ENABLED`,
/// `APPLE_CLIENT_IDS`, `GOOGLE_CLIENT_IDS` (SPEC §4.5), and
/// `PURCHASES_ENABLED`, `REVENUECAT_WEBHOOK_SECRET`, `REVENUECAT_API_KEY`,
/// `PURCHASES_SANDBOX` (SPEC §4.9), and `ADS_ENABLED`, `ADMOB_CALLBACK_KEY`,
/// `ADMOB_SSV_KEYS_URL` (SPEC §4.10).
class ServerConfig {
  const ServerConfig({
    this.host,
    this.port = defaultPort,
    this.dbPath = defaultDbPath,
    this.verifyReplays = true,
    this.logLevel = LogLevel.info,
    this.accounts = const AccountsConfig(),
    this.purchases = const PurchasesConfig(),
    this.ads = const AdsConfig(),
  });

  static const int defaultPort = 8080;
  static const String defaultDbPath = 'data/arco.db';

  /// Bind address; null = whatever the caller passes to the server (all
  /// interfaces in production).
  final String? host;

  /// TCP port; 0 lets the OS pick a free one (used by the tests).
  final int port;

  /// SQLite file path; parent directories are created on startup.
  /// `:memory:` opens an in-memory database.
  final String dbPath;

  /// `VERIFY_REPLAYS=strict` (default) re-simulates every submitted replay;
  /// `off` trusts the claimed score (development only).
  final bool verifyReplays;

  final LogLevel logLevel;

  /// Sign in with Apple / Google (SPEC §4.5); disabled by default.
  final AccountsConfig accounts;

  /// The one-time unlock (SPEC §4.9); disabled by default.
  final PurchasesConfig purchases;

  /// Rewarded ads that pay Sparks (SPEC §4.10); disabled by default.
  final AdsConfig ads;

  /// Parses [env]. Throws [FormatException] on an invalid value so the entry
  /// point can exit with a usage error instead of starting half-configured.
  factory ServerConfig.fromEnvironment(Map<String, String> env) {
    String? read(String key) {
      final raw = env[key]?.trim();
      return (raw == null || raw.isEmpty) ? null : raw;
    }

    var port = defaultPort;
    final rawPort = read('PORT');
    if (rawPort != null) {
      final parsed = int.tryParse(rawPort);
      if (parsed == null || parsed < 0 || parsed > 65535) {
        throw FormatException(
          'PORT must be an integer in 0..65535, got "$rawPort"',
        );
      }
      port = parsed;
    }

    var verifyReplays = true;
    final rawVerify = read('VERIFY_REPLAYS')?.toLowerCase();
    if (rawVerify != null) {
      switch (rawVerify) {
        case 'strict':
          verifyReplays = true;
        case 'off':
          verifyReplays = false;
        default:
          throw FormatException(
            'VERIFY_REPLAYS must be "strict" or "off", got "$rawVerify"',
          );
      }
    }

    var logLevel = LogLevel.info;
    final rawLevel = read('LOG_LEVEL');
    if (rawLevel != null) {
      final parsed = parseLogLevel(rawLevel);
      if (parsed == null) {
        throw FormatException(
          'LOG_LEVEL must be debug|info|warn|error, got "$rawLevel"',
        );
      }
      logLevel = parsed;
    }

    return ServerConfig(
      host: read('HOST'),
      port: port,
      dbPath: read('DB_PATH') ?? defaultDbPath,
      verifyReplays: verifyReplays,
      logLevel: logLevel,
      accounts: AccountsConfig.fromEnvironment(read),
      purchases: PurchasesConfig.fromEnvironment(read),
      ads: AdsConfig.fromEnvironment(read),
    );
  }

  @override
  String toString() =>
      'ServerConfig(host: ${host ?? '*'}, port: $port, dbPath: $dbPath, '
      'verifyReplays: ${verifyReplays ? 'strict' : 'off'}, '
      'logLevel: ${logLevel.name}, purchases: '
      '${purchases.enabled ? 'on' : 'off'}, '
      'ads: ${ads.enabled ? 'on' : 'off'})';
}
