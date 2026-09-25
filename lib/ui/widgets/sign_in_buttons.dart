import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show AppleLogoPainter;

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../services/native_sign_in.dart';
import 'brand_logos.dart';

/// The provider sign-in buttons (SPEC §4.5).
///
/// These are the two widgets in the app that do **not** take their colours from
/// the [GameTheme], and deliberately so. Apple's Human Interface Guidelines fix
/// the Sign in with Apple button's geometry, its logo, its wording and its two
/// colour schemes — black on a light background, white on a dark one — and
/// Google asks the same of its own mark. A button recoloured in vermilion or
/// cyan would be a rejected build, not a nicer one.
///
/// What the theme does decide is the corner radius (the HIG allows anything from
/// square to fully rounded) and which of the sanctioned schemes is used, so the
/// pair still belongs to the look around it. Both buttons share one geometry and
/// one height, because App Store review requires Sign in with Apple to be no
/// less prominent than any other third-party sign-in offered beside it.
///
/// Proportions follow Apple's specification, the same ones
/// `SignInWithAppleButton` implements: a label at 43 % of the height, the logo
/// at 28/44 of it, 16 pt of side padding. The label sits in a [FittedBox] rather
/// than being allowed to wrap, which is what keeps the longer Polish wording —
/// "Zaloguj się przez Apple" — inside a 320 pt phone at a large text scale.
class SignInButton extends StatelessWidget {
  const SignInButton({
    super.key,
    required this.provider,
    required this.onPressed,
    this.height = 48,
  });

  /// Apple's minimum is 44; a couple of points more sits better next to the
  /// app's own 46–58 pt buttons.
  static const double minHeight = 44;

  /// How far the button may grow with the player's text size. Past this a
  /// 320 pt phone cannot hold two of them plus the panel around them, and the
  /// label's own [FittedBox] keeps it readable anyway.
  static const double maxTextScale = 1.35;

  final SignInProvider provider;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    // On a dark look the sanctioned scheme is the light button, and the other
    // way round: that is Apple's rule, and Google's mark is legible on both.
    final light = theme.isDark;
    final label = switch (provider) {
      SignInProvider.apple => s.t('account.signInApple'),
      SignInProvider.google => s.t('account.signInGoogle'),
    };
    final scale = MediaQuery.textScalerOf(
      context,
    ).scale(16).clamp(16.0, 16.0 * maxTextScale);
    final h = (height * scale / 16).clamp(minHeight, 200.0);
    final fontSize = h * 0.43;
    final (Color surface, Color content, Color? border) = switch (provider) {
      // Apple: black/white only, no outline on either (HIG).
      SignInProvider.apple =>
        light
            ? (Colors.white, Colors.black, null)
            : (Colors.black, Colors.white, null),
      // Google: its own light and dark button tokens, including the grey rule
      // that keeps the white one visible on white.
      SignInProvider.google =>
        light
            ? (Colors.white, const Color(0xFF1F1F1F), const Color(0xFF747775))
            : (const Color(0xFF131314), const Color(0xFFE3E3E3), null),
    };
    final radius = theme.radius(0.82).clamp(0.0, h / 2);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      // The label above is the button's whole meaning; without this the Text
      // inside is announced a second time.
      excludeSemantics: true,
      child: Opacity(
        // A brand button has no disabled colour of its own; fading the whole
        // thing keeps the artwork intact.
        opacity: onPressed == null ? 0.5 : 1,
        child: Material(
          color: surface,
          // A plain rounded rectangle even under the glass look's superellipse:
          // the outline is part of the button both providers publish, and only
          // its radius is ours to set.
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: border == null ? BorderSide.none : BorderSide(color: border),
          ),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(radius),
            child: SizedBox(
              height: h,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _mark(fontSize: fontSize, height: h, color: content),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        // The label is sized from the button, so the text scaler
                        // must not size it a second time.
                        child: MediaQuery.withNoTextScaling(
                          child: Text(
                            label,
                            maxLines: 1,
                            softWrap: false,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              inherit: false,
                              color: content,
                              fontSize: fontSize,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.41,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The provider's own mark, in the box Apple's specification gives it.
  Widget _mark({
    required double fontSize,
    required double height,
    required Color color,
  }) {
    final box = height * 28 / 44;
    return SizedBox(
      width: box,
      height: box,
      child: Padding(
        // Optically centres the Apple glyph against the cap height, as Apple's
        // own button does; the square Google mark needs none of it.
        padding: EdgeInsets.only(
          bottom: provider == SignInProvider.apple ? height * 4 / 44 : 0,
        ),
        child: Center(
          child: switch (provider) {
            SignInProvider.apple => SizedBox(
              width: fontSize * 25 / 31,
              height: fontSize,
              child: CustomPaint(painter: AppleLogoPainter(color: color)),
            ),
            SignInProvider.google => SizedBox.square(
              dimension: fontSize,
              child: const CustomPaint(painter: GoogleGPainter()),
            ),
          },
        ),
      ),
    );
  }
}
