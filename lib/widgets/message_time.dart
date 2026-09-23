/// INB-1's three time shapes, and INB-5's count, in the chosen language's
/// format (LANG-3).
///
/// Not message-file strings: the shape depends on the value — today, this week,
/// or older — and `gen-l10n` has no conditional date format to express that.
/// What it would have produced instead is three keys a translator could fill
/// with anything, which is how a French build ends up printing `MM/DD`. `intl`
/// already holds every locale's own short date, day name and clock, so the
/// choice is made here and the formatting is the platform's.
library;

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

/// The time a conversation row draws (INB-1): the clock time for a message on
/// today's local calendar day, the day name within the last seven days, and the
/// short date beyond that.
///
/// [when] is the stored UTC instant; the comparison is made in the device's
/// current time zone, like INB-8's date separators, so a row re-groups when the
/// zone changes rather than carrying a calendar day frozen at capture.
String formatRowTime(DateTime when, DateTime now, String locale) {
  final DateTime local = when.toLocal();
  final DateTime today = calendarDay(now.toLocal());
  final DateTime day = calendarDay(local);

  if (day == today) return DateFormat.jm(locale).format(local);

  // Calendar days, not 168 hours: "within the last seven days" reads as a week
  // of day names, and an hours-based window would put yesterday's late message
  // under a date while this morning's sat under a day name.
  final int daysBack = today.difference(day).inDays;
  if (daysBack > 0 && daysBack < 7) return DateFormat.E(locale).format(local);

  // A time in the future — a source app with a clock ahead of this phone — is
  // not "in the last seven days" and falls through to the date, which is the
  // one shape that cannot be misread as something that just arrived.
  return DateFormat.yMd(locale).format(local);
}

/// The calendar day an already-localised instant falls on, as a value that can
/// be compared *and subtracted* without either instant being reformatted into a
/// string.
///
/// The year, month and day are read from local time — that is the calendar the
/// user is on — but the value is built in UTC, and that is the whole point.
/// Built with `DateTime(...)` these are local midnights, and two local
/// midnights are not 24 hours apart on a day the zone changes: on a
/// spring-forward date yesterday's midnight is 23 hours back, so
/// `difference(...).inDays` truncated to `0`, INB-1's `daysBack > 0` guard
/// failed, and yesterday's message drew a full date where the rule says a day
/// name (correction, 22 September 2026). UTC midnights are exactly 24 hours
/// apart by construction, so the subtraction counts calendar days in every
/// zone, DST or not.
///
/// Nothing formats these: [formatRowTime] formats `local`.
///
/// Visible to tests because it is the only part of that correction a test can
/// execute on every machine. Whether two *local* midnights are 23 hours apart
/// depends on the running machine's zone, and neither CI (ubuntu-latest, UTC)
/// nor the developer's has a transition — so the regression test written
/// through [formatRowTime] skipped itself everywhere and guarded nothing.
/// Whether this value is a **UTC** midnight depends on nothing, and it is the
/// whole of why the subtraction above counts days: revert this to
/// `DateTime(...)` and the assertion fails in every zone, transition or not.
@visibleForTesting
DateTime calendarDay(DateTime local) =>
    DateTime.utc(local.year, local.month, local.day);

/// INB-5's unread count as it is drawn: up to 99 in the language's own digits
/// (LANG-3), and beyond that the message file's `99+`.
///
/// The overflow line is a message and this is not: a number is formatted, never
/// translated, and a `99+` key that a translator can change is how a language
/// ends up with a different cap from every other.
String formatUnreadCount(int count, String locale) =>
    NumberFormat.decimalPattern(locale).format(count);
