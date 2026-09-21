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
  const NoopNotificationSource({this.access = false});

  final bool access;

  @override
  Future<bool> hasAccess() async => access;

  @override
  Future<void> openAccessSettings() async {}

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();
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

class NoopAppLauncher implements AppLauncher {
  const NoopAppLauncher({this.succeeds = true});

  final bool succeeds;

  @override
  Future<bool> open(String package) async => succeeds;
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

/// The whole bag, no-op. What every test gets unless it swaps one out.
///
/// No longer `const`: [NoopCaptureFilter] remembers what it was pushed, so each
/// call has to hand back its own. Reach the filter through
/// `services.captureFilter as NoopCaptureFilter` to assert on it.
DeviceServices noopServices() => DeviceServices(
  notifications: const NoopNotificationSource(),
  captureFilter: NoopCaptureFilter(),
  reply: const NoopReplyService(),
  launcher: const NoopAppLauncher(),
  reminders: const NoopReminderScheduler(),
  entitlements: const NoopEntitlements(),
  appLock: const NoopAppLock(),
);
