/// One pass of [CaptureSync], driven end to end.
///
/// This is the loop that decides whether a message captured at 3am is visible
/// at 8am: the listener runs whether or not Dart does (CAP-13), so nothing else
/// moves the native queue into the database. Everything it does is guarded —
/// per app, per row, per pass — and every one of those guards swallows a throw,
/// so a break in here looks exactly like a quiet phone (section 9). That is why
/// these tests assert what ends up on screen: the texts in the thread, the
/// packages the filter was handed, the rows the listener was told to release.
///
/// The source is a subclass of the real [AndroidNotificationSource] rather than
/// a hand-written double, so the methods under test are the ones `main.dart`
/// wires up, and the repository is a real in-memory SQLite from `helpers.dart`.
/// Faults are injected at the two places the production comments say they
/// happen: a label the `apps` row rejects, and a message write that fails.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/capture/capture_event.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:replybox/models/source_app.dart';
import 'package:replybox/providers/apps_provider.dart';
import 'package:replybox/services/android_capture_service.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:replybox/services/services.dart';

import 'helpers.dart';

/// The listener, faked at the class the app actually uses.
///
/// It records the order it was called in, because the order is a rule: the
/// seen-apps rows are written before the enabled set is mirrored down, or a
/// stale set undoes the first-sighting default CAP-1 has just applied
/// (CAP-1, INB-20).
class _FakeListener extends AndroidNotificationSource {
  _FakeListener();

  /// Every listener call, in order, so a test can assert that two passes ran
  /// one after the other rather than interleaved.
  final List<String> calls = <String>[];

  List<SeenSourceApp> seen = <SeenSourceApp>[];
  final List<List<String>> ackedApps = <List<String>>[];
  final List<List<String>> pushedFilter = <List<String>>[];

  /// The `known` half of each push: every package the database held a row for
  /// when the mirror went down. It is what bounds the listener's own pending
  /// packages, so a test that only looked at the enabled half would pass over
  /// a package the user switched off staying on the phone (CAP-1, INB-22).
  final List<List<String>> pushedKnown = <List<String>>[];

  List<QueuedCaptureEvent> queue = <QueuedCaptureEvent>[];
  final List<List<String>> ackedRows = <List<String>>[];
  int drains = 0;

  CaptureFaults faults = const CaptureFaults();

  /// Runs inside [drainQueue], after the rows for this drain have been taken
  /// and before they are returned: the moment a notification arriving while a
  /// pass is in flight would land in the queue.
  void Function(int drain)? duringDrain;

  final StreamController<Map<String, Object?>> live =
      StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<List<SeenSourceApp>> takeSeenApps() async {
    calls.add('takeSeenApps');
    return List<SeenSourceApp>.of(seen);
  }

  @override
  Future<void> ackSeenApps(List<String> packages) async {
    calls.add('ackSeenApps');
    ackedApps.add(List<String>.of(packages));
    // The listener clears exactly what it was acked for and keeps the rest
    // pending, which is the behaviour the production doc comment promises.
    seen = seen
        .where((SeenSourceApp app) => !packages.contains(app.package))
        .toList();
  }

  @override
  Future<void> setEnabledPackages(
    List<String> packages,
    List<String> known,
  ) async {
    calls.add('setEnabledPackages');
    pushedFilter.add(List<String>.of(packages));
    pushedKnown.add(List<String>.of(known));
  }

  @override
  Future<List<QueuedCaptureEvent>> drainQueue() async {
    calls.add('drainQueue');
    drains += 1;
    final List<QueuedCaptureEvent> rows = List<QueuedCaptureEvent>.of(queue);
    duringDrain?.call(drains);
    return rows;
  }

  @override
  Future<void> ackQueue(List<String> rowIds) async {
    calls.add('ackQueue');
    ackedRows.add(List<String>.of(rowIds));
    queue = queue
        .where((QueuedCaptureEvent row) => !rowIds.contains(row.rowId))
        .toList();
  }

