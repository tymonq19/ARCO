import 'dart:math' as math;

import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

void main() {
  group('Prng', () {
    test('xoshiro128** reference sequence from state (1, 2, 3, 4)', () {
      final p = Prng.fromState(1, 2, 3, 4);
      // Reference outputs of the Blackman & Vigna xoshiro128** algorithm.
      const expected = [
        11520,
        0,
        5927040,
        70819200,
        2031721883,
        1637235492,
        1287239034,
        3734860849,
      ];
      for (final e in expected) {
        expect(p.nextUint32(), e);
      }
    });

    // Golden values cross-checked against an independent JavaScript
    // implementation (splitmix32 with bryc's constants + xoshiro128** using
    // Math.imul), so this pins the seeding against a reference, not against
    // our own code.
    test('splitmix32 seeding reference (seed 12345)', () {
      final p = Prng(12345);
      expect(p.toJson(), [3283241497, 613117429, 2940958500, 516375437]);
      const expected = [
        1093274547,
        203003357,
        3741353573,
        3803725158,
        4178738660,
      ];
      for (final e in expected) {
        expect(p.nextUint32(), e);
      }
    });

    test('splitmix32 seeding reference (seed 0)', () {
      expect(Prng(0).toJson(), [
        1684164658,
        3653269916,
        2939563536,
        2141751570,
      ]);
    });

    test('seed is reduced to 32 bits and different seeds differ', () {
      expect(Prng(5).toJson(), Prng(5 + 0x100000000).toJson());
      expect(Prng(0).toJson(), isNot(Prng(1).toJson()));
      expect(Prng(0).toJson().any((w) => w != 0), isTrue);
      expect(Prng(-1).toJson(), Prng(0xFFFFFFFF).toJson());
    });

    test('mul32 equals the low 32 bits of the exact product', () {
      final rnd = math.Random(3);
      for (var i = 0; i < 5000; i++) {
        final a = rnd.nextInt(1 << 32);
        final b = rnd.nextInt(1 << 32);
        final exact =
            (BigInt.from(a) * BigInt.from(b)) & BigInt.from(0xFFFFFFFF);
        expect(Prng.mul32(a, b), exact.toInt());
      }
      expect(Prng.mul32(0xFFFFFFFF, 0xFFFFFFFF), 1);
      expect(Prng.mul32(0x9E3779B9, 0x85EBCA6B), 0xC10EDA53);
    });

    test('rotl32 rotates within 32 bits', () {
      expect(Prng.rotl32(1, 1), 2);
      expect(Prng.rotl32(0x80000000, 1), 1);
      expect(Prng.rotl32(0x12345678, 8), 0x34567812);
      expect(Prng.rotl32(0xFFFFFFFF, 13), 0xFFFFFFFF);
    });

    test('nextUint32 stays within 32 bits', () {
      final p = Prng(99);
      for (var i = 0; i < 100000; i++) {
        final v = p.nextUint32();
        expect(v, greaterThanOrEqualTo(0));
        expect(v, lessThan(0x100000000));
      }
    });

    test('nextInt is within [0, n) and covers every value', () {
      final p = Prng(2024);
      final seen = List<bool>.filled(7, false);
      for (var i = 0; i < 10000; i++) {
        final v = p.nextInt(7);
        expect(v, greaterThanOrEqualTo(0));
        expect(v, lessThan(7));
        seen[v] = true;
      }
      expect(seen.every((b) => b), isTrue);
      expect(Prng(1).nextInt(1), 0);
      expect(() => Prng(1).nextInt(0), throwsArgumentError);
    });

    test('nextDouble is within [0, 1) with 24-bit granularity', () {
      final p = Prng(77);
      var min = 1.0;
      var max = 0.0;
      for (var i = 0; i < 100000; i++) {
        final v = p.nextDouble();
        expect(v, greaterThanOrEqualTo(0));
        expect(v, lessThan(1));
        expect((v * 16777216.0) % 1, 0);
        if (v < min) min = v;
        if (v > max) max = v;
      }
      expect(min, lessThan(0.001));
      expect(max, greaterThan(0.999));
    });

    test('nextRange is within [a, b)', () {
      final p = Prng(5);
      for (var i = 0; i < 10000; i++) {
        final v = p.nextRange(7, 9);
        expect(v, greaterThanOrEqualTo(7));
        expect(v, lessThan(9));
      }
    });

    test('clone and JSON round-trip reproduce the same sequence', () {
      final p = Prng(31337);
      p.nextUint32();
      p.nextUint32();
      final c = p.clone();
      final j = Prng.fromJson(p.toJson());
      for (var i = 0; i < 1000; i++) {
        final v = p.nextUint32();
        expect(c.nextUint32(), v);
        expect(j.nextUint32(), v);
      }
    });
  });
}
