/// The catalogue (SPEC §4.8, §4.9): what can be owned, what it costs, and which
/// client versions may see it.
///
/// Two tables live here. [Catalogue] holds the cosmetics, priced in Sparks earned
/// by playing; [FullUnlock] holds the single one-time store product that unlocks
/// **all** of them (SPEC §4.9), keyed by the product identifier Apple, Google and
/// RevenueCat all use.
///
/// **Everything here is purely cosmetic.** Not one field of an item or of the
/// unlock reaches `arco_core`, and nothing either of them does can change a
/// paddle's width, a ball's speed or a number of lives. Two reasons, both fatal
/// if ignored: this server re-simulates every submitted replay to verify it
/// (SPEC §4), so an item that changed the simulation would make *honest* runs
/// fail verification; and a leaderboard where money buys rank is worth nothing.
/// The catalogue is therefore a table of ids and amounts, deliberately holding no
/// numbers the simulation could read.
///
/// The tables are served from `GET /api/shop/catalogue` rather than shipped in
/// the app, so a Spark price is changed by deploying the server and no build of
/// the client ever hardcodes one — and the unlock carries **no** price at all,
/// because the only honest price is the localised one the device's own store
/// reports.
library;

/// The kinds of thing a player can own. A kind is a slot: exactly one item of
/// each kind is equipped at a time (see `player_equipped`, SPEC §4.8).
enum CosmeticKind {
  /// A whole look — palette plus style flags — as `lib/app/game_theme.dart`
  /// already defines them.
  theme,

  /// How the ball and its wake are drawn.
  ball,

  /// How the player's paddle arc is drawn.
  paddle;

  /// Parses the wire name; null for anything that is not a kind of this build.
  static CosmeticKind? parse(String? raw) {
    for (final kind in values) {
      if (kind.name == raw) return kind;
    }
    return null;
  }
}

/// One entry of the catalogue.
///
/// [id] is the stable identity used everywhere: in `player_items`, in
/// `player_equipped`, in a buy request, and as the asset name the client
/// resolves. It is prefixed with its kind (`theme.`, `ball.`, `paddle.`) so a
/// log line or a database row says what it is without a lookup.
class CatalogueItem {
  const CatalogueItem({
    required this.id,
    required this.kind,
    required this.priceTokens,
    this.sinceVersion = 1,
    String? nameKey,
  }) : _nameKey = nameKey;

  final String id;
  final CosmeticKind kind;

  /// Price in tokens; 0 means free (see [free]). Never read from a request —
  /// the client cannot send a price, only an item id (SPEC §4.8).
  final int priceTokens;

  /// First catalogue version that contains this item ([Catalogue.version]).
  ///
  /// A client asks for the version it understands and is served nothing newer,
  /// so adding a kind cannot confuse a build that shipped before it existed.
  final int sinceVersion;

  final String? _nameKey;

  /// `Strings` key of the display name, e.g. `theme.neon`.
  ///
  /// Defaults to [id], which is why the theme ids are exactly the keys
  /// `lib/app/strings.dart` already carries: the client needs no mapping table,
  /// and a name is translated in the app rather than shipped from the server in
  /// one language.
  String get nameKey => _nameKey ?? id;

  /// Whether the item costs nothing, and is therefore owned by every player
  /// without a row in `player_items` (SPEC §4.8).
  ///
  /// Derived from [priceTokens] rather than stored beside it: a flag that can
  /// disagree with the price is a bug waiting to be shipped.
  bool get free => priceTokens == 0;

  /// The item as the catalogue endpoint reports it. [owned] is the only
  /// per-player field; everything else is the same for everybody.
  Map<String, dynamic> toJson({required bool owned}) => {
    'id': id,
    'kind': kind.name,
    'priceTokens': priceTokens,
    'free': free,
    'nameKey': nameKey,
    'owned': owned,
  };
}

/// The seeded catalogue (SPEC §4.8).
///
/// Prices are in tokens earned from play (see `tokens.dart` for the rate and
/// the reasoning): 80 is about an evening, 250 about a week of ordinary play.
/// Themes cost most because a theme repaints the whole game; a ball or a paddle
/// is one shape.
abstract final class Catalogue {
  /// Current catalogue version.
  ///
  /// Bumped whenever a **kind** is added, i.e. whenever an older client would
  /// be handed an item it has no way to draw. Adding another item of a kind
  /// that already exists does not bump it: every client already knows how to
  /// draw balls, so a new ball is content, not a format change.
  static const int version = 1;

