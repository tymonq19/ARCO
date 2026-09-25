import 'dart:ui' as ui;

import 'package:arco/app/game_theme.dart';
import 'package:arco/app/settings.dart';
import 'package:arco/services/native_sign_in.dart';
import 'package:arco/ui/widgets/brand_logos.dart';
import 'package:arco/ui/widgets/sign_in_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// The two brand buttons (SPEC §4.5): the wording each provider requires, the
/// colour schemes they sanction, and a layout that holds on the narrowest phone
/// at a large text scale.
void main() {
  group('the Google mark', () {
    test('is the four published outlines, filling its box', () {
      final arcs = GoogleGPainter.arcs();
      expect(arcs.length, 4);

      var bounds = arcs.first.$2.getBounds();
      for (final (_, path) in arcs) {
        expect(path.getBounds().isEmpty, isFalse);
        bounds = bounds.expandToInclude(path.getBounds());
      }
      // The artwork's own box: 48 tall, and 46.98 wide because the blue arm
      // stops a whisker short of the right edge. A parse that dropped a corner
      // or misread a relative curve would not land on these numbers.
      expect(bounds.left, closeTo(0, 0.01));
      expect(bounds.top, closeTo(0, 0.01));
      expect(bounds.right, closeTo(46.98, 0.01));
      expect(bounds.bottom, closeTo(48, 0.01));
    });

    test('puts each colour where the logo has it', () {
      final byColour = <int, Path>{
        for (final (color, path) in GoogleGPainter.arcs())
          color.toARGB32(): path,
      };
      const blue = 0xFF4285F4;
      const green = 0xFF34A853;
      const yellow = 0xFFFBBC05;
      const red = 0xFFEA4335;

      // The crossbar of the G runs right from the centre: that is the blue arm.
      expect(byColour[blue]!.contains(const Offset(30, 24)), isTrue);
      expect(byColour[red]!.contains(const Offset(24, 4)), isTrue);
      expect(byColour[yellow]!.contains(const Offset(4, 24)), isTrue);
      expect(byColour[green]!.contains(const Offset(24, 44)), isTrue);

      // A G is a ring: the hole to the left of the crossbar belongs to nobody.
      for (final (_, path) in GoogleGPainter.arcs()) {
        expect(path.contains(const Offset(16, 24)), isFalse);
      }
    });

    test('paints without throwing, and not at all into an empty box', () {
      const painter = GoogleGPainter();
      final drawn = ui.PictureRecorder();
      painter.paint(Canvas(drawn), const Size(18, 18));
      expect(drawn.endRecording(), isNotNull);

      final empty = ui.PictureRecorder();
      painter.paint(Canvas(empty), Size.zero);
      expect(empty.endRecording(), isNotNull);

      expect(painter.shouldRepaint(const GoogleGPainter()), isFalse);
    });
  });

  group('the path parser', () {
    test('reads absolute and relative commands alike', () {
      // The same 10 x 10 square, four ways of saying it.
      final absolute = parseSvgPath('M0 0 L10 0 L10 10 L0 10 Z');
      final relative = parseSvgPath('m0 0 l10 0 l0 10 l-10 0 z');
      final shorthand = parseSvgPath('M0 0 H10 V10 H0 Z');
      final implicit = parseSvgPath('M0 0 10 0 10 10 0 10 Z');

      for (final path in [absolute, relative, shorthand, implicit]) {
        expect(path.getBounds(), const Rect.fromLTRB(0, 0, 10, 10));
        expect(path.contains(const Offset(5, 5)), isTrue);
        expect(path.contains(const Offset(15, 5)), isFalse);
      }
    });

    test('reads the sloppy number formats real path data uses', () {
      // No separator before a negative number, a leading dot, and two dots in a
      // row meaning two numbers.
      final path = parseSvgPath('M.5.5L10-.5 10 10Z');
      expect(path.getBounds().left, closeTo(0.5, 0.001));
      expect(path.getBounds().top, closeTo(-0.5, 0.001));
    });

    test('reflects the control point of a shorthand curve', () {
      final explicit = parseSvgPath(
        'M0 0 C0 10 10 10 10 0 C10 -10 20 -10 20 0',
      );
      final shorthand = parseSvgPath('M0 0 C0 10 10 10 10 0 S20 -10 20 0');
      expect(shorthand.getBounds(), explicit.getBounds());
    });

    test('stops on a command it does not implement instead of spinning', () {
      final path = parseSvgPath('M0 0 L10 0 A5 5 0 0 1 20 0');
      expect(path.getBounds(), const Rect.fromLTRB(0, 0, 10, 0));
    });

    test('an empty or nonsensical string is an empty path', () {
      expect(parseSvgPath('').getBounds(), Rect.zero);
      expect(parseSvgPath('5 5 5').getBounds(), Rect.zero);
    });
  });

  group('the buttons', () {
    Future<void> pump(
      WidgetTester tester,
      TestEnv env, {
      double textScale = 1,
      double width = 320,
    }) async {
      await tester.pumpWidget(
        wrapApp(
          env,
          Scaffold(
            body: Center(
              child: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
                child: SizedBox(
                  width: width,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final provider in SignInProvider.values)
                        SignInButton(provider: provider, onPressed: () {}),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('carry the wording each provider requires', (tester) async {
      final env = await createTestEnv();
      await pump(tester, env);

      expect(find.text('Sign in with Apple'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsOneWidget);

      env.settings.language = AppLanguage.pl;
      await tester.pump();

      // Apple's and Google's own Polish wording, not a translation of ours.
      expect(find.text('Zaloguj się przez Apple'), findsOneWidget);
      expect(find.text('Zaloguj się przez Google'), findsOneWidget);
    });

    testWidgets('are announced as buttons', (tester) async {
      final env = await createTestEnv();
      await pump(tester, env);
      final semantics = tester.getSemantics(find.byType(SignInButton).first);
      expect(semantics.label, 'Sign in with Apple');
      expect(semantics.flagsCollection.isButton, isTrue);
    });

    testWidgets('use the scheme each theme sanctions', (tester) async {
      for (final theme in GameThemes.all) {
        final env = await createTestEnv(theme: theme.id);
        await pump(tester, env);
        final material = tester.widget<Material>(
          find.descendant(
            of: find.byType(SignInButton).first,
            matching: find.byType(Material),
          ),
        );
        // Apple's rule: white button on a dark background, black on a light one.
        expect(
          material.color,
          theme.isDark ? Colors.white : Colors.black,
          reason: 'the Apple button is the wrong scheme under ${theme.id.name}',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('hold their layout at 320 pt and 1.6 text scale', (
      tester,
    ) async {
      useNarrowPhone(tester);
      for (final theme in GameThemes.all) {
        final env = await createTestEnv(theme: theme.id);
        // The panel padding a real card leaves them, on the narrowest phone.
        await pump(tester, env, textScale: 1.6, width: 232);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the buttons overflowed under ${theme.id.name}',
        );
        for (final provider in SignInProvider.values) {
          final size = tester.getSize(
            find.byWidgetPredicate(
              (w) => w is SignInButton && w.provider == provider,
            ),
          );
          expect(size.width, lessThanOrEqualTo(232));
          // Apple's floor, and the two are always the same height so neither
          // looks like the lesser option.
          expect(size.height, greaterThanOrEqualTo(SignInButton.minHeight));
        }
        final heights = [
          for (final provider in SignInProvider.values)
            tester
                .getSize(
                  find.byWidgetPredicate(
                    (w) => w is SignInButton && w.provider == provider,
                  ),
                )
                .height,
        ];
        expect(heights.first, heights.last);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a disabled button does not fire', (tester) async {
      final env = await createTestEnv();
      var taps = 0;
      await tester.pumpWidget(
        wrapApp(
          env,
          Scaffold(
            body: Column(
              children: [
                SignInButton(provider: SignInProvider.apple, onPressed: null),
                SignInButton(
                  provider: SignInProvider.google,
                  onPressed: () => taps++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Sign in with Apple'));
      await tester.pump();
      expect(taps, 0);
      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();
      expect(taps, 1);
    });
  });
}
