import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// The four looks the player can pick from. The name is persisted, so these
/// identifiers must stay stable.
enum ThemeId { neon, classic, modernist, glass }

/// How the ball's wake is drawn.
enum TrailStyle {
  /// Additive circles that grow toward the ball: a glowing comet.
  comet,

  /// Flat, evenly spaced dots with no blending.
  dots,

  /// No wake at all.
  none,
}

/// Stroke ends and corner treatment for arena geometry.
enum ShapeStyle { rounded, sharp }

/// Whether headings shout or are set in normal case.
enum HeadingCase { upper, normal }

/// A complete look: the palette the arena renderer and the UI share, plus the
/// style flags that make the four themes read as different designs rather than
/// recolours.
///
/// Purely visual — it never reaches `arco_core`, so switching themes cannot
/// change gameplay. Every instance is a compile-time constant (see
/// [GameThemes]), which is what lets [GameTheme.of] compare by identity and
/// repaint the whole app the moment the setting changes.
@immutable
class GameTheme {
  const GameTheme({
    required this.id,
    required this.nameKey,
    required this.brightness,
    required this.background,
    required this.backgroundGradient,
    required this.backgroundStops,
    required this.arenaFill,
    required this.ring,
    required this.ownPaddle,
    required this.opponentPaddle,
    required this.ball,
    required this.ballCore,
    required this.trail,
    required this.heart,
    required this.star,
    required this.wall,
    required this.particle,
    required this.highlight,
    required this.textPrimary,
    required this.textDim,
    required this.panelFill,
    required this.panelBorder,
    required this.surfaceHigh,
    required this.outline,
    required this.danger,
    required this.success,
    required this.accent,
    required this.accentSolo,
    required this.accentDuel,
    required this.accentLeaderboard,
    required this.accentSettings,
    required this.glow,
    required this.trailStyle,
    required this.shapeStyle,
    required this.ringWidth,
    required this.highlightOpacity,
    required this.translucentPanels,
    required this.panelOpacity,
    required this.panelBlur,
    required this.panelBorderOpacity,
    required this.specularEdge,
    required this.squircle,
    required this.cornerRadius,
    required this.scanlines,
    required this.vignette,
    required this.spacing,
    required this.headingCase,
    this.fontFamily,
    this.fontFamilyFallback,
  });

  /// Stable identifier; `id.name` is what [Storage] persists.
  final ThemeId id;

  /// `Strings` key of the display name, e.g. `theme.neon`.
  final String nameKey;

  /// Drives `ColorScheme.brightness`, i.e. Material's own defaults.
  final Brightness brightness;

  // ------------------------------------------------------------------ arena

  /// Solid page colour; also the base of [backgroundGradient].
  final Color background;

  /// Radial gradient painted behind the arena and behind every menu screen.
  final List<Color> backgroundGradient;

  /// Stops of [backgroundGradient]; same length as the colour list.
  final List<double> backgroundStops;

  /// Tint of the arena disc (usually translucent).
  final Color arenaFill;

  /// The arena ring.
  final Color ring;

  // --------------------------------------------------------------- entities

  final Color ownPaddle;
  final Color opponentPaddle;

  /// Ball body.
  final Color ball;

  /// Smaller circle drawn inside the ball; carries its own alpha.
  final Color ballCore;

  /// Ball wake, drawn according to [trailStyle].
  final Color trail;

  final Color heart;
  final Color star;
  final Color wall;

  /// Generic spark colour for effects that have no entity colour of their own.
  final Color particle;

  /// Specular / core colour for paddle and wall inner lines, faded by
  /// [highlightOpacity].
  final Color highlight;

  // ------------------------------------------------------------ text, chrome

  /// HUD and body text.
  final Color textPrimary;

  /// Secondary text: labels, hints, disabled states.
  final Color textDim;

  final Color panelFill;

  /// Panel edge; widgets fade it with [panelBorderOpacity].
  final Color panelBorder;

  /// Raised fill: inactive slider tracks, switch tracks, dividers.
  final Color surfaceHigh;

  /// Outline of unselected controls; kept above the WCAG 1.4.11 3:1 floor.
  final Color outline;

  final Color danger;
  final Color success;

  /// Primary interactive colour (sliders, switches, tabs, spinners).
  final Color accent;

  final Color accentSolo;
  final Color accentDuel;
  final Color accentLeaderboard;
  final Color accentSettings;

  // ----------------------------------------------------------- style flags

  /// Bloom strength, 0 = no glow at all (no blur passes are recorded).
  final double glow;

  final TrailStyle trailStyle;
  final ShapeStyle shapeStyle;

  /// Arena ring stroke width as a fraction of the arena radius.
  final double ringWidth;

