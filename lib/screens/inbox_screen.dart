import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/conversation.dart';
import '../providers/inbox_provider.dart';
import '../providers/permissions_provider.dart';
import '../services/services.dart';
import '../theme.dart';
import '../widgets/app_filter_chips.dart';
import '../widgets/capture_status_line.dart';
import '../widgets/conversation_row.dart';
import '../widgets/failure_notice.dart';
import '../widgets/inbox_empty_states.dart';
import '../widgets/source_app.dart';
import '../widgets/swipe_to_reveal.dart';
import 'battery_guidance_screen.dart';
import 'disclosure_screen.dart';

/// The conversation list — in v1 the whole first screen (INB-19).
///
/// No tab bar: the waiting list is area WAIT, and INB-19 fixes that its arrival
/// changes nothing here. So there is no `TabController` in this file waiting for
/// a second tab, and no stored selected tab: the rule says the selection is
/// never stored, and the way to keep that true is to have nothing to store.
///
/// Presentational. It reads [InboxProvider] and [PermissionsProvider] and calls
/// them; it holds two pieces of state of its own, and both are about this
/// screen rather than about the data — which row's swipe is open, and whether a
/// delete's snackbar is up.
///
/// PERM-13's status line sits above the rows, and the only decision this screen
/// makes about it is *where it goes*: which of the three lines holds was
/// resolved by [PermissionsProvider] before this build started, and nothing
/// here re-ranks them ([CaptureStatusNotice]). The placement itself is PERM-8's
/// own sentence — the banner draws above the rows where conversations are
/// stored and replaces INB-15's *Nothing yet* where none are, while PERM-10's
/// and PERM-11's lines always draw above and leave INB-15's states underneath
/// (PERM-13) — and [isAccessBanner] is where "which kind of line is this"
/// is answered, so this screen holds no copy of that mapping either.
///
/// INB-24: nothing here writes a title, a sender, a message or a package
/// anywhere but to the screen. There is no logging in this file, in any build.
/// The status line is safe over a locked screen for the same reason INB-15's
/// empty states are: it says only what the app can and cannot see.
class InboxScreen extends StatefulWidget {
  const InboxScreen({
    required this.onOpenConversation,
    required this.onOpenIncludedApps,
    super.key,
  });

  /// The row's tap — INB-18's first tap, and the thread screen's cue to open.
  final void Function(BuildContext context, Conversation conversation)
  onOpenConversation;

  /// INB-15's *Nothing yet* action, and the way to the included-apps list
  /// (INB-20).
  final void Function(BuildContext context) onOpenIncludedApps;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  /// Which row has its Delete control revealed, or null (INB-6).
  ///
  /// Here rather than in each row, so opening one closes every other: two
  /// Delete controls on screen at once is not "one control and nothing else".
  String? _openRowId;

  /// About five seconds (INB-6, DEL-2).
  static const Duration _undoWindow = Duration(seconds: 5);

  /// DEL-2's window for someone reaching Undo through a screen reader.
  ///
  /// Three times as long, and that is the whole of the decision: DEL-2 says
  /// *about five seconds*, and five seconds is about how long it takes a
  /// sighted thumb to travel to a control it can already see. A reader has to
  /// be told the line and the action before either exists for them, so the same
  /// window is not the same offer. It is still a window, and that is the other
  /// half: see [_undoDuration].
  static const Duration _undoWindowSpoken = Duration(seconds: 15);

  /// How long this delete's Undo stays up (INB-6, DEL-2, INB-23).
  ///
  /// Material's own answer here is *forever*: a `SnackBar` carrying an action
  /// sets `persist`, and a persisting snackbar never times out — which is why
  /// every snackbar below passes `persist: false` explicitly. Left at the
  /// default the window never closed, so `showSnackBar(...).closed` never
  /// completed, [InboxProvider.forgetPendingUndo] was never called, the
  /// deleted conversation's chip never left INB-14's row and INB-15's
  /// pending-undo state stayed on the screen for the rest of the run. The
  /// device drill of 23 September 2026 measured the snackbar still up at t+8s
  /// and past 25s, and read it as a screen-reader rule; it is not — it is every
  /// user, on every device, with no accessibility service anywhere near it.
  ///
  /// So the window closes in both cases, and only its length differs. A window
  /// that never closes is not kinder to a screen-reader user: it is INB-15's
  /// fourth empty state pinned to their screen with no way back to the list.
  Duration get _undoDuration => MediaQuery.accessibleNavigationOf(context)
      ? _undoWindowSpoken
      : _undoWindow;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final InboxProvider inbox = context.watch<InboxProvider>();
    final PermissionsProvider permissions = context
        .watch<PermissionsProvider>();
    // One instant for the whole frame, so every row agrees about what "today"
    // is (INB-1) and two rows a millisecond apart cannot print different days.
    // The status line is dated from the same instant, so a banner and the rows
    // under it cannot fall either side of midnight.
    final DateTime now = DateTime.now().toUtc();

