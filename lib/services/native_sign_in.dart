import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';

import '../app/account_config.dart';

/// A way of signing in that the server accepts (SPEC §4.5). The enum names are
/// exactly the method strings of `GET /api/health`'s `firebase` list, so no
/// table is needed to translate between them.
enum SignInProvider { apple, google, email }

/// Resolves a method name the server advertised; null for one this build does
/// not know, which is then simply not offered.
SignInProvider? signInProviderByName(String name) {
  for (final provider in SignInProvider.values) {
    if (provider.name == name) return provider;
  }
  return null;
}

/// What the player typed into the e-mail form. [create] is a new account rather
/// than signing in to an existing one.
class EmailSignIn {
  const EmailSignIn({
    required this.email,
    required this.password,
    this.create = false,
  });

  final String email;
  final String password;
  final bool create;

  @override
  String toString() => 'EmailSignIn($email, create: $create)';
}

/// The provider cannot run on this device at all: an unconfigured build, a
/// method switched off in the Firebase console, the web build. The player is
/// told it is unavailable rather than shown a failure they could retry forever.
class SignInUnavailable implements Exception {
  const SignInUnavailable(this.message);
  final String message;
  @override
  String toString() => 'SignInUnavailable($message)';
}

/// The sign-in failed for a reason of its own. [code] is the key the UI shows
/// (`account.error.<code>`); [message] is for the log only and never carries
/// anything from the token.
class SignInFailure implements Exception {
  const SignInFailure(this.code, [this.message = '']);

  /// One of `unknown`, `no_token`, `offline`, `rate_limited`, `email_invalid`,
  /// `email_wrong`, `email_taken`, `email_weak`, `other_method`, `disabled`.
  final String code;
  final String message;

  @override
  String toString() => 'SignInFailure($code, $message)';
}

/// The device half of signing in: it signs the player in to Firebase and hands
/// back the Firebase ID token the server verifies, and nothing else.
///
/// Behind an interface because none of it can work on a simulator without a
/// configured Firebase project — and because a test must be able to play a
/// cancel, a failure and a token without a device (SPEC §4.5).
abstract class NativeSignIn {
  /// Whether this device can actually run [provider]. Checked before a button
  /// is shown, so no button is offered that cannot work.
  Future<bool> isAvailable(SignInProvider provider);

  /// Signs in with [provider] and returns the ID token to post to
  /// `POST /api/account/link`. [email] is required for [SignInProvider.email]
  /// and ignored otherwise.
  ///
  /// Returns **null when the player backed out**: a cancelled sign-in is not an
  /// error and must stay silent. Throws [SignInUnavailable] or [SignInFailure]
  /// for everything else.
  Future<String?> identityToken(SignInProvider provider, {EmailSignIn? email});

  /// Sends the "reset your password" e-mail. Throws [SignInFailure].
  Future<void> sendPasswordReset(String email);

  /// Deletes the signed-in user from the sign-in provider itself — which for
  /// Sign in with Apple also revokes the app's access, as Apple requires of an
  /// account deletion. Signing in again may be needed first; [askPassword] is
  /// how an e-mail account's password is asked for when it is.
  ///
  /// Returns false when the player backed out of that, and nothing was deleted;
  /// true when the user is gone, or there was none on this device. Throws
  /// [SignInFailure].
  Future<bool> deleteUser({Future<String?> Function()? askPassword});

  /// Signs out of the provider on this device, so signing in again asks which
  /// account to use instead of silently picking the last one. Best effort:
  /// failing to clear it must not fail a sign-out.
  Future<void> forgetSession();
}

