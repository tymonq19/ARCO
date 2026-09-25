/// The one-time unlock, server side (SPEC §4.9).
///
/// One product, `arco.unlock.full`, bought once, non-consumable: it unlocks every
/// cosmetic that exists and every one added later, and it turns ads off. That is
/// the whole payment model. Sparks are untouched beside it as the **free** path —
/// earned by playing, spent on individual cosmetics — so a player who never pays
/// can still have everything, slowly.
///
/// The shape of the deal, and the only shape that is safe: **RevenueCat handles
/// the money step, and this server remains the only source of truth for what a
/// player owns.** RevenueCat talks to StoreKit and Google Play, validates the
/// receipt, and tells us what was bought. It does not decide the entitlement,
/// because the entitlement is spent in our shop and read by our game.
///
/// The rule underneath everything here: **never let the client tell the server
/// what it owns.** There is nothing in any request this file reads that says so.
/// The product identifier comes from a source we verified, what it grants comes
/// from `FullUnlock` inside the granting transaction, and the phone's only power
/// is to say "look again".
///
/// Two ways in, and the difference between them is the whole design:
///
/// * **`POST /api/purchases/webhook`** — RevenueCat pushes a verified event to
///   us. This is the authoritative path. It is unauthenticated in the ordinary
///   sense, so it is authenticated by the shared secret RevenueCat signs every
///   webhook with, compared in constant time. Webhooks are retried until they
///   are answered with a 2xx, so granting is idempotent on the **store's**
///   transaction id.
/// * **`POST /api/purchases/sync`** — the phone asks us to look again: after a
///   purchase, when the webhook is a few seconds behind and a player is watching
///   the screen, and on **Restore purchases**, which is now a real feature rather
///   than an apology. It carries **no purchase data at all**: the server asks
///   RevenueCat's REST API what that app user actually owns, with its own secret
///   key, and grants from that answer. The phone cannot lie because the phone is
///   not asked anything. A non-consumable genuinely restores, so a reinstall or a
///   second device recovers premium through this one call.
///
/// A refund or a chargeback arrives as a webhook too, and revokes. What that does
/// — and, more importantly, what it deliberately does *not* touch — is decided and
/// documented in [Db.revokePurchase]: premium goes, and every cosmetic the player
/// also bought with Sparks stays, because those were paid for separately.
///
/// The iron rule is untouched: what money buys here is **cosmetics**, the same
/// ones Sparks buy. Nothing in this file reaches `arco_core`, nothing it does can
/// change a simulation, and the leaderboard cannot be climbed with a card.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'catalogue.dart';
import 'config.dart';
import 'db.dart';
import 'logging.dart';
import 'players.dart';
import 'score_store.dart';

/// `POST /api/purchases/webhook` bodies larger than this are rejected with 413.
///
/// A RevenueCat event is about 2 KB. This is a transport guard with an order of
/// magnitude of headroom, not a tuned limit.
const int maxWebhookBodyBytes = 32 * 1024;

/// `POST /api/purchases/sync` bodies larger than this are rejected with 413.
///
/// The body is ignored entirely — it exists so the call can be a POST — so
/// anything of size is not a client of this endpoint.
const int maxSyncBodyBytes = 1024;

/// The whole feature is switched off (`PURCHASES_ENABLED` unset or `off`).
const String purchasesDisabledError = 'purchases_disabled';

/// The webhook did not carry the shared secret RevenueCat is configured with.
///
/// Deliberately one code for a missing header and a wrong one, exactly as
/// SPEC §4.4 answers one code for a missing and a wrong credential: telling a
/// caller which half it got right is telling it how to get closer.
const String invalidSignatureError = 'invalid_signature';

/// The body was not a RevenueCat event.
const String invalidEventError = 'invalid_event';

/// The event names an app user id that is not a player of this server.
const String unknownPlayerError = 'unknown_player';

/// RevenueCat could not be reached, or answered with something unusable. The
/// same class as `keys_unavailable` on a sign-in: our problem, worth a retry.
const String revenueCatUnavailableError = 'revenuecat_unavailable';

