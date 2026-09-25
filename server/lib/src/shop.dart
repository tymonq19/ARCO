/// The shop, server side (SPEC §4.8): serving the catalogue, reporting what a
/// player owns and holds, buying an item and equipping one.
///
/// The catalogue it serves also advertises the one-time unlock of SPEC §4.9 when
/// the money feature is configured — but nothing here takes money, and nothing
/// here decides whether a player holds it. Both live in `purchases.dart` and
/// `Db.isPremium`, where the only trustworthy signals about a payment are.
///
/// Storage lives in `Db` (the transaction that debits a wallet and writes an
/// item is there, because it has to be one transaction); the token rate lives in
/// `tokens.dart`; the item table lives in `catalogue.dart`. This file is the
/// part in between — it decides what a request means, and shapes the answer.
///
/// Two rules run through all of it.
///
/// **Ownership and balance live here, not on the phone.** A wallet kept in a
/// preferences file is edited in five minutes with a file browser, and the
/// moment real money or an ad reward can top it up, editing it is fraud rather
/// than a bug. So the phone holds no balance it is believed about: it sends an
/// item id, and the server decides.
///
/// **Everything sold is purely cosmetic**, whether it is bought with Sparks or
/// covered by the unlock. Nothing in the catalogue reaches `arco_core`. A paid
/// item that changed a paddle's width would break the replay verification that
/// guards the leaderboard (SPEC §4) — honest runs would stop verifying — and a
/// board where money buys rank is worthless. That is why there is no "effect"
/// field anywhere in this feature, and why there must never be one.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'catalogue.dart';
import 'db.dart';
import 'logging.dart';
import 'score_store.dart';
import 'tokens.dart';

/// `POST /api/shop/*` bodies larger than this are rejected with 413.
///
/// A body carries one item id, or one id per slot. Anything larger is not a
/// client of these endpoints.
const int maxShopBodyBytes = 4 * 1024;

/// The `v` query parameter was not a catalogue version.
const String invalidVersionError = 'invalid_version';

/// The body named no slot at all, or named one with something that is not a
/// string.
const String invalidSlotsError = 'invalid_slots';

/// Outcome of a shop call: an HTTP status plus a JSON body — the same shape
/// `AccountService` returns, so `api.dart` stays routing only.
class ShopResult {
  const ShopResult(this.status, this.body);

  factory ShopResult.error(
    int status,
    String code, {
    String? detail,
    Map<String, dynamic>? extra,
  }) => ShopResult(status, {
    'ok': false,
    'error': code,
    'detail': ?detail,
    ...?extra,
  });

  final int status;
  final Map<String, dynamic> body;

  bool get ok => status == 200;
}

class ShopService {
  ShopService({
    required this.store,
    required this.log,
    UnlockProduct? Function(int clientVersion)? unlock,
    DateTime Function()? clock,
  }) : _unlock = unlock ?? _noUnlock,
       _clock = clock ?? DateTime.now;

  final ScoreStore store;
  final Logger log;

  /// The one-time unlock to advertise, by client version (SPEC §4.9).
  ///
  /// Injected rather than read from `FullUnlock` directly, because whether there
  /// is one at all is a deployment question: `PurchaseService.unlockFor` answers
  /// null while `PURCHASES_ENABLED` is off, and a shop that cannot take money must
  /// not offer something to buy. The default here is that null, so the cosmetic
  /// shop keeps working untouched with no money feature wired at all.
  final UnlockProduct? Function(int clientVersion) _unlock;

  final DateTime Function() _clock;

  static UnlockProduct? _noUnlock(int _) => null;