    // Built once and placed once. Null where PERM-13 resolved
    // [CaptureStatusLine.none], which is also what "the app has learned
    // nothing" looks like — PERM-10 forbids a line on that, and the way to keep
    // that true here is to have nothing to draw.
    final Widget? notice = permissions.statusLine == CaptureStatusLine.none
        ? null
        : CaptureStatusNotice(
            line: permissions.statusLine,
            since: permissions.statusSince,
            now: now,
            onOpenDisclosure: () => _open(context, DisclosureScreen.routeName),
            onOpenGuidance: () =>
                _open(context, BatteryGuidanceScreen.routeName),
            onDismissQuiet: () => unawaited(permissions.dismissQuietNotice()),
            // PERM-11's once-per-twenty-four-hours budget, spent by the line
            // that reaches a reader rather than by the read that resolved it.
            // Unawaited for the same reason the two onboarding screens' own
            // marks are: it is one idempotent settings row, nothing on this
            // screen reads it back, and the notice reports from `initState` —
            // which is a build, so this may not be something the screen waits
            // on (`PermissionsProvider.markQuietNoticeShown`).
            onQuietShown: () => unawaited(permissions.markQuietNoticeShown()),
          );

    // PERM-8's second placement. *Nothing yet* is INB-15's claim about the
    // whole database — not about this filter and not about a failed read — so
    // it is the empty state's own kind that decides this, and the banner
    // replaces exactly the state PERM-8 names and no other. PERM-10's and
    // PERM-11's lines never replace anything: PERM-13 says INB-15's states draw
    // below them.
    //
    // `error == null` is the third clause and it is not defensive: a read that
    // failed with nothing on screen draws [FailureNotice] *before* the empty
    // state is consulted, so a banner promised the empty state's place would
    // simply never be drawn — capture off, and the screen silent about it. With
    // this it stays at the top and the failure speaks underneath it, which is
    // two separate facts stated separately rather than one of them swallowed.
    final bool replacesNothingYet =
        notice != null &&
        isAccessBanner(permissions.statusLine) &&
        inbox.error == null &&
        inbox.emptyState.kind == InboxEmptyKind.nothingYet;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.inboxTitle),
        // INB-20 and INB-22: the way into the included-apps list, from the
        // screen that is always there. INB-15's *Nothing yet* also routes to
        // it, but that state is gone the moment the first message arrives —
        // and with it went every route to the switch INB-22 describes.
        actions: <Widget>[
          _IncludedAppsButton(
            onPressed: () => widget.onOpenIncludedApps(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            // Above the list, and drawn whenever there is a chip to draw —
            // including in INB-15's *Nothing in this filter* state, which is
            // reached with the chips still on screen and would be a dead end
            // without them.
            AppFilterChips(
              chips: inbox.chips,
              filterIsEmpty: inbox.filter.isEmpty,
              onToggle: (String package) {
                setState(() => _openRowId = null);
                unawaited(inbox.toggleFilter(package));
              },
              onClear: () {
                setState(() => _openRowId = null);
                unawaited(inbox.clearFilter());
              },
            ),
            // PERM-13: above the rows, below the chips. Below them because the
            // chips are a control the user set and this is the screen's account
            // of a state they did not — putting the line above would push a
            // filter row the user is working in off the top of the screen every
            // time capture went quiet.
            if (notice != null && !replacesNothingYet) notice,
            Expanded(
              child: _body(
                context,
                inbox,
                now,
                replacesNothingYet ? notice : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// PERM-1: every route out of this screen towards the grant goes through the
  /// disclosure, so the banner's action is a `pushNamed` and never a call into
  /// [PermissionsProvider.openAccessSettings].
  ///
  /// Pushed by name here rather than handed up through a callback like
  /// [InboxScreen.onOpenIncludedApps]: those two callbacks exist because the
  /// thread and the chooser are pushed with arguments this screen would
  /// otherwise have to compose. The disclosure and the battery guidance are
  /// argument-free routes on `MaterialApp.routes`, and routing them through the
  /// widget's constructor would put two more required parameters on every test
  /// that builds this screen for a reason that has nothing to do with them.
  void _open(BuildContext context, String routeName) {
    unawaited(Navigator.of(context).pushNamed<void>(routeName));
  }

  Widget _body(
    BuildContext context,
    InboxProvider inbox,
    DateTime now,
    Widget? bannerInsteadOfNothingYet,
  ) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    // The spinner is for the cold start only. A read triggered by capture never
    // raises the loading flag (INB-25), and a reload that already has rows
    // keeps drawing them rather than blanking a list someone is reading.
    if (inbox.isLoading &&
        inbox.rows.isEmpty &&
        inbox.emptyState.kind == InboxEmptyKind.none) {
      return const Center(child: CircularProgressIndicator());
    }
    // The read failed and left nothing behind, which without this is a
    // zero-item `ListView`: a blank white screen with no sentence on it. A
    // failure that still has rows underneath it does not take them away — the
    // rows are the last true thing the app read.
    if (inbox.error != null && inbox.rows.isEmpty) {
      return FailureNotice(
        // From the message files. Never the exception: `Repository` composes it
        // out of the `Message` it was writing, so `toString()` would put a
        // sender and a message's text on screen and into a crash report
        // (INB-24).
        message: l10n.inboxLoadFailed,
        onRetry: () => unawaited(inbox.load()),
      );
    }
    if (inbox.emptyState.isEmpty) {
      // PERM-8: the banner *replaces* INB-15's *Nothing yet* rather than
      // sitting above it, so it is drawn here, where that state would have
      // been, and not at the top of the screen. Two sentences about an empty
      // inbox is one too many — and the wrong one would be on top, because
      // *Nothing yet* names the included apps and offers the chooser while
      // access is off and none of them can post.
      //
      // Centred and scrollable like INB-15's own states, for INB-15's own
      // reason: the longest of these sentences at the 1.3x text scale INB-23
      // renders at, on a phone, in every language.
      if (bannerInsteadOfNothingYet != null) {
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: Metrics.gutter),
            child: bannerInsteadOfNothingYet,
          ),
        );
      }
      return InboxEmptyStates(
        state: inbox.emptyState,
        onSeeIncludedApps: () => widget.onOpenIncludedApps(context),
        onClearFilter: () {
          setState(() => _openRowId = null);
          unawaited(inbox.clearFilter());
        },
      );
    }

    // Everything the list holds is inside INB-6's Undo window, so the list is
    // empty and none of INB-15's three states is what it is: *Nothing yet* is a
    // claim about the whole database and there is history one tap away. The
    // provider says so rather than the screen working it out, and it is read
    // after the three because a named state wins where both hold. Without this
    // the screen falls through to a zero-item list — five seconds of blank
    // behind the snackbar, the one thing INB-15 says no empty state is.
    //
    // No button. The one action is the Undo in that snackbar; a second control
    // offering the same thing is the two buttons INB-15 rules out.
    if (inbox.emptyState.onlyPendingUndoLeft) {
      return _PendingUndoNotice(message: l10n.inboxEmptyPendingUndo);
    }

    return ListView.builder(
      // INB-10 is the thread's notice; a list that loaded older rows on scroll
      // would be claiming a history this app does not have. There is no
      // paging here and no spinner at either end.
      itemCount: inbox.rows.length,
      itemBuilder: (BuildContext context, int index) {
        final InboxRow row = inbox.rows[index];
        return _Row(
          key: ValueKey<String>(row.id),
          row: row,
          now: now,
          isOpen: _openRowId == row.id,
          onOpenChanged: (bool open) =>
              setState(() => _openRowId = open ? row.id : null),
          onTap: () {
            // A tap on a row whose Delete control is showing puts the row back
            // rather than opening the thread: the control the swipe revealed is
            // what the next tap is about.
            if (_openRowId == row.id) {
              setState(() => _openRowId = null);
              return;
            }
            widget.onOpenConversation(context, row.conversation);
          },
          onDelete: () => _delete(row),
        );
      },
    );
  }

  /// INB-6: one step, no confirmation, about five seconds of Undo.
  Future<void> _delete(InboxRow row) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final InboxProvider inbox = context.read<InboxProvider>();
    final Conversation conversation = row.conversation;

    setState(() => _openRowId = null);
    final DateTime? deletedAt = await inbox.deleteConversation(
      conversation,
      DateTime.now().toUtc(),
    );
    // The write failed, so nothing left the list and there is nothing to undo —
    // and, until this, nothing said so either: the row simply sprang back and
    // the user was left to guess. The line is from the message files and names
    // no conversation, because a snackbar is read aloud and may be drawn over a
    // locked screen (INB-24).
    if (deletedAt == null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.changeFailed),
            duration: _undoDuration,
            // Nothing to persist for: there is no action on this one, so this
            // only says out loud what the default already does. See
            // [_undoDuration] for why no snackbar on this screen is left to it.
            persist: false,
          ),
        );
      return;
    }

    // One snackbar at a time: a second delete inside the first's window would
    // otherwise queue behind it, and the Undo the user is reaching for would be
    // for the wrong conversation.
    messenger.clearSnackBars();
    final SnackBarClosedReason reason = await messenger
        .showSnackBar(
          SnackBar(
            duration: _undoDuration,
            // The one that matters: an action is exactly what makes Material
            // persist a snackbar by default, and this is the snackbar the whole
            // of INB-6's Undo hangs off ([_undoDuration]).
            persist: false,
            content: Text(l10n.conversationDeleted),
            action: SnackBarAction(
              label: l10n.undo,
              onPressed: () => unawaited(_undo(inbox, conversation, deletedAt)),
            ),
          ),
        )
        .closed;

    // The window closed without Undo being pressed, so the chip its app was
    // holding open may now leave the row (INB-6, INB-14). Dismissing the
    // snackbar by hand closes the window early, which is the user saying they
    // are done with it — it is not an undo, and INB-18 does not count it as a
    // tap either way.
    //
    // Named, because this snackbar's own `clearSnackBars` above is one of the
    // ways it closes: a second delete inside these five seconds resolves this
    // wait for the *previous* conversation while the new one is what is
    // pending. The provider ignores a closing it no longer holds.
    if (reason != SnackBarClosedReason.action) {
      await inbox.forgetPendingUndo(conversation);
    }
  }

  /// Undo, and a line when it does not land.
  ///
  /// An Undo that fails silently is the worst of the three: the user pressed
  /// the control that was supposed to put the conversation back, the snackbar
  /// closed, and the row stayed gone with nothing said. The provider clears its
  /// error on the successful read that follows, so what it holds after this
  /// await is this Undo's own outcome.
  Future<void> _undo(
    InboxProvider inbox,
    Conversation conversation,
    DateTime deletedAt,
  ) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await inbox.undoDelete(conversation, deletedAt);
    if (!mounted || inbox.error == null) return;
    messenger
      ..clearSnackBars()
      // The line, never the exception (INB-24).
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.changeFailed),
          duration: _undoDuration,
          persist: false,
        ),
      );
  }
}

