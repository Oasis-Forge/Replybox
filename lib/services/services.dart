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

/// What the app is allowed to say about whether a source app is still on the
/// phone (INB-16).
///
/// Three values, and deliberately not a `bool`. Two of these are things the app
/// has seen; the third is a thing it cannot see, and INB-16 is explicit that the
/// two must not be confused — *the app never tells the user an app is
/// uninstalled unless it can see that it is.* A boolean has nowhere to put
/// [unknown], so it gets folded into [gone] and a row grows a `sourceAppGone`
/// line about an app the user still has installed.
///
/// There is no `isGone` convenience getter here and there should not be one: its
/// negation would read as "installed" for a package the app cannot see at all,
/// which puts the same collapse back one layer down. Callers switch on all three.
enum PackagePresence {
  /// The package manager resolved the package. A label, and usually an icon,
  /// came with it.
  ///
  /// Since 22 September 2026 that is possible for any launchable app and not
  /// only for the shipped six: the manifest's `<queries>` carries a
  /// MAIN + LAUNCHER filter beside the six `<package>` entries, so an app that
  /// joined the inbox by posting (INB-20) resolves here like any other.
  ///
  /// **This does not mean the app can be opened**, and reading it that way is
  /// the defect the 23 September 2026 drill found: `com.android.shell` resolves
  /// here with a real label and has no launcher activity, so the thread drew
  /// `Open Shell` and every tap failed. [SourceAppIdentity.launchability] is the
  /// question a control has to ask.
  installed,

  /// The package manager says there is no such package, for a package the app
  /// was willing to ask about. This is the only answer that means an uninstall.
  ///
  /// INB-16: the conversation keeps its title and its messages, falls back to a
  /// generic source icon, and shows the `sourceAppGone` line in place of
  /// INB-13's control.
  ///
  /// Exact for the six the manifest names one by one — they are visible
  /// whatever shape they are in, so a not-found is absence and nothing else.
  /// For any other package it carries one residual, stated in `SourceAppInfo`
  /// and repeated here because this is the value a screen draws a sentence
  /// from: an app that is still installed, has no launcher activity **and is
  /// withheld from this process entirely** answers not-found and so reads as
  /// `gone`. That residual used to be every non-launchable app; the 23
  /// September 2026 drill measured one that resolves perfectly well
  /// (`com.android.shell`), so a non-launchable package the phone does show is
  /// now [installed] with [Launchability.noLauncher] and keeps its name and its
  /// icon. Either way the messages are untouched (DEL-1).
  gone,

  /// The app cannot tell, and says less rather than guessing (INB-16).
  ///
  /// Four things produce it, and they are all "the app did not learn anything"
  /// rather than "the app learned the package is missing":
  ///
  ///  * the package has never posted a notification to this phone and is not
  ///    one of the shipped six, so the native side refused to ask at all
  ///    (`SourceAppInfo.mayAsk`) — the promise that Replybox never reads the
  ///    device's app list, held in code now that the manifest no longer holds
  ///    it;
  ///  * the lookup was made and failed — a dead binder, a `SecurityException`,
  ///    anything that is not "no such package" — because a failure is not
  ///    evidence of an uninstall;
  ///  * there is no Android under this build at all: a host VM, a widget test,
  ///    or a channel with no listener registered;
  ///  * the reply could not be read — a missing key, a presence string this
  ///    build does not know, a wrong type.
  ///
  /// INB-16: the list row keeps `Open in app`, and a launch that fails reports
  /// only that the app could not be opened.
  ///
  /// **The thread's bottom bar does not offer a launcher intent here**, and
  /// that is the app stopping short of a promise it cannot keep rather than the
  /// app saying more. The first bullet is the case that matters: a package the
  /// native side refused to look up is one it will also refuse to launch
  /// ([AppLauncher.open] applies the same gate), so `Open in app` there could
  /// only ever produce INB-13's snackbar. The bar offers `Open chat` when
  /// [AppLauncher.canOpenChat] says this process still holds the notification —
  /// the one path that needs no visibility and no gate — and otherwise says
  /// that Replybox cannot open the app, which names no uninstall and claims
  /// nothing about the phone.
  unknown,
}

/// Whether a package the phone says is installed has anything to open
/// (INB-13, corrected 23 September 2026).
///
/// A second question, beside [PackagePresence], because they are two different
/// facts and the control needs the second one. `com.android.shell` is installed,
/// resolves a label and an icon, and has no launcher activity: the thread asked
/// "does this package exist", drew `Open Shell`, and answered every tap with
/// INB-13's snackbar. `installed` is not `launchable`.
///
/// Three values for the same reason [PackagePresence] has three: the app can
/// learn that there is something to open, learn that there is not, or learn
/// nothing — and only the middle one is a sentence it may put on screen.
enum Launchability {
  /// The package manager resolved a launcher intent. INB-13's `Open <app>` can
  /// be offered, and the tap has something to start.
  launchable,