/// The RevenueCat event types that **grant** (SPEC §4.9).
///
/// The unlock is a non-subscription product, so `NON_RENEWING_PURCHASE` is the
/// one that actually arrives for it — RevenueCat uses that type for every
/// purchase that will not auto-renew, consumable and non-consumable alike.
/// `INITIAL_PURCHASE` is here because a human could configure the product as a
/// subscription by mistake, and because the guard that makes this safe is not the
/// type but the product: an event whose product is not [FullUnlock.productId]
/// grants nothing, whatever it is called.
const Set<String> grantingEventTypes = <String>{
  'NON_RENEWING_PURCHASE',
  'INITIAL_PURCHASE',
};

/// The RevenueCat event types that **revoke** (SPEC §4.9).
///
/// RevenueCat reports an Apple or Google refund as `CANCELLATION` carrying a
/// `cancel_reason` (`CUSTOMER_SUPPORT` for a refund, `BILLING_ERROR` for a
/// chargeback). `REFUND` is accepted as well so that a future event type of that
/// name does the obvious thing rather than being silently ignored.
///
/// A `CANCELLATION` for something we never recorded — a subscription
/// unsubscribing, a product from another feature — finds no ledger row and is
/// acknowledged with nothing done, which is why this set can afford to be wide.
const Set<String> revokingEventTypes = <String>{'CANCELLATION', 'REFUND'};

/// Outcome of a purchase call: an HTTP status plus a JSON body — the same shape
/// `ShopService` and `AccountService` return, so `api.dart` stays routing only.
class PurchaseResult {
  const PurchaseResult(this.status, this.body);

  factory PurchaseResult.error(
    int status,
    String code, {
    String? detail,
    Map<String, dynamic>? extra,
  }) => PurchaseResult(status, {
    'ok': false,
    'error': code,
    'detail': ?detail,
    ...?extra,
  });

  final int status;
  final Map<String, dynamic> body;

  bool get ok => status == 200;
}

/// One non-subscription purchase as RevenueCat's REST API reports it.
class RevenueCatTransaction {
  const RevenueCatTransaction({
    required this.productId,
    required this.storeTransactionId,
    required this.store,
    required this.purchasedAt,
    required this.isSandbox,
  });

  final String productId;

  /// The **store's** transaction id, which is the idempotency key everywhere in
  /// this feature. A transaction RevenueCat reports without one is skipped
  /// rather than credited under its RevenueCat id: two paths keyed differently
  /// for the same payment is exactly the double credit the key exists to stop.
  final String storeTransactionId;

  final String store;
  final DateTime purchasedAt;
  final bool isSandbox;
}

/// The part of a RevenueCat subscriber record this server reads.
class RevenueCatSubscriber {
  const RevenueCatSubscriber({
    required this.originalAppUserId,
    required this.nonSubscriptions,
    this.activeEntitlements = const <String>{},
  });

  final String originalAppUserId;

  /// Every non-subscription purchase RevenueCat has on file for this app user,
  /// across both stores. A non-consumable lives here, which is what makes a
  /// restore possible: the store remembers the purchase, RevenueCat reports it,
  /// and it still carries the store transaction id a grant is keyed on.
  final List<RevenueCatTransaction> nonSubscriptions;

  /// The RevenueCat **entitlements** this app user currently holds
  /// ([FullUnlock.premiumEntitlement] being the one we configure).
  ///
  /// Read but never trusted as authority for a grant, deliberately. An
  /// entitlement carries no store transaction id, and the transaction id is the
  /// idempotency key that stops one payment unlocking twice and stops a refunded
  /// payment silently unlocking again. So the entitlement is used for exactly one
  /// thing: noticing, in a log line, that RevenueCat thinks somebody is entitled
  /// while we granted nothing — which is what a product attached to the wrong
  /// entitlement, or no entitlement, looks like from here.
  final Set<String> activeEntitlements;
}

/// A RevenueCat call that produced no usable answer.
class RevenueCatException implements Exception {
  const RevenueCatException(this.message);

  final String message;

  @override
  String toString() => 'RevenueCatException: $message';
}

/// Fetches a RevenueCat REST body. Injected so the tests can point the server at
/// a fake RevenueCat on loopback and no test ever reaches the real one.
typedef RevenueCatFetcher =
    Future<String> Function(Uri uri, String apiKey, Duration timeout);

