import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/shipped_apps.dart';
import '../db/repository.dart';
import '../models/conversation.dart';
import '../models/initials.dart';
import '../models/message.dart';
import '../models/source_app.dart';
import '../services/services.dart';

/// "Capture wrote something", as one thing every provider can listen to
/// (INB-25).
///
/// INB-25 gives the app one second from the `EventChannel` event to a message
/// being on an open list **and** an open thread, with no pull-to-refresh. The
/// drain loop already calls back when it has written something, but a single
/// callback can only reach one object, and the thread screen is a second one
/// that has to redraw for the same event. So the callback nudges this, and
/// every provider that can be on screen listens to it.
///
/// A [ChangeNotifier] rather than a stream because that is what the providers
/// already are, and because the sync's own callback is a `VoidCallback`:
/// `captureSync.start(onChanged: signal.captured)` is the whole wiring, and it
/// belongs to whoever builds the tree.
///
/// It carries nothing. What changed is in the database by the time this fires —
/// that is the point of writing first — so a payload would only be a second
/// copy of the truth for a listener to disagree with.
class CaptureSignal extends ChangeNotifier {
  /// Capture stored something. Safe to call when nothing is listening.
  void captured() => notifyListeners();
}

/// Which of the three failures a screen is looking at.
///
/// Three, because the screen has to say three different things and a bare
/// exception cannot tell them apart. RUN-1 and product principle 3 both turn on
/// the app naming what it could not do rather than drawing a blank where the
/// answer should be.
enum FailureKind {
  /// A read did not land. Whatever the screen is drawing is stale or empty —
  /// and an empty list after a failed read is not *Nothing yet* (INB-15), which
  /// is a statement about the database that this read never got to make.
  read,

  /// A write did not land, so nothing moved: the database and the screen still
  /// agree, and the action can simply be taken again.
  write,

  /// The row was written and CAP-1's filter never heard it (INB-22).
  ///
  /// The worst of the three and the reason they are kept apart: the switch on
  /// screen and the row on disk both say on, and the listener is still dropping
  /// that package's notifications before the queue — messages lost, not
  /// delayed, until the next launch or resume re-mirrors. The user has to be
  /// told, because nothing they can see is wrong.
  captureFilter,
}

/// A failure, in the one shape every screen in this area reads.
///
/// The providers hold this rather than the raw exception, for the same reason
/// [CaptureSignal] is shared: a screen may not be left to guess what an
/// arbitrary `Object` meant, and two failures that need two different sentences
/// may not arrive looking identical. [cause] is kept for a fault report and is
/// never drawn — INB-24 forbids putting a database error's text, which can
/// carry a title or a sender, on screen.
@immutable
class StateFailure {
  const StateFailure(this.kind, this.cause, {this.package});

  final FailureKind kind;

  /// What was thrown. Diagnostic only.
  final Object cause;

  /// The row the failed write was about, where it was about one (INB-22).
  final String? package;

  @override
  String toString() =>
      'StateFailure($kind${package == null ? '' : ', $package'}: $cause)';
}

/// `notifyListeners` that is safe to call from a read that a screen started.
///
/// Two things go wrong otherwise, and both are ordinary rather than exotic:
///
///  * a screen's first read starts from `didChangeDependencies`, which runs
///    **inside the build** the provider is being read in, so a flag raised and
///    announced synchronously marks that element dirty mid-build and the
///    framework reports it (INB-20's chooser is the path the real app always
///    takes);
///  * the tree can come down while that read is still in flight, and the read
///    then finishes into a disposed notifier, which throws.
///
/// [notify] answers both: the first announcement of a read lands on a
/// microtask, after the build that started it has finished, and nothing is
/// announced once [dispose] has run.
mixin DeferredNotifier on ChangeNotifier {
  bool _disposed = false;

  /// Whether this notifier is dead. Every `await` in a provider is a place the
  /// tree can come down, so the code after one checks this before it writes.
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Announce now, unless we are already gone.
  void notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Announce after the caller's own synchronous work — a build, most of the
  /// time — has finished.
  Future<void> notifyLater() async {
    await Future<void>.microtask(() {});
    notify();
  }
}

