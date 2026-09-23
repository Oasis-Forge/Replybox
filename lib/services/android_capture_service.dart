/// The Android side of capture: the two channels the Kotlin listener exposes,
/// and the loop that moves its queue into the app database.
///
/// Nothing in here is constructed outside `main.dart` (docs/STACK_NOTES.md):
/// a `MethodChannel` with no host on the other end is exactly the shape of the
/// real service that once hung the suite for ten minutes, so every entry point
/// below is guarded and degrades to the no-op answer off Android.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../capture/capture_event.dart';
import '../capture/ingest.dart';
import '../db/repository.dart';
import '../models/conversation.dart';
import '../models/source_app.dart';
import 'services.dart';

/// The channel names are part of the contract with the Kotlin side; they are
/// the store ID (`com.oasisforge.replybox`) and never a personal name.
const MethodChannel _captureChannel = MethodChannel(
  'com.oasisforge.replybox/capture',
);
const EventChannel _captureEventChannel = EventChannel(
  'com.oasisforge.replybox/capture_events',
);

/// One row of the native hand-over queue: its id and the event it carries.
///
/// The id is kept apart from the payload because CAP-15 releases a row only
/// when its event has been written, so the drain has to be able to ack some
/// rows and leave others.
@immutable
class QueuedCaptureEvent {
  const QueuedCaptureEvent({required this.rowId, required this.json});

  final String rowId;
  final Map<String, Object?> json;
}

/// A package the listener saw post a notification, captured or not (INB-20).
///
/// `enabledByDefault` is the listener's answer to CAP-1's first-sighting rule,
/// not a user choice: it is only ever consulted for a row the database does
/// not have yet.
@immutable
class SeenSourceApp {
  const SeenSourceApp({
    required this.package,
    required this.label,
    required this.lastSeenAt,
    required this.enabledByDefault,
  });

  final String package;
  final String label;
  final DateTime lastSeenAt;
  final bool enabledByDefault;
}

/// The listener, over its `MethodChannel` and `EventChannel`.
///
/// Only [hasAccess], [openAccessSettings], [events] and [setEnabledPackages]
/// are the interface the state layer sees, the last of them through the narrow
/// `CaptureFilter` rather than through this class. The queue methods are
/// deliberately not on either interface: a provider has no business draining or
/// acking, and an interface that carried them would invite one to try.
class AndroidNotificationSource implements NotificationSource, CaptureFilter {
  const AndroidNotificationSource();

  /// PERM-6. False when there is no listener to ask: an absent answer is
  /// reported as "no access", never as access, so no screen ever claims the
  /// app can see notifications it cannot.
  @override
  Future<bool> hasAccess() async => await _invoke<bool>('hasAccess') ?? false;

  /// PERM-7. Returns once the settings page has been asked for, not once the
  /// user has decided — the system tells us nothing about that.
  ///
  /// Throws a `PlatformException` on a device with no notification-access
  /// screen at all. That is deliberately not swallowed: a button that silently
  /// does nothing is the one thing PERM-7's screen must not be.
  @override
  Future<void> openAccessSettings() async =>
      _invoke<void>('openAccessSettings');

  /// Live events while Dart is running (INB-25). Empty off Android, so a test
  /// that subscribes gets a stream that closes rather than one that never
  /// produces and never ends.
  ///
  /// The *same* stream every call, which is the whole point — see
  /// [_sharedCaptureEvents].
  @override
  Stream<Map<String, Object?>> events() => _sharedCaptureEvents;

  /// PERM-10. Three answers, and the null is carried through rather than
  /// flattened.
  ///
  /// `_invoke` already answers null for a build with no host and for a
  /// `MissingPluginException`, and the Kotlin side answers `null` when neither
  /// lifecycle callback has fired in this process (`ListenerState`). Those are
  /// the same observation — nothing learned — so both reach the caller as null
  /// and neither is turned into a false. That is the opposite of [hasAccess]
  /// one method above, and the difference is deliberate: an unanswerable
  /// `hasAccess` reads as "no access" because the safe direction there is
  /// claiming *less* about what the app can see, while an unanswerable
  /// `listenerConnected` read as false would make the app claim *more* — it
  /// would put `capture is not running right now` on screen on the strength of
  /// a channel that did not reply (PERM-10, product principle 3).
  @override
  Future<bool?> listenerConnected() async => _invoke<bool>('listenerConnected');