/// RevenueCat's REST API, as far as this server uses it: one call, asking what
/// an app user has bought (SPEC §4.9).
///
/// `GET /v1/subscribers/{app_user_id}` with a **secret** API key. That endpoint
/// is chosen deliberately over anything richer: it needs no project id, it is
/// the same answer whichever store the purchase came from, and it carries both
/// halves of what a restore needs — the `non_subscriptions` map, where a
/// non-consumable and its store transaction id live, and the `entitlements` map,
/// which is what RevenueCat itself thinks the customer holds.
class RevenueCatApi {
  RevenueCatApi({
    required this.apiKey,
    Uri? baseUri,
    RevenueCatFetcher? fetch,
    this.timeout = const Duration(seconds: 6),
  }) : baseUri = baseUri ?? defaultBaseUri,
       _fetch = fetch ?? fetchRevenueCatOverHttps;

  /// RevenueCat's own API host.
  static final Uri defaultBaseUri = Uri.parse('https://api.revenuecat.com');

  final String apiKey;

  /// Where to ask. Overridden by the tests with a loopback address; HTTPS is
  /// required everywhere else (see [isFetchableRevenueCatUri]).
  final Uri baseUri;

  final Duration timeout;
  final RevenueCatFetcher _fetch;

  /// What RevenueCat has on file for [appUserId].
  ///
  /// Throws [RevenueCatException] for anything that leaves the answer unknown —
  /// unreachable, a 5xx, a body that is not the document we expect — because the
  /// honest response to the phone is then "ask again", never "you bought
  /// nothing".
  ///
  /// A `404` is **not** an error: RevenueCat answers it for an app user it has
  /// never seen, which is every player who has not bought anything, and the
  /// truthful reading of that is an empty list.
  Future<RevenueCatSubscriber> subscriber(String appUserId) async {
    final uri = baseUri.replace(
      path: '/v1/subscribers/${Uri.encodeComponent(appUserId)}',
    );
    final body = await _fetch(uri, apiKey, timeout);
    if (body.isEmpty) {
      return const RevenueCatSubscriber(
        originalAppUserId: '',
        nonSubscriptions: <RevenueCatTransaction>[],
      );
    }
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (e) {
      throw RevenueCatException('subscriber body is not JSON: $e');
    }
    if (json is! Map<String, dynamic>) {
      throw const RevenueCatException('subscriber body is not a JSON object');
    }
    final subscriber = json['subscriber'];
    if (subscriber is! Map<String, dynamic>) {
      throw const RevenueCatException(
        'subscriber body carries no "subscriber"',
      );
    }
    return RevenueCatSubscriber(
      originalAppUserId: '${subscriber['original_app_user_id'] ?? ''}',
      nonSubscriptions: _readNonSubscriptions(subscriber['non_subscriptions']),
      activeEntitlements: _readActiveEntitlements(subscriber['entitlements']),
    );
  }

  /// The entitlement ids RevenueCat reports as currently held.
  ///
  /// `expires_date` is null for a non-consumable's entitlement — it does not
  /// expire — and a date for anything that can lapse; a past date is therefore
  /// not held. A record with no `entitlements` key at all (an older RevenueCat
  /// project, or an app user who has bought nothing) reads as the empty set,
  /// which is the truthful answer and not an error.
  static Set<String> _readActiveEntitlements(Object? raw) {
    if (raw is! Map) return const <String>{};
    final now = DateTime.now().toUtc();
    final out = <String>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final expires = DateTime.tryParse('${value['expires_date'] ?? ''}');
      if (expires != null && expires.toUtc().isBefore(now)) continue;
      out.add('${entry.key}');
    }
    return out;
  }

  static List<RevenueCatTransaction> _readNonSubscriptions(Object? raw) {
    if (raw is! Map) return const <RevenueCatTransaction>[];
    final out = <RevenueCatTransaction>[];
    for (final entry in raw.entries) {
      final productId = '${entry.key}';
      final purchases = entry.value;
      if (purchases is! List) continue;
      for (final purchase in purchases) {
        if (purchase is! Map) continue;
        final transactionId = purchase['store_transaction_id'];
        // No store transaction id, no credit. See
        // [RevenueCatTransaction.storeTransactionId].
        if (transactionId is! String || transactionId.isEmpty) continue;
        out.add(
          RevenueCatTransaction(
            productId: productId,
            storeTransactionId: transactionId,
            store: '${purchase['store'] ?? 'unknown'}',
            purchasedAt:
                DateTime.tryParse(
                  '${purchase['purchase_date'] ?? ''}',
                )?.toUtc() ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            isSandbox: purchase['is_sandbox'] == true,
          ),
        );
      }
    }
    return out;
  }
}