/// One row of the conversation list (INB-1).
///
/// Everything the row draws is already decided here, because a screen that
/// works out its own unread count or its own initials is a screen holding
/// state. What is *not* here is any formatted string: the time, the `99+`, the
/// sender-prefixed preview and every empty-state sentence are message-file
/// lines, and a value object that built them would have to know the locale
/// (LANG-3, LANG-4).
@immutable
class InboxRow {
  const InboxRow({
    required this.conversation,
    required this.app,
    required this.newestMessage,
    required this.unreadCount,
  });

  final Conversation conversation;

  /// The `apps` row this conversation came from, or null where the listener
  /// never wrote one. Null is not an error: it is INB-1's last fallback, where
  /// the row shows a generic source icon and the package name.
  final SourceApp? app;

  /// The message the preview is taken from, or null for a thread whose
  /// messages have all been deleted (DEL-1).
  final Message? newestMessage;

  /// INB-5's count, uncapped. The cap is [unreadOverflows]; the `99+` itself is
  /// `unreadCountOverflow` in the message files.
  final int unreadCount;

  String get id => conversation.id;

  /// INB-1: the unread count is drawn only when it is not zero.
  bool get hasUnread => unreadCount > 0;

  /// INB-5: shown up to 99 and as `99+` beyond.
  bool get unreadOverflows => unreadCount > 99;

  /// The time INB-1 puts on the row, which INB-4 also sorts on.
  DateTime get time => conversation.lastMessageAt;

  /// INB-1: a group conversation's preview is prefixed with the sender's name
  /// and a colon, a one-to-one conversation's is not. An empty sender has no
  /// name to prefix with, so it is not prefixed with an empty one.
  bool get previewNamesSender =>
      conversation.isGroup && (newestMessage?.sender.isNotEmpty ?? false);

  /// INB-12: a raw conversation (CAP-21) is titled with the source app's name
  /// and draws the app icon alone, and its preview is the notification's own
  /// title and text rather than a chat line.
  bool get isRaw => conversation.keySource == KeySource.package;

  /// INB-2: the notification arrived without a name, so the row is titled with
  /// the app's name and carries the `conversationUnnamed` line. Conditioned on
  /// the empty title and never on `key_source`, because a conversation can hold
  /// a resolved key and no title at once.
  bool get isUnnamed => conversation.isUnnamed;

  /// INB-1's leading circle: up to two initials from the first two words of the
  /// title. Empty where the row draws the app icon alone (INB-2, INB-12).
  ///
  /// The rule itself is `initialsOf` in `models/initials.dart`, shared with
  /// INB-8's sender circle in the thread. It used to live here as a static, and
  /// the thread kept a private copy of it that the 23 September 2026 correction
  /// was not carried into — so the row stopped drawing `(1` for a phone number
  /// and the bubble beside it did not. What is left here is the part that *is*
  /// the list's: which rows have no name to take initials from at all.
  String get initials =>
      isUnnamed || isRaw ? '' : initialsOf(conversation.title);
}

/// One chip in INB-14's filter row.
@immutable
class InboxChip {
  const InboxChip({
    required this.package,
    required this.app,
    required this.conversationCount,
    required this.newestMessageAt,
    required this.selected,
  });

  final String package;

  /// The `apps` row, for its label. Null falls back to the package name
  /// (INB-1).
  final SourceApp? app;

  /// How many conversations the list can show from this app right now. Zero on
  /// a chip that is only still here because it is selected, or because its last
  /// conversation is inside a pending Undo (INB-6, INB-14).
  final int conversationCount;

  /// This app's newest message, which is what INB-14 orders on. Null when it
  /// has none the list can show.
  final DateTime? newestMessageAt;

  final bool selected;
}

/// Which of INB-15's empty states the inbox is in.
///
/// Three of the four. The fourth, *Only a pending Undo*, is last in INB-15's
/// order and carries no action, so it is [InboxEmptyState.onlyPendingUndoLeft]
/// rather than a value here — see that field.
enum InboxEmptyKind {
  /// Not empty.
  none,

  /// Nothing is stored at all.
  nothingYet,

  /// A chip selection matches no conversation.
  nothingInFilter,

  /// A search returned nothing. Area SRCH fills this one in; the inbox never
  /// reaches it until a search exists to return nothing.
  noResults,
}

/// What INB-15's empty state has to say, without saying it.
///
/// The states are exclusive and ordered: where more than one condition holds,
/// the first in [InboxEmptyKind]'s order wins — and [onlyPendingUndoLeft], the
/// fourth, loses to all three. That choice is made here so no screen can make
/// it differently.
@immutable
class InboxEmptyState {
  const InboxEmptyState({
    required this.kind,
    this.namedApps = const <SourceApp>[],
    this.otherAppCount = 0,
    this.filteredApps = const <SourceApp>[],
    this.filteredPackages = const <String>[],
    this.hasCaptureGap = false,
    this.onlyPendingUndoLeft = false,
  });

