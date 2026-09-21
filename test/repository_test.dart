import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:replybox/models/source_app.dart';
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

      expect(await repo.insertMessageIfNew(m), isTrue);
      // A different row id, same content: this is what a reconnection re-read
      // hands us, and it must not become a second message.
      expect(
        await repo.insertMessageIfNew(aMessage(conversationId: c.id)),
        isFalse,
      );

      expect((await repo.messages(c.id)).length, 1);
    });

    test('a message the user deleted is never captured again', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(aMessage(conversationId: c.id));
      await repo.deleteConversation(c.id, t0.add(const Duration(minutes: 1)));

      // The dedup lookup sees soft-deleted rows on purpose (CAP-5): a re-post
      // after a delete must not resurrect it.
      final bool wrote = await repo.insertMessageIfNew(
        aMessage(conversationId: c.id),
      );

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
      },
    );

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
        expect(sessions.single['ended_at'], isNotNull);
      },
    );
  });

  group('CAP-12 gaps', () {
    test('installed_at is written once and never moves', () async {
      final DateTime first = await repo.installedAt(t0);
      final DateTime again = await repo.installedAt(
        t0.add(const Duration(days: 3)),
      );

      expect(first, t0);
      expect(again, t0);
    });
  });
}
