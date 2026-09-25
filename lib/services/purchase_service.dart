/// Buying Sparks with real money, client side (SPEC §4.9).
///
/// **The client never computes a balance.** That is the whole shape of this file.
/// A purchase here has two halves and they are deliberately separate:
///
/// 1. the *money* half, which the store and RevenueCat do — this app opens a
///    payment sheet and learns whether it was paid;
/// 2. the *Sparks* half, which **our server** does, on RevenueCat's verified
///    webhook — and which this app learns about by asking the server.
///
/// So a completed purchase adds nothing locally. It nudges
/// `POST /api/purchases/sync` (a request carrying no purchase data at all: the
/// server re-verifies with RevenueCat's API using its own secret key) and then
/// re-reads the wallet through [ShopService]. If the server has not credited it
/// yet, the honest thing to say is "paid, the Sparks are on their way" — not a
/// number this phone made up.
///
/// The prices come from the **store**, verbatim, per market, in the player's own
/// currency. Nothing in this app formats a price or holds one (SPEC §4.9).
///
/// And it must not nag (SPEC §4.9): every Spark a pack sells is earnable by
/// playing, so the packs are a shortcut and are presented as one — below the
/// earning panel, with no countdown, no struck-through price and no prompt
/// anywhere outside the shop.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'player_identity.dart';
import 'purchase_gateway.dart';
import 'shop_service.dart';

/// Whether the Spark-pack section can be shown, and why not when it cannot.
enum PurchaseStatus {
  /// Nothing has been asked yet.
  idle,

  /// The store is being asked for its prices.
  loading,

  /// There are packs with prices to show.
  ready,

  /// This deployment does not sell Sparks, or this build has no store keys, or
  /// the platform has no store. The section is **absent** rather than empty: a
  /// shop that cannot take money must not show a price list.
  unavailable,

  /// There are packs, and the store did not answer about them. Worth a sentence
  /// rather than a blank: the player may be offline or the store may be down,
  /// and either way there is nothing wrong with the game.
  storeSilent,
}

/// One pack as the shop shows it: the server's amount of Sparks, and the
/// **store's** own price string.
@immutable
class SparkPackOffer {
  const SparkPackOffer({required this.pack, this.priceString});

  /// What the server says this pack pays (SPEC §4.9).
  final ShopPack pack;

  /// The store's formatted, localised, tax-inclusive price — displayed verbatim,
  /// never composed here. Null when the store did not report this product, which
  /// on a real device means the store paperwork is unfinished or the product is
  /// not sold in this market.
  final String? priceString;

  String get productId => pack.productId;
  int get sparks => pack.sparks;

  /// Whether this can actually be tapped. A pack the store has no price for
  /// cannot be bought, and offering it would be offering a dead button.
  bool get buyable => priceString != null;
}

/// How a purchase attempt ended, as the shop needs to say it.
enum PurchaseReportKind {
  /// Paid, and **the server has credited it**: the wallet on screen is the new
  /// one, read back from `GET /api/shop/inventory`.
  credited,

  /// Paid, and the server has not credited it yet — the webhook is a moment
  /// behind, or this phone could not reach us to ask. Nothing is lost: the
  /// webhook credits it whether or not the app is running, and the next time the
  /// shop opens the Sparks are there.
  awaitingServer,

  /// Awaiting approval (Ask to Buy, a bank transfer). Not paid yet, not failed.
  pending,

  /// The player backed out. Silence.
  cancelled,

  /// Purchases are switched off on this device.
  notAllowed,

  /// The store could not be reached or has no such product. Nothing was charged.
  storeUnavailable,

  /// No network. Nothing was charged.
  offline,

  /// Anything else. Nothing was charged.
  failed,
}

/// What a purchase attempt came to, with the server's numbers where there are
/// any.
@immutable
class PurchaseReport {
  const PurchaseReport(
    this.kind, {
    this.sparks = 0,
    this.balance,
    this.serverAnswered = false,
  });

