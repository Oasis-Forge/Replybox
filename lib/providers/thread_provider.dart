import 'dart:async';

// `widgets` rather than `foundation`: INB-5's gate is the app's lifecycle, and
// `WidgetsBindingObserver` is how a provider hears about it (see
// [ThreadProvider._watchLifecycle]). Nothing here builds or touches a widget.
import 'package:flutter/widgets.dart';

import '../db/repository.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/source_app.dart';
import '../services/services.dart';
import 'inbox_provider.dart';

/// Which of INB-10's three dates turned out to be the latest, and so what the
/// notice's date actually means.
///
/// The screen does not branch on this — the sentence is the same either way —
/// but a fault report that says only "since the 14th" cannot be told apart from
/// a wrong answer, and this is what makes the notice debuggable without a
/// second query.
enum ThreadHistoryStart {
  /// The app had not been installed before then (CAP-12).
  installedAt,

  /// The listener had never bound before then.
  captureSession,

  /// This source app's own row was not on before then (CAP-1, INB-22).
  appCaptureSession,

  /// None of the three is stored, so the date is the oldest message the thread
  /// holds — the one instant the app can prove it was capturing for this
  /// conversation.
  oldestMessage,
}

/// What INB-10's standing notice has to state, as data.
///
/// Every thread's first row is this notice, and it is not dismissible: the app
/// holds only what arrived as a notification, and a message edited, unsent or
/// deleted in the source app still reads here as it first arrived (CAP-26).
/// That part is a constant line in the message files and needs nothing from
/// here.
///
/// What does need working out is everything below, and none of it is a string:
/// the date, whether access was off until it, and which absence since then is
/// worth naming. The message files turn this into `threadHistorySince`,
/// `threadHistoryAccessOffUntil`, `threadHistoryGaps`,
/// `threadHistoryRetention` and — for [ThreadHistoryNotice.hidesOlderMessages]
/// — the line saying the thread draws its newest
/// [ThreadHistoryNotice.windowSize] messages and holds older ones it is not
/// showing; a value object that built those sentences would
/// have to know the locale and the user's date format (LANG-3).
@immutable
class ThreadHistoryNotice {
  const ThreadHistoryNotice({
    required this.historyBegins,
    required this.begins,
    required this.accessOffUntilBegins,
    this.mostRecentGap,
    this.otherGapCount = 0,
    this.retentionFrom,
    this.oldestShownAt,
    this.windowSize = Repository.threadWindow,
  });

  /// The date the app could first have seen anything for this conversation:
  /// the latest of `installed_at`, the first `capture_sessions` bind, and the
  /// start of the earliest `app_capture_sessions` row for this source app
  /// (INB-10, CAP-1, CAP-12).
  final DateTime historyBegins;

  /// Which of the three [historyBegins] came from.
  final ThreadHistoryStart begins;

  /// Whether no capture session existed before [historyBegins], which the
  /// notice states as access having been off until then (INB-10).
  final bool accessOffUntilBegins;

  /// The most recent absence overlapping this thread's range, or null where
  /// none does (INB-10).
  ///
  /// Only gaps longer than [Repository.minimumReportedGap] reach here, so a
  /// rebind at boot is never reported as an absence anyone noticed.
  final CaptureGap? mostRecentGap;

  /// How many other qualifying gaps overlap the range. The notice names one
  /// and counts the rest rather than listing every absence above a thread.
  final int otherGapCount;

  /// Area RET's window, once it ships. Null until then, and this is the only
  /// place that has to change when it does.
  final DateTime? retentionFrom;

  /// The arrival time of the oldest message actually on screen, and null unless
  /// the thread holds more than [windowSize] messages.
  ///
  /// Non-null is the one state INB-10's date cannot be read literally in: the
  /// notice names the date the app could first have seen anything for this
  /// conversation, and between that date and this one the thread holds messages
  /// the screen is not drawing. Naming the first date and drawing nothing for
  /// the span after it is precisely the blank INB-10 exists to prevent, so the
  /// notice states the window in the same breath (product principle 3).
  ///
  /// This is **not** area RET's window and must never be worded as one: nothing
  /// was removed. The messages are stored, the read is bounded, and what the
  /// sentence has to say is that older messages are held and not shown here.
  final DateTime? oldestShownAt;

