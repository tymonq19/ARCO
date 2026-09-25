import 'package:arco_core/arco_core.dart';
import 'package:test/test.dart';

void main() {
  // Deseret capital long I: one character, two UTF-16 code units.
  const astral = '\u{10400}';

  group('normalizeName length is counted in characters (SPEC §4.2)', () {
    test('a single astral letter is too short', () {
      expect(astral.length, 2); // guards the premise: 2 UTF-16 code units
      expect(normalizeName(astral), isNull);
    });

    test('astral names of 2..12 characters are accepted', () {
      for (var chars = nameMinLength; chars <= nameMaxLength; chars++) {
        final name = astral * chars;
        expect(
          normalizeName(name),
          name,
          reason: '$chars-character name (${name.length} code units)',
        );
      }
    });

    test('an astral name of 13 characters is too long', () {
      expect(normalizeName(astral * (nameMaxLength + 1)), isNull);
    });

    test('mixed ASCII and astral counts each letter once', () {
      final name = 'Ty${astral * 10}'; // 12 characters, 22 code units
      expect(normalizeName(name), name);
      expect(normalizeName('Tym${astral * 10}'), isNull); // 13 characters
    });
  });

  group('normalizeName keeps the rest of SPEC §4.2', () {
    test('trims and collapses whitespace', () {
      expect(normalizeName('  Ty  mek  '), 'Ty mek');
      expect(normalizeName('a\t\nb'), 'a b');
    });

    test('accepts letters, digits, space, underscore and hyphen', () {
      expect(normalizeName('Żółw_9-x'), 'Żółw_9-x');
    });

    test('rejects too short, too long and disallowed characters', () {
      expect(normalizeName('x'), isNull);
      expect(normalizeName(' a '), isNull);
      expect(normalizeName('a' * (nameMaxLength + 1)), isNull);
      expect(normalizeName('bad!!name'), isNull);
      expect(normalizeName('<script>x</script>'), isNull);
      expect(normalizeName('Bob\u202Eevil'), isNull);
      expect(normalizeName('Bo\u200Bb'), isNull);
    });
  });
}
