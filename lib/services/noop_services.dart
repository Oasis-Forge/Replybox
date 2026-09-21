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
DeviceServices noopServices() => const DeviceServices(
  notifications: NoopNotificationSource(),
  reply: NoopReplyService(),
  launcher: NoopAppLauncher(),
  reminders: NoopReminderScheduler(),
  entitlements: NoopEntitlements(),
  appLock: NoopAppLock(),
);
