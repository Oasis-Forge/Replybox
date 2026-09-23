import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../providers/thread_provider.dart';
import 'date_separator.dart';

/// INB-10's standing notice, and every other standing line a thread carries.
///
/// Not dismissible and not a one-time tip: there is no close control here and
/// no stored "seen" flag anywhere that could remove it. It is the thread's
/// first row, above the oldest message, and it is what keeps the screen from
/// reading as a complete conversation when it is a record of notifications
/// (product principle 3, CAP-26).
///
/// It draws, in order:
///
///  1. the base line — only what arrived as a notification, and an edit, unsend
///     or deletion elsewhere still reads as it first arrived (INB-10, CAP-26);
///  2. exactly one date shape — access was off until then, the retention
///     window, or the plain date history begins (INB-10);
///  3. the read's window, where the thread holds more than it (INB-10);
///  4. the most recent overlapping gap and a count of the others, where one
///     exists (INB-10);
///  5. INB-12's line, for a conversation that is a notification rather than a
///     chat;
///  6. INB-2's line, where the notification arrived without a name;
///  7. INB-22's line, where the source app's row is switched off.
///
/// Nothing here scrolls separately and nothing here loads: INB-10 says
/// scrolling to the top must never show a spinner suggesting there is more, so
/// this is an ordinary first item in the same list as the messages.
class ThreadNotice extends StatelessWidget {
  const ThreadNotice({
    required this.notice,
    required this.isRaw,
    required this.isUnnamed,
    required this.sourceAppEnabled,
    required this.appLabel,
    super.key,
  });

  /// INB-10's value object. Null only before the first read lands, and the
  /// dated lines are simply absent until it does — the base line is true
  /// whatever the dates turn out to be, so it draws either way.
  final ThreadHistoryNotice? notice;

  /// INB-12: this conversation is a notification the app could not read as a
  /// chat (CAP-21).
  final bool isRaw;

  /// INB-2: the notification arrived without a name.
  final bool isUnnamed;

  /// INB-22: false puts a line on the thread saying nothing further will
  /// arrive in it while the row stays off.
  final bool sourceAppEnabled;

  /// The source app's name, for the lines that have to say which app they mean.
  /// INB-1's fallback chain has already run, so this is never empty.
  final String appLabel;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final ThreadHistoryNotice? n = notice;

    final List<String> lines = <String>[
      l10n.threadHistoryNotice,
      if (n != null) _dateLine(l10n, context, n),
      // Straight after the date, because it is the line that stops the two from
      // contradicting each other: the date says how far back the app could have
      // seen this conversation, and without this the oldest message drawn is
      // months newer than it with nothing saying why. A thread of 501 messages
      // named the install date and then showed message 501 as its oldest, which
      // reads as five hundred messages lost.
      //
      // Stated, not paged: INB-10 says scrolling to the top never loads older
      // messages and never shows a spinner suggesting there are any — and the
      // oldest drawn message is exactly where a reader would pull.
      if (n != null && n.hidesOlderMessages) l10n.threadWindowed(n.windowSize),
      if (n != null && n.hasGap)
        l10n.threadHistoryGaps(
          threadNoticeInstant(context, n.mostRecentGap!.from),
          threadNoticeInstant(context, n.mostRecentGap!.to),
          n.otherGapCount,
        ),
      if (isRaw) l10n.rawConversationNotice,
      // A raw conversation is titled with the app's name by design (INB-12),
      // so it is not a conversation whose name went missing and does not carry
      // INB-2's line as well.
      if (isUnnamed && !isRaw) l10n.conversationUnnamed,
      if (!sourceAppEnabled) l10n.threadSourceAppOff(appLabel),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < lines.length; i++)
              Padding(
                // By index, not by value: two of these lines could one day be
                // the same sentence in some language, and the last one is the
                // one with no gap under it.
                padding: EdgeInsets.only(bottom: i == lines.length - 1 ? 0 : 8),
                child: Text(
                  lines[i],
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// INB-10 names **one** date, and which sentence it is said in depends on
  /// what the date turned out to be.
  ///
  /// A retention window that is later than the date history begins replaces it
  /// rather than joining it, because a date on screen beside a thread that no
  /// longer reaches it is worse than no date at all. Where no capture session
  /// existed before the date, the notice says access was off until then rather
  /// than leaving the reader to infer it.
  String _dateLine(
    AppLocalizations l10n,
    BuildContext context,
    ThreadHistoryNotice n,
  ) {
    final String date = threadNoticeDate(context, n.since);
    if (n.namesRetention) return l10n.threadHistoryRetention(date);
    if (n.accessOffUntilBegins) return l10n.threadHistoryAccessOffUntil(date);
    return l10n.threadHistorySince(date);
  }
}