/// [NativeSignIn] over Firebase Authentication.
///
/// Apple goes through Firebase's own provider flow: native on iOS, Apple's web
/// page hosted by Firebase on Android, so there is no callback endpoint of ours
/// to run. Google goes through `google_sign_in` and its token is exchanged for a
/// Firebase session. E-mail is Firebase's password sign-in.
///
/// Nothing is asked of Apple or Google beyond identification: no e-mail or name
/// scopes. The server stores the Firebase uid and drops everything else the
/// token carries (SPEC §4.5).
class FirebaseSignIn implements NativeSignIn {
  FirebaseSignIn({
    required bool ready,
    FirebaseAuth? auth,
    GoogleSignIn? google,
    bool? isWeb,
  }) : _ready = ready,
       _authOverride = auth,
       _google = google ?? GoogleSignIn.instance,
       _isWeb = isWeb ?? kIsWeb;

  /// Whether `Firebase.initializeApp` succeeded. False in a build that has no
  /// Firebase configuration yet, which then offers no sign-in at all.
  final bool _ready;
  final FirebaseAuth? _authOverride;
  final GoogleSignIn _google;
  final bool _isWeb;

  /// Read only once Firebase is known to be up: touching the instance before
  /// `initializeApp` throws.
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  /// Providers that turned out not to be runnable here after all.
  ///
  /// Google cannot be asked up front whether it is configured: `initialize`
  /// accepts a build with no client id and only the sheet reports it. So the
  /// first attempt that comes back [SignInUnavailable] is remembered, and
  /// [isAvailable] answers false from then on.
  final Set<SignInProvider> _unavailable = <SignInProvider>{};

  /// `GoogleSignIn.initialize` has to have completed before `authenticate`, and
  /// exactly once; concurrent callers share this.
  Future<void>? _googleInit;

  @override
  Future<bool> isAvailable(SignInProvider provider) async {
    // The web build keeps no credential (see `KeychainSecretStore`), so an
    // account it signed into would be gone on reload. Nothing is offered there.
    if (_isWeb || !_ready) return false;
    if (_unavailable.contains(provider)) return false;
    switch (provider) {
      case SignInProvider.apple:
      case SignInProvider.email:
        return true;
      case SignInProvider.google:
        try {
          await _initGoogle();
          return _google.supportsAuthenticate();
        } on Object {
          return false;
        }
    }
  }

  @override
  Future<String?> identityToken(
    SignInProvider provider, {
    EmailSignIn? email,
  }) async {
    try {
      final UserCredential? credential = await switch (provider) {
        SignInProvider.apple => _signInWithApple(),
        SignInProvider.google => _signInWithGoogle(),
        SignInProvider.email => _signInWithEmail(email),
      };
      if (credential == null) return null;
      // Forced fresh: a cached token from an earlier sign-in would look like a
      // retry of that one to the server's replay ledger.
      final token = await credential.user?.getIdToken(true);
      if (token == null || token.isEmpty) {
        throw const SignInFailure('no_token', 'firebase returned no ID token');
      }
      return token;
    } on SignInUnavailable {
      _unavailable.add(provider);
      rethrow;
    } on FirebaseAuthException catch (e) {
      if (_isCancel(e)) return null;
      final failure = _failureFor(e);
      if (failure is SignInUnavailable) _unavailable.add(provider);
      throw failure;
    }
  }

  Future<UserCredential?> _signInWithApple() =>
      _auth.signInWithProvider(AppleAuthProvider());