/// The line the list carries while its last conversation is inside an Undo
/// window (INB-6, INB-15).
///
/// A sentence and nothing else: the Undo it refers to is on screen already, so
/// this states why the list is empty and gets out of the way when the window
/// closes. Scrollable for the same reason INB-15's states are — the 1.3x text
/// scale INB-23 renders at, on a phone, in every language.
///
/// INB-24: it names no conversation, no sender and no app, so it is safe over
/// a locked screen for exactly the reason INB-15's states are.
class _PendingUndoNotice extends StatelessWidget {
  const _PendingUndoNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: Metrics.gutter,
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// The way into the included-apps list (INB-20, INB-22).
///
/// An `InkResponse` and not an `IconButton`, so this bar affordance is not one
/// of the *actions* INB-15 counts: that rule gives each empty state exactly one
/// action, and a second `ButtonStyleButton` on the same screen is precisely
/// what it forbids. INB-23's two requirements are met directly instead — a
/// 48dp target on its shorter side, and a semantic label from the message
/// files.
class _IncludedAppsButton extends StatelessWidget {
  const _IncludedAppsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Semantics(
      button: true,
      label: l10n.semanticsIncludedApps,
      excludeSemantics: true,
      // The excluded subtree takes the `InkResponse`'s tap action with it, so
      // the action is declared here or a screen reader cannot open this
      // (INB-23). The tooltip stays: it is a long-press affordance for a
      // sighted user on a bare icon, which is what a tooltip is for.
      onTap: onPressed,
      child: Tooltip(
        message: l10n.semanticsIncludedApps,
        child: InkResponse(
          onTap: onPressed,
          radius: Metrics.minTarget / 2,
          child: const SizedBox(
            // INB-23's floor, on both sides.
            width: Metrics.minTarget,
            height: Metrics.minTarget,
            child: Icon(Icons.tune),
          ),
        ),
      ),
    );
  }
}

