/// INB-1's three time shapes, asserted on the string the row draws.
///
/// Every instant here is built with `DateTime(...)` and so is already in the
/// device's zone: `formatRowTime` calls `toLocal()` on what it is given, and
/// that is a no-op for a local value, so these tests say the same thing on
/// every machine that runs them — including the two at the bottom, which is a
/// correction. Those used to be one test that searched the machine's own zone
/// for a spring-forward date and skipped when it found none, which is every
/// machine this project runs on: CI is ubuntu-latest and so UTC, and the
/// developer's zone has no transition either. The guard for a bug that actually
/// shipped had therefore never executed anywhere.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:replybox/widgets/message_time.dart';

/// The locale every assertion below is made in. `en_US` is `intl`'s built-in
/// set, so no symbol loading is needed and the test is not about LANG-3.
const String _locale = 'en_US';

void main() {
  // Midday, so nothing here is one hour from the edge of its own day.
  final DateTime now = DateTime(2026, 9, 22, 12);

  group('INB-1 the time a conversation row draws', () {
    test('a message from today draws the clock time', () {
      final DateTime when = DateTime(2026, 9, 22, 9, 30);

      expect(
        formatRowTime(when, now, _locale),
        DateFormat.jm(_locale).format(when),
      );
    });

    test('a message from yesterday draws the day name', () {
      final DateTime when = DateTime(2026, 9, 21, 23);

      expect(
        formatRowTime(when, now, _locale),
        DateFormat.E(_locale).format(when),
      );
    });

    test('six days back is still a day name', () {
      final DateTime when = DateTime(2026, 9, 16, 12);

      expect(
        formatRowTime(when, now, _locale),
        DateFormat.E(_locale).format(when),
      );
    });

    test('seven days back is a date', () {
      // The window is "the last seven days" of *day names*, so the seventh day
      // back is where the date starts — otherwise two Tuesdays would draw the
      // same word a week apart.
      final DateTime when = DateTime(2026, 9, 15, 12);

      expect(
        formatRowTime(when, now, _locale),
        DateFormat.yMd(_locale).format(when),
      );
    });

    test('a time in the future draws a date, not a day name', () {
      // A source app whose clock is ahead of this phone. A day name would read
      // as something that just arrived.
      final DateTime when = DateTime(2026, 9, 23, 9);

      expect(
        formatRowTime(when, now, _locale),
        DateFormat.yMd(_locale).format(when),
      );
    });
  });

  group('INB-1 on a day the clocks move', () {
    // The bug: the row computed `today.difference(day).inDays` over two *local*
    // midnights, and on a spring-forward date those are 23 hours apart, so
    // `inDays` truncated to 0, the `daysBack > 0` guard failed, and yesterday's
    // message drew a full date where INB-1 says day name (correction, 22
    // September 2026).
    //
    // Neither test below is conditional, and neither needs the machine's zone
    // to move its clocks. They split the rule in two: the first asserts the
    // mechanism that makes the arithmetic zone-proof, which is what a UTC
    // runner can check about a DST defect; the second asserts the behaviour
    // across a whole year of consecutive days, which on a machine whose zone
    // *does* have transitions walks straight through them.
    test('a calendar day is a UTC midnight, which is what makes the day count '
        'survive a zone that moves its clocks', () {
      // Two UTC midnights are 24 hours apart by construction, in every zone;
      // two local midnights are not, and that difference is the entire defect.
      // A revert to `DateTime(...)` fails this on ubuntu-latest, which is the
      // point — the old test could only fail somewhere nobody runs it.
      final DateTime local = DateTime(2026, 3, 8, 23, 30);

      expect(
        calendarDay(local).isUtc,
        isTrue,
        reason:
            'a local midnight is what made the subtraction count hours, so '
            'this value has to be built in UTC',
      );
      expect(calendarDay(local), DateTime.utc(2026, 3, 8));
      expect(
        calendarDay(
          local,
        ).difference(calendarDay(DateTime(2026, 3, 7, 0, 30))).inDays,
        1,
        reason: 'one calendar day back is one day back whatever the clock did',
      );
    });

    test('yesterday draws its day name on every date of a year, transition or '
        'not', () {
      // 10:00 and 12:00 exist on every date in every zone — a spring-forward
      // gap is an hour after midnight — so this sweep is safe to run anywhere,
      // and where the runner's zone has a transition it covers that date the
      // way the old test did, without having to find it first.
      for (int i = 1; i <= 365; i++) {
        final DateTime midday = DateTime(2026, 1, i + 1, 12);
        final DateTime yesterday = DateTime(2026, 1, i, 10);

        expect(
          formatRowTime(yesterday, midday, _locale),
          DateFormat.E(_locale).format(yesterday),
          reason:
              'INB-1: a message from yesterday draws a day name, and '
              '$yesterday is the day before $midday',
        );
      }
    });
  });
}