  /// PERM-10. True means the rebind was asked for, and nothing more.
  ///
  /// An absent answer is false — the request could not be made — which is the
  /// honest reading and is also spent the same way: PERM-10 waits its ten
  /// seconds and asks [listenerConnected] again either way, so the two outcomes
  /// never diverge on screen.
  @override
  Future<bool> requestListenerRebind() async =>
      await _invoke<bool>('requestListenerRebind') ?? false;

  /// Everything the listener queued while Dart was not running (CAP-13).
  ///
  /// Draining does not delete: [ackQueue] does, and only for the rows whose
  /// events were written (CAP-15).
  Future<List<QueuedCaptureEvent>> drainQueue() async {
    final List<Object?>? rows = await _invoke<List<Object?>>('drainQueue');
    if (rows == null) return const <QueuedCaptureEvent>[];
    final List<QueuedCaptureEvent> drained = <QueuedCaptureEvent>[];
    for (final Object? row in rows) {
      final QueuedCaptureEvent? parsed = _parseRow(row);
      if (parsed != null) drained.add(parsed);
    }
    return drained;
  }

  /// Deletes exactly these rows. Called after the write that consumed them.
  Future<void> ackQueue(List<String> rowIds) async {
    if (rowIds.isEmpty) return;
    await _invoke<void>('ackQueue', rowIds);
  }

  /// The packages the listener has seen and not yet been acked for (INB-20).
  ///
  /// It does **not** clear. Taking and clearing in one step meant a package
  /// whose row failed to write — or a pass that threw anywhere after this call
  /// — lost that sighting for good, and INB-20/INB-21 build the chooser from
  /// this list alone, so the user could then never switch that app on. Clearing
  /// is [ackSeenApps], and only for the packages whose row actually landed,
  /// exactly as [drainQueue] and [ackQueue] split for CAP-15.
  Future<List<SeenSourceApp>> takeSeenApps() async {
    final List<Object?>? rows = await _invoke<List<Object?>>('takeSeenApps');
    if (rows == null) return const <SeenSourceApp>[];
    final List<SeenSourceApp> apps = <SeenSourceApp>[];
    for (final Object? row in rows) {
      if (row is! Map) continue;
      final Object? package = row['package'];
      if (package is! String || package.isEmpty) continue;
      apps.add(
        SeenSourceApp(
          package: package,
          // A label the package manager could not resolve is not invented
          // here: INB-1 falls back to the package name on screen, so an empty
          // label is a real value and not a defect.
          label: row['label'] as String? ?? '',
          lastSeenAt: _timeFromMillis(row['lastSeenAt']),
          enabledByDefault: row['enabledByDefault'] as bool? ?? false,
        ),
      );
    }
    return apps;
  }

  /// Clears exactly these packages from the listener's pending list.
  ///
  /// Called after their `apps` rows are written. A package left un-acked comes
  /// back on the next [takeSeenApps] and is simply written again — an upsert,
  /// so the repeat is harmless, and INB-22 is safe because `enabledIfNew` only
  /// ever touches a row that does not exist.
  Future<void> ackSeenApps(List<String> packages) async {
    if (packages.isEmpty) return;
    await _invoke<void>('ackSeenApps', packages);
  }

  /// The filter CAP-1 applies before anything reaches the queue. The database
  /// is the only authority on what is on, so this is a mirror, never a merge.
  ///
  /// [known] is what makes it a mirror the listener can trust. The listener
  /// keeps a package of its own only while it has never been handed to us — a
  /// first sighting CAP-1 defaulted on, which has no row for the database to
  /// have an opinion about yet. Sending the packages we *do* hold a row for
  /// bounds that: a package in [known] and not in [packages] is off on the
  /// phone the moment this returns, whatever the listener still has pending
  /// (CAP-1, INB-22).
  ///
  /// Named arguments across the channel, because two lists of package names in
  /// a row are one transposition away from capturing the wrong apps.
  @override
  Future<void> setEnabledPackages(
    List<String> packages,
    List<String> known,
  ) async => _invoke<void>('setEnabledPackages', <String, Object?>{
    'enabled': packages,
    'known': known,
  });

