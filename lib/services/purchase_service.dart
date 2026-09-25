/// The one-time unlock, client side (SPEC §4.9).
///
/// **The client never grants anything.** That is the whole shape of this file. A
/// purchase here has two halves and they are deliberately separate:
///
/// 1. the *money* half, which the store and RevenueCat do — this app opens a
///    payment sheet and learns whether it was paid;
/// 2. the *entitlement* half, which **our server** does, on RevenueCat's verified
///    webhook — and which this app learns about by asking the server.
///
/// So a completed purchase unlocks nothing locally. It nudges
/// `POST /api/purchases/sync` (a request carrying no purchase data at all: the
/// server re-verifies with RevenueCat's API using its own secret key) and then
/// re-reads the inventory through [ShopService]. If the server has not granted it
/// yet, the honest thing to say is "paid, it lands in a moment" — not a state this
/// phone made up.
///
/// The price comes from the **store**, verbatim, per market, in the player's own
/// currency. Nothing in this app formats a price or holds one (SPEC §4.9).
///
/// And it must not nag (SPEC §4.9): every cosmetic the unlock covers is earnable
/// by playing, so the unlock is a shortcut and a convenience and is presented as
/// one — below the earning panel, with no countdown, no struck-through price and
/// no prompt anywhere outside the shop.
///
/// **Restore is a real feature here, not an apology.** The product is a
/// *non-consumable*: the stores themselves remember it, so a reinstall or a second
/// device genuinely has something to recover. [restore] asks the store to re-link
/// its account to this player and then asks our server to re-verify — and the
/// server grants keyed on the store's own transaction id, which is what makes
/// running it any number of times safe.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'player_identity.dart';
import 'purchase_gateway.dart';
import 'shop_service.dart';

/// Whether the unlock can be offered, and why not when it cannot.
enum PurchaseStatus {
  /// Nothing has been asked yet.
  idle,

  /// The store is being asked for its price.
  loading,

  /// There is an unlock with a price to show.
  ready,

  /// There is nothing to sell: this deployment takes no money, this build has no
  /// store keys, the platform has no store, or the player already owns the
  /// unlock. The offer is **absent** rather than empty — a shop that cannot take
  /// money must not show a price, and a player who has paid must not be shown one
  /// again.
  unavailable,

  /// There is an unlock, and the store did not answer about it. Worth a sentence
  /// rather than a blank: the player may be offline or the store may be down, and
  /// either way there is nothing wrong with the game.
  storeSilent,
}

/// The unlock as the shop shows it: the server's product, and the **store's** own
/// price string.
@immutable
class UnlockOffer {
  const UnlockOffer({required this.product, this.priceString});

  /// What the server says is for sale (SPEC §4.9). It carries no price.
  final UnlockProduct product;

  /// The store's formatted, localised, tax-inclusive price — displayed verbatim,
  /// never composed here. Null when the store did not report this product, which
  /// on a real device means the store paperwork is unfinished or the product is
  /// not sold in this market.
  final String? priceString;

  String get productId => product.productId;
  String get nameKey => product.nameKey;

  /// Whether this can actually be tapped. A product the store has no price for
  /// cannot be bought, and offering it would be offering a dead button.
  bool get buyable => priceString != null;
}

/// How a purchase attempt ended, as the shop needs to say it.
enum PurchaseReportKind {
  /// Paid, and **the server has granted it**: the inventory on screen is the new
  /// one, read back from `GET /api/shop/inventory`, with everything owned.
  unlocked,

  /// Paid, and the server has not granted it yet — the webhook is a moment
  /// behind, or this phone could not reach us to ask. Nothing is lost: the webhook
  /// grants it whether or not the app is running, and the next time the shop opens
  /// everything is unlocked.
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

/// What a purchase attempt came to, with the server's answer where there is one.
@immutable
class PurchaseReport {
  const PurchaseReport(
    this.kind, {
    this.premium = false,
    this.serverAnswered = false,
  });

  final PurchaseReportKind kind;

  /// Whether the **server** says everything is unlocked. Never a guess: false
  /// whenever the server has not confirmed it.
  final bool premium;

  /// Whether our server actually answered.
  ///
  /// The difference this draws matters: "paid, and the server says there is
  /// nothing new" and "paid, and we could not ask" look identical from here and
  /// are completely different things to tell somebody — the first is the ordinary
  /// answer to Restore Purchases on a player who has nothing to restore, the
  /// second is a reason to try again.
  final bool serverAnswered;

