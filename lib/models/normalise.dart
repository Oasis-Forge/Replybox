/// Search normalisation (LANG-4): search ignores case and accents in every
/// language, including the Turkish dotted and dotless i.
///
/// The normalised form is written at capture (CAP-19) and stored beside the
/// original, so searching never has to transform a column at query time and
/// the index is usable.
library;

/// Characters that decompose to a plain letter. Dart's core library has no
/// Unicode normalisation, and pulling a package in for it would be a
/// dependency on the capture path; this table covers the Latin scripts the app
/// ships in plus the Turkish case pairs, and anything outside it is passed
/// through unchanged rather than mangled.
const Map<String, String> _folded = <String, String>{
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'ą': 'a',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'ĉ': 'c',
  'ċ': 'c',
  'ď': 'd',
  'đ': 'd',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ĕ': 'e',
  'ė': 'e',
  'ę': 'e',
  'ě': 'e',
  'ĝ': 'g',
  'ğ': 'g',
  'ġ': 'g',
  'ģ': 'g',
  'ĥ': 'h',
  'ħ': 'h',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ĩ': 'i',
  'ī': 'i',
  'ĭ': 'i',
  'į': 'i',
  'ĵ': 'j',
  'ķ': 'k',
  'ĺ': 'l',
  'ļ': 'l',
  'ľ': 'l',
  'ł': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ņ': 'n',
  'ň': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ō': 'o',
  'ŏ': 'o',
  'ő': 'o',
  'ŕ': 'r',
  'ŗ': 'r',
  'ř': 'r',
  'ś': 's',
  'ŝ': 's',
  'ş': 's',
  'š': 's',
  'ș': 's',
  'ţ': 't',
  'ť': 't',
  'ŧ': 't',
  'ț': 't',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ũ': 'u',
  'ū': 'u',
  'ŭ': 'u',
  'ů': 'u',
  'ű': 'u',
  'ų': 'u',
  'ŵ': 'w',
  'ý': 'y',
  'ÿ': 'y',
  'ŷ': 'y',
  'ź': 'z',
  'ż': 'z',
  'ž': 'z',
  'ß': 'ss',
  'æ': 'ae',
  'œ': 'oe',
  'ð': 'd',
  'þ': 'th',
};

/// Folds [input] for search and comparison.
///
/// Turkish is the reason this cannot be `toLowerCase()` alone. In Turkish the
/// uppercase of `i` is `İ` and the lowercase of `I` is `ı`, so a Turkish user
/// searching "istanbul" must match "İstanbul" and an English user searching
/// "I" must match "i". Folding the dotted and dotless forms to plain `i`
/// before lowercasing makes both true, at the cost of not distinguishing the
/// two letters — which is the right trade for search, where a false match
/// costs a scroll and a missed match costs the feature.
String normalise(String input) {
  if (input.isEmpty) return '';
  // Dotted capital I and dotless lowercase i first, before toLowerCase gets a
  // chance to apply the locale-independent mapping and lose the distinction.
  final String pre = input
      .replaceAll('İ', 'i')
      .replaceAll('I', 'i')
      .replaceAll('ı', 'i');
  final StringBuffer out = StringBuffer();
  for (final int rune in pre.toLowerCase().runes) {
    final String ch = String.fromCharCode(rune);
    out.write(_folded[ch] ?? ch);
  }
  return out.toString();
}
