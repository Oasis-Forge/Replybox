/// The spike's own captures, replayed through the ingest engine.
///
/// The dumps in `docs/research/spike-dumps/` are the fixtures themselves, not a
/// transcription of them: the contract's field names are the dump's field
/// names, so a test here fails the day the engine stops reading what a real
/// phone really wrote. Every rule these lines exercise is provisional on this
/// evidence (CAP-25), which is exactly why the evidence is the test.
///
/// Assertions are what a user would see on the screen — the words in a
/// message, the name on a thread — never that a row exists.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/capture/capture_event.dart';
import 'package:replybox/capture/ingest.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:sqflite/sqflite.dart';

import 'helpers.dart';

/// The shell posts the fixtures; it is not a messaging app, so CAP-1 keeps it
/// out until a row says otherwise.
const String shellPackage = 'com.android.shell';

/// Shipped, so CAP-1 has it on from its first notification.
const String messagesPackage = 'com.google.android.apps.messaging';

/// The string Android puts in a redacted notification. Never stored, and
/// written here only so a test can prove it is nowhere (CAP-8).
const String redactionMarker = 'Sensitive notification content hidden';

/// One dump's lines, exactly as the phone wrote them.
List<String> lines(String name) {
  final List<String> all = File(
    'docs/research/spike-dumps/$name',
  ).readAsLinesSync().where((String line) => line.trim().isNotEmpty).toList();
  expect(all, isNotEmpty, reason: '$name must still hold its capture');
  return all;
}

/// One dump, decoded in file order.
List<CaptureEvent> dump(String name) {
  return lines(name).map((String line) {
    final CaptureEvent? event = CaptureEvent.decode(line);
    expect(event, isNotNull, reason: 'every line of $name must decode');
    return event!;
  }).toList();
}

/// Every value in the messages table as one string.
///
/// CAP-8's real assertion: a column-by-column check passes the day someone
/// adds a column, and the marker leaking into `text_normalised` would be just
/// as visible to a search as leaking into `text`.
Future<String> messagesDump(DBHelper db) async {
  final Database database = await db.database;
  final List<Map<String, Object?>> rows = await database.query('messages');
  return rows
      .map(
        (Map<String, Object?> row) => row.entries
            .map((MapEntry<String, Object?> e) => '${e.key}=${e.value}')
            .join('|'),
      )
      .join('\n');
}