  /// Opacity of the specular core lines; 0 leaves shapes flat.
  final double highlightOpacity;

  /// Panels let the background through at [panelOpacity].
  final bool translucentPanels;
  final double panelOpacity;

  /// Gaussian sigma for the panel backdrop blur; 0 = no [BackdropFilter].
  ///
  /// Only HUD blocks, overlays, menus and cards are blurred — never the
  /// continuously animating arena.
  final double panelBlur;

  final double panelBorderOpacity;

  /// Draws a fine light rim along the top edge of panels (liquid glass).
  final bool specularEdge;

  /// Rounds panels as superellipses (Apple-style squircles) instead of circular
  /// arcs.
  final bool squircle;

  /// Base corner radius for panels, buttons and cards.
  final double cornerRadius;

  /// CRT scanline overlay across the arena.
  final bool scanlines;

  /// Corner darkening, 0 = none.
  final double vignette;

  /// Multiplier for default paddings, so a theme can breathe more.
  final double spacing;

  final HeadingCase headingCase;

  /// Preferred family, or null for the platform default.
  final String? fontFamily;

  /// Families tried when [fontFamily] is missing on the platform.
  final List<String>? fontFamilyFallback;

  // -------------------------------------------------------------- derived

  bool get hasGlow => glow > 0;

  /// True when panels must be drawn behind a [BackdropFilter].
  bool get blurPanels => translucentPanels && panelBlur > 0;

  bool get isDark => brightness == Brightness.dark;

  StrokeCap get strokeCap =>
      shapeStyle == ShapeStyle.rounded ? StrokeCap.round : StrokeCap.butt;

  /// Applies the heading case flag, e.g. for section titles.
  String heading(String text) =>
      headingCase == HeadingCase.upper ? text.toUpperCase() : text;

  /// A corner radius scaled from [cornerRadius]; `factor` 1 is a panel.
  double radius(double factor) => cornerRadius * factor;

  /// Pads [base] by [spacing].
  EdgeInsets pad(EdgeInsets base) => base * spacing;

  /// Border shape used for panels and cards.
  ShapeBorder border(double radius, {Color? color, double width = 1.4}) {
    final side = color == null
        ? BorderSide.none
        : BorderSide(color: color, width: width);
    return squircle
        ? RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(radius),
            side: side,
          )
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: side,
          );
  }

  /// The theme installed by the app shell, or [GameThemes.neon] when a widget
  /// is pumped outside it (a bare widget test, a preview).
  ///
  /// The nullable type argument is deliberate: `provider` only throws when the
  /// requested type is non-nullable, so this resolves to null instead of
  /// blowing up in a tree that has no shell above it.
  static GameTheme of(BuildContext context) =>
      Provider.of<GameTheme?>(context) ?? GameThemes.neon;

  /// Same as [of] but without subscribing; for callbacks and async code.
  static GameTheme read(BuildContext context) =>
      Provider.of<GameTheme?>(context, listen: false) ?? GameThemes.neon;
}

/// The four built-in looks.
abstract final class GameThemes {
  /// Deep navy, cyan and magenta, heavy bloom — the original Arco look and the
  /// default.
  static const GameTheme neon = GameTheme(
    id: ThemeId.neon,
    nameKey: 'theme.neon',
    brightness: Brightness.dark,
    background: Color(0xFF070B1A),
    backgroundGradient: [
      Color(0xFF16224C),
      Color(0xFF0B1230),
      Color(0xFF070B1A),
    ],
    backgroundStops: [0.0, 0.55, 1.0],
    arenaFill: Color(0x141B2A5C),
    ring: Color(0xFF22D3EE),
    ownPaddle: Color(0xFF22D3EE),
    opponentPaddle: Color(0xFFF472B6),
    ball: Color(0xFFF8FAFC),
    ballCore: Color(0x8C22D3EE),
    trail: Color(0xFF22D3EE),
    heart: Color(0xFFFB7185),
    star: Color(0xFFFDE047),
    wall: Color(0xFFC084FC),
    particle: Color(0xFFF8FAFC),
    highlight: Color(0xFFF8FAFC),
    textPrimary: Color(0xFFF8FAFC),
    textDim: Color(0xFF94A3B8),
    panelFill: Color(0xFF0E1530),
    panelBorder: Color(0xFF22D3EE),
    surfaceHigh: Color(0xFF172046),
    outline: Color(0xFF64748B),
    danger: Color(0xFFF87171),
    success: Color(0xFF4ADE80),
    accent: Color(0xFF22D3EE),
    accentSolo: Color(0xFF22D3EE),
    accentDuel: Color(0xFFF472B6),
    accentLeaderboard: Color(0xFFFDE047),
    accentSettings: Color(0xFFC084FC),
    glow: 1.0,
    trailStyle: TrailStyle.comet,
    shapeStyle: ShapeStyle.rounded,
    ringWidth: 0.009,
    highlightOpacity: 0.55,
    translucentPanels: true,
    panelOpacity: 0.92,
    panelBlur: 0,
    panelBorderOpacity: 0.35,
    specularEdge: false,
    squircle: false,
    cornerRadius: 22,
    scanlines: false,
    vignette: 0,
    spacing: 1.0,
    headingCase: HeadingCase.upper,
  );

