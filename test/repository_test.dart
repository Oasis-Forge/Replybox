import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/main.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:replybox/models/record.dart';
import 'package:replybox/models/source_app.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:sqflite/sqflite.dart';

import 'helpers.dart';

/// These assert what the user ends up seeing — how many messages are in a
/// thread, whether a deleted one comes back — rather than that a method
/// returned something.
void main() {
  setUpAll(initTestDatabases);

  late Repository repo;
  late DBHelper db;

  setUp(() async {
    final ({Repository repository, DBHelper db}) t = await testRepository();
    repo = t.repository;
    db = t.db;
  });

  tearDown(() => db.close());

  group('CAP-5 dedup', () {
    test(
      'five messages sharing one timestamp are five messages, not one',
      () async {
        // The exact case the spike measured: a burst arrives with every
        // message carrying the same time, so time cannot separate them.
        final Conversation c = aConversation();
        await repo.insertConversation(c);
        for (int i = 0; i < 5; i++) {
          await repo.insertMessageIfNew(
            aMessage(
              conversationId: c.id,
              text: 'message $i',
              historyIndex: i,
              notificationKey: 'burst-key',
            ),
          );
        }

        final List<Message> stored = await repo.messages(c.id);
        expect(stored.length, 5);
        expect(stored.map((Message m) => m.text), <String>[
          'message 0',
          'message 1',
          'message 2',
          'message 3',
          'message 4',
        ]);
      },
    );

    test('the same notification re-posted adds nothing', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      final Message m = aMessage(conversationId: c.id);

      expect((await repo.insertMessageIfNew(m)).wrote, isTrue);
      // A different row id, same content: this is what a reconnection re-read
      // hands us, and it must not become a second message.
      expect(
        (await repo.insertMessageIfNew(aMessage(conversationId: c.id))).wrote,
        isFalse,
      );

      expect((await repo.messages(c.id)).length, 1);
    });

    test('the same message at a different position is still the same '
        'message', () async {
      // The sliding-window case, at the level the repository can see it: the
      // history moved the message from index 1 to index 0, under a new key,
      // and identity is content — so nothing new is written (CAP-5).
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(
        aMessage(
          conversationId: c.id,
          text: 'still me',
          historyIndex: 1,
          notificationKey: 'notif-1',
        ),
      );

      final bool wrote = (await repo.insertMessageIfNew(
        aMessage(
          conversationId: c.id,
          text: 'still me',
          historyIndex: 0,
          notificationKey: 'notif-2',
        ),
      )).wrote;

      expect(wrote, isFalse);
      expect((await repo.messages(c.id)).map((Message m) => m.text), <String>[
        'still me',
      ]);
    });

    test('two identical texts at one instant are two messages when the '
        'caller says they are', () async {
      // Only the caller applying one notification knows that a second "?" is a
      // second message rather than a re-post of the first, so it claims the row
      // each entry matched and the next entry has to find another.
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      final Set<String> matched = <String>{};

      for (int i = 0; i < 2; i++) {
        final ({bool wrote, String id}) result = await repo.insertMessageIfNew(
          aMessage(conversationId: c.id, text: '?', historyIndex: i),
          alreadyMatched: matched,
        );
        matched.add(result.id);
        expect(result.wrote, isTrue, reason: 'entry $i');
      }

      // And without that claim the second one is a duplicate, which is exactly
      // what a re-post of the same notification must be.
      expect(
        (await repo.insertMessageIfNew(
          aMessage(conversationId: c.id, text: '?', historyIndex: 0),
        )).wrote,
        isFalse,
      );

      expect((await repo.messages(c.id)).map((Message m) => m.text), <String>[
        '?',
        '?',
      ]);
    });

    test('a window that slides onto itself keeps the older line and stores '
        'the newer one', () async {
      // Stored ["A", "?"] with the "?" at index 1, and a window that slides to
      // ["?", "?"] at one instant. CAP-5 aligns the incoming history against
      // the stored one as a sequence: the stored "?" is the line the window
      // moved from index 1 to index 0, so entry 0 *is* that message and entry 1
      // is the one the user has just been sent.
      //
      // Which of the two writes is what the old field-matching got backwards —
      // it read entry 1 as the stored row because they shared a position, and
      // entry 0 as new — and the row it then wrote landed on a unique index
      // that read the collision as "already stored", so the new message was
      // lost. The user-visible answer is three messages either way; this asserts
      // the alignment reaches it by the right road, because the wrong road is
      // what the index used to reject.
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      final DateTime burst = t0.add(const Duration(minutes: 1));
      await repo.insertMessagesIfNew(<Message>[
        aMessage(conversationId: c.id, text: 'A'),
        aMessage(
          conversationId: c.id,
          text: '?',
          historyIndex: 1,
          sentAt: burst,
        ),
      ]);

      final List<({bool wrote, String id})> results = await repo
          .insertMessagesIfNew(<Message>[
            aMessage(conversationId: c.id, text: '?', sentAt: burst),
            aMessage(
              conversationId: c.id,
              text: '?',
              historyIndex: 1,
              sentAt: burst,
            ),
          ]);

      // Entry 0 is the line the window slid down, so it keeps the stored row;
      // entry 1 is the message that is new.
      expect(results.map((({bool wrote, String id}) r) => r.wrote), <bool>[
        false,
        true,
      ]);
      expect((await repo.messages(c.id)).map((Message m) => m.text), <String>[
        'A',
        '?',
        '?',
      ]);
    });

    test('a collision that gets past the matching throws rather than '
        'reporting a duplicate', () async {
      // A row that reaches `idx_messages_post_identity` is a bug in the
      // matching above it, and the old `ConflictAlgorithm.ignore` turned that
      // bug into `wrote: false` — a message the user had been sent, gone,
      // reported as "already stored". That is the one failure CAP-5's
      // correction exists to stop, so it is loud now.
      //
      // A hidden message, because that index is the only one left that can
      // reject anything: a message with no time of its own still has an
      // identity the schema can hold — its notification and its position
      // (CAP-8) — while a message that carried its own time is identified by
      // an alignment against its notification's stored history, which no index
      // can express and which deliberately allows two rows that agree on every
      // column an index could carry.
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      Message hidden() => Message(
        id: newId(),
        conversationId: c.id,
        sender: '',
        sentAt: t0,
        kind: MessageKind.hidden,
        direction: Direction.inbound,
        sendState: SendState.sent,
        notificationKey: 'notif-1',
        historyIndex: 0,
        timeSource: TimeSource.post,
        createdAt: t0,
        updatedAt: t0,
      );

      final ({bool wrote, String id}) first = await repo.insertMessageIfNew(
        hidden(),
      );

      await expectLater(
        // A caller that claims the row it should have matched, and then writes
        // the same message into the same position anyway.
        repo.insertMessageIfNew(hidden(), alreadyMatched: <String>{first.id}),
        throwsA(isA<MessageIdentityCollision>()),
      );
      expect(await repo.messages(c.id), hasLength(1));
    });

    test('a message the user deleted is never captured again', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(aMessage(conversationId: c.id));
      await repo.deleteConversation(c.id, t0.add(const Duration(minutes: 1)));

      // The dedup lookup sees soft-deleted rows on purpose (CAP-5): a re-post
      // after a delete must not resurrect it.
      final bool wrote = (await repo.insertMessageIfNew(
        aMessage(conversationId: c.id),
      )).wrote;

      expect(wrote, isFalse);
      expect(await repo.messages(c.id), isEmpty);
    });
  });

  group('CAP-8 hidden messages', () {
    test('a hidden message cannot carry text, whatever we pass', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);

      // The model drops the text for a kind that cannot carry it...
      final Message hidden = aMessage(
        conversationId: c.id,
        kind: MessageKind.hidden,
        text: 'Sensitive notification content hidden',
        sender: '',
      );
      expect(hidden.text, isNull);

      // ...and the column refuses it even if a future code path tries.
      await repo.insertMessageIfNew(hidden);
      final List<Message> stored = await repo.messages(c.id);
      expect(stored.single.kind, MessageKind.hidden);
      expect(stored.single.text, isNull);
    });

    test('the database rejects text on a hidden row directly', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      final Database raw = await db.database;

      // Bypassing the model entirely: the CHECK constraint is what makes
      // CAP-8 true rather than a convention.
      await expectLater(
        raw.insert('messages', <String, Object?>{
          ...aMessage(conversationId: c.id, kind: MessageKind.hidden).toMap(),
          'text': 'the marker text',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('DEL-1 and DEL-2 deletion', () {
    test('deleting a conversation hides it and its messages, and Undo brings '
        'both back', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(aMessage(conversationId: c.id));

      final DateTime deletedAt = t0.add(const Duration(minutes: 1));
      await repo.deleteConversation(c.id, deletedAt);

      expect(await repo.conversations(), isEmpty);
      expect(await repo.messages(c.id), isEmpty);

      await repo.undeleteConversation(c.id, deletedAt);

      expect((await repo.conversations()).length, 1);
      expect((await repo.messages(c.id)).length, 1);
    });

    test('Undo does not restore a message deleted earlier (CAP-23)', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      final Message kept = aMessage(
        conversationId: c.id,
        text: 'kept',
        historyIndex: 0,
      );
      final Message kill = aMessage(
        conversationId: c.id,
        text: 'deleted earlier',
        historyIndex: 1,
      );
      await repo.insertMessageIfNew(kept);
      await repo.insertMessageIfNew(kill);

      // The user deletes one message an hour before deleting the thread.
      final Database raw = await db.database;
      final DateTime earlier = t0.add(const Duration(minutes: 5));
      await raw.update(
        'messages',
        <String, Object?>{'deleted_at': earlier.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: <Object?>[kill.id],
      );

      final DateTime deletedAt = t0.add(const Duration(hours: 1));
      await repo.deleteConversation(c.id, deletedAt);
      await repo.undeleteConversation(c.id, deletedAt);

      final List<Message> after = await repo.messages(c.id);
      expect(after.map((Message m) => m.text), <String>['kept']);
    });
  });

  group('INB-4 ordering', () {
    test('two reads of tied conversations give the same order', () async {
      // Ties are real, so the order has to be total.
      final Conversation a = aConversation(key: 'a', title: 'A');
      final Conversation b = aConversation(key: 'b', title: 'B');
      await repo.insertConversation(a);
      await repo.insertConversation(b);

      final List<String> first = (await repo.conversations())
          .map((Conversation c) => c.id)
          .toList();
      final List<String> second = (await repo.conversations())
          .map((Conversation c) => c.id)
          .toList();

      expect(first, second);
    });
  });

  group('INB-5 unread', () {
    test('counts only inbound messages newer than the read marker', () async {
      final Conversation c = aConversation(readThroughAt: t0);
      await repo.insertConversation(c);

      await repo.insertMessageIfNew(
        aMessage(conversationId: c.id, text: 'old', historyIndex: 0),
      );
      await repo.insertMessageIfNew(
        aMessage(
          conversationId: c.id,
          text: 'new',
          historyIndex: 1,
          sentAt: t0.add(const Duration(minutes: 1)),
        ),
      );
      await repo.insertMessageIfNew(
        aMessage(
          conversationId: c.id,
          text: 'mine',
          direction: Direction.outbound,
          historyIndex: 2,
          sentAt: t0.add(const Duration(minutes: 2)),
        ),
      );

      expect(await repo.unreadCount(c), 1);
    });

    test('a message whose direction could not be decided is counted in no '
        'badge (INB-9)', () async {
      final Conversation c = aConversation(readThroughAt: t0);
      await repo.insertConversation(c);

      // Newer than the marker, and unread by every test except the one that
      // matters: the app was never told who wrote it. A badge is the app
      // saying somebody is waiting on the user, and it does not say that on a
      // direction it had to guess.
      await repo.insertMessageIfNew(
        aMessage(
          conversationId: c.id,
          text: 'on my way',
          direction: Direction.unknown,
          historyIndex: 0,
          sentAt: t0.add(const Duration(minutes: 1)),
        ),
      );

      expect(await repo.unreadCount(c), 0);
    });
  });

  group('CAP-1 and INB-20 apps', () {
    test(
      'an app the listener saw but does not capture still gets a row',
      () async {
        await repo.upsertSeenApp(
          package: 'com.example.shopping',
          label: 'Shopping',
          enabledIfNew: false,
          at: t0,
        );

        final List<SourceApp> apps = await repo.allApps();
        expect(apps.single.package, 'com.example.shopping');
        expect(apps.single.enabled, isFalse);
        // The label is the whole of what INB-21 draws for this row: the
        // chooser shows the app's icon and label, its switch, and that nothing
        // has arrived from it yet. A row with the right package and a blank
        // label is a switch the user cannot identify, which is the failure this
        // row exists to prevent — INB-20 makes this list the only place a
        // non-shipped package ever appears.
        expect(apps.single.label, 'Shopping');
        // And INB-21 orders the "off and seen posting" group by most recently
        // seen, so the sighting time is content too, not bookkeeping.
        expect(apps.single.lastSeenAt, t0);
      },
    );

    test('a re-sighting updates the label the chooser draws and never the '
        'switch (INB-21, INB-22)', () async {
      await repo.upsertSeenApp(
        package: 'com.example.shopping',
        label: 'Shopping',
        enabledIfNew: false,
        at: t0,
      );
      await repo.setAppEnabled('com.example.shopping', enabled: true, at: t0);

      // The app is renamed and posts again. `enabled` is the user's (INB-22)
      // and a re-sighting never moves it; the label is the app's, and the
      // chooser has to draw the current one.
      final DateTime later = t0.add(const Duration(days: 2));
      await repo.upsertSeenApp(
        package: 'com.example.shopping',
        label: 'Shopping Deluxe',
        enabledIfNew: false,
        at: later,
      );

      final SourceApp app = (await repo.allApps()).single;
      expect(app.label, 'Shopping Deluxe');
      expect(app.lastSeenAt, later);
      expect(
        app.enabled,
        isTrue,
        reason: 'enabledIfNew only ever touches a row that does not exist',
      );
    });

    test(
      'turning an app off records the gap rather than a single timestamp',
      () async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        await repo.setAppEnabled('com.whatsapp', enabled: true, at: t0);
        await repo.setAppEnabled(
          'com.whatsapp',
          enabled: false,
          at: t0.add(const Duration(hours: 2)),
        );

        final Database raw = await db.database;
        final List<Map<String, Object?>> sessions = await raw.query(
          'app_capture_sessions',
          where: 'package = ?',
          whereArgs: <Object?>['com.whatsapp'],
        );
        expect(sessions.length, 1);

        // The two instants *are* the content of INB-10's on-screen notice: the
        // thread says when the app could first have seen anything for it, and
        // names the most recent gap in either sessions table. A row whose ends
        // were both written as one instant satisfies "length 1, ended_at not
        // null" and puts a zero-length gap on screen — which INB-10 discards,
        // because it counts only gaps longer than 60 seconds. The user is then
        // told nothing was missed over a window in which nothing was captured.
        final DateTime started = timeFromDb(sessions.single['started_at']);
        final DateTime ended = timeFromDb(sessions.single['ended_at']);
        expect(started, t0);
        expect(ended, t0.add(const Duration(hours: 2)));
        expect(ended.difference(started), const Duration(hours: 2));
      },
    );

    test('turning it back on opens a second row, so two gaps stay two '
        '(INB-10, INB-22)', () async {
      // One row per enable and per disable: a single timestamp cannot carry
      // more than one gap, and INB-10 names the most recent gap and counts the
      // others. Reusing the row would make two absences read as one.
      await repo.upsertSeenApp(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabledIfNew: true,
        at: t0,
      );
      await repo.setAppEnabled('com.whatsapp', enabled: true, at: t0);
      await repo.setAppEnabled(
        'com.whatsapp',
        enabled: false,
        at: t0.add(const Duration(hours: 1)),
      );
      await repo.setAppEnabled(
        'com.whatsapp',
        enabled: true,
        at: t0.add(const Duration(hours: 3)),
      );

      final Database raw = await db.database;
      final List<Map<String, Object?>> sessions = await raw.query(
        'app_capture_sessions',
        where: 'package = ?',
        whereArgs: <Object?>['com.whatsapp'],
        orderBy: 'started_at ASC',
      );
      expect(sessions.length, 2);
      expect(timeFromDb(sessions.first['started_at']), t0);
      expect(
        timeFromDb(sessions.first['ended_at']),
        t0.add(const Duration(hours: 1)),
      );
      expect(
        timeFromDb(sessions.last['started_at']),
        t0.add(const Duration(hours: 3)),
      );
      expect(
        sessions.last['ended_at'],
        isNull,
        reason: 'capture from this app is on right now',
      );
    });
  });

  group('CAP-12 gaps', () {
    Future<List<Map<String, Object?>>> sessions() async => (await db.database)
        .query('capture_sessions', orderBy: 'started_at ASC');

    test('installed_at is written once and never moves', () async {
      final DateTime first = await repo.installedAt(t0);
      final DateTime again = await repo.installedAt(
        t0.add(const Duration(days: 3)),
      );

      expect(first, t0);
      expect(again, t0);
    });

    // Write-once was never the defect. Nothing called it: a device drill that
    // ran thirty listener sessions and captured eighteen messages finished with
    // the `settings` table exactly as empty as it started (21 September 2026),
    // so CAP-12 had no date to say the history began at. The caller is
    // `ReplyboxApp`'s launch, and this is the only test file that can reach it
    // without leaving the area these defects belong to.
    // Every database read below sits in [WidgetTester.runAsync]: inside
    // `testWidgets` the clock is faked, and a real SQLite call awaited outside
    // it never completes.
    testWidgets('launching the app writes it, so CAP-12 has a date to state', (
      WidgetTester tester,
    ) async {
      late final Repository repository;
      late final DBHelper database;
      await tester.runAsync(() async {
        final ({Repository repository, DBHelper db}) t = await testRepository();
        repository = t.repository;
        database = t.db;
        expect(await repository.setting('installed_at'), isNull);
      });

      await tester.pumpWidget(
        ReplyboxApp(repository: repository, services: noopServices()),
      );
      await tester.pump();

      // The launch does not block on the write, so this waits for it: `pump`
      // advances the faked clock the write's continuations are scheduled on,
      // and `runAsync` is the only place the real SQLite call can make
      // progress. Bounded, so a write that never lands fails rather than hangs.
      Future<String?> settled() async {
        String? value;
        for (int i = 0; i < 100 && value == null; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(() async {
            value = await repository.setting('installed_at');
          });
        }
        return value;
      }

      final String? written = await settled();
      expect(written, isNotNull);
      final DateTime installedAt = timeFromDb(int.parse(written!));
      expect(
        DateTime.now().toUtc().difference(installedAt).inMinutes.abs(),
        lessThan(5),
        reason: 'the first launch, not some other instant',
      );

      // A second launch is not a second install: the value the first one wrote
      // is what the app still holds afterwards.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        ReplyboxApp(repository: repository, services: noopServices()),
      );
      await tester.pump();
      await tester.runAsync(() async {
        expect(await repository.setting('installed_at'), written);
        await database.close();
      });
    });

    test('a second bind while one is open writes no second row', () async {
      expect(await repo.openCaptureSession(t0), isTrue);
      expect(
        await repo.openCaptureSession(t0.add(const Duration(hours: 1))),
        isFalse,
      );

      expect(await sessions(), hasLength(1));
      expect((await sessions()).single['started_at'], timeToDb(t0));
    });

    test('access found off at launch closes the session at the newest message '
        'it captured, never at now', () async {
      // The revoke that produced this: `onListenerDisconnected` never fires at
      // API 37, so nothing closed the row and the app would have claimed
      // capture was on right up to this launch (drill, 21 September 2026).
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.openCaptureSession(t0);
      final DateTime lastMessage = t0.add(const Duration(minutes: 20));
      await repo.insertMessageIfNew(
        aMessage(
          conversationId: c.id,
          text: 'the last thing we saw',
          sentAt: lastMessage,
        ),
      );
      final DateTime launch = t0.add(const Duration(days: 2));

      final DateTime? closedAt = await repo
          .closeOpenCaptureSessionsAtLastEvidence(launch);

      // Every instant the app now claims capture was on has a message standing
      // behind it. The two days between are not claimed, because nothing
      // happened in them that proves the listener was alive.
      expect(closedAt, lastMessage);
      expect((await sessions()).single['ended_at'], timeToDb(lastMessage));
      expect(
        (await sessions()).single['ended_at'],
        isNot(timeToDb(launch)),
        reason: 'closing at now is the bug, not the fix',
      );
    });

    test('a session that captured nothing closes where it started', () async {
      await repo.openCaptureSession(t0);

      final DateTime? closedAt = await repo
          .closeOpenCaptureSessionsAtLastEvidence(
            t0.add(const Duration(days: 1)),
          );

      // No evidence at all, so nothing is claimed: CAP-12's "off since at least
      // a stated time", with the stated time as early as the app can put it.
      expect(closedAt, t0);
      expect((await sessions()).single['ended_at'], timeToDb(t0));
    });

    test('a message the user deleted still proves the listener was alive '
        '(DEL-1)', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.openCaptureSession(t0);
      final DateTime seen = t0.add(const Duration(minutes: 5));
      await repo.insertMessageIfNew(
        aMessage(conversationId: c.id, text: 'deleted later', sentAt: seen),
      );
      await repo.deleteConversation(c.id, t0.add(const Duration(minutes: 6)));

      expect(
        await repo.closeOpenCaptureSessionsAtLastEvidence(
          t0.add(const Duration(hours: 4)),
        ),
        seen,
      );
    });

    test('a message stamped in the future cannot push the close past the '
        'launch', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.openCaptureSession(t0);
      await repo.insertMessageIfNew(
        aMessage(
          conversationId: c.id,
          text: 'a clock nobody set',
          sentAt: t0.add(const Duration(days: 400)),
        ),
      );

      final DateTime launch = t0.add(const Duration(hours: 1));
      expect(
        await repo.closeOpenCaptureSessionsAtLastEvidence(launch),
        t0,
        reason: 'the only evidence is out of range, so there is none',
      );
    });

    test('nothing open is not an invented session', () async {
      expect(await repo.closeOpenCaptureSessionsAtLastEvidence(t0), isNull);
      expect(await sessions(), isEmpty);
    });
  });
}
