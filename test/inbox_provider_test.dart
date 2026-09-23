import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/initials.dart';
import 'package:replybox/models/message.dart';
import 'package:replybox/models/record.dart';
import 'package:replybox/models/source_app.dart';
import 'package:replybox/providers/apps_provider.dart';
import 'package:replybox/providers/inbox_provider.dart';
import 'package:replybox/providers/thread_provider.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:replybox/services/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';

/// The state layer, asserted on what the screen would draw from it — the order
/// of the rows, the number on the badge, which chip is in the row, which
/// sentence the empty state is — never on a method having returned something.
void main() {
  setUpAll(initTestDatabases);

  late Repository repo;
  late DBHelper db;
  late DeviceServices services;

  setUp(() async {
    final ({Repository repository, DBHelper db}) t = await testRepository();
    repo = t.repository;
    db = t.db;
    services = noopServices();
  });

  tearDown(() => db.close());

  /// Waits for the provider to rebuild itself, and fails rather than hanging if
  /// it does not — INB-25 gives it one second.
  Future<void> nextRebuild(
    ChangeNotifierSpy spy,
    void Function() trigger,
  ) async {
    final Future<void> rebuilt = spy.next;
    trigger();
    await rebuilt.timeout(const Duration(seconds: 1));
  }

  group('INB-1 and INB-4 the list', () {
    test('rows come back in the sorted order, each with its own newest '
        'message and unread count', () async {
      final DateTime later = t0.add(const Duration(minutes: 5));
      final Conversation ada = aConversation(key: 'ada', title: 'Ada Lovelace');
      final Conversation grace = aConversation(
        key: 'grace',
        title: 'Grace Hopper',
        lastMessageAt: later,
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
          sentAt: later,
        ),
      );

      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();

      expect(inbox.rows.map((InboxRow r) => r.conversation.title), <String>[
        'Grace Hopper',
        'Ada Lovelace',
      ]);
      expect(inbox.rows.first.newestMessage!.text, 'from grace');
      expect(inbox.rows.first.unreadCount, 1);
      expect(inbox.rows.first.hasUnread, isTrue);
      expect(inbox.rows.last.newestMessage!.text, 'from ada');
    });

    test('a group conversation names the sender in its preview and a '
        'one-to-one does not', () async {
      final Conversation group = aConversation(
        key: 'group',
        title: 'Lunch crew',
        isGroup: true,
      );
      final Conversation direct = aConversation(key: 'direct');
      await repo.insertConversation(group);
      await repo.insertConversation(direct);
      await repo.insertMessageIfNew(
        aMessage(conversationId: group.id, sender: 'Grace', text: 'on my way'),
      );
      await repo.insertMessageIfNew(
        aMessage(conversationId: direct.id, sender: 'Ada', text: 'hello'),
      );

      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();

      final InboxRow groupRow = inbox.rows.firstWhere(
        (InboxRow r) => r.conversation.id == group.id,
      );
      final InboxRow directRow = inbox.rows.firstWhere(
        (InboxRow r) => r.conversation.id == direct.id,
      );
      expect(groupRow.previewNamesSender, isTrue);
      expect(directRow.previewNamesSender, isFalse);
    });

    test('initials are the first letter of the first two words, and an '
        'unnamed conversation has none (INB-2)', () async {
      expect(initialsOf('Ada Lovelace'), 'AL');
      expect(initialsOf('Ada Byron King Lovelace'), 'AB');
      expect(initialsOf('  ada  '), 'A');

      // The drill of 23 September 2026: `(555) 123-0003` drew `(1`, two
      // characters of punctuation and arithmetic where a name goes. The first
      // character of a word is only an initial when it is a letter, so a title
      // with no letters in it yields none and the row falls to INB-2's
      // treatment for a circle with nothing in it (the app icon alone).
      expect(initialsOf('(555) 123-0003'), '');
      expect(initialsOf('42 Grace'), 'G', reason: 'a wordless word is skipped');

      final Conversation unnamed = aConversation(key: 'unnamed', title: '');
      await repo.insertConversation(unnamed);
      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();

      expect(inbox.rows.single.isUnnamed, isTrue);
      expect(
        inbox.rows.single.initials,
        '',
        reason: 'the row shows the app icon alone',
      );
    });

    test('a raw conversation is marked as one (CAP-21, INB-12)', () async {
      final Conversation raw = aConversation(
        key: 'com.example.shopping',
        keySource: KeySource.package,
        title: 'Shopping',
      );
      await repo.insertConversation(raw);
      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();

      expect(inbox.rows.single.isRaw, isTrue);
      expect(inbox.rows.single.initials, '');
    });
  });

  group('INB-5 the badge', () {
    test('ninety-nine is a number and a hundred overflows', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessagesIfNew(<Message>[
        for (int i = 0; i < 100; i++)
          aMessage(
            conversationId: c.id,
            text: 'message $i',
            historyIndex: i,
            notificationKey: 'burst',
          ),
      ]);

      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();
      expect(inbox.rows.single.unreadCount, 100);
      expect(inbox.rows.single.unreadOverflows, isTrue);

      // One fewer, and the exact number is what the badge draws.
      await (await db.database).delete(
        'messages',
        where: 'text = ?',
        whereArgs: <Object?>['message 99'],
      );
      await inbox.load();
      expect(inbox.rows.single.unreadCount, 99);
      expect(inbox.rows.single.unreadOverflows, isFalse);
    });
  });

  group('INB-6 delete and Undo', () {
    test(
      'the row goes, and Undo brings back exactly what that step took',
      () async {
        final Conversation c = aConversation();
        await repo.insertConversation(c);
        await repo.insertMessagesIfNew(<Message>[
          aMessage(conversationId: c.id, text: 'kept', historyIndex: 0),
          aMessage(conversationId: c.id, text: 'also kept', historyIndex: 1),
        ]);
        // One the user deleted earlier, which Undo must not resurrect (CAP-23).
        final DateTime earlier = t0.subtract(const Duration(hours: 1));
        await (await db.database).insert('messages', <String, Object?>{
          ...aMessage(
            conversationId: c.id,
            text: 'deleted earlier',
            historyIndex: 2,
          ).toMap(),
          'deleted_at': timeToDb(earlier),
        });

        final InboxProvider inbox = InboxProvider(repo, services);
        await inbox.load();
        expect(inbox.rows, hasLength(1));

        final DateTime? deletedAt = await inbox.deleteConversation(c, t0);
        expect(deletedAt, t0);
        expect(inbox.rows, isEmpty);

        await inbox.undoDelete(c, deletedAt!);
        expect(inbox.rows, hasLength(1));
        expect((await repo.messages(c.id)).map((Message m) => m.text), <String>[
          'kept',
          'also kept',
        ]);
      },
    );

    test("a chip whose app's last conversation is inside a pending Undo stays "
        'in the row until the window closes', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();
      expect(inbox.chips.single.package, 'com.whatsapp');

      await inbox.deleteConversation(c, t0);
      expect(
        inbox.chips.single.package,
        'com.whatsapp',
        reason: 'the row must not shuffle under the hand reaching for Undo',
      );
      expect(inbox.chips.single.conversationCount, 0);

      await inbox.forgetPendingUndo(c);
      expect(inbox.chips, isEmpty);
    });

    test('a second delete inside the first window takes the slot, and the '
        'first window closing does not clear it', () async {
      // The screen shows one Undo at a time, so deleting B clears A's snackbar
      // — which resolves the screen's wait on it with a non-action reason, and
      // A's window therefore closes *after* B has taken the pending slot. That
      // closing names A, and it must not take B's chip out of the row or B's
      // sentence off the screen while B's Undo is still there (INB-6, INB-14,
      // INB-15).
      final Conversation a = aConversation(key: 'a');
      final Conversation b = aConversation(
        package: 'org.telegram.messenger',
        key: 'b',
      );
      await repo.insertConversation(a);
      await repo.insertConversation(b);
      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();

      await inbox.deleteConversation(a, t0);
      await inbox.deleteConversation(b, t0.add(const Duration(seconds: 1)));
      await inbox.forgetPendingUndo(a);

      expect(
        inbox.pendingUndo?.conversation.id,
        b.id,
        reason: "A's window closing says nothing about B's",
      );
      expect(
        inbox.chips.single.package,
        'org.telegram.messenger',
        reason: "B's chip may not leave the row while B's Undo is on screen",
      );
      expect(
        inbox.emptyState.onlyPendingUndoLeft,
        isTrue,
        reason: 'INB-15 reads the same slot, and B is still inside its window',
      );

      // B's own closing is what finally takes both.
      await inbox.forgetPendingUndo(b);
      expect(inbox.pendingUndo, isNull);
      expect(inbox.chips, isEmpty);
      expect(inbox.emptyState.kind, InboxEmptyKind.nothingYet);
    });
  });

  group('INB-14 the chip row', () {
    test('one chip per app with a conversation, newest app first', () async {
      await repo.insertConversation(
        aConversation(package: 'org.telegram.messenger', key: 'a'),
      );
      await repo.insertConversation(
        aConversation(
          package: 'com.whatsapp',
          key: 'b',
          lastMessageAt: t0.add(const Duration(minutes: 5)),
        ),
      );
      await repo.insertConversation(
        aConversation(package: 'com.whatsapp', key: 'c'),
      );

      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();

      expect(inbox.chips.map((InboxChip chip) => chip.package), <String>[
        'com.whatsapp',
        'org.telegram.messenger',
      ]);
      expect(inbox.chips.first.conversationCount, 2);
    });

    test('a selected chip stays after its last conversation is deleted, '
        'so the filtered-empty state is reachable (INB-15)', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertConversation(
        aConversation(package: 'org.telegram.messenger', key: 'other'),
      );

      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();
      await inbox.toggleFilter('com.whatsapp');
      expect(inbox.rows, hasLength(1));

      await inbox.deleteConversation(c, t0);
      await inbox.forgetPendingUndo(c);

      expect(
        inbox.chips.map((InboxChip chip) => chip.package),
        contains('com.whatsapp'),
      );
      expect(inbox.emptyState.kind, InboxEmptyKind.nothingInFilter);

      // Deselecting it is what finally takes it out of the row.
      await inbox.toggleFilter('com.whatsapp');
      expect(inbox.chips.map((InboxChip chip) => chip.package), <String>[
        'org.telegram.messenger',
      ]);
    });

    test('a filter hides rows and changes no switch', () async {
      await repo.upsertSeenApp(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabledIfNew: true,
        at: t0,
      );
      await repo.insertConversation(aConversation());
      await repo.insertConversation(
        aConversation(package: 'org.telegram.messenger', key: 'other'),
      );

      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();
      await inbox.toggleFilter('org.telegram.messenger');

      expect(inbox.rows, hasLength(1));
      expect(inbox.rows.single.conversation.package, 'org.telegram.messenger');
      expect(await repo.enabledPackages(), <String>['com.whatsapp']);
    });
  });

  group('INB-15 empty states', () {
    test('nothing stored names up to three included apps, most recently '
        'seen first, and counts the rest', () async {
      final List<String> packages = <String>[
        'com.whatsapp',
        'org.telegram.messenger',
        'com.instagram.android',
        'com.facebook.orca',
      ];
      for (int i = 0; i < packages.length; i++) {
        await repo.upsertSeenApp(
          package: packages[i],
          label: 'App $i',
          enabledIfNew: true,
          at: t0.add(Duration(minutes: i)),
        );
      }
      // One the user is not capturing from: it is not an "included" app and is
      // named nowhere.
      await repo.upsertSeenApp(
        package: 'com.example.shopping',
        label: 'Shopping',
        enabledIfNew: false,
        at: t0.add(const Duration(hours: 1)),
      );

      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();

      expect(inbox.emptyState.kind, InboxEmptyKind.nothingYet);
      expect(inbox.emptyState.namedApps.map((SourceApp a) => a.label), <String>[
        'App 3',
        'App 2',
        'App 1',
      ]);
      expect(inbox.emptyState.otherAppCount, 1);
      expect(inbox.emptyState.hasCaptureGap, isFalse);
    });

    test('a capture gap is stated, and a rebind at boot is not', () async {
      final InboxProvider inbox = InboxProvider(
        repo,
        services,
        clock: () => t0.add(const Duration(hours: 6)),
      );

      await repo.openCaptureSession(t0);
      await repo.closeCaptureSession(t0.add(const Duration(minutes: 10)));
      await repo.openCaptureSession(
        t0.add(const Duration(minutes: 10, seconds: 30)),
      );
      await inbox.load();
      expect(inbox.emptyState.hasCaptureGap, isFalse);

      await repo.closeCaptureSession(t0.add(const Duration(hours: 1)));
      await repo.openCaptureSession(t0.add(const Duration(hours: 3)));
      await inbox.load();
      expect(inbox.emptyState.hasCaptureGap, isTrue);
    });

    test(
      'a forgotten filter never makes the app claim it captured nothing',
      () async {
        await repo.insertConversation(aConversation());
        final InboxProvider inbox = InboxProvider(repo, services);
        await inbox.load();
        await inbox.setFilter(<String>{'org.telegram.messenger'});

        expect(inbox.rows, isEmpty);
        expect(
          inbox.emptyState.kind,
          InboxEmptyKind.nothingInFilter,
          reason:
              'there is something stored; the filter is why it is not shown',
        );
        expect(inbox.emptyState.filteredPackages, <String>[
          'org.telegram.messenger',
        ]);

        await inbox.clearFilter();
        expect(inbox.emptyState.kind, InboxEmptyKind.none);
      },
    );

    test('the only conversation being inside an Undo window is said, not '
        'drawn as a blank list', () async {
      // INB-15's fourth state, which the rule does not yet name: one stored
      // conversation, swiped away, and for the five seconds of the Undo window
      // the list is empty while none of the three states holds. *Nothing yet*
      // is a lie here — there is history, one tap away — and *Nothing in this
      // filter* needs a filter there is none of.
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(aMessage(conversationId: c.id));

      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();
      expect(inbox.emptyState.onlyPendingUndoLeft, isFalse);

      await inbox.deleteConversation(c, t0);

      expect(inbox.rows, isEmpty);
      expect(
        inbox.emptyState.onlyPendingUndoLeft,
        isTrue,
        reason:
            'five seconds of blank behind the snackbar is what INB-15 '
            'says no empty state is',
      );
      expect(
        inbox.emptyState.kind,
        InboxEmptyKind.none,
        reason:
            'none of INB-15\'s three states holds, and *Nothing yet* '
            'would claim there is no history when there is',
      );
      expect(
        inbox.pendingUndo?.conversation.id,
        c.id,
        reason: 'the state\'s one action is Undo, and this is what it needs',
      );

      // The window closes, and now the database really is empty.
      await inbox.forgetPendingUndo(c);
      expect(inbox.emptyState.onlyPendingUndoLeft, isFalse);
      expect(inbox.emptyState.kind, InboxEmptyKind.nothingYet);
    });

    test('a filter that also matches nothing still wins, because clearing it '
        'is the useful action', () async {
      // INB-15 orders its states and the fourth goes last: a selection that
      // matches nothing is a thing the user can undo by tapping `All`, and the
      // pending row comes back into view when they do.
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();
      await inbox.setFilter(<String>{'org.telegram.messenger'});
      await inbox.deleteConversation(c, t0);

      expect(inbox.emptyState.kind, InboxEmptyKind.nothingInFilter);
      expect(inbox.emptyState.onlyPendingUndoLeft, isTrue);
      expect(
        inbox.emptyState.isEmpty,
        isTrue,
        reason: 'a named INB-15 state is drawn and the fourth waits its turn',
      );
    });
  });

  group('INB-25 a message captured while the screen is open', () {
    test('reaches an open list within the second, with no reload', () async {
      final CaptureSignal signal = CaptureSignal();
      final Conversation c = aConversation();
      await repo.insertConversation(c);

      final InboxProvider inbox = InboxProvider(
        repo,
        services,
        captureSignal: signal,
      );
      addTearDown(inbox.dispose);
      await inbox.load();
      expect(inbox.rows.single.unreadCount, 0);

      final ChangeNotifierSpy spy = ChangeNotifierSpy(inbox);
      addTearDown(spy.dispose);
      await nextRebuild(spy, () async {
        await repo.insertMessageIfNew(
          aMessage(conversationId: c.id, text: 'just arrived'),
        );
        signal.captured();
      });

      expect(inbox.rows.single.newestMessage!.text, 'just arrived');
      expect(inbox.rows.single.unreadCount, 1);
    });

    test('reaches an open thread within the second, with no reload', () async {
      final CaptureSignal signal = CaptureSignal();
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(
        aMessage(conversationId: c.id, text: 'first'),
      );

      final ThreadProvider thread = ThreadProvider(
        repo,
        services,
        captureSignal: signal,
        clock: () => t0,
      );
      addTearDown(thread.dispose);
      await thread.open(c.id);
      expect(thread.entries, hasLength(1));

      final ChangeNotifierSpy spy = ChangeNotifierSpy(thread);
      addTearDown(spy.dispose);
      await nextRebuild(spy, () async {
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            text: 'second',
            historyIndex: 1,
            sentAt: t0.add(const Duration(minutes: 1)),
          ),
        );
        signal.captured();
      });

      expect(thread.entries.map((ThreadEntry e) => e.message.text), <String>[
        'first',
        'second',
      ]);
    });
  });

  group('INB-7 and INB-8 the thread', () {
    test('oldest first, with a separator on the first message of each local '
        'day', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      // Two on one local day, one on the next. Built from local time so the
      // test asserts the separator the device would actually draw.
      final DateTime day1 = DateTime(2026, 9, 21, 9).toUtc();
      final DateTime day2 = DateTime(2026, 9, 22, 9).toUtc();
      await repo.insertMessagesIfNew(<Message>[
        aMessage(conversationId: c.id, text: 'morning', sentAt: day1),
        aMessage(
          conversationId: c.id,
          text: 'and again',
          historyIndex: 1,
          sentAt: day1.add(const Duration(hours: 2)),
        ),
        aMessage(
          conversationId: c.id,
          text: 'next day',
          historyIndex: 2,
          sentAt: day2,
        ),
      ]);

      final ThreadProvider thread = ThreadProvider(
        repo,
        services,
        clock: () => t0,
      );
      await thread.open(c.id);

      expect(thread.entries.map((ThreadEntry e) => e.message.text), <String>[
        'morning',
        'and again',
        'next day',
      ]);
      expect(thread.entries.map((ThreadEntry e) => e.startsDay), <bool>[
        true,
        false,
        true,
      ]);
    });

    test(
      "an inbound sender's name shows in a group and nowhere else",
      () async {
        final Conversation group = aConversation(key: 'g', isGroup: true);
        await repo.insertConversation(group);
        await repo.insertMessagesIfNew(<Message>[
          aMessage(conversationId: group.id, sender: 'Grace', text: 'theirs'),
          aMessage(
            conversationId: group.id,
            sender: '',
            text: 'mine',
            direction: Direction.outbound,
            historyIndex: 1,
          ),
          aMessage(
            conversationId: group.id,
            sender: '',
            text: 'nobody said',
            direction: Direction.unknown,
            historyIndex: 2,
          ),
        ]);

        final ThreadProvider thread = ThreadProvider(
          repo,
          services,
          clock: () => t0,
        );
        await thread.open(group.id);
        expect(thread.entries.map((ThreadEntry e) => e.showsSender), <bool>[
          true,
          false,
          false,
        ]);
      },
    );

    test('a thread deleted underneath an open screen comes back empty rather '
        'than stale', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(aMessage(conversationId: c.id));

      final ThreadProvider thread = ThreadProvider(
        repo,
        services,
        clock: () => t0,
      );
      await thread.open(c.id);
      expect(thread.conversation, isNotNull);

      await repo.deleteConversation(c.id, t0);
      await thread.refresh();

      expect(thread.conversation, isNull);
      expect(thread.entries, isEmpty);
      expect(
        thread.conversationGone,
        isTrue,
        reason:
            'empty and deleted are two different things, and a screen told '
            'only the first draws a conversation the app captured nothing '
            'for (product principle 3)',
      );
      expect(
        thread.error,
        isNull,
        reason:
            'nothing failed: the read answered, and the answer is that '
            'the row is gone',
      );
      expect(thread.notice, isNull);

      // Opening something that is still there puts the state back.
      final Conversation other = aConversation(key: 'other');
      await repo.insertConversation(other);
      await thread.open(other.id);
      expect(thread.conversationGone, isFalse);
    });

    test('a thread longer than the window says so, beside the date its '
        'history begins (INB-10)', () async {
      // The defect this is written against: the notice names the date the app
      // could first have seen anything for this conversation — deliberately
      // read past the window — and the thread then draws nothing at all for
      // the span between that date and its oldest drawn message. A date on
      // screen with a blank under it is what INB-10 exists to prevent.
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      final Batch batch = (await db.database).batch();
      // Two on the very first instant, so the window's edge falls on a tie.
      // Ties are real (INB-4), and comparing the oldest stored time against
      // the oldest drawn one cannot see a message hidden behind one.
      for (int i = 0; i <= Repository.threadWindow; i++) {
        batch.insert(
          'messages',
          aMessage(
            conversationId: c.id,
            text: 'message $i',
            historyIndex: i,
            notificationKey: 'notif-$i',
            sentAt: t0.add(Duration(minutes: i == 0 ? 0 : i - 1)),
          ).toMap(),
        );
      }
      await batch.commit(noResult: true);
      await repo.installedAt(t0.subtract(const Duration(days: 30)));

      final ThreadProvider thread = ThreadProvider(
        repo,
        services,
        clock: () => t0,
      );
      await thread.open(c.id);

      expect(thread.entries, hasLength(Repository.threadWindow));
      expect(
        thread.entries.first.message.text,
        'message 1',
        reason:
            'the window is the newest 500, and message 0 shares an '
            'instant with message 1',
      );
      expect(thread.isWindowed, isTrue);
      final ThreadHistoryNotice notice = thread.notice!;
      expect(notice.hidesOlderMessages, isTrue);
      expect(notice.windowSize, Repository.threadWindow);
      expect(notice.oldestShownAt, thread.entries.first.message.sentAt);
      expect(
        notice.since.isBefore(notice.oldestShownAt!),
        isTrue,
        reason:
            'the date the notice prints is earlier than anything drawn, '
            'which is exactly why the window has to be stated with it',
      );
    });

    test('a thread that fits in the window hides nothing and says nothing '
        'about one', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(aMessage(conversationId: c.id));

      final ThreadProvider thread = ThreadProvider(
        repo,
        services,
        clock: () => t0,
      );
      await thread.open(c.id);

      expect(thread.isWindowed, isFalse);
      expect(thread.notice!.hidesOlderMessages, isFalse);
      expect(thread.notice!.oldestShownAt, isNull);
    });

    test('a thread from an app whose row is off says so (INB-22)', () async {
      await repo.upsertSeenApp(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabledIfNew: false,
        at: t0,
      );
      final Conversation c = aConversation();
      await repo.insertConversation(c);

      final ThreadProvider thread = ThreadProvider(
        repo,
        services,
        clock: () => t0,
      );
      await thread.open(c.id);
      expect(thread.sourceAppEnabled, isFalse);
    });
  });

  group('INB-5 opening a thread', () {
    test('advances the read marker to the newest message the conversation '
        'holds, and only forward', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      final DateTime newest = t0.add(const Duration(minutes: 5));
      await repo.insertMessagesIfNew(<Message>[
        aMessage(conversationId: c.id, text: 'old'),
        aMessage(
          conversationId: c.id,
          text: 'new',
          historyIndex: 1,
          sentAt: newest,
        ),
      ]);

      final InboxProvider inbox = InboxProvider(repo, services);
      await inbox.load();
      expect(inbox.rows.single.unreadCount, 2);

      final ThreadProvider thread = ThreadProvider(
        repo,
        services,
        clock: () => t0.add(const Duration(hours: 1)),
      );
      await thread.open(c.id);

      expect(thread.conversation!.readThroughAt, newest);
      await inbox.load();
      expect(inbox.rows.single.unreadCount, 0);

      // A late removal for an older notification must not un-read anything
      // (CAP-22).
      await repo.markReadThrough(
        conversationId: c.id,
        through: t0,
        at: t0.add(const Duration(hours: 2)),
      );
      expect((await repo.conversationById(c.id))!.readThroughAt, newest);
    });
  });

  group('INB-10 the standing notice', () {
    test('names the latest of the three dates', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.insertMessageIfNew(
        aMessage(conversationId: c.id, sentAt: t0.add(const Duration(days: 2))),
      );

      await repo.installedAt(t0);
      await repo.openCaptureSession(t0.add(const Duration(hours: 1)));
      // The app's own switch went on later still, so that is the date: nothing
      // from this conversation could have been seen before it (CAP-1).
      await repo.upsertSeenApp(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabledIfNew: false,
        at: t0,
      );
      await repo.setAppEnabled(
        'com.whatsapp',
        enabled: true,
        at: t0.add(const Duration(hours: 4)),
      );

      final ThreadProvider thread = ThreadProvider(
        repo,
        services,
        clock: () => t0.add(const Duration(days: 3)),
      );
      await thread.open(c.id);

      final ThreadHistoryNotice notice = thread.notice!;
      expect(notice.historyBegins, t0.add(const Duration(hours: 4)));
      expect(notice.begins, ThreadHistoryStart.appCaptureSession);
      expect(
        notice.accessOffUntilBegins,
        isFalse,
        reason: 'the listener was already bound an hour after install',
      );
      expect(notice.since, notice.historyBegins);
    });

    test(
      'says access was off until then where no session came first',
      () async {
        final Conversation c = aConversation();
        await repo.insertConversation(c);
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sentAt: t0.add(const Duration(days: 1)),
          ),
        );
        await repo.installedAt(t0);
        await repo.openCaptureSession(t0.add(const Duration(hours: 6)));

        final ThreadProvider thread = ThreadProvider(
          repo,
          services,
          clock: () => t0.add(const Duration(days: 2)),
        );
        await thread.open(c.id);

        expect(thread.notice!.historyBegins, t0.add(const Duration(hours: 6)));
        expect(thread.notice!.begins, ThreadHistoryStart.captureSession);
        expect(thread.notice!.accessOffUntilBegins, isTrue);
      },
    );

    test('names the most recent overlapping gap and counts the others, and '
        'never a rebind at boot', () async {
      final Conversation c = aConversation();
      await repo.insertConversation(c);
      await repo.installedAt(t0);
      await repo.openCaptureSession(t0);

      // The thread spans days 0 to 5.
      await repo.insertMessagesIfNew(<Message>[
        aMessage(conversationId: c.id, text: 'first', sentAt: t0),
        aMessage(
          conversationId: c.id,
          text: 'last',
          historyIndex: 1,
          sentAt: t0.add(const Duration(days: 5)),
        ),
      ]);

      // Two real absences inside that range, and one rebind of thirty seconds.
      await repo.closeCaptureSession(t0.add(const Duration(days: 1)));
      await repo.openCaptureSession(t0.add(const Duration(days: 2)));
      await repo.closeCaptureSession(t0.add(const Duration(days: 3)));
      await repo.openCaptureSession(
        t0.add(const Duration(days: 3, seconds: 30)),
      );
      await repo.closeCaptureSession(t0.add(const Duration(days: 3, hours: 1)));
      await repo.openCaptureSession(t0.add(const Duration(days: 4)));

      final ThreadProvider thread = ThreadProvider(
        repo,
        services,
        clock: () => t0.add(const Duration(days: 6)),
      );
      await thread.open(c.id);

      final ThreadHistoryNotice notice = thread.notice!;
      expect(notice.hasGap, isTrue);
      expect(
        notice.mostRecentGap!.from,
        t0.add(const Duration(days: 3, hours: 1)),
      );
      expect(notice.mostRecentGap!.to, t0.add(const Duration(days: 4)));
      expect(
        notice.otherGapCount,
        1,
        reason: 'the thirty-second rebind is no absence anyone noticed',
      );
    });

    test(
      "a gap that ended before the thread's oldest message is named nowhere",
      () async {
        final Conversation c = aConversation();
        await repo.insertConversation(c);
        await repo.installedAt(t0);
        // The absence is real, and it took nothing from this thread: the
        // conversation had not started. Naming it above this thread would tell
        // the user they lost messages from it.
        await repo.openCaptureSession(t0);
        await repo.closeCaptureSession(t0.add(const Duration(hours: 1)));
        await repo.openCaptureSession(t0.add(const Duration(days: 1)));
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sentAt: t0.add(const Duration(days: 2)),
          ),
        );

        final ThreadProvider thread = ThreadProvider(
          repo,
          services,
          clock: () => t0.add(const Duration(days: 3)),
        );
        await thread.open(c.id);

        expect(thread.notice!.hasGap, isFalse);
        expect(thread.notice!.otherGapCount, 0);
      },
    );
  });

  group('INB-21 the included-apps list', () {
    test('one row in each group gives one exact order', () async {
      // Group 1: on, with a conversation.
      await repo.upsertSeenApp(
        package: 'com.whatsapp',
        label: 'WhatsApp',
        enabledIfNew: true,
        at: t0,
      );
      await repo.insertConversation(aConversation());
      // Group 2: on, nothing captured.
      await repo.upsertSeenApp(
        package: 'org.telegram.messenger',
        label: 'Telegram',
        enabledIfNew: true,
        at: t0,
      );
      // Group 3: off, and seen posting.
      await repo.upsertSeenApp(
        package: 'com.example.shopping',
        label: 'Shopping',
        enabledIfNew: false,
        at: t0,
      );
      // Group 4: off, and never seen posting — a switch the user moved on a
      // shipped row before the app ever posted.
      await repo.setAppEnabled(
        'com.instagram.android',
        enabled: false,
        at: t0,
        labelIfNew: 'com.instagram.android',
      );

      final AppsProvider apps = AppsProvider(repo, services);
      await apps.load();

      // The other three shipped packages are here too, in the second group and
      // ordered among themselves — INB-20 says the list is built from the
      // shipped set as well as from what the listener has seen. This test is
      // about the four groups, so it reads the four rows it seeded in the order
      // the whole list puts them.
      const Set<String> seeded = <String>{
        'com.whatsapp',
        'org.telegram.messenger',
        'com.example.shopping',
        'com.instagram.android',
      };
      final List<IncludedApp> listed = <IncludedApp>[
        for (final IncludedApp a in apps.apps)
          if (seeded.contains(a.package)) a,
      ];
      expect(listed.map((IncludedApp a) => a.package), <String>[
        'com.whatsapp',
        'org.telegram.messenger',
        'com.example.shopping',
        'com.instagram.android',
      ]);
      expect(listed.map((IncludedApp a) => a.group), <AppGroup>[
        AppGroup.onWithMessages,
        AppGroup.onWithNothing,
        AppGroup.offAndSeen,
        AppGroup.rest,
      ]);
      expect(listed.first.conversationCount, 1);
      expect(listed[1].hasCaptured, isFalse);
      expect(
        listed.last.lastSeenAt,
        isNull,
        reason: 'the fourth group is the one the listener has never seen post',
      );

      // And the second group really is alphabetical across everything in it,
      // not just the seeded row: the three untouched shipped packages sort by
      // the only name the app has for them.
      expect(
        apps.apps
            .where((IncludedApp a) => a.group == AppGroup.onWithNothing)
            .map((IncludedApp a) => a.package),
        <String>[
          'com.facebook.orca',
          'com.google.android.apps.messaging',
          'org.thoughtcrime.securesms',
          'org.telegram.messenger',
        ],
      );
    });

    test(
      'at first launch every shipped row sits in the second group',
      () async {
        final AppsProvider apps = AppsProvider(repo, services);
        await apps.load();

        expect(apps.apps, hasLength(6));
        expect(
          apps.apps.every((IncludedApp a) => a.group == AppGroup.onWithNothing),
          isTrue,
        );
        expect(apps.apps.every((IncludedApp a) => a.enabled), isTrue);
        expect(
          apps.showsSearchField,
          isFalse,
          reason: 'six rows is not more than ten',
        );
      },
    );

    test(
      'the switch writes the row and pushes the filter down in one step',
      () async {
        final AppsProvider apps = AppsProvider(repo, services);
        await apps.load();

        await apps.setEnabled('com.whatsapp', enabled: false, now: t0);

        final NoopCaptureFilter filter =
            services.captureFilter as NoopCaptureFilter;
        expect(filter.lastPushed, isEmpty);
        expect(filter.lastPushedKnown, contains('com.whatsapp'));
        expect(
          apps.apps
              .firstWhere((IncludedApp a) => a.package == 'com.whatsapp')
              .enabled,
          isFalse,
        );
      },
    );

    test('turning a row on tells the listener at once, not at the next '
        'resume', () async {
      // The ON direction of the same push, and the one that loses messages
      // rather than leaking them: the user switches an app on and locks the
      // phone, and until the listener hears it CAP-1 drops what that app posts
      // *before the queue* — dropped there is gone, not late. INB-22 promises
      // capture from the moment the switch moves.
      await repo.upsertSeenApp(
        package: 'com.example.shopping',
        label: 'Shopping',
        enabledIfNew: false,
        at: t0,
      );
      final AppsProvider apps = AppsProvider(repo, services);
      await apps.load();

      await apps.setEnabled('com.example.shopping', enabled: true, now: t0);

      final NoopCaptureFilter filter =
          services.captureFilter as NoopCaptureFilter;
      expect(filter.pushes, 1);
      expect(filter.lastPushed, contains('com.example.shopping'));
      // Every package the table holds a row for goes down beside the enabled
      // set, or the listener is free to treat a row it was not told about as a
      // pending first sighting and keep capturing from it (CAP-1).
      expect(filter.lastPushedKnown, contains('com.example.shopping'));
      expect(apps.error, isNull);
      expect(
        apps.apps
            .firstWhere((IncludedApp a) => a.package == 'com.example.shopping')
            .enabled,
        isTrue,
      );
    });

    test('a filter that never heard the switch is said, and stays said '
        '(INB-22)', () async {
      // The worst failure in the area and the one nothing on screen betrays:
      // the switch moved, the row on disk moved, and CAP-1's filter is still
      // dropping that package before the queue. Messages lost, not delayed.
      final _FailingCaptureFilter filter = _FailingCaptureFilter();
      final CaptureSignal signal = CaptureSignal();
      addTearDown(signal.dispose);
      final DeviceServices failing = DeviceServices(
        notifications: const NoopNotificationSource(),
        captureFilter: filter,
        packages: const NoopPackageInfoService(),
        reply: const NoopReplyService(),
        launcher: const NoopAppLauncher(),
        reminders: const NoopReminderScheduler(),
        entitlements: const NoopEntitlements(),
        appLock: const NoopAppLock(),
      );

      final AppsProvider apps = AppsProvider(
        repo,
        failing,
        captureSignal: signal,
      );
      await apps.load();
      await apps.setEnabled('com.whatsapp', enabled: true, now: t0);

      expect(apps.captureFilterFailure?.kind, FailureKind.captureFilter);
      expect(apps.captureFilterFailure?.package, 'com.whatsapp');
      expect(
        (await repo.appByPackage('com.whatsapp'))!.enabled,
        isTrue,
        reason: 'the database keeps the write: it is the authority',
      );

      // Any other app posting anything runs a read that succeeds, and before
      // this the read cleared the failure — so the one state that means
      // messages are being lost was wiped by an unrelated message arriving,
      // usually before a screen ever drew it.
      signal.captured();
      await Future<void>.delayed(Duration.zero);
      await apps.refresh();
      expect(
        apps.captureFilterFailure?.kind,
        FailureKind.captureFilter,
        reason: 'a read that succeeded says nothing about the filter',
      );
      expect(apps.error?.kind, FailureKind.captureFilter);

      // The action for it, and the only thing that clears it.
      filter.throwing = false;
      await apps.retryCaptureFilter();
      expect(apps.captureFilterFailure, isNull);
      expect(apps.error, isNull);
      expect(filter.lastPushed, contains('com.whatsapp'));
    });

    test(
      "removing an app's stored messages is one step with one Undo",
      () async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        final Conversation a = aConversation(key: 'a');
        final Conversation b = aConversation(key: 'b');
        for (final Conversation c in <Conversation>[a, b]) {
          await repo.insertConversation(c);
          await repo.insertMessageIfNew(aMessage(conversationId: c.id));
        }

        final AppsProvider apps = AppsProvider(repo, services);
        await apps.load();

        final ({DateTime deletedAt, int conversations})? removed = await apps
            .removeCaptured('com.whatsapp', t0);
        expect(removed!.conversations, 2);
        expect(await repo.conversations(), isEmpty);
        expect(
          apps.apps
              .firstWhere((IncludedApp a) => a.package == 'com.whatsapp')
              .conversationCount,
          0,
        );
        expect(
          apps.apps
              .firstWhere((IncludedApp a) => a.package == 'com.whatsapp')
              .enabled,
          isTrue,
          reason: 'removing the messages is not turning the switch off',
        );

        await apps.undoRemoveCaptured('com.whatsapp', removed.deletedAt);
        expect(await repo.conversations(), hasLength(2));
        expect((await repo.messages(a.id)), hasLength(1));
      },
    );
  });
}

/// A listener that will not take the set, which is what an unbound listener
/// looks like from Dart (INB-22).
class _FailingCaptureFilter implements CaptureFilter {
  bool throwing = true;
  List<String>? lastPushed;

  @override
  Future<void> setEnabledPackages(
    List<String> packages,
    List<String> known,
  ) async {
    if (throwing) throw StateError('no listener bound');
    lastPushed = List<String>.unmodifiable(packages);
  }
}

/// Waits on a [ChangeNotifier]'s next notification, so a test asserts that a
/// provider rebuilt rather than sleeping and hoping.
class ChangeNotifierSpy {
  ChangeNotifierSpy(this._notifier) {
    _notifier.addListener(_onNotified);
  }

  final ChangeNotifier _notifier;
  Completer<void>? _waiting;

  /// A future that completes on the next notification after this is read.
  Future<void> get next {
    final Completer<void> completer = Completer<void>();
    _waiting = completer;
    return completer.future;
  }

  void _onNotified() {
    final Completer<void>? waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) {
      _waiting = null;
      waiting.complete();
    }
  }

  void dispose() => _notifier.removeListener(_onNotified);
}
