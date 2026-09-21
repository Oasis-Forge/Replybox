/// The columns every stored record carries (REC-1, REC-2, DEL-1), and the
/// helpers that keep them honest.
///
/// These are free functions rather than a base class: the models are plain
/// classes with `toMap`/`fromMap` (docs/STACK_NOTES.md), and a base class would
/// buy inheritance we never use while making `fromMap` harder to read.
library;

import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// A fresh record ID. UUID v4 (REC-2).
String newId() => _uuid.v4();

/// Sentinel for `copyWith` on a nullable field, so clearing a value and
/// leaving it alone are different calls. Without it `copyWith(deletedAt: null)`
/// cannot mean "undelete".
const Object unset = Object();

/// SQLite has no boolean. One place to convert, so a column never ends up
/// holding `'true'` in one code path and `1` in another.
int boolToDb(bool value) => value ? 1 : 0;

/// Reads a SQLite integer back as a bool. Anything other than 0 is true, which
/// matches SQLite's own truthiness rather than inventing a stricter rule.
bool boolFromDb(Object? value) => (value as int? ?? 0) != 0;

/// Milliseconds since the epoch, UTC. Stored as an integer rather than a
/// string so a range scan is an integer comparison and a time zone change
/// cannot re-order anything (contrast DATE-1, which is about dates the *user*
/// picks; these are instants the phone recorded).
int timeToDb(DateTime value) => value.toUtc().millisecondsSinceEpoch;

/// Reads a stored instant back in UTC. Callers convert to local for display.
DateTime timeFromDb(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(value! as int, isUtc: true);

/// Nullable variant of [timeFromDb].
DateTime? timeFromDbOrNull(Object? value) =>
    value == null ? null : timeFromDb(value);

/// The SQL for the columns REC-1, REC-2 and DEL-1 require, so no table can
/// accidentally omit one. Included verbatim in every create step; because a
/// merged migration step is never edited, this constant is only ever read by
/// new steps.
const String recordColumns = '''
  id           TEXT    PRIMARY KEY,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  deleted_at   INTEGER
''';
