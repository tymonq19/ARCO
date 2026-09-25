/// Nickname filtering (SPEC §4.7): offensive names are refused at submission
/// time, and ordinary names — Polish ones with diacritics included, and names
/// that merely contain an unfortunate substring — are not.
///
/// The second half is the harder requirement and gets the longer list. A filter
/// that rejects Cassandra, Essex, Nigeria and Michał is worse than no filter:
/// the player cannot tell what is wrong, and the name they were given at birth
/// is the thing being refused.
library;

import 'dart:convert';

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

/// Names that must go through untouched.
///
/// Three kinds, deliberately mixed: ordinary given names and surnames (Polish
/// ones with every diacritic Polish has), names that contain a blocked string as
/// a substring (Kassandra, Essex, Cumming, Scunthorpe, Shiitake), and names that
/// a careless fold would turn into one (Nigeria and Nigar via run-collapsing,
/// Bob via `boob`, a one-letter token via `kkk`).
const List<String> innocentNames = [
  // Unfortunate substrings, English.
  'Kassandra', 'Cassidy', 'Bassam', 'Hassan', 'Assunta', 'Assisi', 'Passion',
  'Class', 'Glass', 'Brass', 'Massey', 'Essex', 'Sussex', 'Middlesex',
  'Cumming', 'Cumbria', 'Titus', 'Tito', 'Titanic', 'Petit', 'Dickinson',
  'Hancock', 'Babcock', 'Cockburn', 'Scunthorpe', 'Penistone', 'Shiitake',
  'Draper', 'Grape', 'Fagan', 'Spicer', 'Arsen', 'Slutsky', 'Fukuda', 'Fukui',
  'Hoekstra', 'Shoe', 'Wankel', 'Prickett', 'Homolka', 'Analia', 'Anusha',
  'Nazim', 'Nazir', 'Nazia', 'Negroni', 'Semen', 'Kike', 'Pedro', 'Pedrosa',
  // Names a careless fold would break.
  'Nigeria', 'Nigerian', 'Niger', 'Nigar', 'Bob', 'K Pawel', 'Lilia', 'Anna',
  // Thai names, which are why `porn` is word-bounded.
  'Pornthip', 'Supaporn',
  // Polish, with every diacritic the language has.
  'Łukasz', 'Żaneta', 'Zbigniew', 'Małgosia', 'Michał', 'Paweł', 'Grzegorz',
  'Agnieszka', 'Przemek', 'Kasia', 'Zosia', 'Hania', 'Jędrzej', 'Bożena',
  'Wojtek', 'Mateusz', 'Szymon', 'Bartek', 'Krzysiek', 'Iwona', 'Sławek',
  'Włodek', 'Elżbieta', 'Katarzyna', 'Aleksandra', 'Dominika', 'Weronika',
  'Natalia', 'Oliwia', 'Antoni', 'Nikola', 'Milena', 'Marcin', 'Rafał',
  'Ździsław', 'Ciotka', 'Szmatka', 'Chinka', 'Hujar', 'Sikorski',
  // Ordinary nicknames.
  'Ada', 'Tymek', 'Arco', 'Player 1', 'Ala ma kota', 'Żółw_9-x', 'xX_Ada_Xx',
  'AA', 'Xi', 'Ng', 'Dupont', 'Dupuis', 'Jebediah', 'Jeb', 'Analytics',
];

/// Names that must be refused, including the evasions the filter claims to fold
/// away: case, separators, diacritics, digit substitution, repeated characters.
const List<String> offensiveNames = [
  'fuck',
  'FUCK',
  'FuCk',
  'f u c k',
  'f-u-c-k',
  'f_u_c_k',
  'fuuuuck',
  'fuck you',
  'fvck',
  'phuck',
  'motherfuck',
  'sh1t',
  '5h1t',
  'shiiit',
  'bullshit',
  'bitch',
  'b1tch',
  '8itch',
  'biatch',
  'kurwa',
  'KURWA',
  'kurwą',
  'kurva',
  'k u r w a',
  'skurwysyn',
  'skurwiel',
  'chuj',
  'CHUJ',
  'chujowy',
  'chuj3m',
  'huj',
  'pizda',
  'cipa',
  'pedał',
  'PEDAL',
  'ped4l',
  'kutas',
  'dupa',
  'ciota',
  'suka',
  'murzyn',
  'jebac',
  'jebać',
  'jebany',
  'jebnij',
  'zjeb',
  'pojeb',
  'wyjeb',
  'pierdol',
  'spierdalaj',
  'wypierdalaj',
  'cwel',
  'szmata',
  'dziwka',
  'debil',
  'ruchac',
  'czarnuch',
  'pedofil',
  'nigger',
  'n1gger',
  'ni66er',
  'ni99er',
  'nigga',
  'faggot',
  'f4gg0t',
  'fag',
  'F4G',
  'Fag69',
  '69fag',
  'homo',
  'negro',
  'spic',
  'gook',
  'chink',
  'tranny',
  'wetback',
  'retard',
  'nazi',
  'NAZI',
  'Nazi 1',
  'heil',
  'kkk',
  'hitler',
  'nazism',
  'ass',
  'a s s',
  'Ass69',
  'anal',
  'anus',
  'arse',
  'asshole',
  'arsehole',
  'sex',
  'cum',
  'dick',
  'cock',
  'prick',
  'wank',
  'tits',
  'slut',
  's1ut',
  'crap',
  'hoe',
  'porn',
  'rape',
  'rapist',
  'whore',
  'twat',
  'cunt',
  'penis',
  'vagina',
  'pussy',
  'boob',
  'dildo',
  'jizz',
  'skank',
  'incest',
  'molest',
  'bastard',
  'fuk',
];

