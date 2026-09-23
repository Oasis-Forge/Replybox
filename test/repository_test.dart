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
      // Ties are real — the spike's fixture delivered five messages under one
      // identical time — so the order has to be total. Every seeded value is
      // equal on purpose: `aConversation` puts `last_message_at` and
      // `created_at` on t0, so the only key left is `id`.
      final Conversation a = aConversation(key: 'a', title: 'A');
      final Conversation b = aConversation(key: 'b', title: 'B');
      final Conversation c = aConversation(key: 'c', title: 'C');
      await repo.insertConversation(a);
      await repo.insertConversation(b);
      await repo.insertConversation(c);

      final List<String> first = (await repo.conversations())
          .map((Conversation c) => c.id)
          .toList();
      final List<String> second = (await repo.conversations())
          .map((Conversation c) => c.id)
          .toList();

      expect(first, second);
      // And the tie-break is the stated one, not whatever SQLite happened to
      // return: `id` ascending, which no later read can compute differently.
      expect(first, <String>[a.id, b.id, c.id]..sort());
    });

    test('a newer conversation sorts above a tie, and the tie still '
        'breaks by created_at', () async {
      final DateTime later = t0.add(const Duration(minutes: 5));
      final Conversation newest = aConversation(
        key: 'newest',
        lastMessageAt: later,
      );
      // Same `last_message_at`, different `created_at`: the notification for
      // `secondSeen` reached us later, so it sits above `firstSeen`.
      final Conversation firstSeen = Conversation(
        id: 'aaaa-first',
        package: 'com.whatsapp',
        conversationKey: 'first',
        keySource: KeySource.shortcutId,
        title: 'First',
        isGroup: false,
        lastMessageAt: t0,
        createdAt: t0,
        updatedAt: t0,
      );
      final Conversation secondSeen = Conversation(
        id: 'zzzz-second',
        package: 'com.whatsapp',
        conversationKey: 'second',
        keySource: KeySource.shortcutId,
        title: 'Second',
        isGroup: false,
        lastMessageAt: t0,
        createdAt: t0.add(const Duration(minutes: 1)),
        updatedAt: t0,
      );
      await repo.insertConversation(firstSeen);
      await repo.insertConversation(secondSeen);
      await repo.insertConversation(newest);

      expect(
        (await repo.conversations()).map((Conversation c) => c.title),
        <String>['Ada Lovelace', 'Second', 'First'],
      );
    });
  });

  group('INB-7 thread order', () {
    test('two notifications sharing one sent_at still read in one order, '
        'oldest first', () async {
      // The companion to the INB-4 test above: one `sent_at` across two
      // notifications, so the order falls through to the arrival order of the
      // notification, then the position inside it.
      final Conversation c = aConversation();
      await repo.insertConversation(c);

      // The older notification, two entries on one instant.
      await repo.insertMessagesIfNew(<Message>[
        aMessage(
          conversationId: c.id,
          text: 'first',
          notificationKey: 'notif-a',
          historyIndex: 0,
        ),
        aMessage(
          conversationId: c.id,
          text: 'second',
          notificationKey: 'notif-a',
          historyIndex: 1,
        ),
      ]);
      // A second notification, same instant, captured afterwards.
      final DateTime captured = t0.add(const Duration(seconds: 30));
      await repo.insertMessagesIfNew(<Message>[
        Message(
          id: newId(),
          conversationId: c.id,
          sender: 'Ada',
          sentAt: t0,
          kind: MessageKind.text,
          direction: Direction.inbound,
          sendState: SendState.sent,
          notificationKey: 'notif-b',
          historyIndex: 0,
          text: 'third',
          createdAt: captured,
          updatedAt: captured,
        ),
      ]);

      final List<String?> order = (await repo.messages(
        c.id,
      )).map((Message m) => m.text).toList();
      expect(order, <String>['first', 'second', 'third']);
      // And the newest read is the other end of that same order, so the
      // preview and the bottom of the thread can never disagree.
      expect((await repo.newestMessage(c.id))!.text, 'third');
    });

    test('deleting the newest message moves the preview back one', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessagesIfNew(<Message>[
        aMessage(conversationId: c.id, text: 'kept', historyIndex: 0),
        aMessage(conversationId: c.id, text: 'gone', historyIndex: 1),
      ]);

      await db.database.then(
        (Database d) => d.update(
          'messages',
          <String, Object?>{'deleted_at': timeToDb(t0)},
          where: 'text = ?',
          whereArgs: <Object?>['gone'],
        ),
      );

      expect((await repo.newestMessage(c.id))!.text, 'kept');
    });

    test('a list reads one newest message per conversation', () async {
      final Conversation ada = aConversation(key: 'ada', title: 'Ada');
      final Conversation grace = aConversation(
        key: 'grace',
        title: 'Grace',
        lastMessageAt: t0.add(const Duration(minutes: 2)),
      );
      await repo.insertConversation(ada);
      await repo.insertConversation(grace);
      await repo.insertMessageIfNew(
        aMessage(conversationId: ada.id, text: 'from ada'),
      );
      await repo.insertMessageIfNew(
        aMessage(
          conversationId: grace.id,
          sender: 'Grace',
          text: 'from grace',
          notificationKey: 'notif-2',
          sentAt: t0.add(const Duration(minutes: 2)),
        ),
      );

      final Map<String, Message> newest = await repo.newestMessages(
        await repo.conversations(),
      );
      expect(newest[ada.id]!.text, 'from ada');
      expect(newest[grace.id]!.text, 'from grace');
    });

    test('a conversation whose last_message_at is past every message it '
        'holds still has a preview', () async {
      // `last_message_at` only moves forward, so deleting the newest message
      // leaves it pointing past everything the thread still holds. A row with
      // no preview at all is what a user reads as lost data.
      final Conversation c = aConversation(
        lastMessageAt: t0.add(const Duration(hours: 1)),
      );
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(
        aMessage(conversationId: c.id, text: 'still here'),
      );

      final Map<String, Message> newest = await repo.newestMessages(
        <Conversation>[c],
      );
      expect(newest[c.id]!.text, 'still here');
    });

    test('a limited read is the newest end of the same order, even where the '
        'window falls on a tie', () async {
      // What the thread's bounded read rests on: `limit` keeps the newest
      // [limit] and drops what is older, still oldest-first, so the window is
      // a suffix of INB-7's order and never an independently chosen set. The
      // tie is the case that matters — the spike's burst put five messages on
      // one instant, so the window's edge can fall inside one.
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessagesIfNew(<Message>[
        aMessage(conversationId: c.id, text: 'oldest', historyIndex: 0),
        aMessage(conversationId: c.id, text: 'tied with it', historyIndex: 1),
        aMessage(
          conversationId: c.id,
          text: 'newest',
          historyIndex: 2,
          sentAt: t0.add(const Duration(minutes: 1)),
        ),
      ]);

      expect(
        (await repo.messages(c.id, limit: 2)).map((Message m) => m.text),
        <String>['tied with it', 'newest'],
      );
      expect(
        (await repo.messages(c.id, limit: 9)).map((Message m) => m.text),
        <String>['oldest', 'tied with it', 'newest'],
        reason: 'a limit past the end changes nothing',
      );
      // And the thread's real beginning is still readable, which is what lets
      // INB-10's notice name a date the window does not reach.
      expect(await repo.oldestMessageAt(c.id), t0);
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

    test('a hidden message is counted by postTime, and two reads agree '
        '(CAP-8)', () async {
      final Conversation c = aConversation(readThroughAt: t0);
      await repo.insertConversation(c);

      // A hidden message carries no text and no time of its own: its arrival
      // time is the notification's `postTime`, which is the same value INB-4
      // sorts on, so that is what the count has to compare against.
      final DateTime postTime = t0.add(const Duration(minutes: 1));
      await repo.insertMessageIfNew(
        Message(
          id: newId(),
          conversationId: c.id,
          sender: '',
          sentAt: postTime,
          kind: MessageKind.hidden,
          direction: Direction.inbound,
          sendState: SendState.sent,
          notificationKey: 'notif-hidden',
          historyIndex: 0,
          timeSource: TimeSource.post,
          createdAt: postTime,
          updatedAt: postTime,
        ),
      );

      expect(await repo.unreadCount(c), 1);
      expect(await repo.unreadCount(c), 1);
    });

    test(
      'the bulk read gives every row the same count as the single one',
      () async {
        final Conversation ada = aConversation(key: 'ada', readThroughAt: t0);
        final Conversation grace = aConversation(key: 'grace');
        final Conversation quiet = aConversation(key: 'quiet');
        for (final Conversation c in <Conversation>[ada, grace, quiet]) {
          await repo.insertConversation(c);
        }
        // One unread for Ada (newer than her marker), two for Grace (no marker
        // at all), none for the quiet thread.
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: ada.id,
            text: 'new',
            sentAt: t0.add(const Duration(minutes: 1)),
          ),
        );
        await repo.insertMessagesIfNew(<Message>[
          aMessage(
            conversationId: grace.id,
            text: 'one',
            notificationKey: 'g',
            historyIndex: 0,
          ),
          aMessage(
            conversationId: grace.id,
            text: 'two',
            notificationKey: 'g',
            historyIndex: 1,
          ),
        ]);

        final Map<String, int> counts = await repo.unreadCounts();
        expect(counts[ada.id], await repo.unreadCount(ada));
        expect(counts[ada.id], 1);
        expect(counts[grace.id], 2);
        // Absent rather than zero: callers read it with a `?? 0`.
        expect(counts.containsKey(quiet.id), isFalse);
      },
    );

    test('a deleted conversation is in no count at all', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(
        aMessage(conversationId: c.id, text: 'unread'),
      );
      expect((await repo.unreadCounts())[c.id], 1);

      await repo.deleteConversation(c.id, t0);
      expect(await repo.unreadCounts(), isEmpty);
    });
  });

  group('INB-14 and INB-21 per-package activity', () {
    test('counts the conversations the list can show, and their newest '
        'message', () async {
      final DateTime later = t0.add(const Duration(minutes: 10));
      await repo.insertConversation(aConversation(key: 'a'));
      await repo.insertConversation(
        aConversation(key: 'b', lastMessageAt: later),
      );
      await repo.insertConversation(
        aConversation(package: 'org.telegram.messenger', key: 'c'),
      );

      final Map<String, PackageActivity> activity = await repo
          .conversationActivityByPackage();
      expect(activity['com.whatsapp']!.conversations, 2);
      expect(activity['com.whatsapp']!.newestMessageAt, later);
      expect(activity['org.telegram.messenger']!.conversations, 1);
    });

    test('a conversation inside a pending Undo is out of the count', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.deleteConversation(c.id, t0);

      // Out of the count, and so out of the chip row unless something else
      // holds it open — which is the state layer's question (INB-6, INB-14).
      expect(await repo.conversationActivityByPackage(), isEmpty);
    });
  });

  group('INB-22 removing an app\'s stored messages', () {
    test('one step takes every conversation from that app, and one Undo '
        'brings them all back', () async {
      final Conversation a = aConversation(key: 'a');
      final Conversation b = aConversation(key: 'b');
      final Conversation other = aConversation(
        package: 'org.telegram.messenger',
        key: 'c',
      );
      for (final Conversation c in <Conversation>[a, b, other]) {
        await repo.insertConversation(c);
        await repo.insertMessageIfNew(
          aMessage(conversationId: c.id, text: 'in ${c.conversationKey}'),
        );
      }

      final int removed = await repo.deleteConversationsForPackage(
        'com.whatsapp',
        t0,
      );
      expect(removed, 2);
      expect(
        (await repo.conversations()).map((Conversation c) => c.conversationKey),
        <String>['c'],
        reason: 'only the app that was asked for',
      );
      expect(await repo.messages(a.id), isEmpty);

      await repo.undeleteConversationsForPackage('com.whatsapp', t0);
      expect(await repo.conversations(), hasLength(3));
      expect((await repo.messages(a.id)).single.text, 'in a');
    });

    test('Undo does not restore a message the user had deleted earlier '
        '(CAP-23)', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessagesIfNew(<Message>[
        aMessage(conversationId: c.id, text: 'kept', historyIndex: 0),
        aMessage(
          conversationId: c.id,
          text: 'deleted earlier',
          historyIndex: 1,
        ),
      ]);

      final DateTime earlier = t0.subtract(const Duration(hours: 1));
      await db.database.then(
        (Database d) => d.update(
          'messages',
          <String, Object?>{'deleted_at': timeToDb(earlier)},
          where: 'text = ?',
          whereArgs: <Object?>['deleted earlier'],
        ),
      );

      await repo.deleteConversationsForPackage('com.whatsapp', t0);
      await repo.undeleteConversationsForPackage('com.whatsapp', t0);

      expect(
        (await repo.messages(c.id)).map((Message m) => m.text),
        <String>['kept'],
        reason: 'nothing the user deleted ever returns',
      );
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

    test('the switch on a shipped app that has never posted opens its row '
        '(INB-21, INB-22)', () async {
      // A shipped app is captured from its first notification (CAP-1), so it
      // has no `apps` row until it posts — and INB-21 still draws it, with a
      // working switch. Without a row to write to, that switch moved on screen
      // and changed nothing on the phone.
      expect(await repo.appByPackage('com.whatsapp'), isNull);

      await repo.setAppEnabled(
        'com.whatsapp',
        enabled: false,
        at: t0,
        labelIfNew: 'com.whatsapp',
      );

      final SourceApp row = (await repo.appByPackage('com.whatsapp'))!;
      expect(row.enabled, isFalse);
      expect(await repo.enabledPackages(), isEmpty);
      expect(
        Repository.hasNeverPosted(row),
        isTrue,
        reason:
            'the listener has not seen it post, and the row may not '
            'claim otherwise',
      );

      // And a real sighting corrects both the label and the claim.
      await repo.upsertSeenApp(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabledIfNew: true,
        at: t0.add(const Duration(hours: 1)),
      );
      final SourceApp seen = (await repo.appByPackage('com.whatsapp'))!;
      expect(seen.label, 'WhatsApp');
      expect(Repository.hasNeverPosted(seen), isFalse);
      expect(
        seen.enabled,
        isFalse,
        reason: 'a sighting never moves a switch the user set',
      );
    });

    test('without a label to open one, a switch on an unknown package writes '
        'nothing', () async {
      await repo.setAppEnabled('com.example.unknown', enabled: true, at: t0);
      expect(await repo.appByPackage('com.example.unknown'), isNull);
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

    test('reading installed_at for a notice never writes it', () async {
      // INB-10's notice is a read on a screen. A read that wrote the date it is
      // about would move the app's own history to whenever a thread was first
      // opened.
      expect(await repo.installedAtOrNull(), isNull);
      expect(await repo.setting('installed_at'), isNull);

      await repo.installedAt(t0);
      expect(await repo.installedAtOrNull(), t0);
    });

    test('a rebind at boot is not an absence anyone noticed (INB-10)', () async {
      // Fifty-nine seconds between one session closing and the next opening:
      // CAP-12 is explicit that a window interrupted while access stayed on is
      // one window, and a notice for it would train the user to ignore the one
      // that matters.
      await repo.openCaptureSession(t0);
      await repo.closeCaptureSession(t0.add(const Duration(minutes: 10)));
      await repo.openCaptureSession(
        t0.add(const Duration(minutes: 10, seconds: 59)),
      );

      expect(
        await repo.captureGaps(now: t0.add(const Duration(hours: 1))),
        isEmpty,
      );
    });

    test('an hour with access off is a gap, newest first', () async {
      await repo.openCaptureSession(t0);
      await repo.closeCaptureSession(t0.add(const Duration(minutes: 10)));
      await repo.openCaptureSession(t0.add(const Duration(hours: 2)));
      await repo.closeCaptureSession(t0.add(const Duration(hours: 3)));
      await repo.openCaptureSession(t0.add(const Duration(hours: 5)));

      final List<CaptureGap> gaps = await repo.captureGaps(
        now: t0.add(const Duration(hours: 6)),
      );
      expect(gaps, hasLength(2));
      expect(gaps.first.from, t0.add(const Duration(hours: 3)));
      expect(gaps.first.to, t0.add(const Duration(hours: 5)));
      expect(gaps.first.scope, CaptureGapScope.device);
      expect(gaps.last.from, t0.add(const Duration(minutes: 10)));
    });

    test(
      'access that is off right now runs up to the instant asked about',
      () async {
        await repo.openCaptureSession(t0);
        await repo.closeCaptureSession(t0.add(const Duration(minutes: 10)));

        final DateTime now = t0.add(const Duration(hours: 4));
        final List<CaptureGap> gaps = await repo.captureGaps(now: now);
        expect(gaps.single.from, t0.add(const Duration(minutes: 10)));
        expect(gaps.single.to, now);
      },
    );

    test(
      "an app's own switch being off is a gap in that app and in no other",
      () async {
        await repo.openCaptureSession(t0);
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

        final DateTime now = t0.add(const Duration(hours: 4));
        final List<CaptureGap> mine = await repo.captureGaps(
          package: 'com.whatsapp',
          now: now,
        );
        expect(mine.single.scope, CaptureGapScope.app);
        expect(mine.single.from, t0.add(const Duration(hours: 1)));
        expect(mine.single.to, t0.add(const Duration(hours: 3)));

        expect(
          await repo.captureGaps(package: 'org.telegram.messenger', now: now),
          isEmpty,
          reason: "another app's switch took nothing from this one",
        );
      },
    );

    test(
      'a shipped app that was never switched has no app-level start',
      () async {
        // Only the switch moving writes an `app_capture_sessions` row, so a
        // shipped app captured by default has none — and INB-10 must not read
        // that absence as a history beginning at epoch.
        expect(
          await repo.firstCaptureSessionStart(package: 'com.whatsapp'),
          isNull,
        );
      },
    );

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
