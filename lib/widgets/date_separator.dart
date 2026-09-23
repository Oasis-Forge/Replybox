/// INB-8's date separator, and the four date and time formats the thread
/// draws.
///
/// The formats live beside the separator rather than in a `utils/` file because
/// they are one decision, not four: every instant this screen prints goes
/// through LANG-3 with the locale the app is actually rendering in, and putting
/// them in one place is what keeps a second one from appearing with a hand-made
/// pattern in it.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

/// The local calendar day an arrival time falls on (INB-8).
///
/// Computed in the device's **current** time zone from the instant, never read
/// from a stored calendar date, so a message re-groups under a new separator
/// when the zone changes. DATE-1 governs a date the *user* picks and does not
/// apply here.
DateTime localDayOf(DateTime instant) {
  final DateTime local = instant.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// The locale every format below is built for (LANG-3).
///
/// `AppLocalizations.localeName` rather than the platform locale: it is the
/// locale the app resolved to and so the one the surrounding text is in, and
/// `GlobalMaterialLocalizations` has already loaded `intl`'s date symbols for
/// it by the time any of this draws.
String _locale(BuildContext context) => AppLocalizations.of(context).localeName;

/// The separator's own label: a calendar date (INB-8, LANG-3).
///
/// A plain date rather than "Today" or "Yesterday" — those would be two more
/// lines in the message files, and LANG-2 forbids piecing them together here.
String threadSeparatorLabel(BuildContext context, DateTime day) =>
    DateFormat.yMMMd(_locale(context)).format(day);

/// A message's own arrival time, beside its body (INB-8).
///
/// Clock time alone: the day it belongs to is already stated by the separator
/// above it, and repeating it on every bubble is noise.
String threadMessageTime(BuildContext context, DateTime instant) =>
    DateFormat.jm(_locale(context)).format(instant.toLocal());

/// A date INB-10's notice names — when history begins, or a retention window.
String threadNoticeDate(BuildContext context, DateTime instant) =>
    DateFormat.yMMMd(_locale(context)).format(instant.toLocal());

/// One end of a gap INB-10 names.
///
/// Date *and* time, unlike [threadNoticeDate]: a gap can open and close inside
/// one day, and "between 21 Sep and 21 Sep" states an absence while hiding how
/// long it was.
String threadNoticeInstant(BuildContext context, DateTime instant) =>
    DateFormat.yMMMd(_locale(context)).add_jm().format(instant.toLocal());

/// INB-8: sits before the first message of each local calendar day.
class DateSeparator extends StatelessWidget {
  const DateSeparator({required this.day, super.key});

  /// The local calendar day, as [localDayOf] computed it.
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            threadSeparatorLabel(context, day),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
