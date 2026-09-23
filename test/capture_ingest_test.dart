/// The capture rules, one group per rule, over a real in-memory SQLite.
///
/// Synthetic events rather than the dumps: a rule test has to be able to build
/// the one shape that isolates it — a notification whose `shortcutId` is `""`
/// and whose `tag` is not, two hidden messages under one `postTime` — and no
/// dump holds those. `capture_fixture_test.dart` covers the real captures.
///
/// Every assertion is about what the user ends up with: the text of a message,
/// the name of a thread, whether the badge cleared. `insertMessageIfNew`
/// returning true is not evidence that anyone can read the message.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/capture/capture_event.dart';
import 'package:replybox/capture/ingest.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:sqflite/sqflite.dart';

import 'helpers.dart';

// --- event builders --------------------------------------------------------

/// One entry in a notification's message history.
CapturedMessage anEntry({
  String? sender = 'Ada',
  String? text = 'hello',
  DateTime? time,
  String? type,
}) => CapturedMessage(sender: sender, text: text, time: time ?? t0, type: type);

/// A posted MessagingStyle notification from an app that is on by default.
///
/// Defaults are the boring case, so a test overrides exactly the field it is
/// about and a reader can tell which one that is.
CaptureEvent aPost({
  String package = 'com.whatsapp',
  String? key = 'notif-1',
  String? tag,
  String? shortcutId,
  String? conversationTitle,
  String? groupKey,
  String? category,
  String? template = messagingStyleTemplate,
  String? title = 'Ada Lovelace',
  String? text,
  String? selfDisplayName = 'You',
  bool isGroupConversation = false,
  bool isGroupSummary = false,
  bool isOngoing = false,
  DateTime? postTime,
  List<CapturedMessage>? messages,
}) => CaptureEvent(
  type: CaptureEventType.posted,
  key: key,
  package: package,
  tag: tag,
  postTime: postTime ?? t0,
  isOngoing: isOngoing,
  isGroupSummary: isGroupSummary,
  isClearable: true,
  groupKey: groupKey,
  category: category,
  template: template,
  shortcutId: shortcutId,
  conversationTitle: conversationTitle,
  isGroupConversation: isGroupConversation,
  title: title,
  text: text,
  selfDisplayName: selfDisplayName,
  messages: messages ?? <CapturedMessage>[anEntry()],
);

CaptureEvent aRemoval({
  String package = 'com.whatsapp',
  String? key = 'notif-1',
  RemovalReason reason = RemovalReason.other,
}) => CaptureEvent(
  type: CaptureEventType.removed,
  key: key,
  package: package,
  postTime: t0,
  removalReason: reason,
);

