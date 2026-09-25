import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../app/account_config.dart';

/// A sign-in the server accepts (SPEC §4.5). The enum names are exactly the
/// `provider` strings of `POST /api/account/link` and of `GET /api/health`'s
/// `accounts`, so no table is needed to translate between them.
enum SignInProvider { apple, google }

/// Resolves a provider name the server advertised; null for one this build does
/// not know, which is then simply not offered.
SignInProvider? signInProviderByName(String name) {
  for (final provider in SignInProvider.values) {
    if (provider.name == name) return provider;
  }
  return null;
}

/// The provider cannot run on this device at all: an iPhone below iOS 13, an
/// Android build with no Apple Services ID, a missing Google client id, the web
/// build. The player is told it is unavailable rather than shown a failure they
/// could retry forever.
class SignInUnavailable implements Exception {
  const SignInUnavailable(this.message);
  final String message;
  @override
  String toString() => 'SignInUnavailable($message)';
}

/// The native flow failed for a reason of its own. [code] is the key the UI
/// shows (`account.error.<code>`); [message] is for the log only and never
/// carries anything from the token.
class SignInFailure implements Exception {
  const SignInFailure(this.code, [this.message = '']);

  /// One of `unknown`, `no_token`, `offline`.
  final String code;
  final String message;

  @override
  String toString() => 'SignInFailure($code, $message)';
}

/// The platform half of signing in: it produces a signed identity token and
/// nothing else.
///
/// Behind an interface because neither provider can work on a simulator without
/// configured client ids — and because a test must be able to play a cancel, a
/// failure and a token without a device (SPEC §4.5).
abstract class NativeSignIn {
  /// Whether this device can actually run [provider]'s sheet. Checked before a
  /// button is shown, so no button is offered that cannot work.
  Future<bool> isAvailable(SignInProvider provider);

  /// Runs the native sheet and returns the identity token to post to
  /// `POST /api/account/link`.
  ///
  /// Returns **null when the player backed out**: a cancelled sign-in is not an
  /// error and must stay silent. Throws [SignInUnavailable] or [SignInFailure]
  /// for everything else.
  Future<String?> identityToken(SignInProvider provider);

  /// Forgets the provider's own cached session, so signing in again asks which
  /// account to use instead of silently picking the last one. Best effort:
  /// failing to clear it must not fail a sign-out.
  Future<void> forgetSession();
}

/// [NativeSignIn] over `sign_in_with_apple` and `google_sign_in`.
///
/// Both packages are asked for the **identity token only**. No scopes are
/// requested from Apple and no authorization scopes from Google: the server
/// stores the provider name and the opaque `sub`, drops the address and the name
/// the token carries and has no column to put them in (SPEC §4.5), so asking for
/// them would be collecting data we throw away.
class PlatformSignIn implements NativeSignIn {
  PlatformSignIn({
    Future<bool> Function()? appleAvailable,
    GoogleSignIn? google,
    bool? isWeb,
  }) : _appleAvailable = appleAvailable ?? SignInWithApple.isAvailable,
       _google = google ?? GoogleSignIn.instance,
       _isWeb = isWeb ?? kIsWeb;

  final Future<bool> Function() _appleAvailable;
  final GoogleSignIn _google;
  final bool _isWeb;

  /// Providers that turned out not to be runnable here after all.
  ///
  /// Neither SDK can be asked up front whether it is configured: Google's
  /// `initialize` accepts a build with no client id at all and only the sheet
  /// itself reports `No active configuration`. So the first attempt that comes
  /// back [SignInUnavailable] is remembered, and [isAvailable] answers false
  /// from then on — which is what takes the dead button off the screen instead
  /// of leaving the player tapping it.
  final Set<SignInProvider> _unavailable = <SignInProvider>{};

  /// `GoogleSignIn.initialize` has to have completed before `authenticate`, and
  /// exactly once; concurrent callers share this.
  Future<void>? _googleInit;

