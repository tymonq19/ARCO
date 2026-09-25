import 'package:flutter/foundation.dart';

/// Resolves the server base URL from `--dart-define=SERVER_URL`, an optional
/// Settings override and the platform (Android emulator loopback mapping).
class ServerConfig {
  ServerConfig._();

  /// Compile-time default: `--dart-define=SERVER_URL=http://host:port`.
  static const String defaultBaseUrl = String.fromEnvironment(
    'SERVER_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// Effective HTTP base URL (no trailing slash). [override] comes from
  /// Settings; empty/blank means "use the default". On Android (not web) a
  /// `localhost` host is mapped to `10.0.2.2`, the emulator's loopback alias.
  static String resolveBaseUrl(
    String? override, {
    TargetPlatform? platform,
    bool? isWeb,
  }) {
    var raw = (override ?? '').trim();
    if (raw.isEmpty) raw = defaultBaseUrl;
    if (!raw.contains('://')) raw = 'http://$raw';
    while (raw.endsWith('/')) {
      raw = raw.substring(0, raw.length - 1);
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return defaultBaseUrl;
    final web = isWeb ?? kIsWeb;
    final tp = platform ?? defaultTargetPlatform;
    if (!web && tp == TargetPlatform.android && uri.host == 'localhost') {
      return uri.replace(host: '10.0.2.2').toString();
    }
    return uri.toString();
  }

  /// WebSocket endpoint derived from [baseUrl]: `http` → `ws`, `https` → `wss`,
  /// path `/ws`.
  static Uri wsUrl(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' || uri.scheme == 'wss' ? 'wss' : 'ws';
    return uri.replace(scheme: scheme, path: '/ws');
  }

  /// True when [url] parses to an absolute http(s) URL with a host.
  static bool isValidBaseUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }
}
