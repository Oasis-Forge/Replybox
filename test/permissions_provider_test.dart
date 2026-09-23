/// The state layer of section 9, asserted on the sentence a person would read.
///
/// Everything in `PermissionsProvider` exists to keep one promise — the app
/// says which of its three states it is in and never dresses the third up as
/// the second — and every one of those states is a sentence on the first
/// screen. So the assertions below are about which sentence resolves and what
/// time it names, never about a method having returned something: a provider
/// that answered `notRunning` with the right shape and the wrong evidence is
/// exactly the defect PERM-10 is written against, and a test reading only
/// "a value is set" would pass on it.
///
/// Three things are injected rather than waited for, and each one is a rule
/// with a duration in it:
///
///  * **The clock.** PERM-11 measures twenty-four hours and PERM-10 measures
///    sixty seconds; a test that advanced a real clock would be slow where it
///    worked and flaky where it did not.
///  * **The wait.** PERM-10's ten seconds are the whole of "a first resume
///    never accuses a listener that is merely slow to bind", so [_Wait] can
///    hold the wait open and the test can look at the screen *during* it —
///    which is the only way that clause is assertable at all.
///  * **The listener.** [_Listener] counts what it was asked, because PERM-10's
///    limits are counts: at most one rebind request per resume, at most one per
///    sixty seconds. `NoopNotificationSource` deliberately counts nothing (its
///    own comment says why), so this file brings its own fake rather than
///    making that one stateful for everybody.
///
/// The repository is a real in-memory SQLite from `helpers.dart` and the
/// migration assertions open a real file, for the reason that file gives: a
/// mock would pass on SQL SQLite rejects, which is the whole risk a migration
/// test exists to cover. `version1Schema`'s frozen shape is reached through
/// `migration_test.dart` rather than copied, because two copies of a frozen
/// schema stop being frozen the first time one of them is edited.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/data/battery_guidance.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/migrations.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:replybox/models/record.dart';
import 'package:replybox/providers/inbox_provider.dart' show CaptureSignal;
import 'package:replybox/providers/permissions_provider.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:replybox/services/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';
// The version-1 schema, frozen, and the opener that builds a database from it.
// Imported rather than copied: `migration_test.dart`'s own comment explains
// that the value of that list is that it does not move, and a second copy here
// would move on its own the first time somebody tidied one of them. `show`
// keeps the rest of that file — including its `main` — out of this one.
import 'migration_test.dart' show openVersion1;

/// The listener, faked at the interface, because this file counts calls.
///
/// A subclass of `AndroidNotificationSource` (what `capture_sync_test.dart`
/// uses) would be the wrong fake here: that file tests the methods `main.dart`
/// wires up, and this one tests what the provider *asks for* and how often.
/// Every field is mutable, so a test can move the phone underneath a live
/// provider — which is what a revoke, a rebind and a kill all look like from
/// here.
class _Listener implements NotificationSource {
  /// What `Settings.Secure` says. Mutable because PERM-5's whole point is that
  /// this can change without the app being told, and the app must read it
  /// again rather than remember it.
  bool access = false;

  /// PERM-10's tri-state, defaulting to null — "this process has observed
  /// neither lifecycle callback", the answer that may never draw a line.
  bool? connected;

  /// How many times the provider read the system's answer. PERM-5 says every
  /// cold start and every resume, so this is a count and not a flag.
  int accessReads = 0;

  /// How many times the provider read the listener's own state.
  int connectedReads = 0;

  /// PERM-10's counted call. One per resume, one per sixty seconds.
  int rebinds = 0;

  /// How many times the system page was asked for (PERM-1, PERM-7).
  int opens = 0;

  /// PERM-7's third branch: neither intent resolves, and the channel says so
  /// by throwing rather than by returning false.
  bool openThrows = false;

  @override
  Future<bool> hasAccess() async {
    accessReads += 1;
    return access;
  }

  @override
  Future<void> openAccessSettings() async {
    opens += 1;
    if (openThrows) {
      throw PlatformException(code: 'no_settings_page');
    }
  }

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<bool?> listenerConnected() async {
    connectedReads += 1;
    return connected;
  }

  @override
  Future<bool> requestListenerRebind() async {
    rebinds += 1;
    return true;
  }
}

/// PERM-14's device facts, counted for the same reason: the manufacturer is
/// read once per run and cached, and a test that could not see the second read
/// not happening would pass on a channel round trip per resume.
class _SystemSettings implements SystemSettings {
  String? reportedManufacturer;
  int manufacturerReads = 0;
  bool opens = false;

  @override
  Future<String?> manufacturer() async {
    manufacturerReads += 1;
    return reportedManufacturer;
  }

  @override
  Future<bool> openBatteryOptimisationSettings() async => opens;

  @override
  Future<bool> openAppInfoSettings() async => opens;
}

/// PERM-10's ten seconds, under the test's control.
///
/// [hold] is what makes the clause "the line does not show during the wait"
/// assertable: with it raised, the wait parks and the test reads the provider
/// from inside it. With it down the wait is instant, which is what every test
/// that only cares about the answer after ten seconds wants.
class _Wait {
  /// Every duration the provider asked to wait, in order. Its *length* is the
  /// assertion that matters: PERM-10 says the sixty-second floor starts no new
  /// wait, and a second entry here would be that wait.
  final List<Duration> asked = <Duration>[];

  bool hold = false;
  Completer<void>? _held;

  Future<void> call(Duration duration) {
    asked.add(duration);
    if (!hold) return Future<void>.value();
    return (_held = Completer<void>()).future;
  }

  /// Lets a held wait finish, as ten real seconds would.
  void release() {
    final Completer<void>? held = _held;
    _held = null;
    held?.complete();
  }
}