  final PurchaseReportKind kind;

  /// Sparks the **server** credited, as the server reported them. 0 whenever the
  /// server has not confirmed anything — never a guess.
  final int sparks;

  /// The wallet afterwards, from the server. Null when it was not reachable.
  final int? balance;

  /// Whether our server actually answered.
  ///
  /// The difference this draws matters: "paid, and the server says there is
  /// nothing new" and "paid, and we could not ask" look the same from the wallet
  /// and are completely different things to tell somebody — the first is the
  /// ordinary answer to Restore Purchases, the second is a reason to try again.
  final bool serverAnswered;

  /// Whether the player should be told to expect Sparks shortly rather than
  /// shown a number.
  bool get waiting => kind == PurchaseReportKind.awaitingServer;
}

/// What "restore purchases" came to (SPEC §4.9).
@immutable
class RestoreReport {
  const RestoreReport({
    required this.credited,
    required this.sparks,
    required this.failed,
  });

  /// A restore that reached the server and found nothing left to credit — which
  /// is the ordinary, healthy answer, because a consumable does not restore.
  static const RestoreReport nothing = RestoreReport(
    credited: 0,
    sparks: 0,
    failed: false,
  );

  static const RestoreReport unreachable = RestoreReport(
    credited: 0,
    sparks: 0,
    failed: true,
  );

  /// Purchases the server credited as a result. Usually 0.
  final int credited;

  /// Sparks credited.
  final int sparks;

  /// The server or the store could not be reached.
  final bool failed;

  bool get foundSomething => credited > 0;
}

/// Offers the Spark packs, runs a purchase, and then asks the server (SPEC §4.9).
class PurchaseService extends ChangeNotifier {
  PurchaseService({
    required this.gateway,
    required this.api,
    required this.identity,
    required this.shop,
  }) {
    // A purchase that completes while the app is in the background, or a pending
    // payment approved days later, arrives here rather than as the result of a
    // call. The event carries nothing on purpose: it is a prompt to ask the
    // server, and the server is the only thing that knows.
    _updates = gateway.purchaseUpdates.listen((_) => recheck());
  }

  final PurchaseGateway gateway;
  final ApiClient api;

  /// Who is buying (SPEC §4.4). The RevenueCat app user id **is** this player id,
  /// so the two systems agree without a mapping table.
  final PlayerIdentity identity;

  /// Where the wallet lives, as far as this app is concerned: a cache of the
  /// server's last answer. Refreshed after a purchase; never added to.
  final ShopService shop;

  late final StreamSubscription<void> _updates;

  PurchaseStatus _status = PurchaseStatus.idle;
  List<SparkPackOffer> _offers = const <SparkPackOffer>[];
  bool _busy = false;
  Future<void>? _loading;

  PurchaseStatus get status => _status;

  /// The packs to show, in the server's order (cheapest first). Empty unless
  /// [status] is [PurchaseStatus.ready].
  List<SparkPackOffer> get offers => _offers;

  /// A purchase or a restore is in flight: the section stops taking taps, so one
  /// double tap cannot open two payment sheets.
  bool get busy => _busy;

  /// Whether the shop should draw a Spark-pack section at all.
  ///
  /// False when this deployment sells nothing (the server returned no packs),
  /// when this build has no store keys, or when the platform has no store. In all
  /// three cases the right UI is *nothing* — not a disabled button, not an
  /// explanation. Sparks are earnable by playing, so there is no hole to
  /// apologise for.
  bool get offered => gateway.available && shop.snapshot.packs.isNotEmpty;

  /// Asks the store for its prices, after telling it who is buying.
  ///
  /// Called when the shop screen opens, once [ShopService] has the catalogue —
  /// the pack list is the server's, and there is nothing to price before it has
  /// arrived. Concurrent callers join the call in flight.
  Future<void> refresh() {
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    final call = _refresh();
    _loading = call;
    return call.whenComplete(() => _loading = null);
  }