  final InboxEmptyKind kind;

  /// *Nothing yet*: up to three included apps, most recently seen first
  /// (INB-15).
  final List<SourceApp> namedApps;

  /// How many included apps are not in [namedApps].
  final int otherAppCount;

  /// *Nothing in this filter*: the selected apps, for the line that names them.
  /// A selected package with no `apps` row is in [filteredPackages] and not
  /// here.
  final List<SourceApp> filteredApps;

  /// Every selected package, `apps` row or not.
  final List<String> filteredPackages;

  /// Whether a capture gap exists, which *Nothing yet* states as "nothing was
  /// seen while access was off" (CAP-12). Only gaps longer than
  /// [Repository.minimumReportedGap] count, so a rebind at boot never produces
  /// this line.
  final bool hasCaptureGap;

  /// INB-15's fourth state, *Only a pending Undo*: the database holds nothing
  /// but the conversation the user has just deleted, which is inside its
  /// five-second Undo window (INB-6, DEL-2).
  ///
  /// It is none of the other three, which is why the rule had to name it.
  /// *Nothing yet* is a claim about the whole database — that only messages
  /// arriving from now on can appear and there is no history from before
  /// install — and here there is history, one tap away; *Nothing in this
  /// filter* needs a selection and there is none; *No results* needs a search.
  /// Without this the screen draws a zero-item list: five seconds of blank
  /// behind the snackbar, which is the one thing INB-15 says no empty state is.
  ///
  /// It has no action of its own. The action is the Undo the snackbar already
  /// carries, on [InboxProvider.pendingUndo], and a second control offering the
  /// same thing is the two buttons INB-15 forbids.
  ///
  /// Precedence: last, exactly as INB-15 now orders it, so every named state
  /// above it wins. That is what [kind] staying [InboxEmptyKind.none] here
  /// encodes — the screen draws this notice only where [isEmpty] is false, and
  /// a selection that also matches nothing is still *Nothing in this filter*,
  /// whose action clears the filter and shows the pending row's app again.
  ///
  /// A flag beside [kind] rather than a fourth [InboxEmptyKind], and the rule
  /// says so too: [isEmpty] is what gates the screen's branch into
  /// `InboxEmptyStates`, which builds a sentence and a button for each of the
  /// three, and this state has neither. Folding it in would mean a fourth value
  /// that [isEmpty] has to exclude, which says less clearly what this field
  /// says plainly.
  final bool onlyPendingUndoLeft;

  bool get isEmpty => kind != InboxEmptyKind.none;
}