  /// The arcade original: pure black, white paddle and ball, no bloom, a thin
  /// ring, a monospace face, CRT scanlines and a slight vignette.
  static const GameTheme classic = GameTheme(
    id: ThemeId.classic,
    nameKey: 'theme.classic',
    brightness: Brightness.dark,
    background: Color(0xFF000000),
    backgroundGradient: [
      Color(0xFF0C0C0C),
      Color(0xFF000000),
      Color(0xFF000000),
    ],
    backgroundStops: [0.0, 0.6, 1.0],
    arenaFill: Color(0x0AFFFFFF),
    ring: Color(0xFFFFFFFF),
    ownPaddle: Color(0xFFFFFFFF),
    opponentPaddle: Color(0xFFB0B0B0),
    ball: Color(0xFFFFFFFF),
    ballCore: Color(0xFFFFFFFF),
    trail: Color(0xFFFFFFFF),
    heart: Color(0xFFFF5F56),
    star: Color(0xFFFFB000),
    wall: Color(0xFFB0B0B0),
    particle: Color(0xFFFFFFFF),
    highlight: Color(0xFFFFFFFF),
    textPrimary: Color(0xFFFFFFFF),
    textDim: Color(0xFF9A9A9A),
    panelFill: Color(0xFF0A0A0A),
    panelBorder: Color(0xFFE6E6E6),
    surfaceHigh: Color(0xFF1F1F1F),
    outline: Color(0xFF8A8A8A),
    danger: Color(0xFFFF5F56),
    success: Color(0xFF66D9A0),
    accent: Color(0xFFFFB000),
    accentSolo: Color(0xFFFFFFFF),
    accentDuel: Color(0xFFFFB000),
    accentLeaderboard: Color(0xFF66D9A0),
    accentSettings: Color(0xFF9A9A9A),
    glow: 0,
    trailStyle: TrailStyle.none,
    shapeStyle: ShapeStyle.sharp,
    ringWidth: 0.005,
    highlightOpacity: 0,
    translucentPanels: false,
    panelOpacity: 1.0,
    panelBlur: 0,
    panelBorderOpacity: 0.55,
    specularEdge: false,
    squircle: false,
    cornerRadius: 3,
    scanlines: true,
    vignette: 0.5,
    spacing: 1.0,
    headingCase: HeadingCase.upper,
    // iOS has Courier New; Android resolves the generic "monospace".
    fontFamily: 'Courier New',
    fontFamilyFallback: ['Courier', 'Menlo', 'monospace', 'Roboto Mono'],
  );

