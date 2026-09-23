import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../providers/permissions_provider.dart';
import 'date_separator.dart';
import 'message_time.dart';

/// Whether [line] is one of PERM-8's three sentences — the access banner —
/// rather than PERM-10's or PERM-11's line.
///
/// It exists because PERM-8 gives its banner a placement the other two do not
/// have: it draws above the rows where conversations are stored and *replaces*
/// INB-15's *Nothing yet* where none are, while PERM-10's and PERM-11's lines
/// always draw above whatever the body turns out to be and leave INB-15's
/// states underneath them (PERM-13). That is a layout question, so the screen
/// answers it — but the mapping from a value to "this one is the banner" is
/// stated here, once, so a second screen asking the same question cannot
/// answer it differently.
///
/// It is **not** a ranking and must never grow into one. Which line holds is
/// [PermissionsProvider.statusLine]'s decision and PERM-13 fixes the order
/// there; this only reads the value it was handed.
bool isAccessBanner(CaptureStatusLine line) => switch (line) {
  CaptureStatusLine.accessOffSince ||
  CaptureStatusLine.accessOffSinceAtLeast ||
  CaptureStatusLine.accessNeverOn => true,
  CaptureStatusLine.none ||
  CaptureStatusLine.notRunning ||
  CaptureStatusLine.quiet => false,
};

/// PERM-13's status line: at most one, above the first screen's rows.
///
/// **This widget ranks nothing.** PERM-13 fixes an order — PERM-8's access
/// banner, then PERM-10's `capture is not running right now`, then PERM-11's
/// quiet observation — and [PermissionsProvider] has already applied it and
/// handed down one value. A widget that held the three facts and picked between
/// them would be a second place for that order to live, and the two would
/// disagree the first time one of them changed. So there is one `switch` here
/// over one enum, and no branch in this file can produce two lines or reach for
/// a fact the provider did not resolve. That is also the whole of PERM-13's
/// "at most one at a time": not a rule this widget obeys, but a shape it cannot
/// break.
///
/// **One container for all three, deliberately.** PERM-11 says its line carries
/// no error styling and no badge, and the cheapest way to keep that true is for
/// there to be exactly one styling on this screen for a standing line —
/// [ThreadNotice]'s, which is the shape this codebase already uses for a
/// sentence a screen states rather than a thing the user did. A second shape,
/// alarming for PERM-8 and calm for PERM-11, would be a second thing to keep
/// consistent across every language and both brightnesses, and the first edit
/// that reached for `errorContainer` for PERM-10's provisional line would put
/// an alarm on a listener that may simply be slow (CAP-25). The words carry the
/// difference, which is the register this whole app is written in.
///
/// **What it refuses to draw.** No sentence for a branch whose instant the app
/// does not hold: PERM-9 and product principle 3 say the app never prints the
/// time it noticed something as the time that thing happened, and inventing a
/// date for `installed_at` would be the same offence one step further on. Where
/// [since] is null on a branch that names a time, nothing is drawn at all and
/// INB-15's own state is left to speak — see [_sentence].
///
/// **INB-23.** Every control below is a real button with real words on it, and
/// carries no semantic label of its own: the correction of 22 September 2026
/// says a label that repeats the visible sentence makes one thing read as two,
/// which is why §f of the build spec adds no `semanticsCaptureStatus`. The
/// 48dp floor comes from the theme's `MaterialTapTargetSize.padded`, so it
/// holds for every button in the app rather than for the ones someone
/// remembered.
///
/// **INB-24.** Nothing here can name a conversation, a sender, a message or a
/// package: the only values this widget accepts are an enum and an instant, so
/// there is no parameter through which one could arrive and no later edit that
/// could render one. That is also why PERM-8's banner is safe over a locked
/// screen for the reason INB-15's empty states are.
///
/// **INB-25.** It reads no provider, starts no future and touches no
/// repository, so a message arriving while this is on screen costs the list
/// nothing but the rebuild it was already having. The one thing it does besides
/// draw is [onQuietShown], which is a callback out and not work of its own.
///
/// **Why it has a `State` at all**, given everything above: PERM-11 allows its
/// line one showing in any twenty-four hours, and the only honest place to
/// record that a showing happened is the widget that drew it — the same design
/// PERM-14's screen uses, argued in full at
/// `PermissionsProvider.markQuietNoticeShown`. `initState` and
/// [didUpdateWidget] are where "this is now on screen and was not before" is
/// observable, and a `StatelessWidget` has neither.
class CaptureStatusNotice extends StatefulWidget {
  const CaptureStatusNotice({
    required this.line,
    required this.since,
    required this.now,
    required this.onOpenDisclosure,
    required this.onOpenGuidance,
    required this.onDismissQuiet,
    required this.onQuietShown,
    super.key,
  });

