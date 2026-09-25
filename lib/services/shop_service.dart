/// The shop, client side (SPEC §4.8): the wallet, what is owned, what is worn,
/// buying and equipping.
///
/// The catalogue it caches also carries the Spark packs of SPEC §4.9 when the
/// deployment sells them — but nothing here spends money. Paying happens in
/// `purchase_service.dart`, and the Sparks it buys arrive the only way any Spark
/// arrives: because the server said so.
///
/// **Everything here is purely cosmetic.** Not one byte of it reaches
/// `packages/arco_core`: a skin picks a shape and a palette, never a paddle
/// width, a ball speed or a life. Two reasons, both fatal if ignored — the server
/// re-simulates every submitted solo replay to verify it (SPEC §4), so an item
/// that touched the simulation would make *honest* runs fail verification; and a
/// leaderboard where money buys rank is worth nothing. The equipped items leave
/// this file as a [Equipped] the painter reads, and as a [GameTheme] in
/// [Settings]. Nothing else.
///
/// **The server is authoritative.** No price, no balance and no ownership is ever
/// decided here. [ShopSnapshot] is a *cache of the server's last answer*, kept so
/// the game opens wearing the right skin before any request finishes and keeps
/// working on a phone with no network — never so the phone can decide what a
/// player owns. Every purchase and every equip is the server's call, and a stale
/// cache costs one refused request, not a free item.
library;

import 'package:flutter/foundation.dart';

import '../app/cosmetics.dart';
import '../app/game_theme.dart';
import '../app/settings.dart';
import 'api_client.dart';
import 'player_identity.dart';
import 'storage.dart';

/// The three slots of SPEC §4.8, named as the server names them.
///
/// Exactly one item of each is worn at a time, and an item id carries its slot as
/// a prefix (`theme.glass`, `ball.comet`) so a log line, a preference and a
/// request all say what they are about without a lookup table.
abstract final class CosmeticSlot {
  static const String theme = 'theme';
  static const String ball = 'ball';
  static const String paddle = 'paddle';

  /// Slot order, which is also the order a shop screen shows its sections in.
  static const List<String> all = <String>[theme, ball, paddle];

  /// The slot [itemId] belongs to, or null when it carries no known prefix.
  static String? of(String itemId) {
    final dot = itemId.indexOf('.');
    if (dot <= 0) return null;
    final slot = itemId.substring(0, dot);
    return all.contains(slot) ? slot : null;
  }
}

/// How a shop call ended.
enum ShopStatus {
  /// Nothing has been asked yet. Whatever is on screen comes from the cache.
  idle,

  /// A call is in flight.
  loading,

  /// The server answered; everything shown is its own.
  ready,

  /// The server could not be reached. The game plays on, the last known items
  /// stay equipped, and the shop says it needs a connection.
  offline,

  /// The server was reached and refused (rate limited, a 5xx, an answer that
  /// could not be read). Worth a different sentence from [offline]: waiting helps
  /// here, and airplane mode is not the reason.
  unavailable,
}

/// What a buy attempt came to.
enum ShopOutcome {
  /// Owned and paid for — or already owned, which is what a safe retry looks
  /// like: the server charges the price once however often the same request
  /// arrives.
  bought,

  /// The wallet is short. [ShopBuyResult.missing] says by how much, from the
  /// server's own two numbers.
  insufficient,

  /// The server has no such item: this build is ahead of it, or the cache is
  /// stale.
  unknownItem,

  /// The server could not be reached, and asking it afterwards did not reach it
  /// either — so nothing is claimed. **No tokens were taken**: the wallet is only
  /// ever debited inside the server's own transaction, and a retry of the same
  /// item costs the price once.
  offline,

  /// The server refused for a reason of its own. Nothing was taken.
  unavailable,
}

/// The result of [ShopService.buy].
@immutable
class ShopBuyResult {
  const ShopBuyResult(this.outcome, {this.purchase});

  final ShopOutcome outcome;

  /// The server's answer, when it sent one: the price, the balance, and what was
  /// actually charged.
  final ShopPurchase? purchase;

  bool get ok => outcome == ShopOutcome.bought;

  /// Tokens still needed; 0 unless [outcome] is [ShopOutcome.insufficient].
  int get missing => purchase?.missing ?? 0;
}