  /// A light theme: off-white paper, thin near-black strokes, flat geometry,
  /// one strong vermilion accent, headings in normal case. Every text token
  /// clears 4.5:1 on the background (see `test/app/game_theme_test.dart`).
  static const GameTheme modernist = GameTheme(
    id: ThemeId.modernist,
    nameKey: 'theme.modernist',
    brightness: Brightness.light,
    background: Color(0xFFF5F4F0),
    backgroundGradient: [
      Color(0xFFFBFAF7),
      Color(0xFFF5F4F0),
      Color(0xFFEDEBE4),
    ],
    backgroundStops: [0.0, 0.6, 1.0],
    arenaFill: Color(0x0AFFFFFF),
    ring: Color(0xFF17181A),
    ownPaddle: Color(0xFF17181A),
    opponentPaddle: Color(0xFFBE3B27),
    ball: Color(0xFF17181A),
    // A near-black ring with a vermilion heart: flat, and the one accent marks
    // the single thing the player's eye must follow on a white field.
    ballCore: Color(0xFFBE3B27),
    trail: Color(0xFF17181A),
    heart: Color(0xFFBE3B27),
    star: Color(0xFF17181A),
    wall: Color(0xFF3A3D42),
    particle: Color(0xFF3A3D42),
    highlight: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF17181A),
    textDim: Color(0xFF5A5D63),
    panelFill: Color(0xFFFFFFFF),
    panelBorder: Color(0xFF17181A),
    surfaceHigh: Color(0xFFE6E5DF),
    outline: Color(0xFF7E817B),
    danger: Color(0xFFB3261E),
    success: Color(0xFF1E7A52),
    accent: Color(0xFFBE3B27),
    accentSolo: Color(0xFFBE3B27),
    accentDuel: Color(0xFF17181A),
    accentLeaderboard: Color(0xFF17181A),
    accentSettings: Color(0xFF5A5D63),
    glow: 0,
    trailStyle: TrailStyle.dots,
    shapeStyle: ShapeStyle.sharp,
    ringWidth: 0.006,
    highlightOpacity: 0,
    translucentPanels: false,
    panelOpacity: 1.0,
    panelBlur: 0,
    panelBorderOpacity: 0.85,
    specularEdge: false,
    squircle: false,
    cornerRadius: 6,
    scanlines: false,
    vignette: 0,
    spacing: 1.15,
    headingCase: HeadingCase.normal,
    // The platform grotesques: Helvetica Neue on iOS, Roboto on Android.
    fontFamily: 'Helvetica Neue',
    fontFamilyFallback: ['Helvetica', 'Arial', 'Roboto'],
  );

  /// Liquid glass: dark translucent layers, soft blur, specular rims, squircle
  /// corners, muted colours and one luminous accent.
  static const GameTheme glass = GameTheme(
    id: ThemeId.glass,
    nameKey: 'theme.glass',
    brightness: Brightness.dark,
    background: Color(0xFF0A0C10),
    backgroundGradient: [
      Color(0xFF1E2634),
      Color(0xFF12161F),
      Color(0xFF0A0C10),
    ],
    backgroundStops: [0.0, 0.55, 1.0],
    arenaFill: Color(0x0FFFFFFF),
    ring: Color(0xFFAFC0D6),
    ownPaddle: Color(0xFF64D2FF),
    opponentPaddle: Color(0xFF9AA4B8),
    ball: Color(0xFFFFFFFF),
    ballCore: Color(0x9964D2FF),
    trail: Color(0xFF64D2FF),
    heart: Color(0xFFFF8A9B),
    star: Color(0xFFF5D98B),
    wall: Color(0xFF8E9BB3),
    particle: Color(0xFFCBD5E1),
    highlight: Color(0xFFFFFFFF),
    textPrimary: Color(0xFFF2F5F9),
    textDim: Color(0xFFA7B0C0),
    panelFill: Color(0xFF1A2130),
    panelBorder: Color(0xFFDCE6F5),
    surfaceHigh: Color(0xFF2A3345),
    outline: Color(0xFF6C7789),
    danger: Color(0xFFFF6B6B),
    success: Color(0xFF5EE0A8),
    accent: Color(0xFF64D2FF),
    accentSolo: Color(0xFF64D2FF),
    accentDuel: Color(0xFFC3A6FF),
    accentLeaderboard: Color(0xFFF5D98B),
    accentSettings: Color(0xFF9AA4B8),
    glow: 0.55,
    trailStyle: TrailStyle.comet,
    shapeStyle: ShapeStyle.rounded,
    ringWidth: 0.010,
    highlightOpacity: 0.45,
    translucentPanels: true,
    panelOpacity: 0.42,
    panelBlur: 18,
    panelBorderOpacity: 0.28,
    specularEdge: true,
    squircle: true,
    cornerRadius: 26,
    scanlines: false,
    vignette: 0.3,
    spacing: 1.05,
    headingCase: HeadingCase.normal,
  );

  /// Picker order; [neon] is the default.
  static const List<GameTheme> all = [neon, classic, modernist, glass];

  /// `all.length` as a compile-time constant, for const layout maths.
  static const int themeCount = 4;

  static const GameTheme fallback = neon;

  static GameTheme byId(ThemeId id) => switch (id) {
    ThemeId.neon => neon,
    ThemeId.classic => classic,
    ThemeId.modernist => modernist,
    ThemeId.glass => glass,
  };

  /// The look the catalogue calls [itemId] (SPEC §4.8), or null when this build
  /// has no such look.
  ///
  /// The shop's theme ids *are* the `Strings` keys these carry ([GameTheme.nameKey]),
  /// which is why there is no mapping table here to fall out of step with the
  /// server: `theme.glass` is the item id, the string key and the name of this
  /// look, all at once.
  static GameTheme? byItemId(String? itemId) {
    if (itemId == null) return null;
    for (final theme in all) {
      if (theme.nameKey == itemId) return theme;
    }
    return null;
  }

  /// Resolves a persisted `ThemeId.name`; unknown or missing falls back to
  /// [neon], so an old or corrupt preference can never break a launch.
  static GameTheme byName(String? name) {
    for (final theme in all) {
      if (theme.id.name == name) return theme;
    }
    return fallback;
  }
}
