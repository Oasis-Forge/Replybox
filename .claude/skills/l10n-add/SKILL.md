---
name: l10n-add
description: Add, change, or remove app messages in every language at once (LANG-6) with one JSON file, without reading or editing the ARB files by hand. Use whenever a screen needs new or changed text.
---

The ARB files in `lib/l10n` grow to tens of KB each, and the generated `app_localizations*.dart` are larger still: don't read them. To see an existing message, Grep its key with `path: lib/l10n`. The languages are the `app_<code>.arb` files there.

1. Write the messages to a JSON file in the scratchpad. Each key needs a text for every language code; `description` and `placeholders` are optional and go into `app_en.arb` only; `after` puts a new key next to a related one. `null` removes a key. Metadata is merged with what the message already has, so naming only `description` leaves its `placeholders` alone; a metadata field set to `null` removes just that field.
   ```json
   {
     "importDone": {
       "en": "{count, plural, =1{Imported 1 row.} other{Imported {count} rows.}}",
       "ar": "...", "fr": "...",
       "placeholders": {"count": {"type": "int"}},
       "after": "importButton"
     },
     "oldMessage": null
   }
   ```
2. `dart tool/add_messages.dart <file>`. It checks every key has every language and uses each declared placeholder, and writes nothing if anything is wrong.
3. `flutter gen-l10n`, then run the localization tests.

Writing the translations:
- Machine translations are fine; keep them as short as the English, since longer text overflows (test at 1.3× text size).
- Plurals: Arabic uses `=0`, `=1`, `=2`, `few`, `many`, `other`; Polish and Russian add `few` and `many`; Chinese, Japanese, Korean, Thai, Vietnamese and Indonesian have one form, so their `=1` and `other` read the same. Every case English uses must be present in every language, including `=0{...}` when English has it.
- Right-to-left languages (Arabic, Urdu, Hebrew, Persian) each get their own translation: never copy one across to another.
- Placeholder names stay in English in every language: `{count}`, never a translated name.