  /// The catalogue as [clientVersion] sees it, with an `owned` flag per item
  /// plus the caller's balance and equipped slots (SPEC §4.8).
  ///
  /// Balance and slots ride along because the shop screen needs all three and
  /// one round trip is one round trip. The prices are the server's; no build of
  /// the client ever hardcodes one.
  Future<ShopResult> catalogue(
    PlayerRow player, {
    required int clientVersion,
  }) async {
    final inventory = await store.inventory(player.id, now: _clock());
    final owned = _ownedIdSet(inventory, clientVersion);
    return ShopResult(200, {
      'ok': true,
      'version': clientVersion,
      // What the server actually has. When it is higher than `version`, the
      // client is behind and there is content it cannot draw yet — which is a
      // thing worth being able to say in the UI, rather than a thing to hide.
      'latestVersion': Catalogue.version,
      'kinds': [
        for (final kind in Catalogue.kindsUpTo(clientVersion)) kind.name,
      ],
      'items': [
        for (final item in Catalogue.upTo(clientVersion))
          item.toJson(owned: owned.contains(item.id)),
      ],
      'balance': inventory.balance,
      'equipped': _resolveEquipped(inventory.equipped, clientVersion, owned),
      // Whether this player holds the one-time unlock (SPEC §4.9). Every item
      // above then reads `owned: true`, prices included but irrelevant, so a
      // client can draw the shop as a wardrobe rather than a price list from one
      // answer.
      'premium': inventory.premium,
      // What real money can buy: one non-consumable product that unlocks
      // everything (SPEC §4.9). Absent — and so a section the client does not
      // draw — unless this deployment has RevenueCat configured. It carries a
      // product identifier and a name key, and deliberately **no price**: the only
      // honest price is the localised, tax-inclusive one the device's own store
      // reports. Absent as well once the player is premium, because there is then
      // nothing left to sell them.
      'unlock': ?(inventory.premium ? null : _unlock(clientVersion)?.toJson()),
    });
  }

  /// What the caller owns and holds (SPEC §4.8).
  Future<ShopResult> inventory(
    PlayerRow player, {
    required int clientVersion,
  }) async {
    final inventory = await store.inventory(player.id, now: _clock());
    return ShopResult(200, {
      'ok': true,
      'version': clientVersion,
      'latestVersion': Catalogue.version,
      'balance': inventory.balance,
      'earnedTotal': inventory.earnedTotal,
      'spentTotal': inventory.spentTotal,
      // Sparks ever bought with money. 0 for every wallet from now on — money
      // buys the one-time unlock, which credits no Sparks at all (SPEC §4.9) —
      // and still reported so that a wallet from before that change can still be
      // explained by the server that holds it.
      'purchasedTotal': inventory.purchasedTotal,
      // Whether the player holds the one-time unlock (SPEC §4.9): every cosmetic
      // there is, and no ads. The one field a client needs in order to know that
      // `owned` below is the whole catalogue and will stay that way.
      'premium': inventory.premium,
      // And Sparks earned from watching rewarded ads (SPEC §4.10), kept apart
      // from both — so `balance == earnedTotal + purchasedTotal + adTotal -
      // spentTotal` holds, with a non-duplicable ledger row behind each term.
      'adTotal': inventory.adTotal,
      // Everything the player may use, free items included and the whole
      // catalogue when they are premium: the question a client asks is "what can
      // I wear", and neither a free item nor a premium entitlement has a row to
      // say so. Which of them were paid for is answerable from the catalogue's
      // `free` flag and from `premium` above.
      'owned': _ownedIds(inventory, clientVersion),
      'equipped': _resolveEquipped(
        inventory.equipped,
        clientVersion,
        _ownedIdSet(inventory, clientVersion),
      ),
      // How much of today's earning allowance is gone, and what it is, so the
      // client can say "you have earned 200 of 200 today, it resets at midnight
      // UTC" instead of leaving a player wondering why a good run paid nothing.
      'earnedToday': inventory.earnedToday,
      'dailyCap': TokenRate.dailyCap,
    });
  }