  @override
  Future<CaptureFaults> captureFaults() async {
    calls.add('captureFaults');
    return faults;
  }

  @override
  Stream<Map<String, Object?>> events() => live.stream;
}

/// A real repository that fails where the production comments say a failure
/// happens, and only there.
///
/// Both guards in `_syncOnce` exist for a real fault that cannot be reproduced
/// through SQLite from a test: "a label the channel handed over as something
/// the row cannot hold" and a write that fails under a constraint a migration
/// has not reached. Injecting them here is the only way to reach the code that
/// decides what is acked afterwards — and that decision is the whole of CAP-15.
class _FaultyRepository extends Repository {
  _FaultyRepository(super.db);

  /// An `apps` row carrying this label throws instead of being written.
  String? rejectLabel;

  /// A message carrying this text throws instead of being stored.
  String? rejectText;

  @override
  Future<SourceApp> upsertSeenApp({
    required String package,
    required String label,
    required bool enabledIfNew,
    required DateTime at,
  }) {
    if (rejectLabel != null && label == rejectLabel) {
      throw StateError('the apps row rejected the label $label');
    }
    return super.upsertSeenApp(
      package: package,
      label: label,
      enabledIfNew: enabledIfNew,
      at: at,
    );
  }

  @override
  Future<List<({bool wrote, String id})>> insertMessagesIfNew(
    List<Message> messages,
  ) {
    if (rejectText != null &&
        messages.any((Message m) => m.text == rejectText)) {
      throw StateError('the message write failed');
    }
    return super.insertMessagesIfNew(messages);
  }
}

/// A filter that cannot be told. INB-22's failure path: the switch moved on
/// screen and the listener never heard about it.
class _UnreachableCaptureFilter implements CaptureFilter {
  @override
  Future<void> setEnabledPackages(
    List<String> packages,
    List<String> known,
  ) async => throw StateError('the listener could not be told');
}

/// One `posted` row of the native queue, MessagingStyle with a one-entry
/// history — the shape Google Messages posts, which is the only real app the
/// spike measured (CAP-4, CAP-5's correction).
QueuedCaptureEvent _posted({
  required String rowId,
  required String text,
  required DateTime at,
  String package = 'com.whatsapp',
  String shortcutId = 'ada',
  String title = 'Ada Lovelace',
  String sender = 'Ada',
}) => QueuedCaptureEvent(
  rowId: rowId,
  json: <String, Object?>{
    'event': 'posted',
    'key': '0|$package|$rowId',
    'package': package,
    'postTime': at.millisecondsSinceEpoch,
    'template': messagingStyleTemplate,
    'shortcutId': shortcutId,
    'title': title,
    'selfDisplayName': 'Hassan',
    'messages': <Object?>[
      <String, Object?>{
        'sender': sender,
        'text': text,
        'time': at.millisecondsSinceEpoch,
      },
    ],
  },
);

