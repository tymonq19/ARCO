import 'package:arco/app/game_theme.dart';
import 'package:arco/app/settings.dart';
import 'package:arco/app/strings.dart';
import 'package:arco/services/storage.dart';
import 'package:arco/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/contrast.dart';

/// Simulates a fresh app launch over the same preferences store.
Future<Settings> relaunch() async {
  SharedPreferences.resetStatic();
  return Settings(await Storage.load());
}

/// Tokens a theme paints text with; each needs WCAG AA (4.5:1) on both the page
/// background and a panel, because all of them are used as label colours
/// somewhere (scores, ranks, hints, error messages).
List<(String, Color)> textTokens(GameTheme t) => [
  ('textPrimary', t.textPrimary),
  ('textDim', t.textDim),
  ('accent', t.accent),
  ('star', t.star),
  ('heart', t.heart),
  ('danger', t.danger),
  ('success', t.success),
  ('accentSolo', t.accentSolo),
  ('accentDuel', t.accentDuel),
  ('accentLeaderboard', t.accentLeaderboard),
  ('accentSettings', t.accentSettings),
];

/// Tokens a theme draws shapes with: WCAG 1.4.11 asks for 3:1.
List<(String, Color)> graphicTokens(GameTheme t) => [
  ('ring', t.ring),
  ('ownPaddle', t.ownPaddle),
  ('opponentPaddle', t.opponentPaddle),
  ('ball', t.ball),
  ('wall', t.wall),
  ('outline', t.outline),
];