  /// The one line [PermissionsProvider] resolved (PERM-13).
  final CaptureStatusLine line;

  /// The instant that line's sentence names, or null where the app holds none
  /// ([PermissionsProvider.statusSince]).
  final DateTime? since;

  /// The frame's own instant, so the time this draws agrees with the times the
  /// rows beneath it draw (INB-1). Passed in rather than read from the clock
  /// here for exactly that reason: two `DateTime.now()` calls a millisecond
  /// apart can fall either side of midnight and print different days.
  final DateTime now;

  /// PERM-8's one action. It opens the disclosure and never the system page
  /// directly (PERM-1), which is why this is not named `onTurnOnAccess`: the
  /// banner offers a screen that explains, not a grant.
  final VoidCallback onOpenDisclosure;

  /// PERM-14's guidance, which is the action on both PERM-10's line and
  /// PERM-11's.
  final VoidCallback onOpenGuidance;

  /// PERM-11's dismissal, and only PERM-11's. The other two report a state that
  /// does not go away on being tapped (PERM-8, PERM-13), so no branch below
  /// draws this control for them — and because every callback here is required,
  /// a caller cannot half-wire one and leave a dead control on screen.
  final VoidCallback onDismissQuiet;

  /// PERM-11's line has just gone on screen, once per time it does.
  ///
  /// Not a dismissal and not an action the user took: this is the notice
  /// reporting itself, so that the once-per-twenty-four-hours budget is spent
  /// by a sentence somebody could read rather than by a state somebody
  /// resolved. Required like every other callback here, because a caller that
  /// forgot it would leave the budget being spent in the old, wrong place with
  /// nothing on screen to show for it.
  ///
  /// Called for PERM-11's branch alone. PERM-8's banner and PERM-10's line have
  /// no budget: they report a state that is still true on the next read and
  /// they draw again every time it is.
  final VoidCallback onQuietShown;

  @override
  State<CaptureStatusNotice> createState() => _CaptureStatusNoticeState();
}

class _CaptureStatusNoticeState extends State<CaptureStatusNotice> {
  /// Whether this element has already reported the showing it is drawing now.
  ///
  /// Reset when the widget stops drawing PERM-11's line, so the sequence
  /// *quiet → the access banner → quiet again*, which one element can serve
  /// without ever being rebuilt from scratch, reports twice. Two showings a day
  /// apart are two showings; PERM-11's twenty-four hours are the provider's to
  /// enforce from the stamp and are deliberately not re-argued here.
  bool _reportedQuiet = false;

  @override
  void initState() {
    super.initState();
    _reportShowing();
  }

  @override
  void didUpdateWidget(covariant CaptureStatusNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reportShowing();
  }

  /// Whether this build puts PERM-11's sentence on the screen.
  ///
  /// The instant is part of the question and not a detail: [_sentence] answers
  /// null for a quiet line with no time to name, and a widget that drew nothing
  /// must not spend the day's one showing. That is the same refusal the whole
  /// of [_sentence] is built on, read here as a condition.
  bool get _drawsQuiet =>
      widget.line == CaptureStatusLine.quiet && widget.since != null;