void main() {
  group('ordinary names are not caught (SPEC §4.7)', () {
    test('every name on the false-positive list passes', () {
      final caught = <String>[];
      for (final name in innocentNames) {
        final hit = offensiveNamePattern(name);
        if (hit != null) caught.add('$name (matched "$hit")');
      }
      expect(
        caught,
        isEmpty,
        reason:
            'a filter that refuses these is worse than no filter: the player '
            'cannot tell what is wrong, and it is their own name',
      );
    });

    test('and every one of them is a valid name to begin with', () {
      // Otherwise the list above would be proving nothing: §4.2 would already
      // have rejected them.
      for (final name in innocentNames) {
        expect(normalizeName(name), isNotNull, reason: name);
      }
    });

    test('the named collisions are each rescued by a named mechanism', () {
      // Word-bounding, not the allowlist: the substring is real, the word is not.
      expect(offensiveNamePattern('Kassandra'), isNull);
      expect(offensiveNamePattern('ass'), 'ass');
      expect(offensiveNamePattern('Essex'), isNull);
      expect(offensiveNamePattern('sex'), 'sex');

      // The allowlist, for substring entries that a real word does contain.
      expect(offensiveNamePattern('Scunthorpe'), isNull);
      expect(offensiveNamePattern('cunt'), 'cunt');
      expect(offensiveNamePattern('Penistone'), isNull);
      expect(offensiveNamePattern('penis'), 'penis');
      // Shiitake only collides once runs are collapsed ("shitake").
      expect(offensiveNamePattern('Shiitake'), isNull);
      expect(offensiveNamePattern('shiiit'), 'shit');

      // `collapse: false`, because the collapsed form is a real word.
      expect(collapseRuns(foldName('nigger')), 'niger');
      expect(offensiveNamePattern('Nigeria'), isNull);
      expect(offensiveNamePattern('Nigar'), isNull);
      expect(offensiveNamePattern('nigger'), 'nigger');
      expect(offensiveNamePattern('Fagot'), isNull, reason: 'PL: bassoon');
      expect(offensiveNamePattern('faggot'), 'faggot');

      // The minimum collapsed length, because `boob` collapses to `bob` and
      // `kkk` collapses to `k`.
      expect(collapseRuns(foldName('boob')), 'bob');
      expect(minCollapsedPatternLength, greaterThan(3));
      expect(offensiveNamePattern('Bob'), isNull);
      expect(offensiveNamePattern('K Pawel'), isNull);
      expect(offensiveNamePattern('boob'), 'boob');
      expect(offensiveNamePattern('kkk'), 'kkk');
    });

    test('masking an innocent word cannot glue a blocked one together', () {
      // The allowlist replaces with a separator, not with nothing, so the
      // letters either side of it never become neighbours.
      expect(offensiveNamePattern('funigerck'), isNull);
      expect(offensiveNamePattern('fu niger ck'), isNull);
      // And a blocked word that merely sits next to an allowlisted one still
      // matches.
      expect(offensiveNamePattern('nigeriafuck'), 'fuck');
      expect(offensiveNamePattern('scunthorpefuck'), 'fuck');
    });
  });

  group('offensive names are caught, through the obvious evasions', () {
    test('every name on the blocked list is refused', () {
      final missed = [
        for (final name in offensiveNames)
          if (offensiveNamePattern(name) == null) name,
      ];
      expect(missed, isEmpty);
    });

    test('case, diacritics and digits fold onto the pattern', () {
      expect(foldName('KURWĄ'), 'kurwa');
      expect(foldName('PEDAŁ'), 'pedai', reason: 'ł folds into the i/l class');
      expect(foldName('5h1t'), 'shit');
      expect(foldName('ni66er'), 'nigger');
      expect(foldName('F4G'), 'fag');
      expect(foldName('Żółw'), 'zoiw');
    });

    test('separators are removed before a substring match', () {
      expect(offensiveNamePattern('k u r w a'), 'kurw');
      expect(offensiveNamePattern('k-u-r-w-a'), 'kurw');
      expect(offensiveNamePattern('k_u_r_w_a'), 'kurw');
      // A word-bounded entry also matches the whole name once joined.
      expect(offensiveNamePattern('a s s'), 'ass');
    });

    test('repeated characters collapse', () {
      expect(collapseRuns('fuuuuck'), 'fuck');
      expect(offensiveNamePattern('fuuuuuuck'), 'fuck');
      expect(offensiveNamePattern('kurrrwa'), 'kurw');
    });

    test('a word-bounded entry survives leading and trailing digits', () {
      expect(offensiveNamePattern('Ass69'), 'ass');
      expect(offensiveNamePattern('69fag'), 'fag');
      expect(offensiveNamePattern('Nazi 1'), 'nazi');
      // But not a name that merely ends in digits.
      expect(offensiveNamePattern('Kasia69'), isNull);
    });
  });

  group('the lists themselves', () {
    test('every entry is plain lowercase ASCII and appears once', () {
      final seen = <String>{};
      for (final entry in blockedNames) {
        expect(
          entry.pattern,
          matches(r'^[a-z]+$'),
          reason: 'patterns are folded before use, so write them plainly',
        );
        expect(
          seen.add(entry.pattern),
          isTrue,
          reason: 'duplicate entry: ${entry.pattern}',
        );
      }
      expect(blockedNames, hasLength(greaterThan(50)));
      expect(englishBlockedNames, isNotEmpty);
      expect(polishBlockedNames, isNotEmpty);
    });

    test('no substring entry is short enough to be a syllable', () {
      // A three-letter substring entry is how a filter ends up refusing
      // Cassandra. Short entries have to be `whole: true`.
      for (final entry in blockedNames.where((e) => !e.whole)) {
        expect(
          entry.pattern.length,
          greaterThanOrEqualTo(4),
          reason: '${entry.pattern} must be whole: true to be this short',
        );
      }
    });

    test('every allowlist entry is a name §4.2 would accept', () {
      for (final word in innocentSubstrings) {
        expect(normalizeName(word), isNotNull, reason: word);
      }
    });
  });

  group('over HTTP', () {
    late ArcoServer server;
    late Replay replay;

    setUpAll(() {
      replay = recordSoloReplay(seed: 20260923);
      expect(ReplayVerifier.verify(replay).ok, isTrue);
    });

    setUp(() async {
      server = await bootServer();
    });

    Uri api(String path) => Uri.parse('${server.baseUrl}$path');

    Map<String, dynamic> decode(http.Response r) =>
        jsonDecode(r.body) as Map<String, dynamic>;

    Future<http.Response> submit(String name) => http.post(
      api('/api/scores'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(scoreBody(name, replay)),
    );

    test(
      'POST /api/scores refuses an offensive name and stores nothing',
      () async {
        for (final name in ['Kurwa', 'FuCk You', 'ni66er', 'Ass69']) {
          final r = await submit(name);
          expect(r.statusCode, 400, reason: '$name: ${r.body}');
          expect(decode(r)['ok'], isFalse);
          expect(decode(r)['error'], offensiveNameError);
          expect(
            decode(r).containsKey('detail'),
            isFalse,
            reason:
                'which entry matched is a tuning hint for the next attempt, so '
                'it stays in the log',
          );
        }

        final list = await http.get(api('/api/leaderboard'));
        expect(
          (decode(list)['entries'] as List<dynamic>),
          isEmpty,
          reason: 'a refused name means a refused run',
        );
        expect(await server.store.count(), 0);
      },
    );

    test('POST /api/scores still accepts ordinary and Polish names', () async {
      for (final name in ['Ada', 'Małgosia', 'Kassandra', 'Żółw_9-x']) {
        final r = await submit(name);
        expect(r.statusCode, 201, reason: '$name: ${r.body}');
      }
      final list = await http.get(api('/api/leaderboard'));
      expect((decode(list)['entries'] as List<dynamic>), hasLength(4));
    });

    test('the §4.2 rules are unchanged, and separate', () async {
      // Still `invalid_name`, not `offensive_name`: too short, and a character
      // the name grammar never allowed.
      expect(decode(await submit('x'))['error'], 'invalid_name');
      expect(decode(await submit('bad!!name'))['error'], 'invalid_name');
    });

    test('POST /api/players refuses an offensive preset name', () async {
      final r = await http.post(
        api('/api/players'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'name': 'Kurwa'}),
      );
      expect(r.statusCode, 400, reason: r.body);
      expect(decode(r)['error'], offensiveNameError);
      expect(
        await server.store.playerCount(),
        0,
        reason: 'a name the player could never submit under issues no player',
      );

      final ok = await http.post(
        api('/api/players'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'name': 'Małgosia'}),
      );
      expect(ok.statusCode, 201, reason: ok.body);
      expect(decode(ok)['name'], 'Małgosia');
    });
  });
}
