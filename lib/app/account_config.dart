/// Compile-time client ids for Sign in with Apple / Google (SPEC §4.5).
///
/// Nothing here is a secret: a client id is public by design, it is baked into
/// every build of every app that uses it, and the server never trusts it — the
/// `aud` claim of the identity token is checked against the server's **own**
/// `APPLE_CLIENT_IDS` / `GOOGLE_CLIENT_IDS`. It lives in `--dart-define`s rather
/// than in source so one checkout can build the dev and the store flavour, and
/// so a fork that has no Google project simply leaves them empty and gets no
/// Google button.
///
/// On iOS the Google client id can equally come from `GIDClientID` in
/// `Info.plist`, which is what `google_sign_in` reads when nothing is passed;
/// a value here takes precedence. See SETUP.md for what a human has to fill in.
abstract final class AccountConfig {
  /// iOS/macOS OAuth client id of *this app* (`…apps.googleusercontent.com`),
  /// from `--dart-define=GOOGLE_CLIENT_ID=…`.
  static const String googleClientId = String.fromEnvironment(
    'GOOGLE_CLIENT_ID',
  );

  /// The **web** OAuth client id of the same Google project, from
  /// `--dart-define=GOOGLE_SERVER_CLIENT_ID=…`.
  ///
  /// Android has no client id of its own: `google_sign_in` needs this one to be
  /// handed an `idToken` at all, and its value is the `aud` the token carries —
  /// so it is what the server's `GOOGLE_CLIENT_IDS` must list.
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );

  /// The Apple **Services ID** used for the web-based flow on Android, from
  /// `--dart-define=APPLE_SERVICE_ID=…`.
  ///
  /// On iOS and macOS Sign in with Apple needs nothing here: the `aud` of the
  /// token is the app's own bundle id, configured in Xcode. Android has no
  /// native Apple sign-in, so the package opens Apple's web flow, whose `aud`
  /// is this Services ID and which needs [appleRedirectUri] to come back.
  static const String appleServiceId = String.fromEnvironment(
    'APPLE_SERVICE_ID',
  );

  /// `https://…/callbacks/sign_in_with_apple` — the Return URL registered on the
  /// Apple Services ID, from `--dart-define=APPLE_REDIRECT_URI=…`.
  static const String appleRedirectUri = String.fromEnvironment(
    'APPLE_REDIRECT_URI',
  );

  /// Whether the Apple web flow (Android) is configured. Without both halves
  /// the button is not offered there rather than failing on the tap.
  static bool get appleWebConfigured =>
      appleServiceId.isNotEmpty && Uri.tryParse(appleRedirectUri)?.host != null;

  /// The client id to hand `google_sign_in`, or null to let the platform read
  /// its own configuration file.
  static String? get googleClientIdOrNull =>
      googleClientId.isEmpty ? null : googleClientId;

  static String? get googleServerClientIdOrNull =>
      googleServerClientId.isEmpty ? null : googleServerClientId;
}
