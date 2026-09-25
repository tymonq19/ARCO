import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

void main() {
  group('DetMath', () {
    test('sin and cos match dart:math within 1e-6 on 10k samples', () {
      final rnd = math.Random(1234);
      var maxErr = 0.0;
      for (var i = 0; i < 10000; i++) {
        final x = (rnd.nextDouble() - 0.5) * 100; // [-50, 50]
        final es = (DetMath.sin(x) - math.sin(x)).abs();
        final ec = (DetMath.cos(x) - math.cos(x)).abs();
        if (es > maxErr) maxErr = es;
        if (ec > maxErr) maxErr = ec;
      }
      expect(maxErr, lessThan(1e-6));
    });

    test('sin and cos at special angles', () {
      expect(DetMath.sin(0), 0);
      expect(DetMath.cos(0), 1);
      expect(DetMath.sin(DetMath.halfPi), closeTo(1, 1e-9));
      expect(DetMath.cos(DetMath.halfPi), closeTo(0, 1e-9));
      expect(DetMath.sin(DetMath.pi), closeTo(0, 1e-9));
      expect(DetMath.cos(DetMath.pi), closeTo(-1, 1e-9));
      expect(DetMath.sin(3 * DetMath.pi / 2), closeTo(-1, 1e-9));
      expect(DetMath.cos(3 * DetMath.pi / 2), closeTo(0, 1e-9));
      expect(DetMath.sin(DetMath.tau), closeTo(0, 1e-9));
      expect(DetMath.cos(-DetMath.tau * 3), closeTo(1, 1e-9));
      expect(DetMath.sin(-DetMath.halfPi), closeTo(-1, 1e-9));
    });

    test('sin/cos are exactly reproducible', () {
      for (var i = 0; i < 1000; i++) {
        final x = i * 0.0123 - 6.0;
        expect(DetMath.sin(x), DetMath.sin(x));
        expect(DetMath.cos(x), DetMath.cos(x));
      }
    });

    test('atan2 matches dart:math within 1e-6 on 10k samples', () {
      final rnd = math.Random(4321);
      var maxErr = 0.0;
      for (var i = 0; i < 10000; i++) {
        final y = (rnd.nextDouble() - 0.5) * 4;
        final x = (rnd.nextDouble() - 0.5) * 4;
        final err = (DetMath.atan2(y, x) - math.atan2(y, x)).abs();
        if (err > maxErr) maxErr = err;
      }
      expect(maxErr, lessThan(1e-6));
    });

    test('atan2 quadrants, axes and zero cases', () {
      expect(DetMath.atan2(0, 0), 0);
      expect(DetMath.atan2(0, 1), 0);
      expect(DetMath.atan2(1, 0), DetMath.halfPi);
      expect(DetMath.atan2(0, -1), DetMath.pi);
      expect(DetMath.atan2(-1, 0), -DetMath.halfPi);
      expect(DetMath.atan2(-0.0, -1), DetMath.pi); // documented: -0 == 0
      expect(DetMath.atan2(1, 1), closeTo(DetMath.quarterPi, 1e-9));
      expect(DetMath.atan2(1, -1), closeTo(3 * DetMath.quarterPi, 1e-9));
      expect(DetMath.atan2(-1, -1), closeTo(-3 * DetMath.quarterPi, 1e-9));
      expect(DetMath.atan2(-1, 1), closeTo(-DetMath.quarterPi, 1e-9));
      expect(DetMath.atan2(2, 0.5), closeTo(math.atan2(2, 0.5), 1e-7));
      expect(DetMath.atan2(1e-9, 1), closeTo(1e-9, 1e-12));
      expect(DetMath.atan2(1, 1e-9), closeTo(DetMath.halfPi, 1e-7));
      // Range check on a full sweep.
      for (var i = 0; i < 720; i++) {
        final a = i * DetMath.tau / 720;
        final r = DetMath.atan2(math.sin(a), math.cos(a));
        expect(r, greaterThan(-DetMath.pi));
        expect(r, lessThanOrEqualTo(DetMath.pi));
      }
    });

    test('normAngle maps into [0, tau)', () {
      expect(DetMath.normAngle(0), 0);
      expect(DetMath.normAngle(DetMath.tau), 0);
      expect(DetMath.normAngle(-DetMath.tau), 0);
      expect(DetMath.normAngle(-1e-18), lessThan(DetMath.tau));
      expect(DetMath.normAngle(1.5), 1.5);
      expect(DetMath.normAngle(-0.1), closeTo(DetMath.tau - 0.1, 1e-12));
      expect(DetMath.normAngle(7 * DetMath.tau + 1), closeTo(1, 1e-12));
      final rnd = math.Random(7);
      for (var i = 0; i < 10000; i++) {
        final a = (rnd.nextDouble() - 0.5) * 1000;
        final n = DetMath.normAngle(a);
        expect(n, greaterThanOrEqualTo(0));
        expect(n, lessThan(DetMath.tau));
        // Same direction as the input.
        expect(math.cos(n), closeTo(math.cos(a), 1e-9));
        expect(math.sin(n), closeTo(math.sin(a), 1e-9));
      }
    });

    test('angleDiff gives the shortest signed difference in (-pi, pi]', () {
      expect(DetMath.angleDiff(0.1, 0), closeTo(0.1, 1e-12));
      expect(DetMath.angleDiff(0, 0.1), closeTo(-0.1, 1e-12));
      expect(DetMath.angleDiff(DetMath.tau - 0.1, 0), closeTo(-0.1, 1e-12));
      expect(DetMath.angleDiff(0, DetMath.tau - 0.1), closeTo(0.1, 1e-12));
      expect(DetMath.angleDiff(DetMath.pi, 0), DetMath.pi);
      expect(DetMath.angleDiff(0, DetMath.pi), DetMath.pi);
      expect(DetMath.angleDiff(5, 5), 0);
      final rnd = math.Random(8);
      for (var i = 0; i < 10000; i++) {
        final a = (rnd.nextDouble() - 0.5) * 100;
        final b = (rnd.nextDouble() - 0.5) * 100;
        final d = DetMath.angleDiff(a, b);
        expect(d, greaterThan(-DetMath.pi));
        expect(d, lessThanOrEqualTo(DetMath.pi));
        expect(math.cos(b + d), closeTo(math.cos(a), 1e-9));
        expect(math.sin(b + d), closeTo(math.sin(a), 1e-9));
      }
    });
  });
}