  /// The package manager resolved the app and no launcher intent for it. There
  /// is a name and an icon to draw and nothing to open, so the thread's bar says
  /// so in place of the control (INB-13, INB-16).
  noLauncher,

  /// Nothing was learned: the package did not resolve at all ([PackagePresence]
  /// carries that), the answer could not be read, or there is no Android under
  /// this build.
  ///
  /// A caller reads this as "nothing known against a launch" and not as
  /// [noLauncher]. The two are kept apart in the direction the rest of this file
  /// keeps its unknowns apart: the app may withhold a control only where it has
  /// seen that there is nothing to open, and INB-13's snackbar already covers a
  /// launch that turns out to fail.
  unknown,
}

/// What the package manager could say about one source app (INB-1, INB-16).
@immutable
class SourceAppIdentity {
  const SourceAppIdentity({
    required this.package,
    required this.presence,
    this.label,
    this.icon,
    this.launchability = Launchability.unknown,
  });

  /// The answer for a package the app never declared, and for every lookup that
  /// could not be made (INB-16).
  const SourceAppIdentity.unknown(String package)
    : this(package: package, presence: PackagePresence.unknown);

  final String package;

  final PackagePresence presence;

  /// The app's current label, or null unless [presence] is
  /// [PackagePresence.installed].
  ///
  /// INB-1 reads this first for a declared package; for every other row the
  /// label is the one the listener stored on the `apps` row (INB-20), and where
  /// neither resolves the row shows the package name. That fallback chain lives
  /// on the screen — this class reports what the package manager said and never
  /// substitutes for it, so a null here is a fact and not an empty string
  /// pretending to be a name.
  final String? label;

  /// The app's icon as PNG bytes, ready for `Image.memory`, or null where the
  /// package manager resolved nothing or the icon could not be drawn.
  ///
  /// Bytes rather than a path: the icon belongs to the other app and is only
  /// reachable through its package manager entry, and nothing about it is
  /// written to disk (CAP-15 keeps icons out of the database, and this is the
  /// same icon).
  ///
  /// A row that finds this null draws INB-1's generic source icon. Losing an
  /// icon never changes [presence]: whether the app is installed and whether its
  /// icon could be drawn are two facts, and folding them would put a `gone` line
  /// on a row for an app that is right there.
  final Uint8List? icon;

  /// Whether there is anything to open, for a package [presence] says is
  /// installed (INB-13).
  ///
  /// [Launchability.unknown] unless the answer travelled, which is what an
  /// identity built by hand and every off-Android build gets. The channel
  /// carries it on every `installed` answer, and `SourceAppInfoTest` holds the
  /// native side to that; a reader that finds it missing says it learned
  /// nothing rather than inventing either half.
  final Launchability launchability;
}

/// INB-1's app icon and INB-16's installed-or-gone: the two things a row needs
/// from Android that the database cannot answer.
///
/// One package at a time, because that is how a list asks — and because a
/// method that took a list would be one refactor away from the enumeration
/// INB-20 forbids. There is no "list the installed apps" here and there is no
/// way to build one out of what is here, but since 22 September 2026 the reason
/// is a rule rather than the manifest. Android now makes every launchable app
/// visible to this process, and what keeps this from being a probe is that the
/// native side answers [PackagePresence.unknown], without consulting the phone,
/// for every package that is neither one of the shipped six nor one this
/// install has already seen post a notification. So the set this can ever
/// confirm is the apps that have messaged the user, plus the six the disclosure
/// names (PERM-3) — never the phone's app list.
abstract interface class PackageInfoService {
  /// Asks about [package], or returns what was already asked.
  ///
  /// Never throws: a row has to draw either way, and INB-16 turns every failure
  /// into [PackagePresence.unknown] rather than into an error a screen would
  /// have to invent a sentence for.
  Future<SourceAppIdentity> lookup(String package);

  /// What [lookup] has already resolved for [package], or null if nothing has.
  ///
  /// Synchronous, because a list builds rows synchronously: a row that has this
  /// draws its icon in the first frame instead of flashing the fallback through
  /// a `FutureBuilder` on every scroll.
  SourceAppIdentity? lookupCached(String package);

  /// Drops everything remembered, so the next [lookup] asks the phone again.
  ///
  /// An app can be installed or uninstalled while Replybox is in the background
  /// and nothing tells the app — watching for that would mean a broadcast
  /// receiver, which is a component this app does not have and INB-16 does not
  /// ask for. Calling this on resume is what makes INB-16's `gone` row appear
  /// after the user uninstalls the source app, at the cost of one lookup per
  /// visible package.
  void forgetAll();
}

