/// Best-effort nickname filtering (SPEC §4.7).
///
/// SPEC §4.2 only ever asked whether a name is 2–12 characters of letters,
/// digits, space, `_` and `-`. That is a validity rule, not a moderation rule:
/// `Kurwa` and every English four-letter word passed it. A worldwide board that
/// children see — and that Apple and Google review — needs the second rule, so a
/// submission whose name matches the blocklist is refused with
/// [offensiveNameError] and nothing is stored.
///
/// The word lists live in `name_blocklist.dart` and the flags on each entry are
/// documented there. This file is the matching, and it is deliberately the
/// smaller half.
///
/// ## What it catches
///
/// The name is reduced to a skeleton before matching, which folds away the
/// evasions people actually use:
///
/// * case (`KURWA`);
/// * diacritics, Polish included (`Chuj`, `PEDAŁ`, `kurwą`);
/// * digit substitution (`5h1t`, `f4g`, `ni66er`, `8itch`), with `1` folded to
///   the same class as both `i` and `l` so `s1ut` reaches `slut`;
/// * separators (`f u c k`, `f-u-c-k`, `k_u_r_w_a`), because every space, `_`
///   and `-` is removed before a substring match;
/// * repeated characters (`fuuuuck`, `shiiit`), via a second run-collapsed view;
/// * leading and trailing digits on a word-bounded entry (`Ass69`, `69fag`).
///
/// ## What it does not catch, and why that is the right trade
///
/// * **Homoglyphs from another script.** SPEC §4.2 allows any Unicode letter, so
///   `хуй` in Cyrillic or `ᏟႮΝᎢ` in Cherokee/Greek look-alikes goes through.
///   Folding confusables back to Latin would mean rewriting genuine Russian,
///   Greek and Georgian names into Latin strings and matching *those* against a
///   profanity list, which is a false-positive machine. A list of full offensive
///   words in other scripts is the honest way to extend this, not a confusable
///   table.
/// * **Repeated letters inside an entry marked `collapse: false`** (`niggger`).
///   Its collapsed form is a real word; see `name_blocklist.dart`.
/// * **Decorated word-bounded entries** (`Ass.69` is impossible under §4.2, but
///   `xAssx` is not). Word-bounding is what stops the filter insulting every
///   Cassandra, and that is worth more than catching `xAssx`.
/// * **Anything not on the list**: new slang, misspellings nobody predicted,
///   another language. The list is extensible precisely because this will
///   happen; the filter is a floor, not a guarantee.
///
/// Both halves of that are why the filter runs **only on the server**. Shipping
/// the list in the app would publish it, invite exactly the evasions above, and
/// still be bypassable by anyone posting to `/api/scores` directly.
library;

import 'name_blocklist.dart';

/// The submitted name matched the blocklist (SPEC §4.7). The client shows "pick
/// another nickname"; which word matched is never disclosed, because that is a
/// tuning aid for whoever wrote the name, not information they need.
const String offensiveNameError = 'offensive_name';

/// Shortest collapsed pattern allowed to match the run-collapsed view.
///
/// Collapsing runs is what turns `fuuuuck` into `fuck`, but it also shortens the
/// patterns, and a short pattern matched against a collapsed name is how a
/// filter ends up rejecting `Bob` (`boob` collapses to `bob`) or a nickname of
/// `K Pawel` (`kkk` collapses to `k`). Below this length the collapsed view is
/// simply not consulted; the plain view still is.
const int minCollapsedPatternLength = 4;

/// Characters folded onto one representative, keyed by the representative.
///
/// Digits are folded onto the letters they imitate. `l` shares the `i` class:
/// `1` is used for both, and a single fold cannot be two things, so the two
/// letters become one. `Michał` folds to `michai`, which matches nothing — the
/// cost of the class is a slightly lossier skeleton, and the gain is that `s1ut`
/// and `shlt` both land on a pattern.
const Map<String, String> _foldGroups = {
  'a': '4@àáâãäåāăąæ',
  'b': '8ƀ',
  'c': 'çćĉċč¢',
  'd': 'ďđð',
  'e': '3èéêëēĕėęě',
  'g': '69ĝğġģ',
  'i': r'1!|lìíîïĩīĭįıłĺļľ',
  'j': 'ĵ',
  'h': 'ĥħ',
  'k': 'ķ',
  'n': 'ñńņňŉŋ',
  'o': r'0òóôõöøōŏő°œ',
  'r': 'ŕŗř',
  's': r'5$śŝşšß',
  't': '7+ţťŧþ',
  'u': 'ùúûüũūŭůűų',
  'w': 'ŵ',
  'y': 'ýÿŷ',
  'z': 'źżž',
};

/// Code point → code point, built once from [_foldGroups] (top-level finals are
/// lazy in Dart, so this costs nothing until the first name is checked).
final Map<int, int> _foldTable = {
  for (final group in _foldGroups.entries)
    for (final rune in group.value.runes) rune: group.key.codeUnitAt(0),
};