void main() {
  test('Modernist is legible in daylight: every text token clears 4.5:1', () {
    const t = GameThemes.modernist;
    expect(t.brightness, Brightness.light);
    // The exact numbers, so a later palette tweak cannot quietly dim them.
    expect(
      contrastRatio(t.textPrimary, t.background),
      closeTo(16.14, 0.02),
      reason: 'near-black body text on off-white paper',
    );
    expect(
      contrastRatio(t.textDim, t.background),
      closeTo(6.00, 0.02),
      reason: 'secondary grey text',
    );
    expect(
      contrastRatio(t.accent, t.background),
      closeTo(4.96, 0.02),
      reason: 'the one strong accent is also used as a label colour',
    );
    for (final (name, color) in textTokens(t)) {
      expect(
        contrastRatio(color, t.background),
        greaterThanOrEqualTo(4.5),
        reason: '$name on the modernist background',
      );
      expect(
        contrastRatio(color, t.panelFill),
        greaterThanOrEqualTo(4.5),
        reason: '$name on a modernist panel',
      );
    }
    for (final (name, color) in graphicTokens(t)) {
      expect(
        contrastRatio(color, t.background),
        greaterThanOrEqualTo(3.0),
        reason: '$name on the modernist background',
      );
    }
  });

  test('every theme keeps text at AA and shapes at 3:1', () {
    for (final t in GameThemes.all) {
      for (final (name, color) in textTokens(t)) {
        expect(
          contrastRatio(color, t.background),
          greaterThanOrEqualTo(4.5),
          reason: '${t.id.name}: $name on the background',
        );
        expect(
          contrastRatio(color, t.panelFill),
          greaterThanOrEqualTo(4.5),
          reason: '${t.id.name}: $name on a panel',
        );
      }
      for (final (name, color) in graphicTokens(t)) {
        expect(
          contrastRatio(color, t.background),
          greaterThanOrEqualTo(3.0),
          reason: '${t.id.name}: $name on the background',
        );
      }
    }
  });

  test('the four themes are genuinely different looks, not recolours', () {
    expect(GameThemes.all.map((t) => t.id).toSet(), hasLength(4));
    expect(GameThemes.themeCount, GameThemes.all.length);
    // Neon is the only heavy-bloom look; classic and modernist are flat.
    expect(GameThemes.neon.hasGlow, isTrue);
    expect(GameThemes.classic.hasGlow, isFalse);
    expect(GameThemes.modernist.hasGlow, isFalse);
    expect(GameThemes.glass.hasGlow, isTrue);
    // Trails, caps, panels and type all differ.
    expect(
      GameThemes.all.map((t) => t.trailStyle).toSet(),
      containsAll(<TrailStyle>[
        TrailStyle.comet,
        TrailStyle.dots,
        TrailStyle.none,
      ]),
    );
    expect(GameThemes.classic.scanlines, isTrue);
    expect(GameThemes.classic.vignette, greaterThan(0));
    expect(GameThemes.classic.shapeStyle, ShapeStyle.sharp);
    expect(GameThemes.classic.fontFamily, isNotNull);
    expect(GameThemes.modernist.fontFamily, isNotNull);
    expect(GameThemes.modernist.headingCase, HeadingCase.normal);
    expect(GameThemes.glass.blurPanels, isTrue);
    expect(GameThemes.glass.squircle, isTrue);
    expect(GameThemes.glass.specularEdge, isTrue);
    // Only the glass look blurs anything at all.
    for (final t in GameThemes.all.where((t) => t.id != ThemeId.glass)) {
      expect(t.blurPanels, isFalse, reason: '${t.id.name} must not blur');
    }
    // The ring width is a real difference: classic's is the thinnest.
    expect(GameThemes.classic.ringWidth, lessThan(GameThemes.neon.ringWidth));
  });

  test('the platform overlays are drawn against the theme, not over it', () {
    // The app draws edge to edge, so the clock and the battery sit straight on
    // the theme's background. Modernist's paper needs dark glyphs; the other
    // three need light ones. Getting this backwards makes the status bar
    // vanish, which is exactly what it did before it was set at all.
    for (final theme in GameThemes.all) {
      final style = systemOverlayStyleFor(theme);
      final wanted = theme.isDark ? Brightness.light : Brightness.dark;
      expect(
        style.statusBarIconBrightness,
        wanted,
        reason: '${theme.id.name}: status bar glyphs',
      );
      expect(
        style.systemNavigationBarIconBrightness,
        wanted,
        reason: '${theme.id.name}: navigation bar glyphs',
      );
      // iOS reads `statusBarBrightness` as the brightness of what is *behind*
      // the glyphs, i.e. the opposite of the glyphs themselves.
      expect(
        style.statusBarBrightness,
        theme.brightness,
        reason: '${theme.id.name}: the backdrop the glyphs sit on',
      );
      expect(style.statusBarColor, Colors.transparent);
      expect(style.systemNavigationBarColor, theme.background);
    }
    expect(
      systemOverlayStyleFor(GameThemes.modernist).statusBarIconBrightness,
      Brightness.dark,
    );
  });

  test('an AppBar asks for the same overlays as the rest of the app', () {
    // An AppBar posts its own annotation over the app-wide one, so a screen
    // with one would otherwise fall back to Material's default.
    for (final theme in GameThemes.all) {
      expect(
        buildAppTheme(theme).appBarTheme.systemOverlayStyle,
        systemOverlayStyleFor(theme),
        reason: theme.id.name,
      );
    }
  });

  test('heading case follows the theme', () {
    expect(GameThemes.neon.heading('Theme'), 'THEME');
    expect(GameThemes.classic.heading('Theme'), 'THEME');
    expect(GameThemes.modernist.heading('Theme'), 'Theme');
    expect(GameThemes.glass.heading('Theme'), 'Theme');
  });

  test('every theme has a translated display name', () {
    for (final t in GameThemes.all) {
      expect(Strings.en[t.nameKey], isNotNull, reason: t.nameKey);
      expect(Strings.pl[t.nameKey], isNotNull, reason: t.nameKey);
    }
  });

  test('byName resolves the persisted id and falls back to neon', () {
    for (final t in GameThemes.all) {
      expect(GameThemes.byName(t.id.name), same(t));
      expect(GameThemes.byId(t.id), same(t));
    }
    expect(GameThemes.byName(null), same(GameThemes.neon));
    expect(GameThemes.byName(''), same(GameThemes.neon));
    expect(GameThemes.byName('vaporwave'), same(GameThemes.neon));
  });

  test('neon is the default when nothing is stored', () async {
    SharedPreferences.setMockInitialValues(const {});
    final settings = Settings(await Storage.load());
    expect(settings.theme, same(GameThemes.neon));
    expect(settings.themeId, ThemeId.neon);
  });

  test('the chosen theme survives a Storage round-trip', () async {
    for (final chosen in GameThemes.all) {
      SharedPreferences.setMockInitialValues(const {});
      final settings = Settings(await Storage.load());
      settings.theme = chosen;
      // Writes are fire-and-forget; let the store flush before relaunching.
      await Future<void>.delayed(Duration.zero);

      final next = await relaunch();
      expect(next.themeId, chosen.id, reason: 'after storing ${chosen.id}');
      expect(next.theme, same(chosen));
    }
  });

  test('a corrupt stored theme still launches on the default', () async {
    SharedPreferences.setMockInitialValues(const {'theme': 'not-a-theme'});
    final settings = Settings(await Storage.load());
    expect(settings.theme, same(GameThemes.neon));
  });

  test('setting the theme notifies once and only on a real change', () async {
    SharedPreferences.setMockInitialValues(const {});
    final settings = Settings(await Storage.load());
    var notifications = 0;
    settings.addListener(() => notifications++);
    settings.theme = GameThemes.classic;
    settings.themeId = ThemeId.classic;
    expect(notifications, 1);
    settings.themeId = ThemeId.modernist;
    expect(notifications, 2);
  });
}