/// Opening the source app, for every row where replying in place is not
/// possible (INB-13, CAP-14).
///
/// ## Both of INB-13's launches are here now, and why that matters
///
/// [openChat] used to sit on `AndroidAppLauncher` alone, as a concrete method
/// with no caller, on the reasoning that the label came from
/// [ReplyService.canReplyTo] and the screen that would ask ships with area REP.
/// That reasoning was wrong about which path is the fallback.
///
/// [open] used to be unable to work for a package outside the manifest's
/// `<queries>`: `getLaunchIntentForPackage` is filtered by package visibility
/// and answered null, and the declaration was the six shipped packages. The
/// packages outside it are exactly INB-20's second source — every app that
/// joined the inbox by posting a notification — so for those apps [open] was
/// not a fallback at all, it was a control that failed every time, forever.
/// That is what the developer's 22 September 2026 decision fixed: `<queries>`
/// now also declares a MAIN + LAUNCHER filter, so [open] resolves for any
/// launchable app. `QUERY_ALL_PACKAGES` is still absent and still gated.
///
/// [openChat] is unchanged and is still the first path, not the advanced one:
/// it needs no visibility at all — a `PendingIntent` runs as the app that
/// created it — so it reaches an app with no launcher activity, and it lands on
/// the conversation rather than on wherever the app opens.
///
/// So the interface carries both, plus [canOpenChat], because INB-13 decides
/// which path runs **before the tap** — the label says which — and a screen that
/// had to fire a path to learn whether it existed would draw `Open chat` and
/// then a snackbar.
abstract interface class AppLauncher {
  /// Starts [package]'s own launcher intent, carrying nothing the app added
  /// (product principle 1).
  ///
  /// **Returns whether the app actually opened, and nothing else may answer
  /// true.** A launch that threw, a package that resolved to nothing, a build
  /// with no host on the channel: all false, because INB-13 spends every one of
  /// them the same way — one snackbar, about five seconds, and nothing else on
  /// screen changes. A true from any of those is the defect this interface
  /// shipped with for one release: the screen returns early on success, so a
  /// launcher that lied about opening also suppressed the sentence that would
  /// have told the user it had not.
  ///
  /// A caller offers this only where [PackagePresence.installed] says the
  /// package manager resolved the app. That is now any launchable app the user
  /// has been messaged by, rather than only the shipped six — and the two
  /// conditions are the same one, because the native side refuses to resolve a
  /// launcher intent for a package it would also refuse to look up: neither
  /// shipped nor ever seen posting means false here, without the phone being
  /// asked (INB-20, `SourceAppInfo.mayAsk`). Offering it on
  /// [PackagePresence.unknown] is the permanently-failing control described
  /// above.
  Future<bool> open(String package);

  /// Whether this process holds [notificationKey]'s own content intent, so
  /// `Open chat` may be offered (INB-13, CAP-14).
  ///
  /// False on a cold start, after a listener reconnection, and once the entry
  /// has been evicted — a `PendingIntent` cannot be serialised, so this is a
  /// fact about this run and never about the conversation. Never throws: a
  /// screen has to draw either way, and "it could not be asked" is the same
  /// answer as "nothing is held".
  Future<bool> canOpenChat(String notificationKey);

  /// Fires the held content intent, exactly as the source app built it
  /// (product principle 1).
  ///
  /// **True means the send was made, which is weaker than [open]'s true**, and
  /// the 23 September 2026 drill is why it is written down here. Android's
  /// background-activity-launch rules can block the activity *after*
  /// `PendingIntent.send()` has returned successfully: on API 37 a two-second-old
  /// Google Messages notification sent cleanly and opened nothing, and the app
  /// had no idea. `AppLaunch.kt` now lends the send this app's own foreground
  /// start privileges, which is the part that can be fixed here; what cannot be
  /// fixed here is that the platform reports no outcome. So a caller of this
  /// method owes the user one more check — that Replybox actually stopped being
  /// the app on screen — before it treats a true as a launch
  /// (`thread_screen.dart`).
  ///
  /// False here is never a reason to try [open] instead: the user was offered
  /// `Open chat`, and landing them on an app's home screen is the same lie in
  /// the other direction (`AppLaunch.kt`).
  Future<bool> openChat(String notificationKey);
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
    required this.packages,
    required this.reply,
    required this.launcher,
    required this.reminders,
    required this.entitlements,
    required this.appLock,
  });

  final NotificationSource notifications;

  /// INB-22's other half: the switch the chooser moved, pushed down at once.
  final CaptureFilter captureFilter;

  /// INB-1's icon and label, and INB-16's installed-or-gone.
  final PackageInfoService packages;

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
