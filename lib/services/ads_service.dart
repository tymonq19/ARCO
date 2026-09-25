/// Rewarded ads that pay Sparks, client side (SPEC §4.10).
///
/// **The client never credits a Spark.** That is the whole shape of this file, and
/// it matters more here than anywhere else in the app: an app that could say "I
/// watched an ad, add ten Sparks" is a Spark printer, and every phone would have
/// one. So a watched ad has two halves and they are deliberately separate:
///
/// 1. the *watching* half, which the Google Mobile Ads SDK does — this app asks
///    for an ad, shows it, and learns whether the player watched it through;
/// 2. the *Sparks* half, which **our server** does, on the server-side
///    verification callback Google signs and posts to it — and which this app
///    learns about by asking the server.
///
/// So a finished ad adds nothing locally. It polls `GET /api/ads/offer` until the
/// server's lifetime ad total moves, then re-reads the wallet through
/// [ShopService]. If the callback has not landed yet, the honest thing to say is
/// "your sparks are on their way" — not a number this phone made up.
///
/// **Where an ad may appear**, and it is a short list on purpose (SPEC §4.10): in
/// the shop, as a way to earn Sparks beside the other way, and on the game-over
/// overlay, as an optional extra on the run just finished. Never an interstitial,
/// never before a duel, never on launch. An ad that is not asked for is an ad shown
/// *at* somebody.
///
/// **And it is hidden when it would not work.** The button is drawn only when an ad
/// is already in hand *and* the server says there is allowance left and the
/// cooldown has passed. A rewarded button that spins, fails, or takes thirty
/// seconds and pays nothing is worse than no button at all — and there is nothing
/// to apologise for, because every Spark an ad pays is earnable by playing.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ads_gateway.dart';
import 'api_client.dart';
import 'player_identity.dart';
import 'shop_service.dart';

/// How an ad attempt ended, as a screen needs to say it.
enum AdReportKind {
  /// Watched, and **the server has credited it**: the wallet on screen is the new
  /// one, read back from `GET /api/shop/inventory`.
  credited,

  /// Watched, and the server has not confirmed yet — Google's callback is a moment
  /// behind, or this phone could not reach us to ask. Nothing is lost: the callback
  /// goes to our server and does not need this app to be running.
  awaitingServer,

  /// Closed before the reward. Silence — a player who changed their mind does not
  /// need a message about it.
  dismissed,

  /// The player declined the consent form. Silence too, and the button is now
  /// absent. The game is entirely unaffected.
  consentRefused,

  /// There was no ad, or it could not be shown. Nothing happened.
  unavailable,
}

/// What an ad attempt came to, with the server's numbers where there are any.
@immutable
class AdReport {
  const AdReport(this.kind, {this.sparks = 0, this.balance});

  final AdReportKind kind;

  /// Sparks the **server** credited, as the server reported them. 0 whenever the
  /// server has not confirmed anything — never a guess.
  final int sparks;

  /// The wallet afterwards, from the server. Null when it was not reachable.
  final int? balance;

  /// Whether the player should be told to expect Sparks shortly rather than shown
  /// a number.
  bool get waiting => kind == AdReportKind.awaitingServer;

  /// Whether anything at all should be said. A player who backed out of an ad or
  /// declined a form has said their piece.
  bool get silent =>
      kind == AdReportKind.dismissed || kind == AdReportKind.consentRefused;
}

/// Offers a rewarded ad, shows it, and then asks the server (SPEC §4.10).
class AdsService extends ChangeNotifier {
  AdsService({
    required this.gateway,
    required this.api,
    required this.identity,
    required this.shop,
    this.pollAttempts = 8,
    this.pollDelay = const Duration(milliseconds: 600),
  }) {
    // An ad that finishes loading, or a consent state that settles, changes
    // whether a button should be on screen.
    _changes = gateway.changes.listen((_) => notifyListeners());
  }

  final AdsGateway gateway;
  final ApiClient api;

  /// Who is watching (SPEC §4.4). This player id goes into the ad's signed
  /// `custom_data`, which is what Google's callback resolves to a wallet — so the
  /// two systems agree without a mapping table.
  final PlayerIdentity identity;

  /// Where the wallet lives, as far as this app is concerned: a cache of the
  /// server's last answer. Re-read after a credited ad; never added to.
  final ShopService shop;

