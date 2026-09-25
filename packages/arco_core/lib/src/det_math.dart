/// Deterministic trigonometry using only IEEE-754 basic arithmetic so results
/// are bit-identical on every platform (VM, AOT, JS). See SPEC.md §2.1.
///
/// Only `+ - * /`, comparisons and `floor` are used: no `dart:math`
/// transcendental functions and no fused operations. Every polynomial is
/// evaluated in a fixed Horner order so the rounding sequence is identical on
/// every backend.
library;

class DetMath {
  DetMath._();

  static const double pi = 3.141592653589793;
  static const double tau = 6.283185307179586;
  static const double halfPi = 1.5707963267948966;
  static const double quarterPi = 0.7853981633974483;

  /// 3π/2: start angle of the solo paddle and of player 0 in a duel.
  static const double threeHalfPi = 4.71238898038469;

  /// Literal 1/τ used for range reduction (multiplication instead of division
  /// keeps the reduction cheap; the value is exact to the last bit).
  static const double invTau = 0.15915494309189535;

  /// tan(π/8) = √2 − 1: threshold of the atan argument reduction.
  static const double _tanEighthPi = 0.41421356237309503;

  // Taylor coefficients of sin(x) = x − x³/3! + x⁵/5! − … (through x¹⁵).
  static const double _s3 = -1.0 / 6.0;
  static const double _s5 = 1.0 / 120.0;
  static const double _s7 = -1.0 / 5040.0;
  static const double _s9 = 1.0 / 362880.0;
  static const double _s11 = -1.0 / 39916800.0;
  static const double _s13 = 1.0 / 6227020800.0;
  static const double _s15 = -1.0 / 1307674368000.0;

  // Taylor coefficients of cos(x) = 1 − x²/2! + x⁴/4! − … (through x¹⁶).
  static const double _c2 = -1.0 / 2.0;
  static const double _c4 = 1.0 / 24.0;
  static const double _c6 = -1.0 / 720.0;
  static const double _c8 = 1.0 / 40320.0;
  static const double _c10 = -1.0 / 3628800.0;
  static const double _c12 = 1.0 / 479001600.0;
  static const double _c14 = -1.0 / 87178291200.0;
  static const double _c16 = 1.0 / 20922789888000.0;

  // Taylor coefficients of atan(x) = x − x³/3 + x⁵/5 − … (through x²³).
  static const double _a3 = -1.0 / 3.0;
  static const double _a5 = 1.0 / 5.0;
  static const double _a7 = -1.0 / 7.0;
  static const double _a9 = 1.0 / 9.0;
  static const double _a11 = -1.0 / 11.0;
  static const double _a13 = 1.0 / 13.0;
  static const double _a15 = -1.0 / 15.0;
  static const double _a17 = 1.0 / 17.0;
  static const double _a19 = -1.0 / 19.0;
  static const double _a21 = 1.0 / 21.0;
  static const double _a23 = -1.0 / 23.0;

  /// Reduces [x] to the equivalent angle in [-π, π].
  static double _reduce(double x) {
    final k = (x * invTau + 0.5).floorToDouble();
    return x - k * tau;
  }

  /// Taylor polynomial of sin, accurate to ~1e-11 on [-π/2, π/2].
  static double _sinPoly(double r) {
    final r2 = r * r;
    return r *
        (1.0 +
            r2 *
                (_s3 +
                    r2 *
                        (_s5 +
                            r2 *
                                (_s7 +
                                    r2 *
                                        (_s9 +
                                            r2 *
                                                (_s11 +
                                                    r2 *
                                                        (_s13 +
                                                            r2 * _s15)))))));
  }

  /// Taylor polynomial of cos, accurate to ~1e-12 on [0, π/2].
  static double _cosPoly(double r) {
    final r2 = r * r;
    return 1.0 +
        r2 *
            (_c2 +
                r2 *
                    (_c4 +
                        r2 *
                            (_c6 +
                                r2 *
                                    (_c8 +
                                        r2 *
                                            (_c10 +
                                                r2 *
                                                    (_c12 +
                                                        r2 *
                                                            (_c14 +
                                                                r2 *
                                                                    _c16)))))));
  }

  /// Taylor polynomial of atan, accurate to ~1e-11 on [-tan(π/8), tan(π/8)].
  static double _atanPoly(double t) {
    final t2 = t * t;
    return t *
        (1.0 +
            t2 *
                (_a3 +
                    t2 *
                        (_a5 +
                            t2 *
                                (_a7 +
                                    t2 *
                                        (_a9 +
                                            t2 *
                                                (_a11 +
                                                    t2 *
                                                        (_a13 +
                                                            t2 *
                                                                (_a15 +
                                                                    t2 *
                                                                        (_a17 +
                                                                            t2 *
                                                                                (_a19 + t2 * (_a21 + t2 * _a23)))))))))));
  }

  /// atan(t) for t in [0, 1].
  static double _atanUnit(double t) {
    if (t > _tanEighthPi) {
      // atan(t) = π/4 + atan((t − 1) / (t + 1)); the argument is in
      // (−tan(π/8), 0].
      return quarterPi + _atanPoly((t - 1.0) / (t + 1.0));
    }
    return _atanPoly(t);
  }

  /// sin(x) for any finite x, |error| < 1e-6.
  static double sin(double x) {
    var r = _reduce(x);
    if (r > halfPi) {
      r = pi - r;
    } else if (r < -halfPi) {
      r = -pi - r;
    }
    return _sinPoly(r);
  }

  /// cos(x) for any finite x, |error| < 1e-6.
  static double cos(double x) {
    var r = _reduce(x);
    if (r < 0) r = -r;
    if (r > halfPi) return -_cosPoly(pi - r);
    return _cosPoly(r);
  }

  /// atan2(y, x) in (-pi, pi], |error| < 1e-6. atan2(0, 0) == 0.
  ///
  /// Unlike `dart:math`, a negative zero `y` is treated as +0, so the result
  /// for `x < 0, y == 0` is always +π (never −π).
  static double atan2(double y, double x) {
    if (x == 0 && y == 0) return 0;
    final ax = x < 0 ? -x : x;
    final ay = y < 0 ? -y : y;
    double a;
    if (ay <= ax) {
      a = _atanUnit(ay / ax);
    } else {
      a = halfPi - _atanUnit(ax / ay);
    }
    if (x < 0) a = pi - a;
    if (y < 0) a = -a;
    return a;
  }

  /// Normalizes an angle into [0, tau).
  static double normAngle(double a) {
    var r = a - tau * (a * invTau).floorToDouble();
    if (r >= tau) r -= tau;
    if (r < 0) r += tau;
    if (r >= tau) r = 0;
    return r;
  }

  /// Signed shortest difference `target - from` in (-pi, pi].
  static double angleDiff(double target, double from) {
    final d = target - from;
    var r = d - tau * (d * invTau + 0.5).floorToDouble();
    if (r <= -pi) r += tau;
    if (r > pi) r -= tau;
    return r;
  }
}