  Future<UserCredential?> _signInWithGoogle() async {
    final idToken = await _googleIdToken();
    if (idToken == null) return null;
    return _auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  Future<UserCredential> _signInWithEmail(EmailSignIn? form) {
    if (form == null) {
      throw ArgumentError('an e-mail sign-in needs the address and password');
    }
    final email = form.email.trim();
    return form.create
        ? _auth.createUserWithEmailAndPassword(
            email: email,
            password: form.password,
          )
        : _auth.signInWithEmailAndPassword(
            email: email,
            password: form.password,
          );
  }

  /// Google's ID token from its own sheet, or null when the player backed out.
  Future<String?> _googleIdToken() async {
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
      // raises `No active configuration` here. Not something the player can
      // retry, so it is reported as unavailable and the button goes.
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
  Future<void> sendPasswordReset(String email) async {
    if (!_ready) throw const SignInFailure('unknown', 'firebase is not up');
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      // Saying "no such account" would tell anyone which addresses play here.
      if (e.code == 'user-not-found') return;
      final failure = _failureFor(e);
      throw failure is SignInFailure ? failure : SignInFailure('unknown');
    }
  }

  @override
  Future<bool> deleteUser({Future<String?> Function()? askPassword}) async {
    if (!_ready) return true;
    final user = _auth.currentUser;
    if (user == null) return true;
    final methods = {for (final info in user.providerData) info.providerId};
    try {
      if (methods.contains('apple.com')) {
        // Apple requires the app's access to be revoked when the account goes,
        // and revoking needs a fresh authorization code — which only signing in
        // again produces. It doubles as the recent sign-in Firebase wants.
        final fresh = await user.reauthenticateWithProvider(
          AppleAuthProvider(),
        );
        final code = fresh.additionalUserInfo?.authorizationCode;
        if (code != null) {
          await _auth.revokeTokenWithAuthorizationCode(code);
        }
        await user.delete();
      } else {
        try {
          await user.delete();
        } on FirebaseAuthException catch (e) {
          if (e.code != 'requires-recent-login') rethrow;
          if (!await _reauthenticate(user, methods, askPassword)) return false;
          await user.delete();
        }
      }
    } on FirebaseAuthException catch (e) {
      if (_isCancel(e)) return false;
      final failure = _failureFor(e);
      throw failure is SignInFailure ? failure : SignInFailure('unknown');
    }
    await _signOutGoogle();
    return true;
  }

  /// Signs [user] in again so Firebase lets it be deleted; false when the
  /// player backed out.
  Future<bool> _reauthenticate(
    User user,
    Set<String> methods,
    Future<String?> Function()? askPassword,
  ) async {
    if (methods.contains('google.com')) {
      final idToken = await _googleIdToken();
      if (idToken == null) return false;
      await user.reauthenticateWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
      return true;
    }
    final email = user.email;
    if (methods.contains('password') && email != null && askPassword != null) {
      final password = await askPassword();
      if (password == null || password.isEmpty) return false;
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
      return true;
    }
    throw const SignInFailure('unknown', 'no way to sign in again');
  }

  @override
  Future<void> forgetSession() async {
    if (_ready) {
      try {
        await _auth.signOut();
      } on Object {
        // A Firebase that will not sign out must not fail a local sign-out.
      }
    }
    await _signOutGoogle();
  }

  Future<void> _signOutGoogle() async {
    try {
      await _google.signOut();
    } on Object {
      // Nothing to clear, or an SDK that will not: neither is the player's
      // problem.
    }
  }

  /// The player closed the sheet. Apple's native sheet and the web flow on
  /// Android report it under different codes.
  static bool _isCancel(FirebaseAuthException e) =>
      const {
        'canceled',
        'cancelled',
        'web-context-canceled',
        'web-context-cancelled',
        'user-cancelled',
        'popup-closed-by-user',
      }.contains(e.code) ||
      // ASAuthorizationError.canceled, when it comes through untranslated.
      (e.message?.contains('1001') ?? false);

  /// What a Firebase refusal means to the player.
  static Exception _failureFor(FirebaseAuthException e) => switch (e.code) {
    'network-request-failed' => SignInFailure('offline', e.code),
    'too-many-requests' => SignInFailure('rate_limited', e.code),
    'invalid-email' => SignInFailure('email_invalid', e.code),
    'user-not-found' ||
    'wrong-password' ||
    'invalid-credential' ||
    'INVALID_LOGIN_CREDENTIALS' => SignInFailure('email_wrong', e.code),
    'email-already-in-use' => SignInFailure('email_taken', e.code),
    'weak-password' => SignInFailure('email_weak', e.code),
    'account-exists-with-different-credential' => SignInFailure(
      'other_method',
      e.code,
    ),
    'user-disabled' => SignInFailure('disabled', e.code),
    'operation-not-allowed' => SignInUnavailable(e.code),
    _ => SignInFailure('unknown', e.code),
  };
}
