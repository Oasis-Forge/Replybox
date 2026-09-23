/// No-op implementations, and the default everywhere except `main.dart`.
///
/// Each one answers the way an unconfigured device would: no access, no live
/// reply action, no purchase, no lock. That matters — a fake that answers
/// "yes" to everything makes tests pass on paths the app will never reach on a
/// real phone.
library;

import '../models/conversation.dart';
import 'services.dart';

class NoopNotificationSource implements NotificationSource {
  const NoopNotificationSource({this.access = false, this.connected});

  final bool access;

  /// What [listenerConnected] answers, and **null by default, not false**
  /// (PERM-10).
  ///
  /// A device with no listener to ask has learned nothing, and that is a
  /// different answer from having watched the listener go away. A default of
  /// false would let a widget test draw PERM-10's `capture is not running`
  /// line on a build that never had a listener at all — the one sentence
  /// PERM-10 forbids without evidence, asserted by a test that would pass on
  /// the build that says it wrongly. That is the same trap
  /// [NoopPackageInfoService] avoids by never answering
  /// [PackagePresence.gone].
  ///
  /// A test that wants PERM-10's branch says `connected: false`, and by saying
  /// it states what it is asserting about.
  final bool? connected;

  @override
  Future<bool> hasAccess() async => access;

  @override
  Future<void> openAccessSettings() async {}

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<bool?> listenerConnected() async => connected;

  /// False, and it counts nothing: a phone with no listener cannot make the
  /// request, and false is "the request could not even be made" rather than
  /// anything about the listener (PERM-10). A test that needs to count rebinds
  /// — PERM-10's one-per-resume and its sixty-second floor — uses its own fake,
  /// because a counter here would make this class stateful and every test would
  /// share it.
  @override
  Future<bool> requestListenerRebind() async => false;
}

/// Accepts the set and forgets it, which is what a phone with no listener does
/// with it (INB-22). It records the last set it was handed so a test can assert
/// that a switch pushed CAP-1's filter down rather than only writing the row —
/// the defect this interface exists to make impossible.
class NoopCaptureFilter implements CaptureFilter {
  NoopCaptureFilter();

  /// Null until something pushes. An empty list is a real value — every app
  /// off — and is not the same as never having been told.
  List<String>? get lastPushed => _lastPushed;
  List<String>? _lastPushed;

  /// The `known` half of the same push: every package the database had a row
  /// for. Kept because it is the half that decides whether a package the user
  /// turned off actually goes off on the phone (CAP-1, INB-22), so a test that
  /// only asserted [lastPushed] would pass over the defect this argument fixes.
  List<String>? get lastPushedKnown => _lastPushedKnown;
  List<String>? _lastPushedKnown;

  /// How many times a set was pushed, so a test can tell one push from two.
  int get pushes => _pushes;
  int _pushes = 0;

  @override
  Future<void> setEnabledPackages(
    List<String> packages,
    List<String> known,
  ) async {
    _lastPushed = List<String>.unmodifiable(packages);
    _lastPushedKnown = List<String>.unmodifiable(known);
    _pushes += 1;
  }
}

/// Answers [PackagePresence.unknown] for every package, which is exactly what a
/// device with no package manager to ask can honestly say (INB-16).
///
/// Never [PackagePresence.gone] by default, and that is the point: a fake that
/// reported an uninstall would let a widget test assert the one sentence INB-16
/// forbids the app to say without having seen it — and the test would pass on
/// the build that says it wrongly.
///
/// [identities] seeds specific answers for a test that needs a row with an icon
/// or a `sourceAppGone` line. Anything it does not name stays unknown.
class NoopPackageInfoService implements PackageInfoService {
  const NoopPackageInfoService({
    this.identities = const <String, SourceAppIdentity>{},
  });

  final Map<String, SourceAppIdentity> identities;

  @override
  Future<SourceAppIdentity> lookup(String package) async =>
      lookupCached(package)!;

  /// Answers synchronously and always, because this fake has nothing to fetch:
  /// a seeded row draws in the first frame rather than after a pump.
  @override
  SourceAppIdentity? lookupCached(String package) =>
      identities[package] ?? SourceAppIdentity.unknown(package);

  @override
  void forgetAll() {}
}

class NoopReplyService implements ReplyService {
  const NoopReplyService();