/// The last thing the server said about this player's shop, plus the catalogue it
/// served (SPEC §4.8).
///
/// Immutable and cheap to compare, so it can be provided above the navigator and
/// a change repaints exactly what shows it.
@immutable
class ShopSnapshot {
  const ShopSnapshot({
    this.items = const <ShopItem>[],
    this.packs = const <ShopPack>[],
    this.owned = const <String>{},
    this.equipped = const <String, String>{},
    this.balance = 0,
    this.earnedToday = 0,
    this.dailyCap = 0,
    this.latestVersion = 0,
    this.knownAt,
  });

  /// The empty state: nothing has ever been fetched on this device.
  static const ShopSnapshot unknown = ShopSnapshot();

  /// The items that cost nothing, and are therefore owned by every player
  /// without a row anywhere (`Catalogue.free`, `server/lib/src/catalogue.dart`).
  ///
  /// This is the one fact about the catalogue the client holds by itself, and it
  /// is here for a single case: a phone that has never reached the server still
  /// has to be able to play, and to pick between the looks that cost nothing.
  /// `test/services/shop_ids_test.dart` pins the set against the server's own
  /// table, so it cannot drift.
  ///
  /// It grants nothing. Equipping is the server's decision (`403 item_not_owned`
  /// if it disagrees) and buying certainly is, so the worst a wrong entry here can
  /// cost is one refused request — never a free item. The dangerous direction,
  /// believing the phone about something that costs tokens, is not possible: a
  /// paid item is owned only when the **server** has said so.
  static const Set<String> freeItemIds = <String>{
    'theme.neon',
    'theme.classic',
    'ball.orb',
    'paddle.arc',
  };

  /// The catalogue in the order the server served it: by slot, cheapest first.
  final List<ShopItem> items;

  /// The Spark packs the server sells (SPEC §4.9), cheapest first. **Empty**
  /// unless the deployment has RevenueCat configured — which is how the shop
  /// knows not to draw a money section at all.
  ///
  /// A pack carries an amount of Sparks and a store product identifier, and
  /// deliberately no price: the price is the store's, localised, and is fetched
  /// from the device's own store by `PurchaseService`.
  final List<ShopPack> packs;

  /// Item ids the server says this player may wear, free ones included.
  final Set<String> owned;

  /// Slot → item id, as the server stores it.
  final Map<String, String> equipped;

  /// The wallet, and the day's earning allowance — all three the server's own
  /// numbers.
  final int balance;
  final int earnedToday;
  final int dailyCap;

  /// The newest catalogue version the server has. Higher than this build's means
  /// there is content the app cannot draw yet.
  final int latestVersion;

  /// When the server last confirmed all of this; null while nothing ever has.
  final DateTime? knownAt;

  /// Whether a server answer is behind this at all. A screen must not show a
  /// balance of "0" for a wallet nobody has ever asked about.
  bool get known => knownAt != null;

  /// Whether a catalogue has been seen, i.e. whether there is anything to show in
  /// a shop.
  bool get hasCatalogue => items.isNotEmpty;

  /// Whether the day's earning allowance is spent ([dailyCap] of SPEC §4.8).
  /// Both numbers are the server's; this only compares them.
  bool get dailyCapReached => dailyCap > 0 && earnedToday >= dailyCap;

  /// Whether [itemId] may be worn: the server said so, or it costs nothing.
  bool owns(String itemId) =>
      owned.contains(itemId) || freeItemIds.contains(itemId);

  /// Whether [itemId] is what is worn in its slot.
  bool isEquipped(String itemId) {
    final slot = CosmeticSlot.of(itemId);
    return slot != null && equipped[slot] == itemId;
  }

  /// Whether the wallet covers [item] right now. A comparison of two server
  /// numbers, never a sum computed here.
  bool canAfford(ShopItem item) => known && balance >= item.priceTokens;

  /// The catalogue entry for [itemId], or null when the catalogue has none.
  ShopItem? item(String itemId) {
    for (final item in items) {
      if (item.id == itemId) return item;
    }
    return null;
  }

  /// The items of one slot, in catalogue order.
  List<ShopItem> itemsOf(String slot) => <ShopItem>[
    for (final item in items)
      if (item.kind == slot) item,
  ];

  /// The slots the catalogue actually carries, in [CosmeticSlot.all] order.
  List<String> get slots => <String>[
    for (final slot in CosmeticSlot.all)
      if (items.any((item) => item.kind == slot)) slot,
  ];

