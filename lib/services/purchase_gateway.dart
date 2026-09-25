/// The store, behind one interface (SPEC §4.9).
///
/// Everything above this file — which packs are offered, what the messages say,
/// when the wallet is re-read — is ordinary Dart that a test can drive. Everything
/// below it is `purchases_flutter`, StoreKit and Google Play Billing, none of
/// which can run in a unit test and none of which can run on a simulator without a
/// configured store account. That is the whole reason the seam exists, and it is
/// the same seam `native_sign_in.dart` draws around the Apple and Google sheets.
///
/// **This layer never decides what a purchase is worth.** It reports what the
/// store did — paid, cancelled, pending, already owned — and the *amount* of
/// Sparks comes from our server, credited by our server, on RevenueCat's verified
/// signal (see `purchase_service.dart` and `server/lib/src/purchases.dart`). A
/// gateway that returned a balance would be a phone deciding how much money it
/// had spent.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../app/purchase_config.dart';

/// How a purchase attempt ended.
///
/// Every one of these is an ordinary thing that happens to real players on real
/// phones, which is why each has a name and a sentence rather than sharing a
/// generic failure: "you cancelled", "your bank is thinking about it" and "the
/// store is down" are three completely different things to be told.
enum PurchaseOutcome {
  /// The store took the money. **This is not yet Sparks**: our server credits
  /// them, and the client's next move is to ask the server, never to add
  /// anything itself.
  completed,

  /// The player backed out of the sheet. Silence is the correct response — a
  /// player who changed their mind does not need a message about it.
  cancelled,

  /// Awaiting approval: Ask to Buy, SEPA direct debit, a cash top-up. The money
  /// may arrive minutes or days later, and the webhook will credit it whenever it
  /// does, whether or not the app is running.
  pending,

  /// The store says this purchase already happened. Not an error and not a
  /// second charge: the right move is to ask our server, which is the only place
  /// that knows whether it was credited.
  alreadyOwned,

  /// Purchases are switched off on this device (Screen Time, a managed device, a
  /// child account). Nothing the app can fix, and worth saying plainly rather
  /// than reporting as a failure.
  notAllowed,

  /// The store could not be reached or refused to deal — including a product the
  /// store does not have, which on a real device means the store paperwork is
  /// not finished. Nothing was charged.
  storeUnavailable,

  /// No network. Nothing was charged.
  offline,

  /// Anything else. Nothing was charged.
  failed,
}

/// What the store said about one attempt.
@immutable
class PurchaseAttempt {
  const PurchaseAttempt(this.outcome, {this.productId = '', this.detail});

  final PurchaseOutcome outcome;
  final String productId;

  /// The store's own message, for the log only. Never shown: store messages are
  /// untranslated, often internal, and occasionally alarming.
  final String? detail;

  bool get paid => outcome == PurchaseOutcome.completed;

  /// Whether the right next step is to ask our server what it holds.
  ///
  /// True for a completed purchase and for one the store considers already made:
  /// in both cases money may have changed hands and only the server knows
  /// whether it has been credited.
  bool get worthChecking =>
      outcome == PurchaseOutcome.completed ||
      outcome == PurchaseOutcome.alreadyOwned;
}

/// A product's price, as the **store** reports it.
///
/// [priceString] is StoreKit's / Billing's own formatted string: the player's
/// currency, their locale's separators, their market's tax rules, and whatever
/// Apple or Google currently charge. It is displayed verbatim.
///
/// Nothing here is ever composed from a number. An app that formats its own
/// prices is an app that shows `$4.99` to somebody who will be charged `5,99 €`,
/// and in several countries that is not merely rude.
@immutable
class StorePrice {
  const StorePrice({required this.productId, required this.priceString});

  final String productId;
  final String priceString;
}

/// The store, as the rest of the app needs it.
abstract interface class PurchaseGateway {
  /// Whether this build and this device can buy anything at all: a configured
  /// public key and a platform with a store. False on the web build and in any
  /// build a human has not given keys to.
  bool get available;