/// Fetches a RevenueCat REST body over HTTPS.
///
/// The same guards as the provider key fetch in `id_token.dart`, because this is
/// the other place the server talks to the outside world: HTTPS only (bar a
/// loopback host, which is how the tests point it at their own fake), no
/// redirects — a redirect could move the trust anchor to another host — a
/// response-size cap, and a timeout on every step so a hanging RevenueCat cannot
/// pile up requests on the isolate that also drives the room tick.
///
/// Returns the empty string for a `404`, which is RevenueCat's answer for an app
/// user it has never heard of.
Future<String> fetchRevenueCatOverHttps(
  Uri uri,
  String apiKey,
  Duration timeout, {
  int maxBytes = 512 * 1024,
}) async {
  if (!isFetchableRevenueCatUri(uri)) {
    throw RevenueCatException('refusing to call $uri: HTTPS only');
  }
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = timeout;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    final response = await request.close().timeout(timeout);
    if (response.statusCode == HttpStatus.notFound) {
      await response.drain<void>();
      return '';
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw RevenueCatException('HTTP ${response.statusCode} from RevenueCat');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      if (builder.length + chunk.length > maxBytes) {
        throw RevenueCatException('RevenueCat answer is over $maxBytes bytes');
      }
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes());
  } on RevenueCatException {
    rethrow;
  } catch (e) {
    throw RevenueCatException('$e');
  } finally {
    client.close(force: true);
  }
}

