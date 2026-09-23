/// One rule, one implementation: the initials drawn inside a circle
/// (INB-1, INB-2, INB-8).
///
/// Two surfaces draw a circle with initials in it — INB-1's leading circle on
/// an inbox row, over a conversation title, and INB-8's sender circle beside an
/// inbound bubble in a group thread, over a sender's name. They are the same
/// question about different strings, so they are one function here rather than
/// a copy each.
///
/// It lives beside `normalise` and not on the inbox's row object, for the
/// reason the copy existed at all: a pure text rule on the list's view model is
/// something the thread can only reach by importing the list, and the thread
/// has nothing to do with the list. `models/` is the layer both a provider and
/// a widget may import, which is what lets there be one of these.
///
/// **The copy is why this file exists.** `_SenderAvatar._initials` in
/// `widgets/message_bubble.dart` was a deliberate private copy of
/// `InboxRow.initialsOf`, and when the 23 September 2026 drill's
/// nonsense-initials fix corrected the original it was not carried across — so
/// a group thread whose sender is a phone number still drew `(1`, one screen
/// deeper than the bug that was reported. That is the same shape as INB-1's
/// label chain, which was four copies and one branch out of date in each; the
/// answer there was `sourceAppLabel` and the answer here is this.
library;

/// The first *letter* of each of the first two words of [name], upper-cased.
///
/// A word with no letter in it contributes nothing, and a name with no letters
/// at all yields no initials — so the circle falls to INB-2's treatment for a
/// circle with nothing to draw in it: the app icon alone on an inbox row
/// (`SourceAppAvatar` draws that whenever the initials are empty), and an empty
/// circle beside a bubble. INB-1 says "up to two initials", and nought is one of
/// the numbers up to two.
///
/// This is a decision INB-1 does not make, so here is the reasoning. A phone
/// number is a name with no name in it, and the device drill of 23 September
/// 2026 found `(555) 123-0003` drawn as `(1`, which is not the conversation's
/// initials, not a number, and not anything a person would recognise — it is
/// two characters of punctuation and arithmetic standing where a name should
/// be. Taking the first character of the word made that inevitable: the first
/// character of a word is only an initial when it is a letter. Digits are
/// excluded on the same grounds — `51` for `(555) 123-0003` would be exactly as
/// meaningless — and both surfaces still show the whole name beside the circle,
/// so nothing is lost by drawing no guess. On an inbox row the conversation is
/// *not* unnamed (INB-2's `conversationUnnamed` line is conditioned on an empty
/// title and stays off): it has a name, and its name simply has no initials.
///
/// The match is over whole code points, so a name starting outside the Basic
/// Multilingual Plane yields one whole character instead of half a surrogate
/// pair.
String initialsOf(String name) {
  final StringBuffer out = StringBuffer();
  int taken = 0;
  for (final String word in name.trim().split(RegExp(r'\s+'))) {
    final Match? letter = _letter.firstMatch(word);
    if (letter == null) continue;
    out.write(letter[0]!.toUpperCase());
    if (++taken == 2) break;
  }
  return out.toString();
}

/// Any letter, in any script (`\p{L}`), matched as a whole code point.
final RegExp _letter = RegExp(r'\p{L}', unicode: true);