  /// The ball and paddle the arena should draw — the only thing the renderer ever
  /// learns from the shop. An id this build cannot draw resolves to the free
  /// default rather than throwing (see `lib/app/cosmetics.dart`).
  Equipped get skins => Equipped(
    ball: BallSkin.parse(equipped[CosmeticSlot.ball]),
    paddle: PaddleSkin.parse(equipped[CosmeticSlot.paddle]),
  );

  /// The look the server has stored, or null when it holds none this build knows.
  GameTheme? get theme => GameThemes.byItemId(equipped[CosmeticSlot.theme]);

  /// The catalogue id of a look, which is exactly its `Strings` key — the server
  /// seeded the theme ids as the keys `lib/app/strings.dart` already carried, so
  /// no mapping table exists to fall out of step.
  static String idOfTheme(GameTheme theme) => theme.nameKey;

  ShopSnapshot copyWith({
    List<ShopItem>? items,
    List<ShopPack>? packs,
    Set<String>? owned,
    Map<String, String>? equipped,
    int? balance,
    int? earnedToday,
    int? dailyCap,
    int? latestVersion,
    DateTime? knownAt,
  }) => ShopSnapshot(
    items: items ?? this.items,
    packs: packs ?? this.packs,
    owned: owned ?? this.owned,
    equipped: equipped ?? this.equipped,
    balance: balance ?? this.balance,
    earnedToday: earnedToday ?? this.earnedToday,
    dailyCap: dailyCap ?? this.dailyCap,
    latestVersion: latestVersion ?? this.latestVersion,
    knownAt: knownAt ?? this.knownAt,
  );

  /// The same snapshot wearing [itemId] in its slot.
  ShopSnapshot wearing(String slot, String itemId) =>
      copyWith(equipped: <String, String>{...equipped, slot: itemId});

  Map<String, dynamic> toJson() => {
    'v': 1,
    'items': [for (final item in items) item.toJson()],
    'packs': [for (final pack in packs) pack.toJson()],
    'owned': owned.toList(),
    'equipped': equipped,
    'balance': balance,
    'earnedToday': earnedToday,
    'dailyCap': dailyCap,
    'latestVersion': latestVersion,
    'knownAt': knownAt?.toUtc().toIso8601String(),
  };

  /// Reads a cached snapshot; null for anything that is not one this build wrote.
  static ShopSnapshot? fromJson(Map<String, dynamic>? j) {
    if (j == null || j['v'] != 1) return null;
    return ShopSnapshot(
      items: <ShopItem>[
        for (final raw in (j['items'] as List?) ?? const [])
          if (raw is Map<String, dynamic>) ?ShopItem.fromJson(raw),
      ],
      packs: <ShopPack>[
        for (final raw in (j['packs'] as List?) ?? const [])
          if (raw is Map<String, dynamic>) ?ShopPack.fromJson(raw),
      ],
      owned: <String>{
        for (final id in (j['owned'] as List?) ?? const []) '$id',
      },
      equipped: <String, String>{
        for (final entry in ((j['equipped'] as Map?) ?? const {}).entries)
          if (entry.value is String) '${entry.key}': entry.value as String,
      },
      balance: (j['balance'] as num?)?.toInt() ?? 0,
      earnedToday: (j['earnedToday'] as num?)?.toInt() ?? 0,
      dailyCap: (j['dailyCap'] as num?)?.toInt() ?? 0,
      latestVersion: (j['latestVersion'] as num?)?.toInt() ?? 0,
      knownAt: DateTime.tryParse(j['knownAt'] as String? ?? ''),
    );
  }
}

/// Reads the shop endpoints of SPEC §4.8 and keeps the answer.
///
/// A [ChangeNotifier] because three things watch it: the arena (through the
/// [Equipped] provided above the navigator), the shop screen, and the balance on
/// the title screen.
class ShopService extends ChangeNotifier {
  ShopService({
    required this.api,
    required this.identity,
    required this.storage,
    required this.settings,
    DateTime Function()? now,
    this.catalogueVersion = clientCatalogueVersion,
  }) : _now = now ?? DateTime.now {
    // The cache is read synchronously, before the first frame: a player who
    // bought a skin has to be wearing it when the app opens, not a frame or a
    // round trip later, and on a phone with no network that is all there will
    // ever be.
    _snapshot =
        ShopSnapshot.fromJson(storage.shopCache) ?? ShopSnapshot.unknown;
    _pending = <String, String>{...storage.shopPendingEquip};
  }