/// Every value in the messages table as one string, for the CAP-8 assertion
/// that a marker is nowhere at all — a column-by-column check would pass the
/// day someone adds a column.
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
    // A fixed clock, so REC-1's capture time and CAP-5's `sent_at` can be told
    // apart by a test rather than by luck.
    ingest = CaptureIngest(repo, clock: () => t0);
  });

  tearDown(() => db.close());

  /// The row the listener writes for a package it has seen (INB-20).
  Future<void> seeApp(
    String package, {
    required bool enabled,
    String label = 'An app',
  }) => repo.upsertSeenApp(
    package: package,
    label: label,
    enabledIfNew: enabled,
    at: t0,
  );

  Future<List<Message>> threadOf(IngestOutcome outcome) =>
      repo.messages(outcome.conversationId!);

  group('CAP-1 included apps', () {
    test('a package the user switched off stores nothing', () async {
      await seeApp('com.whatsapp', enabled: false, label: 'WhatsApp');

      final IngestOutcome outcome = await ingest.apply(
        aPost(messages: <CapturedMessage>[anEntry(text: 'you never see this')]),
      );

      expect(outcome.action, IngestAction.dropped);
      expect(outcome.rule, 'CAP-1');
      expect(await repo.conversations(), isEmpty);
      // The drop has to reach the table, not only the return value: a stored
      // row from a switched-off app is the failure that costs the permission.
      expect(await messagesDump(db), isEmpty);
    });

    test('an app nobody has included stores nothing', () async {
      // No `apps` row at all, and not in the shipped list — the default for
      // every app the user has not chosen.
      final IngestOutcome outcome = await ingest.apply(
        aPost(package: 'com.example.shopping'),
      );

      expect(outcome.action, IngestAction.dropped);
      expect(outcome.rule, 'CAP-1');
      expect(await repo.conversations(), isEmpty);
    });

    test('a shipped messaging app is on before its row exists', () async {
      // The listener writes `apps` rows on the next drain, so the first
      // notification of a fresh install arrives before any row; falling back
      // to anything but the shipped list would lose it.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          package: 'com.google.android.apps.messaging',
          messages: <CapturedMessage>[anEntry(text: 'the very first one')],
        ),
      );

      expect(outcome.action, IngestAction.stored);
      expect((await threadOf(outcome)).single.text, 'the very first one');
    });

    test('switching an app off leaves what it already captured', () async {
      await seeApp('com.whatsapp', enabled: true, label: 'WhatsApp');
      final IngestOutcome first = await ingest.apply(
        aPost(messages: <CapturedMessage>[anEntry(text: 'captured while on')]),
      );

      await repo.setAppEnabled('com.whatsapp', enabled: false, at: t0);
      final IngestOutcome second = await ingest.apply(
        aPost(
          key: 'notif-2',
          messages: <CapturedMessage>[anEntry(text: 'captured while off')],
        ),
      );

      expect(second.rule, 'CAP-1');
      // Product principle 4: turning an app off is not a delete.
      expect((await threadOf(first)).map((Message m) => m.text), <String>[
        'captured while on',
      ]);
    });

    test('a notification with no package is dropped', () async {
      final IngestOutcome outcome = await ingest.apply(aPost(package: ''));

      expect(outcome.action, IngestAction.dropped);
      expect(outcome.rule, 'CAP-1');
    });
  });

  group('CAP-2 what becomes a message', () {
    test('a promotion is never guessed into a sender and a text', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          template: r'android.app.Notification$BigTextStyle',
          title: 'Half price this weekend',
          text: '50% off everything',
          messages: const <CapturedMessage>[],
        ),
      );

      expect(outcome.action, IngestAction.dropped);
      expect(outcome.rule, 'CAP-2');
      expect(await repo.conversations(), isEmpty);
      expect(await messagesDump(db), isNot(contains('50% off')));
    });

    test('a MessagingStyle notification with no history is dropped', () async {
      // Both halves of the gate: the template alone is not a message, and
      // without a category CAP-21 has nothing to keep it for either.
      final IngestOutcome outcome = await ingest.apply(
        aPost(messages: const <CapturedMessage>[]),
      );

      expect(outcome.action, IngestAction.dropped);
      expect(outcome.rule, 'CAP-2');
    });

    test('a history of entries carrying nothing is dropped', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          messages: <CapturedMessage>[
            anEntry(sender: '', text: '', time: t0),
            anEntry(sender: null, text: null, time: t0),
          ],
        ),
      );

      expect(outcome.action, IngestAction.dropped);
      expect(outcome.rule, 'CAP-2');
      expect(await repo.conversations(), isEmpty);
    });

    test('a MessagingStyle notification with a history is kept', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(messages: <CapturedMessage>[anEntry(text: 'see you at six')]),
      );

      expect(outcome.action, IngestAction.stored);
      expect(outcome.rule, 'CAP-4');
      expect((await threadOf(outcome)).single.text, 'see you at six');
    });
  });

  group('CAP-3 conversation identity', () {
    test('shortcutId wins over the other two', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(shortcutId: 'sc-7', conversationTitle: 'Ada', tag: 'tag-9'),
      );

      final Conversation c = (await repo.conversations()).single;
      expect(c.conversationKey, 'sc-7');
      expect(c.keySource, KeySource.shortcutId);
      // The losers are kept beside the winner, so an app that changes its
      // keying can be migrated instead of silently splitting every thread.
      expect(c.conversationTitle, 'Ada');
      expect(c.tag, 'tag-9');
      expect(outcome.conversationId, c.id);
    });

    test('conversationTitle wins when shortcutId is empty', () async {
      await ingest.apply(
        aPost(shortcutId: '', conversationTitle: 'Grace Hopper', tag: 'tag-9'),
      );

      final Conversation c = (await repo.conversations()).single;
      expect(c.conversationKey, 'Grace Hopper');
      expect(c.keySource, KeySource.conversationTitle);
      // `""` is what redaction leaves behind, so it must not be stored as a
      // candidate either.
      expect(c.shortcutId, isNull);
    });

    test('tag wins when both title fields are empty', () async {
      await ingest.apply(
        aPost(shortcutId: '', conversationTitle: '', tag: 'thread-42'),
      );

      final Conversation c = (await repo.conversations()).single;
      expect(c.conversationKey, 'thread-42');
      expect(c.keySource, KeySource.tag);
    });

    test('with no candidate a notification keys on itself and never '
        'merges', () async {
      await ingest.apply(
        aPost(
          key: 'notif-a',
          shortcutId: '',
          conversationTitle: '',
          tag: '',
          messages: <CapturedMessage>[anEntry(text: 'from one stranger')],
        ),
      );
      await ingest.apply(
        aPost(
          key: 'notif-b',
          shortcutId: '',
          conversationTitle: '',
          tag: '',
          messages: <CapturedMessage>[anEntry(text: 'from another')],
        ),
      );

      final List<Conversation> all = await repo.conversations();
      expect(all, hasLength(2));
      expect(all.map((Conversation c) => c.keySource), <KeySource>[
        KeySource.notificationKey,
        KeySource.notificationKey,
      ]);
    });

    test('a candidate that draws as nothing is still a key, and the thread '
        'stays one thread', () async {
      // The silent split this rule exists to forbid, arriving from our own
      // code. INB-2 widened "empty" to "nothing a reader could see" for the
      // title it draws, and the keying read the same predicate — so a thread
      // keyed on a `shortcutId` of one space stopped resolving to that key and
      // fell through to the notification key. The first notification opens the
      // thread, the second opens a second one beside it, and the user's history
      // is in the one they can no longer reach.
      //
      // Two different notification keys on purpose: with one key the rows would
      // merge whatever the resolver did, so nothing would be proved.
      await ingest.apply(
        aPost(
          key: 'notif-a',
          shortcutId: ' ',
          messages: <CapturedMessage>[anEntry(text: 'first')],
        ),
      );
      await ingest.apply(
        aPost(
          key: 'notif-b',
          shortcutId: ' ',
          postTime: t0.add(const Duration(minutes: 1)),
          messages: <CapturedMessage>[
            anEntry(text: 'second', time: t0.add(const Duration(minutes: 1))),
          ],
        ),
      );

      final List<Conversation> all = await repo.conversations();
      expect(
        all,
        hasLength(1),
        reason: 'CAP-3: a keying change is migrated, never split silently',
      );
      expect(all.single.conversationKey, ' ');
      expect(all.single.keySource, KeySource.shortcutId);
      // The candidate column says the same thing as the key beside it, so a
      // migration reading these rows cannot be told a story the key contradicts.
      expect(all.single.shortcutId, ' ');
      // And both messages are in the one thread the user can open.
      final List<Message> messages = await repo.messages(all.single.id);
      expect(messages.map((Message m) => m.text), <String>['first', 'second']);
    });

    test('a zero-width candidate keys the same way a visible one does', () async {
      // The other shape of the same value: `​` draws as nothing and is
      // perfectly good identity. INB-2 still folds it away for the title, which
      // is its own question and is asserted where INB-2 is.
      await ingest.apply(
        aPost(
          key: 'notif-a',
          conversationTitle: '​',
          shortcutId: '',
          title: '',
        ),
      );
      await ingest.apply(
        aPost(
          key: 'notif-b',
          conversationTitle: '​',
          shortcutId: '',
          title: '',
        ),
      );

      final Conversation c = (await repo.conversations()).single;
      expect(c.conversationKey, '​');
      expect(c.keySource, KeySource.conversationTitle);
      // INB-2's question, on the same notification and answered the other way:
      // there is no name to draw, so the row says the notification arrived
      // without one. Both readings are right; they are not one predicate.
      expect(c.isUnnamed, isTrue);
    });

    test(
      'two threads of one app sharing a groupKey stay two threads',
      () async {
        // The spike's own bug: one groupKey covered three separate Google
        // Messages threads, so a groupKey-keyed inbox showed one.
        const String shared = '0|com.whatsapp|g:Aggregate_AlertingSection';
        await ingest.apply(
          aPost(
            key: 'notif-a',
            groupKey: shared,
            conversationTitle: 'Grace Hopper',
            messages: <CapturedMessage>[
              anEntry(sender: 'Grace', text: 'first of two'),
            ],
          ),
        );
        await ingest.apply(
          aPost(
            key: 'notif-b',
            groupKey: shared,
            conversationTitle: 'Alan Turing',
            messages: <CapturedMessage>[
              anEntry(sender: 'Alan', text: 'second of two'),
            ],
          ),
        );

        final List<Conversation> all = await repo.conversations();
        expect(all.map((Conversation c) => c.title).toSet(), <String>{
          'Grace Hopper',
          'Alan Turing',
        });
        expect(
          all.map((Conversation c) => c.conversationKey),
          everyElement(isNot(shared)),
        );
      },
    );

    test('one thread keeps its identity across two notifications', () async {
      final IngestOutcome first = await ingest.apply(
        aPost(
          key: 'notif-a',
          shortcutId: 'sc-1',
          messages: <CapturedMessage>[anEntry(text: 'are you up')],
        ),
      );
      final IngestOutcome second = await ingest.apply(
        aPost(
          key: 'notif-b',
          shortcutId: 'sc-1',
          messages: <CapturedMessage>[
            anEntry(
              text: 'still there',
              time: t0.add(const Duration(minutes: 1)),
            ),
          ],
        ),
      );

      expect(second.conversationId, first.conversationId);
      expect((await threadOf(first)).map((Message m) => m.text), <String>[
        'are you up',
        'still there',
      ]);
    });
  });

  group('CAP-4 the whole history', () {
    test('a burst stores every message, not only the visible line', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          // What the shade shows is the newest line only.
          text: 'fifth message',
          messages: <CapturedMessage>[
            anEntry(text: 'first message'),
            anEntry(text: 'second message'),
            anEntry(text: 'third message'),
            anEntry(text: 'fourth message'),
            anEntry(text: 'fifth message'),
          ],
        ),
      );

      expect(outcome.messagesStored, 5);
      expect((await threadOf(outcome)).map((Message m) => m.text), <String>[
        'first message',
        'second message',
        'third message',
        'fourth message',
        'fifth message',
      ]);
    });

    test('a re-post of the same burst adds nothing', () async {
      final CaptureEvent event = aPost(
        messages: <CapturedMessage>[
          anEntry(text: 'first message'),
          anEntry(text: 'second message'),
        ],
      );
      final IngestOutcome first = await ingest.apply(event);
      final IngestOutcome second = await ingest.apply(event);

      expect(second.action, IngestAction.duplicate);
      expect(second.messagesStored, 0);
      expect(second.conversationId, first.conversationId);
      expect(await threadOf(first), hasLength(2));
    });

    test('an entry carrying nothing never shifts another message', () async {
      // The blank entry at index 1 holds its place, so the message after it
      // keeps the identity it arrived with.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          messages: <CapturedMessage>[
            anEntry(text: 'before the gap'),
            const CapturedMessage(),
            anEntry(text: 'after the gap'),
          ],
        ),
      );

      final List<Message> stored = await threadOf(outcome);
      expect(stored.map((Message m) => m.text), <String>[
        'before the gap',
        'after the gap',
      ]);
      expect(stored.map((Message m) => m.historyIndex), <int>[0, 2]);
    });
  });

  group('CAP-5 stored once', () {
    test('a posted notification with no key is dropped', () async {
      // Every keyless message would land on the one ('', 0) slot, so the first
      // would swallow the rest.
      final IngestOutcome outcome = await ingest.apply(aPost(key: ''));

      expect(outcome.action, IngestAction.dropped);
      expect(outcome.rule, 'CAP-5');
      expect(await repo.conversations(), isEmpty);
    });

    test('a message the user deleted is not captured again', () async {
      final IngestOutcome first = await ingest.apply(
        aPost(messages: <CapturedMessage>[anEntry(text: 'delete me')]),
      );
      final Message stored = (await threadOf(first)).single;
      final Database database = await db.database;
      await database.update(
        'messages',
        <String, Object?>{'deleted_at': t0.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: <Object?>[stored.id],
      );

      final IngestOutcome second = await ingest.apply(
        aPost(messages: <CapturedMessage>[anEntry(text: 'delete me')]),
      );

      expect(second.action, IngestAction.duplicate);
      expect(await threadOf(first), isEmpty);
    });

    test(
      'an app that reuses one key for a thread keeps every message',
      () async {
        // Google Messages — the one real app the spike measured — posts one
        // notification per message and reuses one key for the whole thread, each
        // post carrying a history of one entry at index 0. Identity by position
        // stored the first message a contact ever sent and nothing after it.
        const String reused = '0|com.whatsapp|7|null|10150';
        for (int i = 1; i <= 3; i++) {
          await ingest.apply(
            aPost(
              key: reused,
              shortcutId: 'ada',
              messages: <CapturedMessage>[
                anEntry(
                  text: 'message $i',
                  time: t0.add(Duration(minutes: i)),
                ),
              ],
            ),
          );
        }

        final Conversation ada = (await repo.conversations()).single;
        expect(
          (await repo.messages(ada.id)).map((Message m) => m.text),
          <String>['message 1', 'message 2', 'message 3'],
        );
      },
    );

    test('a key an app reuses for a different thread does not swallow '
        'it', () async {
      // An app that shows one notification at a time — fixed id, no tag —
      // reuses its key by construction, and the second conversation's message
      // used to land on the first one's slot and vanish.
      const String reused = '0|com.whatsapp|7|null|10150';
      await ingest.apply(
        aPost(
          key: reused,
          shortcutId: 'ada',
          conversationTitle: 'Ada Lovelace',
          messages: <CapturedMessage>[anEntry(sender: 'Ada', text: 'from Ada')],
        ),
      );

      final IngestOutcome second = await ingest.apply(
        aPost(
          key: reused,
          shortcutId: 'grace',
          conversationTitle: 'Grace Hopper',
          messages: <CapturedMessage>[
            anEntry(sender: 'Grace', text: 'from Grace'),
          ],
        ),
      );

      expect(second.action, IngestAction.stored);
      expect((await threadOf(second)).single.text, 'from Grace');
    });

    test('a sliding history window keeps its newest message and repeats '
        'nothing', () async {
      // The window moves a message to a new position, which is the whole
      // reason position cannot be identity.
      final List<String> window1 = <String>['m1', 'm2', 'm3', 'm4', 'm5'];
      final List<String> window2 = <String>['m2', 'm3', 'm4', 'm5', 'm6'];
      CapturedMessage sliding(String text) => anEntry(
        text: text,
        // Each message keeps the time its app gave it across both reads, which
        // is what a history window actually does.
        time: t0.add(Duration(minutes: int.parse(text.substring(1)))),
      );

      await ingest.apply(
        aPost(
          shortcutId: 'ada',
          messages: <CapturedMessage>[
            for (final String t in window1) sliding(t),
          ],
        ),
      );
      final IngestOutcome second = await ingest.apply(
        aPost(
          shortcutId: 'ada',
          messages: <CapturedMessage>[
            for (final String t in window2) sliding(t),
          ],
        ),
      );

      expect(second.messagesStored, 1);
      expect((await threadOf(second)).map((Message m) => m.text), <String>[
        ...window1,
        'm6',
      ]);
    });

    test('a sliding window at one millisecond keeps its new message', () async {
      // The window above gives every message its own minute, so `sent_at`
      // separates them and no two entries can ever want the same stored row.
      // A burst does not: the spike delivered five messages under one
      // identical timestamp, and then the only thing telling two "?" entries
      // apart is which stored row each one claims.
      //
      // Stored ["A", "?"] with the "?" at index 1; the window slides to
      // ["?", "?"]. Claiming by content first, entry 0 took the stored ?@1 —
      // the only row matching it — entry 1 found nothing left and wrote itself
      // at index 1, straight onto the identity index, and the collision came
      // back as "already stored". Two rows where CAP-5 wants three, and the
      // message the user had just been sent was gone.
      // One instant for the "?"s — the burst — and an earlier one for "A", so
      // the thread's order is the rule's and not two UUIDs'.
      final DateTime burst = t0.add(const Duration(minutes: 1));
      await ingest.apply(
        aPost(
          shortcutId: 'ada',
          messages: <CapturedMessage>[
            anEntry(sender: 'Ada', text: 'A', time: t0),
            anEntry(sender: 'Ada', text: '?', time: burst),
          ],
        ),
      );

      final IngestOutcome second = await ingest.apply(
        aPost(
          shortcutId: 'ada',
          messages: <CapturedMessage>[
            anEntry(sender: 'Ada', text: '?', time: burst),
            anEntry(sender: 'Ada', text: '?', time: burst),
          ],
        ),
      );

      expect(second.action, IngestAction.stored);
      expect(second.messagesStored, 1);
      expect((await threadOf(second)).map((Message m) => m.text), <String>[
        'A',
        '?',
        '?',
      ]);
    });

    test('two identical texts in one burst stay two messages', () async {
      // Sent twice because the first went unanswered. Across notification keys
      // these would be one message; inside one history they are two, and only
      // the engine applying the event can tell the difference.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          messages: <CapturedMessage>[
            anEntry(sender: 'Ada', text: '?'),
            anEntry(sender: 'Ada', text: '?'),
            anEntry(sender: 'Ada', text: 'you there'),
          ],
        ),
      );

      expect(outcome.messagesStored, 3);
      expect((await threadOf(outcome)).map((Message m) => m.text), <String>[
        '?',
        '?',
        'you there',
      ]);
    });

    test('a re-post of that burst still adds nothing', () async {
      final CaptureEvent event = aPost(
        messages: <CapturedMessage>[
          anEntry(sender: 'Ada', text: '?'),
          anEntry(sender: 'Ada', text: '?'),
          anEntry(sender: 'Ada', text: 'you there'),
        ],
      );
      await ingest.apply(event);
      final IngestOutcome second = await ingest.apply(event);

      expect(second.action, IngestAction.duplicate);
      expect(await threadOf(second), hasLength(3));
    });
  });

  group('CAP-6 group summaries', () {
    test(
      'a summary is never a message even when it carries a history',
      () async {
        final IngestOutcome outcome = await ingest.apply(
          aPost(
            isGroupSummary: true,
            messages: <CapturedMessage>[
              anEntry(text: 'the children have this'),
            ],
          ),
        );

        expect(outcome.action, IngestAction.dropped);
        expect(outcome.rule, 'CAP-6');
        expect(await repo.conversations(), isEmpty);
        expect(await messagesDump(db), isEmpty);
      },
    );
  });

  group('CAP-7 ongoing notifications', () {
    test('a status is never a message', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          isOngoing: true,
          messages: <CapturedMessage>[
            anEntry(text: 'doing work in the background'),
          ],
        ),
      );

      expect(outcome.action, IngestAction.dropped);
      expect(outcome.rule, 'CAP-7');
      expect(await messagesDump(db), isEmpty);
    });

    test(
      'an ongoing notification is dropped before the summary check',
      () async {
        // Order matters only in that both must drop; neither may fall through to
        // storage because the other rule matched first.
        final IngestOutcome outcome = await ingest.apply(
          aPost(isOngoing: true, isGroupSummary: true),
        );

        expect(outcome.action, IngestAction.dropped);
        expect(await repo.conversations(), isEmpty);
      },
    );
  });

  group('CAP-8 hidden messages', () {
    /// A redacted notification as Android builds one: every name emptied, the
    /// system's own marker in the text.
    CaptureEvent redacted({
      String key = 'notif-1',
      String marker = 'Sensitive notification content hidden',
      DateTime? postTime,
      DateTime? entryTime,
      int entries = 1,
    }) => aPost(
      key: key,
      shortcutId: 'sc-1',
      title: '',
      text: marker,
      selfDisplayName: '',
      postTime: postTime ?? t0,
      messages: List<CapturedMessage>.generate(
        entries,
        (int _) =>
            CapturedMessage(sender: '', text: marker, time: entryTime ?? t0),
      ),
    );

    test(
      'it is stored as hidden with no text and the marker is nowhere',
      () async {
        const String marker = 'Sensitive notification content hidden';
        final IngestOutcome outcome = await ingest.apply(redacted());

        final Message stored = (await threadOf(outcome)).single;
        expect(stored.kind, MessageKind.hidden);
        expect(stored.text, isNull);
        expect(stored.sender, isEmpty);
        expect(await messagesDump(db), isNot(contains(marker)));
      },
    );

    test('detection is structural, not a match on the marker text', () async {
      // The same notification on a phone set to Spanish. Matching the string
      // would file this as a message whose text is a system string.
      const String spanish = 'Contenido de notificación sensible oculto';
      final IngestOutcome outcome = await ingest.apply(
        redacted(marker: spanish),
      );

      expect((await threadOf(outcome)).single.kind, MessageKind.hidden);
      expect(await messagesDump(db), isNot(contains('oculto')));
    });

    test('a named notification is not hidden however short its text', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          title: 'Ada Lovelace',
          messages: <CapturedMessage>[anEntry(sender: 'Ada', text: 'ok')],
        ),
      );

      final Message stored = (await threadOf(outcome)).single;
      expect(stored.kind, MessageKind.text);
      expect(stored.text, 'ok');
    });

    test(
      'its arrival time is the post time, not its own drifting one',
      () async {
        // The observed drift: one unchanged notification reported a message time
        // 19 seconds later on the second read, which would re-sort the thread.
        final DateTime posted = t0;
        final IngestOutcome outcome = await ingest.apply(
          redacted(
            postTime: posted,
            entryTime: posted.add(const Duration(seconds: 19)),
          ),
        );

        expect((await threadOf(outcome)).single.sentAt, posted);
      },
    );

    test('two hidden messages under one postTime stay two messages', () async {
      // Nothing about a hidden message differs between the two — no sender, no
      // text, one time — so anything matching on content collapses them and
      // the user loses a message they were never shown and cannot recover.
      final IngestOutcome outcome = await ingest.apply(redacted(entries: 2));

      final List<Message> stored = await threadOf(outcome);
      expect(stored, hasLength(2));
      expect(stored.map((Message m) => m.historyIndex), <int>[0, 1]);
      expect(outcome.messagesStored, 2);
    });

    test('a hidden notification leaves a named thread its name', () async {
      await ingest.apply(
        aPost(
          key: 'notif-a',
          shortcutId: 'sc-1',
          conversationTitle: 'Ada Lovelace',
          isGroupConversation: true,
          messages: <CapturedMessage>[anEntry(text: 'before the lock')],
        ),
      );
      await ingest.apply(redacted(key: 'notif-b'));

      final Conversation c = (await repo.conversations()).single;
      expect(c.title, 'Ada Lovelace');
      // Redaction reports every thread as one-to-one; flipping the flag would
      // drop the sender prefix from the whole thread's previews.
      expect(c.isGroup, isTrue);
    });

    test('a redaction with no message history is hidden, not raw text', () async {
      // Android redacts whatever the template, so a redacted notification that
      // is not MessagingStyle falls to CAP-21's path. Storing its marker as raw
      // text would make the system's string searchable and draw it as though a
      // person had sent it — and the privacy policy says it is not stored.
      const String marker = 'Sensitive notification content hidden';
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          template: r'android.app.Notification$BigTextStyle',
          category: 'msg',
          title: '',
          text: marker,
          selfDisplayName: '',
          messages: const <CapturedMessage>[],
        ),
      );

      final Message stored = (await threadOf(outcome)).single;
      expect(stored.kind, MessageKind.hidden);
      expect(stored.text, isNull);
      expect(stored.sender, isEmpty);
      // Every column, because `text_normalised` is just as searchable as
      // `text`.
      expect(await messagesDump(db), isNot(contains(marker)));
      expect(await messagesDump(db), isNot(contains('Sensitive')));
    });

    test('a notification that simply has no title is still kept as raw '
        '(CAP-21)', () async {
      // The evidence is the title Android *emptied*, not a title an app never
      // set: `org.json` drops a null key, so absent and `""` are different
      // values, and treating absent as redaction would throw away exactly the
      // content CAP-21 exists to keep.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          template: r'android.app.Notification$BigTextStyle',
          category: 'msg',
          title: null,
          text: 'you have 3 new messages',
          selfDisplayName: null,
          messages: const <CapturedMessage>[],
        ),
      );

      final Message stored = (await threadOf(outcome)).single;
      expect(stored.kind, MessageKind.raw);
      expect(stored.text, 'you have 3 new messages');
    });

    test('redaction empties the sender, so an entry that carries none at all '
        'is not hidden', () async {
      // The discriminator, and the whole of it. Android's redaction *empties*
      // the values it is handed — the spike's dump carries `"sender": ""` —
      // while `MessagingStyle` marks the phone owner's own line by building it
      // with a null Person, so its sender key is never written. `org.json`
      // drops a null key, so the two arrive as different values.
      //
      // Read as "empty or absent", this predicate fired on a line the user
      // wrote whenever the notification also carried no title (INB-2 says it
      // can) and named no user: the text was dropped for good and the user was
      // shown their own message as something their phone had hidden.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          title: '',
          selfDisplayName: null,
          text: 'on my way',
          messages: <CapturedMessage>[
            CapturedMessage(sender: null, text: 'on my way', time: t0),
          ],
        ),
      );

      final Message stored = (await threadOf(outcome)).single;
      expect(stored.kind, MessageKind.text);
      expect(stored.text, 'on my way');
    });

    test(
      'an emptied sender on the same notification is still hidden',
      () async {
        // The other side of the same discriminator, so the fix above cannot be
        // "stop detecting redaction".
        const String marker = 'Sensitive notification content hidden';
        final IngestOutcome outcome = await ingest.apply(
          aPost(
            title: '',
            selfDisplayName: '',
            text: marker,
            messages: <CapturedMessage>[
              CapturedMessage(sender: '', text: marker, time: t0),
            ],
          ),
        );

        final Message stored = (await threadOf(outcome)).single;
        expect(stored.kind, MessageKind.hidden);
        expect(stored.text, isNull);
        expect(await messagesDump(db), isNot(contains(marker)));
      },
    );

    test('a title of one space is a title, so the message keeps its '
        'words', () async {
      // The two questions this notification is asked at once, and the reason
      // one predicate cannot answer both. INB-2: "is there a name to draw?" —
      // no, a space draws as a blank row, so the thread is unnamed. CAP-8:
      // "did Android empty this?" — no, redaction writes `""` and this title
      // arrived with something in it. Answered with INB-2's predicate, the
      // notification read as redacted: the words below were stored as null and
      // the user was told their phone had hidden a message it never touched.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          title: ' ',
          selfDisplayName: null,
          text: 'on my way',
          messages: <CapturedMessage>[
            CapturedMessage(sender: '', text: 'on my way', time: t0),
          ],
        ),
      );

      final Message stored = (await threadOf(outcome)).single;
      expect(stored.kind, MessageKind.text);
      expect(stored.text, 'on my way');
      // And INB-2 still gets its own answer from the same notification: there
      // was no name to draw, so the row says the notification arrived without
      // one.
      expect((await repo.conversations()).single.isUnnamed, isTrue);
    });

    test(
      'a title of one space is not redaction on the raw path either',
      () async {
        // The other half of CAP-8, on the same shape, so the two halves cannot
        // drift apart again: here the title is the whole of the evidence, and a
        // space is a value an app sent rather than a field Android emptied.
        final IngestOutcome outcome = await ingest.apply(
          aPost(
            template: r'android.app.Notification$BigTextStyle',
            category: 'msg',
            title: ' ',
            text: 'you have 3 new messages',
            selfDisplayName: null,
            messages: const <CapturedMessage>[],
          ),
        );

        final Message stored = (await threadOf(outcome)).single;
        expect(stored.kind, MessageKind.raw);
        expect(stored.text, 'you have 3 new messages');
      },
    );
  });

  group('INB-9 direction', () {
    test('a line the user wrote arrives with no sender and is stored '
        'outbound', () async {
      // `Notification.MessagingStyle.Message(text, time, null)` is the
      // platform's own way of saying "the current user wrote this", and
      // `toBundle()` writes neither sender key for it. Compared against
      // `selfDisplayName`, an absent sender equals nothing, so the outbound
      // branch was unreachable for exactly the messages it existed to catch.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          selfDisplayName: 'You',
          messages: <CapturedMessage>[
            anEntry(sender: 'Ada', text: 'are we still on'),
            CapturedMessage(sender: null, text: 'yes, 6pm', time: t0),
          ],
        ),
      );

      final List<Message> thread = await threadOf(outcome);
      expect(thread.map((Message m) => m.text), <String>[
        'are we still on',
        'yes, 6pm',
      ]);
      expect(thread.map((Message m) => m.direction), <Direction>[
        Direction.inbound,
        Direction.outbound,
      ]);
    });

    test(
      "the user's own message is in nobody's unread badge (INB-5)",
      () async {
        final IngestOutcome outcome = await ingest.apply(
          aPost(
            selfDisplayName: 'You',
            messages: <CapturedMessage>[
              CapturedMessage(sender: null, text: 'on my way', time: t0),
            ],
          ),
        );

        final Conversation c = (await repo.conversations()).single;
        expect(await repo.unreadCount(c), 0);
        expect((await threadOf(outcome)).single.direction, Direction.outbound);
      },
    );

    test('an app that names nobody leaves the direction undecided rather than '
        'guessing', () async {
      // No sender key and no `selfDisplayName`: the platform's convention
      // cannot be read into a notification that never used the other half of
      // it. INB-9 draws this with no side and no sender.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          selfDisplayName: null,
          messages: <CapturedMessage>[
            CapturedMessage(sender: null, text: 'who wrote this', time: t0),
          ],
        ),
      );

      final Message stored = (await threadOf(outcome)).single;
      expect(stored.direction, Direction.unknown);
      expect(stored.text, 'who wrote this');
      final Conversation c = (await repo.conversations()).single;
      expect(await repo.unreadCount(c), 0);
    });

    test('a sender the notification emptied decides nothing either', () async {
      // Redaction on a notification that still has a title, so CAP-8's test
      // does not fire: there is a sender, it has no name, and nothing can be
      // concluded from it.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          title: 'Ada Lovelace',
          selfDisplayName: 'You',
          messages: <CapturedMessage>[
            CapturedMessage(sender: '', text: 'something', time: t0),
          ],
        ),
      );

      expect((await threadOf(outcome)).single.direction, Direction.unknown);
    });

    test('a named sender is still inbound, and the user named is still '
        'outbound', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          selfDisplayName: 'Ada',
          messages: <CapturedMessage>[
            anEntry(sender: 'Grace', text: 'from someone else'),
            anEntry(sender: 'Ada', text: 'from the user'),
          ],
        ),
      );

      expect(
        (await threadOf(outcome)).map((Message m) => m.direction),
        <Direction>[Direction.inbound, Direction.outbound],
      );
    });

    test("the projection's senderAbsent flag is what decides it", () {
      // The contract the native side emits (`NotificationProjection
      // .projectHistory`): one `sender` — the legacy name, else the Person's —
      // and the absence stated separately, because a `sender` missing from the
      // JSON cannot be told from one Android emptied.
      final CaptureEvent event = CaptureEvent.decode(
        '{"event":"posted","key":"k","package":"com.whatsapp",'
        '"messages":[{"sender":"Ada","senderAbsent":false,"text":"hi"},'
        '{"sender":"","senderAbsent":false,"text":"hidden"},'
        '{"senderAbsent":true,"text":"mine"}]}',
      )!;

      expect(event.messages.map((CapturedMessage m) => m.hasSender), <bool>[
        true,
        true,
        false,
      ]);
      expect(event.messages.map((CapturedMessage m) => m.senderEmptied), <bool>[
        false,
        true,
        false,
      ]);
    });

    test('a dump written before the flag existed still reads correctly', () {
      // Every fixture in docs/research/spike-dumps predates `senderAbsent`, and
      // none of them holds a line the posting user wrote. Absence of the flag
      // therefore falls back to the older reading — a `sender` key that arrived
      // at all is a sender the notification carried — which is what keeps the
      // redaction fixture reading as redaction.
      final CaptureEvent event = CaptureEvent.decode(
        '{"event":"posted","key":"k","package":"com.google.android.apps.messaging",'
        '"messages":[{"sender":"","text":"Sensitive notification content hidden",'
        '"time":1789990228798}]}',
      )!;

      expect(event.messages.single.senderEmptied, isTrue);
      expect(event.messages.single.senderAbsent, isFalse);
    });

    test('the modern sender key is read as well as the legacy one', () {
      // `Message.toBundle()` writes `sender_person` and, while that Person has
      // a name, the legacy `sender` beside it. Reading only the legacy key
      // would lose the name on any app that stopped writing it.
      final CaptureEvent event = CaptureEvent.decode(
        '{"event":"posted","key":"k","package":"com.whatsapp",'
        '"messages":[{"sender_person":{"name":"Ada"},"text":"hi"},'
        '{"sender":"Grace","text":"hello"},'
        '{"sender_person":"Katherine","text":"hey"},'
        '{"text":"mine"}]}',
      )!;

      expect(event.messages.map((CapturedMessage m) => m.sender), <String?>[
        'Ada',
        'Grace',
        'Katherine',
        null,
      ]);
      // And the one that carried no sender key under either name is the one
      // the user wrote.
      expect(event.messages.map((CapturedMessage m) => m.hasSender), <bool>[
        true,
        true,
        true,
        false,
      ]);
    });

    test('a Person the projection could not name is still a sender', () {
      // Present with nothing readable in it is redaction's shape, not the
      // user's: `hasSender` is what CAP-8 and INB-9 both turn on.
      final CaptureEvent event = CaptureEvent.decode(
        '{"event":"posted","key":"k","package":"com.whatsapp",'
        '"messages":[{"sender_person":{},"text":"hi"}]}',
      )!;

      expect(event.messages.single.hasSender, isTrue);
      expect(event.messages.single.senderEmptied, isTrue);
      expect(event.messages.single.senderAbsent, isFalse);
    });
  });

  group('CAP-9 attachments', () {
    test('a photo is stored as a type code and never as words', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          messages: <CapturedMessage>[
            anEntry(sender: 'Ada', text: 'Photo', type: 'image/jpeg'),
          ],
        ),
      );

      final Message stored = (await threadOf(outcome)).single;
      expect(stored.kind, MessageKind.image);
      // LANG-2: a rendered word stored now is one language's word forever.
      expect(stored.text, isNull);
      expect(await messagesDump(db), isNot(contains('Photo')));
    });

    test('audio, video and anything else map to their kinds', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          messages: <CapturedMessage>[
            anEntry(text: null, type: 'audio/ogg'),
            anEntry(text: null, type: 'video/mp4'),
            anEntry(text: null, type: 'application/pdf'),
          ],
        ),
      );

      expect(
        (await threadOf(outcome)).map((Message m) => m.kind),
        <MessageKind>[
          MessageKind.voice,
          MessageKind.video,
          // Nothing in the spike named an attachment type, so anything unmapped
          // says only that something arrived the app cannot show.
          MessageKind.other,
        ],
      );
    });

    test('five photos in one burst stay five messages', () async {
      // Same sender, same timestamp, no text to tell them apart — the burst
      // case, with the one field that could separate them removed.
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          messages: List<CapturedMessage>.generate(
            5,
            (int _) => anEntry(sender: 'Ada', text: null, type: 'image/jpeg'),
          ),
        ),
      );

      expect(await threadOf(outcome), hasLength(5));
    });

    test('a photo a sliding window moves is one photo, not two', () async {
      // An attachment used to be keyed on where it sat, because it has no text
      // to key on. A window that slides moves it, so the same photo came back
      // under a new position, matched nothing, and was stored again — and the
      // inbox drew the user two of a photo they were sent once.
      final DateTime later = t0.add(const Duration(minutes: 1));
      await ingest.apply(
        aPost(
          shortcutId: 'ada',
          messages: <CapturedMessage>[
            anEntry(sender: 'Ada', text: 'A', time: t0),
            anEntry(sender: 'Ada', text: null, type: 'image/jpeg', time: t0),
          ],
        ),
      );

      final IngestOutcome second = await ingest.apply(
        aPost(
          shortcutId: 'ada',
          messages: <CapturedMessage>[
            anEntry(sender: 'Ada', text: null, type: 'image/jpeg', time: t0),
            anEntry(sender: 'Ada', text: 'B', time: later),
          ],
        ),
      );

      expect(second.messagesStored, 1);
      expect((await threadOf(second)).map((Message m) => m.kind), <MessageKind>[
        MessageKind.text,
        MessageKind.image,
        MessageKind.text,
      ]);
    });

    test('an attachment the app cannot name is matched the same way', () async {
      // `other` is CAP-9's attachment whose type the notification did not name
      // — it still has a sender, a time and a type code — not a message with
      // no content, so it is not on CAP-8's position identity either.
      final DateTime later = t0.add(const Duration(minutes: 1));
      await ingest.apply(
        aPost(
          shortcutId: 'ada',
          messages: <CapturedMessage>[
            anEntry(sender: 'Ada', text: 'A', time: t0),
            anEntry(
              sender: 'Ada',
              text: null,
              type: 'application/pdf',
              time: t0,
            ),
          ],
        ),
      );

      final IngestOutcome second = await ingest.apply(
        aPost(
          shortcutId: 'ada',
          messages: <CapturedMessage>[
            anEntry(
              sender: 'Ada',
              text: null,
              type: 'application/pdf',
              time: t0,
            ),
            anEntry(sender: 'Ada', text: 'B', time: later),
          ],
        ),
      );

      expect(second.messagesStored, 1);
      expect((await threadOf(second)).map((Message m) => m.kind), <MessageKind>[
        MessageKind.text,
        MessageKind.other,
        MessageKind.text,
      ]);
    });
  });

  group('CAP-12 capture sessions', () {
    Future<List<Map<String, Object?>>> sessions() async {
      final Database database = await db.database;
      return database.query('capture_sessions', orderBy: 'started_at ASC');
    }

    test('connecting opens a session and disconnecting closes it', () async {
      final DateTime bound = t0;
      final DateTime lost = t0.add(const Duration(hours: 3));

      final IngestOutcome opened = await ingest.apply(
        CaptureEvent(type: CaptureEventType.listenerConnected, postTime: bound),
      );
      final IngestOutcome closed = await ingest.apply(
        CaptureEvent(
          type: CaptureEventType.listenerDisconnected,
          postTime: lost,
        ),
      );

      expect(opened.action, IngestAction.sessionOpened);
      expect(opened.rule, 'CAP-12');
      expect(closed.action, IngestAction.sessionClosed);
      final Map<String, Object?> row = (await sessions()).single;
      expect(row['started_at'], bound.millisecondsSinceEpoch);
      expect(row['ended_at'], lost.millisecondsSinceEpoch);
    });

    test('a session is recorded whatever package rules would say', () async {
      // The gap belongs to the listener, not to any app, so no CAP-1 check may
      // stand between the event and the row.
      await ingest.apply(
        const CaptureEvent(type: CaptureEventType.listenerConnected),
      );

      expect(await sessions(), hasLength(1));
    });

    test('binding again while a session is open opens nothing, so the app '
        'never counts one window twice', () async {
      // The device drill bound the listener thirty times in one sitting —
      // revoke and grant, `am start -S`, force-stop, reboot — and finished with
      // thirty rows, every one of them still open (21 September 2026). CAP-12's
      // record of when capture was on cannot be read off a table like that.
      final List<IngestOutcome> outcomes = await ingest.applyAll(<CaptureEvent>[
        CaptureEvent(type: CaptureEventType.listenerConnected, postTime: t0),
        CaptureEvent(
          type: CaptureEventType.listenerConnected,
          postTime: t0.add(const Duration(minutes: 5)),
        ),
        CaptureEvent(
          type: CaptureEventType.listenerConnected,
          postTime: t0.add(const Duration(hours: 2)),
        ),
      ]);

      final Map<String, Object?> row = (await sessions()).single;
      // The first bind's time is kept: it is the earlier of the two, and
      // nothing in the events dates the gap between them.
      expect(row['started_at'], t0.millisecondsSinceEpoch);
      expect(row['ended_at'], isNull);
      expect(outcomes.first.action, IngestAction.sessionOpened);
      // Reported as "understood, and correctly changed nothing" rather than as
      // an open, so INB-25's second is not spent reloading for a row that was
      // never written.
      expect(outcomes[1].action, IngestAction.ignored);
      expect(outcomes[1].rule, 'CAP-12');
      expect(outcomes[2].action, IngestAction.ignored);
    });

    test('a bind after a clean disconnect opens the next session', () async {
      // The guard is "while one is open", not "ever again": a listener that
      // said goodbye and came back is two windows and is recorded as two.
      await ingest.applyAll(<CaptureEvent>[
        CaptureEvent(type: CaptureEventType.listenerConnected, postTime: t0),
        CaptureEvent(
          type: CaptureEventType.listenerDisconnected,
          postTime: t0.add(const Duration(hours: 1)),
        ),
        CaptureEvent(
          type: CaptureEventType.listenerConnected,
          postTime: t0.add(const Duration(hours: 2)),
        ),
      ]);

      final List<Map<String, Object?>> rows = await sessions();
      expect(rows, hasLength(2));
      expect(
        rows.first['ended_at'],
        t0.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      expect(rows.last['ended_at'], isNull);
    });

    test(
      'an event shape the contract does not define changes nothing',
      () async {
        final IngestOutcome outcome = await ingest.apply(
          const CaptureEvent(type: CaptureEventType.unknown),
        );

        expect(outcome.action, IngestAction.ignored);
        expect(outcome.rule, 'CAP-15');
        expect(await sessions(), isEmpty);
        expect(await repo.conversations(), isEmpty);
      },
    );
  });

  group('CAP-21 the raw fallback', () {
    test('a msg-category notification with no history is kept', () async {
      await seeApp('com.example.chat', enabled: true, label: 'Chatterbox');

      final IngestOutcome outcome = await ingest.apply(
        aPost(
          package: 'com.example.chat',
          template: r'android.app.Notification$BigTextStyle',
          category: 'msg',
          title: '2 new messages',
          text: 'tap to open',
          messages: const <CapturedMessage>[],
        ),
      );

      expect(outcome.action, IngestAction.stored);
      expect(outcome.rule, 'CAP-21');
      final Conversation c = (await repo.conversations()).single;
      // Labelled with the app, because there is no conversation to name.
      expect(c.title, 'Chatterbox');
      expect(c.conversationKey, 'com.example.chat');
      // CAP-3 stores the field the key came from, and this key is the package:
      // a row saying `notificationKey` while holding a package would send the
      // keying migration CAP-3 exists for looking at the wrong column.
      expect(c.keySource, KeySource.package);
      expect(c.shortcutId, isNull);
      expect(c.conversationTitle, isNull);
      expect(c.tag, isNull);
      final Message stored = (await threadOf(outcome)).single;
      expect(stored.kind, MessageKind.raw);
      expect(stored.sender, '2 new messages');
      expect(stored.text, 'tap to open');
    });

    test('social and email are kept too, promo is not', () async {
      for (final String category in <String>['social', 'email']) {
        final IngestOutcome outcome = await ingest.apply(
          aPost(
            key: 'notif-$category',
            template: r'android.app.Notification$InboxStyle',
            category: category,
            title: 'A notice',
            text: 'about $category',
            messages: const <CapturedMessage>[],
          ),
        );
        expect(outcome.rule, 'CAP-21', reason: category);
      }

      final IngestOutcome promo = await ingest.apply(
        aPost(
          key: 'notif-promo',
          template: r'android.app.Notification$InboxStyle',
          category: 'promo',
          title: 'A sale',
          text: 'about promo',
          messages: const <CapturedMessage>[],
        ),
      );
      expect(promo.rule, 'CAP-2');
      expect(await messagesDump(db), isNot(contains('about promo')));
    });

    test('with neither title nor text there is nothing to show', () async {
      final IngestOutcome outcome = await ingest.apply(
        aPost(
          template: r'android.app.Notification$BigTextStyle',
          category: 'msg',
          title: '',
          text: '',
          messages: const <CapturedMessage>[],
        ),
      );

      expect(outcome.action, IngestAction.dropped);
      expect(outcome.rule, 'CAP-21');
      expect(await repo.conversations(), isEmpty);
    });

    test(
      'a raw thread never merges with a real one from the same app',
      () async {
        await ingest.apply(
          aPost(
            key: 'notif-real',
            shortcutId: 'sc-1',
            conversationTitle: 'Ada Lovelace',
            messages: <CapturedMessage>[anEntry(text: 'a real conversation')],
          ),
        );
        await ingest.apply(
          aPost(
            key: 'notif-raw',
            template: r'android.app.Notification$BigTextStyle',
            category: 'msg',
            title: 'You have mail',
            text: 'tap to open',
            messages: const <CapturedMessage>[],
          ),
        );

        final List<Conversation> all = await repo.conversations();
        expect(all, hasLength(2));
        expect(all.map((Conversation c) => c.conversationKey).toSet(), <String>{
          'sc-1',
          'com.whatsapp',
        });
      },
    );
  });

  group('CAP-22 removals', () {
    /// A stored message to remove the notification of.
    Future<IngestOutcome> storeOne() => ingest.apply(
      aPost(
        shortcutId: 'sc-1',
        messages: <CapturedMessage>[anEntry(text: 'are we still on')],
      ),
    );

    Future<Conversation> reread(String id) async =>
        (await repo.conversations()).firstWhere((Conversation c) => c.id == id);

    for (final RemovalReason reason in RemovalReason.values) {
      test(
        '${reason.name} ${reason.marksRead ? 'marks read' : 'changes nothing'}',
        () async {
          final IngestOutcome posted = await storeOne();

          final IngestOutcome removal = await ingest.apply(
            aRemoval(reason: reason),
          );

          expect(removal.rule, 'CAP-22');
          final Conversation after = await reread(posted.conversationId!);
          if (reason.marksRead) {
            expect(removal.action, IngestAction.markedRead);
            expect(after.readThroughAt, t0);
            expect(await repo.unreadCount(after), 0);
          } else {
            // Clearing the shade is not the user reading anything.
            expect(removal.action, IngestAction.ignored);
            expect(after.readThroughAt, isNull);
            expect(await repo.unreadCount(after), 1);
          }
          // CAP-11 in every case: the shade is the other app's, the inbox ours.
          expect(
            (await repo.messages(posted.conversationId!)).single.text,
            'are we still on',
          );
        },
      );
    }

    test('a reason Android adds later changes nothing', () async {
      expect(RemovalReason.fromName('SNOOZED'), RemovalReason.other);
      expect(RemovalReason.other.marksRead, isFalse);
    });

    test('a removal carrying no reason at all changes nothing', () async {
      // The reason comes from the event; a notification merely being gone is
      // never read as one.
      final IngestOutcome posted = await storeOne();
      final IngestOutcome removal = await ingest.apply(
        CaptureEvent(
          type: CaptureEventType.removed,
          key: 'notif-1',
          package: 'com.whatsapp',
          postTime: t0,
        ),
      );

      expect(removal.action, IngestAction.ignored);
      expect((await reread(posted.conversationId!)).readThroughAt, isNull);
    });

    test(
      'a removal for a notification nothing was stored from is quiet',
      () async {
        final IngestOutcome outcome = await ingest.apply(
          aRemoval(key: 'never-seen', reason: RemovalReason.click),
        );

        expect(outcome.action, IngestAction.ignored);
        expect(outcome.conversationId, isNull);
      },
    );

    test('a late removal of an older notification never un-reads', () async {
      final DateTime later = t0.add(const Duration(minutes: 10));
      final IngestOutcome first = await ingest.apply(
        aPost(
          key: 'notif-old',
          shortcutId: 'sc-1',
          messages: <CapturedMessage>[anEntry(text: 'the old one')],
        ),
      );
      await ingest.apply(
        aPost(
          key: 'notif-new',
          shortcutId: 'sc-1',
          messages: <CapturedMessage>[
            anEntry(text: 'the new one', time: later),
          ],
        ),
      );
      await ingest.apply(
        aRemoval(key: 'notif-new', reason: RemovalReason.click),
      );

      final IngestOutcome late = await ingest.apply(
        aRemoval(key: 'notif-old', reason: RemovalReason.appCancel),
      );

      expect(late.action, IngestAction.ignored);
      final Conversation after = await reread(first.conversationId!);
      expect(after.readThroughAt, later);
      expect(await repo.unreadCount(after), 0);
    });

    test('a click on a burst reads the whole burst', () async {
      // Five messages on one timestamp: the marker has to clear all five.
      final IngestOutcome posted = await ingest.apply(
        aPost(
          shortcutId: 'sc-1',
          messages: List<CapturedMessage>.generate(
            5,
            (int i) => anEntry(text: 'message $i'),
          ),
        ),
      );
      await ingest.apply(aRemoval(reason: RemovalReason.click));

      final Conversation after = await reread(posted.conversationId!);
      expect(await repo.unreadCount(after), 0);
      expect(await repo.messages(posted.conversationId!), hasLength(5));
    });
  });

  group('CAP-23 revival', () {
    test(
      'a new message revives the thread without resurrecting a deleted one',
      () async {
        final IngestOutcome first = await ingest.apply(
          aPost(
            key: 'notif-a',
            shortcutId: 'sc-1',
            conversationTitle: 'Ada Lovelace',
            messages: <CapturedMessage>[anEntry(text: 'the deleted message')],
          ),
        );
        final String id = first.conversationId!;
        await repo.deleteConversation(id, t0.add(const Duration(minutes: 1)));
        expect(await repo.conversations(), isEmpty);

        final DateTime later = t0.add(const Duration(minutes: 5));
        final IngestOutcome second = await ingest.apply(
          aPost(
            key: 'notif-b',
            shortcutId: 'sc-1',
            conversationTitle: 'Ada Lovelace',
            messages: <CapturedMessage>[
              anEntry(text: 'a message after', time: later),
            ],
          ),
        );

        expect(second.revived, isTrue);
        // The same row, not a second one for the same thread.
        expect(second.conversationId, id);
        final List<Conversation> all = await repo.conversations();
        expect(all.single.title, 'Ada Lovelace');
        expect((await repo.messages(id)).map((Message m) => m.text), <String>[
          'a message after',
        ]);
      },
    );

    test('re-posting the deleted notification brings nothing back', () async {
      final CaptureEvent event = aPost(
        shortcutId: 'sc-1',
        messages: <CapturedMessage>[anEntry(text: 'the deleted message')],
      );
      final IngestOutcome first = await ingest.apply(event);
      await repo.deleteConversation(first.conversationId!, t0);

      final IngestOutcome again = await ingest.apply(event);

      expect(again.revived, isTrue);
      expect(again.action, IngestAction.duplicate);
      expect(await repo.messages(first.conversationId!), isEmpty);
    });

    test(
      'a thread that was never deleted is not reported as revived',
      () async {
        final IngestOutcome outcome = await ingest.apply(aPost());

        expect(outcome.revived, isFalse);
      },
    );
  });

  group('rows other apps wrote', () {
    test(
      'a line that is not a JSON object is one lost event, not a throw',
      () async {
        for (final String line in <String>[
          'not json at all',
          '[1, 2, 3]',
          '"a bare string"',
          '',
          '{',
        ]) {
          expect(CaptureEvent.decode(line), isNull, reason: line);
        }
      },
    );

    test('missing fields, wrong types and an empty history are survivable', () async {
      const List<String> rows = <String>[
        // Nothing but an event name.
        '{"event":"posted"}',
        // A number where a package belongs: read as absent, never stringified,
        // because "1024" as a package would be the app inventing one.
        '{"event":"posted","package":1024,"key":"k1"}',
        // An empty history, which is what every group summary carried.
        '{"event":"posted","package":"com.whatsapp","key":"k2","messages":[]}',
        // A string where the times belong.
        '{"event":"posted","package":"com.whatsapp","key":"k3",'
            '"postTime":"nonsense","template":"android.app.Notification\$MessagingStyle",'
            '"messages":[{"sender":"Ada","text":"hello","time":"nonsense"}]}',
        // A history that is not a list, and entries that are not maps.
        '{"event":"posted","package":"com.whatsapp","key":"k4","messages":"none"}',
        '{"event":"posted","package":"com.whatsapp","key":"k5",'
            '"template":"android.app.Notification\$MessagingStyle",'
            '"messages":[7,null,{"sender":9,"text":true,"time":{}}]}',
        // Booleans arriving as the numbers a channel may flatten them to.
        '{"event":"posted","package":"com.whatsapp","key":"k6",'
            '"isGroupSummary":1,"messages":[]}',
        // A removal with a reason nobody has heard of.
        '{"event":"removed","package":"com.whatsapp","key":"k7",'
            '"removalReasonName":"WHAT_IS_THIS"}',
        // An event the contract does not define, which the dumps really carry.
        '{"event":"dismiss_all","result":"cancelled"}',
      ];

      final List<CaptureEvent> events = <CaptureEvent>[];
      for (final String row in rows) {
        final CaptureEvent? event = CaptureEvent.decode(row);
        expect(event, isNotNull, reason: row);
        events.add(event!);
      }

      final List<IngestOutcome> outcomes = await ingest.applyAll(events);

      expect(outcomes, hasLength(rows.length));
      // Only k3 carried a readable message, so it is the only thread; nothing
      // was invented out of a row the engine could not read.
      final Conversation only = (await repo.conversations()).single;
      expect(only.conversationKey, 'k3');
      final Message stored = (await repo.messages(only.id)).single;
      expect(stored.text, 'hello');
      // Unreadable times fall back to the capture clock rather than to zero:
      // 1970 would put the thread at the bottom of the inbox forever (INB-4).
      expect(stored.sentAt, t0);
    });

    test('a wrongly typed title is absent rather than invented', () async {
      final CaptureEvent event = CaptureEvent.decode(
        '{"event":"posted","package":"com.whatsapp","key":"k1",'
        '"title":404,"conversationTitle":404,'
        '"template":"android.app.Notification\$MessagingStyle",'
        '"messages":[{"sender":"Ada","text":"hello","time":1789990218088}]}',
      )!;

      expect(event.title, isNull);
      final IngestOutcome outcome = await ingest.apply(event);

      final Conversation c = (await repo.conversations()).single;
      expect(c.title, isEmpty);
      expect(c.conversationKey, 'k1');
      expect((await threadOf(outcome)).single.text, 'hello');
      expect(await messagesDump(db), isNot(contains('404')));
    });

    test('a timestamp too large to be an instant costs one time, not the '
        'drain', () async {
      // Any included app can put 9e18 in that field, and
      // `DateTime.fromMillisecondsSinceEpoch` throws past ±8.64e15. Unguarded,
      // the throw escapes `decode` — which catches only FormatException — and
      // the queue row that carried it fails the same way on every drain until
      // the 30-day drop (CAP-15).
      const String hostile =
          '{"event":"posted","package":"com.whatsapp","key":"k-hostile",'
          '"postTime":9223372036854775807,'
          '"template":"android.app.Notification\$MessagingStyle",'
          '"title":"Ada Lovelace",'
          '"messages":[{"sender":"Ada","text":"hello","time":-9223372036854775808}]}';

      final CaptureEvent? event = CaptureEvent.decode(hostile);
      expect(event, isNotNull);
      expect(event!.postTime, isNull);
      // The most negative int there is, which is its own absolute value.
      expect(event.messages.single.time, isNull);

      final List<IngestOutcome> outcomes = await ingest.applyAll(<CaptureEvent>[
        event,
        aPost(
          key: 'k-after',
          messages: <CapturedMessage>[anEntry(text: 'the one behind it')],
        ),
      ]);

      // The message is still captured; it simply arrives at the only honest
      // time left, which is the capture clock (INB-4).
      expect(outcomes.first.action, IngestAction.stored);
      expect((await threadOf(outcomes.first)).single.sentAt, t0);
      expect((await threadOf(outcomes.last)).single.text, 'the one behind it');
    });

    test('a truncated history keeps the rest of the drain', () async {
      // One bad row must not cost the events queued behind it.
      final List<IngestOutcome> outcomes = await ingest.applyAll(<CaptureEvent>[
        CaptureEvent.decode('{"event":"posted","package":"com.whatsapp"}')!,
        aPost(
          messages: <CapturedMessage>[anEntry(text: 'the one that counts')],
        ),
      ]);

      expect(outcomes.first.action, IngestAction.dropped);
      expect(outcomes.last.action, IngestAction.stored);
      expect(
        (await repo.messages(outcomes.last.conversationId!)).single.text,
        'the one that counts',
      );
    });
  });

  // --- known gaps ---------------------------------------------------------
  //
  // Each of these pins behaviour that contradicts the rule named in it. They
  // are written green so the branch is not held red by bugs this file does not
  // own, and every one carries the assertion that *should* hold — flipping it
  // is a one-line change once the rule or the engine moves. Reported, not
  // fixed; see the capture handoff.
  // Gaps 1, 3 and 5 were the message-identity defect and are fixed; their
  // tests now sit in the CAP-5, CAP-8 and CAP-21 groups above, asserting the
  // behaviour rather than pinning the loss. The numbers of the three that are
  // still open are left alone, so a gap keeps one name for its whole life.
  group('CAP-5 a time that moves is not identity', () {
    // Android sets `StatusBarNotification.postTime` on every enqueue, including
    // the in-place update an app makes when it re-posts a notification already
    // in the shade. Every message with no time of its own — a hidden one
    // (CAP-8), a raw one (CAP-21), an attachment or a text line whose entry
    // carried no readable time — took that value as its `sent_at`, and the
    // dedup lookup matched on it. So the stored row was never found, and the
    // same message was written again on every re-post, forever.
    //
    // CAP-8 already says what those messages are identified by instead: the
    // notification key and the position in the history. These are the five
    // shapes a reviewer reproduced against real SQLite.

    final DateTime t1 = t0;
    final DateTime t2 = t0.add(const Duration(minutes: 1));
    final DateTime t3 = t0.add(const Duration(minutes: 2));

    /// A redacted notification, as Android builds one, with [entries] lines.
    CaptureEvent redacted({required DateTime postTime, required int entries}) =>
        aPost(
          shortcutId: 'ada',
          title: '',
          text: 'Sensitive notification content hidden',
          selfDisplayName: '',
          postTime: postTime,
          messages: List<CapturedMessage>.generate(
            entries,
            (int _) => const CapturedMessage(
              sender: '',
              text: 'Sensitive notification content hidden',
            ),
          ),
        );

    Future<int> threadLength() async =>
        (await repo.messages((await repo.conversations()).single.id)).length;

    test('A: a redacted history that grows stores the new line only', () async {
      await ingest.apply(redacted(postTime: t1, entries: 1));
      final IngestOutcome second = await ingest.apply(
        redacted(postTime: t2, entries: 2),
      );

      // Two messages were sent. The second post re-presents the first at index
      // 0 and adds one at index 1.
      expect(second.messagesStored, 1);
      expect(await threadLength(), 2);
    });

    test('B: a redacted window that slides keeps its new message', () async {
      await ingest.apply(redacted(postTime: t1, entries: 2));
      final IngestOutcome second = await ingest.apply(
        redacted(postTime: t2, entries: 2),
      );

      // Three messages were sent: the window holds the newest two, so the
      // second post is the older one again plus one that is new. The newest
      // line of a re-presented history is the only place a slide can put a
      // message, and a hidden message carries nothing that could prove it is
      // the same one — so a post at a new moment is a new message, and the app
      // keeps it rather than reading it as a re-post and losing it.
      expect(second.messagesStored, 1);
      expect(await threadLength(), 3);
    });

    test('CAP-13: a reconnection re-read of the same notification stores '
        'nothing', () async {
      // The other side of B, and the reason the rule is "the same moment" and
      // not "a later one": a re-read hands back the same `StatusBarNotification`
      // with the same `postTime`, so nothing about it is new.
      await ingest.apply(redacted(postTime: t1, entries: 2));
      final IngestOutcome reread = await ingest.apply(
        redacted(postTime: t1, entries: 2),
      );

      expect(reread.action, IngestAction.duplicate);
      expect(await threadLength(), 2);
    });

    test('C: an attachment history that grows on entries with no time stores '
        'the new photo only', () async {
      CaptureEvent photos({required DateTime postTime, required int entries}) =>
          aPost(
            shortcutId: 'ada',
            postTime: postTime,
            messages: List<CapturedMessage>.generate(
              entries,
              // No `time`: the entry carried none, so `sent_at` falls back to
              // the notification's moving post time.
              (int _) =>
                  const CapturedMessage(sender: 'Ada', type: 'image/jpeg'),
            ),
          );

      await ingest.apply(photos(postTime: t1, entries: 1));
      final IngestOutcome second = await ingest.apply(
        photos(postTime: t2, entries: 2),
      );

      expect(second.messagesStored, 1);
      final List<Message> thread = await repo.messages(
        (await repo.conversations()).single.id,
      );
      expect(thread, hasLength(2));
      expect(thread.every((Message m) => m.kind == MessageKind.image), isTrue);
    });

    test('D: a text entry whose time cannot be read is not stored again on a '
        're-post', () async {
      // `9e18` milliseconds is not an instant a `DateTime` can hold, so the
      // time is read as absent and `sent_at` falls back to the post time.
      CaptureEvent hostile(int postTime) => CaptureEvent.decode(
        '{"event":"posted","key":"notif-1","package":"com.whatsapp",'
        '"template":"android.app.Notification\$MessagingStyle",'
        '"title":"Ada Lovelace","selfDisplayName":"You",'
        '"postTime":$postTime,'
        '"messages":[{"sender":"Ada","text":"hey","time":9000000000000000000}]}',
      )!;

      await ingest.apply(hostile(t1.millisecondsSinceEpoch));
      final IngestOutcome second = await ingest.apply(
        hostile(t2.millisecondsSinceEpoch),
      );

      expect(second.action, IngestAction.duplicate);
      expect(await threadLength(), 1);
    });

    test('E: a raw notification re-posted unchanged is one message, and a '
        'changed one is two (CAP-21)', () async {
      // The everyday case: an app calling notify() again with the same id.
      // "N new notifications", a group alert, an email summary. Matched on the
      // post time, this grew by one row on every re-post for as long as the app
      // kept re-posting.
      CaptureEvent summary(String text, DateTime postTime) => aPost(
        template: r'android.app.Notification$BigTextStyle',
        category: 'social',
        title: 'Instagram',
        text: text,
        postTime: postTime,
        messages: const <CapturedMessage>[],
      );

      await ingest.apply(summary('2 new notifications', t1));
      final IngestOutcome repost = await ingest.apply(
        summary('2 new notifications', t2),
      );
      expect(repost.action, IngestAction.duplicate);
      expect(await threadLength(), 1);

      // And the content is still identity, so an app that says something else
      // is saying something else.
      final IngestOutcome changed = await ingest.apply(
        summary('3 new notifications', t3),
      );
      expect(changed.messagesStored, 1);
      expect(await threadLength(), 2);
    });

    test('a message that carried its own time is still matched on content, '
        'wherever it turns up', () async {
      // The other half of the rule, so the fix cannot become "match everything
      // on position". A re-read under a new key is the same message (CAP-13).
      await ingest.apply(
        aPost(
          key: 'notif-a',
          shortcutId: 'ada',
          messages: <CapturedMessage>[anEntry(sender: 'Ada', text: 'hello')],
        ),
      );
      final IngestOutcome reread = await ingest.apply(
        aPost(
          key: 'notif-b',
          shortcutId: 'ada',
          messages: <CapturedMessage>[anEntry(sender: 'Ada', text: 'hello')],
        ),
      );

      expect(reread.action, IngestAction.duplicate);
      expect(await threadLength(), 1);
    });

    test('and the column says which rule a stored row is under', () async {
      await ingest.apply(redacted(postTime: t1, entries: 1));
      await ingest.apply(
        aPost(
          key: 'notif-2',
          shortcutId: 'ada',
          messages: <CapturedMessage>[anEntry(sender: 'Ada', text: 'hello')],
        ),
      );

      final List<Message> thread = await repo.messages(
        (await repo.conversations()).single.id,
      );
      expect(
        thread.map((Message m) => (m.kind, m.timeSource)).toSet(),
        <(MessageKind, TimeSource)>{
          (MessageKind.hidden, TimeSource.post),
          (MessageKind.text, TimeSource.entry),
        },
      );
    });

    // The device found the rest of this rule, and the suite could not have:
    // every test above moves the notification's `postTime`, and the drill moved
    // **the history entry's own time** (drill, 21 September 2026). Google
    // Messages posted one notification twice, 501 ms apart, with the same key,
    // the same position, the same sender and the same words, and the user saw
    // their own reply twice in the thread.

    test('F: an entry whose own clock moved under it is the same message', () async {
      // The drill's shape exactly: the reply the user typed into the shade sat
      // at index 3 of a four-line history, and on the next post of the same
      // notification it sat at index 3 of a five-line one, with its time moved.
      CaptureEvent thread({required int ownReplyMillis, required bool echo}) =>
          aPost(
            key: 'gm-key',
            shortcutId: '1',
            title: '(555) 123-4567',
            selfDisplayName: 'You',
            messages: <CapturedMessage>[
              anEntry(sender: '(555) 123-4567', text: 'first', time: t1),
              anEntry(sender: '(555) 123-4567', text: 'fourth', time: t2),
              anEntry(sender: '(555) 123-4567', text: 'fifth', time: t3),
              CapturedMessage(
                // No sender key at all: the platform's own way of marking the
                // phone owner's line (INB-9).
                hasSender: false,
                text: 'my own reply line',
                time: DateTime.fromMillisecondsSinceEpoch(
                  ownReplyMillis,
                  isUtc: true,
                ),
              ),
              if (echo)
                anEntry(
                  sender: '(555) 123-4567',
                  text: 'my own reply line',
                  time: t3.add(const Duration(minutes: 1)),
                ),
            ],
          );

      final int first = t0
          .add(const Duration(minutes: 10))
          .millisecondsSinceEpoch;
      await ingest.apply(thread(ownReplyMillis: first, echo: false));
      final IngestOutcome second = await ingest.apply(
        // 501 ms later, which is what the phone did.
        thread(ownReplyMillis: first + 501, echo: true),
      );

      final List<Message> stored = await repo.messages(
        (await repo.conversations()).single.id,
      );
      // The reply is there once, in the words the user typed, on their own side.
      final List<Message> own = stored
          .where((Message m) => m.direction == Direction.outbound)
          .toList();
      expect(own, hasLength(1));
      expect(own.single.text, 'my own reply line');
      // Five messages, not six: the echo the network sent back carries a sender
      // and is a different message, so it is kept.
      expect(stored.map((Message m) => m.text), <String>[
        'first',
        'fourth',
        'fifth',
        'my own reply line',
        'my own reply line',
      ]);
      expect(second.messagesStored, 1);
    });

    test('G: but the same words sent again at the newest position are two '
        'messages', () async {
      // The safety of F, asserted rather than assumed. A contact who sends "ok"
      // and then "ok" again to a thread whose history holds one entry hands us
      // two genuinely different messages at position 0 under one key. Folding
      // them into one would lose the second, which is the class of defect this
      // whole rule exists to stop — and nothing in the data separates that from
      // a re-post of the first with its clock moved, so CAP-5's alignment
      // declines an overlap that no unmoved entry corroborates and takes the
      // duplicate over the loss.
      CaptureEvent ok(DateTime at) => aPost(
        key: 'gm-key',
        shortcutId: 'ada',
        messages: <CapturedMessage>[
          anEntry(sender: 'Ada', text: 'ok', time: at),
        ],
      );

      await ingest.apply(ok(t1));
      final IngestOutcome second = await ingest.apply(ok(t2));

      expect(second.messagesStored, 1);
      expect(await threadLength(), 2);
    });

    test('H: a window that slides still loses nothing', () async {
      // The other residual the fix must not create. The alignment matches on
      // the order and never on the index, so a slide — which is what moves an
      // entry off its index — changes nothing about what it recognises.
      CaptureEvent window(List<(String, DateTime)> lines) => aPost(
        key: 'gm-key',
        shortcutId: 'ada',
        messages: <CapturedMessage>[
          for (final (String text, DateTime at) in lines)
            anEntry(sender: 'Ada', text: text, time: at),
        ],
      );

      await ingest.apply(
        window(<(String, DateTime)>[('one', t1), ('two', t2)]),
      );
      final IngestOutcome slid = await ingest.apply(
        window(<(String, DateTime)>[('two', t2), ('three', t3)]),
      );

      expect(slid.messagesStored, 1);
      expect(
        (await repo.messages(
          (await repo.conversations()).single.id,
        )).map((Message m) => m.text),
        <String>['one', 'two', 'three'],
      );
    });

    // The second drill, and the two shapes that finished field-matching off.
    // Both are replayed from the phone's own bytes in
    // `capture_fixture_test.dart`; these are the same shapes reduced to the one
    // thing each of them is about (drill, emulator-5554, API 37, 21 September
    // 2026, evening).

    test('I: a window that slides AND moves a clock in one post stores only '
        'what is new', () async {
      // Shape (i). The oldest entry falls off the window in the same post that
      // moves the newest one's clock, so a content match misses (the time
      // moved) and a position match misses (the index moved). The alignment
      // matches on neither: "b", "c" and the owner's line are the same three
      // messages in the same order, wherever they now sit and whatever their
      // clocks now say.
      CaptureEvent post(List<CapturedMessage> entries) => aPost(
        key: 'gm-key',
        shortcutId: 'ada',
        title: 'Ada',
        selfDisplayName: 'You',
        messages: entries,
      );
      CapturedMessage from(String text, DateTime at) =>
          anEntry(sender: 'Ada', text: text, time: at);
      CapturedMessage own(String text, DateTime at) =>
          CapturedMessage(hasSender: false, text: text, time: at);

      final DateTime t4 = t0.add(const Duration(minutes: 3));
      await ingest.apply(
        post(<CapturedMessage>[
          from('a', t1),
          from('b', t2),
          from('c', t3),
          own('my reply', t4),
        ]),
      );
      final IngestOutcome second = await ingest.apply(
        post(<CapturedMessage>[
          // 'a' fell off the front …
          from('b', t2),
          from('c', t3),
          // … the owner's line moved from index 3 to index 2 *and* its clock
          // moved 400 ms under it …
          own('my reply', t4.add(const Duration(milliseconds: 400))),
          // … and the network echoed the reply back, which is a message of its
          // own and is kept (INB-9).
          from('my reply', t4.add(const Duration(seconds: 1))),
        ]),
      );

      expect(second.messagesStored, 1);
      final List<Message> thread = await repo.messages(
        (await repo.conversations()).single.id,
      );
      expect(thread.map((Message m) => m.text), <String>[
        'a',
        'b',
        'c',
        'my reply',
        'my reply',
      ]);
      // The owner's own words, once, on their side, and still the time the app
      // first gave them: recognising a message never rewrites it.
      final List<Message> own1 = thread
          .where((Message m) => m.direction == Direction.outbound)
          .toList();
      expect(own1, hasLength(1));
      expect(own1.single.text, 'my reply');
      expect(own1.single.sentAt, t4);
    });

    test('J: a clock that moves on the newest line of the history is still '
        'the same message', () async {
      // Shape (ii), and the one the old rule could not reach at all: the
      // position match was forbidden at the newest position, deliberately, and
      // this entry never leaves it. Without an SMS loopback echoing every
      // outgoing message back there is nothing to demote the owner's line, so
      // on a real phone this is the ordinary case.
      //
      // What separates it from G is the entry above it: "hello" still carries
      // the time it carried before, which is what says this history is the one
      // already stored rather than a fresh window of the same words.
      CaptureEvent post(DateTime replyAt) => aPost(
        key: 'gm-key',
        shortcutId: 'ada',
        title: 'Ada',
        selfDisplayName: 'You',
        messages: <CapturedMessage>[
          anEntry(sender: 'Ada', text: 'hello', time: t1),
          CapturedMessage(hasSender: false, text: 'my reply', time: replyAt),
        ],
      );

      await ingest.apply(post(t2));
      final IngestOutcome second = await ingest.apply(
        post(t2.add(const Duration(milliseconds: 550))),
      );

      expect(second.action, IngestAction.duplicate);
      expect(await threadLength(), 2);
    });

    test(
      'K: the alignment reads the end of a long history, not its start',
      () async {
        // The tail is bounded — a history is at most 25 entries on the platform —
        // so a thread with more rows under one key than the bound must still
        // recognise the window that is actually posted, which sits at the end.
        // Read from the wrong end, every re-post of a long-lived thread would file
        // its whole history again.
        CaptureEvent post(List<int> ns) => aPost(
          key: 'gm-key',
          shortcutId: 'ada',
          messages: <CapturedMessage>[
            for (final int n in ns)
              anEntry(
                sender: 'Ada',
                text: 'm$n',
                time: t0.add(Duration(minutes: n)),
              ),
          ],
        );

        // Sixty messages, delivered five at a time under one key, is more rows
        // than the alignment ever reads back at once.
        expect(60, greaterThan(Repository.alignmentTailLimit));
        for (int start = 1; start <= 60; start += 5) {
          await ingest.apply(
            post(<int>[for (int n = start; n < start + 5; n++) n]),
          );
        }
        expect(await threadLength(), 60);

        // The newest window again, with the newest entry's clock moved the way
        // the phone moves it.
        final IngestOutcome again = await ingest.apply(
          aPost(
            key: 'gm-key',
            shortcutId: 'ada',
            messages: <CapturedMessage>[
              for (int n = 56; n <= 59; n++)
                anEntry(
                  sender: 'Ada',
                  text: 'm$n',
                  time: t0.add(Duration(minutes: n)),
                ),
              anEntry(
                sender: 'Ada',
                text: 'm60',
                time: t0.add(const Duration(minutes: 60, milliseconds: 300)),
              ),
            ],
          ),
        );

        expect(again.action, IngestAction.duplicate);
        expect(await threadLength(), 60);
      },
    );

    test('L: an older post of the same key redelivered after a newer one is '
        'still the same messages', () async {
      // Where the alignment hands over to CAP-5's cross-key content match, and
      // the reason that match still looks inside this key too. The queue is
      // appended to while the app is dead and drained when it starts, and a
      // re-read on reconnection can hand back a post the app has already moved
      // past (CAP-13). The overlap is then not at the end of what is stored, so
      // no alignment exists — and the content match settles it, because every
      // one of those entries still carries the time it was stored with.
      CaptureEvent post(List<String> texts) => aPost(
        key: 'gm-key',
        shortcutId: 'ada',
        messages: <CapturedMessage>[
          for (final String text in texts)
            anEntry(
              sender: 'Ada',
              text: text,
              time: t0.add(Duration(minutes: text.length)),
            ),
        ],
      );

      await ingest.apply(post(<String>['a']));
      await ingest.apply(post(<String>['a', 'bb', 'ccc']));
      final IngestOutcome stale = await ingest.apply(post(<String>['a']));

      expect(stale.action, IngestAction.duplicate);
      expect(
        (await repo.messages(
          (await repo.conversations()).single.id,
        )).map((Message m) => m.text),
        <String>['a', 'bb', 'ccc'],
      );
    });
  });

  group('known gaps, pinned so a change to them is deliberate', () {
    test('BUG 2 (CAP-8): a hidden placeholder holds its slot against the '
        'words it hid', () async {
      const String marker = 'Sensitive notification content hidden';
      await ingest.apply(
        aPost(
          key: 'notif-1',
          shortcutId: 'ada',
          title: '',
          selfDisplayName: '',
          text: marker,
          messages: <CapturedMessage>[anEntry(sender: '', text: marker)],
        ),
      );

      // The same notification key, now carrying real content — what a re-read
      // after the screen is unlocked would deliver (CAP-13).
      final IngestOutcome second = await ingest.apply(
        aPost(
          key: 'notif-1',
          shortcutId: 'ada',
          conversationTitle: 'Ada Lovelace',
          messages: <CapturedMessage>[
            anEntry(sender: 'Ada', text: 'the real words'),
          ],
        ),
      );

      // Since CAP-5 stopped keying identity on position, the words are no
      // longer swallowed: they are stored beside the placeholder rather than
      // instead of it. What is left is that the placeholder stays in the
      // thread, so the user sees a "hidden message" note above the message it
      // was hiding.
      // Unordered on purpose: both rows carry the notification's one post time
      // and index 0, so which is drawn first is a tie the database breaks by
      // id — which is the other half of this gap.
      final List<Message> thread = await threadOf(second);
      expect(thread, hasLength(2));
      expect(thread.map((Message m) => m.kind).toSet(), <MessageKind>{
        MessageKind.hidden,
        MessageKind.text,
      });
      expect(thread.map((Message m) => m.text), contains('the real words'));
      expect(await messagesDump(db), isNot(contains(marker)));
      // SHOULD BE: the placeholder is replaced, leaving 'the real words' alone.
    });

    test('BUG 4 (CAP-3): an app that starts sending shortcutId splits one '
        'thread in two', () async {
      await ingest.apply(
        aPost(
          key: 'notif-a',
          conversationTitle: 'Ada Lovelace',
          messages: <CapturedMessage>[anEntry(text: 'before the app update')],
        ),
      );
      await ingest.apply(
        aPost(
          key: 'notif-b',
          shortcutId: 'ada',
          conversationTitle: 'Ada Lovelace',
          messages: <CapturedMessage>[
            anEntry(
              text: 'after the app update',
              time: t0.add(const Duration(minutes: 1)),
            ),
          ],
        ),
      );

      // The candidates needed to notice this are stored on both rows; nothing
      // reads them, so the inbox shows the same person twice.
      final List<Conversation> all = await repo.conversations();
      expect(all, hasLength(2));
      expect(all.map((Conversation c) => c.title).toSet(), <String>{
        'Ada Lovelace',
      });
      // SHOULD BE: one thread, migrated onto the new key.
    });
  });
}