  /// What capture could not do, from the listener's own fault record.
  ///
  /// Asked rather than pushed, for the same reason `hasAccess` is: the listener
  /// runs when Dart does not, so the counters move while nobody is listening,
  /// and a snapshot read on every pass is the only reading that is complete.
  /// An absent answer is no faults, never an invented one.
  Future<CaptureFaults> captureFaults() async {
    final Map<Object?, Object?>? row = await _invoke<Map<Object?, Object?>>(
      'captureFaults',
    );
    if (row == null) return const CaptureFaults();
    return CaptureFaults(
      queueWriteFailures: row['queueWriteFailures'] as int? ?? 0,
      lastQueueWriteFailureAt: _instantFromMillis(
        row['lastQueueWriteFailureAt'],
      ),
      storeWriteFailures: row['storeWriteFailures'] as int? ?? 0,
      lastStoreWriteFailureAt: _instantFromMillis(
        row['lastStoreWriteFailureAt'],
      ),
      storeUnreadable: row['storeUnreadable'] as bool? ?? false,
    );
  }

  static QueuedCaptureEvent? _parseRow(Object? row) {
    if (row is! String) return null;
    // "<rowId>\t<json>": a tab, because no notification field the listener
    // projects can contain one — the row id is not derived from content.
    final int tab = row.indexOf('\t');
    if (tab <= 0) return null;
    final Map<String, Object?>? json = _decodeEvent(row.substring(tab + 1));
    if (json == null) return null;
    return QueuedCaptureEvent(rowId: row.substring(0, tab), json: json);
  }

  static Map<String, Object?>? _decodeEvent(String source) {
    try {
      final Object? decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      return Map<String, Object?>.from(decoded);
    } on FormatException {
      return null;
    }
  }

  /// An absent `lastSeenAt` becomes now, which is the only honest reading: the
  /// listener is telling us about a sighting it has just handed over, and
  /// INB-21 orders this list by it, so a zero would sort a live app to the
  /// bottom for ever.
  ///
  /// An out-of-range one becomes now for the same reason, and the throw is
  /// caught rather than left to escape: this runs while the pending list is
  /// being read, and one unreadable millisecond used to take down the whole
  /// pass — no rows written, no queue drained, and under INB-20/INB-21 every
  /// package in that batch missing from the chooser, which is the one list the
  /// user can switch an app on from. A row we keep with a slightly wrong time
  /// sorts oddly once; a row we drop cannot be turned on at all.
  static DateTime _timeFromMillis(Object? value) {
    if (value is! int) return DateTime.now().toUtc();
    try {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    } on Object {
      return DateTime.now().toUtc();
    }
  }

  /// Like [_timeFromMillis] but for a field where "never" is a real answer, so
  /// absent and the native record's zero both read as null. Guarded the same
  /// way: a fault report must not be the thing that breaks a pass.
  static DateTime? _instantFromMillis(Object? value) {
    if (value is! int || value <= 0) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    } on Object {
      return null;
    }
  }
}

/// Whether a listener can exist at all on this platform.
bool get _hasHost => Platform.isAndroid;

/// One stream over the `EventChannel`, shared by every caller of [events].
///
/// The native side attaches and detaches a **single** sink
/// (`CaptureEvents.attach`/`detach`). A second `receiveBroadcastStream()` builds
/// a second controller, whose `onListen` replaces the first's sink, and whose
/// `onCancel` nulls the sink for both — so the drain loop would stop being
/// nudged the moment a second subscriber came and went, and INB-25's one-second
/// deadline would quietly become "the next resume". CaptureSync is the only
/// subscriber today; PERM-8's banner is the second.
///
/// Sharing one broadcast controller is what makes the counting right instead:
/// `onListen` fires on the first subscriber and `onCancel` only when the last
/// one leaves.
///
/// Lazy, because a top-level `final` in Dart is: nothing touches the channel on
/// a platform that has no host, and off Android this is the empty stream, which
/// closes rather than hanging a test for ever.
final Stream<Map<String, Object?>> _sharedCaptureEvents = _hasHost
    ? _captureEventChannel
          .receiveBroadcastStream()
          .map<Map<String, Object?>?>((Object? event) {
            if (event is! String) return null;
            return AndroidNotificationSource._decodeEvent(event);
          })
          .where((Map<String, Object?>? event) => event != null)
          .cast<Map<String, Object?>>()
    : const Stream<Map<String, Object?>>.empty();