  /// The catalogue version **this build** can draw (`Catalogue.version`).
  ///
  /// It is sent with every shop call, and the server serves nothing newer, so an
  /// app that shipped before a kind of item existed is never handed one it would
  /// have to render as a blank card.
  static const int clientCatalogueVersion = 1;

  /// How long an answer is reused before a screen that opens re-reads it. There
  /// is no polling: the shop refreshes when it is opened, when the title screen
  /// appears and after a run has been submitted.
  static const Duration freshness = Duration(minutes: 2);

  final ApiClient api;

  /// Who the wallet belongs to (SPEC §4.4). Anonymous players have a server-side
  /// identity too, so the shop works for them without a sign-in.
  final PlayerIdentity identity;
  final Storage storage;

  /// Where the equipped **look** lives. The other two slots are drawn from
  /// [snapshot]; the theme is a [Settings] value because every screen already
  /// reads it from there, and it has to be right before any request finishes.
  final Settings settings;

  final int catalogueVersion;
  final DateTime Function() _now;

  late ShopSnapshot _snapshot;
  ShopStatus _status = ShopStatus.idle;
  DateTime? _confirmedAt;
  Future<void>? _refreshing;

  /// Slot choices made while the server was unreachable, waiting to be pushed.
  late Map<String, String> _pending;

  ShopSnapshot get snapshot => _snapshot;
  ShopStatus get status => _status;

  /// The ball and the paddle the arena draws.
  Equipped get equipped => _snapshot.skins;

  /// Whether the wallet has ever been read. Nothing shows a balance until it has:
  /// "0" is a claim about the wallet, and we would not be entitled to make it.
  bool get balanceKnown => _snapshot.known;
  int get balance => _snapshot.balance;

  bool get loading => _status == ShopStatus.loading;

  /// The last attempt did not produce an answer. The shop says so; the game does
  /// not care.
  bool get failed =>
      _status == ShopStatus.offline || _status == ShopStatus.unavailable;

  /// Slot choices still waiting to reach the server, for a test and for a
  /// "not synced yet" hint.
  Map<String, String> get pendingEquip => Map.unmodifiable(_pending);

  /// Re-reads the catalogue and the inventory (SPEC §4.8).
  ///
  /// [issue] lets this call **issue** the anonymous identity of SPEC §4.4 if the
  /// device has none: opening the shop is a player asking for something that needs
  /// a wallet, so it may. Everywhere else it is false, which keeps a player who
  /// only ever plays offline costing the server nothing — and keeps the app from
  /// creating a player at launch.
  ///
  /// Concurrent callers join the call in flight. An answer younger than
  /// [freshness] is reused unless [force].
  Future<void> refresh({bool issue = false, bool force = false}) {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final at = _confirmedAt;
    if (!force &&
        at != null &&
        _now().difference(at) < freshness &&
        _status == ShopStatus.ready) {
      return Future<void>.value();
    }
    final call = _refresh(issue: issue);
    _refreshing = call;
    return call.whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh({required bool issue}) async {
    final credentials = issue
        ? await identity.ensureIssued()
        : await identity.load();
    if (credentials == null) {
      // There is nobody to ask about yet. When this call was allowed to create a
      // player and still has none, something stopped it — no network to issue
      // over, or nowhere to keep the secret — and the shop screen has to say so.
      // When it was not allowed to (the title screen, [issue] false), there is
      // nothing wrong at all, and a failure state would be a lie.
      if (issue) _setStatus(ShopStatus.offline);
      return;
    }
    _setStatus(ShopStatus.loading);
    try {
      // Anything chosen while offline goes up first, so the answer we adopt
      // below already contains it instead of undoing it.
      await _pushPending(credentials);
      // Sequential on purpose: two calls whose errors must not race each other
      // into an unhandled rejection, and the shop budget (SPEC §4.8: 30 calls
      // per IP per minute) has ample room for both.
      final catalogue = await api.shopCatalogue(
        credentials,
        version: catalogueVersion,
      );
      final inventory = await api.shopInventory(
        credentials,
        version: catalogueVersion,
      );
      await _adopt(credentials, catalogue, inventory);
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        // The credential is not ours any more (a deleted account, a rebuilt
        // database). Forgetting it is what puts the device back to anonymous;
        // the next submission issues a fresh identity, with a fresh wallet.
        await identity.forget();
      }
      _setStatus(e.isOffline ? ShopStatus.offline : ShopStatus.unavailable);
    }
  }

