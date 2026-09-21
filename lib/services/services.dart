/// Every device service sits behind an interface here.
///
/// Tests get the no-op fakes in `noop_services.dart` by default; only
/// `main.dart` builds a real one. A real service reachable as a default
/// parameter is the trap docs/STACK_NOTES.md records: it hung the suite for
/// ten minutes.
library;

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
    required this.reply,
    required this.launcher,
    required this.reminders,
    required this.entitlements,
    required this.appLock,
  });

  final NotificationSource notifications;
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