  /// Whether the player should be told to expect it shortly rather than shown a
  /// state nobody has confirmed.
  bool get waiting => kind == PurchaseReportKind.awaitingServer;
}

/// What "restore purchases" came to (SPEC §4.9).
@immutable
class RestoreReport {
  const RestoreReport({
    required this.premium,
    required this.granted,
    required this.failed,
  });

  /// A restore that reached the server and found no purchase for this store
  /// account. Not an error: it is what a player who has never bought the unlock,
  /// or who is signed in to a different Apple ID than the one that paid, should
  /// be told plainly.
  static const RestoreReport nothing = RestoreReport(
    premium: false,
    granted: 0,
    failed: false,
  );

  static const RestoreReport unreachable = RestoreReport(
    premium: false,
    granted: 0,
    failed: true,
  );

  /// Whether everything is unlocked now, as the **server** reports it. True both
  /// for a purchase this call recovered and for one that was already ours, which
  /// is the same good news either way.
  final bool premium;

  /// Purchases the server granted as a result of this call. 0 when it was already
  /// granted — the healthy case, and not a failure.
  final int granted;

  /// The server could not be reached.
  final bool failed;

  /// Whether there is anything to celebrate.
  bool get foundSomething => premium;
}

/// Offers the one-time unlock, runs the purchase, and then asks the server
/// (SPEC §4.9).
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

  /// Where the entitlement lives, as far as this app is concerned: a cache of the
  /// server's last answer. Refreshed after a purchase; never granted here.
  final ShopService shop;

  late final StreamSubscription<void> _updates;

  PurchaseStatus _status = PurchaseStatus.idle;
  UnlockOffer? _offer;
  bool _busy = false;
  Future<void>? _loading;

  PurchaseStatus get status => _status;

  /// The unlock to show, or null unless [status] is [PurchaseStatus.ready] or
  /// [PurchaseStatus.storeSilent].
  UnlockOffer? get offer => _offer;

  /// A purchase or a restore is in flight: the offer stops taking taps, so one
  /// double tap cannot open two payment sheets.
  bool get busy => _busy;

  /// Whether this player already owns everything (SPEC §4.9) — the server's
  /// answer, through [ShopService]. The offer becomes a quiet confirmation.
  bool get premium => shop.premium;

  /// Whether the shop should draw an **offer** at all.
  ///
  /// False when this deployment sells nothing (the server advertised no product),
  /// when this build has no store keys, when the platform has no store, and when
  /// the player is already premium — the server stops advertising the unlock the
  /// moment it is owned, because there is then nothing left to sell. In all of
  /// those cases the right UI is *not* a disabled button and *not* an apology:
  /// every cosmetic is earnable by playing, so there is no hole to explain.
  bool get offered => gateway.available && shop.snapshot.unlock != null;

  /// Whether Restore Purchases is worth showing.
  ///
  /// True whenever this deployment takes money at all, premium or not: the store
  /// guidelines expect the button in any app that sells something, a player on a
  /// second device needs it, and — unlike under the old consumable model — it
  /// genuinely works. It does **not** need the store keys: the useful half is
  /// asking our own server.
  bool get canRestore => offered || premium;

  /// Asks the store for its price, after telling it who is buying.
  ///
  /// Called when the shop screen opens, once [ShopService] has the catalogue —
  /// the product is the server's, and there is nothing to price before it has
  /// arrived. Concurrent callers join the call in flight.
  Future<void> refresh() {
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    final call = _refresh();
    _loading = call;
    return call.whenComplete(() => _loading = null);
  }

  Future<void> _refresh() async {
    final product = shop.snapshot.unlock;
    if (!gateway.available || product == null) {
      _offer = null;
      _setStatus(PurchaseStatus.unavailable);
      return;
    }
    _setStatus(PurchaseStatus.loading);
    // Opening the shop is a player asking for something that needs a player, so
    // this call may issue the anonymous identity of SPEC §4.4 — the same licence
    // `ShopService.refresh(issue: true)` has, and for the same reason.
    final credentials = await identity.ensureIssued();
    if (credentials == null) {
      // No identity means nothing to grant the unlock to, so there is nothing to
      // sell yet.
      _offer = null;
      _setStatus(PurchaseStatus.unavailable);
      return;
    }
    final identified = await gateway.identify(credentials.id);
    if (!identified) {
      _offer = null;
      _setStatus(PurchaseStatus.storeSilent);
      return;
    }
    String? price;
    for (final quoted in await gateway.prices(<String>[product.productId])) {
      if (quoted.productId == product.productId) {
        price = quoted.priceString;
        break;
      }
    }
    _offer = UnlockOffer(product: product, priceString: price);
    // A product with no price cannot be bought, so if there is none there is
    // nothing to show and the store is the reason.
    _setStatus(
      price == null ? PurchaseStatus.storeSilent : PurchaseStatus.ready,
    );
  }