  /// Installs a server answer as the truth, and dresses the app in it.
  Future<void> _adopt(
    PlayerCredentials credentials,
    ShopCatalogue catalogue,
    ShopInventory inventory,
  ) async {
    // A device that has never synced holds a look the player chose here and the
    // server has never heard about. Its own choice is the newer information, so
    // it is pushed rather than overwritten — otherwise installing this build
    // would silently undress everybody back to the default.
    final firstSync = !_snapshot.known;
    final owned = <String>{
      ...inventory.owned,
      for (final item in catalogue.items)
        if (item.owned) item.id,
    };
    _snapshot = ShopSnapshot(
      items: catalogue.items,
      // Whether this deployment sells Sparks at all, and for how many. Cached
      // with the rest of the catalogue so a shop opened offline still knows
      // there is a money section — it just cannot price it (SPEC §4.9).
      packs: catalogue.packs,
      owned: owned,
      equipped: inventory.equipped.isEmpty
          ? catalogue.equipped
          : inventory.equipped,
      balance: inventory.balance,
      earnedToday: inventory.earnedToday,
      dailyCap: inventory.dailyCap,
      latestVersion: inventory.latestVersion,
      knownAt: _now(),
    );
    _confirmedAt = _now();
    final localTheme = ShopSnapshot.idOfTheme(settings.theme);
    if (firstSync &&
        _snapshot.equipped[CosmeticSlot.theme] != localTheme &&
        _snapshot.owns(localTheme)) {
      _snapshot = _snapshot.wearing(CosmeticSlot.theme, localTheme);
      await _save();
      _setStatus(ShopStatus.ready);
      // Best effort: if it does not land, the pending slot keeps it and the next
      // refresh tries again.
      await _sendEquip(credentials, CosmeticSlot.theme, localTheme);
      return;
    }
    await _save();
    _applyTheme();
    _setStatus(ShopStatus.ready);
  }

  /// Dresses the app in the look the server has stored (SPEC §4.8: the slot
  /// follows the account, so a second device wears what the first one chose).
  void _applyTheme() {
    final theme = _snapshot.theme;
    if (theme == null || theme.id == settings.themeId) return;
    if (!_snapshot.owns(ShopSnapshot.idOfTheme(theme))) return;
    settings.theme = theme;
  }

  /// Buys [itemId] and puts it on (SPEC §4.8).
  ///
  /// Wearing it is part of buying it: paying for something you cannot see is a
  /// receipt, not a reward. The equip is best effort — the item is owned either
  /// way, and the slot can be set again.
  ///
  /// Nothing about the price or the wallet is decided here. On a failure that
  /// leaves the purchase unsettled the server is asked again rather than guessed
  /// at, which is why a retry can never take tokens twice: the second request for
  /// the same item charges 0.
  Future<ShopBuyResult> buy(String itemId) async {
    final credentials = await identity.ensureIssued();
    if (credentials == null) {
      _setStatus(ShopStatus.offline);
      return const ShopBuyResult(ShopOutcome.offline);
    }
    try {
      final purchase = await api.shopBuy(
        credentials,
        itemId,
        version: catalogueVersion,
      );
      if (!purchase.ok) {
        // A refusal carries the server's own price and balance: adopt them, so
        // the screen the player is looking at stops disagreeing with it.
        _snapshot = _snapshot.copyWith(
          balance: purchase.balance,
          knownAt: _now(),
        );
        await _save();
        _setStatus(ShopStatus.ready);
        return ShopBuyResult(
          purchase.insufficient
              ? ShopOutcome.insufficient
              : ShopOutcome.unknownItem,
          purchase: purchase,
        );
      }
      _snapshot = _snapshot.copyWith(
        owned: <String>{..._snapshot.owned, ...purchase.owned, purchase.itemId},
        balance: purchase.balance,
        knownAt: _now(),
      );
      _confirmedAt = _now();
      await _save();
      _setStatus(ShopStatus.ready);
      await equip(purchase.itemId);
      return ShopBuyResult(ShopOutcome.bought, purchase: purchase);
    } on ApiException catch (e) {
      // The purchase may have landed before the answer was lost. Never guess:
      // ask the server what it holds. If it holds the item, the player owns it
      // and this is a success; if the server cannot be reached at all, nothing is
      // claimed and nothing was taken — the debit only ever happens inside the
      // server's transaction.
      if (e.isUnauthorized) await identity.forget();
      await refresh(force: true);
      if (_status == ShopStatus.ready) {
        if (_snapshot.owns(itemId)) {
          await equip(itemId);
          return const ShopBuyResult(ShopOutcome.bought);
        }
        // The server answers, and does not hold the item: the purchase did not
        // happen and nothing was taken. "You are offline" would be the wrong
        // sentence for a shop that is plainly answering.
        return const ShopBuyResult(ShopOutcome.unavailable);
      }
      return ShopBuyResult(
        _status == ShopStatus.offline
            ? ShopOutcome.offline
            : ShopOutcome.unavailable,
      );
    }
  }