  /// How many messages a thread reads at once ([Repository.threadWindow]), for
  /// the sentence that states it.
  final int windowSize;

  /// Whether stored messages older than [oldestShownAt] exist and are not on
  /// screen.
  ///
  /// INB-10 forbids the top of the thread implying more can be loaded — no
  /// spinner, and scrolling to the top loads nothing — so this is a sentence the
  /// screen states, never a control it draws.
  bool get hidesOlderMessages => oldestShownAt != null;

  /// INB-10: where a retention window is in force and is later than
  /// [historyBegins], the notice names the window instead — a date on screen
  /// beside a thread that no longer reaches it is worse than no date.
  bool get namesRetention =>
      retentionFrom != null && retentionFrom!.isAfter(historyBegins);

  /// The date the notice actually prints.
  DateTime get since => namesRetention ? retentionFrom! : historyBegins;

  /// Whether a gap is named at all.
  bool get hasGap => mostRecentGap != null;
}

/// One drawn line of a thread: a message, and what INB-7 and INB-8 say goes
/// around it.
@immutable
class ThreadEntry {
  const ThreadEntry({
    required this.message,
    required this.startsDay,
    required this.showsSender,
  });

  final Message message;

  /// INB-8: a date separator sits above this message, because it is the first
  /// of its local calendar day.
  ///
  /// Computed from the arrival time in the device's **current** time zone and
  /// never from a stored calendar date, so a message re-groups under a new
  /// separator if the zone changes. DATE-1 is about a date the user picks and
  /// does not apply here.
  final bool startsDay;

  /// INB-8: an inbound message shows its sender's name in a group conversation
  /// and not in a one-to-one. An outbound message never does (INB-9), and
  /// neither does one whose direction could not be decided — that one is drawn
  /// with no side and no sender rather than guessed into one.
  final bool showsSender;
}

