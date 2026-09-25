/// The shop (SPEC §4.8, §4.9, §4.10): what can be worn, what it costs in sparks,
/// what the player already owns — plus the two shortcuts, a rewarded ad and the
/// one-time unlock real money buys, in that order under the earning panel.
///
/// **Everything in here is purely cosmetic.** Nothing sold on this screen changes
/// the simulation — not a paddle's width, not the ball's speed, not a life. The
/// server re-simulates every solo replay it is sent, so an item that touched the
/// game would make honest runs fail verification, and a leaderboard money can
/// climb is worth nothing. The confirmation dialog says so in as many words,
/// because a player deciding whether to spend has every right to know.
///
/// **The server decides everything.** Prices, the wallet and ownership all come
/// from `GET /api/shop/catalogue` and `GET /api/shop/inventory`; this screen is a
/// window on them. It shows what the server returned and never a figure of its
/// own — while the answer is missing it says so instead of guessing, and while it
/// is stale it says that too.
library;

import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/cosmetics.dart';
import '../app/game_theme.dart';
import '../app/settings.dart';
import '../app/strings.dart';
import '../services/account_service.dart';
import '../services/ads_gateway.dart';
import '../services/ads_service.dart';
import '../services/api_client.dart';
import '../services/audio_service.dart';
import '../services/native_sign_in.dart';
import '../services/player_identity.dart';
import '../services/purchase_service.dart';
import '../services/shop_service.dart';
import 'widgets/neon_button.dart';
import 'widgets/neon_panel.dart';
import 'widgets/shop_card.dart';
import 'widgets/spark_ad.dart';
import 'widgets/spark_balance.dart';
import 'widgets/unlock_card.dart';

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});

  static const String route = '/shop';

  /// Gap between cards, horizontally and vertically.
  static const double cardGap = 12;

  /// Cards never grow past the size the previews are designed for.
  static const double maxCardWidth = ShopCard.defaultWidth;

  /// Narrowest a card may get before a row of three stops being worth it.
  static const double minCardWidth = 132;

  /// Widest the content column ever gets: four cards at their drawn size plus
  /// the gaps between them, plus the horizontal padding.
  static const double maxContentWidth = 4 * maxCardWidth + 3 * cardGap + 32;

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> with WidgetsBindingObserver {
  /// A purchase or an equip is in flight: the grid stops taking taps, so a
  /// double tap cannot start two.
  bool _busy = false;

  /// Sign-ins this deployment accepts (SPEC §4.5), for the one-line hint about
  /// keeping purchases. Null until asked; empty means the feature is off and the
  /// hint would be a dead end.
  List<SignInProvider>? _providers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A payment can finish while the app is in the background — the sheet hands
  /// off to the App Store, Ask to Buy waits for a parent, a bank confirms an
  /// hour later. Coming back is therefore a moment to ask the server whether
  /// anything landed. It is cheap, it is silent when there is nothing, and it
  /// never adds anything locally (SPEC §4.9).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    unawaited(context.read<PurchaseService>().recheck());
    // An ad is a full-screen takeover, so coming back from one lands here too:
    // the allowance has moved, the cooldown has started, and there is a new ad to
    // preload. Silent, and it credits nothing (SPEC §4.10).
    unawaited(context.read<AdsService>().refresh());
  }

  Future<void> _load() async {
    if (!mounted) return;
    // Opening the shop is a player asking for something that needs a wallet, so
    // this is the one call allowed to *issue* the anonymous identity of SPEC §4.4
    // — which is also why the shop works without any sign-in at all.
    await context.read<ShopService>().refresh(issue: true, force: true);
    if (!mounted) return;
    // The unlock comes from that answer, so the store is asked for its price only
    // once the server has said whether there is a product to price (SPEC §4.9).
    unawaited(context.read<PurchaseService>().refresh());
    // And the ad allowance (SPEC §4.10): the server says whether an ad would pay,
    // and only then is one preloaded — so a player at the day's cap costs nobody
    // an ad request, and the button is instant when it does appear.
    unawaited(context.read<AdsService>().refresh());
    context.read<PlayerIdentity>().refreshProfile();
    final providers = await context.read<AccountService>().providers();
    if (!mounted) return;
    setState(() => _providers = providers);
  }

  ShopService get _shop => context.read<ShopService>();

  /// Puts an owned item on. The look changes under the player's hands, which is
  /// the point.
  Future<void> _wear(String itemId) async {
    final s = Strings.read(context);
    context.read<AudioService>().play(Sfx.click);
    setState(() => _busy = true);
    final stored = await _shop.equip(itemId);
    if (!mounted) return;
    setState(() => _busy = false);
    // It is on either way; what failed is telling the server. Saying so beats
    // pretending the choice did not stick — or pretending it reached the account.
    if (!stored && _shop.pendingEquip.isNotEmpty) {
      _say(s.t('shop.equipPending'));
    }
  }

  /// Confirms, buys, and reports what the **server** said (SPEC §4.8).
  ///
  /// The order matters: nothing is charged before the player has seen the price
  /// and said yes, and the sentence afterwards carries the balance the server
  /// reported rather than one worked out here.
  Future<void> _buy(ShopItem item, String label) async {
    final s = Strings.read(context);
    final shop = _shop;
    final snapshot = shop.snapshot;
    final affordable = snapshot.canAfford(item);
    final confirmed = await showShopBuyDialog(
      context,
      label: label,
      priceTokens: item.priceTokens,
      balance: snapshot.balance,
      balanceKnown: snapshot.known,
      // Two of the server's own numbers compared, never a wallet computed here.
      // The server refuses the purchase anyway if this turns out to be wrong,
      // and its refusal is what the player is then shown. A wallet nobody has
      // read is not a wallet that is short: then the offer stands and the server
      // decides.
      missing: snapshot.known && !affordable
          ? item.priceTokens - snapshot.balance
          : 0,
    );
    if (confirmed != true || !mounted) return;
    context.read<AudioService>().play(Sfx.click);
    setState(() => _busy = true);
    final result = await shop.buy(item.id);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result.outcome) {
      case ShopOutcome.bought:
        context.read<AudioService>().play(Sfx.star);
        _say(
          s.f('shop.bought', {
            'item': label,
            'balance': s.sparks(shop.balance),
          }),
        );
      case ShopOutcome.insufficient:
        _say(s.f('shop.insufficient', {'missing': s.sparks(result.missing)}));
      case ShopOutcome.offline:
        _say(s.t('shop.buyOffline'));
      case ShopOutcome.unavailable:
      case ShopOutcome.unknownItem:
        _say(s.t('shop.buyFailed'));
    }
  }

  /// Buys the one-time unlock and reports what the **server** then held
  /// (SPEC §4.9).
  ///
  /// Nothing is unlocked on this phone at any point. The store takes the money;
  /// our server grants the entitlement on RevenueCat's verified webhook; this asks
  /// the server and repeats its answer. When the server has not granted it yet,
  /// the message says so plainly instead of showing a state nobody has confirmed.
  Future<void> _buyUnlock(UnlockOffer offer) async {
    final s = Strings.read(context);
    final purchases = context.read<PurchaseService>();
    context.read<AudioService>().play(Sfx.click);
    setState(() => _busy = true);
    final report = await purchases.buy(offer.productId);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (report.kind) {
      case PurchaseReportKind.unlocked:
        context.read<AudioService>().play(Sfx.star);
        _say(s.t('shop.unlockDone'));
      case PurchaseReportKind.awaitingServer:
        _say(s.t('shop.unlockWaiting'));
      case PurchaseReportKind.pending:
        _say(s.t('shop.unlockPending'));
      case PurchaseReportKind.cancelled:
        // Silence. A player who changed their mind does not need telling.
        break;
      case PurchaseReportKind.notAllowed:
        _say(s.t('shop.unlockNotAllowed'));
      case PurchaseReportKind.storeUnavailable:
        _say(s.t('shop.unlockStoreDown'));
      case PurchaseReportKind.offline:
        _say(s.t('shop.unlockOffline'));
      case PurchaseReportKind.failed:
        _say(s.t('shop.unlockFailed'));
    }
  }

  /// Restore purchases (SPEC §4.9).
  ///
  /// A real action, not an apology: the unlock is a **non-consumable**, so the
  /// store keeps a record of it for the account that paid and a reinstall or a
  /// second device genuinely recovers it. What is reported is what the **server**
  /// says afterwards — unlocked, nothing found on this store account, or "we could
  /// not ask" — and those are three different sentences on purpose.
  Future<void> _restore() async {
    final s = Strings.read(context);
    final purchases = context.read<PurchaseService>();
    context.read<AudioService>().play(Sfx.click);
    setState(() => _busy = true);
    final report = await purchases.restore();
    if (!mounted) return;
    setState(() => _busy = false);
    if (report.failed) {
      _say(s.t('shop.restoreFailed'));
      return;
    }
    if (report.foundSomething) {
      context.read<AudioService>().play(Sfx.star);
      _say(s.t('shop.restoreDone'));
      return;
    }
    _say(s.t('shop.restoreNothing'));
  }

  /// Watches a rewarded ad for Sparks (SPEC §4.10).
  ///
  /// **This adds nothing.** The reward is credited by our server when Google's
  /// signed server-side verification callback arrives; this shows the ad, then asks
  /// the server and repeats its answer. When the server has not credited it yet the
  /// message says so plainly instead of showing a figure nobody has confirmed.
  ///
  /// It is also where the consent form appears, if the player has not chosen yet:
  /// the moment they asked for the thing consent is needed for.
  Future<void> _watchAd() async {
    final s = Strings.read(context);
    final ads = context.read<AdsService>();
    context.read<AudioService>().play(Sfx.click);
    setState(() => _busy = true);
    final report = await ads.watch(AdPlacementId.shop);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (report.kind) {
      case AdReportKind.credited:
        context.read<AudioService>().play(Sfx.star);
        _say(
          s.f('ads.credited', {
            'sparks': s.sparks(report.sparks),
            'balance': s.sparks(
              report.balance ?? context.read<ShopService>().balance,
            ),
          }),
        );
      case AdReportKind.awaitingServer:
        _say(s.t('ads.waiting'));
      case AdReportKind.dismissed:
      case AdReportKind.consentRefused:
        // Silence. A player who closed the ad, or who said no to data, has said
        // their piece — and the game is exactly the same either way.
        break;
      case AdReportKind.unavailable:
        _say(s.t('ads.noAd'));
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final shop = context.watch<ShopService>();
    final snapshot = shop.snapshot;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('shop.title')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: const SparkBalance()),
          ),
        ],
      ),
      body: NeonBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const padding = EdgeInsets.fromLTRB(16, 4, 16, 48);
              // The content is centred inside a readable column rather than
              // stretched: four cards at their drawn size plus their gaps is
              // as wide as this screen ever needs to be.
              final width = math.min(
                constraints.maxWidth,
                ShopScreen.maxContentWidth,
              );
              final available = width - padding.horizontal;
              return _centred(
                width,
                ListView(
                  padding: padding,
                  // The whole screen is three sections of cards and one panel,
                  // and every card is a real arena painting: keeping them laid
                  // out while the player scrolls costs a little memory and
                  // saves re-recording twelve pictures, exactly as the Settings
                  // list does with its four theme previews.
                  cacheExtent: 1400,
                  children: _body(s, theme, shop, snapshot, available),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _body(
    Strings s,
    GameTheme theme,
    ShopService shop,
    ShopSnapshot snapshot,
    double available,
  ) {
    if (!snapshot.hasCatalogue) {
      return [const SizedBox(height: 24), _unreachable(s, theme, shop)];
    }
    final cardWidth = _cardWidth(available);
    return [
      // The catalogue on screen is the last one the server sent. When the newest
      // attempt failed, that is worth a line — the prices are still real, but
      // nothing here has just been confirmed.
      if (shop.failed) ...[
        const SizedBox(height: 8),
        _staleNotice(s, theme, shop),
      ],
      for (final slot in snapshot.slots) ...[
        SectionLabel(s.t('shop.section.$slot')),
        _grid(s, snapshot, slot, cardWidth),
        const SizedBox(height: 18),
      ],
      // The day's earning allowance — and **only** for a player who still has
      // something to spend it on. Once the unlock is bought, a progress bar
      // towards items they already own is a bar measuring nothing (SPEC §4.9).
      // The wallet itself is untouched: the server keeps crediting every run.
      if (snapshot.showsBalance) _earning(s, theme, snapshot),
      // Directly under the earning panel, above the unlock. The order is the
      // argument twice over: Sparks come from playing; an ad costs half a minute of
      // attention; the unlock costs money. Renders nothing at all when this
      // deployment credits no ads, this build has no AdMob unit, no ad is in hand,
      // or the player bought the unlock — which buys no ads (SPEC §4.10).
      SparkAdSection(onWatch: _watchAd),
      // Below the earning panel, always. The order is the argument: everything the
      // unlock covers is earnable by playing, and the unlock is the shortcut for
      // anyone who would rather not wait (SPEC §4.9). Renders nothing at all when
      // this deployment takes no money or this build has no store keys — and
      // becomes a quiet confirmation once it is owned.
      UnlockSection(onBuy: _buyUnlock, onRestore: _restore),
      if (_missingContent(snapshot) > 0) ...[
        const SizedBox(height: 12),
        Text(
          s.t('shop.updateApp'),
          style: TextStyle(color: theme.textDim, fontSize: 12),
        ),
      ],
      if (_shouldOfferAccount(context.watch<PlayerIdentity>().profile)) ...[
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, size: 15, color: theme.textDim),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                s.t('shop.accountHint'),
                style: TextStyle(color: theme.textDim, fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    ];
  }

  /// One section's cards, wrapped so they reflow instead of overflowing when the
  /// text scale or the phone makes them wider.
  /// Keeps [child] in a column of [width], centred, when the screen is wider.
  Widget _centred(double width, Widget child) => Center(
    child: SizedBox(width: width, child: child),
  );

  Widget _grid(
    Strings s,
    ShopSnapshot snapshot,
    String slot,
    double cardWidth,
  ) {
    return Wrap(
      // Cards are capped at `maxCardWidth`, so a row rarely fills the width
      // exactly. Left-aligned, every leftover pixel piled up on the right and
      // the whole shop looked pinned to the left edge.
      alignment: WrapAlignment.center,
      spacing: ShopScreen.cardGap,
      runSpacing: 16,
      children: [
        for (final item in snapshot.itemsOf(slot))
          if (_canShow(item))
            ShopCard(
              itemId: item.id,
              label: s.item(item.nameKey),
              state: _stateOf(snapshot, item),
              priceTokens: item.priceTokens,
              width: cardWidth,
              onTap: _busy
                  ? null
                  : () => _tap(snapshot, item, s.item(item.nameKey)),
            ),
      ],
    );
  }

  void _tap(ShopSnapshot snapshot, ShopItem item, String label) {
    if (snapshot.isEquipped(item.id)) return;
    if (snapshot.owns(item.id) || item.owned) {
      _wear(item.id);
      return;
    }
    _buy(item, label);
  }

  ShopCardState _stateOf(ShopSnapshot snapshot, ShopItem item) {
    if (snapshot.isEquipped(item.id)) return ShopCardState.worn;
    if (snapshot.owns(item.id) || item.owned) return ShopCardState.owned;
    return snapshot.canAfford(item)
        ? ShopCardState.affordable
        : ShopCardState.unaffordable;
  }

  /// Whether this build can draw [item] at all. A newer server can hold a ball
  /// this version has never heard of; selling it would mean selling a card that
  /// comes out as the default, so it is left out and counted instead.
  bool _canShow(ShopItem item) =>
      GameThemes.byItemId(item.id) != null || canRenderItem(item.id);

  int _missingContent(ShopSnapshot snapshot) =>
      snapshot.items.where((item) => !_canShow(item)).length;

  /// Whether to say, once and without a button, that signing in keeps what was
  /// bought.
  ///
  /// Only when this deployment actually accepts a sign-in (SPEC §4.5) and this
  /// player has not used one: an offer that cannot be taken is worse than
  /// silence. Watched rather than read, so the line appears when the standing
  /// arrives instead of on the next rebuild.
  bool _shouldOfferAccount(PlayerProfile? profile) {
    final providers = _providers;
    if (providers == null || providers.isEmpty) return false;
    return profile != null && !profile.hasAccount;
  }

  /// Two cards on a phone, three or four where they genuinely fit (a tablet, the
  /// web build, landscape) — and never wider than the previews are drawn for.
  double _cardWidth(double available) {
    const gap = ShopScreen.cardGap;
    var perRow = 2;
    for (var next = 3; next <= 4; next++) {
      final width = (available - (next - 1) * gap) / next;
      if (width < ShopScreen.minCardWidth) break;
      perRow = next;
    }
    final width = (available - (perRow - 1) * gap) / perRow;
    return width.clamp(48.0, ShopScreen.maxCardWidth);
  }

  /// What the day has paid and what it can still pay (SPEC §4.8) — both the
  /// server's numbers.
  ///
  /// The cap is said plainly rather than left as a silent zero on a good run: a
  /// player who has earned the day's allowance is owed the sentence.
  Widget _earning(Strings s, GameTheme theme, ShopSnapshot snapshot) {
    final capped = snapshot.dailyCapReached;
    final progress = snapshot.dailyCap <= 0
        ? 0.0
        : (snapshot.earnedToday / snapshot.dailyCap).clamp(0.0, 1.0);
    return NeonPanel(
      color: theme.star,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                theme.heading(s.t('shop.earnTitle')),
                style: TextStyle(
                  color: theme.textDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: theme.headingCase == HeadingCase.upper
                      ? 1.5
                      : 0,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SparkIcon(size: 15, color: theme.star),
                  const SizedBox(width: 4),
                  Text(
                    s.f('shop.earnedToday', {
                      'earned': snapshot.earnedToday,
                      'cap': snapshot.dailyCap,
                    }),
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (snapshot.dailyCap > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: theme.surfaceHigh,
                color: capped ? theme.success : theme.star,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            capped
                ? s.f('shop.capReached', {'cap': s.sparks(snapshot.dailyCap)})
                : s.t('shop.earnHint'),
            style: TextStyle(color: theme.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// Nothing to show at all: the shop has never been read on this device and the
  /// server cannot be reached now. The game is unaffected, and says so.
  Widget _unreachable(Strings s, GameTheme theme, ShopService shop) {
    if (shop.loading || shop.status == ShopStatus.idle) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return NeonPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            shop.status == ShopStatus.offline
                ? Icons.wifi_off
                : Icons.cloud_off,
            color: theme.textDim,
            size: 28,
          ),
          const SizedBox(height: 12),
          Text(
            shop.status == ShopStatus.offline
                ? s.t('shop.offline')
                : s.t('shop.unavailable'),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.textDim, fontSize: 13),
          ),
          const SizedBox(height: 16),
          NeonButton(
            label: s.t('common.retry'),
            height: 48,
            fontSize: 13,
            onPressed: shop.loading ? null : _load,
          ),
        ],
      ),
    );
  }

  /// The prices are real but were not confirmed just now.
  Widget _staleNotice(Strings s, GameTheme theme, ShopService shop) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          shop.status == ShopStatus.offline ? Icons.wifi_off : Icons.cloud_off,
          size: 15,
          color: theme.textDim,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            shop.status == ShopStatus.offline
                ? s.t('shop.offline')
                : s.t('shop.unavailable'),
            style: TextStyle(color: theme.textDim, fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        NeonIconButton(
          icon: Icons.refresh,
          tooltip: s.t('common.retry'),
          color: theme.textDim,
          onPressed: _load,
        ),
      ],
    );
  }
}

/// Asks before spending (SPEC §4.8), and says what is being spent on.
///
/// Returns true when the player confirmed. For an item the wallet does not cover
/// there is nothing to confirm: the dialog says how much is missing and offers
/// only a way out — the figure is the difference between two of the server's own
/// numbers, and the server refuses the purchase in any case if this app has them
/// wrong.
Future<bool?> showShopBuyDialog(
  BuildContext context, {
  required String label,
  required int priceTokens,
  required int balance,
  required bool balanceKnown,
  required int missing,
}) {
  final s = Strings.read(context);
  final theme = GameTheme.read(context);
  final settings = context.read<Settings>();
  final short = missing > 0;
  return showDialog<bool>(
    context: context,
    builder: (context) => Provider<GameTheme>.value(
      value: theme,
      child: ChangeNotifierProvider<Settings>.value(
        value: settings,
        child: AlertDialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          contentPadding: EdgeInsets.zero,
          content: NeonPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  s.f('shop.buyTitle', {'item': label}),
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  short
                      ? s.f('shop.insufficient', {'missing': s.sparks(missing)})
                      : s.f('shop.buyBody', {
                          'price': s.sparks(priceTokens),
                          'balance': balanceKnown
                              ? s.sparks(balance)
                              : s.t('shop.balanceUnknown'),
                        }),
                  style: TextStyle(
                    color: theme.textDim,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 18),
                if (short)
                  NeonButton(
                    label: s.t('common.ok'),
                    height: 48,
                    fontSize: 13,
                    onPressed: () => Navigator.of(context).pop(false),
                  )
                else ...[
                  NeonButton(
                    label: s.t('shop.buy'),
                    height: 50,
                    fontSize: 14,
                    icon: Icons.auto_awesome,
                    color: theme.star,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                  const SizedBox(height: 10),
                  NeonButton(
                    label: s.t('common.cancel'),
                    height: 46,
                    fontSize: 13,
                    filled: false,
                    color: theme.textDim,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