  /// Every item, in the order a shop screen should show them: by kind, and
  /// within a kind cheapest first, free ones leading.
  static const List<CatalogueItem> items = <CatalogueItem>[
    // The four looks `lib/app/game_theme.dart` already defines. Neon and
    // Classic are free, so a player who never spends a token still has a
    // choice — a shop whose free tier is a single default reads as a demo.
    CatalogueItem(id: 'theme.neon', kind: CosmeticKind.theme, priceTokens: 0),
    CatalogueItem(
      id: 'theme.classic',
      kind: CosmeticKind.theme,
      priceTokens: 0,
    ),
    CatalogueItem(
      id: 'theme.modernist',
      kind: CosmeticKind.theme,
      priceTokens: 150,
    ),
    CatalogueItem(
      id: 'theme.glass',
      kind: CosmeticKind.theme,
      priceTokens: 250,
    ),
    // Balls. `ball.orb` is what the game draws today, so it is free and is the
    // default every player starts equipped with.
    CatalogueItem(id: 'ball.orb', kind: CosmeticKind.ball, priceTokens: 0),
    CatalogueItem(id: 'ball.comet', kind: CosmeticKind.ball, priceTokens: 80),
    CatalogueItem(id: 'ball.prism', kind: CosmeticKind.ball, priceTokens: 120),
    CatalogueItem(id: 'ball.ember', kind: CosmeticKind.ball, priceTokens: 180),
    // Paddles. `paddle.arc` is the plain arc the renderer draws today.
    CatalogueItem(id: 'paddle.arc', kind: CosmeticKind.paddle, priceTokens: 0),
    CatalogueItem(
      id: 'paddle.blade',
      kind: CosmeticKind.paddle,
      priceTokens: 80,
    ),
    CatalogueItem(
      id: 'paddle.halo',
      kind: CosmeticKind.paddle,
      priceTokens: 120,
    ),
    CatalogueItem(
      id: 'paddle.chevron',
      kind: CosmeticKind.paddle,
      priceTokens: 180,
    ),
  ];

  static final Map<String, CatalogueItem> _byId = <String, CatalogueItem>{
    for (final item in items) item.id: item,
  };

  /// The item with [id], or null when this build has no such item — which is
  /// what every unknown id in a request is (SPEC §4.8).
  static CatalogueItem? byId(String? id) => id == null ? null : _byId[id];

  /// Whether [id] is an item nobody has to buy. False for an unknown id.
  static bool isFree(String id) => _byId[id]?.free ?? false;

  /// Every item a client that understands catalogue version [clientVersion] may
  /// be shown.
  static List<CatalogueItem> upTo(int clientVersion) => <CatalogueItem>[
    for (final item in items)
      if (item.sinceVersion <= clientVersion) item,
  ];

  /// The kinds present in version [clientVersion], in slot order.
  static List<CosmeticKind> kindsUpTo(int clientVersion) => <CosmeticKind>[
    for (final kind in CosmeticKind.values)
      if (items.any(
        (item) => item.kind == kind && item.sinceVersion <= clientVersion,
      ))
        kind,
  ];

  /// What a player has equipped in [kind] before they ever choose: the first
  /// free item of that kind.
  ///
  /// It exists so that a player with no stored preference — which is every
  /// player on their first launch — still gets a complete, valid answer from
  /// the inventory endpoint, and so that adding a kind needs no backfill.
  static CatalogueItem defaultFor(CosmeticKind kind) =>
      items.firstWhere((item) => item.kind == kind && item.free);

  /// Number of items of [kind].
  static int countOf(CosmeticKind kind) =>
      items.where((item) => item.kind == kind).length;
}