  /// Wears [itemId], immediately and then on the server (SPEC §4.8).
  ///
  /// Returns whether the server stored it. It is applied locally either way — the
  /// player asked for it and owns it, and a look that waits for a round trip
  /// feels broken — and a choice the server has not heard yet is kept in
  /// [pendingEquip] and pushed by the next refresh. That is what makes switching
  /// between two owned looks work on a plane and survive the flight.
  ///
  /// An item the player does not own is refused here as well as by the server: a
  /// UI that offers it is a bug, and this is the assertion of that.
  Future<bool> equip(String itemId) async {
    final slot = CosmeticSlot.of(itemId);
    if (slot == null || !_snapshot.owns(itemId)) return false;
    if (_snapshot.equipped[slot] != itemId) {
      _snapshot = _snapshot.wearing(slot, itemId);
      await _save();
      if (slot == CosmeticSlot.theme) _applyTheme();
      notifyListeners();
    }
    final credentials = await identity.load();
    if (credentials == null) {
      await _rememberPending(slot, itemId);
      return false;
    }
    return _sendEquip(credentials, slot, itemId);
  }

  Future<bool> _sendEquip(
    PlayerCredentials credentials,
    String slot,
    String itemId,
  ) async {
    try {
      final equipped = await api.shopEquip(credentials, <String, String?>{
        slot: itemId,
      }, version: catalogueVersion);
      _snapshot = _snapshot.copyWith(equipped: equipped, knownAt: _now());
      if (_pending.remove(slot) != null) {
        await storage.setShopPendingEquip(_pending);
      }
      await _save();
      _applyTheme();
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      if (e.isOffline) {
        await _rememberPending(slot, itemId);
        _setStatus(ShopStatus.offline);
        return false;
      }
      // The server refused this choice (it says the item is not owned, or has
      // never heard of it). Pushing it again would only be refused again, so it
      // is dropped and the next refresh brings back what the server does hold.
      if (_pending.remove(slot) != null) {
        await storage.setShopPendingEquip(_pending);
      }
      if (e.isUnauthorized) await identity.forget();
      return false;
    }
  }

  /// What a finished run earned (SPEC §4.8), as the `201` from `POST /api/scores`
  /// reported it.
  ///
  /// The balance comes straight from that answer, so the game-over screen and the
  /// title screen agree without another request; the refresh that follows is for
  /// the day's allowance, which only the inventory endpoint carries — and which is
  /// the difference between "that run paid nothing" and "you have earned today's
  /// 200".
  Future<void> noteRun({int? tokens, int? balance}) async {
    if (balance != null) {
      _snapshot = _snapshot.copyWith(balance: balance, knownAt: _now());
      await _save();
      notifyListeners();
    }
    if (tokens == null) return;
    await refresh(force: true);
  }

  Future<void> _pushPending(PlayerCredentials credentials) async {
    if (_pending.isEmpty) return;
    final slots = <String, String>{..._pending};
    try {
      final equipped = await api.shopEquip(
        credentials,
        slots,
        version: catalogueVersion,
      );
      _snapshot = _snapshot.copyWith(equipped: equipped);
      _pending = <String, String>{};
      await storage.setShopPendingEquip(_pending);
    } on ApiException catch (e) {
      // Still no connection: keep them for the next attempt. A refusal of their
      // own (an item this player does not own after all) is final, so they are
      // dropped instead of being retried forever.
      if (e.isOffline) rethrow;
      _pending = <String, String>{};
      await storage.setShopPendingEquip(_pending);
    }
  }

  Future<void> _rememberPending(String slot, String itemId) async {
    _pending[slot] = itemId;
    await storage.setShopPendingEquip(_pending);
  }

  Future<void> _save() => storage.setShopCache(_snapshot.toJson());

  void _setStatus(ShopStatus status) {
    _status = status;
    notifyListeners();
  }
}
