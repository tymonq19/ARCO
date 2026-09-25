import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A two-key string store for the player's credential (SPEC §4.4).
///
/// The player secret is issued exactly once by `POST /api/players` and the
/// server keeps only a salted digest of it, so losing it costs the player their
/// scores — and leaking it hands somebody else their identity. It therefore
/// lives here rather than in `shared_preferences`, whose file is world-readable
/// on a rooted phone and lands in plain text in a device backup, and it is
/// never written to a log.
///
/// Every method may throw: a keychain can be locked, a platform can be missing
/// the plugin, and the web build has no keychain at all. Callers treat a throw
/// as "no credential storage on this device" and fall back to anonymous
/// submissions (see [PlayerIdentity]).
abstract class SecretStore {
  /// The stored value for [key], or null when nothing is stored.
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// The platform keychain: iOS/macOS Keychain, the Android Keystore-backed
/// encrypted preferences, libsecret on Linux and the credential store on
/// Windows — everything `flutter_secure_storage` wraps.
///
/// On the **web** every method throws instead of falling back to the package's
/// browser implementation, which keeps the value in `localStorage` where any
/// script on the origin can read it. A browser player submits anonymously,
/// which is exactly what §4.4 allows; it is not somewhere to keep a credential.
class KeychainSecretStore implements SecretStore {
  KeychainSecretStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(iOptions: _ios, mOptions: _macos);

  /// `kSecAttrAccessibleAfterFirstUnlock`, not the package's default
  /// `WhenUnlocked`: a pending replay is retried at launch, which can happen
  /// while the screen is still locked, and the credential has to be readable
  /// then. `synchronizable` stays false (the default), so the secret is never
  /// copied into the iCloud keychain — one device, one credential, which is
  /// what §4.4 issues.
  static const IOSOptions _ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  static const MacOsOptions _macos = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) {
    if (kIsWeb) throw UnsupportedError('no keychain on the web');
    return _storage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) {
    if (kIsWeb) throw UnsupportedError('no keychain on the web');
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) {
    if (kIsWeb) throw UnsupportedError('no keychain on the web');
    return _storage.delete(key: key);
  }
}
