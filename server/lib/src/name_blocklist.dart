/// The word lists behind the nickname filter (SPEC §4.7). Data only — the
/// matching logic lives in `name_filter.dart`, so this file can be extended
/// without touching code, and a change here is reviewable as a change to a list.
///
/// ## What belongs here
///
/// Profanity, sexual terms, slurs and hate references — the things that get an
/// app pulled from review or shown to a ten-year-old. **Not** mild insults
/// (`idiot`, `kretyn`, `loser`): they are endless, they read as ordinary
/// teasing, and every one of them costs false positives. The board is filtered,
/// not polite.
///
/// ## How an entry is matched
///
/// The name is folded first (lowercase, diacritics stripped, `0→o 1→i/l 3→e
/// 4→a 5→s 6→g 7→t 8→b 9→g`, separators dropped, runs of one character
/// collapsed) — see `name_filter.dart` for the exact steps. Patterns are folded
/// through the *same* function, so write them in plain lowercase ASCII and the
/// fold takes care of `kurwą`, `PEDAŁ` and `sh1t`.
///
/// * default (`whole: false`) — the pattern matches **anywhere** in the name
///   with every separator removed, so `k-u-r-w-a` and `xxkurwaxx` both match.
///   Use it only when no real name can contain the pattern.
/// * `whole: true` — the pattern must be a whole word (a token of the name, or
///   the entire name once separators are dropped). This is the answer to the
///   Scunthorpe problem: `ass` as a substring insults every Cassandra, Hassan
///   and Bassam, so it is word-bounded and `Ass69` gets through instead. Short
///   and ambiguous entries belong here; the comment on each says which real
///   name forced it.
/// * `collapse: false` — skip the run-collapsed view for this pattern, because
///   its collapsed form is a legitimate word: `nigger → niger` would insult
///   every Nigerian, `faggot → fagot` is Polish for bassoon. The cost is that
///   `niggger` is not caught. That trade is not close.
///
/// A pattern whose collapsed form is shorter than
/// [minCollapsedPatternLength] is never matched against the collapsed view at
/// all, which is why `boob → bob` does not block Bob and `kkk → k` does not
/// block a nickname of `K Pawel`.
///
/// ## Judgement calls, recorded so they are not re-litigated by accident
///
/// * `kike` is **not** listed: it is a real slur, but `Kike` is also an ordinary
///   Spanish short form of Enrique, and blocking every one of them to catch a
///   word nobody spells that way by accident is a net loss.
/// * `murzyn` **is** listed, word-bounded. It is offensive in current Polish
///   usage; it is also a rare Polish surname, and someone called Murzyn will
///   have to pick another nickname. A leaderboard visible to children is the
///   wrong place to hold that line.
/// * `semen`, `tit` and `porn` as substrings are absent or word-bounded because
///   Semen (Ukrainian given name), Titus and the very common Thai `-porn` names
///   (Pornthip, Supaporn) are more numerous than the evasions they would catch.
library;

/// One entry of the blocklist. See the library comment for the three knobs.
class BlockedName {
  const BlockedName(this.pattern, {this.whole = false, this.collapse = true});

  /// Plain lowercase ASCII; folded through the filter's own fold before use.
  final String pattern;

  /// Match only a whole token (or the whole name), not any substring.
  final bool whole;

  /// Also match the run-collapsed view (`fuuuck` → `fuck`).
  final bool collapse;
}