/// Every call to the listener goes through here.
///
/// Null means "there is nobody to ask", and every caller above turns that into
/// the no-op answer. `MissingPluginException` is the same condition reached a
/// different way — a test binding, or a build where the Kotlin side is not
/// registered — and is treated identically rather than crashing a screen.
Future<T?> _invoke<T>(String method, [Object? arguments]) async {
  if (!_hasHost) return null;
  try {
    return await _captureChannel.invokeMethod<T>(method, arguments);
  } on MissingPluginException {
    return null;
  }
}

/// PERM-14's pages, over the same channel and the same [_invoke] guard.
///
/// Not a second channel and not a plugin: all three of these are one-line
/// Kotlin `when` branches beside the notification-access intents that
/// `CaptureChannel` already owns, and none of them declares a permission
/// (PERM-15). Putting them here rather than on [AndroidNotificationSource] is
/// the interface's own argument repeated in the implementation — a page about
/// battery is not a fact about notifications, and folding them together would
/// give a provider that only needs a settings page a handle on the drain.
///
/// Every method degrades to [NoopSystemSettings]'s answer off Android with no
/// guard of its own, because `_invoke` answers null for a build with no host
/// and for a `MissingPluginException` alike. That matters for the same reason
/// it matters everywhere else in this file: a `MethodChannel` with nobody on
/// the other end is the shape of the service that hung the suite for ten
/// minutes (docs/STACK_NOTES.md).
class AndroidSystemSettings implements SystemSettings {
  const AndroidSystemSettings();

  /// `Build.MANUFACTURER`, or null.
  ///
  /// The Kotlin side sends `""` for a field that is null or blank, and the
  /// empty string is mapped to null here rather than drawn: PERM-14 prints this
  /// into a sentence, and an empty name would render as
  /// `This phone reports its manufacturer as .` — the app asserting something
  /// about the hardware that the hardware did not say. The screen's other
  /// branch (`batteryGuidanceManufacturerUnknown`) exists precisely so a null
  /// has somewhere honest to go.
  ///
  /// Not trimmed or lower-cased here. The value is printed as-is (LANG-5) and
  /// `batteryGuidanceFor` normalises its own copy for the table lookup, so the
  /// two never share a mutation.
  @override
  Future<String?> manufacturer() async {
    final String? value = await _invoke<String>('deviceManufacturer');
    return (value == null || value.isEmpty) ? null : value;
  }

  /// True only when an activity actually started. An absent answer is false,
  /// which PERM-14 spends as PERM-7's written path — never as a page the user
  /// is now looking at.
  @override
  Future<bool> openBatteryOptimisationSettings() async =>
      await _invoke<bool>('openBatteryOptimisationSettings') ?? false;

  /// Same contract, this app's own app-info page (PERM-15's last clause: the
  /// route that replaces a runtime prompt the system will no longer show).
  @override
  Future<bool> openAppInfoSettings() async =>
      await _invoke<bool>('openAppInfoSettings') ?? false;
}

/// Replying in place, over the listener's in-memory action map.
///
/// CAP-14 makes repliability a property of this run: a `PendingIntent` cannot
/// be serialised, so there is nothing on disk to read and nothing worth
/// writing there. The listener holds the map; this class only asks it.
class AndroidReplyService implements ReplyService {
  AndroidReplyService();

  /// The last answer the listener gave for a conversation, by conversation id.
  ///
  /// This is a memo, not storage: it is built after launch, never read from or
  /// written to the database, and dies with the process — the same lifetime as
  /// the `PendingIntent` it describes (CAP-14). It starts empty, so a cold
  /// start answers false everywhere and the inbox shows "open in app"
  /// (INB-13) until something asks.
  final Map<String, bool> _liveThisRun = <String, bool>{};

  /// Synchronous because the state layer's interface is, and a screen cannot
  /// await while it builds a row. Unasked means false: claiming a reply field
  /// that is not there costs the user a typed message (INB-13).
  @override
  bool canReplyTo(Conversation conversation) =>
      _liveThisRun[conversation.id] ?? false;

