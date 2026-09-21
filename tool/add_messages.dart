// Adds, changes, or removes app messages in every ARB file in lib/l10n at
// once (LANG-6), so nobody reads or edits the large files by hand.
//
//   dart tool/add_messages.dart <messages.json>
//
// The input maps each key to its text in every language. English-only
// metadata is optional, and "after" puts a new key next to a related one (a
// new key otherwise goes at the end; an existing key keeps its place):
//
//   {
//     "importDone": {
//       "en": "Imported {count} rows.",
//       "ar": "...", "bn": "...", "zh": "...", "nl": "...", "fr": "...",
//       "de": "...", "el": "...", "hi": "...", "id": "...", "it": "...",
//       "ja": "...", "ko": "...", "pl": "...", "pt": "...", "ru": "...",
//       "es": "...", "th": "...", "tr": "...", "ur": "...", "vi": "...",
//       "description": "Shown after an import.",
//       "placeholders": {"count": {"type": "int"}},
//       "after": "importButton"
//     },
//     "oldMessage": null
//   }
//
// A key set to null is removed. Nothing is written if any message has a
// problem. Run `flutter gen-l10n` afterwards.
import 'dart:convert';
import 'dart:io';

/// Every language that has a `lib/l10n/app_<code>.arb` file, English first.
final languages = [
  'en',
  ...(Directory('lib/l10n')
      .listSync()
      .map((file) => RegExp(r'app_(\w+)\.arb$').firstMatch(file.path)?[1])
      .whereType<String>()
      .where((language) => language != 'en')
      .toList()
    ..sort()),
];
const metadataFields = {'description', 'placeholders'};

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart tool/add_messages.dart <messages.json>');
    exit(64);
  }
  final input = jsonDecode(File(args.single).readAsStringSync());
  if (input is! Map<String, dynamic>) {
    exitWith(['The input must be a JSON object of messages.']);
  }

  final files = {for (final l in languages) l: File('lib/l10n/app_$l.arb')};
  final arbs = {
    for (final l in languages)
      l: jsonDecode(files[l]!.readAsStringSync()) as Map<String, dynamic>,
  };
  final problems = check(input, arbs['en']!);
  if (problems.isNotEmpty) exitWith(problems);

  var added = 0, changed = 0, removed = 0;
  for (final MapEntry(key: key, value: message) in input.entries) {
    if (message == null) {
      for (final arb in arbs.values) {
        arb
          ..remove(key)
          ..remove('@$key');
      }
      removed++;
      continue;
    }
    message as Map<String, dynamic>;
    if (arbs['en']!.containsKey(key)) {
      changed++;
    } else {
      added++;
    }
    // Merge with the metadata already there. Built from the input alone, supplying
    // only "description" replaced the whole @key block and took "placeholders" with
    // it, so a message still using {count} lost its declaration and gen-l10n either
    // failed or generated the method without its typed argument. A field set to
    // null removes it.
    final metadata = <String, dynamic>{
      ...?(arbs['en']!['@$key'] as Map<String, dynamic>?),
    };
    for (final field in metadataFields) {
      if (!message.containsKey(field)) continue;
      if (message[field] == null) {
        metadata.remove(field);
      } else {
        metadata[field] = message[field];
      }
    }
    for (final language in languages) {
      arbs[language] = put(arbs[language]!, {
        key: message[language],
        if (language == 'en' && metadata.isNotEmpty) '@$key': metadata,
      }, after: message['after'] as String?);
    }
  }

  for (final language in languages) {
    write(files[language]!, arbs[language]!);
  }
  stdout.writeln(
    '$added added, $changed changed, $removed removed, '
    'in ${languages.length} files.',
  );
}

/// Everything wrong with [input], checked against the English file.
List<String> check(Map<String, dynamic> input, Map<String, dynamic> english) {
  final problems = <String>[];
  final known = english.keys.toSet();
  for (final MapEntry(:key, :value) in input.entries) {
    if (value == null) {
      if (!known.remove(key)) problems.add('$key: not a message, to remove');
      continue;
    }
    if (value is! Map<String, dynamic>) {
      problems.add('$key: expected an object, or null to remove it');
      continue;
    }
    final unknown = value.keys.toSet().difference({
      ...languages,
      ...metadataFields,
      'after',
    });
    if (unknown.isNotEmpty) {
      problems.add('$key: unknown fields ${unknown.join(', ')}');
    }
    for (final language in languages) {
      final text = value[language];
      if (text is! String || text.trim().isEmpty) {
        problems.add('$key: no "$language" text');
      }
    }
    final after = value['after'];
    if (after != null && !known.contains(after)) {
      problems.add('$key: "after" names $after, which is not a message');
    }
    // An explicit null removes the declaration, so there is nothing left to check
    // against; `??` alone would fall back to the ones being removed and demand the
    // new text still use them.
    final placeholders =
        (value.containsKey('placeholders')
                ? value['placeholders']
                : (english['@$key'] as Map?)?['placeholders'])
            as Map? ??
        const {};
    for (final name in placeholders.keys) {
      final use = RegExp('\\{$name[},]');
      for (final language in languages) {
        final text = value[language];
        if (text is String && !use.hasMatch(text)) {
          problems.add('$key: "$language" does not use {$name}');
        }
      }
    }
    known.add(key);
  }
  return problems;
}

/// [arb] with [entries] (a key and maybe its metadata) in place: an existing
/// key keeps its position, a new one goes after [after] and its metadata, or
/// at the end.
Map<String, dynamic> put(
  Map<String, dynamic> arb,
  Map<String, Object?> entries, {
  String? after,
}) {
  final key = entries.keys.first;
  final exists = arb.containsKey(key);
  final anchor = exists || after == null
      ? null
      : arb.containsKey('@$after')
      ? '@$after'
      : after;
  final result = <String, dynamic>{};
  var placed = false;
  for (final MapEntry(key: k, value: v) in arb.entries) {
    if (k == key) {
      result.addAll(entries);
      placed = true;
      continue;
    }
    if (entries.containsKey(k)) continue;
    result[k] = v;
    if (k == anchor) {
      result.addAll(entries);
      placed = true;
    }
  }
  // "after" is checked against the English file, but this runs on every language,
  // and a translation file that has drifted may not have that key at all. The
  // anchor was then non-null and simply never matched, so the message was dropped
  // from that file while the summary still counted it as added. Ending up at the
  // end of one file is a cosmetic difference; losing the message is not.
  if (!placed) result.addAll(entries);
  return result;
}

/// Writes [arb] the way the ARB files are laid out, keeping their line endings.
void write(File file, Map<String, dynamic> arb) {
  final crlf = file.readAsStringSync().contains('\r\n');
  final text = '${const JsonEncoder.withIndent('  ').convert(arb)}\n';
  file.writeAsStringSync(crlf ? text.replaceAll('\n', '\r\n') : text);
}

Never exitWith(List<String> problems) {
  stderr.writeln('Nothing written:\n${problems.join('\n')}');
  exit(1);
}
