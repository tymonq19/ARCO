import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/game_theme.dart';
import '../app/settings.dart';
import '../app/strings.dart';
import '../app/theme.dart';
import '../services/audio_service.dart';
import '../services/haptics.dart';
import '../services/shop_service.dart';
import 'home_screen.dart';
import 'widgets/neon_button.dart';
import 'widgets/neon_panel.dart';
import 'widgets/shop_card.dart';
import 'widgets/theme_preview.dart';

/// First launch: pick a look, type a nickname, start playing.
///
/// The look is chosen by *seeing* it, not by reading its name: tapping a card
/// dresses this whole screen in that theme — background, type, input field,
/// button — so the choice is made from the thing itself. Nothing is persisted
/// until the player continues; [Settings.completeOnboarding] then writes the
/// theme, the nickname and the flag that keeps this screen from coming back.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  static const String route = '/welcome';

  /// How long one look takes to dissolve into the next.
  ///
  /// Short enough to feel like a response to the tap rather than a wait, long
  /// enough that the eye reads it as a change of clothes and not a glitch.
  static const Duration transition = Duration(milliseconds: 320);

  /// Gap between the theme cards, horizontally and vertically.
  static const double cardGap = 12;

  /// Cards never grow past the size [ThemePreview] is designed for.
  static const double maxCardWidth = ThemePreview.defaultWidth;

  /// Card height as a multiple of its width.
  ///
  /// Shorter than [ThemePreview]'s own 150x220 proportion, and paired with a
  /// tighter [cardLabelHeight]: two rows of cards plus a wordmark, a nickname
  /// field and a button is a lot of screen, and everything here has to clear
  /// the fold on a phone. The ring is inscribed in the card's *width*, which
  /// none of this changes, so the illustration is unaffected.
  static const double cardHeightFactor = 1.2;

  /// Caption strip inside a card; tighter than [ThemePreview]'s default so the
  /// shorter card keeps a full-size ring.
  static const double cardLabelHeight = 28;

  /// Narrowest a card may get before four of them stop fitting in one row.
  static const double minRowCardWidth = 110;

  /// Width at which all four cards fit side by side.
  static const double oneRowWidth =
      GameThemes.themeCount * minRowCardWidth +
      (GameThemes.themeCount - 1) * cardGap;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _dissolve;
  late final TextEditingController _name;

  /// The look being previewed, i.e. the one this screen is dressed in.
  late GameTheme _theme;

  /// The look it is dissolving out of; equal to [_theme] once settled.
  late GameTheme _from;

  @override
  void initState() {
    super.initState();
    final settings = context.read<Settings>();
    _theme = settings.theme;
    _from = _theme;
    // The generated nickname is already in Settings, so the player can simply
    // continue; the field starts on it rather than empty.
    _name = TextEditingController(text: settings.playerName);
    _controller = AnimationController(
      vsync: this,
      duration: OnboardingScreen.transition,
      value: 1,
    );
    _dissolve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    // Once the dissolve is over the outgoing look has nothing left to show, so
    // the screen drops back to a single backdrop layer.
    _controller.addStatusListener((status) {
      if (status != AnimationStatus.completed || _from.id == _theme.id) return;
      setState(() => _from = _theme);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _name.dispose();
    super.dispose();
  }

  /// The nickname as the server would store it, or null while it is invalid.
  String? get _validName => normalizeName(_name.text);

  void _pick(GameTheme option) {
    if (option.id == _theme.id) return;
    context.read<AudioService>().play(Sfx.click);
    context.read<Haptics>().selection();
    setState(() {
      _from = _theme;
      _theme = option;
    });
    _controller
      ..value = 0
      ..forward();
  }

  void _continue() {
    final name = _validName;
    if (name == null) return;
    context.read<AudioService>().play(Sfx.click);
    // The normalized name, not the raw text: the server collapses repeated
    // spaces and trims, and the leaderboard must show what it stored.
    context.read<Settings>().completeOnboarding(theme: _theme, name: name);
    Navigator.of(context).pushReplacementNamed(HomeScreen.route);
  }

  /// A colour part-way between the outgoing and the incoming look.
  ///
  /// The two backdrops cross-fade as whole pictures, but the text and the
  /// button sit on top of both, so their colours are interpolated on the same
  /// timeline instead of snapping the moment a card is tapped.
  Color _blend(Color Function(GameTheme) pick) =>
      Color.lerp(pick(_from), pick(_theme), _dissolve.value)!;

  double _blendD(double Function(GameTheme) pick) =>
      lerpDouble(pick(_from), pick(_theme), _dissolve.value)!;

  @override
  Widget build(BuildContext context) {
    // The chooser paints in the look being previewed rather than the one the
    // app launched in: every widget below reads it through the same provider
    // the app shell uses, so this screen is a faithful dress rehearsal.
    // `AnimatedTheme` carries the Material side of the switch (the nickname
    // field's fill, border and label) across the same 320 ms.
    return Provider<GameTheme>.value(
      value: _theme,
      // The status bar has to follow the *pending* look, not the stored one.
      // Nothing is persisted while the player browses, so the annotation the
      // app shell posts still describes the look they arrived in — and a
      // player trying Modernist would watch the clock and the battery vanish
      // into the paper. This one sits deeper, so it wins while the screen is
      // up, and disappears with it.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemOverlayStyleFor(_theme),
        child: AnimatedTheme(
          data: buildAppTheme(_theme),
          duration: OnboardingScreen.transition,
          child: Builder(builder: _buildBody),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final s = Strings.of(context);
    final theme = _theme;
    // Which looks are the player's (SPEC 4.8). On a genuine first launch that is
    // the ones that cost nothing — the others are shown, locked, with a line
    // saying where they come from. Nothing is asked of the server here: a player
    // who has not played yet has no wallet, and inventing one at the welcome
    // screen would be a request nobody asked for.
    final shop = context.watch<ShopService>();
    return Scaffold(
      // The cross-fading backdrop below covers the scaffold, and the content
      // scrolls over it.
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(child: _backdrop()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final padding = theme.pad(
                  const EdgeInsets.fromLTRB(20, 8, 20, 16),
                );
                // Built once per selection, outside the per-frame builder
                // below: the cards are real arena paintings, so re-recording
                // four of them on every animation frame would be wasteful.
                final chooser = _chooser(
                  s,
                  shop,
                  constraints.maxWidth - padding.horizontal,
                );
                final anyLocked = GameThemes.all.any(
                  (option) => !_owns(shop, option),
                );
                return SingleChildScrollView(
                  padding: padding,
                  child: AnimatedBuilder(
                    animation: _dissolve,
                    builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _wordmark(s),
                        const SizedBox(height: 10),
                        Text(
                          s.t('onboarding.welcome'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _blend((t) => t.textDim),
                            fontSize: 14,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _label(s.t('onboarding.pickTheme')),
                        const SizedBox(height: 10),
                        chooser,
                        if (anyLocked) ...[
                          const SizedBox(height: 10),
                          Text(
                            s.t('onboarding.moreLooks'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _blend((t) => t.textDim),
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        _nameField(s),
                        const SizedBox(height: 14),
                        NeonButton(
                          label: s.t('onboarding.start'),
                          icon: Icons.play_arrow_rounded,
                          color: _blend((t) => t.accent),
                          onPressed: _validName == null ? null : _continue,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          s.t('onboarding.changeLater'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _blend((t) => t.textDim),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The two looks stacked, the incoming one painted over the outgoing one at
  /// the dissolve's opacity: picking a theme reads as a change of light rather
  /// than a cut. [NeonBackground] does the painting, so the gradient, the
  /// vignette and the CRT scanlines are each theme's real ones.
  Widget _backdrop() {
    final incoming = _themedBackdrop(_theme);
    if (_from.id == _theme.id) return incoming;
    return Stack(
      fit: StackFit.expand,
      children: [
        _themedBackdrop(_from),
        FadeTransition(opacity: _dissolve, child: incoming),
      ],
    );
  }

  Widget _themedBackdrop(GameTheme theme) => Provider<GameTheme>.value(
    value: theme,
    child: const NeonBackground(child: SizedBox.expand()),
  );

  /// ARCO, set as large as the width allows and never broken across lines.
  Widget _wordmark(Strings s) {
    final glow = _blendD((t) => t.glow);
    final halo = _blend((t) => t.accent);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        s.t('app.title'),
        textAlign: TextAlign.center,
        style: TextStyle(
          // Not [GlowText]: the halo and the ink are interpolated here so the
          // wordmark travels with the backdrop instead of snapping.
          color: _blend((t) => t.textPrimary),
          fontSize: 52,
          fontWeight: FontWeight.w900,
          letterSpacing: 13,
          shadows: glow > 0
              ? [
                  Shadow(
                    color: halo.withValues(alpha: 0.9 * glow),
                    blurRadius: 18,
                  ),
                  Shadow(
                    color: halo.withValues(alpha: 0.45 * glow),
                    blurRadius: 36,
                  ),
                ]
              : null,
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
    _theme.heading(text),
    style: TextStyle(
      color: _blend((t) => t.textDim),
      fontSize: 12,
      fontWeight: FontWeight.w800,
      letterSpacing: _theme.headingCase == HeadingCase.upper ? 2 : 0.4,
    ),
  );

  /// The four looks as illustrated cards, two by two.
  ///
  /// A two-by-two grid rather than a sideways-scrolling row, because this is
  /// the one screen whose whole job is choosing: all four options have to be on
  /// screen without a gesture nobody announced, and the page already scrolls
  /// vertically at large text scales, so a horizontal scroller nested inside it
  /// would compete with that. Where four cards genuinely fit side by side (a
  /// tablet, the web build, a phone in landscape) they are laid out in one
  /// centred row instead.
  Widget _chooser(Strings s, ShopService shop, double available) {
    const gap = OnboardingScreen.cardGap;
    final perRow = available >= OnboardingScreen.oneRowWidth
        ? GameThemes.themeCount
        : 2;
    final width = math.min(
      OnboardingScreen.maxCardWidth,
      (available - (perRow - 1) * gap) / perRow,
    );
    final height = width * OnboardingScreen.cardHeightFactor;
    return Column(
      children: [
        for (var i = 0; i < GameThemes.themeCount; i += perRow) ...[
          if (i > 0) const SizedBox(height: gap),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (
                var j = i;
                j < i + perRow && j < GameThemes.themeCount;
                j++
              ) ...[
                if (j > i) const SizedBox(width: gap),
                _card(s, shop, GameThemes.all[j], width, height),
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// Whether this look is the player's to wear. Free looks always are; a paid one
  /// is only ever owned because the **server** says so (SPEC 4.8).
  bool _owns(ShopService shop, GameTheme option) =>
      shop.snapshot.owns(ShopSnapshot.idOfTheme(option));

  Widget _card(
    Strings s,
    ShopService shop,
    GameTheme option,
    double width,
    double height,
  ) {
    final selected = option.id == _theme.id;
    final owned = _owns(shop, option);
    // A locked look is shown but not offered: there is nothing to buy with yet,
    // and a card that answers a tap with a dead end is worse than one that
    // plainly is not available. The line under the chooser says where they come
    // from.
    Widget card = ThemePreview(
      theme: option,
      width: width,
      height: height,
      label: s.t(option.nameKey),
      labelHeight: OnboardingScreen.cardLabelHeight,
      selected: selected && owned,
      onTap: owned ? () => _pick(option) : null,
    );
    if (!owned) {
      card = Stack(
        clipBehavior: Clip.none,
        children: [
          card,
          const Positioned(top: 5, left: 5, child: LockBadge(size: 20)),
        ],
      );
    }
    // The chosen card sits slightly forward of the other three, so the
    // selection reads even before the eye finds the ring and the check.
    return AnimatedScale(
      scale: selected ? 1.0 : 0.95,
      duration: OnboardingScreen.transition,
      curve: Curves.easeOut,
      child: card,
    );
  }

  Widget _nameField(Strings s) {
    final valid = _validName != null;
    return TextField(
      controller: _name,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {
        if (_validName != null) _continue();
      },
      textAlign: TextAlign.center,
      maxLength: nameMaxLength,
      textInputAction: TextInputAction.done,
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 2,
      ),
      decoration: InputDecoration(
        labelText: s.t('onboarding.nicknameLabel'),
        // The rule is on screen from the start and simply turns red when the
        // name breaks it: "Invalid nickname" on its own never tells anyone
        // what to type instead.
        helperText: s.t('home.nicknameHint'),
        helperMaxLines: 2,
        errorText: valid ? null : s.t('home.nicknameHint'),
        errorMaxLines: 2,
        counterText: '',
      ),
    );
  }
}