  void _reportShowing() {
    if (!_drawsQuiet) {
      _reportedQuiet = false;
      return;
    }
    if (_reportedQuiet) return;
    _reportedQuiet = true;
    widget.onQuietShown();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final String? sentence = _sentence(context, l10n);
    if (sentence == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              sentence,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // The actions wrap rather than sitting in a `Row`: at the 1.3x text
            // scale INB-23 renders at, PERM-11's two controls in the language
            // with the longest word for *Dismiss* do not fit one phone-width
            // line, and a `Row` of fixed children in a box it has outgrown
            // overflows — which INB-23 counts as a failure outright.
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final _Action action in _actions(l10n))
                  TextButton(
                    onPressed: action.onPressed,
                    child: Text(action.label),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The one sentence this line says, or null for "say nothing at all".
  ///
  /// Null happens twice, and the two are different in kind:
  ///
  ///  * [CaptureStatusLine.none] — the provider has nothing to report, which
  ///    includes the case that matters most: a listener that has told this
  ///    process nothing yet. PERM-10 forbids a line on that.
  ///  * A branch that names a time with no time to name. PERM-8's three
  ///    sentences and PERM-11's all carry an instant, and `installed_at` is
  ///    written once per launch before any screen exists — so a null here is a
  ///    test or a launch that failed before that write. **The answer is
  ///    silence, not a substituted date.** PERM-9 and product principle 3 say
  ///    the app never prints a time it does not hold, and a banner reading
  ///    *installed on 1 January 1970* would break that rule in the one
  ///    direction CAP-12 may not be wrong in. INB-15's own state then draws
  ///    normally, which names no time and claims nothing.
  ///
  /// There is no timeless variant of PERM-8's third sentence in the message
  /// files today; if one is ever written, it belongs in this branch.
  String? _sentence(BuildContext context, AppLocalizations l10n) {
    final DateTime? at = widget.since;
    final DateTime now = widget.now;
    return switch (widget.line) {
      CaptureStatusLine.none => null,
      // `formatRowTime` and not a format of this file's own (LANG-3): the shape
      // depends on the value — a clock time today, a day name inside the week,
      // a date beyond it — and `message_time.dart` argues that choice once for
      // the whole app. A banner that dated itself differently from the rows
      // under it would be two calendars on one screen.
      CaptureStatusLine.accessOffSince =>
        at == null
            ? null
            : l10n.captureOffSince(formatRowTime(at, now, l10n.localeName)),
      CaptureStatusLine.accessOffSinceAtLeast =>
        at == null
            ? null
            : l10n.captureOffSinceAtLeast(
                formatRowTime(at, now, l10n.localeName),
              ),
      // A calendar date, not [formatRowTime]: this placeholder is an install
      // date inside the sentence *installed on …*, and the row format would
      // print a clock time for a phone that installed the app this morning and
      // a weekday name for one that installed it on Tuesday. Neither is a date
      // anybody installed anything on. `threadNoticeDate` is the app's existing
      // date shape (INB-10) and is reused rather than copied.
      CaptureStatusLine.accessNeverOn =>
        at == null ? null : l10n.captureNeverOn(threadNoticeDate(context, at)),
      // The one branch with no instant by design. PERM-10 says the app does not
      // know when the listener unbound, and PERM-9's discipline forbids
      // printing the time it noticed instead — so the sentence carries no time
      // and this is not a missing value.
      CaptureStatusLine.notRunning => l10n.captureNotRunning,
      CaptureStatusLine.quiet =>
        at == null
            ? null
            : l10n.captureQuietSince(formatRowTime(at, now, l10n.localeName)),
    };
  }

  /// The controls this line carries, in the order they are read.
  ///
  /// PERM-8's banner is not dismissible — the state it reports does not go away
  /// on being tapped — and its one action opens the disclosure rather than the
  /// system page (PERM-1). PERM-10's line carries PERM-14 alone. PERM-11's is
  /// the only one of the three that can be dismissed, and its guidance link
  /// comes first because the dismissal is the way out, not the offer.
  List<_Action> _actions(AppLocalizations l10n) => switch (widget.line) {
    CaptureStatusLine.none => const <_Action>[],
    CaptureStatusLine.accessOffSince ||
    CaptureStatusLine.accessOffSinceAtLeast ||
    CaptureStatusLine.accessNeverOn => <_Action>[
      _Action(l10n.captureOffAction, widget.onOpenDisclosure),
    ],
    CaptureStatusLine.notRunning => <_Action>[
      _Action(l10n.captureGuidanceAction, widget.onOpenGuidance),
    ],
    CaptureStatusLine.quiet => <_Action>[
      _Action(l10n.captureGuidanceAction, widget.onOpenGuidance),
      _Action(l10n.captureQuietDismiss, widget.onDismissQuiet),
    ],
  };
}

/// A label from the message files and the thing it does. Nothing else reaches a
/// control on this line — no icon, no badge, no count (PERM-11).
@immutable
class _Action {
  const _Action(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;
}