SeenSourceApp _seen(
  String package,
  String label, {
  bool enabledByDefault = false,
  Duration ago = Duration.zero,
}) => SeenSourceApp(
  package: package,
  label: label,
  lastSeenAt: t0.subtract(ago),
  enabledByDefault: enabledByDefault,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initTestDatabases);

  late DBHelper db;
  late _FaultyRepository repo;
  late _FakeListener listener;
  late CaptureHealth health;
  late CaptureSync sync;

  setUp(() async {
    db = testDb();
    repo = _FaultyRepository(db);
    listener = _FakeListener();
    health = CaptureHealth();
    sync = CaptureSync(listener, repo, health);
  });

  tearDown(() async {
    sync.stop();
    await listener.live.close();
    await db.close();
  });

  /// Everything the inbox would draw for the one thread the tests build: the
  /// texts, in the order INB-7 puts them in.
  Future<List<String?>> threadTexts() async {
    final List<Conversation> conversations = await repo.conversations();
    if (conversations.isEmpty) return <String?>[];
    return (await repo.messages(
      conversations.single.id,
    )).map((Message m) => m.text).toList();
  }

  group('CaptureSync: one pass', () {
    // The queue for the pass below. Four rows in one thread; the third one's
    // write fails.
    const String boom = 'the write that fails';
    final DateTime t1 = t0.add(const Duration(minutes: 1));
    final DateTime t2 = t0.add(const Duration(minutes: 2));
    final DateTime t3 = t0.add(const Duration(minutes: 3));

    setUp(() {
      listener.seen = <SeenSourceApp>[
        // A shipped app, on the first time it posts (CAP-1, decision 9).
        _seen('com.whatsapp', 'WhatsApp', enabledByDefault: true),
        // The label the row rejects. Nothing about this package reaches the
        // database, so INB-20's chooser cannot offer it — which is why it must
        // stay pending on the listener rather than being acked away.
        _seen('com.example.broken', 'rejected label'),
        _seen('com.example.shopping', 'Shopping', ago: const Duration(days: 1)),
      ];
      repo.rejectLabel = 'rejected label';
      repo.rejectText = boom;
      listener.queue = <QueuedCaptureEvent>[
        _posted(rowId: 'r1', text: 'the boiler is fixed', at: t0),
        _posted(rowId: 'r2', text: 'call me when you are up', at: t1),
        _posted(rowId: 'r3', text: boom, at: t2),
        _posted(rowId: 'r4', text: 'are we still on for eight', at: t3),
      ];
    });

    test(
      'a package whose row would not write is not acked away (INB-20)',
      () async {
        await sync.sync();

        // INB-20/INB-21: this list is the only place a non-shipped package ever
        // appears, so a sighting acked before its row landed is an app the user
        // can never switch on. It stays pending instead, and the next pass
        // writes it.
        expect(listener.ackedApps.single, <String>[
          'com.whatsapp',
          'com.example.shopping',
        ]);
        expect(
          listener.seen.map((SeenSourceApp a) => a.package),
          <String>['com.example.broken'],
          reason:
              'the listener still holds the sighting it was never acked for',
        );
        // What the chooser would draw: the two that landed, by label.
        expect((await repo.allApps()).map((SourceApp a) => a.label), <String>[
          'Shopping',
          'WhatsApp',
        ]);
      },
    );

    test('the enabled mirror goes down after the seen rows, carrying the app '
        'the listener just defaulted on (CAP-1)', () async {
      await sync.sync();

      // The order is the rule. Mirroring first would hand back a set with no
      // com.whatsapp in it and undo the first-sighting default the listener
      // applied before Dart ever ran — on an install where the shipped app is
      // the only thing being captured, that is capture switching itself off.
      expect(
        listener.calls.indexOf('setEnabledPackages'),
        greaterThan(listener.calls.indexOf('takeSeenApps')),
      );
      expect(
        listener.calls.indexOf('setEnabledPackages'),
        greaterThan(listener.calls.indexOf('ackSeenApps')),
      );
      expect(listener.pushedFilter.single, <String>['com.whatsapp']);
      expect(
        listener.pushedFilter.single,
        isNot(contains('com.example.shopping')),
        reason: 'an app seen posting is off until the user turns it on (CAP-1)',
      );
      // The `known` half bounds what the listener may keep of its own: a
      // package we hold a row for is off on the phone the moment this returns,
      // whatever the listener still has pending. com.example.broken is
      // deliberately absent — no row landed, so nothing can speak for it yet.
      expect(listener.pushedKnown.single, <String>[
        'com.example.shopping',
        'com.whatsapp',
      ]);
      expect(
        listener.pushedFilter.single.every(
          listener.pushedKnown.single.contains,
        ),
        isTrue,
        reason: 'the enabled set is always a subset of the known set',
      );
    });

    test('only the rows whose event was written are released (CAP-15)', () async {
      await sync.sync();

      expect(listener.ackedRows.single, <String>['r1', 'r2', 'r4']);
      // CAP-15 releases a row when its event has been written, so the row whose
      // ingest threw is still in the queue for the next pass.
      expect(listener.queue.map((QueuedCaptureEvent r) => r.rowId), <String>[
        'r3',
      ]);
    });

    test('the thread holds the three messages that landed, with their '
        'texts', () async {
      await sync.sync();

      // The texts, not a count: a pass that stored three empty rows would pass
      // a count and would be a thread the user cannot read.
      expect(await threadTexts(), <String>[
        'the boiler is fixed',
        'call me when you are up',
        'are we still on for eight',
      ]);
      final Conversation thread = (await repo.conversations()).single;
      expect(thread.title, 'Ada Lovelace');
      expect(thread.package, 'com.whatsapp');
    });

    test('a redelivery of the same messages adds nothing (CAP-5)', () async {
      await sync.sync();

      // CAP-13's reconnection re-read hands the same messages over again under
      // new queue rows. CAP-5 matches on content, so nothing is stored twice —
      // and the new rows are still released, or the queue would never empty.
      listener.queue = <QueuedCaptureEvent>[
        ...listener.queue,
        _posted(rowId: 'r5', text: 'the boiler is fixed', at: t0),
        _posted(rowId: 'r6', text: 'call me when you are up', at: t1),
        _posted(rowId: 'r7', text: 'are we still on for eight', at: t3),
      ];

      await sync.sync();

      expect(await threadTexts(), <String>[
        'the boiler is fixed',
        'call me when you are up',
        'are we still on for eight',
      ]);
      expect(listener.ackedRows.last, <String>['r5', 'r6', 'r7']);
      expect(
        listener.queue.map((QueuedCaptureEvent r) => r.rowId),
        <String>['r3'],
        reason: 'the row that still fails is still not acked',
      );
    });

    test('the row that failed lands on the pass after the fault clears, and '
        'is acked then (CAP-15)', () async {
      await sync.sync();
      repo.rejectText = null;

      await sync.sync();

      // Every message the user was sent, in INB-7's order, including the one
      // that took two passes to arrive.
      expect(await threadTexts(), <String>[
        'the boiler is fixed',
        'call me when you are up',
        boom,
        'are we still on for eight',
      ]);
      expect(listener.ackedRows.last, <String>['r3']);
      expect(listener.queue, isEmpty);
    });

    test('the package whose row failed is written on the next pass '
        '(INB-20)', () async {
      await sync.sync();
      repo.rejectLabel = null;

      await sync.sync();

      expect(
        (await repo.allApps()).map((SourceApp a) => a.package),
        contains('com.example.broken'),
      );
      expect(listener.ackedApps.last, <String>['com.example.broken']);
      expect(listener.seen, isEmpty);
    });
  });

  group('CaptureSync: rows the rules refuse', () {
    test('a malformed row is released rather than left to wedge the '
        'queue', () async {
      // A row the contract does not define and a row with no key at all. Both
      // are understood and correctly change nothing, and both are acked: a
      // queue that only released stored events would never empty on a phone
      // full of ongoing notifications (CAP-15).
      listener.seen = <SeenSourceApp>[
        _seen('com.whatsapp', 'WhatsApp', enabledByDefault: true),
      ];
      listener.queue = <QueuedCaptureEvent>[
        const QueuedCaptureEvent(
          rowId: 'bad-1',
          json: <String, Object?>{'event': 'a shape we do not define'},
        ),
        const QueuedCaptureEvent(
          rowId: 'bad-2',
          json: <String, Object?>{
            'event': 'posted',
            'package': 'com.whatsapp',
            'template': messagingStyleTemplate,
          },
        ),
        _posted(rowId: 'good', text: 'still got through', at: t0),
      ];

      await sync.sync();

      expect(listener.ackedRows.single, <String>['bad-1', 'bad-2', 'good']);
      expect(listener.queue, isEmpty);
      // The malformed rows before it did not cost the user the message that
      // came after them.
      expect(await threadTexts(), <String>['still got through']);
    });
  });

  group('CaptureSync: passes never overlap (INB-4, INB-25)', () {
    test('a sync asked for mid-pass is remembered and runs after it', () async {
      listener.seen = <SeenSourceApp>[
        _seen('com.whatsapp', 'WhatsApp', enabledByDefault: true),
      ];
      listener.queue = <QueuedCaptureEvent>[
        _posted(rowId: 'first', text: 'are you awake', at: t0),
      ];
      listener.duringDrain = (int drain) {
        if (drain != 1) return;
        // The last nudge of a burst: a notification lands while the pass it
        // triggered is still draining, and asks for another. Dropped, it would
        // sit in the queue until the next resume, which is the delay INB-25
        // forbids for a message that arrived with the app open.
        listener.queue = <QueuedCaptureEvent>[
          _posted(
            rowId: 'second',
            text: 'the last one of the burst',
            at: t0.add(const Duration(seconds: 1)),
          ),
        ];
        unawaited(sync.sync());
      };

      await sync.sync();

      expect(listener.drains, 2);
      // Serial, not interleaved: two drains overlapping would hand the same
      // rows to the ingest twice and can move last_message_at backwards, which
      // INB-4 makes the whole list's order.
      expect(listener.calls, <String>[
        'takeSeenApps',
        'ackSeenApps',
        'setEnabledPackages',
        'drainQueue',
        'ackQueue',
        'captureFaults',
        'takeSeenApps',
        'ackSeenApps',
        'setEnabledPackages',
        'drainQueue',
        'ackQueue',
        'captureFaults',
      ]);
      expect(await threadTexts(), <String>[
        'are you awake',
        'the last one of the burst',
      ]);
    });

    test('a live event nudges a drain, and start() drains once itself '
        '(CAP-13, INB-25)', () async {
      // The app row already exists, so the first pass writes nothing and
      // `onChanged` can only fire for a message.
      await repo.upsertSeenApp(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabledIfNew: true,
        at: t0,
      );
      final Completer<void> firstDrain = Completer<void>();
      listener.duringDrain = (int drain) {
        if (drain == 1 && !firstDrain.isCompleted) firstDrain.complete();
      };
      final Completer<void> wrote = Completer<void>();
      int changed = 0;
      sync.start(
        onChanged: () {
          changed += 1;
          if (!wrote.isCompleted) wrote.complete();
        },
      );

      await firstDrain.future;
      expect(listener.drains, 1, reason: 'start() drains the queue itself');

      listener.queue = <QueuedCaptureEvent>[
        _posted(rowId: 'live', text: 'sent while you were looking', at: t0),
      ];
      listener.live.add(const <String, Object?>{'event': 'posted'});
      await wrote.future;

      // The event is a nudge to drain and nothing else: what reaches the screen
      // is the queue row, released once, not the payload of the live event —
      // which is deliberately not even a well-formed one.
      expect(await threadTexts(), <String>['sent while you were looking']);
      expect(listener.queue, isEmpty);
      expect(changed, 1, reason: 'the screen is told once, after a write');
    });

    test('a listener error does not kill the subscription for good', () async {
      await repo.upsertSeenApp(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabledIfNew: true,
        at: t0,
      );
      final Completer<void> firstDrain = Completer<void>();
      listener.duringDrain = (int drain) {
        if (drain == 1 && !firstDrain.isCompleted) firstDrain.complete();
      };
      final Completer<void> wrote = Completer<void>();
      sync.start(
        onChanged: () {
          if (!wrote.isCompleted) wrote.complete();
        },
      );
      await firstDrain.future;

      listener.live.addError(StateError('the channel broke'));
      await Future<void>.delayed(Duration.zero);

      // An unhandled channel error kills the subscription, and a dead
      // subscription looks exactly like a quiet phone (section 9).
      listener.queue = <QueuedCaptureEvent>[
        _posted(rowId: 'after', text: 'after the channel error', at: t0),
      ];
      listener.live.add(const <String, Object?>{'event': 'posted'});
      await wrote.future;

      expect(await threadTexts(), <String>['after the channel error']);
    });

    test('a pass that throws throughout leaves the app standing and the rows '
        'queued', () async {
      // Everything the listener can be asked fails. The user sees nothing new
      // and nothing is lost: the rows are still in the queue for the next
      // resume, and no unhandled async error reaches the engine.
      final _AllFailingListener broken = _AllFailingListener();
      final CaptureSync brokenSync = CaptureSync(broken, repo, health);

      await expectLater(brokenSync.sync(), completes);
      expect(await threadTexts(), isEmpty);
    });
  });

  group('CaptureHealth (CAP-12)', () {
    test('a fault the listener recorded reaches the screen', () async {
      listener.faults = const CaptureFaults(
        queueWriteFailures: 2,
        storeUnreadable: true,
      );

      await sync.sync();

      // Not a number the app invented: PERM-8's banner is what says the app
      // could not see something, and it can only say it if the pass reports it.
      expect(health.faults.queueWriteFailures, 2);
      expect(health.faults.storeUnreadable, isTrue);
      expect(health.faults.isHealthy, isFalse);
    });

    test('a fault report that fails is not what stops a pass', () async {
      listener.seen = <SeenSourceApp>[
        _seen('com.whatsapp', 'WhatsApp', enabledByDefault: true),
      ];
      listener.queue = <QueuedCaptureEvent>[
        _posted(rowId: 'r1', text: 'captured anyway', at: t0),
      ];
      final _FaultReportFails broken = _FaultReportFails(listener);

      await CaptureSync(broken, repo, health).sync();

      expect(await threadTexts(), <String>['captured anyway']);
    });
  });

  // The switch's own provider, not the inbox's: `InboxProvider.setAppEnabled`
  // was a second copy of this and is gone. What the group covers is unchanged,
  // because the rule was never about which provider held the method — INB-22
  // says the switch takes effect from the moment it moves, and the only thing
  // that can make that true is the screen that moved it telling the listener
  // so. Mirroring on the next resume is too late in the ON direction: CAP-1
  // drops what the app posts before then, and dropped there is gone, not late.
  group('AppsProvider.setEnabled pushes CAP-1 filter down (INB-22)', () {
    late Repository plain;

    setUp(() async {
      plain = Repository(db);
      await plain.upsertSeenApp(
        package: 'com.example.shopping',
        label: 'Shopping',
        enabledIfNew: false,
        at: t0,
      );
      await plain.upsertSeenApp(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabledIfNew: true,
        at: t0,
      );
    });

    test('turning a row on tells the listener at once, not at the next '
        'resume', () async {
      final DeviceServices services = noopServices();
      final AppsProvider provider = AppsProvider(plain, services);

      await provider.setEnabled('com.example.shopping', enabled: true, now: t0);

      // INB-22: the switch takes effect from the moment it moves. Waiting for
      // the next resume means CAP-1 drops what the app posts before then, and
      // dropped there is gone, not late.
      final NoopCaptureFilter filter =
          services.captureFilter as NoopCaptureFilter;
      expect(filter.pushes, 1);
      expect(filter.lastPushed, <String>[
        'com.example.shopping',
        'com.whatsapp',
      ]);
      expect(filter.lastPushedKnown, <String>[
        'com.example.shopping',
        'com.whatsapp',
      ]);
      expect(provider.error, isNull);
      // What the chooser now draws beside the row.
      expect(
        provider.apps
            .where((IncludedApp a) => a.package == 'com.example.shopping')
            .single
            .enabled,
        isTrue,
      );
    });

    test('turning a row off pushes a set without it', () async {
      final DeviceServices services = noopServices();
      final AppsProvider provider = AppsProvider(plain, services);

      await provider.setEnabled('com.whatsapp', enabled: false, now: t0);

      final NoopCaptureFilter filter =
          services.captureFilter as NoopCaptureFilter;
      expect(filter.lastPushed, isEmpty);
      // The package the user just switched off has to be in `known`, or the
      // listener is free to keep capturing from it as a pending first sighting
      // — silent capture in the OFF direction, which is the one CAP-1 and
      // product principle 4 cannot survive.
      expect(filter.lastPushedKnown, contains('com.whatsapp'));
      // Asserted on the row and not on "no row is enabled": this provider draws
      // the shipped six whether or not the database holds a row for them
      // (INB-20), and CAP-1 has the other five on by default, so an emptiness
      // check here would be a test of the seed rather than of the switch.
      expect(
        provider.apps
            .where((IncludedApp a) => a.package == 'com.whatsapp')
            .single
            .enabled,
        isFalse,
        reason: 'the row and the filter say the same thing',
      );
    });

    test('a push the listener never heard is surfaced, not swallowed', () async {
      final DeviceServices services = DeviceServices(
        notifications: const NoopNotificationSource(),
        captureFilter: _UnreachableCaptureFilter(),
        packages: const NoopPackageInfoService(),
        reply: const NoopReplyService(),
        launcher: const NoopAppLauncher(),
        reminders: const NoopReminderScheduler(),
        entitlements: const NoopEntitlements(),
        appLock: const NoopAppLock(),
      );
      final AppsProvider provider = AppsProvider(plain, services);

      await provider.setEnabled('com.example.shopping', enabled: true, now: t0);

      // The switch on screen would otherwise be telling the user something the
      // phone is not doing — silent loss in the ON direction (INB-22).
      expect(provider.error, isNotNull);
      // Read through `error` above and named here: this is the one failure a
      // later successful read must not clear, because a capture signal fires
      // within the second of any app posting anything.
      expect(provider.captureFilterFailure, isNotNull);
      // The database keeps the write: it is the authority, and the next launch
      // re-mirrors from it.
      expect(
        provider.apps
            .where((IncludedApp a) => a.package == 'com.example.shopping')
            .single
            .enabled,
        isTrue,
      );
    });
  });
}