  /// Tells the store layer which Arco player is buying (SPEC §4.9).
  ///
  /// This is the join between the two systems: RevenueCat's app user id **is**
  /// our player id, so a webhook naming an app user id names a wallet without any
  /// mapping table to fall out of step. Returns whether it took.
  Future<bool> identify(String playerId);

  /// The store's own localised prices for [productIds]. Products the store does
  /// not have are simply absent.
  Future<List<StorePrice>> prices(List<String> productIds);

  /// Opens the payment sheet for [productId].
  Future<PurchaseAttempt> buy(String productId);

  /// Re-links this store account to the current app user and asks the store to
  /// resend what it has. See `PurchaseService.restore` for what that means for a
  /// consumable, which is not what most people expect.
  Future<void> restore();

  /// Fires whenever the store layer's view of this user changes — including a
  /// purchase that completes while the app is in the background, or minutes after
  /// a pending payment was approved. The event carries nothing: it is a prompt to
  /// ask our server, which is the only place a balance lives.
  Stream<void> get purchaseUpdates;

  Future<void> dispose();
}

/// The real store, through `purchases_flutter`.
///
/// Configured lazily: nothing here touches the plugin until the shop is actually
/// opened, so a player who never opens it never initialises StoreKit, and a build
/// with no keys never calls in at all.
class RevenueCatPurchases implements PurchaseGateway {
  RevenueCatPurchases({String? apiKey, this.logging = kDebugMode})
    : _apiKey = apiKey ?? PurchaseConfig.keyForPlatform;

  final String? _apiKey;

  /// Verbose SDK logs in debug builds only: they name products and app user ids,
  /// which is exactly what is wanted while wiring a store up and exactly what
  /// should not be in a release log.
  final bool logging;

  final StreamController<void> _updates = StreamController<void>.broadcast();

  bool _configured = false;
  String? _appUserId;
  void Function(CustomerInfo)? _listener;

  @override
  bool get available => _apiKey != null;

  @override
  Future<bool> identify(String playerId) async {
    final key = _apiKey;
    if (key == null) return false;
    try {
      if (!_configured) {
        if (logging) await Purchases.setLogLevel(LogLevel.debug);
        // The app user id is set at configuration time rather than logged in
        // afterwards, so the very first purchase on a fresh install is already
        // attributed to our player and no anonymous RevenueCat identity is ever
        // created for it. An anonymous one would still work — the webhook tries
        // the aliases — but it would put a purchase one alias away from its
        // wallet for no reason.
        await Purchases.configure(
          PurchasesConfiguration(key)..appUserID = playerId,
        );
        _configured = true;
        _appUserId = playerId;
        _listener = _onCustomerInfo;
        Purchases.addCustomerInfoUpdateListener(_listener!);
        return true;
      }
      if (_appUserId != playerId) {
        // The player changed under us: an account was linked and the two devices
        // merged into one player id (SPEC §4.5), or the credential was reissued.
        await Purchases.logIn(playerId);
        _appUserId = playerId;
      }
      return true;
    } on PlatformException catch (e) {
      debugPrint('RevenueCat identify failed: ${e.message}');
      return false;
    } on Object catch (e) {
      debugPrint('RevenueCat identify failed: $e');
      return false;
    }
  }

  @override
  Future<List<StorePrice>> prices(List<String> productIds) async {
    if (_apiKey == null || productIds.isEmpty) return const <StorePrice>[];
    try {
      final products = await Purchases.getProducts(
        productIds,
        // Spark packs are consumables, not subscriptions. Asking for the wrong
        // category returns nothing at all on Android, which looks exactly like
        // "the store has no such product".
        productCategory: ProductCategory.nonSubscription,
      );
      return <StorePrice>[
        for (final product in products)
          StorePrice(
            productId: product.identifier,
            // The store's string, verbatim. Never rebuilt from `product.price`.
            priceString: product.priceString,
          ),
      ];
    } on PlatformException catch (e) {
      debugPrint('RevenueCat prices failed: ${e.message}');
      return const <StorePrice>[];
    } on Object catch (e) {
      debugPrint('RevenueCat prices failed: $e');
      return const <StorePrice>[];
    }
  }