/// The one thing real money buys: a **single, non-consumable store product**
/// that unlocks everything, forever (SPEC §4.9).
///
/// This is the only product in the whole app, and its being *one* is the product
/// decision. There is no ladder of tiers, no subscription, no Spark pack and
/// nothing that only makes sense next to a struck-through price. A player either
/// pays once or never pays, and the player who never pays can still earn every
/// cosmetic by playing (SPEC §4.8) — slowly, which is the honest difference
/// between the two paths and the only difference there is.
///
/// **What it grants** is **premium**: every cosmetic in the catalogue, including
/// every cosmetic added to it later, and no ads ever offered. It is answered as
/// *ownership* rather than written out as a row per item — see `Db.isPremium` —
/// so a new item is included the moment it is added to [Catalogue.items] and
/// nothing has to be backfilled for anybody.
///
/// **Why non-consumable matters.** A consumable is delivered once and gone; it
/// cannot be restored, only re-bought, which is why "Restore purchases" used to
/// be an apology. A non-consumable is a permanent entitlement the stores
/// themselves remember, so a reinstall, a second device or a new phone genuinely
/// recovers it — `POST /api/purchases/sync` asks RevenueCat what this app user
/// owns and grants from that answer.
///
/// **There is no price here, and there must never be one.** The price is the
/// store's: set per market in App Store Connect and the Play Console, and shown
/// to the player from the device's own StoreKit / Billing response — localised,
/// tax-inclusive, and correct in markets nobody on the team has thought about. A
/// price in this file would be wrong in most of them, illegal in several, and
/// stale the moment somebody edited a tier. What the server owns is the other
/// half of the deal: *what the purchase grants*, which is not a number at all.
///
/// The iron rule is untouched. What money buys is **cosmetics** — the same ones
/// Sparks buy — so nothing here reaches `arco_core`, nothing it does can change a
/// paddle's width or a ball's speed, and no leaderboard position can be bought.
class UnlockProduct {
  const UnlockProduct({
    required this.productId,
    this.sinceVersion = 1,
    String? nameKey,
  }) : _nameKey = nameKey;

  /// The store product identifier, the same string in App Store Connect, in the
  /// Play Console and in RevenueCat. It is the key everywhere: a webhook names
  /// it, a `StoreProduct` on the phone carries it, and a purchase of it is what
  /// this server turns into premium.
  ///
  /// Lowercase letters, digits and dots only — the intersection of what both
  /// stores accept, so one id serves both.
  final String productId;

  /// First catalogue version that contains this product ([Catalogue.version]).
  final int sinceVersion;

  final String? _nameKey;

  /// `Strings` key of the display name, e.g. `unlock.full`.
  String get nameKey => _nameKey ?? productId;

  /// The product as `GET /api/shop/catalogue` reports it: the id to ask the
  /// store for, and the key to name it by. **No price** — see the class comment.
  Map<String, dynamic> toJson() => {'productId': productId, 'nameKey': nameKey};
}

/// The one-time unlock this build sells (SPEC §4.9).
///
/// Selling it needs more than this table: the same product identifier has to
/// exist in App Store Connect, in the Play Console and in RevenueCat — as a
/// **non-consumable** in both stores, attached to the [premiumEntitlement]
/// entitlement in RevenueCat — or the store simply reports it as unavailable.
/// A webhook naming a product this file does not hold is **refused**, never
/// granted at a guess.
abstract final class FullUnlock {
  /// The store product identifier. Prefixed `arco.unlock.` rather than
  /// `arco.sparks.`, because what is bought is the unlock and not a quantity of
  /// anything; the old Spark packs are gone and this identifier deliberately
  /// does not reuse one of theirs.
  static const String productId = 'arco.unlock.full';

  /// The RevenueCat **entitlement** the product is attached to.
  ///
  /// RevenueCat entitlements exist for exactly this shape of product: a
  /// permanent thing a customer either has or has not. The server never treats
  /// the entitlement as authority for a grant — a grant is keyed on the store's
  /// transaction id, which an entitlement does not carry — but it reads it on
  /// the sync path so that a store record and our ledger disagreeing is visible
  /// in a log line rather than silent (see `purchases.dart`).
  static const String premiumEntitlement = 'premium';

  static const UnlockProduct product = UnlockProduct(
    productId: productId,
    nameKey: 'unlock.full',
  );

  /// Whether [candidate] is the unlock product. False for null, for a cosmetic
  /// item id, and for any product this build does not sell — including one that
  /// exists in a store but not here.
  static bool isUnlock(String? candidate) => candidate == productId;

  /// The product as a client that understands catalogue version [clientVersion]
  /// may be shown it, or null when that version predates it.
  static UnlockProduct? upTo(int clientVersion) =>
      product.sinceVersion <= clientVersion ? product : null;
}