  /// Buys the unlock (SPEC §4.9).
  ///
  /// The store is asked, and then — if money may have changed hands — **our
  /// server** is asked what it holds. Nothing is unlocked locally at any point:
  /// the `premium` in the returned [PurchaseReport] is the server's own answer, or
  /// false.
  ///
  /// A product this build is not offering is refused before the sheet opens: the
  /// product is the server's, and buying something it does not advertise would be
  /// buying something it will not grant either.
  Future<PurchaseReport> buy(String productId) async {
    if (_busy) return const PurchaseReport(PurchaseReportKind.failed);
    final offer = _offer;
    if (offer == null || offer.productId != productId || !offer.buyable) {
      return const PurchaseReport(PurchaseReportKind.storeUnavailable);
    }
    _busy = true;
    notifyListeners();
    try {
      final attempt = await gateway.buy(productId);
      if (!attempt.worthChecking) return _reportFor(attempt.outcome);
      // Paid — or the store thinks it already was, which is exactly what a
      // non-consumable says on a second attempt. Either way the only question
      // left is what the server holds, and the only way to answer it is to ask.
      return await _askServer();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Restore purchases (SPEC §4.9).
  ///
  /// **This genuinely restores.** The unlock is a *non-consumable*, so the store
  /// keeps a record of it for the account that paid: a reinstall, a new phone or a
  /// second device can recover it without our server having been reachable at the
  /// time. Two things happen, in order — the store is asked to re-link its account
  /// to this player, and our server is asked to re-verify with RevenueCat. The
  /// grant is keyed on the store's own transaction id, so this is safe to run any
  /// number of times and cannot unlock anything twice.
  ///
  /// Signing in with Apple or Google (SPEC §4.5) is still what carries a *player*
  /// between devices; this carries the *purchase*. They are different jobs and the
  /// UI says so.
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
      final sync = await _sync(credentials);
      if (sync == null) return RestoreReport.unreachable;
      // The inventory endpoint is the one source of what is owned, so it is
      // re-read whatever the sync said.
      await shop.refresh(force: true);
      if (sync.premium) {
        return RestoreReport(
          premium: true,
          granted: sync.granted,
          failed: false,
        );
      }
      // The server answered and holds no live purchase for this store account.
      // That is a fact, not a failure, and it is the honest thing to report.
      return RestoreReport.nothing;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Asks the server whether anything new has been granted, without any UI.
  ///
  /// This is what runs when the store tells us something changed — a purchase
  /// that completed while the app was backgrounded, a pending payment finally
  /// approved — and what the shop screen calls when the app comes back to the
  /// foreground. Cheap, idempotent, and silent when there is nothing new.
  Future<void> recheck() async {
    if (_busy || !gateway.available) return;
    await _askServer();
  }

  /// Nudges the server and then re-reads the inventory from it.
  ///
  /// Both halves matter. The nudge (`POST /api/purchases/sync`) makes the server
  /// re-verify with RevenueCat, so a player who paid thirty seconds ago does not
  /// have to wait for a late webhook. The re-read (`ShopService.refresh`) is what
  /// puts the unlocked catalogue on screen, and it is the **server** that decided
  /// it — this method never unlocks anything.
  Future<PurchaseReport> _askServer() async {
    final credentials = await identity.load();
    if (credentials == null) {
      return const PurchaseReport(
        PurchaseReportKind.awaitingServer,
        serverAnswered: false,
      );
    }
    final sync = await _sync(credentials);
    if (sync == null) {
      // Paid, and we could not ask. The webhook is authoritative and does not
      // need this phone, so nothing is lost — but nothing may be claimed either.
      return const PurchaseReport(
        PurchaseReportKind.awaitingServer,
        serverAnswered: false,
      );
    }
    // What is owned always comes from the inventory endpoint, whatever the sync
    // answered: one source for an entitlement, and it is the server's.
    await shop.refresh(force: true);
    if (sync.premium || shop.premium) {
      return const PurchaseReport(
        PurchaseReportKind.unlocked,
        premium: true,
        serverAnswered: true,
      );
    }
    return const PurchaseReport(
      PurchaseReportKind.awaitingServer,
      serverAnswered: true,
    );
  }

  /// One `POST /api/purchases/sync`, or null when it could not be made.
  Future<PurchaseSync?> _sync(PlayerCredentials credentials) async {
    try {
      return await api.purchasesSync(credentials);
    } on ApiException catch (e) {
      if (e.isUnauthorized) await identity.forget();
      return null;
    }
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