  /// Asks the listener whether it still holds a live action for
  /// [notificationKey], and remembers the answer for [canReplyTo].
  ///
  /// Asked rather than stored (CAP-14): dismissal alone does not remove a held
  /// action, but a reconnection or a process death does, and only the listener
  /// knows which has happened.
  ///
  /// **Nothing in `lib/` calls this yet, so [canReplyTo] answers false on every
  /// conversation and every thread shows INB-13's `Open in app`.** That is the
  /// dead path, stated rather than left to be discovered: the map above starts
  /// empty and only this method ever writes to it.
  ///
  /// It is dead because the caller does not exist. The thread screen is what
  /// knows which conversation is open and which notification key its newest
  /// message carries, and INB-13 is where the answer is spent — so the call
  /// belongs in that screen's load, once per conversation opened, and the
  /// screen ships with area REP (`docs/ROADMAP.md`). Wiring it from a provider
  /// instead would mean asking the listener about every row in the list on
  /// every build, which is a binder call per row for an answer INB-13 needs
  /// once.
  ///
  /// Nothing is broken meanwhile, and that is deliberate rather than lucky:
  /// false is the honest answer for a cold start (a `PendingIntent` is not
  /// serialisable), `Open in app` is the same control in the same place as the
  /// reply field it will become (product principle 5, INB-13), and the failure
  /// this ordering avoids — claiming a reply field that is not there and
  /// costing the user a typed message — is the one that matters.
  Future<bool> refreshCanReplyTo(
    Conversation conversation,
    String notificationKey,
  ) async {
    final bool live =
        await _invoke<bool>('canReplyTo', notificationKey) ?? false;
    _liveThisRun[conversation.id] = live;
    return live;
  }

  /// Sending is the **Reply** item (area REP) in `docs/ROADMAP.md`. It throws
  /// rather than returning quietly, because a reply that silently did nothing
  /// is the one failure the user would not notice until the other person did.
  @override
  Future<void> send(Conversation conversation, String text) =>
      throw UnimplementedError(
        'sending a reply is the Reply item (area REP) in docs/ROADMAP.md',
      );
}

/// Moves the listener's queue into the app database, on launch and on resume.
///
/// The listener runs whether or not Dart does (docs/PLAN.md section 4), so
/// this is the only thing that makes a message captured at 3am visible at 8am.
class CaptureSync with WidgetsBindingObserver {
  /// Positional for the same reason `InboxProvider` is: Dart has no private
  /// named parameters, and none of these has any business being public.
  CaptureSync(this._source, this._repository, this._health);

  final AndroidNotificationSource _source;
  final Repository _repository;

  /// Where a fact the listener reported but could not act on lands, so it is
  /// reachable by a screen instead of dying in this class (see [CaptureHealth]).
  final CaptureHealth _health;

  /// The normaliser, which is what decides whether an event becomes a message
  /// at all (CAP-2, CAP-6, CAP-7, CAP-21). This class only decides what
  /// reaches it and what is acked afterwards.
  late final CaptureIngest _ingest = CaptureIngest(_repository);

  StreamSubscription<Map<String, Object?>>? _subscription;
  VoidCallback? _onChanged;

  /// Whether a pass is running, and whether one was asked for while it was.
  ///
  /// Two flags rather than one: dropping a request that arrives mid-pass is
  /// what would lose the last event of a burst. See [sync].
  bool _running = false;
  bool _again = false;

  /// [onChanged] is called after anything was written, so the screen that is
  /// already on it reloads (INB-25). It is a callback rather than a provider
  /// because this class knows about the database and not about the UI.
  void start({VoidCallback? onChanged}) {
    _onChanged = onChanged;
    WidgetsBinding.instance.addObserver(this);
    _subscription = _source.events().listen(
      _applyLive,
      // A channel error kills the subscription if it is unhandled, and a dead
      // subscription looks exactly like a quiet phone (section 9). The drain
      // on the next resume is what keeps capture working meanwhile.
      onError: (Object _) {},
    );
    unawaited(_launch());
  }