  /// How hard to poll for the server's credit after an ad, and how long to wait
  /// between attempts.
  ///
  /// Google's callback normally lands within a second or two, so the default is a
  /// few seconds in total — long enough that the ordinary case shows a number, short
  /// enough that a player is not left watching a spinner. When it runs out the
  /// answer is [AdReportKind.awaitingServer], which is true rather than hopeful:
  /// the callback does not need this app.
  final int pollAttempts;
  final Duration pollDelay;

  late final StreamSubscription<void> _changes;

  AdOffer _offer = AdOffer.none;
  bool _busy = false;
  Future<void>? _loading;

  /// The server's last answer about this player's allowance.
  AdOffer get offer => _offer;

  /// Whether ads may be requested at all, as far as consent is concerned.
  AdConsentState get consent => gateway.consent;

  /// Whether this build could show an ad at all: a configured ad unit on a
  /// platform AdMob serves.
  bool get configured => gateway.available;

  /// Whether this player bought the one-time unlock (SPEC §4.9), as the server's
  /// last offer reported it.
  ///
  /// It means **no ads at all** — not fewer, none. The server already answers
  /// `available: false` for them with the day's allowance untouched, so this is the
  /// second lock on the same door, and it is worth having: an ad shown to somebody
  /// who paid for no ads is the one failure this whole flag exists to prevent.
  bool get premium => _offer.premium;

  /// An ad is in flight: the button stops taking taps, so one double tap cannot
  /// open two ads.
  bool get busy => _busy;

  /// **An ad is in hand and the server says it would pay.** The only state in
  /// which a "watch an ad" button is ever drawn.
  bool get canWatch =>
      configured && !premium && gateway.loaded && _offer.available;

  /// The server says an ad would pay, but the player has not answered the consent
  /// form yet — so there is something to offer, and the form is what is offered.
  ///
  /// This is the moment the form belongs to: the player has opened the shop and is
  /// looking at ways to earn Sparks. Asking on launch would be asking before there
  /// is anything to ask *for*.
  bool get needsConsent =>
      configured &&
      !premium &&
      _offer.available &&
      gateway.consent == AdConsentState.required;

  /// Whether the **shop** should draw its ad row.
  ///
  /// True for a loaded ad, and true when consent is still unanswered — the shop is
  /// where the ask can happen, because it is where the player is already reading
  /// about earning Sparks.
  bool get offeredInShop => canWatch || needsConsent;

  /// Whether the **game-over** overlay should draw its button.
  ///
  /// Only for an ad already in hand. Game over is not the moment for a privacy
  /// form, and it is certainly not the moment for a spinner: the button is instant
  /// or it is absent.
  bool get offeredAtGameOver => canWatch;

  /// Asks the server what the allowance is, checks consent, and preloads an ad.
  ///
  /// Called when a screen that could offer an ad opens, and again when the app
  /// comes back to the foreground. Concurrent callers join the call in flight.
  Future<void> refresh() {
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    final call = _refresh();
    _loading = call;
    return call.whenComplete(() => _loading = null);
  }

  Future<void> _refresh() async {
    if (!gateway.available) {
      _offer = AdOffer.none;
      notifyListeners();
      return;
    }
    // Opening a screen that offers an ad is a player asking for something that
    // needs a wallet, so this may issue the anonymous identity of SPEC §4.4 — the
    // same licence `ShopService.refresh(issue: true)` and `PurchaseService` have.
    final credentials = await identity.ensureIssued();
    if (credentials == null) {
      // No identity means no wallet to credit, so there is nothing to offer.
      _offer = AdOffer.none;
      notifyListeners();
      return;
    }
    _offer = await _askServer() ?? AdOffer.none;
    notifyListeners();
    if (!_offer.available) {
      // The day is spent or the cooldown is running. Asking Google for an ad we
      // could not pay for would be spending somebody's data on nothing.
      return;
    }
    // Consent before any ad request, always — that is what makes a refusal a game
    // with no ads rather than a compliance problem. `refreshConsent` shows nothing:
    // it only asks Google whether a form is required here.
    if (gateway.consent == AdConsentState.unknown) {
      await gateway.refreshConsent();
    }
    if (gateway.consent == AdConsentState.allowed) await gateway.load();
    notifyListeners();
  }