  /// False, always: after a cold start there is no held action, and that is
  /// the state a test should be reasoning about unless it says otherwise
  /// (CAP-14).
  @override
  bool canReplyTo(Conversation conversation) => false;

  @override
  Future<void> send(Conversation conversation, String text) async =>
      throw StateError('no reply action held (CAP-14)');
}

/// Starts nothing, and says so.
///
/// [succeeds] defaulted to **true** and that is what hid the defect this class
/// is now named by: `main.dart` handed one of these to the Android build, so
/// INB-13's control launched nothing on a real phone and the screen — which
/// returns early on success — swallowed the snackbar that would have said so.
/// A no-op that claims success is not a fake of a launcher; it is a fake of a
/// launcher that worked, and it makes every test above it pass on a path the
/// app cannot reach.
///
/// False is also the honest answer on its own terms, which is this file's rule
/// (see the header): an unconfigured device has no package manager to resolve a
/// launcher intent and no listener holding a content intent, so nothing opens.
/// A test that wants the other branch says `succeeds: true` and, by saying it,
/// states that it is asserting about a launch that landed.
class NoopAppLauncher implements AppLauncher {
  const NoopAppLauncher({this.succeeds = false, this.holdsChat = false});

  /// Whether a launch this fake was asked to make is reported as having landed.
  /// Covers both of INB-13's paths, because both are the same promise to the
  /// screen: the app opened, or it did not.
  final bool succeeds;

  /// Whether this fake claims the listener still holds a content intent
  /// (INB-13's `Open chat`).
  ///
  /// False by default and separate from [succeeds] for the same reason the
  /// interface separates them: a fake that held a chat by default would draw
  /// `Open chat` on every thread in every test, which is the state a cold start
  /// never has. A test that wants that state says so.
  final bool holdsChat;

  @override
  Future<bool> open(String package) async => succeeds;

  @override
  Future<bool> canOpenChat(String notificationKey) async => holdsChat;

  @override
  Future<bool> openChat(String notificationKey) async => succeeds;
}

class NoopReminderScheduler implements ReminderScheduler {
  const NoopReminderScheduler();

  @override
  Future<void> scheduleAt(
    DateTime when,
    String conversationId,
    String body,
  ) async {}

  @override
  Future<void> cancel(String conversationId) async {}
}

class NoopEntitlements implements Entitlements {
  const NoopEntitlements({this.plus = false});

  final bool plus;

  @override
  Future<bool> hasPlus() async => plus;
}

class NoopAppLock implements AppLock {
  const NoopAppLock({this.available = false, this.authenticates = true});

  final bool available;
  final bool authenticates;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate() async => authenticates;
}

/// Answers "nothing to open and nothing to report", which is what a device with
/// no settings app can honestly say (PERM-14).
///
/// [opens] is false by default for the reason [NoopAppLauncher.succeeds] is:
/// a fake that claims a page opened is a fake of a phone where it worked, and
/// PERM-14's screen returns early on a true — so a lying default would suppress
/// the written path that is the whole of what the app can offer when the page
/// is not there (PERM-7's third branch, reached a second time).
///
/// [reportedManufacturer] is null by default rather than a placeholder name:
/// PERM-14 prints this value to the user, and a substituted string would be the
/// app telling them something about their hardware that the hardware did not
/// say.
class NoopSystemSettings implements SystemSettings {
  const NoopSystemSettings({this.reportedManufacturer, this.opens = false});

  final String? reportedManufacturer;
  final bool opens;

  @override
  Future<String?> manufacturer() async => reportedManufacturer;

  @override
  Future<bool> openBatteryOptimisationSettings() async => opens;

  @override
  Future<bool> openAppInfoSettings() async => opens;
}

/// The whole bag, no-op. What every test gets unless it swaps one out.
///
/// No longer `const`: [NoopCaptureFilter] remembers what it was pushed, so each
/// call has to hand back its own. Reach the filter through
/// `services.captureFilter as NoopCaptureFilter` to assert on it.
DeviceServices noopServices() => DeviceServices(
  notifications: const NoopNotificationSource(),
  captureFilter: NoopCaptureFilter(),
  packages: const NoopPackageInfoService(),
  reply: const NoopReplyService(),
  launcher: const NoopAppLauncher(),
  reminders: const NoopReminderScheduler(),
  entitlements: const NoopEntitlements(),
  appLock: const NoopAppLock(),
  systemSettings: const NoopSystemSettings(),
);