/// One open thread (INB-7 to INB-13).
///
/// Separate from [InboxProvider] rather than a field on it, because the two
/// have different lifetimes: the list is alive for the whole run and the thread
/// is alive while one is open. Folding the thread into the list would leave the
/// list holding a conversation's whole message history for as long as the app
/// is running.
///
/// Every mutation here follows the house order: **write first, then change
/// state, and roll back on failure.**
class ThreadProvider extends ChangeNotifier
    with DeferredNotifier, WidgetsBindingObserver {
  ThreadProvider(
    this._repository,
    this._services, {
    CaptureSignal? captureSignal,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow {
    _captureSignal = captureSignal;
    _captureSignal?.addListener(_onCaptured);
    _watchLifecycle();
  }

  static DateTime _utcNow() => DateTime.now().toUtc();

  final Repository _repository;
  final DeviceServices _services;
  final DateTime Function() _clock;
  CaptureSignal? _captureSignal;

  /// Whether this thread is being looked at (INB-5).
  ///
  /// True until a lifecycle event says otherwise, because that is the state a
  /// thread is opened in and because a run with no binding to hear from — a
  /// unit test — has no screen that could be anything but drawn.
  bool _resumed = true;
  bool _observing = false;

  String? _conversationId;
  Conversation? _conversation;
  SourceApp? _sourceApp;
  List<ThreadEntry> _entries = const <ThreadEntry>[];
  ThreadHistoryNotice? _notice;
  bool _loading = false;
  StateFailure? _error;

  /// Whether the last read found the conversation row gone (INB-6, DEL-1).
  bool _gone = false;

  /// What the last notice was computed over, so a capture signal about another
  /// app does not re-run four session queries to arrive at the same sentence.
  /// See [_read].
  String? _noticeSignature;

  String? get conversationId => _conversationId;
  Conversation? get conversation => _conversation;

  /// The `apps` row this thread came from. Null where the listener never wrote
  /// one, which INB-1 draws as a generic source icon and the package name.
  SourceApp? get sourceApp => _sourceApp;

  /// INB-22: a thread from an app whose row is off carries a standing line
  /// saying no further messages will arrive in it while the row stays off, so a
  /// thread that stopped at the moment the switch flipped never reads as a
  /// conversation that simply went quiet.
  ///
  /// True where there is no row at all: a package the listener has not seen is
  /// not an app the user switched off, and claiming otherwise would put a line
  /// on a thread about a switch nobody moved.
  bool get sourceAppEnabled => _sourceApp?.enabled ?? true;

  /// The thread, oldest at the top and newest at the bottom (INB-7).
  List<ThreadEntry> get entries => _entries;

  /// INB-10's notice. Null only before the first load lands.
  ThreadHistoryNotice? get notice => _notice;

  bool get isLoading => _loading;

  /// The last failure, for the screen to show (see `InboxProvider.error`, which
  /// sets out the order the states are read in). A thread that failed to load
  /// draws no messages and no notice, and a screen that ignored this would draw
  /// that as an empty thread rather than as an app that could not answer.
  StateFailure? get error => _error;

  /// The conversation this thread was opened on is not there any more: swiped
  /// away from the list while the thread sat on a route behind it, or its app's
  /// stored messages removed from the included-apps screen (INB-6, INB-22,
  /// DEL-1).
  ///
  /// **A state of its own, and not a failure and not an empty thread.** Nothing
  /// failed — the read answered correctly — and the thread is not a conversation
  /// the app captured nothing for. Without this the screen sees not-loading, no
  /// error and no entries, and draws a conversation with nothing in it under a
  /// stale title, which is the app claiming to have seen nothing where in fact
  /// it saw everything and the user deleted it (product principle 3).
  ///
  /// The conversation may still be inside its five-second Undo window, so the
  /// sentence says the conversation was deleted and never that it is gone for
  /// good.
  bool get conversationGone => _gone;

  /// INB-7, and the one thing this screen cannot show: the thread holds more
  /// than [Repository.threadWindow] messages, so what is drawn is its newest
  /// [Repository.threadWindow] and there is nothing older on screen.
  ///
  /// The same fact as [ThreadHistoryNotice.hidesOlderMessages], and it lives
  /// there because it is part of one sentence with INB-10's date: the notice is
  /// the thread's first row, and a date that the drawn messages do not reach is
  /// only honest beside the reason they do not.
  bool get isWindowed => _notice?.hidesOlderMessages ?? false;

  /// How many messages a thread reads at once, for the line that states it.
  int get window => Repository.threadWindow;

  /// Whether a live reply action is held for this thread in this process
  /// (CAP-14).
  ///
  /// False is the ordinary state after a cold start, and INB-13's control is
  /// what stands in the same place when it is.
  bool get canReply {
    final Conversation? c = _conversation;
    return c != null && _services.reply.canReplyTo(c);
  }

  /// INB-13: the bottom bar holds `Open in app` in place of a reply field
  /// whenever there is no live action **and** whenever the newest message is
  /// hidden, whatever the action map holds — a capability declined rather than
  /// a platform limit (INB-3, decision 8).
  bool get newestMessageHidden =>
      _entries.isNotEmpty && _entries.last.message.kind == MessageKind.hidden;

  bool get showsOpenInApp => !canReply || newestMessageHidden;

  /// INB-5's gate, and the reason this provider watches the binding at all.
  ///
  /// Nothing else can tell it. The screen builds this object and hands it a
  /// conversation id; it does not report that the phone went to the home
  /// screen, and [CaptureSignal] fires on every drain whether anyone is looking
  /// or not. Without the gate the sequence is: open Ana's thread, press Home —
  /// the route is still alive and Dart is still running — Ana sends three
  /// messages, the drain fires the signal, the read advances `read_through_at`
  /// past all three, and coming back there is no unread badge, ever, for
  /// messages that were never drawn.
  void _watchLifecycle() {
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } on Object {
      // No binding, which is a unit test that never builds a widget: there are
      // no lifecycle events to gate on and nothing on screen to be wrong.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool resumed = state == AppLifecycleState.resumed;
    if (resumed == _resumed) return;
    _resumed = resumed;
    // INB-5: a message that arrived while nobody was looking is marked read as
    // it is drawn, which is now — so the read that draws it is the read that
    // advances the marker, and the two can never come apart.
    if (resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    _captureSignal?.removeListener(_onCaptured);
    _captureSignal = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    super.dispose();
  }

  /// Opens a thread. Loud: the spinner goes up first.
  Future<void> open(String conversationId) async {
    _conversationId = conversationId;
    _conversation = null;
    _entries = const <ThreadEntry>[];
    _notice = null;
    _noticeSignature = null;
    _gone = false;
    _loading = true;
    // The screen starts this from `initState`, inside the build that mounts it
    // (see [DeferredNotifier]).
    await notifyLater();
    if (isDisposed) return;
    try {
      await _read();
      _error = null;
    } catch (e) {
      _error = StateFailure(FailureKind.read, e);
    } finally {
      _loading = false;
      // The route can be popped while this read is in flight, and the screen
      // disposes the provider on its way out.
      notify();
    }
  }

  /// The same read without the spinner (INB-25).
  ///
  /// A message captured while this thread is open reaches it within a second of
  /// the event and without leaving the screen, so this must not blank what the
  /// reader is looking at.
  Future<void> refresh() async {
    if (_conversationId == null) return;
    try {
      await _read();
      _error = null;
    } catch (e) {
      _error = StateFailure(FailureKind.read, e);
    }
    notify();
  }

  /// The screen left. Drops the history rather than leaving a thread's worth of
  /// messages in memory behind a list.
  void close() {
    _conversationId = null;
    _conversation = null;
    _sourceApp = null;
    _entries = const <ThreadEntry>[];
    _notice = null;
    _noticeSignature = null;
    _error = null;
    _gone = false;
    notify();
  }

  void _onCaptured() {
    // Coalesced rather than fired once per event. The signal fires for a message
    // from any app, and the spike's own fixture delivered five under one
    // timestamp: without this a burst runs this thread's whole read five times
    // over, each one overlapping the last. One read is in flight, one more is
    // queued behind it, and anything that arrives in between is covered by that
    // second read — which is what keeps INB-25's second while the reads stay
    // proportional to the bursts rather than to the messages.
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
    final String id = _conversationId!;
    final DateTime now = _clock();
    final Conversation? conversation = await _repository.conversationById(id);
    if (conversation == null) {
      // Deleted underneath us, which is an ordinary outcome: the row can be
      // swiped away from the list while its thread is still on a route
      // somebody backed out of, and the included-apps screen removes a whole
      // package's conversations in one step (INB-6, INB-22, DEL-1).
      //
      // Said, not merely emptied. [conversationGone] is what stops the screen
      // drawing this as a conversation the app captured nothing for.
      _conversation = null;
      _sourceApp = null;
      _entries = const <ThreadEntry>[];
      _notice = null;
      _noticeSignature = null;
      _gone = true;
      return;
    }
    _gone = false;

    // Bounded, because this runs on open **and** on every capture signal —
    // which fires for a message from any app, not only this one. Unbounded, a
    // ten-thousand-message thread materialised ten thousand objects, then ran
    // the read marker and four more queries for the notice, every time anybody
    // wrote to the phone. [Repository.threadWindow] says what a longer thread
    // shows, and [ThreadHistoryNotice.hidesOlderMessages] is what says it on
    // screen.
    //
    // One past the window, and the extra row is read for one purpose: it is the
    // only way to know the window is hiding something. Comparing the oldest
    // stored time against the oldest drawn one cannot tell — ties are real
    // (INB-4), so the 501st message can share an instant with the 500th, and the
    // thread would then drop it while reporting nothing hidden.
    final List<Message> read = await _repository.messages(
      id,
      limit: Repository.threadWindow + 1,
    );
    final bool windowed = read.length > Repository.threadWindow;
    final List<Message> messages = windowed ? read.sublist(1) : read;
    // The real beginning of the thread, which the window may not reach. One
    // row, and INB-10's notice needs it whether or not the window did.
    final DateTime? oldestAt = await _repository.oldestMessageAt(id);
    _sourceApp = await _repository.appByPackage(conversation.package);
    _entries = _entriesFor(conversation, messages);

    // INB-5: opening the thread advances the read marker to the newest message
    // the conversation holds, whatever was scrolled — and a message arriving
    // while the thread is open is marked read **as it is drawn**, which is what
    // [_resumed] gates on. A read is not a drawing: the capture signal fires on
    // every drain, so without the gate a thread left open behind the home
    // screen marked three new messages read that nobody ever saw.
    //
    // Written before the state changes, and forward only: `markReadThrough`
    // refuses an advance to a message older than the stored value, so a late
    // `APP_CANCEL` on an older notification cannot un-read newer messages
    // (CAP-22).
    if (messages.isNotEmpty && _resumed) {
      final DateTime through = messages.last.sentAt;
      final bool moved = await _repository.markReadThrough(
        conversationId: id,
        through: through,
        at: now,
      );
      _conversation = moved
          ? conversation.copyWith(readThroughAt: through, updatedAt: now)
          : conversation;
    } else {
      _conversation = conversation;
    }

    // Four more reads — `installed_at`, two session starts and the gap scan —
    // and none of their answers can change because a message arrived for
    // *another app*. Recomputing only when something the notice is made of
    // moved is what keeps a capture signal from costing seven queries per open
    // thread, on top of the list's own.
    //
    // What the signature covers: this thread's range, which is what a gap has
    // to overlap to be named, and this source app's row, whose `updated_at`
    // moves whenever INB-22's switch writes an `app_capture_sessions` row the
    // date is taken from. What it does not cover is the first `capture_sessions`
    // bind ever arriving while this very thread is open — `installed_at` is
    // written at launch and a later gap cannot overlap a range that ends before
    // it, so that one case is the whole of it, and it is corrected the next time
    // the thread is opened.
    final DateTime? rangeEnd = messages.isEmpty ? null : messages.last.sentAt;
    final String signature =
        '$id|$oldestAt|$rangeEnd|${messages.length}|$windowed'
        '|${_sourceApp?.updatedAt}';
    if (_notice == null || signature != _noticeSignature) {
      _notice = await _historyNotice(
        conversation,
        messages,
        oldestAt,
        now,
        oldestShownAt: windowed ? messages.first.sentAt : null,
      );
      _noticeSignature = signature;
    }
  }

  /// INB-7's order comes from the repository; INB-8's separators and sender
  /// names are decided here, because both depend on the device's current time
  /// zone and on the conversation, and a screen that worked them out would be a
  /// screen holding state.
  List<ThreadEntry> _entriesFor(
    Conversation conversation,
    List<Message> messages,
  ) {
    final List<ThreadEntry> entries = <ThreadEntry>[];
    DateTime? previousDay;
    for (final Message message in messages) {
      final DateTime local = message.sentAt.toLocal();
      final DateTime day = DateTime(local.year, local.month, local.day);
      entries.add(
        ThreadEntry(
          message: message,
          startsDay: previousDay == null || day != previousDay,
          showsSender:
              conversation.isGroup &&
              message.direction == Direction.inbound &&
              message.sender.isNotEmpty,
        ),
      );
      previousDay = day;
    }
    return entries;
  }

  /// Assembles INB-10's notice.
  ///
  /// The date is "the latest of `installed_at`, the first `capture_sessions`
  /// bind, and the start of the earliest `app_capture_sessions` row for this
  /// source app". Each can be missing and each missing one means something
  /// different, so none of them is defaulted:
  ///
  ///  * no `installed_at` — nothing has written it yet this launch — leaves the
  ///    other two to answer;
  ///  * no `capture_sessions` row means the listener has never bound, and the
  ///    notice then says access was off until the date it does name;
  ///  * no `app_capture_sessions` row for this package is the ordinary case for
  ///    a shipped app captured by default (CAP-1), because only the switch
  ///    moving writes one. It is not a date of zero, and defaulting it to epoch
  ///    would make every such thread claim a history running back to 1970.
  ///
  /// With all three missing the thread still needs a date, and the oldest
  /// message it holds is the one instant the app can prove it was capturing —
  /// the same argument `closeOpenCaptureSessionsAtLastEvidence` makes, and for
  /// the same reason: every instant claimed has a stored message standing
  /// behind it. [now] is the last resort, for a thread with no messages at all.
  ///
  /// "Where no session existed before that date it says access was off until
  /// then" is read literally: a bind that *is* the date had no session before
  /// it, so a thread whose history starts at the first ever bind says access
  /// was off until then, which is exactly true.
  /// [oldestAt] is the thread's real oldest message, which [messages] may not
  /// reach: the read is bounded to [Repository.threadWindow] and the notice is
  /// a statement about the whole thread, not about the window.
  ///
  /// [oldestShownAt] is the other half of being honest about that. The date
  /// above is deliberately read past the window, so on a thread longer than the
  /// window the notice names a date the drawn messages do not reach — and a
  /// date on screen with nothing under it is the blank INB-10 exists to name.
  /// Non-null here is the screen's instruction to say so.
  Future<ThreadHistoryNotice> _historyNotice(
    Conversation conversation,
    List<Message> messages,
    DateTime? oldestAt,
    DateTime now, {
    DateTime? oldestShownAt,
  }) async {
    final DateTime? installedAt = await _repository.installedAtOrNull();
    final DateTime? firstBind = await _repository.firstCaptureSessionStart();
    final DateTime? firstAppSession = await _repository
        .firstCaptureSessionStart(package: conversation.package);

    DateTime? latest;
    ThreadHistoryStart? latestFrom;
    void consider(DateTime? candidate, ThreadHistoryStart source) {
      if (candidate == null) return;
      if (latest == null || candidate.isAfter(latest!)) {
        latest = candidate;
        latestFrom = source;
      }
    }

    consider(installedAt, ThreadHistoryStart.installedAt);
    consider(firstBind, ThreadHistoryStart.captureSession);
    consider(firstAppSession, ThreadHistoryStart.appCaptureSession);

    final DateTime begins = latest ?? (oldestAt ?? now);
    final ThreadHistoryStart from =
        latestFrom ?? ThreadHistoryStart.oldestMessage;

    // The thread's range: from its oldest message to its newest. A thread with
    // no messages has no range, and nothing can overlap it — which is right,
    // because there is nothing on screen for a gap to be an absence in.
    //
    // The oldest is the thread's own and not the window's: a gap that fell
    // before the newest five hundred messages is still an absence in this
    // thread, and the notice is about the thread.
    final DateTime? rangeStart = oldestAt;
    final DateTime? rangeEnd = messages.isEmpty ? null : messages.last.sentAt;

    List<CaptureGap> overlapping = const <CaptureGap>[];
    if (rangeStart != null && rangeEnd != null) {
      final List<CaptureGap> gaps = await _repository.captureGaps(
        package: conversation.package,
        now: now,
      );
      overlapping = <CaptureGap>[
        for (final CaptureGap gap in gaps)
          // "A *later* gap": one that is over before the history even begins
          // took nothing from this thread.
          if (gap.to.isAfter(begins) && gap.overlaps(rangeStart, rangeEnd)) gap,
      ];
    }

    return ThreadHistoryNotice(
      historyBegins: begins,
      begins: from,
      // No capture session started strictly before the date the notice names.
      accessOffUntilBegins: firstBind == null || !firstBind.isBefore(begins),
      // `captureGaps` returns newest first.
      mostRecentGap: overlapping.isEmpty ? null : overlapping.first,
      otherGapCount: overlapping.isEmpty ? 0 : overlapping.length - 1,
      oldestShownAt: oldestShownAt,
    );
  }

  /// INB-13's control, on the path this area owns: the source app's launcher
  /// intent, with no extra, no message, no sender and no conversation
  /// identifier the app added (product principle 1).
  ///
  /// Returns whether the app opened. False is INB-13's snackbar — about five
  /// seconds, saying only that the app could not be opened — and it changes
  /// nothing on screen and leaves any typed text untouched, which is why this
  /// notifies nobody and reloads nothing.
  ///
  /// The other path, firing the notification's own content intent so the
  /// control reads `Open chat`, needs the in-memory action map and is the Reply
  /// area's to expose; a thread with no live action never had it.
  Future<bool> openSourceApp() async {
    final Conversation? c = _conversation;
    if (c == null) return false;
    try {
      return await _services.launcher.open(c.package);
    } catch (_) {
      // A launch that throws or resolves to nothing is the same outcome to the
      // user, and INB-13 says it changes nothing on screen either way.
      return false;
    }
  }
}
