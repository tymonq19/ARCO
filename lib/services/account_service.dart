import 'package:flutter/foundation.dart';

import 'account_offer.dart';
import 'api_client.dart';
import 'native_sign_in.dart';
import 'player_identity.dart';
import 'storage.dart';

/// What a sign-in attempt came to, in the terms the player is shown.
sealed class SignInResult {
  const SignInResult();
}

/// The player backed out of the native sheet. **Silent**: nothing is shown,
/// nothing is remembered, the offer stays exactly as it was (SPEC §4.5).
class SignInCancelled extends SignInResult {
  const SignInCancelled();
}

/// The account is attached and the credential it issued has already replaced the
/// stored one. [outcome] is what actually happened — created, linked, restored,
/// merged — and [movedScores] is how many runs a merge carried across.
class SignInSucceeded extends SignInResult {
  const SignInSucceeded(this.link);

  final AccountLink link;

  AccountLinkOutcome get outcome => link.outcome;
  int get movedScores => link.movedScores;
  String get provider => link.provider;
}

/// The attempt failed. [code] is the message key (`account.error.<code>`) and
/// [detail] is the one thing a documented refusal carries with it — the provider
/// of `409 already_linked`.
class SignInFailed extends SignInResult {
  const SignInFailed(this.code, {this.detail});

  final String code;
  final String? detail;
}

/// What a deletion came to.
sealed class DeleteResult {
  const DeleteResult();
}

/// The player is gone server side and nothing on this device points at it any
/// more. [scoresAnonymised] is how many verified runs stayed on the board
/// without an owner (SPEC §4.5).
class DeleteSucceeded extends DeleteResult {
  const DeleteSucceeded(this.scoresAnonymised);
  final int scoresAnonymised;
}

class DeleteFailed extends DeleteResult {
  const DeleteFailed(this.code);
  final String code;
}

/// Signing in with Apple or Google, and everything that follows from it
/// (SPEC §4.5).
///
/// It owns three decisions and no widgets:
/// * **which buttons exist at all** — the intersection of what the deployment
///   advertises on `GET /api/health` and what this device can actually run, so
///   there is never a button that cannot work;
/// * **the credential swap** — the `200` from `POST /api/account/link` replaces
///   both halves of the stored credential, because a merge can answer with a
///   different surviving player;
/// * **when to stop offering** — see [AccountOffer].
class AccountService {
  AccountService({
    required this.api,
    required this.identity,
    required this.native,
    required this.offer,
    required this.storage,
    DateTime Function()? now,
    TargetPlatform Function()? platform,
    this.providersTtl = const Duration(minutes: 10),
  }) : _now = now ?? DateTime.now,
       _platform = platform ?? (() => defaultTargetPlatform);

  final ApiClient api;
  final PlayerIdentity identity;
  final NativeSignIn native;

  /// When the offer may be shown, and the memory of it having been waved away.
  final AccountOffer offer;

  final Storage storage;

  /// How long the provider list from `GET /api/health` is reused. A deployment
  /// does not switch sign-in on twice an hour, and the list is read every time a
  /// screen that might offer it opens.
  final Duration providersTtl;

  final DateTime Function() _now;
  final TargetPlatform Function() _platform;

  List<SignInProvider>? _providers;
  DateTime? _providersAt;
  Future<List<SignInProvider>>? _providersCall;

  /// The last known provider list, or null while it has never been read. Null is
  /// deliberately not "none": a screen shows no buttons for either, but only an
  /// answered `health()` is allowed to say the feature is off.
  List<SignInProvider>? get cachedProviders => _providers;

  /// True once we know there is nothing to offer: the deployment advertises no
  /// provider, or none of the advertised ones can run here.
  bool get knownUnavailable => _providers != null && _providers!.isEmpty;

  /// The providers to offer, in the order to show them.
  ///
  /// `GET /api/health`'s `accounts` is the authority on what the server accepts
  /// (SPEC §4.5) — an empty list means the whole feature is off and **nothing**
  /// is shown, no dead buttons. Each advertised provider is then asked whether
  /// it can run on this device at all.
  ///
  /// A failed health check leaves the list unknown rather than empty, so a phone
  /// that was offline for one screen is not told sign-in does not exist.
  Future<List<SignInProvider>> providers({bool force = false}) {
    final at = _providersAt;
    if (!force &&
        at != null &&
        _providers != null &&
        _now().difference(at) < providersTtl) {
      return Future<List<SignInProvider>>.value(_providers);
    }
    final pending = _providersCall;
    if (pending != null) return pending;
    final call = _readProviders();
    _providersCall = call;
    return call.whenComplete(() => _providersCall = null);
  }

  Future<List<SignInProvider>> _readProviders() async {
    // A credential we cannot keep makes an account pointless: it would be gone
    // on the next launch. This is the web build, and any device whose keychain
    // refuses us (SPEC §4.4).
    await identity.load();
    if (!identity.canStoreSecret) {
      _providers = const <SignInProvider>[];
      _providersAt = _now();
      return _providers!;
    }
    final List<String> advertised;
    try {
      advertised = (await api.health()).accounts;
    } on ApiException {
      return _providers ?? const <SignInProvider>[];
    }
    final usable = <SignInProvider>[];
    for (final provider in _ordered(advertised)) {
      if (await native.isAvailable(provider)) usable.add(provider);
    }
    _providers = List<SignInProvider>.unmodifiable(usable);
    _providersAt = _now();
    return _providers!;
  }