/// The inbox's state.
///
/// Every mutation here follows the same order: **write first, then change
/// state, and roll back on failure.** The opposite order — update the list,
/// then persist — is what produces a UI that shows something the database
/// does not have, which survives until the next restart and then looks to the
/// user like data loss.
class InboxProvider extends ChangeNotifier with DeferredNotifier {
  /// Both dependencies are injected, never reached for: that is what lets a
  /// test hand over an in-memory database and the no-op services. Positional
  /// because Dart has no private named parameters, and these fields have no
  /// business being public.
  ///
  /// [captureSignal] is INB-25's other half: with one, a message captured while
  /// this list is on screen redraws it within the second, with no
  /// pull-to-refresh. Without one the list only moves when someone calls
  /// [load]. [clock] is injected for the same reason the database is — a test
  /// that has to wait for a real clock is a test that is slow and flaky.
  InboxProvider(
    this._repository,
    this._services, {
    CaptureSignal? captureSignal,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow {
    _captureSignal = captureSignal;
    _captureSignal?.addListener(_onCaptured);
  }

  static DateTime _utcNow() => DateTime.now().toUtc();

  final Repository _repository;
  final DeviceServices _services;
  final DateTime Function() _clock;
  CaptureSignal? _captureSignal;

  List<Conversation> _conversations = const <Conversation>[];
  List<InboxRow> _rows = const <InboxRow>[];
  List<InboxChip> _chips = const <InboxChip>[];
  List<SourceApp> _apps = const <SourceApp>[];
  Set<String> _filter = const <String>{};
  InboxEmptyState _emptyState = const InboxEmptyState(
    kind: InboxEmptyKind.none,
  );
  ({Conversation conversation, DateTime deletedAt})? _pendingUndo;
  bool _loading = false;
  StateFailure? _error;

  List<Conversation> get conversations => _conversations;

  /// The list, assembled (INB-1). Ordered exactly as
  /// [Repository.conversations] returned it, which is INB-4's order.
  List<InboxRow> get rows => _rows;

  /// INB-14's chip row, without `All`: that one is pinned by the screen and is
  /// selected exactly when [filter] is empty.
  List<InboxChip> get chips => _chips;

  List<SourceApp> get apps => _apps;

  /// Packages the list is filtered to. Empty means no filter (INB-14).
  Set<String> get filter => _filter;

  /// Which of INB-15's empty states holds, and what it needs to say it.
  InboxEmptyState get emptyState => _emptyState;

  /// The conversation inside its Undo window, and the instant it was deleted
  /// (INB-6, DEL-2).
  ///
  /// The screen shows its snackbar for about five seconds and then calls
  /// [forgetPendingUndo]. Until it does, this row is out of the list, out of
  /// every filter and out of its chip's count — but its chip stays in the row,
  /// which is the one thing INB-6 says survives the window.
  ({Conversation conversation, DateTime deletedAt})? get pendingUndo =>
      _pendingUndo;

  bool get isLoading => _loading;

  /// The last failure, for the screen to show. Cleared by the next successful
  /// read or mutation, never silently.
  ///
  /// **The screen reads this before anything else.** The four states are
  /// exclusive and in this order: a failure, then [isLoading] with nothing
  /// drawn yet, then [emptyState], then the rows. A failed read leaves the list
  /// empty and [emptyState] at [InboxEmptyKind.none] — it never reached the
  /// question — and a screen that skipped this getter would draw that as a
  /// zero-item list: a blank white screen with no sentence on it, which is
  /// exactly the failure RUN-1 and product principle 3 exist to prevent.
  ///
  /// [FailureKind.captureFilter] never reaches this getter, because this screen
  /// holds no switch: INB-22's switch lives on the included-apps list, and
  /// `AppsProvider` is the one provider that writes a row and mirrors CAP-1's
  /// filter down. This list only ever reads.
  StateFailure? get error => _error;

  /// Whether the list on screen is empty because a read failed rather than
  /// because nothing is stored.
  bool get failedToLoad => _error?.kind == FailureKind.read && _rows.isEmpty;

  /// Whether replying in place is possible for this conversation right now
  /// (CAP-14). Always false after a cold start, which is why the inbox needs
  /// "open in app" before the Reply area exists (INB-13).
  bool canReplyTo(Conversation conversation) =>
      _services.reply.canReplyTo(conversation);

  @override
  void dispose() {
    _captureSignal?.removeListener(_onCaptured);
    _captureSignal = null;
    super.dispose();
  }

  /// A loud read: the spinner goes up first. For a cold start and for anything
  /// the user asked for.
  Future<void> load() async {
    _loading = true;
    // Announced on a microtask rather than here: a screen's first read starts
    // from inside a build (see [DeferredNotifier]).
    await notifyLater();
    if (isDisposed) return;
    try {
      await _read();
      _error = null;
    } catch (e) {
      _error = StateFailure(FailureKind.read, e);
    } finally {
      _loading = false;
      notify();
    }
  }

  /// The same read without the spinner (INB-25).
  ///
  /// A message arriving while the list is open must reach it within a second
  /// and "without leaving the screen"; raising the loading flag for that would
  /// blank a list the user is reading every time somebody writes to them.
  Future<void> refresh() async {
    try {
      await _read();
      _error = null;
    } catch (e) {
      _error = StateFailure(FailureKind.read, e);
    }
    notify();
  }

  void _onCaptured() {
    // Fire and forget: the signal is a `VoidCallback` from the drain loop, and
    // making the loop wait on a screen's read would put the queue behind the
    // UI.
    //
    // Coalesced, because this read is the expensive one — every conversation,
    // one newest-message query per four hundred of them, the unread aggregate
    // and the per-package aggregate — and the signal fires per message. The
    // spike's own fixture delivered five under one timestamp (INB-4), so a
    // burst ran all of that five times over with the reads overlapping. One in
    // flight and one queued behind it covers everything that arrived in the
    // meantime, because the queued read sees the whole database, and INB-25's
    // second is kept: the second read starts the moment the first returns.
    if (_reading) {
      _readAgain = true;
      return;
    }
    unawaited(_refreshCoalesced());
  }

  bool _reading = false;
  bool _readAgain = false;

  Future<void> _refreshCoalesced() async {
    _reading = true;
    try {
      do {
        _readAgain = false;
        await refresh();
      } while (_readAgain && !isDisposed);
    } finally {
      _reading = false;
    }
  }

  Future<void> _read() async {
    final DateTime now = _clock();
    _apps = await _repository.allApps();
    final Map<String, PackageActivity> activity = await _repository
        .conversationActivityByPackage();
    _conversations = await _repository.conversations(
      packages: _filter.isEmpty ? null : _filter.toList(),
    );
    final Map<String, Message> newest = await _repository.newestMessages(
      _conversations,
    );
    final Map<String, int> unread = await _repository.unreadCounts(
      packages: _filter.isEmpty ? null : _filter.toList(),
    );
    final Map<String, SourceApp> byPackage = <String, SourceApp>{
      for (final SourceApp app in _apps) app.package: app,
    };

    _rows = <InboxRow>[
      for (final Conversation c in _conversations)
        InboxRow(
          conversation: c,
          app: byPackage[c.package],
          newestMessage: newest[c.id],
          unreadCount: unread[c.id] ?? 0,
        ),
    ];
    _chips = _buildChips(activity, byPackage);
    _emptyState = await _buildEmptyState(activity, now);
  }

  /// INB-14's chip row.
  ///
  /// Membership is "one chip per source app with at least one conversation the
  /// list can show", plus two exceptions the rules make explicit and which are
  /// the reason this is not simply the keys of [activity]:
  ///
  ///  * a **selected** chip stays after its app's last conversation is deleted,
  ///    and leaves the moment it is deselected or on the next cold start. That
  ///    is how INB-15's *Nothing in this filter* state is reachable at all:
  ///    drop the chip the instant its count hits zero and the filter clears
  ///    itself, and the user never sees why the list went empty.
  ///  * a chip whose app's last conversation is inside a **pending Undo** stays
  ///    until the window closes (INB-6), so the row does not shuffle under the
  ///    hand that is reaching for Undo.
  ///
  /// The order is the app's newest message descending, then package ascending
  /// (INB-14, following INB-4). A chip with nothing showable has no newest
  /// message, so it sorts after every chip that has one — it is there on
  /// sufferance and does not get to push a live app down the row.
  List<InboxChip> _buildChips(
    Map<String, PackageActivity> activity,
    Map<String, SourceApp> byPackage,
  ) {
    final Set<String> packages = <String>{
      ...activity.keys,
      ..._filter,
      ?_pendingUndo?.conversation.package,
    };
    final List<InboxChip> chips = <InboxChip>[
      for (final String package in packages)
        InboxChip(
          package: package,
          app: byPackage[package],
          conversationCount: activity[package]?.conversations ?? 0,
          newestMessageAt: activity[package]?.newestMessageAt,
          selected: _filter.contains(package),
        ),
    ];
    chips.sort((InboxChip a, InboxChip b) {
      final DateTime? at = a.newestMessageAt;
      final DateTime? bt = b.newestMessageAt;
      if (at != null && bt != null && at != bt) return bt.compareTo(at);
      if (at == null && bt != null) return 1;
      if (at != null && bt == null) return -1;
      return a.package.compareTo(b.package);
    });
    return chips;
  }

  /// INB-15's four empty states, in the order the rule fixes.
  Future<InboxEmptyState> _buildEmptyState(
    Map<String, PackageActivity> activity,
    DateTime now,
  ) async {
    // *Nothing yet* asks about the whole database and not about the filtered
    // read: a forgotten filter must never be able to make the app claim it has
    // captured nothing at all.
    //
    // The two halves of `activity.isEmpty` split cleanly, which is why there is
    // no ordering question between them: with no pending Undo the database is
    // genuinely empty and this is *Nothing yet*; with one, everything the app
    // holds is inside that window and [InboxEmptyState.onlyPendingUndoLeft] is
    // what the screen says instead of drawing five seconds of blank.
    final bool onlyPendingUndoLeft =
        activity.isEmpty && _pendingUndo != null && _rows.isEmpty;
    final bool nothingStored = activity.isEmpty && _pendingUndo == null;
    if (nothingStored) {
      final List<SourceApp> included = await _includedApps(now);
      final List<CaptureGap> gaps = await _repository.captureGaps(now: now);
      return InboxEmptyState(
        kind: InboxEmptyKind.nothingYet,
        namedApps: included.take(3).toList(growable: false),
        otherAppCount: included.length <= 3 ? 0 : included.length - 3,
        hasCaptureGap: gaps.isNotEmpty,
      );
    }
    if (_rows.isEmpty && _filter.isNotEmpty) {
      return InboxEmptyState(
        kind: InboxEmptyKind.nothingInFilter,
        filteredPackages: _filter.toList(growable: false),
        filteredApps: <SourceApp>[
          for (final SourceApp a in _apps)
            if (_filter.contains(a.package)) a,
        ],
        onlyPendingUndoLeft: onlyPendingUndoLeft,
      );
    }
    return InboxEmptyState(
      kind: InboxEmptyKind.none,
      onlyPendingUndoLeft: onlyPendingUndoLeft,
    );
  }

  /// The apps *Nothing yet* names, most recently seen first (INB-15).
  ///
  /// Built the way INB-20 says the chooser is built — the shipped messaging
  /// list unioned with the packages the listener has actually seen post — and
  /// not from the `apps` table alone. The table alone was the bug: INB-20 is
  /// explicit that a shipped app has **no row until it posts**, so on a fresh
  /// install every included app is missing from it, the list comes back empty,
  /// and the screen falls through to the line that names nothing. That is the
  /// one moment this state is ever on screen, so the rule's whole point was
  /// never exercised on the path it exists for.
  ///
  /// A shipped package with no row is carried as a row-shaped value with no id
  /// and no stored label: there is no row, and inventing one on disk to draw a
  /// sentence would be a write nobody asked for. Its label comes from the
  /// package manager, which INB-1 makes the first source for a package inside
  /// INB-16's `<queries>` — and the shipped six are exactly that declaration.
  ///
  /// **And only if the package manager actually resolves it.** INB-15 names
  /// apps whose messages can appear here, so a shipped package this phone does
  /// not have cannot be one of them, and a lookup that answered
  /// [PackagePresence.unknown] is not a name the app may put in a sentence that
  /// claims to name apps (INB-16: it says less rather than guessing). Where
  /// nothing resolves, the list is as empty as it was and the screen keeps the
  /// label-free line — the honest fallback, rather than six raw package names.
  ///
  /// Order: `last_seen_at` descending, so an app that has posted comes before
  /// one that never has ([Repository.neverSeenPosting] is epoch and sorts
  /// last), then package ascending so two reads can never disagree (INB-4's
  /// discipline).
  Future<List<SourceApp>> _includedApps(DateTime now) async {
    final Map<String, SourceApp> byPackage = <String, SourceApp>{
      for (final SourceApp a in _apps) a.package: a,
    };
    final List<SourceApp> included = <SourceApp>[];
    for (final String package in <String>{
      ...shippedMessagingApps,
      ...byPackage.keys,
    }) {
      final SourceApp? row = byPackage[package];
      // CAP-1's default for a package with no row: on for the shipped list, and
      // there is nothing else without a row.
      final bool enabled = row?.enabled ?? isShippedMessagingApp(package);
      if (!enabled) continue;
      if (row != null) {
        included.add(row);
        continue;
      }
      final SourceApp? installed = await _shippedWithNoRow(package, now);
      if (installed != null) included.add(installed);
    }
    included.sort((SourceApp a, SourceApp b) {
      final int bySeen = b.lastSeenAt.compareTo(a.lastSeenAt);
      return bySeen != 0 ? bySeen : a.package.compareTo(b.package);
    });
    return included;
  }

  /// A shipped app that is on this phone and has not posted yet, or null where
  /// the package manager cannot say that it is.
  Future<SourceApp?> _shippedWithNoRow(String package, DateTime now) async {
    final SourceAppIdentity identity = await _services.packages.lookup(package);
    if (identity.presence != PackagePresence.installed) return null;
    final String? label = identity.label;
    if (label == null || label.isEmpty) return null;
    return SourceApp(
      // No row, so no id. Never written and never matched against one.
      id: '',
      package: package,
      label: label,
      enabled: true,
      lastSeenAt: Repository.neverSeenPosting,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Replaces the chip selection (INB-14). A filter is a view: it hides rows,
  /// changes no `enabled` flag and deletes nothing.
  Future<void> setFilter(Set<String> packages) async {
    _filter = packages;
    await load();
  }

  /// One chip tapped. App chips are multi-select, and `All` is selected exactly
  /// when no app chip is (INB-14).
  Future<void> toggleFilter(String package) async {
    final Set<String> next = <String>{..._filter};
    if (!next.remove(package)) next.add(package);
    await setFilter(next);
  }

  /// `All` tapped, or INB-15's *Nothing in this filter* action.
  Future<void> clearFilter() => setFilter(const <String>{});

  /// Deletes a conversation and everything in it (CAP-16, DEL-1, DEL-2).
  ///
  /// Returns the instant it was deleted, which [undoDelete] needs to restore
  /// exactly the messages this step took and no others (CAP-23).
  Future<DateTime?> deleteConversation(
    Conversation conversation,
    DateTime now,
  ) async {
    final List<Conversation> before = _conversations;
    try {
      await _repository.deleteConversation(conversation.id, now);
    } catch (e) {
      _error = StateFailure(FailureKind.write, e);
      notify();
      return null;
    }
    // Only now does the list change, and only because the write succeeded.
    _conversations = before
        .where((Conversation c) => c.id != conversation.id)
        .toList(growable: false);
    _rows = _rows
        .where((InboxRow r) => r.id != conversation.id)
        .toList(growable: false);
    // One slot, overwritten rather than added to, because one slot is what is
    // on screen: INB-6's Undo lives in DEL-2's snackbar, and the screen clears
    // the previous snackbar before it shows this one, so at most one
    // conversation is ever undoable. A set here would hold the earlier delete
    // open — its chip in the row (INB-14), its sentence in INB-15's fourth
    // state — for an Undo the user can no longer reach, which is the same
    // mismatch between state and screen as the one below, pointing the other
    // way.
    _pendingUndo = (conversation: conversation, deletedAt: now);
    _error = null;
    // The chip row and the empty state both move with the delete — the count
    // drops, and a filter that now matches nothing becomes INB-15's second
    // state — so the read that decides them runs rather than being guessed at
    // here.
    await refresh();
    return now;
  }

  Future<void> undoDelete(Conversation conversation, DateTime deletedAt) async {
    try {
      await _repository.undeleteConversation(conversation.id, deletedAt);
    } catch (e) {
      _error = StateFailure(FailureKind.write, e);
      notify();
      return;
    }
    // Targeted for the same reason [forgetPendingUndo] is: an Undo tapped in
    // the instant a second delete takes the slot restores its own conversation
    // — it was passed in — and must not close the window of the delete that
    // replaced it.
    _clearPendingUndo(conversation);
    await load();
  }

  /// An Undo window closed without being used (INB-6, DEL-2). The chip its app
  /// was holding open now leaves the row.
  ///
  /// **Targeted on [conversation].** One slot and two closings is an ordinary
  /// sequence, not an exotic one: delete A, delete B inside A's five seconds.
  /// B takes the slot, and showing B's snackbar clears A's — which resolves the
  /// screen's wait on A's snackbar with a non-action reason, so A's closing
  /// arrives *after* B took the slot. Untargeted, that closing cleared B: B's
  /// chip left the row and INB-15's fourth state went with it while B's Undo
  /// was still on screen. The restore itself was never at risk, because the
  /// screen's Undo closes over its own conversation — which is exactly why this
  /// was worth fixing here, the wrong thing was the state, and the state is the
  /// only thing that can be asked.
  ///
  /// So a closing that names a conversation the slot no longer holds is a
  /// no-op, and nothing has to reason about which delete resolved first.
  ///
  /// The argument-less form closes whichever single window is open. That is
  /// what a caller with no conversation in hand means, and the only one is a
  /// test driving DEL-2's five seconds by hand where there is exactly one.
  Future<void> forgetPendingUndo([Conversation? conversation]) async {
    if (!_clearPendingUndo(conversation)) return;
    await refresh();
  }

  /// Drops the pending Undo if it is still [conversation]'s, or if the caller
  /// named none. Answers whether anything moved, so a stale closing does not
  /// pay for a read.
  bool _clearPendingUndo(Conversation? conversation) {
    final ({Conversation conversation, DateTime deletedAt})? held =
        _pendingUndo;
    if (held == null) return false;
    if (conversation != null && held.conversation.id != conversation.id) {
      return false;
    }
    _pendingUndo = null;
    return true;
  }
}
