import 'package:arco/ui/widgets/neon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a label too wide for the button is scaled, not ellipsized', (
    tester,
  ) async {
    // Half of the duel waiting room's button row: "UDOSTĘPNIJ" (the Polish
    // SHARE) is wider than the slot the English label was sized for, and it
    // used to be cut to "UDOSTĘPN…".
    const label = 'UDOSTĘPNIJ';
    const slotWidth = 160.0;
    // NeonButton pads its body by 20 px on each side.
    const innerWidth = slotWidth - 40;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: slotWidth,
              child: NeonButton(
                label: label,
                height: 48,
                fontSize: 12,
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );

    // The paragraph lays itself out at its natural width and is painted
    // scaled down; clamping it to the button instead is what produced the
    // ellipsis, and would make these two widths equal.
    final natural = tester.getSize(find.text(label)).width;
    final painted = tester.getRect(find.text(label)).width;
    expect(
      natural,
      greaterThan(innerWidth),
      reason: 'the fixture no longer exercises an overlong label',
    );
    expect(
      natural,
      greaterThan(painted),
      reason: 'the label is not being scaled to fit',
    );
    expect(painted, lessThanOrEqualTo(innerWidth + 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a label that already fits is left at its natural size', (
    tester,
  ) async {
    const label = 'SOLO';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: NeonButton(label: label, onPressed: () {}),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.text(label)).width,
      closeTo(tester.getRect(find.text(label)).width, 0.01),
    );
    expect(tester.takeException(), isNull);
  });
}