  @override
  Future<PurchaseAttempt> buy(String productId) async {
    if (_apiKey == null) {
      return PurchaseAttempt(
        PurchaseOutcome.storeUnavailable,
        productId: productId,
      );
    }
    try {
      final products = await Purchases.getProducts(<String>[
        productId,
      ], productCategory: ProductCategory.nonSubscription);
      if (products.isEmpty) {
        // On a real device this means the product is not approved, not in this
        // market, or misspelled somewhere in the store paperwork.
        return PurchaseAttempt(
          PurchaseOutcome.storeUnavailable,
          productId: productId,
          detail: 'the store has no product "$productId"',
        );
      }
      await Purchases.purchase(PurchaseParams.storeProduct(products.first));
      return PurchaseAttempt(PurchaseOutcome.completed, productId: productId);
    } on PlatformException catch (e) {
      return PurchaseAttempt(
        outcomeFor(PurchasesErrorHelper.getErrorCode(e)),
        productId: productId,
        detail: e.message,
      );
    } on Object catch (e) {
      return PurchaseAttempt(
        PurchaseOutcome.failed,
        productId: productId,
        detail: '$e',
      );
    }
  }

  @override
  Future<void> restore() async {
    if (_apiKey == null) return;
    try {
      await Purchases.restorePurchases();
    } on PlatformException catch (e) {
      debugPrint('RevenueCat restore failed: ${e.message}');
    } on Object catch (e) {
      debugPrint('RevenueCat restore failed: $e');
    }
  }

  @override
  Stream<void> get purchaseUpdates => _updates.stream;

  void _onCustomerInfo(CustomerInfo _) {
    // Deliberately ignores everything in the payload. What changed is not the
    // question; the question is "does our server hold anything new", and only
    // our server can answer it.
    if (!_updates.isClosed) _updates.add(null);
  }

  @override
  Future<void> dispose() async {
    final listener = _listener;
    if (listener != null) {
      Purchases.removeCustomerInfoUpdateListener(listener);
      _listener = null;
    }
    await _updates.close();
  }

  /// Maps a RevenueCat error code to the outcome the UI reasons about.
  ///
  /// Public and pure so the mapping is testable without a store: getting
  /// "cancelled" wrong means shouting at a player who simply changed their mind,
  /// and getting "pending" wrong means telling somebody their payment failed when
  /// it is merely waiting for a parent to approve it.
  @visibleForTesting
  static PurchaseOutcome outcomeFor(PurchasesErrorCode code) => switch (code) {
    PurchasesErrorCode.purchaseCancelledError => PurchaseOutcome.cancelled,
    PurchasesErrorCode.paymentPendingError => PurchaseOutcome.pending,
    PurchasesErrorCode.productAlreadyPurchasedError ||
    PurchasesErrorCode.receiptAlreadyInUseError ||
    PurchasesErrorCode.receiptInUseByOtherSubscriberError =>
      PurchaseOutcome.alreadyOwned,
    PurchasesErrorCode.purchaseNotAllowedError ||
    PurchasesErrorCode.insufficientPermissionsError ||
    PurchasesErrorCode.ineligibleError => PurchaseOutcome.notAllowed,
    PurchasesErrorCode.networkError ||
    PurchasesErrorCode.offlineConnectionError => PurchaseOutcome.offline,
    PurchasesErrorCode.storeProblemError ||
    PurchasesErrorCode.productNotAvailableForPurchaseError ||
    PurchasesErrorCode.productRequestTimeout ||
    PurchasesErrorCode.configurationError ||
    PurchasesErrorCode.apiEndpointBlocked ||
    PurchasesErrorCode.invalidCredentialsError ||
    PurchasesErrorCode.unknownBackendError ||
    PurchasesErrorCode.unexpectedBackendResponseError =>
      PurchaseOutcome.storeUnavailable,
    _ => PurchaseOutcome.failed,
  };
}