/// One row and the control its swipe reveals (INB-1, INB-6).
class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.now,
    required this.isOpen,
    required this.onOpenChanged,
    required this.onTap,
    required this.onDelete,
    super.key,
  });

  final InboxRow row;
  final DateTime now;
  final bool isOpen;
  final ValueChanged<bool> onOpenChanged;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return SwipeToReveal(
      extent: Metrics.deleteExtent,
      isOpen: isOpen,
      onOpenChanged: onOpenChanged,
      action: _DeleteControl(row: row, onPressed: onDelete),
      // Opaque, and its own `Material`: the control sits behind the row, so a
      // row painted on nothing would show Delete through its own text the
      // moment the swipe began.
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: ConversationRow(row: row, now: now, onTap: onTap),
      ),
    );
  }
}

/// The one control INB-6's swipe reveals.
class _DeleteControl extends StatelessWidget {
  const _DeleteControl({required this.row, required this.onPressed});

  final InboxRow row;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // INB-2 and INB-12: an unnamed conversation and a raw one are both named by
    // their source app, so the sentence a screen reader hears for this control
    // has to name it the way the row above it does — through INB-1's one chain
    // (`source_app.dart`), and not through the stored label alone. This was
    // `row.app?.label ?? package`, which was two branches short of the chain:
    // it skipped the package manager, and a stored label of `''` won the
    // fallback, so the control announced `Delete` and then nothing at all.
    //
    // The face is resolved here rather than shared with the row because the
    // swipe builds this control only while it is open (`swipe_to_reveal.dart`),
    // so a closed row pays nothing for it.
    return SourceAppFace(
      package: row.conversation.package,
      builder: (BuildContext context, SourceAppIdentity? identity) =>
          _control(context, identity),
    );
  }

  Widget _control(BuildContext context, SourceAppIdentity? identity) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String title = row.isUnnamed || row.isRaw
        ? sourceAppLabel(
            package: row.conversation.package,
            identity: identity,
            app: row.app,
          )
        : row.conversation.title;

    return Semantics(
      button: true,
      label: l10n.semanticsDeleteConversation(title),
      excludeSemantics: true,
      // `excludeSemantics` stops the subtree being visited at all, so the
      // `InkWell`'s tap action never reached this node and a screen reader had
      // a control it could read and not activate. The action is declared here
      // instead. A sighted tap still goes through the `InkWell` — this is the
      // same `onPressed`, reached the other way (INB-6, INB-23).
      onTap: onPressed,
      child: Material(
        color: scheme.errorContainer,
        child: InkWell(
          // No confirmation stands after it (INB-6, INB-18): this is the whole
          // delete.
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            // The control is drawn the full height of its row, and the row is
            // only as tall as a title and a preview. At the 1.3x text scale
            // INB-23 renders at, an icon plus two lines of `labelMedium` is
            // taller than that, and a `Column` of fixed children in a box it
            // has outgrown overflows — which INB-23 counts as a failure. So the
            // label is the part that gives: `Flexible` lets it take one line
            // where there is no room for two, and the ellipsis keeps a longer
            // language's word inside the control rather than over its edge.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  Icons.delete_outline,
                  color: scheme.onErrorContainer,
                  size: 22,
                ),
                const SizedBox(height: 2),
                Flexible(
                  child: Text(
                    l10n.deleteConversation,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