  /// The advertised providers this build knows, in display order.
  ///
  /// Apple comes first on Apple's own platforms: App Store review requires Sign
  /// in with Apple to be offered wherever another third-party sign-in is, and
  /// the order is the cheapest way to make it the equal of the other one.
  /// Elsewhere Google leads, because that is the sign-in an Android player
  /// expects first.
  List<SignInProvider> _ordered(List<String> advertised) {
    final known = <SignInProvider>[
      for (final name in advertised) ?signInProviderByName(name),
    ];
    final platform = _platform();
    final appleFirst =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    final order = appleFirst
        ? const [SignInProvider.apple, SignInProvider.google]
        : const [SignInProvider.google, SignInProvider.apple];
    return <SignInProvider>[
      for (final provider in order)
        if (known.contains(provider)) provider,
    ];
  }

  /// Runs [provider]'s native sheet and links what it returns (SPEC §4.5).
  ///
  /// The identity token is posted with whatever credential this device already
  /// holds, and is **never** posted with one we just issued: issuing first would
  /// create an empty player and then immediately merge it away.
  Future<SignInResult> signIn(SignInProvider provider) async {
    final String? token;
    try {
      token = await native.identityToken(provider);
    } on SignInUnavailable {
      // This device cannot run that sheet after all, which only the attempt
      // could establish. Drop the cached list so the next screen asks again and
      // stops offering it.
      _providers = null;
      _providersAt = null;
      return const SignInFailed('unavailable');
    } on SignInFailure catch (e) {
      return SignInFailed(e.code);
    } on Object {
      return const SignInFailed('unknown');
    }
    // A cancel is not an error and says nothing about the offer.
    if (token == null) return const SignInCancelled();

    // Reads the stored credential; deliberately does not issue one.
    final stored = await identity.load();
    try {
      return await _link(provider, token, stored);
    } on ApiException catch (e) {
      // The credential we sent is not usable and nothing was stored (SPEC §4.4
      // fails closed here too). The token is still good and the ledger pins the
      // outcome to the first *accepted* call, so dropping the stale credential
      // and presenting the same token again restores the account instead of
      // losing the sign-in to a secret from a rebuilt database.
      if (stored != null && e.errorCode == invalidCredentialsError) {
        await identity.forget();
        try {
          return await _link(provider, token, null);
        } on ApiException catch (retry) {
          return SignInFailed(_codeFor(retry), detail: retry.detail);
        }
      }
      return SignInFailed(_codeFor(e), detail: e.detail);
    }
  }

  Future<SignInResult> _link(
    SignInProvider provider,
    String token,
    PlayerCredentials? credentials,
  ) async {
    final link = await api.linkAccount(
      provider: provider.name,
      idToken: token,
      credentials: credentials,
    );
    // Both halves at once: a link always issues a new credential, and on a merge
    // the surviving player may be a different id than the one we sent.
    await identity.adopt(link.credentials);
    identity.adoptProfile(link.toProfile());
    await identity.rememberCountry(link.country);
    // There is nothing left to offer.
    await offer.silenceForever();
    return SignInSucceeded(link);
  }

  /// Forgets this device's credential, so the phone plays anonymously again.
  ///
  /// Deliberately **not** `POST /api/account/unlink`: that detaches the account
  /// from the player everywhere, which would sign the player's other phone out
  /// of an account it is still using. SPEC §4.5 issues one credential per device
  /// and never revokes another's, so "sign out on this device" is exactly this —
  /// and signing in again restores the same player (`outcome: restored`).
  Future<void> signOutOnThisDevice() async {
    await native.forgetSession();
    await identity.forget();
    // A deliberate sign-out is the clearest "no" there is; do not come back with
    // the offer on the next personal best.
    await offer.silenceForever();
  }

  /// `DELETE /api/players/me` (SPEC §4.5), then everything local that pointed at
  /// that player.
  ///
  /// The score rows themselves stay on the leaderboard as anonymous runs — a
  /// verified run is a fact about the board, and deleting rows would restate
  /// everybody else's rank. What goes is every link between the person and them.
  Future<DeleteResult> deleteAccount() async {
    final credentials = await identity.load();
    if (credentials == null) {
      // Nothing was ever issued, so there is nothing server side to delete; the
      // local state is still cleared so the two halves cannot disagree.
      await _forgetLocally();
      return const DeleteSucceeded(0);
    }
    try {
      final anonymised = await api.deletePlayer(credentials);
      await _forgetLocally();
      return DeleteSucceeded(anonymised);
    } on ApiException catch (e) {
      // Already gone (a second tap, another device got there first): the player
      // does not exist, which is the state that was asked for.
      if (e.isUnauthorized) {
        await _forgetLocally();
        return const DeleteSucceeded(0);
      }
      return DeleteFailed(_codeFor(e));
    }
  }

  Future<void> _forgetLocally() async {
    await native.forgetSession();
    await identity.forget();
    await storage.forgetOwnScores();
    await offer.silenceForever();
  }

  /// The message key for a refusal. Everything the server documents for
  /// `POST /api/account/link` and `DELETE /api/players/me` (SPEC §4.5) has its
  /// own sentence; anything else is the honest "it did not finish".
  static String _codeFor(ApiException e) {
    if (e.isOffline) return 'offline';
    const known = <String>{
      'accounts_disabled',
      'invalid_token',
      'invalid_provider',
      'already_linked',
      'keys_unavailable',
      'rate_limited',
      'invalid_credentials',
    };
    final code = e.errorCode;
    if (code != null && known.contains(code)) return code;
    if (e.kind == ApiErrorKind.rateLimited) return 'rate_limited';
    return 'unknown';
  }
}
