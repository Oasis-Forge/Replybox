/// Every device service sits behind an interface here.
///
/// Tests get the no-op fakes in `noop_services.dart` by default; only
/// `main.dart` builds a real one. A real service reachable as a default
/// parameter is the trap docs/STACK_NOTES.md records: it hung the suite for
/// ten minutes.
library;

import 'package:flutter/foundation.dart';

import '../models/conversation.dart';
import '../models/message.dart';

/// Whether the listener can see notifications at all, and when it could.
///
/// Nothing here can prove capture is *working* — a listener that silently
/// died is indistinguishable from a quiet phone, and the check that would
/// settle it waits for the release that already needs POST_NOTIFICATIONS
/// (decision 12, PERM-12). These methods answer only what the system will
/// actually tell us.
abstract interface class NotificationSource {
  /// Whether notification access is granted right now (PERM-6).
  Future<bool> hasAccess();

  /// Opens Android's notification-access settings page (PERM-7). Returns once
  /// the page has been launched, not once the user has decided.
  Future<void> openAccessSettings();

  /// Events the listener has queued while Dart was not running, drained on
  /// launch and on resume (CAP-13).
  Stream<Map<String, Object?>> events();
}

/// The one thing the chooser has to be able to push down to the listener: the
/// set of packages CAP-1's filter lets through.
///
/// Narrow on purpose. The drain and the acks stay off every interface the state
/// layer can see — a provider has no business releasing queue rows — but the
/// enabled set is different in kind: INB-22 says a switch takes effect from the
/// moment it moves, and the only thing that can make that true is the screen
/// that moved it telling the listener so. Mirroring on the next resume is too
/// late, in both directions: a package turned on drops every notification
/// posted before the app is next resumed (CAP-1 drops them before the queue, so
/// they are gone rather than delayed), and a package turned off keeps writing
/// its sender, title and text into the queue that CAP-1 says they must never
/// reach.
///
/// The database is still the only authority on what is on. An implementation
/// mirrors the set it is handed; it never merges, and it never decides.
abstract interface class CaptureFilter {
  /// Replaces the listener's filter with exactly [packages], and tells it which
  /// packages that answer covers.
  ///
  /// [known] is every package the database holds an `apps` row for, on or off;
  /// [packages] is the subset that is on. The listener may keep a package of its
  /// own only while it is in neither — a first sighting it has not handed over
  /// yet, which no row can speak for (CAP-1). A package in [known] and not in
  /// [packages] is off from the moment this returns, with no exception, which is
  /// what INB-22 promises the switch does.
  ///
  /// [packages] must be a subset of [known]; a caller builds both from one read
  /// of the table rather than from two.
  ///
  /// Throws when the listener could not be told. The caller shows that rather
  /// than swallowing it: a switch that moved on screen and not on the phone is
  /// silent data loss in the ON direction (INB-22).
  Future<void> setEnabledPackages(List<String> packages, List<String> known);
}

/// What capture could not do.
///
/// The mirror of the Kotlin `CaptureFaults` record, field for field, plus one
/// fault this side owns and the listener cannot see
/// ([messageIdentityCollisions]). Counts and instants only — never a package, a
/// title or a text, because a fault record that carried the row it lost would
/// put message content somewhere the database's rules do not reach (product
/// principle 1, CAP-15, INB-24).
///
/// These are facts the app cannot re-derive. A notification the listener could
/// not append to the queue is not delayed, it is gone unless a Dart isolate
/// happened to be running to hear the live nudge, and a store it cannot read
/// makes CAP-1 fail closed so nothing at all is captured. CAP-12 and product
/// principle 3 say the app states a gap like that rather than letting it read
/// as a quiet phone.
@immutable
class CaptureFaults {
  const CaptureFaults({
    this.queueWriteFailures = 0,
    this.lastQueueWriteFailureAt,
    this.storeWriteFailures = 0,
    this.lastStoreWriteFailureAt,
    this.storeUnreadable = false,
    this.messageIdentityCollisions = 0,
    this.lastMessageIdentityCollisionAt,
  });

  /// Events the listener could not append to the hand-over queue (CAP-15).
  final int queueWriteFailures;

  /// When the last append failed, UTC, or null if none has. The native side
  /// sends 0 for "never"; that is read as null here rather than as 1970, which
  /// a screen would otherwise print.
  final DateTime? lastQueueWriteFailureAt;

  /// Times the included-apps store could not be written: the listener's own
  /// copy is ahead of the disk, so a first-sighting default (CAP-1) or a
  /// pushed filter may not survive a service restart.
  final int storeWriteFailures;
  final DateTime? lastStoreWriteFailureAt;

  /// The included-apps store could not be read. CAP-1 fails closed while this
  /// is true, so nothing is being captured from any app at all.
  final bool storeUnreadable;

  /// Messages the ingest could not store because CAP-5's matching missed a row
  /// the identity index then rejected (`MessageIdentityCollision`).
  ///
  /// This one is ours, not the listener's: it happens after the hand-over, in
  /// `CaptureSync`, so nothing native can count it. `Repository._insertMessage`
  /// throws it "loud on purpose" — the whole reason it is an exception rather
  /// than a `wrote: false` is that CAP-5's correction of 21 September 2026 was
  /// written after a swallowed collision made a message the user had just been
  /// sent disappear with nothing on screen. The sync loop then caught it with a
  /// bare `on Object` and dropped it, which put the silence straight back. A
  /// count here is what makes "loud" true: the row stays in the queue, and
  /// PERM-8's banner can say the app is holding less than it claims (CAP-12,
  /// RUN-1).
  final int messageIdentityCollisions;

  /// When the last collision was seen, UTC, or null if none has been.
  final DateTime? lastMessageIdentityCollisionAt;