void main() {
  setUpAll(initTestDatabases);

  late Repository repo;
  late DBHelper db;
  late CaptureIngest ingest;

  setUp(() async {
    final ({Repository repository, DBHelper db}) t = await testRepository();
    repo = t.repository;
    db = t.db;
    ingest = CaptureIngest(repo, clock: () => t0);
    // What the user's switch does (INB-22). Without it CAP-1 drops the shell
    // fixtures before any of this is reached — which the CAP-1 tests cover.
    await repo.upsertSeenApp(
      package: shellPackage,
      label: 'Android Shell',
      enabledIfNew: true,
      at: t0,
    );
  });

  tearDown(() => db.close());

  Future<Conversation> threadNamed(String title) async {
    final List<Conversation> all = await repo.conversations();
    return all.firstWhere(
      (Conversation c) => c.title == title,
      orElse: () => throw StateError(
        'no thread named "$title"; the inbox holds '
        '${all.map((Conversation c) => c.title).toList()}',
      ),
    );
  }

  group('shell-burst.jsonl', () {
    test('the burst is five messages, not the one visible line', () async {
      final List<IngestOutcome> outcomes = await ingest.applyAll(
        dump('shell-burst.jsonl'),
      );

      // The shade showed only "fifth message"; the history held all five.
      final Conversation ada = await threadNamed('Ada Lovelace');
      final List<Message> thread = await repo.messages(ada.id);
      expect(thread.map((Message m) => m.text), <String>[
        'first message',
        'second message',
        'third message',
        'fourth message',
        'fifth message',
      ]);
      expect(thread.map((Message m) => m.sender).toSet(), <String>{'Ada'});
      expect(thread.map((Message m) => m.kind).toSet(), <MessageKind>{
        MessageKind.text,
      });
      // One timestamp across the whole burst — the reason CAP-5 cannot use it.
      expect(thread.map((Message m) => m.sentAt).toSet(), hasLength(1));
      expect(outcomes.first.messagesStored, 5);
    });

    test('replaying the whole file again still leaves five', () async {
      await ingest.applyAll(dump('shell-burst.jsonl'));
      final List<IngestOutcome> second = await ingest.applyAll(
        dump('shell-burst.jsonl'),
      );

      final Conversation ada = await threadNamed('Ada Lovelace');
      expect(await repo.messages(ada.id), hasLength(5));
      expect(await repo.conversations(), hasLength(4));
      expect(
        second.where((IngestOutcome o) => o.action == IngestAction.stored),
        isEmpty,
      );
    });

    test('three threads sharing one groupKey stay three threads', () async {
      await ingest.applyAll(dump('shell-burst.jsonl'));

      final List<Conversation> all = await repo.conversations();
      // Newest first (INB-4); the burst was posted first and so sits last.
      expect(all.map((Conversation c) => c.title), <String>[
        'Katherine Johnson',
        'Alan Turing',
        'Grace Hopper',
        'Ada Lovelace',
      ]);
      // The three conversations after the burst all carried
      // `g:Aggregate_AlertingSection`; keying on it would have merged them.
      expect(
        all.map((Conversation c) => c.conversationKey),
        everyElement(isNot(contains('Aggregate_AlertingSection'))),
      );
      expect(all.map((Conversation c) => c.keySource).toSet(), <KeySource>{
        KeySource.conversationTitle,
      });
      expect(
        (await repo.messages(
          (await threadNamed('Grace Hopper')).id,
        )).single.text,
        'first of three conversations',
      );
    });

    test('the group summary is not a fifth thread', () async {
      final List<IngestOutcome> outcomes = await ingest.applyAll(
        dump('shell-burst.jsonl'),
      );

      // Its own history was empty; the four children carry the content.
      expect(outcomes.last.action, IngestAction.dropped);
      expect(outcomes.last.rule, 'CAP-6');
      expect(await repo.conversations(), hasLength(4));
    });
  });

  group('messages-redaction.jsonl', () {
    test(
      'the redacted message is stored hidden and the marker is nowhere',
      () async {
        await ingest.applyAll(dump('messages-redaction.jsonl'));

        // Redaction empties the title, so the thread arrives with a good key and
        // no name at all (INB-2).
        final Conversation hiddenThread = (await repo.conversations())
            .firstWhere((Conversation c) => c.isUnnamed);
        final Message hidden = (await repo.messages(hiddenThread.id)).single;
        expect(hidden.kind, MessageKind.hidden);
        expect(hidden.text, isNull);
        expect(hidden.sender, isEmpty);
        // The one assertion that catches a regression wherever it lands: the
        // whole table, every column.
        expect(await messagesDump(db), isNot(contains(redactionMarker)));
        // And nowhere a thread name could carry it either.
        expect(
          (await repo.conversations()).map((Conversation c) => c.title),
          everyElement(isNot(contains('Sensitive'))),
        );
      },
    );

    test('the hidden message arrives at the notification post time', () async {
      await ingest.applyAll(dump('messages-redaction.jsonl'));

      final Conversation hiddenThread = (await repo.conversations()).firstWhere(
        (Conversation c) => c.isUnnamed,
      );
      final Message hidden = (await repo.messages(hiddenThread.id)).single;
      // The dump's own postTime, not the message time beside it, which moved
      // 19 seconds between two reads of this same unchanged notification.
      expect(
        hidden.sentAt,
        DateTime.fromMillisecondsSinceEpoch(1789990228530, isUtc: true),
      );
    });

    test('the message that was not redacted reads normally', () async {
      await ingest.applyAll(dump('messages-redaction.jsonl'));

      final Conversation named = await threadNamed('(555) 987-6543');
      final Message message = (await repo.messages(named.id)).single;
      expect(message.text, 'hey are we still on for tomorrow');
      expect(message.sender, '(555) 987-6543');
      expect(message.kind, MessageKind.text);
      // Google Messages supplied a shortcutId, which CAP-3 takes first.
      expect(named.keySource, KeySource.shortcutId);
      expect(named.conversationKey, '2');
    });

    test('the background-work notice is not a message', () async {
      final List<IngestOutcome> outcomes = await ingest.applyAll(
        dump('messages-redaction.jsonl'),
      );

      expect(outcomes[1].action, IngestAction.dropped);
      expect(outcomes[1].rule, 'CAP-7');
      expect(
        await messagesDump(db),
        isNot(contains('doing work in the background')),
      );
      // Its APP_CANCEL removal has nothing to mark read, and says so rather
      // than reaching for a conversation.
      expect(outcomes[2].action, IngestAction.ignored);
      expect(outcomes[2].rule, 'CAP-22');
      expect(outcomes[2].conversationId, isNull);
    });

    test('a shipped app is captured before any switch was touched', () async {
      // No `apps` row for Google Messages exists in this test; CAP-1's default
      // is what lets the first notification of a fresh install through.
      expect(await repo.appByPackage(messagesPackage), isNull);

      await ingest.applyAll(dump('messages-redaction.jsonl'));

      expect(await repo.conversations(), hasLength(2));
    });
  });

  group('messages-reply-after-dismissal.jsonl', () {
    /// Everything the removals in that file refer to, captured first.
    Future<void> captureTheThingsThatGetRemoved() async {
      await ingest.applyAll(dump('shell-burst.jsonl'));
      await ingest.applyAll(dump('messages-redaction.jsonl'));
    }

    test('clearing the shade reads nothing', () async {
      await captureTheThingsThatGetRemoved();

      await ingest.applyAll(dump('messages-reply-after-dismissal.jsonl'));

      // Nine notifications left the shade; not one of them was read.
      for (final Conversation c in await repo.conversations()) {
        expect(c.readThroughAt, isNull, reason: c.title);
        expect(await repo.unreadCount(c), greaterThan(0), reason: c.title);
      }
    });

    test('a dismissed message stays in the inbox', () async {
      await captureTheThingsThatGetRemoved();

      await ingest.applyAll(dump('messages-reply-after-dismissal.jsonl'));

      // The shade is the other app's; the inbox is ours (CAP-11).
      expect(
        (await repo.messages(
          (await threadNamed('Ada Lovelace')).id,
        )).map((Message m) => m.text),
        <String>[
          'first message',
          'second message',
          'third message',
          'fourth message',
          'fifth message',
        ],
      );
      expect(await messagesDump(db), isNot(contains(redactionMarker)));
    });

    test('the file carries exactly two removal reasons, and one of them '
        'reads', () async {
      // `LISTENER_CANCEL_ALL` here is the spike tool's own `cancelAll()` — a
      // *listener* clearing the shade through the API. It is not what the
      // shade's own Clear all produces, which the device drill measured as
      // `CANCEL_ALL` on every one of six removals (CAP-22, 21 September 2026);
      // that reason is asserted against the shipped-projection dump below.
      // Neither marks read, so the behaviour was never in question — only what
      // the rule and these tests were describing.
      final List<CaptureEvent> events = dump(
        'messages-reply-after-dismissal.jsonl',
      );
      final Set<RemovalReason> reasons = events
          .where((CaptureEvent e) => e.type == CaptureEventType.removed)
          .map((CaptureEvent e) => e.removalReason)
          .toSet();

      expect(reasons, <RemovalReason>{
        RemovalReason.appCancel,
        RemovalReason.listenerCancelAll,
      });
      expect(RemovalReason.appCancel.marksRead, isTrue);
      expect(RemovalReason.listenerCancelAll.marksRead, isFalse);
    });

    test('every removal in the file changes nothing', () async {
      await captureTheThingsThatGetRemoved();

      final List<CaptureEvent> events = dump(
        'messages-reply-after-dismissal.jsonl',
      );
      final List<IngestOutcome> outcomes = await ingest.applyAll(events);

      for (int i = 0; i < events.length; i++) {
        if (events[i].type != CaptureEventType.removed) continue;
        // The only APP_CANCEL in the file removes the background-work notice,
        // which CAP-7 never stored — so even the reason that does read has
        // nothing here to read.
        expect(outcomes[i].action, IngestAction.ignored, reason: '$i');
        expect(outcomes[i].rule, 'CAP-22', reason: '$i');
      }
    });

    test(
      'the tooling lines the dumps carry are understood and ignored',
      () async {
        await captureTheThingsThatGetRemoved();

        final List<CaptureEvent> events = dump(
          'messages-reply-after-dismissal.jsonl',
        );
        final List<IngestOutcome> outcomes = await ingest.applyAll(events);

        // `dismiss_all` and `reply_attempt` are the spike tool's own lines, not
        // contract events; guessing at one is how an app files a delivery notice
        // as a message.
        final List<IngestOutcome> unknowns = <IngestOutcome>[
          for (int i = 0; i < events.length; i++)
            if (events[i].type == CaptureEventType.unknown) outcomes[i],
        ];
        expect(unknowns, hasLength(2));
        expect(
          unknowns.map((IngestOutcome o) => o.action).toSet(),
          <IngestAction>{IngestAction.ignored},
        );
        expect(unknowns.map((IngestOutcome o) => o.rule).toSet(), <String>{
          'CAP-15',
        });
      },
    );

    test('the next message under the same key is stored, not swallowed '
        '(CAP-5)', () async {
      // The one real app the spike measured posts one notification per message
      // and reuses one key for the whole thread: the key below appears on the
      // post and again on its removal, and its history is a single entry at
      // index 0. Identity by key-plus-position therefore stored the first
      // message a contact ever sent and nothing after it — this is that thread
      // receiving its second message, built from the captured line so the key
      // is the phone's own.
      final String captured = lines('messages-reply-after-dismissal.jsonl')
          .firstWhere(
            (String line) =>
                line.contains('"event":"posted"') &&
                line.contains('incoming_message:4'),
          );
      final Map<String, Object?> first =
          jsonDecode(captured) as Map<String, Object?>;
      final Map<String, Object?> next = <String, Object?>{
        ...first,
        'postTime': 1789990299000,
        'text': 'it did, and so did this one',
        'messages': <Object?>[
          <String, Object?>{
            'sender': '(555) 444-3333',
            'text': 'it did, and so did this one',
            'time': 1789990298000,
          },
        ],
      };
      // Same key, same shortcutId, same thread — only the message is new.
      expect(next['key'], first['key']);

      await ingest.applyAll(<CaptureEvent>[
        CaptureEvent.decode(captured)!,
        CaptureEvent.decode(jsonEncode(next))!,
      ]);

      final Conversation thread = await threadNamed('(555) 444-3333');
      expect(
        (await repo.messages(thread.id)).map((Message m) => m.text),
        <String>[
          'does a held reply survive dismissal',
          'it did, and so did this one',
        ],
      );
    });

    test('and replaying that same captured line twice adds nothing', () async {
      final String captured = lines('messages-reply-after-dismissal.jsonl')
          .firstWhere(
            (String line) =>
                line.contains('"event":"posted"') &&
                line.contains('incoming_message:4'),
          );

      await ingest.applyAll(<CaptureEvent>[
        CaptureEvent.decode(captured)!,
        CaptureEvent.decode(captured)!,
      ]);

      final Conversation thread = await threadNamed('(555) 444-3333');
      expect(await repo.messages(thread.id), hasLength(1));
    });

    test('the new message in the file lands in its own thread', () async {
      await captureTheThingsThatGetRemoved();

      await ingest.applyAll(dump('messages-reply-after-dismissal.jsonl'));

      final Conversation thread = await threadNamed('(555) 444-3333');
      expect(
        (await repo.messages(thread.id)).single.text,
        'does a held reply survive dismissal',
      );
      // Dismissal never removed it, and never read it either.
      expect(thread.readThroughAt, isNull);
    });
  });

  /// The dump the **shipped** projection wrote.
  ///
  /// The three files above were written by the throwaway debug spike, so they
  /// cannot fail the day `NotificationProjection.kt` renames or drops a field —
  /// which is exactly where the user's-own-message defect hid for three rounds
  /// of fixes. This file is `files/capture-queue.jsonl` as it stood on
  /// `emulator-5554` (API 37 / Android 17) after the device drill of
  /// 21 September 2026: the exact bytes the listener handed to Dart, so a
  /// change to the Kotlin contract fails a test here.
  ///
  /// Two things a reader of this group has to know, both flagged by the drill
  /// and both recorded in the dump's README:
  ///
  ///  * **`queuedAt` is not part of the projection's contract.** It is added by
  ///    `CaptureQueue.append` when the row is written to the queue file, not by
  ///    `NotificationProjection`, so nothing below asserts on it and nothing
  ///    should. `postTime` is the notification's own instant and is the one
  ///    CAP-8 and INB-4 read.
  ///  * **The file holds no CAP-21 raw line.** `cmd notification post` has no
  ///    flag for a notification category and a shell-posted `MessagingStyle`
  ///    carries no `category` key at all, so no `msg`/`social`/`email`
  ///    notification without a message history could be built on this image.
  ///    CAP-21's path therefore has no device evidence and no fixture, and the
  ///    assertions below deliberately claim nothing about it (CAP-25).
  group('2026-09-21-shipped-projection.jsonl', () {
    const String fixture = '2026-09-21-shipped-projection.jsonl';

    /// The thread the drill drove hardest: Google Messages `shortcutId` 1,
    /// which received histories of 1, 3, 4 and 5 entries under one key.
    const String grace = '(555) 123-4567';

    /// The reply the phone's owner typed into the shade. Google Messages
    /// appended it with a null `Person`, so the projection emitted
    /// `senderAbsent: true` and no `sender` key at all — the only recorded
    /// evidence for the assumption INB-9's correction rests on.
    const String ownReply = 'my own reply line';

    test('the owner’s own reply is one outbound message, in the words they '
        'typed (INB-9)', () async {
      await ingest.applyAll(dump(fixture));

      final List<Message> thread = await repo.messages(
        (await threadNamed(grace)).id,
      );
      final List<Message> own = thread
          .where((Message m) => m.direction == Direction.outbound)
          .toList();
      expect(own, hasLength(1));
      expect(own.single.text, ownReply);
      expect(own.single.sender, isEmpty, reason: 'it carried no sender at all');
      expect(own.single.kind, MessageKind.text);
      // Their own message is not somebody waiting on them (INB-5, INB-9).
      expect(await repo.unreadCount(await threadNamed(grace)), 4);
    });

    test('the same reply posted twice with its own clock moved is one row, '
        'not two (CAP-5)', () async {
      // The defect a device found and the suite could not. Google Messages
      // posted this notification twice, 501 ms apart, and moved the history
      // entry's *own* time between the posts: same conversation, same key,
      // same position, same words, `time` 1790015627272 then 1790015627773.
      // CAP-5 matched an entry row on `sent_at`, so the second post wrote a
      // second row and the user's thread showed their reply twice.
      final List<String> raw = lines(fixture);
      // The entry, written exactly as the projection wrote it: no `sender` key
      // at all, and a `time` that differs between the two posts by 501 ms.
      expect(
        raw.where(
          (String line) =>
              line.contains('{"senderAbsent":true,"text":"$ownReply"'),
        ),
        hasLength(2),
        reason: 'the duplicate pair must still be in the fixture',
      );
      expect(raw[8], contains('"$ownReply","time":1790015627272'));
      expect(raw[11], contains('"$ownReply","time":1790015627773'));

      await ingest.applyAll(dump(fixture));

      final List<Message> thread = await repo.messages(
        (await threadNamed(grace)).id,
      );
      // Two rows carry those words, and they are two different messages: the
      // one the user wrote, and the network's echo of it, which arrived with a
      // sender and a time of its own.
      final List<Message> withThoseWords = thread
          .where((Message m) => m.text == ownReply)
          .toList();
      expect(withThoseWords, hasLength(2));
      expect(withThoseWords.map((Message m) => m.direction), <Direction>[
        Direction.outbound,
        Direction.inbound,
      ]);
      expect(withThoseWords.last.sender, grace);
    });

    test('histories of 1, 3, 4 and 5 entries land as that many messages in '
        'one thread (CAP-4, CAP-5)', () async {
      // Four posts under one notification key, each carrying a longer history
      // than the last — the real app, not a shell fixture. The thread grows
      // with the history and never resets, duplicates or collapses.
      final List<CaptureEvent> events = dump(fixture);
      final List<CaptureEvent> graceThread = events
          .where(
            (CaptureEvent e) =>
                e.type == CaptureEventType.posted &&
                e.package == messagesPackage &&
                e.shortcutId == '1',
          )
          .toList();
      expect(graceThread.map((CaptureEvent e) => e.messages.length), <int>[
        1,
        3,
        4,
        5,
      ]);

      final List<int> sizes = <int>[];
      for (final CaptureEvent event in graceThread) {
        await ingest.apply(event);
        sizes.add((await repo.messages((await threadNamed(grace)).id)).length);
      }

      expect(sizes, <int>[1, 3, 4, 5]);
      expect(
        (await repo.messages(
          (await threadNamed(grace)).id,
        )).map((Message m) => m.text),
        <String>[
          'first sms from Grace',
          'fourth line same thread',
          'fifth line same thread',
          ownReply,
          ownReply,
        ],
      );
    });

    test('the redacted one-time code is hidden, and the marker is in no '
        'column anywhere (CAP-8)', () async {
      await ingest.applyAll(dump(fixture));

      // Redaction empties the title, so this thread arrives with a good key and
      // no name at all (INB-2).
      final Conversation hiddenThread = (await repo.conversations()).firstWhere(
        (Conversation c) => c.isUnnamed,
      );
      final Message hidden = (await repo.messages(hiddenThread.id)).single;
      expect(hidden.kind, MessageKind.hidden);
      expect(hidden.text, isNull);
      expect(hidden.sender, isEmpty);
      // Four posts of that notification, one message. Its `sender` arrived
      // emptied rather than absent (`senderAbsent: false`), which is what tells
      // redaction apart from the owner's own line in this very file.
      expect(
        lines(fixture).where(
          (String line) =>
              line.contains('"event":"posted"') &&
              line.contains(redactionMarker),
        ),
        hasLength(4),
      );
      // Every value in the table, so the marker cannot hide in
      // `text_normalised` where a search would find it (CAP-19).
      expect(await messagesDump(db), isNot(contains(redactionMarker)));
      expect(
        (await repo.conversations()).map((Conversation c) => c.title),
        everyElement(isNot(contains('Sensitive'))),
      );

      // And the ordinary SMS that arrived seconds after it is intact, which is
      // the whole point of the pair being in one file.
      expect(
        (await repo.messages(
          (await threadNamed('(555) 777-9999')).id,
        )).single.text,
        'an ordinary message with no code in it',
      );
    });

    test('the shade’s Clear all arrives as CANCEL_ALL and reads nothing '
        '(CAP-22)', () async {
      final List<CaptureEvent> events = dump(fixture);
      final List<CaptureEvent> removals = events
          .where((CaptureEvent e) => e.type == CaptureEventType.removed)
          .toList();

      // Six removals, one reason. The rule used to cite LISTENER_CANCEL_ALL as
      // the shade-clear reason, which is what a *listener* calling cancelAll()
      // produces; the shade's own Clear all is CANCEL_ALL, on every one of them.
      expect(removals, hasLength(6));
      expect(
        removals.map((CaptureEvent e) => e.removalReason).toSet(),
        <RemovalReason>{RemovalReason.cancelAll},
      );
      expect(RemovalReason.cancelAll.marksRead, isFalse);

      await ingest.applyAll(events);

      // Nothing was read, and nothing left the inbox (CAP-11).
      for (final Conversation c in await repo.conversations()) {
        expect(c.readThroughAt, isNull, reason: c.title);
      }
      expect(
        (await repo.messages((await threadNamed(grace)).id)),
        hasLength(5),
      );
    });

    test('eight binds in one sitting are one open session (CAP-12)', () async {
      // The drill revoked and granted access, ran `am start -S`, force-stopped
      // and rebooted; `onListenerDisconnected` never fired once, so every bind
      // used to insert another row and the table ended with thirty open
      // sessions. One window is one row.
      final List<CaptureEvent> events = dump(fixture);
      expect(
        events
            .where(
              (CaptureEvent e) => e.type == CaptureEventType.listenerConnected,
            )
            .length,
        8,
      );
      expect(
        events.where(
          (CaptureEvent e) => e.type == CaptureEventType.listenerDisconnected,
        ),
        isEmpty,
        reason: 'a revoke delivers no disconnect at API 37',
      );

      await ingest.applyAll(events);

      final List<Map<String, Object?>> sessions = await (await db.database)
          .query('capture_sessions');
      expect(sessions, hasLength(1));
      expect(sessions.single['ended_at'], isNull);
    });

    test(
      'the whole file replayed twice adds nothing (CAP-5, CAP-13)',
      () async {
        await ingest.applyAll(dump(fixture));
        final List<Conversation> first = await repo.conversations();
        final List<IngestOutcome> second = await ingest.applyAll(dump(fixture));

        expect(await repo.conversations(), hasLength(first.length));
        expect(
          second.where((IngestOutcome o) => o.action == IngestAction.stored),
          isEmpty,
        );
        expect(
          (await repo.messages((await threadNamed(grace)).id)),
          hasLength(5),
        );
      },
    );

    test('every thread the drill drove is its own, with its own words', () async {
      await ingest.applyAll(dump(fixture));

      // Seven threads: five from Google Messages, two the drill posted from the
      // shell by hand. Every Messages notification carried the same `groupKey`,
      // so keying on it would have merged all five (CAP-3).
      final List<Conversation> all = await repo.conversations();
      expect(all, hasLength(7));
      expect(
        (await repo.messages(
          (await threadNamed('(555) 999-0001')).id,
        )).single.text,
        'second message, app dead',
      );
      expect(
        (await repo.messages(
          (await threadNamed('(555) 999-0002')).id,
        )).single.text,
        'third message, app dead',
      );
      // The shell's own two-line history: both lines kept, both with their
      // sender, and neither read as the owner's — the shell named nobody `You`.
      expect(
        (await repo.messages(
          (await threadNamed('Self Test')).id,
        )).map((Message m) => (m.sender, m.text)),
        <(String, String?)>[
          ('Bob', 'a line Bob wrote'),
          ('Them', 'a line the user wrote'),
        ],
      );
    });
  });

  /// The evening drill, and the two shapes that broke the field-matching.
  ///
  /// `2026-09-21-shipped-projection-evening.jsonl` is `files/capture-queue.jsonl`
  /// as it stood on `emulator-5554` (API 37 / Android 17) after the second
  /// device drill of 21 September 2026 — the same shipped projection as the
  /// group above, a few hours later. All four of the owner's replies were stored
  /// twice on that device, and the file is why: it holds both of the shapes that
  /// no tuple of fields can match, replayable off the phone.
  ///
  ///  * **The window slid and the clock moved in the same post.** Between the
  ///    post at 1790018596957 and the one at 1790018598503 the oldest entry fell
  ///    off `incoming_message:1`, so "fourth reply line" moved from history
  ///    index 6 to 5 *and* its time moved 1790018596220 → 1790018596639. A
  ///    content match misses (the time moved) and a position match misses (the
  ///    index moved).
  ///  * **The moved entry was still the newest line.** On
  ///    `incoming_message:2`, "third reply line" sits at index 1 of a two-entry
  ///    history in both posts with its time moved 1790018504757 → 1790018505307
  ///    — and the position shape was deliberately forbidden at the newest
  ///    position, so nothing matched there either. The emulator's SMS loopback
  ///    echoes every outgoing message back, which is what demotes the owner's
  ///    line out of the newest slot in the other thread; a real phone has no
  ///    echo, so this is likely the ordinary case and not the rare one.
  ///
  /// CAP-5's alignment matches on neither position nor time, so both fall out of
  /// the same rule.
  group('2026-09-21-shipped-projection-evening.jsonl', () {
    const String fixture = '2026-09-21-shipped-projection-evening.jsonl';
    const String slid = '(555) 123-4567';
    const String newest = '(555) 987-6543';

    test('both failing shapes are still in the file, in the phone’s own '
        'bytes', () async {
      // Pinned by line, because the whole value of this fixture is that it is
      // what the listener really handed over. A projection change that dropped
      // `senderAbsent`, or a re-capture that lost the moved clocks, would leave
      // the assertions below passing against a file that no longer holds the
      // defect.
      final List<String> raw = lines(fixture);
      expect(raw, hasLength(13));

      // Shape (ii): the newest line of a two-entry history, clock moved.
      expect(
        raw[6],
        contains('"text":"third reply line","time":1790018504757'),
      );
      expect(
        raw[11],
        contains('"text":"third reply line","time":1790018505307'),
      );
      // Shape (i): the window slid and the clock moved in one post.
      expect(
        raw[10],
        contains('"text":"fourth reply line","time":1790018596220'),
      );
      expect(
        raw[12],
        contains('"text":"fourth reply line","time":1790018596639'),
      );
      expect(
        raw[12],
        isNot(contains('first message from the drill')),
        reason: 'the oldest entry fell off the window in that post',
      );
      // And every one of the owner's four replies carries no sender key at all,
      // which is what INB-9 reads their direction from — while the loopback's
      // echo of the same words carries one, which is what makes the echo a
      // different message.
      for (final String reply in <String>[
        'my own reply line',
        'second reply line',
        'third reply line',
        'fourth reply line',
      ]) {
        expect(
          raw.any(
            (String line) =>
                line.contains('{"senderAbsent":true,"text":"$reply"'),
          ),
          isTrue,
          reason: reply,
        );
      }
    });

    test('the owner’s four replies are four messages, in the words they '
        'typed (CAP-5, INB-9)', () async {
      await ingest.applyAll(dump(fixture));

      final List<Message> outbound = <Message>[
        for (final Conversation c in await repo.conversations())
          ...(await repo.messages(
            c.id,
          )).where((Message m) => m.direction == Direction.outbound),
      ];
      // Four replies were typed into the shade across the two threads, and each
      // one is stored once. Every one of them was stored twice on the device.
      expect(outbound.map((Message m) => m.text), <String>[
        'my own reply line',
        'second reply line',
        'fourth reply line',
        'third reply line',
      ]);
      expect(
        outbound.map((Message m) => m.sender),
        everyElement(isEmpty),
        reason: 'the owner’s line carries no sender at all',
      );
    });

    test('the entry that slid and moved its clock at once is one message '
        '(CAP-5)', () async {
      await ingest.applyAll(dump(fixture));

      final List<Message> thread = await repo.messages(
        (await threadNamed(slid)).id,
      );
      // Eight messages: four the contact sent, one the drill sent as "fourth
      // message", and the owner's three replies — each of which the emulator's
      // SMS loopback then echoed back with a sender of its own, which is a
      // different message and is kept (INB-9).
      expect(thread.map((Message m) => m.text), <String>[
        'first message from the drill',
        'my own reply line',
        'my own reply line',
        'second reply line',
        'second reply line',
        'fourth message from the drill',
        'fourth reply line',
        'fourth reply line',
      ]);
      expect(thread.map((Message m) => m.direction), <Direction>[
        Direction.inbound,
        Direction.outbound,
        Direction.inbound,
        Direction.outbound,
        Direction.inbound,
        Direction.inbound,
        Direction.outbound,
        Direction.inbound,
      ]);
      // The owner's own line is the one with no sender; its echo carries one.
      expect(
        thread
            .where((Message m) => m.text == 'fourth reply line')
            .map((Message m) => m.sender),
        <String>['', slid],
      );
    });

    test('the entry that moved its clock at the newest position is one '
        'message (CAP-5)', () async {
      await ingest.applyAll(dump(fixture));

      final List<Message> thread = await repo.messages(
        (await threadNamed(newest)).id,
      );
      // Two posts of this notification, both carrying the same two entries, and
      // the owner's reply moved its own clock between them. Nothing was echoed
      // here, so the reply stayed the newest line — where the old rule was
      // forbidden to look — and it was stored twice on the device.
      expect(
        thread.map((Message m) => (m.text, m.direction)),
        <(String?, Direction)>[
          ('third message from the drill', Direction.inbound),
          ('third reply line', Direction.outbound),
        ],
      );
    });

    test(
      'replaying the whole file again adds nothing (CAP-5, CAP-13)',
      () async {
        await ingest.applyAll(dump(fixture));
        final int before = <int>[
          for (final Conversation c in await repo.conversations())
            (await repo.messages(c.id)).length,
        ].fold(0, (int a, int b) => a + b);

        final List<IngestOutcome> second = await ingest.applyAll(dump(fixture));

        expect(
          second.where((IngestOutcome o) => o.action == IngestAction.stored),
          isEmpty,
        );
        expect(
          <int>[
            for (final Conversation c in await repo.conversations())
              (await repo.messages(c.id)).length,
          ].fold(0, (int a, int b) => a + b),
          before,
        );
      },
    );

    test('five binds in one sitting are one open session (CAP-12)', () async {
      final List<CaptureEvent> events = dump(fixture);
      expect(
        events
            .where(
              (CaptureEvent e) => e.type == CaptureEventType.listenerConnected,
            )
            .length,
        5,
      );

      await ingest.applyAll(events);

      final List<Map<String, Object?>> sessions = await (await db.database)
          .query('capture_sessions');
      expect(sessions, hasLength(1));
      expect(sessions.single['ended_at'], isNull);
    });
  });
}