void main() {
  setUpAll(initTestDatabases);

  late Repository repo;
  late DBHelper db;
  late _Listener listener;
  late _SystemSettings settings;
  late _Wait wait;
  late DateTime now;

  setUp(() async {
    final ({Repository repository, DBHelper db}) t = await testRepository();
    repo = t.repository;
    db = t.db;
    listener = _Listener();
    settings = _SystemSettings();
    wait = _Wait();
    now = t0;
  });

  tearDown(() => db.close());

  /// The no-op bag with this file's two fakes in it.
  ///
  /// Built from the same no-ops `noopServices()` uses, so nothing in here is a
  /// second set of defaults: only the two services these rules are about are
  /// swapped, and every other device service still answers the way an
  /// unconfigured phone does.
  DeviceServices services({NotificationSource? notifications}) =>
      DeviceServices(
        notifications: notifications ?? listener,
        captureFilter: NoopCaptureFilter(),
        packages: const NoopPackageInfoService(),
        reply: const NoopReplyService(),
        launcher: const NoopAppLauncher(),
        reminders: const NoopReminderScheduler(),
        entitlements: const NoopEntitlements(),
        appLock: const NoopAppLock(),
        systemSettings: settings,
      );

  /// A provider over the current repository, clock and wait.
  ///
  /// Called twice in a test where the test is about a process being killed:
  /// the second one is the next launch, reading the same database with no
  /// memory of the first — which is the only way PERM-5's "a stored flag can
  /// never unlock anything" can actually be shown.
  ///
  /// [signal] is null everywhere except the group that is about a listener
  /// binding, exactly as it is null in every provider `main.dart` does not
  /// build: a test that is not about a binding gets a provider that reads when
  /// it is asked to and at no other time.
  PermissionsProvider build({CaptureSignal? signal}) {
    final PermissionsProvider provider = PermissionsProvider(
      repo,
      services(),
      captureSignal: signal,
      clock: () => now,
      delay: wait.call,
    );
    addTearDown(() {
      if (!provider.isDisposed) provider.dispose();
    });
    return provider;
  }

  /// The nudge `main.dart` hands every provider that can be on screen (INB-25).
  ///
  /// Torn down before the provider that listens to it cannot be — `addTearDown`
  /// runs last-registered first, and every caller below makes the signal before
  /// it makes the provider, so the provider lets go of its listener while the
  /// signal is still alive. A signal disposed first would make the provider's
  /// own `removeListener` throw, which is a test artefact and not a rule.
  CaptureSignal aCaptureSignal() {
    final CaptureSignal signal = CaptureSignal();
    addTearDown(signal.dispose);
    return signal;
  }

  /// Yields until the provider has parked in PERM-10's wait, and fails rather
  /// than hanging if it never does.
  Future<void> untilWaiting() async {
    for (int i = 0; i < 200 && wait.asked.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      wait.asked,
      isNotEmpty,
      reason: 'the provider never parked in the ten-second wait (PERM-10)',
    );
  }

  /// Yields until [done], and fails with [what] rather than hanging.
  ///
  /// The read a capture signal starts cannot be awaited by the thing that fired
  /// it — a `ChangeNotifier` listener is a `VoidCallback`, which is the whole
  /// reason `main.dart`'s drain loop nudges a signal rather than awaiting a
  /// provider — so a test has to give the event loop its turns and then look.
  /// Real turns and not a fixed count: the read touches a real SQLite file.
  Future<void> until(bool Function() done, String what) async {
    for (int i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(done(), isTrue, reason: what);
  }

  /// Gives any work a signal started room to finish, without waiting for
  /// anything in particular. For the assertions that are about something *not*
  /// happening.
  Future<void> settle() async {
    for (int i = 0; i < 40; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// A phone that has been capturing and has gone quiet: an install date, one
  /// enabled app seen posting after it, and an event at [lastEventAt].
  ///
  /// Every one of PERM-11's preconditions except the twenty-four hours, which
  /// each test states for itself by moving [now]. Kept in one place because a
  /// test that set three of the four and forgot the fourth would assert
  /// silence and prove nothing.
  Future<void> aPhoneThatHasBeenCapturing({
    required DateTime lastEventAt,
  }) async {
    await repo.installedAt(t0);
    await repo.upsertSeenApp(
      package: 'com.whatsapp',
      label: 'WhatsApp',
      enabledIfNew: true,
      at: t0.add(const Duration(minutes: 1)),
    );
    await repo.noteCaptureEventAt(lastEventAt);
  }

  /// One stored thread, so a test about capture being off can also assert that
  /// the messages are still there (PERM-9, DEL-1).
  Future<Conversation> aStoredThread({required DateTime at}) async {
    final Conversation thread = aConversation(lastMessageAt: at);
    await repo.insertConversation(thread);
    await repo.insertMessageIfNew(
      aMessage(
        conversationId: thread.id,
        text: 'the boiler is fixed',
        sentAt: at,
      ),
    );
    return thread;
  }

  group('PERM-5: the platform is asked, and nothing stored is believed', () {
    test('access is read from the system on every refresh and never from a '
        'stored flag', () async {
      listener.access = true;
      final PermissionsProvider provider = build();

      await provider.refresh();
      expect(provider.hasAccess, isTrue);
      expect(listener.accessReads, 1);

      // The phone changes underneath a live provider, which is what a revoke in
      // the system's own settings app is. Nothing tells the app.
      listener.access = false;
      await provider.refresh();

      expect(provider.hasAccess, isFalse);
      expect(
        listener.accessReads,
        2,
        reason: 'one read per resume, every time',
      );
      // And the screen says so rather than staying on the last good answer: a
      // provider that cached the grant would leave the inbox with no banner
      // over a phone capturing nothing (PERM-8, PERM-13).
      expect(provider.statusLine, CaptureStatusLine.accessNeverOn);
    });

    test('a stored flag can never unlock anything: the grant is gone after a '
        'kill and the app says so', () async {
      // The whole of PERM-5 in one run. Access is on, the disclosure is shown
      // and its stamp is written, the process dies, and the user revokes access
      // while the app is not running — the sequence that a "we onboarded them"
      // flag would answer with a screen saying capture is fine.
      await repo.installedAt(t0);
      listener.access = true;
      listener.connected = true;
      final PermissionsProvider first = build();
      await first.refresh();
      await first.markDisclosureShown();
      expect(first.hasAccess, isTrue);
      first.dispose();

      listener.access = false;
      final PermissionsProvider next = build();
      await next.refresh();

      expect(
        next.hasAccess,
        isFalse,
        reason: 'the platform is the only source',
      );
      expect(next.statusLine, CaptureStatusLine.accessNeverOn);
      expect(next.statusSince, t0, reason: 'PERM-8 names installed_at');

      // And structurally: there is no key in `settings` that could have said
      // otherwise. PERM-5 lists what may not be stored — a grant, an opened
      // page, a "sent to settings" — and this is the assertion that a later
      // change cannot quietly add one.
      final Database database = await db.database;
      final Set<String> keys = (await database.query(
        'settings',
        columns: <String>['key'],
      )).map((Map<String, Object?> row) => row['key']! as String).toSet();
      expect(
        keys,
        everyElement(
          isIn(<String>[
            'installed_at',
            'disclosure_shown_at',
            'battery_guidance_shown_at',
            'quiet_notice_shown_at',
            'last_capture_event_at',
          ]),
        ),
        reason:
            'every stored key records something the app did; none records '
            'anything the platform did (PERM-5)',
      );
    });

    test('a launch that finds access already granted and the disclosure never '
        'shown asks for the disclosure', () async {
      // The grant made in the system's own settings app, which the app cannot
      // intercept. Onboarding is not done, because the disclosure has never
      // been on screen, and decision 6 says the app may not capture from an app
      // the user did not name without having said so first.
      listener.access = true;
      listener.connected = true;
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.hasAccess, isTrue);
      expect(provider.shouldShowDisclosure, isTrue);
    });
  });

  group('PERM-4: offered once, and never suppressed on a tap', () {
    test(
      'the disclosure is offered without a tap exactly once per install',
      () async {
        final PermissionsProvider first = build();
        await first.refresh();
        expect(first.shouldShowDisclosure, isTrue);

        // The screen draws and records that it was on screen, from its own
        // initState — the fact PERM-5 asks for is display, not dismissal.
        await first.markDisclosureShown();
        expect(first.shouldShowDisclosure, isFalse);
        first.dispose();

        final PermissionsProvider relaunch = build();
        await relaunch.refresh();

        expect(
          relaunch.shouldShowDisclosure,
          isFalse,
          reason: 'once per install, and the stamp is what survives the kill',
        );
      },
    );

    test('after a decline no stored flag is what a later launch reads to '
        'suppress the screen', () async {
      await repo.installedAt(t0);
      final PermissionsProvider first = build();
      await first.refresh();
      await first.markDisclosureShown();
      first.dispose();

      final PermissionsProvider relaunch = build();
      await relaunch.refresh();

      // The offer is suppressed; the screen is not. PERM-4 is satisfied by the
      // banner being present on every later launch — its action opens the
      // disclosure (PERM-1) — so the app that declined still has one tap to the
      // system page.
      expect(relaunch.shouldShowDisclosure, isFalse);
      expect(
        relaunch.statusLine,
        CaptureStatusLine.accessNeverOn,
        reason: 'the banner is always there, and it is what opens the screen',
      );
      // And the tap path itself reads no flag: the same provider that has just
      // said "do not offer" still opens the system page when asked.
      expect(await relaunch.openAccessSettings(), isTrue);
      expect(listener.opens, 1);
    });
  });

  group('PERM-7: a page that will not open', () {
    test('a settings page that will not open sets canOpenAccessSettings false '
        'and never throws at a screen', () async {
      listener.openThrows = true;
      final PermissionsProvider provider = build();
      await provider.refresh();
      expect(provider.canOpenAccessSettings, isTrue, reason: 'no honest probe');

      final bool opened = await provider.openAccessSettings();

      // No throw reaches the caller, and the screen's answer is the written
      // path rather than an error: a `PlatformException` surfacing here would
      // be a red screen where PERM-7 asks for a sentence.
      expect(opened, isFalse);
      expect(provider.canOpenAccessSettings, isFalse);

      // Permanently for the run. The phone has now told the app this page does
      // not exist, and offering the button again on the next resume would be
      // the dead button PERM-7 forbids.
      listener.openThrows = false;
      await provider.refresh();
      expect(provider.canOpenAccessSettings, isFalse);
    });
  });

  group('PERM-8 and PERM-9: what the banner may say about when', () {
    test('a window closed on a reported disconnection resolves '
        'accessOffSince', () async {
      final DateTime unbound = t0.add(const Duration(hours: 2));
      await repo.installedAt(t0);
      await aStoredThread(at: t0.add(const Duration(hours: 1)));
      await repo.openCaptureSession(t0);
      // The listener said so itself, inside its own callback, with that
      // callback's time.
      await repo.closeCaptureSession(unbound);
      listener.access = false;
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.accessOffSince);
      expect(
        provider.statusSince,
        unbound,
        reason: 'the exact instant, because the row records that it is exact',
      );
    });

    test('a window closed on a later discovery resolves '
        'accessOffSinceAtLeast', () async {
      final DateTime lastEvidence = t0.add(const Duration(hours: 1));
      final DateTime noticed = t0.add(const Duration(hours: 10));
      await repo.installedAt(t0);
      await aStoredThread(at: lastEvidence);
      await repo.openCaptureSession(t0);
      // Nothing ever reported the unbind. The app found out on a resume.
      await repo.closeOpenCaptureSessionsAtLastEvidence(noticed);
      listener.access = false;
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.accessOffSinceAtLeast);
      expect(provider.statusSince, lastEvidence);
      expect(
        provider.statusSince,
        isNot(noticed),
        reason:
            'the app never prints the time it noticed something as the time '
            'that thing happened (product principle 3, PERM-9)',
      );
    });

    test('no window ever closed resolves accessNeverOn and names '
        'installed_at', () async {
      await repo.installedAt(t0);
      listener.access = false;
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.accessNeverOn);
      expect(provider.statusSince, t0);
    });

    test('an open window beside a closed history still reads the closed '
        'one', () async {
      // The trap the repository's doc comment names: "is anything open" is a
      // different question from "what was the newest close", and a reader that
      // asked the first would draw the never-on banner over a phone that has
      // been capturing all week.
      final DateTime unbound = t0.add(const Duration(hours: 2));
      await repo.installedAt(t0);
      await repo.openCaptureSession(t0);
      await repo.closeCaptureSession(unbound);
      await repo.openCaptureSession(t0.add(const Duration(hours: 3)));
      listener.access = false;
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.accessOffSince);
      expect(provider.statusSince, unbound);
    });

    test('closeCaptureSession stores an exact end and '
        'closeOpenCaptureSessionsAtLastEvidence stores an estimate, and '
        'neither touches a stored message', () async {
      // PERM-9's two halves side by side, in one database, because the thing
      // being asserted is that they are *different* and that neither of them
      // costs the user a message. DEL-1 and CAP-12: the gap is recorded, the
      // messages are untouched.
      final DateTime sent = t0.add(const Duration(hours: 1));
      final Conversation thread = await aStoredThread(at: sent);
      await repo.insertMessageIfNew(
        aMessage(
          conversationId: thread.id,
          text: 'and one more before it went',
          notificationKey: 'notif-2',
          sentAt: sent.add(const Duration(minutes: 5)),
        ),
      );

      await repo.openCaptureSession(t0);
      await repo.closeCaptureSession(t0.add(const Duration(hours: 2)));
      final ({DateTime endedAt, bool estimated})? reported = await repo
          .newestClosedCaptureSession();
      expect(reported?.estimated, isFalse);
      expect(reported?.endedAt, t0.add(const Duration(hours: 2)));

      await repo.openCaptureSession(t0.add(const Duration(hours: 3)));
      await repo.closeOpenCaptureSessionsAtLastEvidence(
        t0.add(const Duration(hours: 20)),
      );
      final ({DateTime endedAt, bool estimated})? discovered = await repo
          .newestClosedCaptureSession();
      expect(discovered!.estimated, isTrue);

      // What the user still sees in the thread, in INB-7's order, after both
      // closes: every message, with its text, none hidden and none deleted.
      final List<Message> kept = await repo.messages(thread.id);
      expect(kept.map((Message m) => m.text), <String>[
        'the boiler is fixed',
        'and one more before it went',
      ]);
      expect(
        kept.map((Message m) => m.kind),
        everyElement(MessageKind.text),
        reason: 'not one message is marked unreliable (PERM-9, CAP-12)',
      );
      expect(kept.map((Message m) => m.deletedAt), everyElement(isNull));
    });
  });

  group('PERM-9: the estimate flag and the upgrade that backfills it', () {
    late Directory dir;
    late String path;

    setUp(() async {
      // A file, not `:memory:`: an upgrade is two opens of one database, and an
      // in-memory one is gone the moment the first open closes.
      dir = await Directory.systemTemp.createTemp('replybox-perm9');
      path = '${dir.path}/replybox.db';
    });

    tearDown(() => dir.delete(recursive: true));

    /// A closed `capture_sessions` row as a **version-1** device could hold it:
    /// no `ended_is_estimate` column at all, and the only witness to which
    /// close wrote it is whether `updated_at` moved past `ended_at`.
    Future<void> insertVersion1Session(
      Database database, {
      required String id,
      required DateTime startedAt,
      required DateTime endedAt,
      required DateTime updatedAt,
    }) async {
      await database.insert('capture_sessions', <String, Object?>{
        'id': id,
        'created_at': timeToDb(startedAt),
        'updated_at': timeToDb(updatedAt),
        'deleted_at': null,
        'started_at': timeToDb(startedAt),
        'ended_at': timeToDb(endedAt),
      });
    }

    Future<List<Map<String, Object?>>> sessionsOf(DBHelper helper) async =>
        (await helper.database).query(
          'capture_sessions',
          columns: <String>[
            'id',
            'started_at',
            'ended_at',
            'ended_is_estimate',
          ],
          orderBy: 'started_at ASC',
        );

    test('the estimate flag survives the upgrade from version 1', () async {
      // §d's first three assertions. The fourth is the test after this one,
      // because "the upgrade re-dates nothing" is a different claim from "the
      // upgrade reads the old signal correctly" and they fail for different
      // reasons.
      expect(
        migrationSteps.length,
        3,
        reason: 'the flag is a fourth column and a third step, appended',
      );
      final DBHelper fresh = testDb();
      addTearDown(fresh.close);
      expect(await (await fresh.database).getVersion(), 3);

      final Database old = await openVersion1(path);
      // The reported close, as the previous build wrote it: updated_at is the
      // instant being claimed, because the listener said so inside its own
      // callback.
      await insertVersion1Session(
        old,
        id: 'reported',
        startedAt: t0,
        endedAt: t0.add(const Duration(hours: 2)),
        updatedAt: t0.add(const Duration(hours: 2)),
      );
      // The discovery close: ended_at is the last thing the app could prove and
      // updated_at is when it found out, an hour later.
      await insertVersion1Session(
        old,
        id: 'discovered',
        startedAt: t0.add(const Duration(hours: 3)),
        endedAt: t0.add(const Duration(hours: 4)),
        updatedAt: t0.add(const Duration(hours: 5)),
      );
      await old.close();

      final DBHelper upgraded = DBHelper(
        factoryOverride: databaseFactoryFfi,
        pathOverride: path,
      );
      addTearDown(upgraded.close);
      final List<Map<String, Object?>> rows = await sessionsOf(upgraded);

      expect(
        rows.map((Map<String, Object?> r) => r['ended_is_estimate']),
        <int>[0, 1],
        reason:
            'the reported close says "since"; the discovery says "since at least"',
      );

      // And what that means on screen, which is the reason the column exists:
      // the newest closed window is the discovered one, so PERM-8 hedges.
      final Repository upgradedRepo = Repository(upgraded);
      expect(
        (await upgradedRepo.newestClosedCaptureSession())!.estimated,
        isTrue,
      );
    });

    test('the upgrade re-dates no session', () async {
      // §d's fourth assertion, and DEL-1's discipline: the flag records how a
      // window ended and never when. An upgrade that moved an `ended_at` would
      // change what PERM-8's banner says the user lost, which is the one
      // direction CAP-12 may not be wrong in.
      final Database old = await openVersion1(path);
      await insertVersion1Session(
        old,
        id: 'reported',
        startedAt: t0,
        endedAt: t0.add(const Duration(hours: 2)),
        updatedAt: t0.add(const Duration(hours: 2)),
      );
      await insertVersion1Session(
        old,
        id: 'discovered',
        startedAt: t0.add(const Duration(hours: 3)),
        endedAt: t0.add(const Duration(hours: 4)),
        updatedAt: t0.add(const Duration(hours: 5)),
      );
      final List<Map<String, Object?>> before = await old.query(
        'capture_sessions',
        columns: <String>['id', 'started_at', 'ended_at'],
        orderBy: 'started_at ASC',
      );
      await old.close();

      final DBHelper upgraded = DBHelper(
        factoryOverride: databaseFactoryFfi,
        pathOverride: path,
      );
      addTearDown(upgraded.close);
      final List<Map<String, Object?>> after = await sessionsOf(upgraded);

      expect(after, hasLength(before.length), reason: 'no row gained or lost');
      for (int i = 0; i < before.length; i++) {
        expect(after[i]['id'], before[i]['id']);
        expect(after[i]['started_at'], before[i]['started_at']);
        expect(after[i]['ended_at'], before[i]['ended_at']);
      }
    });

    test('a fresh database records which close wrote each row', () async {
      // The same claim as the backfill, from the other end: on a database that
      // never saw version 1, the column is written directly by the two close
      // paths and `updated_at` goes back to meaning only what REC-1 says.
      await repo.openCaptureSession(t0);
      await repo.closeCaptureSession(t0.add(const Duration(hours: 1)));
      await repo.openCaptureSession(t0.add(const Duration(hours: 2)));
      await repo.closeOpenCaptureSessionsAtLastEvidence(
        t0.add(const Duration(hours: 9)),
      );

      final List<Map<String, Object?>> rows = await (await db.database).query(
        'capture_sessions',
        columns: <String>['ended_is_estimate'],
        orderBy: 'started_at ASC',
      );
      expect(
        rows.map((Map<String, Object?> r) => r['ended_is_estimate']),
        <int>[0, 1],
      );
    });
  });

  group('PERM-10: a listener that is not connected', () {
    setUp(() {
      listener.access = true;
      listener.connected = false;
    });

    test('a disconnected listener is asked to rebind once per resume', () async {
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(listener.rebinds, 1);
      expect(wait.asked, <Duration>[const Duration(seconds: 10)]);
      expect(provider.statusLine, CaptureStatusLine.notRunning);
      expect(
        provider.statusSince,
        isNull,
        reason:
            'the app does not know when the unbind happened and will not print '
            'the time it noticed instead (PERM-9)',
      );

      // A resume a full minute later asks once more, and only once more.
      now = t0.add(const Duration(seconds: 61));
      await provider.refresh();
      expect(listener.rebinds, 2);
      expect(wait.asked, hasLength(2));
    });

    test('a second resume inside sixty seconds asks for no rebind and shows '
        'the line at once', () async {
      final PermissionsProvider provider = build();
      await provider.refresh();
      expect(listener.rebinds, 1);

      now = t0.add(const Duration(seconds: 30));
      await provider.refresh();

      expect(listener.rebinds, 1, reason: 'the sixty-second floor');
      // The half that is easy to miss: the floor must also start no new wait,
      // or every glance at the app inside that minute would hide a state the
      // app already established for another ten seconds.
      expect(
        wait.asked,
        hasLength(1),
        reason: 'no new wait starts when the request is suppressed',
      );
      expect(provider.statusLine, CaptureStatusLine.notRunning);
    });

    test('the line does not show during the ten-second wait', () async {
      wait.hold = true;
      final PermissionsProvider provider = build();

      final Future<void> refreshing = provider.refresh();
      await untilWaiting();

      // This is "a first resume never accuses a listener that is merely slow to
      // bind", as the user would experience it: the rebind has been asked for,
      // the ten seconds are running, and the screen says nothing.
      expect(provider.statusLine, CaptureStatusLine.none);
      expect(listener.rebinds, 1);

      // A resume that lands inside the wait starts no second wait, makes no
      // second request — and, the part reached through a side door, does not
      // set the line either.
      await provider.refresh();
      expect(listener.rebinds, 1);
      expect(wait.asked, hasLength(1));
      expect(provider.statusLine, CaptureStatusLine.none);

      wait.release();
      await refreshing;

      expect(provider.statusLine, CaptureStatusLine.notRunning);
    });

    test('a listener that answers null is never accused', () async {
      // Null is "neither lifecycle callback has fired in this process" — a
      // build with no host on the channel, a run that started while the
      // listener happened to be unbound, a test. Nothing was learned, so
      // nothing is claimed, and no rebind is asked for on nothing.
      listener.connected = null;
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.none);
      expect(listener.rebinds, 0);
      expect(wait.asked, isEmpty);
    });

    test('the line is gone the moment the listener connects', () async {
      final PermissionsProvider provider = build();
      await provider.refresh();
      expect(provider.statusLine, CaptureStatusLine.notRunning);

      // The rebind took effect, or the user turned the screen on, or the system
      // rebound it of its own accord. Whichever it was, the line goes.
      listener.connected = true;
      now = t0.add(const Duration(seconds: 30));
      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.none);
      expect(
        listener.rebinds,
        1,
        reason: 'a connected listener is not asked to rebind',
      );
    });

    test('a listener that binds during the wait is never accused', () async {
      // The same clause from the other side, and the one a ten-second wait
      // exists for: slow to bind is not dead.
      wait.hold = true;
      final PermissionsProvider provider = build();
      final Future<void> refreshing = provider.refresh();
      await untilWaiting();

      listener.connected = true;
      wait.release();
      await refreshing;

      expect(provider.statusLine, CaptureStatusLine.none);
    });

    test(
      'a rebind request the channel cannot even make claims nothing',
      () async {
        // A throw is not evidence about the listener, exactly as a false from
        // `requestListenerRebind` is not: both mean the request could not be
        // made, and PERM-10 forbids either of them reaching the user as a failure
        // of capture. So the line keeps what it held — which here is nothing —
        // and the app does not fall over on a channel that went away.
        final PermissionsProvider onThrow = PermissionsProvider(
          repo,
          services(notifications: _ThrowingRebind(listener)),
          clock: () => now,
          delay: wait.call,
        );
        addTearDown(() {
          if (!onThrow.isDisposed) onThrow.dispose();
        });

        await expectLater(onThrow.refresh(), completes);

        expect(onThrow.statusLine, CaptureStatusLine.none);
        expect(
          wait.asked,
          isEmpty,
          reason: 'a request that was never made starts no wait',
        );
      },
    );
  });

  group('PERM-8 and PERM-10: a listener binding, heard without a resume', () {
    // PERM-8's banner "is gone on the first app resume **or listener binding**
    // after access returns, whichever comes first" and PERM-10's line is
    // removed "**the moment** the listener connects". Both clauses were built
    // as though a resume were the only thing that could clear them, so a
    // binding that happened while the app was open left both sentences on
    // screen until the user backgrounded the app and came back.
    //
    // The binding reaches Dart as a `listener_connected` row the listener
    // enqueues, drained by `CaptureSync`, which nudges the one `CaptureSignal`
    // every provider that can be on screen already listens to. So the
    // assertions below fire that signal: what the phone does is out of this
    // file's reach, and what the app does with the nudge is exactly what these
    // two clauses are.

    test('a binding while the app is open takes the not-running line away '
        'without a resume', () async {
      final CaptureSignal signal = aCaptureSignal();
      listener.access = true;
      listener.connected = false;
      final PermissionsProvider provider = build(signal: signal);

      await provider.refresh();
      expect(provider.statusLine, CaptureStatusLine.notRunning);

      // The rebind took effect four seconds later. Nothing resumes: the user is
      // looking at the list the whole time.
      listener.connected = true;
      now = t0.add(const Duration(seconds: 4));
      signal.captured();

      await until(
        () => provider.statusLine == CaptureStatusLine.none,
        'PERM-10: the line survived the binding that was supposed to remove '
        'it. The app went on saying capture was not running while it was.',
      );
      expect(
        listener.rebinds,
        1,
        reason:
            'PERM-10 counts requests per resume and per sixty seconds, and a '
            'signal is neither: the binding was heard, not asked for again',
      );
      expect(
        wait.asked,
        hasLength(1),
        reason: 'and it started no second ten-second wait',
      );
    });

    test('a binding takes PERM-8\'s banner away when access came back, and the '
        'system is what is asked', () async {
      final CaptureSignal signal = aCaptureSignal();
      listener.access = false;
      final PermissionsProvider provider = build(signal: signal);

      await provider.refresh();
      expect(provider.statusLine, CaptureStatusLine.accessNeverOn);
      final int readsBefore = listener.accessReads;

      // The grant was made and the listener bound. PERM-8's "whichever comes
      // first" is the binding here, and there has been no resume to carry it.
      listener.access = true;
      listener.connected = true;
      signal.captured();

      await until(
        () => provider.statusLine == CaptureStatusLine.none,
        'PERM-8: the banner outlived the binding that was supposed to take it '
        'away',
      );
      expect(provider.hasAccess, isTrue);
      expect(provider.statusSince, isNull);
      // PERM-5, through the new door. A signal is a cue to look and never
      // evidence about the grant: the answer came from the platform on this
      // read, exactly as it does on a resume.
      expect(
        listener.accessReads,
        greaterThan(readsBefore),
        reason:
            'PERM-5: the banner cleared without the system being asked, which '
            'means something stored decided it',
      );
    });

    test('a signal storm asks for no rebind and starts no second wait', () async {
      // A reconnection drains a queue, and the spike's own fixture delivered
      // five events under one timestamp — so the realistic shape of this signal
      // is a burst, not a single nudge. Two things must survive it: PERM-10's
      // sixty-second floor, and the cap of one request per resume, which a
      // storm sixty-one seconds after a resume would otherwise walk straight
      // past.
      final CaptureSignal signal = aCaptureSignal();
      listener.access = true;
      listener.connected = false;
      final PermissionsProvider provider = build(signal: signal);

      await provider.refresh();
      expect(listener.rebinds, 1);
      expect(wait.asked, hasLength(1));

      // Well past the floor, so nothing but the rule itself is stopping a
      // second request.
      now = t0.add(const Duration(minutes: 5));
      for (int i = 0; i < 20; i++) {
        signal.captured();
      }
      await settle();

      expect(
        listener.rebinds,
        1,
        reason:
            'PERM-10: a capture signal asked Android to rebind. The request is '
            'a resume\'s, and twenty signals are not twenty resumes.',
      );
      expect(
        wait.asked,
        hasLength(1),
        reason: 'and no signal started a second ten-second wait',
      );
      expect(
        provider.statusLine,
        CaptureStatusLine.notRunning,
        reason:
            'the finding the resume established still stands: a signal that '
            'asked for nothing also un-said nothing',
      );
      expect(
        listener.accessReads,
        3,
        reason:
            'one resume, one read in flight and one queued behind it. Twenty '
            'signals are not twenty platform reads.',
      );
    });

    test('a signal after dispose reads nothing and throws nothing', () async {
      // `main.dart` disposes this provider before the signal it listens to, and
      // a drain in flight can nudge the signal while the tree is coming down.
      final CaptureSignal signal = aCaptureSignal();
      listener.access = true;
      listener.connected = true;
      final PermissionsProvider provider = build(signal: signal);
      await provider.refresh();
      final int readsBefore = listener.accessReads;

      provider.dispose();
      signal.captured();
      await settle();

      expect(
        listener.accessReads,
        readsBefore,
        reason:
            'the subscription outlived dispose, so a dead provider was still '
            'asking the platform questions for a screen nobody is looking at',
      );
    });
  });

  group('PERM-11: silence is never reported as failure', () {
    setUp(() {
      listener.access = true;
      listener.connected = true;
    });

    test('twenty-three hours of silence says nothing', () async {
      final DateTime lastEvent = t0.add(const Duration(hours: 1));
      await aPhoneThatHasBeenCapturing(lastEventAt: lastEvent);
      now = lastEvent.add(const Duration(hours: 23));
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.none);
      expect(
        await repo.quietNoticeShownAt(),
        isNull,
        reason: 'nothing was said, so nothing is stamped',
      );
    });

    test('twenty-four hours with no enabled app ever seen posting says '
        'nothing', () async {
      // A phone where no included app has ever posted — nothing installed,
      // everything switched off — is not a phone with a problem. A line here
      // would be the app describing the user's own setup back to them as a
      // fault.
      final DateTime lastEvent = t0.add(const Duration(hours: 1));
      await repo.installedAt(t0);
      await repo.noteCaptureEventAt(lastEvent);
      await repo.upsertSeenApp(
        package: 'com.example.shopping',
        label: 'Shopping',
        enabledIfNew: false,
        at: t0.add(const Duration(minutes: 1)),
      );
      now = lastEvent.add(const Duration(hours: 30));
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.none);
      expect(await repo.quietNoticeShownAt(), isNull);
    });

    test('twenty-four hours with both preconditions met shows the quiet '
        'line', () async {
      final DateTime lastEvent = t0.add(const Duration(hours: 1));
      await aPhoneThatHasBeenCapturing(lastEventAt: lastEvent);
      now = lastEvent.add(const Duration(hours: 25));
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.quiet);
      expect(
        provider.statusSince,
        lastEvent,
        reason: 'the line states when something last arrived',
      );
      // What it is not: a failure. With the listener connected there is nothing
      // to accuse, and `notRunning` here would be exactly the third state
      // dressed up as the second.
      expect(provider.statusLine, isNot(CaptureStatusLine.notRunning));
      expect(listener.rebinds, 0);
    });

    test('the stated time is the newest of the last event and the last '
        'connection, never the time it was noticed', () async {
      // A listener that bound five hours after the last message is not a phone
      // that has been silent since the message: the window starts at the
      // reconnection, or every rebind would be reported as a day of silence.
      final DateTime lastEvent = t0.add(const Duration(hours: 1));
      final DateTime bound = t0.add(const Duration(hours: 5));
      await aPhoneThatHasBeenCapturing(lastEventAt: lastEvent);
      await repo.openCaptureSession(bound);
      now = bound.add(const Duration(hours: 26));
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.quiet);
      expect(provider.statusSince, bound);
      expect(
        provider.statusSince,
        isNot(now),
        reason:
            'the app never prints the time it looked as the time something '
            'happened (product principle 3)',
      );
    });

    test('the line shows at most once in any twenty-four hours, across a '
        'relaunch', () async {
      final DateTime lastEvent = t0.add(const Duration(hours: 1));
      await aPhoneThatHasBeenCapturing(lastEventAt: lastEvent);
      now = lastEvent.add(const Duration(hours: 25));
      final PermissionsProvider first = build();

      await first.refresh();
      expect(first.statusLine, CaptureStatusLine.quiet);
      // The line was drawn, and the notice says so. That call is what starts
      // the twenty-four hours this test is about — see the two tests below for
      // why it is the notice and not the read that spends them.
      await first.markQuietNoticeShown();

      // A second resume an hour later. Still silent, still connected, and the
      // app says nothing more.
      now = now.add(const Duration(hours: 1));
      await first.refresh();
      expect(first.statusLine, CaptureStatusLine.none);

      // The process dies and comes back inside the same window. The stamp is
      // what makes the limit survive that, rather than a field that died with
      // the run.
      first.dispose();
      final PermissionsProvider relaunch = build();
      await relaunch.refresh();
      expect(
        relaunch.statusLine,
        CaptureStatusLine.none,
        reason: 'at most once in any twenty-four hours, stamped not remembered',
      );

      // A day later it may speak again — the window rolls, or the line would
      // show once per install and never again.
      now = now.add(const Duration(hours: 25));
      await relaunch.refresh();
      expect(relaunch.statusLine, CaptureStatusLine.quiet);
    });

    test('resolving the line spends nothing: the budget is for a sentence '
        'somebody read', () async {
      // The defect this pins. The stamp used to be written at the bottom of the
      // read that *decided* the line could show — and `main.dart` runs that
      // read from its `initState`, before the first frame, and then pushes the
      // disclosure and PERM-14's guidance over the inbox. So the one showing
      // PERM-11 allows in a day was spent behind two routes, on a line nobody
      // had read, and the app then stayed silent about a phone it had noticed
      // going quiet until the next day.
      final DateTime lastEvent = t0.add(const Duration(hours: 1));
      await aPhoneThatHasBeenCapturing(lastEventAt: lastEvent);
      now = lastEvent.add(const Duration(hours: 25));
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.quiet);
      expect(
        await repo.quietNoticeShownAt(),
        isNull,
        reason:
            'PERM-11: resolving the line spent the day\'s one showing. The '
            'notice is what reports its own showing, exactly as PERM-14\'s '
            'screen does.',
      );

      // And because nothing was shown, the offer is still open. A line the
      // reader never got is not a line they have had today.
      now = now.add(const Duration(minutes: 5));
      await provider.refresh();
      expect(provider.statusLine, CaptureStatusLine.quiet);
    });

    test('the notice reporting its own showing is what spends it', () async {
      final DateTime lastEvent = t0.add(const Duration(hours: 1));
      await aPhoneThatHasBeenCapturing(lastEventAt: lastEvent);
      now = lastEvent.add(const Duration(hours: 25));
      final PermissionsProvider provider = build();
      await provider.refresh();
      expect(provider.statusLine, CaptureStatusLine.quiet);

      // What `CaptureStatusNotice` calls from its own `initState` once it has a
      // sentence on screen.
      await provider.markQuietNoticeShown();

      expect(
        await repo.quietNoticeShownAt(),
        now,
        reason: 'the stamp is the instant the line was drawn',
      );
      // An hour later the twenty-four hours are the app's answer, and they are
      // measured from the showing.
      now = now.add(const Duration(hours: 1));
      await provider.refresh();
      expect(provider.statusLine, CaptureStatusLine.none);

      // A day past that showing it may speak again: the window rolls, or the
      // line would show once per install and never after.
      now = now.add(const Duration(hours: 24));
      await provider.refresh();
      expect(provider.statusLine, CaptureStatusLine.quiet);
    });

    test('dismissing it takes it away for the run and is not the same as never '
        'having held it', () async {
      final DateTime lastEvent = t0.add(const Duration(hours: 1));
      await aPhoneThatHasBeenCapturing(lastEventAt: lastEvent);
      now = lastEvent.add(const Duration(hours: 25));
      final PermissionsProvider provider = build();
      await provider.refresh();
      expect(provider.statusLine, CaptureStatusLine.quiet);

      await provider.dismissQuietNotice();

      expect(provider.statusLine, CaptureStatusLine.none);
      expect(provider.quietNoticeDismissed, isTrue);
      // And it stays gone for the run even once the window has rolled: the user
      // has said they are not interested in this observation.
      now = now.add(const Duration(hours: 30));
      await provider.refresh();
      expect(provider.statusLine, CaptureStatusLine.none);
    });
  });

  group('PERM-13: one line, and which one', () {
    test(
      'access off wins over a disconnected listener and over silence',
      () async {
        // All three conditions true at once. The access banner is the first in
        // the order, and the other two are not merely outranked — they are never
        // evaluated, because they are only meaningful when the higher state is
        // false.
        final DateTime unbound = t0.add(const Duration(hours: 2));
        await aPhoneThatHasBeenCapturing(
          lastEventAt: t0.add(const Duration(hours: 1)),
        );
        await repo.openCaptureSession(t0);
        await repo.closeCaptureSession(unbound);
        listener.access = false;
        listener.connected = false;
        now = t0.add(const Duration(hours: 40));
        final PermissionsProvider provider = build();

        await provider.refresh();

        expect(provider.statusLine, CaptureStatusLine.accessOffSince);
        expect(provider.statusSince, unbound);
        expect(
          listener.connectedReads,
          0,
          reason: 'PERM-10 is not asked when access is off',
        );
        expect(listener.rebinds, 0);
        expect(
          await repo.quietNoticeShownAt(),
          isNull,
          reason: 'PERM-11 is not evaluated, so nothing is stamped',
        );
      },
    );

    test('a disconnected listener wins over silence', () async {
      await aPhoneThatHasBeenCapturing(
        lastEventAt: t0.add(const Duration(hours: 1)),
      );
      listener.access = true;
      listener.connected = false;
      now = t0.add(const Duration(hours: 40));
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(provider.statusLine, CaptureStatusLine.notRunning);
      expect(provider.statusSince, isNull);
      expect(
        await repo.quietNoticeShownAt(),
        isNull,
        reason: 'the silence has a known cause, so it is not reported as one',
      );
    });
  });

  group('PERM-14: guidance offered once, about a phone it names', () {
    test('the guidance is offered once, on the first launch that reads access '
        'as granted', () async {
      listener.access = false;
      final PermissionsProvider provider = build();
      await provider.refresh();
      expect(
        provider.shouldShowBatteryGuidance,
        isFalse,
        reason:
            'guidance about keeping a listener alive over a banner saying '
            'capture is off would be two screens disagreeing',
      );

      listener.access = true;
      listener.connected = true;
      await provider.refresh();
      expect(provider.shouldShowBatteryGuidance, isTrue);

      await provider.markBatteryGuidanceShown();
      expect(provider.shouldShowBatteryGuidance, isFalse);
      provider.dispose();

      final PermissionsProvider relaunch = build();
      await relaunch.refresh();
      expect(relaunch.shouldShowBatteryGuidance, isFalse);
    });

    test('the stored flag records that the guidance was shown and not that the '
        'grant was made', () async {
      // The process is killed on the system page: the grant is made, the app
      // reads it on the next launch, and the guidance has still never been on
      // screen. A flag that recorded the grant would swallow the one showing
      // the user was owed.
      listener.access = true;
      listener.connected = true;
      final PermissionsProvider killed = build();
      await killed.refresh();
      expect(killed.shouldShowBatteryGuidance, isTrue);
      expect(
        await repo.batteryGuidanceShownAt(),
        isNull,
        reason: 'reading a grant writes nothing',
      );
      killed.dispose();

      final PermissionsProvider relaunch = build();
      await relaunch.refresh();

      expect(relaunch.shouldShowBatteryGuidance, isTrue);
    });

    test(
      'the manufacturer is what the device reported, read once per run',
      () async {
        settings.reportedManufacturer = 'Xiaomi';
        listener.access = true;
        listener.connected = true;
        final PermissionsProvider provider = build();

        await provider.refresh();
        expect(provider.manufacturer, 'Xiaomi');
        expect(
          provider.guidance,
          isNull,
          reason: 'the table is empty, so every phone takes the generic branch',
        );

        // `Build.MANUFACTURER` cannot move under a running process, so a second
        // resume is not a second channel round trip.
        await provider.refresh();
        expect(settings.manufacturerReads, 1);
      },
    );

    test('a phone that reported no manufacturer is not given one', () async {
      settings.reportedManufacturer = null;
      listener.access = true;
      listener.connected = true;
      final PermissionsProvider provider = build();

      await provider.refresh();

      expect(
        provider.manufacturer,
        isNull,
        reason:
            'the screen says the phone did not report one rather than printing '
            'a name the device never gave',
      );
    });

    test('the manufacturer table ships empty and every entry it could hold '
        'carries a verified date', () async {
      // Decision 11: an entry with no verified date does not ship. The first
      // assertion is today's state and the second is the guard on the day a
      // hardware run adds the first entry — it is the one that has to be here
      // before there is anything to guard.
      expect(
        batteryGuidanceByManufacturer,
        isEmpty,
        reason:
            'the 24-hour OEM survival check has not run, so any path in here '
            'would be a claim about a named manufacturer (decision 11)',
      );
      batteryGuidanceByManufacturer.forEach((
        String key,
        BatteryGuidanceEntry entry,
      ) {
        expect(entry.verifiedDevice, isNotEmpty, reason: 'entry "$key"');
        expect(entry.stepMessageIds, isNotEmpty, reason: 'entry "$key"');
        expect(
          entry.verifiedOn.isAfter(DateTime.utc(2026)),
          isTrue,
          reason: 'entry "$key" carries a real verification date',
        );
      });
    });

    test('a manufacturer lookup is an exact lower-cased match and nothing '
        'looser', () async {
      // What every phone sees today: no entry, whatever it calls itself, so the
      // screen names the manufacturer and offers the two Android pages.
      for (final String reported in <String>[
        'Xiaomi',
        'xiaomi',
        'XIAOMI',
        'Xiaomi Communications',
        'samsung',
      ]) {
        expect(
          batteryGuidanceFor(reported),
          isNull,
          reason: '"$reported" is not a phone this app has been tested on',
        );
      }
      expect(batteryGuidanceFor(null), isNull);
      expect(batteryGuidanceFor('   '), isNull);

      // The two halves of "exact", asserted over whatever the table holds. Both
      // loops are empty today and neither is decoration: the first is what
      // stops a future entry being keyed in a shape the lookup cannot reach,
      // and the second is what stops a near-match being served steps verified
      // on someone else's hardware.
      for (final String key in batteryGuidanceByManufacturer.keys) {
        expect(key, key.trim().toLowerCase(), reason: 'keys are normalised');
        expect(batteryGuidanceFor(key.toUpperCase()), isNotNull);
        expect(batteryGuidanceFor('  $key  '), isNotNull);
        expect(
          batteryGuidanceFor('$key Technologies'),
          isNull,
          reason: 'no prefix match, no contains, no alias list',
        );
      }
    });

    test(
      'a settings page that does not open is a false and never a throw',
      () async {
        settings.opens = false;
        final PermissionsProvider provider = build();

        // PERM-7's shape, reached a second time: the screen replaces the control
        // with the written path rather than leaving a button that does nothing.
        expect(await provider.openBatteryOptimisationSettings(), isFalse);
        expect(await provider.openAppInfoSettings(), isFalse);

        settings.opens = true;
        expect(await provider.openBatteryOptimisationSettings(), isTrue);
        expect(await provider.openAppInfoSettings(), isTrue);
      },
    );
  });

  group('PERM-15: this area adds no permission', () {
    test('nothing in this area is reachable without a permission', () {
      // The Kotlin this round added — `requestRebind`, `Build.MANUFACTURER`,
      // `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`,
      // `ACTION_APPLICATION_DETAILS_SETTINGS` — is exactly the shape of change
      // that grows a `uses-permission` without anybody deciding to. Two things
      // hold the line and both are asserted here:
      //
      //  * the release manifest declares none (`manifest_test.dart` owns the
      //    same claim from the CAP-20 side; this one is PERM-15's, and it is
      //    cheap enough to be worth failing twice);
      //  * `ALLOWED` in `release.yml` is still empty, which nothing else in the
      //    suite reads. The gate fails in both directions, so an empty list is
      //    what makes "the artifact declares nothing" checkable on every
      //    release rather than only here.
      final File manifest = File('android/app/src/main/AndroidManifest.xml');
      expect(
        manifest.existsSync(),
        isTrue,
        reason: 'a test that quietly checks nothing is how a permission ships',
      );
      // Comments stripped, and load-bearing: the manifest's own CAP-20 comment
      // writes out `<uses-permission>` in order to say capture declares none,
      // so a raw read would fail on the paragraph explaining the absence.
      final String xml = manifest.readAsStringSync().replaceAll(
        RegExp(r'<!--.*?-->', dotAll: true),
        '',
      );
      expect(
        xml,
        isNot(contains('<uses-permission')),
        reason:
            'PERM-15: the disclosure, the rebind, the manufacturer read and '
            'both settings intents change the built permission list by nothing',
      );

      final File release = File('.github/workflows/release.yml');
      expect(release.existsSync(), isTrue);
      expect(
        release.readAsStringSync(),
        contains("ALLOWED: ''"),
        reason:
            'an empty ALLOWED means "declares no permissions at all", and the '
            'onboarding PR leaves it identical (RUN-2, PERM-15)',
      );
    });
  });

  group('disposal', () {
    test('a wait that finishes into a dead provider announces nothing and '
        'throws nothing', () async {
      // The one thing in this class that can outlive the tree: PERM-10's ten
      // seconds are a future, not a `Timer`, so nothing can be cancelled — the
      // code after the wait has to notice the tree came down instead. A
      // notification after `dispose` is a `ChangeNotifier` throw on a phone
      // that merely went to the home screen ten seconds after a resume.
      wait.hold = true;
      listener.access = true;
      listener.connected = false;
      final PermissionsProvider provider = build();
      int announcements = 0;
      provider.addListener(() => announcements += 1);

      final Future<void> refreshing = provider.refresh();
      await untilWaiting();
      final int before = announcements;

      provider.dispose();
      wait.release();

      await expectLater(refreshing, completes);
      expect(
        announcements,
        before,
        reason: 'nothing is announced after dispose',
      );
      expect(
        provider.statusLine,
        CaptureStatusLine.none,
        reason: 'and nothing is written into a dead provider either',
      );
    });

    test(
      'a resume that lands after dispose stops at the first check',
      () async {
        // `main.dart`'s lifecycle observer can fire while the tree is coming
        // down, so a refresh on a dead provider is a real sequence and not a
        // contrived one. It completes, it draws nothing, and it does not go on
        // asking the platform questions for a screen nobody is looking at.
        listener.access = true;
        listener.connected = true;
        final PermissionsProvider provider = build();
        provider.dispose();

        await expectLater(provider.refresh(), completes);

        expect(provider.statusLine, CaptureStatusLine.none);
        expect(
          listener.connectedReads,
          0,
          reason: 'it returns at the first isDisposed check, not at the last',
        );
      },
    );
  });
}

/// A channel whose rebind request throws, which the platform is entitled to do
/// and PERM-10 spends the same way as a false: nothing was learned.
class _ThrowingRebind implements NotificationSource {
  _ThrowingRebind(this._delegate);

  final _Listener _delegate;

  @override
  Future<bool> hasAccess() => _delegate.hasAccess();

  @override
  Future<void> openAccessSettings() => _delegate.openAccessSettings();

  @override
  Stream<Map<String, Object?>> events() => _delegate.events();

  @override
  Future<bool?> listenerConnected() => _delegate.listenerConnected();

  @override
  Future<bool> requestListenerRebind() async =>
      throw PlatformException(code: 'no_host');
}