  @override
  Future<bool> isAvailable(SignInProvider provider) async {
    // The web build keeps no credential (see `KeychainSecretStore`), so an
    // account it signed into would be gone on reload. Nothing is offered there.
    if (_isWeb) return false;
    if (_unavailable.contains(provider)) return false;
    switch (provider) {
      case SignInProvider.apple:
        // Apple is native on iOS 13+/macOS 10.15+. Elsewhere the package opens
        // Apple's web flow, which needs a Services ID and a Return URL — an
        // Android build without them is not offered the button.
        try {
          if (!await _appleAvailable()) return false;
        } on Object {
          return false;
        }
        return defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            AccountConfig.appleWebConfigured;
      case SignInProvider.google:
        try {
          await _initGoogle();
          return _google.supportsAuthenticate();
        } on Object {
          // No client id configured, or the SDK is missing: not available here.
          return false;
        }
    }
  }

  @override
  Future<String?> identityToken(SignInProvider provider) async {
    try {
      return await switch (provider) {
        SignInProvider.apple => _appleToken(),
        SignInProvider.google => _googleToken(),
      };
    } on SignInUnavailable {
      _unavailable.add(provider);
      rethrow;
    }
  }

  Future<String?> _appleToken() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        // Nothing is asked for beyond identification itself: see the class doc.
        scopes: const <AppleIDAuthorizationScopes>[],
        webAuthenticationOptions: AccountConfig.appleWebConfigured
            ? WebAuthenticationOptions(
                clientId: AccountConfig.appleServiceId,
                redirectUri: Uri.parse(AccountConfig.appleRedirectUri),
              )
            : null,
      );
      final token = credential.identityToken;
      if (token == null || token.isEmpty) {
        throw const SignInFailure(
          'no_token',
          'apple returned no identityToken',
        );
      }
      return token;
    } on SignInWithAppleNotSupportedException catch (e) {
      throw SignInUnavailable(e.message);
    } on SignInWithAppleAuthorizationException catch (e) {
      // A cancel is the player saying no. It is not an error, nothing is shown
      // and the offer is left exactly as it was.
      if (e.code == AuthorizationErrorCode.canceled) return null;
      throw SignInFailure('unknown', '${e.code}');
    } on SignInWithAppleException catch (e) {
      throw SignInFailure('unknown', '$e');
    }
  }

  Future<String?> _googleToken() async {
    try {
      await _initGoogle();
      final account = await _google.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        // Android hands back an idToken only when `serverClientId` is set; this
        // is what a build that forgot it looks like at runtime.
        throw const SignInFailure('no_token', 'google returned no idToken');
      }
      return token;
    } on GoogleSignInException catch (e) {
      switch (e.code) {
        case GoogleSignInExceptionCode.canceled:
          return null;
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
        case GoogleSignInExceptionCode.uiUnavailable:
          throw SignInUnavailable('${e.code}: ${e.description}');
        case GoogleSignInExceptionCode.interrupted:
        case GoogleSignInExceptionCode.unknownError:
        case GoogleSignInExceptionCode.userMismatch:
          throw SignInFailure('unknown', '${e.code}');
      }
    } on UnsupportedError catch (e) {
      throw SignInUnavailable('${e.message}');
    } on PlatformException catch (e) {
      // The native side could not even start: on iOS a build with neither
      // `GIDClientID` in `Info.plist` nor `--dart-define=GOOGLE_CLIENT_ID`
      // raises `No active configuration` here, and `initialize` accepted it
      // without a word. It is not something the player can retry, so it is
      // reported as unavailable and the button goes (see [_unavailable]).
      throw SignInUnavailable('${e.code}: ${e.message}');
    }
  }

  Future<void> _initGoogle() => _googleInit ??= _google
      .initialize(
        clientId: AccountConfig.googleClientIdOrNull,
        serverClientId: AccountConfig.googleServerClientIdOrNull,
      )
      .onError<Object>((error, _) {
        // Allowed to be retried: a failed init must not pin the failure for the
        // rest of the launch.
        _googleInit = null;
        throw error;
      });

  @override
  Future<void> forgetSession() async {
    try {
      await _google.signOut();
    } on Object {
      // Apple has nothing to clear (the credential lives in the system), and a
      // Google SDK that will not sign out must not fail a local sign-out.
    }
  }
}
