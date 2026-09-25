/// xoshiro128** PRNG on 32-bit unsigned ints; identical on VM and JS.
/// See SPEC.md §2.1.
///
/// Every intermediate value stays below 2^53 so the generator produces the
/// same sequence when Dart ints are JavaScript doubles: multiplications go
/// through [Prng.mul32] (16-bit halves), shifts are masked, and right shifts
/// are only applied to non-negative 32-bit values.
library;

const int _mask32 = 0xFFFFFFFF;
const int _mask16 = 0xFFFF;

class Prng {
  /// Seeds the generator; the four state words are derived from [seed] via splitmix32.
  Prng(int seed) : s0 = 0, s1 = 0, s2 = 0, s3 = 0 {
    var state = seed & _mask32;
    state = _splitmixAdvance(state);
    s0 = _splitmixOutput(state);
    state = _splitmixAdvance(state);
    s1 = _splitmixOutput(state);
    state = _splitmixAdvance(state);
    s2 = _splitmixOutput(state);
    state = _splitmixAdvance(state);
    s3 = _splitmixOutput(state);
    // xoshiro must never be seeded with the all-zero state (it would stay
    // there forever). Unreachable with splitmix32 in practice, but cheap.
    if (s0 == 0 && s1 == 0 && s2 == 0 && s3 == 0) s0 = 1;
  }

  Prng.fromState(this.s0, this.s1, this.s2, this.s3);

  int s0, s1, s2, s3;

  /// 32-bit multiply without exceeding 2^53 in intermediates (JS-safe).
  ///
  /// Splits both operands into 16-bit halves: the low×low product is below
  /// 2^32 and the cross products contribute only their low 16 bits shifted
  /// by 16, so every partial sum stays below 2^33.
  static int mul32(int a, int b) {
    final aLo = a & _mask16;
    final aHi = (a >> 16) & _mask16;
    final bLo = b & _mask16;
    final bHi = (b >> 16) & _mask16;
    final lo = aLo * bLo;
    final mid = (aLo * bHi + aHi * bLo) & _mask16;
    return (lo + mid * 65536) & _mask32;
  }

  /// Rotate-left on a 32-bit value using masked shifts.
  static int rotl32(int x, int k) =>
      ((x << k) & _mask32) | ((x & _mask32) >> (32 - k));

  static int _splitmixAdvance(int state) => (state + 0x9E3779B9) & _mask32;

  /// splitmix32 output function (bryc's constants).
  static int _splitmixOutput(int state) {
    var z = state ^ (state >> 16);
    z = mul32(z, 0x21F0AAAD);
    z ^= z >> 15;
    z = mul32(z, 0x735A2D97);
    z ^= z >> 15;
    return z;
  }

  int nextUint32() {
    final result = mul32(rotl32(mul32(s1, 5), 7), 9);
    final t = (s1 << 9) & _mask32;
    s2 ^= s0;
    s3 ^= s1;
    s1 ^= s2;
    s0 ^= s3;
    s2 ^= t;
    s3 = rotl32(s3, 11);
    return result;
  }

  /// Uniform double in [0, 1) built from the top 24 bits.
  double nextDouble() => (nextUint32() >> 8) / 16777216.0;

  /// Uniform int in [0, n).
  ///
  /// Uses the simple modulo reduction: for the small ranges the simulation
  /// needs (n ≤ a few thousand) the bias is below 1e-6 and irrelevant for
  /// gameplay, while the single-draw cost keeps rng consumption predictable.
  int nextInt(int n) {
    if (n <= 0) throw ArgumentError.value(n, 'n', 'must be positive');
    return nextUint32() % n;
  }

  double nextRange(double a, double b) => a + (b - a) * nextDouble();

  Prng clone() => Prng.fromState(s0, s1, s2, s3);

  List<int> toJson() => [s0, s1, s2, s3];

  factory Prng.fromJson(List<dynamic> j) =>
      Prng.fromState(j[0] as int, j[1] as int, j[2] as int, j[3] as int);
}