  /// Whether anything is wrong. The one question a banner has to ask.
  bool get isHealthy =>
      queueWriteFailures == 0 &&
      storeWriteFailures == 0 &&
      !storeUnreadable &&
      messageIdentityCollisions == 0;
}

/// The current [CaptureFaults], as something a screen can watch.
///
/// In memory for this run, like the native counters it mirrors: nothing about a
/// fault is written to the database, and the failure being current has exactly
/// the lifetime of the process that hit it.
///
/// **Where a screen reads this:** PERM-8's capture banner on the first screen.
/// It already owns the "capture is not whole" line, it is already that screen's
/// whole account of the state, and a second banner for the same idea would cost
/// the user a tap for nothing. A screen watches it like any other
/// [ChangeNotifier] (`context.watch<CaptureHealth>()`); `main.dart` puts one in
/// the tree on every platform, so the widget is never conditional and a test
/// can push a fault into it without a channel.
class CaptureHealth extends ChangeNotifier {
  CaptureHealth();

  CaptureFaults _faults = const CaptureFaults();
  CaptureFaults get faults => _faults;

  /// The one fault this side counts itself, kept apart from the listener's
  /// snapshot so a later [report] cannot overwrite it with a zero the native
  /// record never had a field for.
  int _identityCollisions = 0;
  DateTime? _lastIdentityCollisionAt;

  /// Called after every sync pass, so a fault hit while the app is open is on
  /// screen within INB-25's second rather than at the next launch.
  void report(CaptureFaults faults) => _publish(faults);

  /// A message CAP-5's matching missed and the identity index rejected
  /// (`MessageIdentityCollision`, [CaptureFaults.messageIdentityCollisions]).
  ///
  /// Counted, never described: the exception carries the `Message` itself, and
  /// its `toString` carries the sender's name, which INB-24 keeps out of every
  /// log and every screen.
  void noteMessageIdentityCollision(DateTime at) {
    _identityCollisions++;
    _lastIdentityCollisionAt = at;
    _publish(_faults);
  }

  /// Merges the listener's snapshot with the counts this side owns, and
  /// notifies only when the banner's answer actually moved.
  void _publish(CaptureFaults reported) {
    final CaptureFaults next = CaptureFaults(
      queueWriteFailures: reported.queueWriteFailures,
      lastQueueWriteFailureAt: reported.lastQueueWriteFailureAt,
      storeWriteFailures: reported.storeWriteFailures,
      lastStoreWriteFailureAt: reported.lastStoreWriteFailureAt,
      storeUnreadable: reported.storeUnreadable,
      messageIdentityCollisions: _identityCollisions,
      lastMessageIdentityCollisionAt: _lastIdentityCollisionAt,
    );
    if (next.queueWriteFailures == _faults.queueWriteFailures &&
        next.storeWriteFailures == _faults.storeWriteFailures &&
        next.storeUnreadable == _faults.storeUnreadable &&
        next.messageIdentityCollisions == _faults.messageIdentityCollisions) {
      // Unchanged: notifying anyway would rebuild the first screen on every
      // resume and every live event, for a banner whose text did not move.
      return;
    }
    _faults = next;
    notifyListeners();
  }
}

/// Sending a reply through the source app's own notification action.
abstract interface class ReplyService {
  /// Whether a live reply action is held for this conversation *in this
  /// process* (CAP-14). A PendingIntent cannot be serialised, so this is
  /// always false straight after a cold start.
  bool canReplyTo(Conversation conversation);

  /// Fires the held action. Throws if it is gone, which the caller shows as
  /// "open in app" rather than a failed send.
  Future<void> send(Conversation conversation, String text);
}

/// Opening the source app, for every row where replying in place is not
/// possible (INB-13, CAP-14).
abstract interface class AppLauncher {
  /// Launches [package]. Returns false when the app is gone or refuses, which
  /// INB-13 requires be shown rather than swallowed.
  Future<bool> open(String package);
}

/// Snooze and nudge alarms. Nothing uses it until the Triage area ships; the
/// interface exists now so the state layer is wired for it once rather than
/// twice.
abstract interface class ReminderScheduler {
  Future<void> scheduleAt(DateTime when, String conversationId, String body);
  Future<void> cancel(String conversationId);
}

/// What the store says this account owns (PAY-1).
abstract interface class Entitlements {
  /// Asked at every launch, so a refund or a family-shared purchase lands
  /// without a reinstall.
  Future<bool> hasPlus();
}

/// The device's own biometrics or screen lock (LOCK-1). The app never stores a
/// PIN of its own.
abstract interface class AppLock {
  /// Whether the device still has a lock to use. False turns app lock off
  /// rather than locking the user out of their own data (LOCK-3).
  Future<bool> isAvailable();

  /// Prompts. Returns whether the user authenticated.
  Future<bool> authenticate();
}

/// Everything the state layer needs from the device, in one bag, so a screen
/// or a provider takes one dependency instead of six.
class DeviceServices {
  const DeviceServices({
    required this.notifications,
    required this.captureFilter,
    required this.reply,
    required this.launcher,
    required this.reminders,
    required this.entitlements,
    required this.appLock,
  });

  final NotificationSource notifications;

  /// INB-22's other half: the switch the chooser moved, pushed down at once.
  final CaptureFilter captureFilter;

  final ReplyService reply;
  final AppLauncher launcher;
  final ReminderScheduler reminders;
  final Entitlements entitlements;
  final AppLock appLock;
}

/// A message the app has composed but not yet confirmed as sent (INB-9).
/// Defined here because both the reply service and the state layer need the
/// shape, and neither owns the other.
typedef PendingReply = ({Conversation conversation, Message message});
