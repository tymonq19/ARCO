import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'game_theme.dart';

/// How the platform's own overlays — the iOS status bar, the Android status and
/// navigation bars — must be drawn for [theme].
///
/// The app draws edge to edge, so those glyphs sit directly on the theme's
/// background: light ones on the three dark looks, dark ones on Modernist,
/// whose paper would otherwise swallow the clock and the battery whole.
SystemUiOverlayStyle systemOverlayStyleFor(GameTheme theme) {
  final base = theme.isDark
      ? SystemUiOverlayStyle.light
      : SystemUiOverlayStyle.dark;
  return base.copyWith(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: theme.background,
    systemNavigationBarIconBrightness: theme.isDark
        ? Brightness.light
        : Brightness.dark,
  );
}

/// Builds the Material [ThemeData] for [theme].
///
/// Everything visual is derived from the [GameTheme], so the same function
/// produces the dark neon shell, the black arcade shell, the light modernist
/// shell and the glass shell. Widgets that need more than Material exposes read
/// the [GameTheme] itself through [GameTheme.of].
ThemeData buildAppTheme(GameTheme theme) {
  final scheme = ColorScheme(
    brightness: theme.brightness,
    primary: theme.accent,
    onPrimary: theme.background,
    secondary: theme.accentDuel,
    onSecondary: theme.background,
    tertiary: theme.accentLeaderboard,
    surface: theme.panelFill,
    onSurface: theme.textPrimary,
    error: theme.danger,
    onError: theme.background,
  );
  // Upper-case headings want wide tracking; a normal-case grotesque wants
  // almost none, so the tracking follows the theme's heading style.
  final track = theme.headingCase == HeadingCase.upper ? 1.0 : 0.2;
  final base = ThemeData(
    useMaterial3: true,
    brightness: theme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: theme.background,
    canvasColor: theme.background,
    fontFamily: theme.fontFamily,
    fontFamilyFallback: theme.fontFamilyFallback,
  );
  final text = base.textTheme.apply(
    bodyColor: theme.textPrimary,
    displayColor: theme.textPrimary,
  );
  final panelRadius = BorderRadius.circular(theme.radius(0.65));
  OutlineInputBorder inputBorder(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: panelRadius,
        borderSide: BorderSide(color: color, width: width),
      );
  return base.copyWith(
    textTheme: text.copyWith(
      displayLarge: text.displayLarge?.copyWith(
        fontWeight: FontWeight.w900,
        letterSpacing: 4 * track,
      ),
      headlineMedium: text.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: 2 * track,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: track,
      ),
      labelLarge: text.labelLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: 2 * track,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: theme.textPrimary,
      elevation: 0,
      centerTitle: true,
      // An AppBar posts its own overlay annotation on top of the app-wide one,
      // so it has to be told the same answer.
      systemOverlayStyle: systemOverlayStyleFor(theme),
      titleTextStyle: TextStyle(
        color: theme.textPrimary,
        fontFamily: theme.fontFamily,
        fontFamilyFallback: theme.fontFamilyFallback,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: 3 * track,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: theme.translucentPanels
          ? theme.panelFill.withValues(alpha: theme.panelOpacity)
          : theme.panelFill,
      labelStyle: TextStyle(color: theme.textDim),
      hintStyle: TextStyle(color: theme.textDim),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: inputBorder(theme.outline, 1),
      enabledBorder: inputBorder(theme.outline, 1),
      focusedBorder: inputBorder(theme.accent, 2),
      errorBorder: inputBorder(theme.danger, 1),
      focusedErrorBorder: inputBorder(theme.danger, 2),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: theme.accent,
      thumbColor: theme.accent,
      inactiveTrackColor: theme.surfaceHigh,
      overlayColor: theme.accent.withValues(alpha: 0.2),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.selected) ? theme.background : theme.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.selected) ? theme.accent : theme.surfaceHigh,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? theme.accent.withValues(alpha: 0.2)
              : theme.panelFill,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? theme.accent : theme.textDim,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: theme.outline)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: theme.surfaceHigh,
      contentTextStyle: TextStyle(color: theme.textPrimary),
      behavior: SnackBarBehavior.floating,
    ),
    dividerColor: theme.surfaceHigh,
    listTileTheme: ListTileThemeData(
      iconColor: theme.accent,
      textColor: theme.textPrimary,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: theme.accent,
      unselectedLabelColor: theme.textDim,
      indicatorColor: theme.accent,
      dividerColor: theme.surfaceHigh,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: theme.accent),
  );
}