  /// Buys one item for [player] (SPEC §4.8).
  ///
  /// [body] is the raw request body; the only field read from it is `itemId`.
  /// There is deliberately no price or quantity in the request: the price comes
  /// from the catalogue inside the buying transaction.
  Future<ShopResult> buy(
    PlayerRow player,
    Uint8List body, {
    required int clientVersion,
  }) async {
    final parsed = _decodeObject(body);
    if (parsed.refusal != null) return parsed.refusal!;
    final rawId = parsed.json!['itemId'];
    if (rawId is! String || rawId.isEmpty) {
      return ShopResult.error(
        400,
        'invalid_json',
        detail: 'itemId must be a non-empty string',
      );
    }
    final item = Catalogue.byId(rawId);
    if (item == null) {
      return ShopResult.error(
        404,
        BuyOutcome.unknownItemError,
        extra: {'itemId': rawId},
      );
    }

    final outcome = await store.buyItem(
      playerId: player.id,
      itemId: item.id,
      now: _clock(),
    );
    if (!outcome.ok) {
      // Short balance. The price and the balance are both the server's own
      // numbers, so the client can say exactly how many tokens are missing.
      return ShopResult.error(
        402,
        outcome.error!,
        extra: {
          'itemId': outcome.itemId,
          'priceTokens': outcome.price,
          'balance': outcome.balance,
        },
      );
    }
    if (outcome.charged > 0) {
      log.info(
        'item bought player=${player.id} item=${outcome.itemId} '
        'price=${outcome.charged} balance=${outcome.balance}',
      );
    }
    return ShopResult(200, {
      'ok': true,
      'itemId': outcome.itemId,
      'priceTokens': outcome.price,
      // What this call took. 0 when the item was already owned, which is what
      // makes a retry after a lost response safe: the same request twice costs
      // the price once.
      'charged': outcome.charged,
      // Already owned covers three cases the client does not have to tell apart:
      // free, bought before, and premium (SPEC §4.9).
      'alreadyOwned': outcome.alreadyOwned,
      'balance': outcome.balance,
      'premium': outcome.premium,
      'owned': _resolveOwned(
        outcome.ownedItemIds,
        outcome.premium,
        clientVersion,
      ),
    });
  }

  /// Stores the caller's slot choices (SPEC §4.8).
  ///
  /// The body names slots by kind: `{"theme":"theme.glass","ball":null}` equips
  /// a theme and puts the ball back to the free default. A slot that is not
  /// mentioned is left alone.
  Future<ShopResult> equip(
    PlayerRow player,
    Uint8List body, {
    required int clientVersion,
  }) async {
    final parsed = _decodeObject(body);
    if (parsed.refusal != null) return parsed.refusal!;
    final json = parsed.json!;
    final slots = <String, String?>{};
    for (final entry in json.entries) {
      final value = entry.value;
      if (value == null) {
        slots[entry.key] = null;
        continue;
      }
      if (value is! String || value.isEmpty) {
        return ShopResult.error(
          400,
          invalidSlotsError,
          detail: '"${entry.key}" must be an item id or null',
        );
      }
      slots[entry.key] = value;
    }
    if (slots.isEmpty) {
      return ShopResult.error(
        400,
        invalidSlotsError,
        detail:
            'name at least one slot: '
            '${[for (final k in CosmeticKind.values) k.name].join(', ')}',
      );
    }

    final outcome = await store.equipItems(
      EquipRequest(playerId: player.id, slots: slots, now: _clock()),
    );
    if (!outcome.ok) {
      log.info(
        'equip refused player=${player.id} '
        '${outcome.error} item=${outcome.itemId}',
      );
      return ShopResult.error(
        _equipStatus(outcome.error!),
        outcome.error!,
        extra: {
          if (outcome.error == EquipOutcome.unknownKindError)
            'kind': outcome.itemId
          else
            'itemId': outcome.itemId,
        },
      );
    }
    return ShopResult(200, {
      'ok': true,
      'equipped': _resolveEquipped(
        outcome.equipped,
        clientVersion,
        // Every slot is answered against what the player owns *now*, not only
        // the one this call wrote: a refund can have un-owned another slot's
        // choice since it was stored (SPEC §4.9), and the answer has to be what
        // the game will actually draw.
        _ownedSet(outcome.ownedItemIds, outcome.premium, clientVersion),
      ),
    });
  }