/// [innocentSubstrings], folded and longest first, for the plain view.
final List<String> _maskPlain = _byLengthDesc([
  for (final word in innocentSubstrings) foldName(word),
]);

/// [innocentSubstrings], folded and run-collapsed, for the collapsed view.
final List<String> _maskCollapsed = _byLengthDesc([
  for (final word in innocentSubstrings) collapseRuns(foldName(word)),
]);

List<String> _byLengthDesc(List<String> words) =>
    words.where((w) => w.isNotEmpty).toList()
      ..sort((a, b) => b.length.compareTo(a.length));

/// Lowercases [raw] and folds every character in [_foldGroups] onto its
/// representative. Length is preserved, so nothing here can turn a short name
/// into a long one.
String foldName(String raw) {
  final out = StringBuffer();
  for (final rune in raw.toLowerCase().runes) {
    out.writeCharCode(_foldTable[rune] ?? rune);
  }
  return out.toString();
}

/// Collapses every run of one character to a single one: `fuuuuck` → `fuck`.
String collapseRuns(String value) {
  final out = StringBuffer();
  int? previous;
  for (final rune in value.runes) {
    if (rune != previous) out.writeCharCode(rune);
    previous = rune;
  }
  return out.toString();
}

/// The four views of a name the blocklist is matched against (SPEC §4.7).
class NameSkeleton {
  const NameSkeleton({
    required this.tokens,
    required this.collapsedTokens,
    required this.joined,
    required this.collapsedJoined,
  });

  /// Folded words of the name, plus a variant of each with its leading and
  /// trailing digits removed, so `Ass69` still offers `ass`. What a
  /// `whole: true` entry is compared against.
  final List<String> tokens;
  final List<String> collapsedTokens;

  /// Every separator removed, then [innocentSubstrings] masked out with a space
  /// — so `f u c k` is one word, while the mask cannot be used to glue a blocked
  /// word back together across it.
  final String joined;
  final String collapsedJoined;
}

/// Reduces [name] to the views [offensiveNamePattern] matches against.
NameSkeleton buildNameSkeleton(String name) {
  final tokens = <String>{};
  final folded = <String>[];
  for (final piece in name.split(RegExp(r'[\s_\-]+'))) {
    if (piece.isEmpty) continue;
    final whole = foldName(piece);
    if (whole.isEmpty) continue;
    folded.add(whole);
    tokens.add(whole);
    final bare = foldName(_stripEdgeDigits(piece));
    if (bare.isNotEmpty) tokens.add(bare);
  }
  final joined = folded.join();
  return NameSkeleton(
    tokens: tokens.toList(growable: false),
    collapsedTokens: {
      for (final token in tokens) collapseRuns(token),
    }.toList(growable: false),
    joined: _mask(joined, _maskPlain),
    collapsedJoined: _mask(collapseRuns(joined), _maskCollapsed),
  );
}

/// The blocklist entry [name] matched, or null when the name is acceptable.
///
/// The pattern is returned for the server log only: it tells whoever tunes the
/// list which entry fired, and it never reaches the client.
String? offensiveNamePattern(String name) {
  final skeleton = buildNameSkeleton(name);
  for (final entry in blockedNames) {
    final pattern = foldName(entry.pattern);
    if (pattern.isEmpty) continue;
    if (entry.whole
        ? skeleton.tokens.contains(pattern) || skeleton.joined == pattern
        : skeleton.joined.contains(pattern)) {
      return entry.pattern;
    }
    if (!entry.collapse) continue;
    final collapsed = collapseRuns(pattern);
    if (collapsed.length < minCollapsedPatternLength) continue;
    if (entry.whole
        ? skeleton.collapsedTokens.contains(collapsed) ||
              skeleton.collapsedJoined == collapsed
        : skeleton.collapsedJoined.contains(collapsed)) {
      return entry.pattern;
    }
  }
  return null;
}

/// Whether [name] must be refused with [offensiveNameError] (SPEC §4.7).
bool isOffensiveName(String name) => offensiveNamePattern(name) != null;

/// Removes leading and trailing ASCII digits: `69fag1` → `fag`.
String _stripEdgeDigits(String value) {
  var start = 0;
  var end = value.length;
  bool digit(int i) {
    final c = value.codeUnitAt(i);
    return c >= 0x30 && c <= 0x39;
  }

  while (start < end && digit(start)) {
    start++;
  }
  while (end > start && digit(end - 1)) {
    end--;
  }
  return value.substring(start, end);
}

/// Replaces each of [words] with a space, longest first.
String _mask(String value, List<String> words) {
  var out = value;
  for (final word in words) {
    out = out.replaceAll(word, ' ');
  }
  return out;
}