/// English entries.
const List<BlockedName> englishBlockedNames = [
  // Profanity with no innocent host word.
  BlockedName('fuck'),
  BlockedName('fvck'), // the vowel-swap evasion, with no innocent host word
  BlockedName('phuck'),
  BlockedName('shit'),
  BlockedName('bitch'),
  BlockedName('biatch'),
  BlockedName('bastard'),
  BlockedName('whore'),
  BlockedName('twat'),
  BlockedName('cunt'), // Scunthorpe is in [innocentSubstrings].
  BlockedName('asshole'),
  BlockedName('arsehole'),
  // Sexual.
  BlockedName('penis'), // Penistone is in [innocentSubstrings].
  BlockedName('vagina'),
  BlockedName('pussy'),
  BlockedName('boob'),
  BlockedName('dildo'),
  BlockedName('blowjob'),
  BlockedName('handjob'),
  BlockedName('jizz'),
  BlockedName('skank'),
  BlockedName('rapist'),
  BlockedName('incest'),
  BlockedName('molest'),
  BlockedName('pedophile'),
  // Slurs and hate.
  BlockedName('nigger', collapse: false), // collapses to "niger".
  BlockedName(
    'nigga',
    collapse: false,
  ), // collapses to "niga"; Nigar is a name.
  BlockedName('chink'),
  BlockedName('wetback'),
  BlockedName('faggot', collapse: false), // collapses to "fagot" (PL: bassoon).
  BlockedName('tranny'),
  BlockedName('retard'),
  BlockedName('nazism'),
  BlockedName('hitler'),
  // Word-bounded: each of these, as a substring, hits ordinary names.
  BlockedName('ass', whole: true), // Cassandra, Hassan, Bassam, Assunta
  BlockedName('arse', whole: true), // Arsen, Arsenio
  BlockedName('anal', whole: true), // Analia
  BlockedName('anus', whole: true), // Anusha, Anush
  BlockedName('sex', whole: true), // Essex, Sexton
  BlockedName('cum', whole: true), // Cumming, Cumberbatch
  BlockedName('dick', whole: true), // Dickinson, Dickens, Benedick
  BlockedName('cock', whole: true), // Hancock, Cockburn
  BlockedName('prick', whole: true), // Prickett
  BlockedName('wank', whole: true), // Wankel, Wanke
  BlockedName('tits', whole: true), // Titsworth
  BlockedName('slut', whole: true), // Slutsky
  BlockedName('fuk', whole: true), // Fukuda, Fukui, Fukuyama
  BlockedName('crap', whole: true), // Crapper, Scrapper
  BlockedName('hoe', whole: true), // Hoekstra, Hoeven
  BlockedName('porn', whole: true), // Pornthip, Supaporn, Pornsak
  BlockedName('rape', whole: true), // Draper, Grape
  BlockedName('fag', whole: true), // Fagan, Fagin, Faggioli
  BlockedName('homo', whole: true), // Homolka
  BlockedName('negro', whole: true), // Negro, Del Negro
  BlockedName('spic', whole: true), // Spicer, Spice
  BlockedName('gook', whole: true), // Gook
  BlockedName('nazi', whole: true), // Nazir, Nazim, Nazia, Nazish
  BlockedName('heil', whole: true), // Heiliger
  BlockedName('kkk', whole: true),
];

/// Polish entries. Diacritics need no special spelling: `pedał`, `kurwą` and
/// `jebać` all fold onto the ASCII patterns below.
const List<BlockedName> polishBlockedNames = [
  // Profanity. Substring-safe: these stems do not occur in Polish names.
  BlockedName('kurw'), // kurwa, kurwy, skurwysyn, skurwiel
  BlockedName('kurv'), // the Slovak/Hungarian spelling, used in Polish chats
  BlockedName('chuj'), // chuj, chujowy, chujnia
  BlockedName('pizd'), // pizda, pizdy
  BlockedName('cipa'),
  BlockedName('cwel'),
  BlockedName('szmata'),
  BlockedName('dziwk'), // dziwka, dziwki
  BlockedName('pierdol'), // pierdolić, opierdolić
  BlockedName('pierdal'), // spierdalaj, wypierdalaj
  BlockedName('ruchac'), // ruchać
  BlockedName('debil'),
  BlockedName('pedofil'),
  BlockedName('czarnuch'),
  // Stems of "jebać" spelled out rather than one "jeb", which would also hit
  // Jeb and Jebediah.
  BlockedName('jebac'),
  BlockedName('jeban'), // jebany, jebana
  BlockedName('jebal'), // jebał
  BlockedName('jebie'),
  BlockedName('jebn'), // jebnąć
  BlockedName('zjeb'),
  BlockedName('pojeb'),
  BlockedName('wyjeb'),
  // Word-bounded: a real word or a real surname shares the spelling.
  BlockedName('huj', whole: true), // Hujar, Hujda
  BlockedName('kutas', whole: true), // Kutas (surname)
  BlockedName('dupa', whole: true), // Dupas
  BlockedName('pedal', whole: true), // pedał: also a bicycle pedal
  BlockedName('ciota', whole: true), // ciotka (aunt) is ordinary
  BlockedName('suka', whole: true), // Sukarno
  BlockedName('murzyn', whole: true), // see the library comment
];

/// Every blocked entry, in the order the filter tries them.
const List<BlockedName> blockedNames = [
  ...englishBlockedNames,
  ...polishBlockedNames,
];

/// Innocent strings that must survive a substring match: each is masked out of
/// the name before the blocklist is tried (SPEC §4.7).
///
/// One entry per real collision, with the pattern it rescues. Masking replaces
/// the string with a separator rather than deleting it, so it cannot be used to
/// glue a blocked word back together: `nigeriafuck` still matches `fuck`, and
/// `fu` + `niger` + `ck` does not.
const List<String> innocentSubstrings = [
  'chinka', // chink — the ordinary Polish word for a Chinese woman
  'scunthorpe', // cunt
  'penistone', // penis
  'shiitake', // shit, via the run-collapsed view ("shitake")
  'niger', // guards the run-collapsed view if `nigger` ever gets collapse: true
  'nigeria',
  'nigerian',
  'nigerien',
];