  /// Parses the catalogue version a client asks for.
  ///
  /// Absent means "whatever you have": a caller that does not version itself
  /// gets the current catalogue. A version newer than this server's is clamped
  /// rather than refused — a client ahead of its server is an ordinary state
  /// during a rollout, and the honest answer is what the server does have.
  /// Anything that is not a version at all is a `400`, in keeping with `period`
  /// and `country` on the leaderboard (SPEC §4.6).
  static ({int? version, String? error}) parseClientVersion(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return (version: Catalogue.version, error: null);
    }
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed < 1) {
      return (version: null, error: invalidVersionError);
    }
    return (
      version: parsed > Catalogue.version ? Catalogue.version : parsed,
      error: null,
    );
  }

  static int _equipStatus(String error) => switch (error) {
    EquipOutcome.notOwnedError => 403,
    EquipOutcome.unknownItemError => 404,
    _ => 400,
  };

  /// Every item id the player may use, as a client of [clientVersion] sees it:
  /// the free ones, the ones they bought with Sparks, and — when they are
  /// premium — **every** item there is (SPEC §4.9), minus anything that version
  /// has no way to draw.
  ///
  /// Premium is read here as one flag covering the whole loop rather than as a
  /// list of ids from storage, which is the point of it: an item added to the
  /// catalogue next year is inside this loop the day it is added, with nothing
  /// written for anybody who already paid.
  static Set<String> _ownedIdSet(
    PlayerInventory inventory,
    int clientVersion,
  ) => _ownedSet(inventory.ownedItemIds, inventory.premium, clientVersion);

  /// The same answer as a list, in catalogue order — a set literal is a
  /// `LinkedHashSet`, so the order the items were served in is preserved.
  static List<String> _ownedIds(PlayerInventory inventory, int clientVersion) =>
      _ownedIdSet(inventory, clientVersion).toList(growable: false);

  static List<String> _resolveOwned(
    List<String> bought,
    bool premium,
    int clientVersion,
  ) => _ownedSet(bought, premium, clientVersion).toList(growable: false);

  static Set<String> _ownedSet(
    List<String> bought,
    bool premium,
    int clientVersion,
  ) {
    final boughtIds = bought.toSet();
    return <String>{
      for (final item in Catalogue.upTo(clientVersion))
        if (premium || item.free || boughtIds.contains(item.id)) item.id,
    };
  }

  /// The stored slot choices with the defaults filled in, one entry per kind the
  /// client understands.
  ///
  /// A stored item the client cannot draw — because it was added after the
  /// version it asked for — is reported as that kind's default rather than
  /// hidden: the answer has to be something the client can actually render, and
  /// the stored preference is untouched, so it comes back the moment the app is
  /// updated.
  ///
  /// [owned] applies the same treatment to an item the player no longer owns,
  /// which is the case a refund creates: premium is revoked while a cosmetic it
  /// covered is still equipped (SPEC §4.9). The slot then answers its free
  /// default, and the *stored* choice is again left alone — so it comes back
  /// intact if the player buys that item with Sparks or buys the unlock again.
  /// Omitted where the caller has just validated ownership itself.
  static Map<String, String> _resolveEquipped(
    Map<String, String> stored,
    int clientVersion, [
    Set<String>? owned,
  ]) => {
    for (final kind in Catalogue.kindsUpTo(clientVersion))
      kind.name: _visible(stored[kind.name], clientVersion, kind, owned),
  };

  static String _visible(
    String? id,
    int clientVersion,
    CosmeticKind kind,
    Set<String>? owned,
  ) {
    final item = Catalogue.byId(id);
    if (item == null || item.sinceVersion > clientVersion) {
      return Catalogue.defaultFor(kind).id;
    }
    if (owned != null && !owned.contains(item.id)) {
      return Catalogue.defaultFor(kind).id;
    }
    return item.id;
  }

  /// Decodes a JSON object body, or the refusal to answer with.
  static ({Map<String, dynamic>? json, ShopResult? refusal}) _decodeObject(
    Uint8List body,
  ) {
    if (body.isEmpty) {
      return (
        json: null,
        refusal: ShopResult.error(
          400,
          'invalid_json',
          detail: 'body must be a JSON object',
        ),
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } catch (e) {
      return (
        json: null,
        refusal: ShopResult.error(400, 'invalid_json', detail: '$e'),
      );
    }
    if (json is! Map<String, dynamic>) {
      return (
        json: null,
        refusal: ShopResult.error(
          400,
          'invalid_json',
          detail: 'body must be a JSON object',
        ),
      );
    }
    return (json: json, refusal: null);
  }
}