  /// Shows an ad at [placement] and then asks the server (SPEC §4.10).
  ///
  /// The consent form is shown here, on the tap, if it is still unanswered — the
  /// moment the player has asked for the thing consent is needed for. A player who
  /// declines gets [AdReportKind.consentRefused], the button disappears, and
  /// nothing else about the game changes.
  ///
  /// Nothing is added locally at any point: the Sparks in the returned [AdReport]
  /// are the server's own number, or 0.
  Future<AdReport> watch(AdPlacementId placement) async {
    if (_busy || !gateway.available) {
      return const AdReport(AdReportKind.unavailable);
    }
    _busy = true;
    notifyListeners();
    try {
      final credentials = await identity.ensureIssued();
      if (credentials == null) {
        return const AdReport(AdReportKind.unavailable);
      }
      if (gateway.consent != AdConsentState.allowed) {
        final outcome = await gateway.requestConsent();
        switch (outcome) {
          case AdConsentOutcome.refused:
          case AdConsentOutcome.unavailable:
            // Said no, or could not be asked. Either way we may not request an ad,
            // and the right UI is none.
            return const AdReport(AdReportKind.consentRefused);
          case AdConsentOutcome.notRequired:
          case AdConsentOutcome.obtained:
            break;
        }
      }
      if (!gateway.loaded && !await gateway.load()) {
        return const AdReport(AdReportKind.unavailable);
      }
      final outcome = await gateway.show(
        playerId: credentials.id,
        placement: placement,
      );
      switch (outcome) {
        case AdShowOutcome.dismissed:
          return const AdReport(AdReportKind.dismissed);
        case AdShowOutcome.failed:
          return const AdReport(AdReportKind.unavailable);
        case AdShowOutcome.rewarded:
          return await _awaitCredit();
      }
    } finally {
      _busy = false;
      notifyListeners();
      // The next ad, and the allowance the one just watched used up. Not awaited:
      // the report is already the caller's answer, and the button reappearing (or
      // not) is the next frame's business.
      unawaited(refresh());
    }
  }

  /// Polls the server until it has credited the ad, then re-reads the wallet.
  ///
  /// The signal is [AdOffer.adTotal]: a lifetime total of Sparks earned from ads,
  /// which can only move one way and only for this reason. Comparing balances
  /// would be ambiguous — a run submitted in the background moves a balance too.
  Future<AdReport> _awaitCredit() async {
    final before = _offer.adTotal;
    for (var attempt = 0; attempt < pollAttempts; attempt++) {
      final answer = await _askServer();
      if (answer == null) {
        // We cannot reach our own server. Google's callback does not need us to,
        // so nothing is lost — but nothing may be claimed either.
        return const AdReport(AdReportKind.awaitingServer);
      }
      _offer = answer;
      notifyListeners();
      if (answer.adTotal > before) {
        // The wallet on screen always comes from the inventory endpoint, whatever
        // this call answered: one source for a balance, and it is the server's.
        await shop.refresh(force: true);
        return AdReport(
          AdReportKind.credited,
          sparks: answer.adTotal - before,
          balance: shop.snapshot.known ? shop.balance : answer.balance,
        );
      }
      if (attempt < pollAttempts - 1) await Future<void>.delayed(pollDelay);
    }
    // Watched, and the credit has not arrived yet. It will, without this app.
    return AdReport(AdReportKind.awaitingServer, balance: _offer.balance);
  }

  /// `GET /api/ads/offer`, or null when the server could not be asked.
  ///
  /// A deployment with ads switched off answers `404 ads_disabled`, which is not a
  /// failure worth a message — it is a deployment that sells no ads, and it comes
  /// back as [AdOffer.none] so the app simply shows nothing.
  Future<AdOffer?> _askServer() async {
    final credentials = await identity.load();
    if (credentials == null) return AdOffer.none;
    try {
      return await api.adsOffer(credentials);
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await identity.forget();
        return AdOffer.none;
      }
      if (e.errorCode == 'ads_disabled') return AdOffer.none;
      return null;
    }
  }

  @override
  void dispose() {
    _changes.cancel();
    gateway.dispose();
    super.dispose();
  }
}