  Future<void> _refresh() async {
    final packs = shop.snapshot.packs;
    if (!gateway.available || packs.isEmpty) {
      _offers = const <SparkPackOffer>[];
      _setStatus(PurchaseStatus.unavailable);
      return;
    }
    _setStatus(PurchaseStatus.loading);
    // Opening the shop is a player asking for something that needs a wallet, so
    // this call may issue the anonymous identity of SPEC §4.4 — the same licence
    // `ShopService.refresh(issue: true)` has, and for the same reason.
    final credentials = await identity.ensureIssued();
    if (credentials == null) {
      // No identity means no wallet to credit, so there is nothing to sell yet.
      _offers = const <SparkPackOffer>[];
      _setStatus(PurchaseStatus.unavailable);
      return;
    }
    final identified = await gateway.identify(credentials.id);
    if (!identified) {
      _offers = const <SparkPackOffer>[];
      _setStatus(PurchaseStatus.storeSilent);
      return;
    }
    final prices = <String, String>{
      for (final price in await gateway.prices([
        for (final pack in packs) pack.productId,
      ]))
        price.productId: price.priceString,
    };
    _offers = <SparkPackOffer>[
      for (final pack in packs)
        SparkPackOffer(pack: pack, priceString: prices[pack.productId]),
    ];
    // A pack with no price cannot be bought, so if none of them has one there is
    // nothing to show and the store is the reason.
    _setStatus(
      _offers.any((offer) => offer.buyable)
          ? PurchaseStatus.ready
          : PurchaseStatus.storeSilent,
    );
  }