  /// The launch sequence, in order and awaited so it is an order rather than a
  /// race: **drain first, then settle the session against the access the app
  /// actually has.**
  ///
  /// It ran the other way round until a device showed what that costs. The close
  /// correctly ended the session access had been taken away under — and the very
  /// same launch's drain then applied a queued `listener_connected` whose
  /// `postTime` predates the revoke, opening a new session and leaving it open
  /// while access was off (drill, emulator-5554, API 37, 21 September 2026). The
  /// next launch closed that one, and opened another. CAP-12 was then telling
  /// the user capture had been on across a window in which it was off, which is
  /// the one direction that rule may not be wrong in — reached, this time, by
  /// the reconciliation's own fix.
  ///
  /// Draining first is what makes the reconciliation final: every lifecycle
  /// event the listener recorded while the app was dead has been applied by the
  /// time the access is read, so what is left is the app's real state and
  /// nothing can arrive behind it to reopen what was just closed. Applying a
  /// queued connect that really did happen is right — CAP-12 is a record of what
  /// the listener could see, not of what the app noticed. Leaving the window
  /// open when access is off is not, and that is the half this ordering fixes.
  ///
  /// The open-guard is untouched and stays where it is ([Repository.openCaptureSession]):
  /// the device confirmed it works, with eight binds and five
  /// `listener_connected` events producing one row and one open window.
  Future<void> _launch() async {
    await sync();
    await closeSessionAccessTookAway();
  }

  /// Closes a capture session that access was taken away under (CAP-12,
  /// PERM-8).
  ///
  /// `onListenerDisconnected` does not fire for a revoke at API 37 — checked
  /// with Dart dead, so the queue cannot have swallowed it; the process is torn
  /// down and nothing is delivered (drill, 21 September 2026). Nothing else
  /// ever closes the row, so without this the app would tell the user capture
  /// had been continuously on across a window in which it was off — the one
  /// direction CAP-12 may not be wrong in.
  ///
  /// Launch and not every pass, deliberately. This is a reconciliation of what
  /// the *last* run left behind; a session the running app opened is one it is
  /// watching, and closing that on a resume would shorten a window that is
  /// genuinely open. The instant the row is closed at is
  /// [Repository.closeOpenCaptureSessionsAtLastEvidence]'s choice, argued
  /// there.
  ///
  /// **Called after the launch drain, never before it** — [_launch] says why,
  /// and it is not a detail: run first, this method closes the window correctly
  /// and the drain behind it reopens one from a queued connect that predates the
  /// revoke.
  ///
  /// Guarded like everything else in this class: a listener that cannot answer
  /// must not be what stops a launch. An unanswerable `hasAccess` reads as no
  /// access (PERM-6), and closing a session the app cannot prove is the safe
  /// direction anyway.
  Future<void> closeSessionAccessTookAway() async {
    try {
      if (await _source.hasAccess()) return;
      await _repository.closeOpenCaptureSessionsAtLastEvidence(
        DateTime.now().toUtc(),
      );
    } on Object {
      // Nothing is lost by waiting: the next launch reconciles the same row,
      // and the row stays open meanwhile, which is the state this method
      // exists to correct rather than one it created.
    }
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _subscription = null;
    _onChanged = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(sync());
  }