/// A listener that fails whatever it is asked. Nothing in a pass may escape as
/// an unhandled async error and take the app down with it.
class _AllFailingListener extends AndroidNotificationSource {
  _AllFailingListener();

  @override
  Future<List<SeenSourceApp>> takeSeenApps() async =>
      throw StateError('the channel is gone');

  @override
  Future<List<QueuedCaptureEvent>> drainQueue() async =>
      throw StateError('the channel is gone');

  @override
  Future<CaptureFaults> captureFaults() async =>
      throw StateError('the channel is gone');

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();
}

/// Everything works except the fault report, which is asked for last and on
/// purpose: a fact about a pass that already happened must never be what stops
/// one (CAP-12).
class _FaultReportFails extends AndroidNotificationSource {
  _FaultReportFails(this._delegate);

  final _FakeListener _delegate;

  @override
  Future<List<SeenSourceApp>> takeSeenApps() => _delegate.takeSeenApps();

  @override
  Future<void> ackSeenApps(List<String> packages) =>
      _delegate.ackSeenApps(packages);

  @override
  Future<void> setEnabledPackages(List<String> packages, List<String> known) =>
      _delegate.setEnabledPackages(packages, known);

  @override
  Future<List<QueuedCaptureEvent>> drainQueue() => _delegate.drainQueue();

  @override
  Future<void> ackQueue(List<String> rowIds) => _delegate.ackQueue(rowIds);

  @override
  Future<CaptureFaults> captureFaults() async =>
      throw StateError('the listener cannot answer');

  @override
  Stream<Map<String, Object?>> events() => _delegate.events();
}