  /// Buys [productId] (SPEC §4.9).
  ///
  /// The store is asked, and then — if money may have changed hands — **our
  /// server** is asked what it holds. Nothing is added locally at any point, and
  /// nothing about the amount is decided here: the Sparks in the returned
  /// [PurchaseReport] are the server's own number, or 0.
  ///
  /// A product this build does not have an offer for is refused before the sheet
  /// opens: the pack list is the server's, and buying something that is not on it
  /// would be buying a product the server cannot price either.
  Future<PurchaseReport> buy(String productId) async {
    if (_busy) return const PurchaseReport(PurchaseReportKind.failed);
    final offer = offerFor(productId);
    if (offer == null || !offer.buyable) {
      return const PurchaseReport(PurchaseReportKind.storeUnavailable);
    }
    _busy = true;
    notifyListeners();
    try {
      final attempt = await gateway.buy(productId);
      if (!attempt.worthChecking) return _reportFor(attempt.outcome);
      // Paid — or the store thinks it already was. Either way the only question
      // left is what the server holds, and the only way to answer it is to ask.
      return await _askServer();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Restore purchases (SPEC §4.9).
  ///
  /// **What this actually does, said plainly here because the UI says it too:** a
  /// Spark pack is a *consumable*. Consumables do not restore — the store hands
  /// them over once and considers the matter closed — so there is nothing for a
  /// reinstall to restore, and a player's Sparks are not on the phone at all.
  /// They are on their Arco player, which is why signing in with Apple or Google
  /// is what carries them to a new phone.
  ///
  /// The button exists anyway, for two good reasons: the store review guidelines
  /// expect it in any app that sells anything, and a player who reinstalls will
  /// look for it. So it does the two useful things it can: it asks the store to
  /// re-link this store account to this player, and it asks our server to
  /// re-verify with RevenueCat — which genuinely does credit a purchase that was
  /// paid for and never landed, because that path is keyed on the store's own
  /// transaction id and is safe to run any number of times.
  Future<RestoreReport> restore() async {
    if (_busy) return RestoreReport.unreachable;
    _busy = true;
    notifyListeners();
    try {
      final credentials = await identity.ensureIssued();
      if (credentials == null) return RestoreReport.unreachable;
      // Makes the store re-associate its account with this app user id, so that
      // anything it has on file shows up under our player rather than under
      // whatever identity the previous install used.
      if (gateway.available) {
        await gateway.identify(credentials.id);
        await gateway.restore();
      }
      final report = await _askServer();
      if (report.kind == PurchaseReportKind.credited) {
        return RestoreReport(credited: 1, sparks: report.sparks, failed: false);
      }
      // Nothing new. That is the *expected* answer for a consumable, so it is
      // only a failure when the server never answered at all.
      return report.serverAnswered
          ? RestoreReport.nothing
          : RestoreReport.unreachable;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Asks the server whether anything new has been credited, without any UI.
  ///
  /// This is what runs when the store tells us something changed — a purchase
  /// that completed while the app was backgrounded, a pending payment finally
  /// approved — and what the shop screen calls when the app comes back to the
  /// foreground. Cheap, idempotent, and silent when there is nothing new.
  Future<void> recheck() async {
    if (_busy || !gateway.available) return;
    await _askServer();
  }

  /// The offer for [productId], or null when this build is not offering it.
  SparkPackOffer? offerFor(String productId) {
    for (final offer in _offers) {
      if (offer.productId == productId) return offer;
    }
    return null;
  }

  /// Nudges the server and then re-reads the wallet from it.
  ///
  /// Both halves matter. The nudge (`POST /api/purchases/sync`) makes the server
  /// re-verify with RevenueCat, so a player who paid thirty seconds ago does not
  /// have to wait for a late webhook. The re-read (`ShopService.refresh`) is what
  /// puts a balance on screen, and it is a balance the **server** computed — this
  /// method never adds a Spark to anything.
  Future<PurchaseReport> _askServer() async {
    final credentials = await identity.load();
    if (credentials == null) {
      return const PurchaseReport(
        PurchaseReportKind.awaitingServer,
        serverAnswered: false,
      );
    }
    // The balance the server last told us, so the message afterwards can say
    // whether it moved. Two server numbers compared; neither invented here.
    final before = shop.snapshot.known ? shop.balance : null;
    PurchaseSync? sync;
    try {
      sync = await api.purchasesSync(credentials);
    } on ApiException catch (e) {
      if (e.isUnauthorized) await identity.forget();
      // Paid, and we could not ask. The webhook is authoritative and does not
      // need this phone, so nothing is lost — but nothing may be claimed either.
      return const PurchaseReport(
        PurchaseReportKind.awaitingServer,
        serverAnswered: false,
      );
    }
    // The wallet on screen always comes from the inventory endpoint, whatever the
    // sync answered: one source for a balance, and it is the server's.
    await shop.refresh(force: true);
    final after = shop.snapshot.known ? shop.balance : null;
    final grew = before != null && after != null && after > before;
    if (sync.credited > 0 || grew) {
      return PurchaseReport(
        PurchaseReportKind.credited,
        // The server's own figure for what it just credited; the balance
        // difference is used only when the webhook got there first and the sync
        // therefore credited nothing itself.
        sparks: sync.sparks > 0 ? sync.sparks : (grew ? after - before : 0),
        balance: after,
        serverAnswered: true,
      );
    }
    return PurchaseReport(
      PurchaseReportKind.awaitingServer,
      balance: after,
      serverAnswered: true,
    );
  }

  static PurchaseReport _reportFor(PurchaseOutcome outcome) =>
      PurchaseReport(switch (outcome) {
        PurchaseOutcome.cancelled => PurchaseReportKind.cancelled,
        PurchaseOutcome.pending => PurchaseReportKind.pending,
        PurchaseOutcome.notAllowed => PurchaseReportKind.notAllowed,
        PurchaseOutcome.storeUnavailable => PurchaseReportKind.storeUnavailable,
        PurchaseOutcome.offline => PurchaseReportKind.offline,
        // `completed` and `alreadyOwned` never reach here: both are
        // `worthChecking`, so the server is asked instead of a message guessed.
        _ => PurchaseReportKind.failed,
      });

  void _setStatus(PurchaseStatus status) {
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _updates.cancel();
    gateway.dispose();
    super.dispose();
  }
}