  /// One pass: seen apps, then the enabled mirror, then the queue.
  ///
  /// Passes never overlap. Two drains overlapping would hand the same rows to
  /// the ingest twice and ack them twice, and two ingests interleaved inside a
  /// single conversation's read-modify-write can move `last_message_at`
  /// backwards, which INB-4 says decides the whole list's order.
  ///
  /// A request that arrives while a pass is running is **remembered, not
  /// dropped**. The events that nudge this are a burst — the spike's own
  /// fixture delivered five under one timestamp — and the last nudge of a burst
  /// is exactly the one that arrives while the pass it triggered is still
  /// draining. Dropping it left that event sitting in the queue until the next
  /// resume, which is precisely the delay INB-25 forbids for a message that
  /// arrived with the app open.
  Future<void> sync() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        // Cleared before the pass, so anything asked for *during* it is caught
        // by the loop rather than by the check that let us in here.
        _again = false;
        try {
          await _syncOnce();
        } on Object {
          // A channel or database failure here is not the last chance to
          // capture anything: the next resume runs the whole pass again, and a
          // row that was written but never acked is simply drained a second
          // time and recognised by CAP-5. What it must not do is reach the
          // engine as an unhandled async error and take the app down with it.
          //
          // Inside the loop, so a failing pass cannot swallow a pending
          // request; it terminates because a pass that drains nothing sets
          // nothing pending.
        }
      } while (_again);
    } finally {
      _running = false;
    }
  }

  Future<void> _syncOnce() async {
    // Order matters, and this is the reason: a package the listener enabled by
    // CAP-1's first-sighting rule exists only in this answer until it is
    // written. Mirroring the enabled set down before writing it would send back
    // a set that does not contain it and undo the default the listener just
    // applied — which is also why the native `setEnabledPackages` keeps a
    // package it has never handed over. The `known` list below is what bounds
    // that keeping to exactly those packages: everything this database has a row
    // for goes down with the mirror, so a package we know about and left out of
    // the enabled list is off at once (CAP-1, INB-22).
    final List<SeenSourceApp> seen = await _source.takeSeenApps();
    final List<String> seenWritten = <String>[];
    for (final SeenSourceApp app in seen) {
      // Guarded per app, not per batch. One package whose upsert throws — a
      // label the channel handed over as something the row cannot hold, a
      // constraint the migration has not reached — used to abandon the rest of
      // the batch, and under INB-20/INB-21 an app that never reaches this table
      // is an app the user can never switch on, because this list is the only
      // place a non-shipped package ever appears.
      try {
        await _repository.upsertSeenApp(
          package: app.package,
          label: app.label,
          // Only for a row that does not exist yet: `enabled` is the user's
          // (INB-22), and a re-sighting never moves it.
          enabledIfNew: app.enabledByDefault,
          at: app.lastSeenAt,
        );
        seenWritten.add(app.package);
      } on Object {
        // Left un-acked, so the listener still has it pending and the next
        // pass writes it again. Nothing is lost by waiting; the row was lost by
        // clearing.
      }
    }
    // Acked only now, and only for the rows that landed. This is the same split
    // CAP-15 makes for the event queue: the side that can lose the fact does
    // not release it until the side that keeps it has it.
    await _source.ackSeenApps(seenWritten);

    // Both lists off the one read, so the enabled set can never name a package
    // the known set leaves out.
    final List<SourceApp> apps = await _repository.allApps();
    await _source.setEnabledPackages(
      <String>[
        for (final SourceApp app in apps)
          if (app.enabled) app.package,
      ],
      <String>[for (final SourceApp app in apps) app.package],
    );

    final List<QueuedCaptureEvent> rows = await _source.drainQueue();
    final List<String> written = <String>[];
    bool changed = seenWritten.isNotEmpty;

    // The newest `postTime` of anything the listener handed over in this pass,
    // which is PERM-11's clock and not a record of this drain.
    //
    // Tracked here rather than in the ingest because PERM-11 counts events of
    // *any* kind — a message, a removal, a lifecycle callback — and the
    // ingest's job is deciding which of them become messages (CAP-2, CAP-21).
    // An event the rules dropped still proves the listener was alive and
    // delivering at that instant, which is the only thing this clock claims.
    DateTime? newestEvent;

    for (final QueuedCaptureEvent row in rows) {
      try {
        final CaptureEvent event = CaptureEvent.fromJson(row.json);
        // Before the apply, deliberately: the event's own time is evidence of
        // delivery whatever the ingest then does with it, and an ingest that
        // throws must not also lose the proof that something arrived.
        final DateTime? postTime = event.postTime;
        if (postTime != null &&
            (newestEvent == null || postTime.isAfter(newestEvent))) {
          newestEvent = postTime;
        }
        final IngestOutcome outcome = await _ingest.apply(event);
        // Acked whatever the outcome: an event the rules dropped (CAP-2,
        // CAP-6, CAP-7) or that was already stored (CAP-5) has been dealt
        // with, and a queue that only released stored events would never
        // empty on a phone full of ongoing notifications.
        written.add(row.rowId);
        changed = changed || _changedAnything(outcome);
      } on MessageIdentityCollision {
        // `Repository._insertMessage` throws this "loud on purpose": CAP-5's
        // matching missed a stored row, and the alternative — swallowing it —
        // is what made a message the user had just been sent vanish with
        // nothing on screen, which is the defect CAP-5's correction of
        // 21 September 2026 exists to stop. The bare `on Object` below caught
        // it anyway and put that silence straight back, so the one exception
        // in this app that is meant to be heard was the quietest thing in it.
        //
        // Recorded rather than rethrown: rethrowing here would abandon the
        // rest of the drain, and the other rows are innocent. The row stays
        // un-acked like any other failure, and the count reaches PERM-8's
        // banner through CaptureHealth (CAP-12, RUN-1).
        _health.noteMessageIdentityCollision(DateTime.now().toUtc());
        // The type and nothing else. `MessageIdentityCollision.toString()`
        // prints the `Message`, whose own `toString` prints the sender's name,
        // and INB-24 keeps a sender's name out of logcat in every build. Where
        // to look is fixed and needs no payload: Repository, idx_messages_identity.
        debugPrint(
          'capture: a MessageIdentityCollision left a row in the queue '
          '(CAP-5 matching vs idx_messages_identity)',
        );
      } on Object {
        // CAP-15 releases a row when its event has been written, so a row
        // whose ingest threw is left in the queue for the next pass. A row
        // that keeps failing is not retried for ever: the listener drops what
        // is still undrained after 30 days.
      }
    }
    if (written.isNotEmpty) await _source.ackQueue(written);
    if (changed) _onChanged?.call();

    // PERM-11's clock, written after the ack and guarded like the fault report
    // below it: a line that says when something last arrived must never be what
    // stops a drain, and the next pass re-reads the same queue anyway.
    //
    // Clamped to now, and the reason is the rule's own sentence. `postTime` is
    // the source app's clock, not ours; a phone whose clock is a day ahead
    // would otherwise buy the app twenty-four hours of silence in which
    // PERM-11's line can never appear. Clamping down is safe in the direction
    // that matters — it can only make the line appear sooner, never hide it.
    // `noteCaptureEventAt` refuses to move backwards, so a queue drained out of
    // order cannot walk the clock down and put the line on a busy phone.
    if (newestEvent != null) {
      try {
        final DateTime now = DateTime.now().toUtc();
        await _repository.noteCaptureEventAt(
          newestEvent.isAfter(now) ? now : newestEvent,
        );
      } on Object {
        // The clock falling behind costs PERM-11's line a delay, which the rule
        // already tolerates — it is a 24-hour window and an explicit guess. A
        // pass that failed here would cost the user captured messages.
      }
    }

    // Last, and outside everything above: a fault the listener recorded is a
    // fact about a pass that has already happened, and asking for it must never
    // be what stops one. CAP-12 — the app says what it could not see.
    try {
      _health.report(await _source.captureFaults());
    } on Object {
      // A listener that cannot even answer this is already reported by every
      // other call in the pass failing; inventing a fault here would be the app
      // guessing.
    }
  }

  /// A live event is a nudge to drain, and nothing else.
  ///
  /// The listener says so in writing: every event goes into the queue and "the
  /// EventChannel is only a nudge to drain it" (CAP-13), because one delivery
  /// path with one acknowledgement path is what makes the queue empty.
  /// Ingesting the event here made it a second, unacknowledged path — and an
  /// unserialised one, because `Stream.listen` does not await its callback, so
  /// two events in a burst ran inside `upsertConversation` at once, both read
  /// the same row, and the later write could carry the earlier message's time.
  /// `last_message_at` going backwards sorts a thread below an older one, which
  /// INB-4 makes the whole list's order.
  ///
  /// The payload is deliberately unused. Reading it here would be the start of
  /// growing the second path back.
  void _applyLive(Map<String, Object?> json) {
    unawaited(sync());
  }

  /// Whether an outcome changed something a screen reads.
  ///
  /// A re-post whose messages were all already stored is the common case
  /// (CAP-5), and reloading the whole list for it would spend the second
  /// INB-25 allows on work with nothing to show. A session row counts: it is
  /// what INB-10's notice is computed from.
  static bool _changedAnything(IngestOutcome outcome) =>
      switch (outcome.action) {
        IngestAction.stored ||
        IngestAction.markedRead ||
        IngestAction.sessionOpened ||
        IngestAction.sessionClosed => true,
        IngestAction.duplicate ||
        IngestAction.dropped ||
        IngestAction.ignored => false,
      };
}