/// HTTPS anywhere, plain HTTP only against loopback (the tests' fake
/// RevenueCat). A secret API key must never go out over a channel an attacker on
/// the path could read.
bool isFetchableRevenueCatUri(Uri uri) {
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  final host = uri.host;
  if (host == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  return address != null && address.isLoopback;
}

/// What one RevenueCat webhook event says, as far as this server reads it.
class WebhookEvent {
  const WebhookEvent({
    required this.id,
    required this.type,
    required this.appUserIds,
    required this.productId,
    required this.transactionId,
    required this.store,
    required this.environment,
    required this.purchasedAt,
  });

  final String id;
  final String type;

  /// Every app user id the event names, in the order they should be tried:
  /// `app_user_id`, then `original_app_user_id`, then the aliases.
  ///
  /// All three exist because RevenueCat merges identities of its own accord
  /// (an anonymous id that later logs in), and the one our player id is under
  /// may be any of them.
  final List<String> appUserIds;

  final String productId;

  /// The store's transaction id — the idempotency key (SPEC §4.9).
  final String transactionId;

  final String store;

  /// `PRODUCTION` or `SANDBOX`.
  final String environment;

  final DateTime purchasedAt;

  bool get isSandbox => environment.toUpperCase() == 'SANDBOX';

  bool get grants => grantingEventTypes.contains(type);
  bool get revokes => revokingEventTypes.contains(type);

  /// Parses the `{"api_version":…,"event":{…}}` envelope RevenueCat posts.
  ///
  /// Returns null for anything that is not one. Only the fields above are read;
  /// the event also carries a price, a currency and a country, and none of them
  /// is looked at — what the purchase grants comes from `FullUnlock`, so a price
  /// in the body is not merely untrusted, it is unused.
  static WebhookEvent? parse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final event = json['event'];
    if (event is! Map<String, dynamic>) return null;
    final type = event['type'];
    if (type is! String || type.isEmpty) return null;
    final ids = <String>[];
    void addId(Object? raw) {
      if (raw is String && raw.isNotEmpty && !ids.contains(raw)) ids.add(raw);
    }

    addId(event['app_user_id']);
    addId(event['original_app_user_id']);
    final aliases = event['aliases'];
    if (aliases is List) {
      for (final alias in aliases) {
        addId(alias);
      }
    }
    // Apple reissues a transaction id on a restore, so the *original* one is
    // preferred where both exist: it is the id that identifies the payment
    // rather than the delivery of it, and crediting has to be keyed on the
    // payment.
    final transactionId =
        _string(event['original_transaction_id']) ??
        _string(event['transaction_id']) ??
        '';
    final purchasedMs = event['purchased_at_ms'] ?? event['event_timestamp_ms'];
    return WebhookEvent(
      id: _string(event['id']) ?? '',
      type: type,
      appUserIds: ids,
      productId: _string(event['product_id']) ?? '',
      transactionId: transactionId,
      store: _string(event['store']) ?? 'unknown',
      environment: _string(event['environment']) ?? 'PRODUCTION',
      purchasedAt: purchasedMs is num
          ? DateTime.fromMillisecondsSinceEpoch(
              purchasedMs.toInt(),
              isUtc: true,
            )
          : DateTime.now().toUtc(),
    );
  }

  static String? _string(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;
}

/// The money path (SPEC §4.9): verifying a webhook, granting premium, revoking it
/// on a refund, and re-verifying on the client's nudge — which is also what
/// "Restore purchases" is.
///
/// Always constructed, even when the feature is off — [enabled] is then false,
/// the two endpoints answer [purchasesDisabledError] and nothing else about the
/// server changes. That is the same shape `AccountService` has, and it is what
/// makes the switch a genuine switch rather than a conditional wiring.
class PurchaseService {
  PurchaseService({
    required this.store,
    required this.config,
    required this.log,
    RevenueCatApi? api,
    Uri? revenueCatBaseUri,
    RevenueCatFetcher? fetchRevenueCat,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _api =
           api ??
           (config.enabled
               ? RevenueCatApi(
                   apiKey: config.apiKey,
                   baseUri: revenueCatBaseUri,
                   fetch: fetchRevenueCat,
                 )
               : null);

  final ScoreStore store;
  final PurchasesConfig config;
  final Logger log;
  final DateTime Function() _clock;
  final RevenueCatApi? _api;

  bool get enabled => config.enabled;

  /// The unlock this deployment sells, or null when the feature is off
  /// (SPEC §4.9).
  ///
  /// A shop that cannot take money must not offer the unlock: the section simply
  /// is not there, which is also what every build gets before a human has
  /// configured RevenueCat. Null rather than an empty list because there is
  /// exactly one product and "there is no product" is the honest shape of that.
  UnlockProduct? unlockFor(int clientVersion) =>
      enabled ? FullUnlock.upTo(clientVersion) : null;

  /// `POST /api/purchases/webhook` — RevenueCat's authoritative signal
  /// (SPEC §4.9).
  ///
  /// [authorization] is the request's `Authorization` header, which is where
  /// RevenueCat puts the shared secret it is configured with. It is checked
  /// **before the body is looked at**, in constant time, and a mismatch is a
  /// `401` that grants nothing.
  ///
  /// Everything that is not an error is answered `200`, including an event this
  /// server does nothing with. That is not laxness: RevenueCat retries any
  /// non-2xx, so acknowledging "seen, nothing to do" is the difference between a
  /// quiet log and the same subscription event arriving every hour forever.
  Future<PurchaseResult> webhook(
    Uint8List body, {
    required String? authorization,
  }) async {
    if (!enabled) {
      return PurchaseResult.error(404, purchasesDisabledError);
    }
    if (!_secretMatches(authorization)) {
      log.warn(
        'purchase webhook refused: Authorization does not match '
        'REVENUECAT_WEBHOOK_SECRET',
      );
      return PurchaseResult.error(401, invalidSignatureError);
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } catch (e) {
      return PurchaseResult.error(400, invalidEventError, detail: '$e');
    }
    final event = WebhookEvent.parse(json);
    if (event == null) {
      return PurchaseResult.error(
        400,
        invalidEventError,
        detail: 'body must be {"event":{"type":…}}',
      );
    }

    // A sandbox purchase costs nothing and a sandbox account can make them all
    // day, so it grants only where a human asked for that (`PURCHASES_SANDBOX`,
    // a staging deployment). Acknowledged either way, so RevenueCat stops.
    if (event.isSandbox && !config.creditSandbox) {
      log.info(
        'purchase webhook ignored: sandbox ${event.type} '
        'product=${event.productId} (PURCHASES_SANDBOX is off)',
      );
      return PurchaseResult(200, {
        'ok': true,
        'granted': false,
        'ignored': 'sandbox',
      });
    }

    if (event.revokes) return _revoke(event);
    if (!event.grants) {
      // A renewal, a transfer, a subscription lapsing, RevenueCat's own TEST
      // event: all real, none of them the unlock being bought.
      log.info('purchase webhook ignored: ${event.type} event=${event.id}');
      return PurchaseResult(200, {
        'ok': true,
        'granted': false,
        'ignored': event.type,
      });
    }
    return _grant(event);
  }

  /// `POST /api/purchases/sync` — the client's nudge, and **Restore purchases**
  /// (SPEC §4.9).
  ///
  /// Two jobs, one call, because they are the same question. The phone has just
  /// paid and wants the unlock before the webhook lands; or the phone has been
  /// reinstalled, or is a second device, and the player has pressed Restore. Both
  /// ask us to look again, and in both cases the request carries **nothing**: this
  /// asks RevenueCat, with the server's own secret key, what [player] actually
  /// owns, and grants from that answer.
  ///
  /// That is the whole point of the endpoint's shape. A client that could name a
  /// product would be a client that could unlock the catalogue; a client that can
  /// only say "look again" can, at worst, make us ask RevenueCat a question we
  /// would have answered anyway.
  ///
  /// **This is what makes a restore real.** The unlock is a non-consumable, so the
  /// store keeps it forever and RevenueCat keeps reporting it; a reinstall on a
  /// signed-in player finds the same app user id, the same transaction, and — by
  /// the idempotency key — either grants it once or finds it already granted. A
  /// restore on a *new* player grants it to that player, which is the honest
  /// answer when the previous one was deleted.
  ///
  /// An unknown product here is **skipped**, not refused — the opposite of the
  /// webhook. A subscriber record legitimately lists everything that app user ever
  /// bought, including the Spark packs this build no longer sells and anything a
  /// future feature adds; a webhook, by contrast, is telling us about one specific
  /// purchase, and being unable to place it is a misconfiguration worth surfacing.
  Future<PurchaseResult> sync(PlayerRow player) async {
    if (!enabled) {
      return PurchaseResult.error(404, purchasesDisabledError);
    }
    final api = _api;
    if (api == null) {
      return PurchaseResult.error(503, revenueCatUnavailableError);
    }
    final RevenueCatSubscriber subscriber;
    try {
      subscriber = await api.subscriber(player.id);
    } on RevenueCatException catch (e) {
      log.warn('purchase sync could not reach RevenueCat: ${e.message}');
      return PurchaseResult.error(503, revenueCatUnavailableError);
    }

    var granted = 0;
    var seenUnlock = false;
    for (final transaction in subscriber.nonSubscriptions) {
      if (!FullUnlock.isUnlock(transaction.productId)) continue;
      if (transaction.isSandbox && !config.creditSandbox) continue;
      seenUnlock = true;
      final grant = await store.grantPurchase(
        PurchaseGrantRequest(
          playerId: player.id,
          productId: transaction.productId,
          transactionId: transaction.storeTransactionId,
          store: transaction.store,
          environment: transaction.isSandbox ? 'SANDBOX' : 'PRODUCTION',
          source: 'sync',
          purchasedAt: transaction.purchasedAt,
          now: _clock(),
        ),
      );
      if (!grant.granted) continue;
      granted++;
      log.info(
        'premium granted (sync) player=${player.id} '
        'product=${grant.productId} txn=${grant.transactionId}',
      );
    }

    final premium = await store.isPremium(player.id);
    // RevenueCat says this customer is entitled and we have nothing to show for
    // it. That is not a player problem and there is nothing to guess at — it is a
    // product attached to the wrong entitlement, or to none, or an entitlement
    // granted by hand in the dashboard with no purchase behind it. Logged loudly
    // because it is invisible from everywhere else, and deliberately *not* acted
    // on: an entitlement carries no store transaction id, and granting without one
    // would give up the idempotency that stops a refunded payment unlocking again.
    if (!premium &&
        subscriber.activeEntitlements.contains(FullUnlock.premiumEntitlement)) {
      log.warn(
        'RevenueCat reports the "${FullUnlock.premiumEntitlement}" entitlement '
        'for player=${player.id} but no ${FullUnlock.productId} transaction '
        '(check the product is attached to the entitlement in RevenueCat)',
      );
    }

    final ledger = await store.purchasesOf(player.id);
    return PurchaseResult(200, {
      'ok': true,
      // The answer the client acts on: everything, or not.
      'premium': premium,
      // How many purchases this call turned into premium. Almost always 0: either
      // the webhook won, or there was nothing to restore, and both are healthy.
      'granted': granted,
      // Whether RevenueCat knows of the unlock for this app user at all, which is
      // the difference between "restored" and "there was nothing to restore" — the
      // one sentence a Restore button has to be able to say truthfully.
      'owned': seenUnlock || premium,
      // The wallet, from the server, as every other shop answer reports it. A
      // premium player still earns Sparks by playing; they simply have nothing
      // left to spend them on.
      'balance': await store.walletBalance(player.id),
      // The ledger, so premium can be explained on the device that is asking
      // about it (SPEC §4.9) — the date, the store, and the transaction id off
      // the player's own receipt.
      'purchases': [for (final row in ledger) row.toJson()],
    });
  }

  Future<PurchaseResult> _grant(WebhookEvent event) async {
    if (event.productId.isEmpty || event.transactionId.isEmpty) {
      return PurchaseResult.error(
        400,
        invalidEventError,
        detail: 'a granting event needs product_id and a transaction id',
      );
    }
    if (!FullUnlock.isUnlock(event.productId)) {
      // Refused rather than ignored: RevenueCat is telling us money changed
      // hands for something this build does not sell. Guessing what it grants is
      // out of the question, and swallowing it would hide a misconfiguration
      // that has already taken a player's money. The non-2xx makes RevenueCat
      // retry and surfaces the event as failed in its dashboard, which is
      // exactly where a human should find it — and once the product id is fixed
      // or deployed, the retry lands.
      log.warn(
        'purchase webhook refused: unknown product "${event.productId}" '
        'event=${event.id} txn=${event.transactionId}',
      );
      return PurchaseResult.error(
        400,
        PurchaseGrant.unknownProductError,
        extra: {'productId': event.productId},
      );
    }
    final playerId = await _resolvePlayer(event.appUserIds);
    if (playerId == null) {
      log.warn(
        'purchase webhook refused: no player for app user '
        '${event.appUserIds.join(', ')} event=${event.id}',
      );
      return PurchaseResult.error(
        404,
        unknownPlayerError,
        extra: {'appUserId': event.appUserIds.firstOrNull},
      );
    }
    final grant = await store.grantPurchase(
      PurchaseGrantRequest(
        playerId: playerId,
        productId: event.productId,
        transactionId: event.transactionId,
        store: event.store,
        environment: event.environment,
        source: 'webhook',
        purchasedAt: event.purchasedAt,
        now: _clock(),
        eventId: event.id.isEmpty ? null : event.id,
      ),
    );
    if (!grant.ok) {
      // `unknown_product` cannot happen (checked above) and `unknown_player`
      // cannot either (resolved above); this is the race where the player was
      // deleted between the two.
      return PurchaseResult.error(404, grant.error!);
    }
    if (grant.duplicate) {
      // The ordinary retry. Answered 200 so RevenueCat stops, and logged at
      // debug because a webhook arriving twice is normal operation, not news.
      log.debug(
        'purchase webhook already recorded txn=${grant.transactionId} '
        'player=$playerId premium=${grant.premium}',
      );
    } else {
      log.info(
        'premium granted (webhook) player=$playerId '
        'product=${grant.productId} txn=${grant.transactionId} '
        'store=${event.store}',
      );
    }
    return PurchaseResult(200, {
      'ok': true,
      'granted': grant.granted,
      'duplicate': grant.duplicate,
      'playerId': playerId,
      'productId': grant.productId,
      // What the player holds now. On a duplicate this is the asking player's own
      // state, so a transaction already recorded against somebody else reports
      // `false` rather than implying it unlocked anything here.
      'premium': grant.premium,
    });
  }

  Future<PurchaseResult> _revoke(WebhookEvent event) async {
    if (event.transactionId.isEmpty) {
      return PurchaseResult.error(
        400,
        invalidEventError,
        detail: 'a refund event needs a transaction id',
      );
    }
    final revoke = await store.revokePurchase(
      transactionId: event.transactionId,
      now: _clock(),
    );
    if (!revoke.ok) {
      // Nothing of ours was ever recorded under that transaction: a subscription
      // cancelling, a product from elsewhere, or a refund for a purchase that
      // predates this feature. Acknowledged, because there is genuinely nothing
      // to do and a retry would find the same nothing.
      log.info(
        'purchase refund ignored: nothing recorded for '
        'txn=${event.transactionId} (${event.type}, event=${event.id})',
      );
      return PurchaseResult(200, {
        'ok': true,
        'revoked': false,
        'ignored': PurchaseRevoke.unknownTransactionError,
      });
    }
    if (revoke.duplicate) {
      log.debug(
        'purchase refund already applied txn=${event.transactionId} '
        'player=${revoke.playerId}',
      );
    } else {
      log.info(
        // The cosmetics the player bought with Sparks are untouched, by
        // construction rather than by care: premium was never rows in
        // `player_items`, so there is nothing here that could have reached them
        // (see [Db.revokePurchase]).
        'premium revoked (refund) player=${revoke.playerId} '
        'product=${revoke.productId} txn=${event.transactionId} '
        '${revoke.premium ? '(still premium: another live purchase)' : ''}',
      );
    }
    return PurchaseResult(200, {
      'ok': true,
      'revoked': revoke.revoked,
      'duplicate': revoke.duplicate,
      'playerId': ?revoke.playerId,
      // Normally false. True only where a second live purchase survives the
      // refund — the same player having bought the unlock on both stores.
      'premium': revoke.premium,
    });
  }

  /// The player one of [appUserIds] means, or null when none of them is one.
  ///
  /// We set the RevenueCat app user id to our player id from the app, so the
  /// first candidate normally hits. The others are tried because RevenueCat
  /// aliases identities of its own accord, and because our own player ids move
  /// under a merge (SPEC §4.5) — an unlock bought on a phone whose player was
  /// later absorbed must still unlock for the surviving player, which is what
  /// `ScoreStore.canonicalPlayerId` resolves.
  Future<String?> _resolvePlayer(List<String> appUserIds) async {
    for (final candidate in appUserIds) {
      // The shape is checked before the lookup so that a RevenueCat anonymous id
      // (`$RCAnonymousID:…`) or any other identifier never reaches the database
      // as a player id.
      if (!PlayerCredentials.isPlayerId(candidate)) continue;
      final canonical = await store.canonicalPlayerId(candidate);
      if (await store.playerById(canonical) != null) return canonical;
    }
    return null;
  }

  /// Whether [authorization] carries the configured webhook secret.
  ///
  /// Constant time in the length of the secret, so a wrong header cannot be
  /// tuned one character at a time by measuring the reply.
  ///
  /// Both the bare secret and `Bearer <secret>` are accepted. RevenueCat sends
  /// verbatim whatever string is typed into its dashboard, and both forms are
  /// what people type; neither is weaker, because both require knowing the
  /// secret.
  bool _secretMatches(String? authorization) {
    final expected = config.webhookSecret;
    if (expected.isEmpty) return false;
    final raw = authorization?.trim() ?? '';
    if (raw.isEmpty) return false;
    final candidate =
        raw.length > 7 &&
            raw.substring(0, 6).toLowerCase() == 'bearer' &&
            raw[6] == ' '
        ? raw.substring(7).trim()
        : raw;
    // `constantTimeEquals` is the one `players.dart` already uses to compare a
    // credential digest: one implementation of this, not two.
    return constantTimeEquals(utf8.encode(candidate), utf8.encode(expected));
  }
}
