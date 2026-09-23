/// The conversation list on screen (INB-1 to INB-6, INB-12 to INB-15,
/// INB-18, INB-23, INB-24).
///
/// Every assertion here is about what a person would see: the words on the
/// screen, the order they are in, and how many taps it took to get there. A
/// test that only proved a widget exists would pass on a row that draws an
/// empty string, which is the failure a list assembled out of notifications is
/// most likely to have.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/l10n/app_localizations.dart';
import 'package:replybox/main.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:replybox/models/source_app.dart';
import 'package:replybox/providers/apps_provider.dart';
import 'package:replybox/providers/inbox_provider.dart';
import 'package:replybox/providers/permissions_provider.dart';
import 'package:replybox/screens/inbox_screen.dart';
import 'package:replybox/screens/included_apps_screen.dart';
import 'package:replybox/screens/thread_screen.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:replybox/services/services.dart';
import 'package:replybox/widgets/app_filter_chips.dart';
import 'package:replybox/widgets/conversation_row.dart';
import 'package:replybox/widgets/inbox_empty_states.dart';
import 'package:replybox/widgets/source_app.dart';

import 'helpers.dart';

void main() {
  setUpAll(initTestDatabases);

  late Repository repo;
  late DBHelper db;

  /// The database is real and does real asynchronous work, so every seeding
  /// step has to happen outside the fake clock a widget test installs.
  /// Awaiting a database call straight from a `testWidgets` body hangs until
  /// the ten-minute timeout — the trap this whole file is arranged around.
  Future<void> seed(
    WidgetTester tester,
    Future<void> Function(Repository repo) write,
  ) async {
    await tester.runAsync(() => write(repo));
  }

  setUp(() async {
    db = testDb();
    repo = Repository(db);
    // A phone that has been through onboarding. PERM-4 pushes the disclosure
    // over the first screen without a tap exactly once per install, and this
    // file pumps `ReplyboxApp` on a fresh database nineteen times — so without
    // these two stamps every test here would be racing that push, and the list
    // it is asserting about would be the offstage route underneath it.
    //
    // The two facts unlock nothing (PERM-5): they record that two screens were
    // once displayed. Written here, in the real zone, because a database call
    // awaited from inside a `testWidgets` body hangs on the faked clock.
    await repo.markDisclosureShown(DateTime.utc(2026, 9, 1));
    await repo.markBatteryGuidanceShown(DateTime.utc(2026, 9, 1));
  });

  tearDown(() async => db.close());

  group('the conversation list', () {
    testWidgets('INB-18 replying is two taps and clearing is one, counted on '
        'a seeded list from a cold start', (WidgetTester tester) async {
      // The rule asks for the taps to be counted rather than for the controls
      // to be found, so every tap goes through one counter and the count is
      // what is asserted. Typing, scrolling, the reveal swipe and dismissing a
      // snackbar are not taps and never touch it.
      final _Launches launches = _Launches();
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'are we still on for six'),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(
          repository: repo,
          services: _services(launcher: launches, identities: _whatsappHere),
        ),
      );
      // INB-19: the list is the whole first screen, so a cold start opens on
      // the tab the conversation is on and nothing is scrolled.
      await _until(tester, find.text('Ada Lovelace'));

      int taps = 0;

      taps++;
      await tester.tap(find.text('Ada Lovelace'));
      await _openedThread(tester, find.text('Open WhatsApp'));

      // Until area REP ships, INB-13's control is the second tap of the reply
      // path, and it sits where the reply field will be.
      taps++;
      await tester.tap(find.text('Open WhatsApp'));
      await _settle(tester);

      expect(taps, 2, reason: 'INB-18: replying is two taps');
      expect(launches.opened, <String>['com.whatsapp']);
      // INB-18: no confirmation dialog stands after either path.
      expect(find.byType(AlertDialog), findsNothing);

      // Back to the list for the clearing half, which INB-18 counts from the
      // same screen. Getting back there is not part of either count.
      await tester.pageBack();
      await _settle(tester);

      taps = 0;
      // The swipe that reveals Delete is not a tap.
      await tester.drag(find.text('Ada Lovelace'), const Offset(-200, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Delete'), findsOneWidget);

      taps++;
      await tester.tap(find.text('Delete'));
      await _until(tester, find.text('Conversation deleted'));

      expect(taps, 1, reason: 'INB-18: clearing is one tap');
      expect(find.text('Ada Lovelace'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      // Undo is the optional second tap; dismissing the snackbar is not a tap.
      expect(find.text('Undo'), findsOneWidget);

      await _closeSnackBar(tester);
    });

    testWidgets('INB-4 and INB-7 two reads of rows and messages that share one '
        'timestamp come back in the same order', (WidgetTester tester) async {
      // The spike's burst put five messages under one identical time, so the
      // tie is real data rather than a hypothetical: INB-4 breaks it by
      // `created_at` descending then `id` ascending, and INB-7 breaks the
      // thread's by `created_at`, then the history index, then `id`.
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(
          id: 'conv-a',
          key: 'ada',
          title: 'Ada Lovelace',
        );
        final Conversation grace = aConversation(
          id: 'conv-b',
          key: 'grace',
          title: 'Grace Hopper',
        );
        await repo.insertConversation(ada);
        await repo.insertConversation(grace);
        // Two notifications sharing one `sent_at`, in one thread.
        await repo.insertMessageIfNew(
          aMessage(
            id: 'msg-b',
            conversationId: ada.id,
            text: 'second under the same clock',
            notificationKey: 'notif-2',
          ),
        );
        await repo.insertMessageIfNew(
          aMessage(
            id: 'msg-a',
            conversationId: ada.id,
            text: 'first under the same clock',
            notificationKey: 'notif-1',
          ),
        );
        await repo.insertMessageIfNew(
          aMessage(conversationId: grace.id, sender: 'Grace', text: 'hello'),
        );
      });

      const List<String> titles = <String>['Ada Lovelace', 'Grace Hopper'];
      const List<String> lines = <String>[
        'first under the same clock',
        'second under the same clock',
      ];

      List<String> listOrder = const <String>[];
      List<String> threadOrder = const <String>[];

      for (int read = 0; read < 2; read++) {
        await tester.pumpWidget(
          ReplyboxApp(
            key: ValueKey<int>(read),
            repository: repo,
            services: _services(),
          ),
        );
        await _until(tester, find.text('Ada Lovelace'));
        final List<String> seenList = _topToBottom(tester, titles);

        await tester.tap(find.text('Ada Lovelace'));
        await _openedThread(tester, find.text('first under the same clock'));
        final List<String> seenThread = _topToBottom(tester, lines);

        if (read == 0) {
          listOrder = seenList;
          threadOrder = seenThread;
        } else {
          expect(seenList, listOrder, reason: 'INB-4: two reads, one order');
          expect(
            seenThread,
            threadOrder,
            reason: 'INB-7: two reads, one order',
          );
        }

        await tester.pageBack();
        await _settle(tester);
      }

      // And it is the order the rules fix, not a stable accident: equal
      // `last_message_at` and equal `created_at` leave `id` ascending.
      expect(listOrder, <String>['Ada Lovelace', 'Grace Hopper']);
      // INB-7: oldest at the top.
      expect(threadOrder, <String>[
        'first under the same clock',
        'second under the same clock',
      ]);
    });

    testWidgets('INB-5 two reads of a hidden message produce the same count', (
      WidgetTester tester,
    ) async {
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        // CAP-8: the phone hid the contents, so there is no text and no
        // sender. INB-5 counts it by the notification's post time all the same.
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: ada.id,
            sender: '',
            kind: MessageKind.hidden,
          ),
        );
      });

      for (int read = 0; read < 2; read++) {
        await tester.pumpWidget(
          ReplyboxApp(
            key: ValueKey<int>(read),
            repository: repo,
            services: _services(),
          ),
        );
        await _until(tester, find.text('Ada Lovelace'));

        expect(find.text('1'), findsOneWidget, reason: 'INB-5: one unread');
        // INB-3: the row's preview is the message-files line, never the
        // system's marker text and never the emptied sender.
        expect(
          find.text(
            'Your phone hid this message. Open it in the app it came from.',
          ),
          findsOneWidget,
        );
      }
    });

    testWidgets('INB-2 a conversation that arrived without a name is titled '
        'with its app and says so', (WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        final Conversation unnamed = aConversation(title: '');
        await repo.insertConversation(unnamed);
        await repo.insertMessageIfNew(
          aMessage(conversationId: unnamed.id, text: 'see you there'),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(
        tester,
        find.text('This conversation arrived without a name'),
      );

      // Titled with the source app's name — the only name the app holds.
      expect(find.text('WhatsApp'), findsWidgets);
      expect(find.text('see you there'), findsOneWidget);
    });

    testWidgets("INB-12 a raw conversation previews the notification's own "
        'title and text', (WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.example.parcels',
          label: 'Parcels',
          enabledIfNew: true,
          at: t0,
        );
        final Conversation raw = aConversation(
          package: 'com.example.parcels',
          key: 'com.example.parcels',
          keySource: KeySource.package,
          title: '',
        );
        await repo.insertConversation(raw);
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: raw.id,
            sender: 'Out for delivery',
            text: 'Arriving by 18:00',
            kind: MessageKind.raw,
          ),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      // INB-12: the notification's title and text joined by the message file's
      // separator, under a title that is the app's name.
      await _until(tester, find.text('Out for delivery — Arriving by 18:00'));
      expect(find.text('Parcels'), findsWidgets);
    });

    testWidgets('INB-6 a swipe reveals Delete, the tap clears the row, and '
        'Undo puts it back', (WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'the engine works'),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('Ada Lovelace'));

      // Nothing is revealed until the swipe: a Delete control sitting under
      // every closed row is one a screen reader finds on all of them.
      expect(find.text('Delete'), findsNothing);

      await tester.drag(find.text('Ada Lovelace'), const Offset(-200, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // INB-6: one control and nothing else.
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await _until(tester, find.text('Conversation deleted'));
      expect(find.text('Ada Lovelace'), findsNothing);
      expect(find.text('the engine works'), findsNothing);

      // The snackbar animates in, so the tap has to wait for it to land.
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.text('Undo'));
      await _until(tester, find.text('Ada Lovelace'));
      expect(find.text('the engine works'), findsOneWidget);

      await _closeSnackBar(tester);
    });

    testWidgets('INB-14 the chip row pins All at the leading edge and names '
        'each app', (WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'hello'),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('Ada Lovelace'));

      expect(find.text('All'), findsOneWidget);
      expect(find.text('WhatsApp'), findsOneWidget);
      // Pinned at the leading edge, which is the left in English (INB-23).
      expect(
        tester.getTopLeft(find.text('All')).dx,
        lessThan(tester.getTopLeft(find.text('WhatsApp')).dx),
      );
    });
  });

  group('INB-15 empty states', () {
    testWidgets('Nothing yet says what it has, and its one action opens the '
        'included-apps list', (WidgetTester tester) async {
      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('Nothing yet'));

      expect(
        find.text(
          'Nothing yet. Messages from the apps you have included will appear '
          'here.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Only messages that arrive from now on can appear. There is none '
          'from before Replybox was installed.',
        ),
        findsOneWidget,
      );
      // Exactly one action, and it is not blank (INB-15).
      expect(_buttons, findsOneWidget);
      expect(find.text('See included apps'), findsOneWidget);

      await tester.tap(find.text('See included apps'));
      await _until(tester, find.text('Included apps'));
      // Let its read finish before the tree comes down: the same provider also
      // notifies after being disposed when a read is still in flight.
      await _settle(tester);

      // The screen it opens starts its first read from `didChangeDependencies`
      // and its provider notifies synchronously, so the framework reports a
      // build-time `setState` every time it is opened. That is its own defect
      // and its own failing test, in `included_apps_test.dart`; it is drained
      // here so this test fails only on its own subject.
      while (tester.takeException() != null) {}
    });

    testWidgets('Nothing in this filter names the selected app, and its one '
        'action puts every app back', (WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        await repo.upsertSeenApp(
          package: 'org.telegram.messenger',
          label: 'Telegram',
          enabledIfNew: true,
          at: t0,
        );
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        final Conversation kurt = aConversation(
          package: 'org.telegram.messenger',
          key: 'kurt',
          title: 'Kurt Gödel',
        );
        await repo.insertConversation(ada);
        await repo.insertConversation(kurt);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'hello'),
        );
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: kurt.id,
            sender: 'Kurt',
            text: 'incomplete',
            notificationKey: 'notif-2',
          ),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('Kurt Gödel'));

      // Filter to Telegram, then clear its one conversation. INB-14 keeps a
      // selected chip in the row after its app's last conversation goes, which
      // is the only way this state is reachable at all.
      await tester.tap(find.text('Telegram'));
      await _settle(tester);
      expect(find.text('Ada Lovelace'), findsNothing);

      await tester.drag(find.text('Kurt Gödel'), const Offset(-200, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Delete'));

      await _until(tester, find.text('Nothing in this filter'));
      expect(find.text('No conversations from Telegram.'), findsOneWidget);
      expect(find.text('Show all'), findsOneWidget);

      await tester.tap(find.text('Show all'));
      await _until(tester, find.text('Ada Lovelace'));

      await _closeSnackBar(tester);
    });

    testWidgets("No results keeps INB-15's shape: a title, and exactly one "
        'action', (WidgetTester tester) async {
      // No screen reaches this one today — area SRCH is what produces a search
      // that returns nothing — so the state is drawn directly. INB-15 still
      // fixes that it has a title, exactly one action, and no blank.
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: InboxEmptyStates(
              state: const InboxEmptyState(kind: InboxEmptyKind.noResults),
              onSeeIncludedApps: () {},
              onClearFilter: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('No results'), findsOneWidget);
      expect(find.text('Clear search'), findsOneWidget);
      expect(_buttons, findsOneWidget);
    });
  });

  group('INB-23 the list at 1.3x text, mirrored, and reachable', () {
    /// A phone-size screen, in logical pixels, for every test in this group.
    ///
    /// INB-23 names a phone, and a phone is where the rule can actually fail:
    /// the 800x600 a widget test defaults to is wider than any of them, so a
    /// row that overflows on a phone lays out comfortably on it.
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    /// The list, filled, in one direction and text scale.
    Future<void> show(
      WidgetTester tester, {
      required bool rtl,
      double textScale = 1.3,
    }) async {
      await tester.pumpWidget(
        _screenHost(
          repository: repo,
          services: _services(),
          rtl: rtl,
          textScale: textScale,
          home: InboxScreen(
            onOpenConversation: (BuildContext _, Conversation _) {},
            onOpenIncludedApps: (BuildContext _) {},
          ),
        ),
      );
    }

    testWidgets('a filled list draws every row inside a phone screen at 1.3x, '
        'in words a longer language would need', (WidgetTester tester) async {
      phone(tester);
      const _Long w = _Long.german;
      await seed(tester, (Repository repo) => _seedBusyList(repo, w));

      await show(tester, rtl: false);
      await _until(tester, find.text(w.title));

      final AppLocalizations l10n = _l10n(tester);
      final String preview = l10n.conversationPreviewWithSender(
        w.sender,
        w.newest,
      );

      // The row is populated, not an empty state: both conversations, the
      // sender-prefixed preview INB-1 asks for, and INB-5's count past 99.
      expect(find.text(w.title), findsOneWidget);
      expect(find.text(w.otherTitle), findsOneWidget);
      expect(find.text(preview), findsOneWidget);
      expect(find.text(l10n.unreadCountOverflow), findsOneWidget);

      // INB-23: it fails on overflow, and nothing the row draws may run off
      // the side of the screen.
      _fitsThePhone(tester, <String>[
        w.title,
        w.otherTitle,
        preview,
        l10n.unreadCountOverflow,
      ]);

      // INB-1: the preview is one line, truncated with an ellipsis rather than
      // wrapped — the ellipsis is what keeps the row a row at 1.3x.
      final RenderParagraph line = tester.renderObject<RenderParagraph>(
        find.text(preview),
      );
      expect(
        line.didExceedMaxLines,
        isTrue,
        reason: 'INB-1: the long preview was not truncated',
      );
      expect(
        tester.getSize(find.text(preview)).height,
        lessThan(2 * line.preferredLineHeight),
      );
    });

    testWidgets("INB-1 the row's leading circle and trailing count swap sides "
        'between a left-to-right and a right-to-left language', (
      WidgetTester tester,
    ) async {
      phone(tester);
      const _Long w = _Long.arabic;
      await seed(tester, (Repository repo) => _seedBusyList(repo, w));

      await show(tester, rtl: false);
      await _until(tester, find.text(w.title));
      final AppLocalizations l10n = _l10n(tester);
      final ({double circle, double title, double count}) ltr = (
        circle: tester.getTopLeft(find.byType(SourceAppAvatar).first).dx,
        title: tester.getTopLeft(find.text(w.title)).dx,
        count: tester.getTopLeft(find.text(l10n.unreadCountOverflow)).dx,
      );
      // Left to right: the circle leads on the left, the count trails on the
      // right, and the title sits between them (INB-1).
      expect(ltr.circle, lessThan(ltr.title));
      expect(ltr.count, greaterThan(ltr.title));

      await show(tester, rtl: true);
      await _until(tester, find.text(w.title));
      final ({double circle, double title, double count}) rtl = (
        circle: tester.getTopLeft(find.byType(SourceAppAvatar).first).dx,
        title: tester.getTopLeft(find.text(w.title)).dx,
        count: tester.getTopLeft(find.text(l10n.unreadCountOverflow)).dx,
      );
      // INB-23: both mirror. Asserting the pair swapped, rather than each
      // side on its own, is what makes this a mirror test — a layout that
      // hard-coded the right-hand side would satisfy one half of it.
      expect(
        rtl.circle,
        greaterThan(rtl.title),
        reason: 'INB-23: the leading circle did not mirror',
      );
      expect(
        rtl.count,
        lessThan(rtl.title),
        reason: 'INB-23: the trailing count did not mirror',
      );

      // INB-23: the number inside the mirrored row stays left to right, so a
      // count never reads back to front.
      expect(
        tester.widget<Text>(find.text(l10n.unreadCountOverflow)).textDirection,
        TextDirection.ltr,
      );
      _fitsThePhone(tester, <String>[w.title, l10n.unreadCountOverflow]);
    });

    testWidgets('INB-14 the chip row pins All at the leading edge of whichever '
        'language it is drawn in', (WidgetTester tester) async {
      phone(tester);
      const _Long w = _Long.arabic;
      await seed(tester, (Repository repo) => _seedBusyList(repo, w));

      await show(tester, rtl: false);
      await _until(tester, find.text(w.title));
      final AppLocalizations l10n = _l10n(tester);
      expect(
        tester.getTopLeft(find.text(l10n.filterAll)).dx,
        lessThan(tester.getTopLeft(find.text(w.app)).dx),
      );

      await show(tester, rtl: true);
      await _until(tester, find.text(w.title));
      // INB-23: `All` is pinned where the language puts "first", which is the
      // right-hand edge here.
      expect(
        tester.getTopLeft(find.text(l10n.filterAll)).dx,
        greaterThan(tester.getTopLeft(find.text(w.app)).dx),
        reason: 'INB-23: the chip row did not mirror',
      );
    });

    testWidgets('INB-6 the swipe that reveals Delete mirrors, and the wrong '
        'way round reveals nothing', (WidgetTester tester) async {
      phone(tester);
      const _Long w = _Long.arabic;
      await seed(tester, (Repository repo) => _seedBusyList(repo, w));

      await show(tester, rtl: false);
      await _until(tester, find.text(w.title));
      final AppLocalizations l10n = _l10n(tester);
      final String delete = l10n.deleteConversation;

      // Left to right the row slides towards the leading edge, so the drag
      // goes left and the control is revealed at the right.
      await _drag(tester, find.text(w.title), -200);
      expect(find.text(delete), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(delete)).dx,
        greaterThan(tester.getTopLeft(find.text(w.title)).dx),
      );

      await show(tester, rtl: true);
      await _until(tester, find.text(w.title));

      // The same drag, unmirrored, must do nothing: if a left-hand drag still
      // opened the row, the gesture would not have mirrored at all and the
      // assertion below would pass on an accident.
      await _drag(tester, find.text(w.title), -200);
      expect(
        find.text(delete),
        findsNothing,
        reason: 'INB-23: the swipe direction did not mirror',
      );

      await _drag(tester, find.text(w.title), 200);
      expect(find.text(delete), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(delete)).dx,
        lessThan(tester.getTopLeft(find.text(w.title)).dx),
        reason: 'INB-23: Delete was not revealed at the mirrored edge',
      );
    });

    testWidgets('every control the list names is at least 48dp on its shorter '
        'side, measured on a phone screen at 1.3x', (
      WidgetTester tester,
    ) async {
      phone(tester);
      const _Long w = _Long.german;
      await seed(tester, (Repository repo) => _seedBusyList(repo, w));

      await show(tester, rtl: false);
      await _until(tester, find.text(w.title));
      final AppLocalizations l10n = _l10n(tester);

      // INB-23 fixes 48dp; the test says 48 rather than reading the app's own
      // constant, or it would pass on the day that constant changed.
      _atLeast48(tester, find.byType(ConversationRow).first, 'the row');
      _atLeast48(tester, find.byType(SourceAppAvatar).first, 'the circle');
      final Iterable<Element> chips = find.byType(FilterChip).evaluate();
      expect(chips.length, greaterThanOrEqualTo(2), reason: 'All and one app');
      for (int i = 0; i < chips.length; i++) {
        _atLeast48(tester, find.byType(FilterChip).at(i), 'chip $i');
      }

      await _drag(tester, find.text(w.title), -200);
      // INB-6 names the floor on this one itself, and the label is drawn
      // inside a fixed 96dp reveal: a longer word than `Delete` is exactly
      // what would push it out.
      _atLeast48(
        tester,
        find
            .ancestor(
              of: find.text(l10n.deleteConversation),
              matching: find.byType(InkWell),
            )
            .first,
        'Delete',
      );
    });

    testWidgets('every control the list names says what it is, in words from '
        'the message files', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        phone(tester);
        const _Long w = _Long.german;
        await seed(tester, (Repository repo) => _seedBusyList(repo, w));

        await show(tester, rtl: false);
        await _until(tester, find.text(w.title));
        final AppLocalizations l10n = _l10n(tester);

        // The row. Its label is built from `semanticsConversationRow`, so the
        // expected text comes from the message files too — a test that spelt
        // the sentence out would keep passing after a translator changed it.
        final String preview = l10n.conversationPreviewWithSender(
          w.sender,
          w.newest,
        );
        expect(
          tester.getSemantics(find.text(w.title)).label,
          startsWith(
            l10n.semanticsConversationRow(w.title, w.app, preview, ''),
          ),
          reason: 'INB-23: the row does not name itself to a screen reader',
        );
        // INB-5's count is drawn as a badge, so a reader is told it only if
        // the row says it (INB-23).
        expect(
          tester.getSemantics(find.text(w.otherTitle)).label,
          contains(l10n.semanticsUnreadCount(1)),
        );

        // Each chip, including `All`.
        expect(
          _spoken(tester.getSemantics(find.text(l10n.filterAll))),
          contains(l10n.semanticsFilterChipAll),
        );
        expect(
          _spoken(tester.getSemantics(find.text(w.app))),
          contains(l10n.semanticsFilterChip(w.app)),
        );

        // Delete, once the swipe has revealed it. It names the conversation it
        // would delete, because a reader who cannot see which row is open has
        // nothing else to go on (INB-6).
        await _drag(tester, find.text(w.title), -200);
        expect(
          tester.getSemantics(find.text(l10n.deleteConversation)).label,
          l10n.semanticsDeleteConversation(w.title),
        );
      } finally {
        // Not an `addTearDown`: the binding checks that no semantics handle
        // outlives the test, and it checks before tear-downs run.
        handle.dispose();
      }
    });
  });

  group('INB-24', () {
    testWidgets('INB-24 nothing the inbox draws is written anywhere but the '
        'screen', (WidgetTester tester) async {
      // RUN-2's permission gate and CAP-24's manifest check cannot catch a log
      // line, so this drives the list and a thread with values nothing else in
      // the app could produce, and asserts none of them left through a sink
      // this process has.
      const String title = 'Zzy-Title-8f21';
      const String sender = 'Zzy-Sender-8f21';
      const String body = 'Zzy-Body-8f21';
      const String package = 'com.zzy.package8f21';

      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: package,
          label: 'Zzy-Label-8f21',
          enabledIfNew: true,
          at: t0,
        );
        final Conversation c = aConversation(
          package: package,
          title: title,
          isGroup: true,
        );
        await repo.insertConversation(c);
        await repo.insertMessageIfNew(
          aMessage(conversationId: c.id, sender: sender, text: body),
        );
      });

      final List<String> emitted = <String>[];
      final DebugPrintCallback originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) emitted.add(message);
      };
      try {
        await _capturingPrint(emitted, () async {
          await tester.pumpWidget(
            ReplyboxApp(
              repository: repo,
              // This package has an `apps` row, so INB-20 makes it askable and
              // a real phone resolves it (INB-16, decision 13). Seeded so the
              // screen under the capture is the one a phone draws — including
              // INB-13's control, whose label is INB-1's, and which is one more
              // place a package name could leak and does not.
              services: _services(
                identities: const <String, SourceAppIdentity>{
                  package: SourceAppIdentity(
                    package: package,
                    presence: PackagePresence.installed,
                    label: 'Zzy-Label-8f21',
                  ),
                },
              ),
            ),
          );
          await _until(tester, find.text(title));

          // The thread draws the same words again, so it is driven inside the
          // same capture.
          await tester.tap(find.text(title));
          await _openedThread(tester, find.text('Open Zzy-Label-8f21'));
          await tester.pageBack();
          await _settle(tester);
        });
      } finally {
        // Restored inside the body, not in a tear-down: the binding checks
        // that no foundation debug variable outlives the test, and it checks
        // before tear-downs run.
        debugPrint = originalDebugPrint;
      }

      for (final String secret in <String>[title, sender, body, package]) {
        expect(
          emitted.where((String line) => line.contains(secret)),
          isEmpty,
          reason: 'INB-24: $secret reached a log line',
        );
      }
      expect(tester.takeException(), isNull);
    });

    test('INB-24 no inbox source file holds a sink that could carry a title, '
        'a sender, a message or the package list off the screen', () {
      // The runtime half above can only speak for the build it runs in. This
      // half is what makes "in any build" checkable: a line behind
      // `kDebugMode`, inside an `assert`, or on a path no test happens to
      // reach is still a line in the file.

      // What draws the inbox and holds the state behind it.
      final List<String> presentation = <String>[
        for (final String dir in <String>['lib/screens', 'lib/widgets'])
          ...Directory(
            dir,
          ).listSync().whereType<File>().map((File f) => f.path),
        'lib/providers/inbox_provider.dart',
        'lib/providers/thread_provider.dart',
        'lib/providers/apps_provider.dart',
      ];
      expect(presentation.length, greaterThan(10));

      // The two files a package name now travels through, both new on this
      // branch. Before the launcher intent filter landed in `<queries>` the
      // only package names the app could ask about were the six compiled into
      // it; since the decision of 22 September 2026 it can ask about every app
      // that has posted, so these carry more than they used to and were the
      // two files this scan did not read (INB-16, INB-20, decision 13).
      const List<String> channels = <String>[
        'lib/services/android_package_service.dart',
        'lib/services/android_app_launcher.dart',
      ];
      for (final String path in channels) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason:
              '$path is gone or renamed, so this scan silently stopped reading '
              'the file where package names cross to the platform (INB-24).',
        );
      }

      // Every way a string leaves this process: the console, a crash report,
      // another app, and the file system. None of these has a use in any inbox
      // file, whichever layer it sits in.
      final Map<String, RegExp> sinks = <String, RegExp>{
        'print': RegExp(r'(^|[^a-zA-Z])print\s*\('),
        'debugPrint': RegExp('debugPrint'),
        'dart:developer': RegExp(r'dart:developer|developer\.log'),
        'stdout or stderr': RegExp(r'\bstd(out|err)\b'),
        'a crash report': RegExp('recordError|reportError|Crashlytics'),
        'a share sheet': RegExp(r'\bShare\b|SharePlus'),
        'the clipboard': RegExp(r'Clipboard\.'),
        'the file system': RegExp(r'\bFile\(|\bDirectory\('),
      };

      // Two more that are sinks for a screen, a widget or a provider and are
      // not sinks at all for the service whose whole job is to cross the
      // channel. What INB-24 forbids is a message's text, a sender's name, a
      // conversation title or the device's package list reaching logcat, a
      // crash report, a share sheet or a file outside the app database — not
      // the platform boundary itself, which is where INB-1's icon, INB-16's
      // presence and INB-13's launch have to go and which stays inside the
      // phone (product principle 1). `dart:io` rides with it: both services
      // import it for `Platform.isAndroid` alone, and the file-system half of
      // it is banned above by the two calls that actually open something.
      //
      // Keeping them separate rather than dropping them is what lets the two
      // files be scanned at all. Banning them everywhere would have left the
      // choice of leaving those files unread, or deleting the assertion that
      // keeps a screen from reaching the platform behind its provider.
      final Map<String, RegExp> presentationOnly = <String, RegExp>{
        'a platform channel': RegExp('MethodChannel|EventChannel'),
        'dart:io': RegExp('dart:io'),
      };

      /// [path]'s source with its comments gone. These files explain
      /// themselves at length and name the channels capture arrives on; what
      /// the rule is about is a call, not a sentence about one.
      String code(String path) => File(path)
          .readAsLinesSync()
          .map((String line) {
            final int comment = line.indexOf('//');
            return comment == -1 ? line : line.substring(0, comment);
          })
          .join('\n');

      final List<String> found = <String>[];
      for (final MapEntry<String, List<String>> layer in <String, List<String>>{
        'presentation': presentation,
        'channel': channels,
      }.entries) {
        for (final String path in layer.value) {
          final String source = code(path);
          final Map<String, RegExp> banned = <String, RegExp>{
            ...sinks,
            if (layer.key == 'presentation') ...presentationOnly,
          };
          banned.forEach((String name, RegExp pattern) {
            if (pattern.hasMatch(source)) found.add('$path: $name');
          });
        }
      }
      expect(found, isEmpty, reason: 'INB-24: a sink in an inbox code path');
    });

    test('INB-24 the two files that do cross a channel cross it to the app\'s '
        'own Kotlin side, and name no other', () {
      // The allowance above is worth what this assertion is worth: a channel is
      // not a sink because the thing on the far end of `com.oasisforge.replybox
      // /capture` is this app's own listener, inside the phone (product
      // principle 1, CAP-20). A second channel name in either file is a far end
      // this reasoning has never been applied to, so it is named and read
      // rather than assumed — a plugin's channel is a component with its own
      // manifest entries and its own idea of what to do with a package name.
      //
      // What travels over the channel — one package per ask, never a list — is
      // `test/package_visibility_test.dart`'s, at both ends (INB-20).
      final Set<String> named = <String>{};
      for (final String path in <String>[
        'lib/services/android_package_service.dart',
        'lib/services/android_app_launcher.dart',
      ]) {
        final String source = File(path).readAsStringSync();
        named.addAll(
          RegExp(
            r"(?:Method|Event)Channel\(\s*'([^']*)'",
          ).allMatches(source).map((RegExpMatch m) => m.group(1)!),
        );
      }
      expect(
        named,
        <String>{'com.oasisforge.replybox/capture'},
        reason:
            'INB-24: a channel in an inbox service goes somewhere other than '
            "this app's own capture host. Found: $named",
      );
    });
  });

  group('gaps found while testing', () {
    testWidgets('INB-5 the badge clears when the reader comes back from the '
        'thread', (WidgetTester tester) async {
      // Opening a thread advances `read_through_at` (INB-5), so the count the
      // list is still drawing is stale the moment the reader backs out.
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'are you there'),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(
          repository: repo,
          services: _services(identities: _whatsappHere),
        ),
      );
      await _until(tester, find.text('Ada Lovelace'));
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.text('Ada Lovelace'));
      await _openedThread(tester, find.text('Open WhatsApp'));
      expect(find.text('are you there'), findsOneWidget);
      await tester.pageBack();
      await _settle(tester);

      expect(
        find.text('1'),
        findsNothing,
        reason: 'INB-5: the conversation was read, so nothing is unread',
      );
    });

    testWidgets("INB-12 a raw conversation's row does not also claim the "
        'notification arrived without a name', (WidgetTester tester) async {
      // INB-12 titles a raw row with the app's name by design, so it is not a
      // conversation whose name went missing. The thread agrees — it draws
      // INB-2's line only when the conversation is unnamed *and* not raw — but
      // the row conditions on the empty title alone, so the same conversation
      // says two different things on the two screens.
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.example.parcels',
          label: 'Parcels',
          enabledIfNew: true,
          at: t0,
        );
        final Conversation raw = aConversation(
          package: 'com.example.parcels',
          key: 'com.example.parcels',
          keySource: KeySource.package,
          title: '',
        );
        await repo.insertConversation(raw);
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: raw.id,
            sender: 'Out for delivery',
            text: 'Arriving by 18:00',
            kind: MessageKind.raw,
          ),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('Out for delivery — Arriving by 18:00'));

      expect(
        find.text('This conversation arrived without a name'),
        findsNothing,
        reason: 'INB-12: a raw row is not an unnamed conversation',
      );
    });

    testWidgets('INB-20 the included-apps list is reachable from a list that '
        'has conversations in it', (WidgetTester tester) async {
      // INB-15 routes to it from *Nothing yet*, which is the only way in. One
      // captured message later, the switch INB-22 describes cannot be reached
      // from the app at all.
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'hello'),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('Ada Lovelace'));

      // Tapped, not counted: an `actions` list that is merely not null is met
      // by a bar affordance that routes nowhere, which is the whole of what
      // INB-20 and INB-22 are about — the user reaching the switch.
      final AppLocalizations l10n = _l10n(tester);
      await tester.tap(find.bySemanticsLabel(l10n.semanticsIncludedApps));
      await _until(tester, find.byType(IncludedAppsScreen));
      // The screen starts its own read when it is mounted, so the rows arrive
      // a frame or more after the route does.
      await _until(tester, find.byType(Switch));

      // And it is the included-apps list they landed on, with the switch on it
      // and the sentence that says what the switch does (INB-21, INB-22).
      expect(find.text('Included apps'), findsWidgets);
      expect(
        find.text(
          'Off means the next notification this app posts is not stored. What '
          'is already here stays.',
        ),
        findsOneWidget,
      );
      expect(
        find.byType(Switch),
        findsWidgets,
        reason: 'INB-22: the route is reachable but carries no switch',
      );
      // INB-20's shipped six are rows from the first launch, named by their
      // package where nothing resolved a label. Scoped to the screen that was
      // pushed: the list underneath keeps its state, chip row and all, so an
      // unscoped finder here would also match the inbox behind it.
      expect(
        find.descendant(
          of: find.byType(IncludedAppsScreen),
          matching: find.text('com.whatsapp'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('INB-23 a row with unread messages says so to a screen '
        'reader', (WidgetTester tester) async {
      // INB-23 gives every control a semantic label from the message files,
      // and `semanticsUnreadCount` is the line for this one — INB-1 draws the
      // count, so a reader who cannot see it is told nothing.
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        await seed(tester, (Repository repo) async {
          final Conversation ada = aConversation(title: 'Ada Lovelace');
          await repo.insertConversation(ada);
          for (int i = 0; i < 3; i++) {
            await repo.insertMessageIfNew(
              aMessage(
                conversationId: ada.id,
                text: 'message $i',
                notificationKey: 'notif-$i',
              ),
            );
          }
        });

        await tester.pumpWidget(
          ReplyboxApp(repository: repo, services: _services()),
        );
        await _until(tester, find.text('Ada Lovelace'));
        expect(find.text('3'), findsOneWidget);

        expect(
          find.bySemanticsLabel(RegExp('3 unread messages')),
          findsOneWidget,
          reason: 'INB-23: the unread count is never read out',
        );
      } finally {
        // Not an `addTearDown`: the binding checks that no semantics handle
        // outlives the test, and it checks before tear-downs run.
        handle.dispose();
      }
    });

    testWidgets('INB-23 the initials circle and the app-icon badge are '
        'decoration, so a reader hears one row and not three', (
      WidgetTester tester,
    ) async {
      // INB-23 used to list both among the controls owing a 48dp target and a
      // label of their own. Building the row showed they are neither: the row
      // is what is tappable, and both only restate what the row's own label
      // already says. See INB-23's correction of 22 September 2026.
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const _Long w = _Long.german;
        await seed(tester, (Repository repo) => _seedBusyList(repo, w));

        await tester.pumpWidget(
          _screenHost(
            repository: repo,
            services: _services(),
            rtl: false,
            textScale: 1.3,
            home: InboxScreen(
              onOpenConversation: (BuildContext _, Conversation _) {},
              onOpenIncludedApps: (BuildContext _) {},
            ),
          ),
        );
        await _until(tester, find.text(w.title));
        final AppLocalizations l10n = _l10n(tester);
        final List<String> spoken = _allSpoken(tester);

        // The row says who it is from, so the badge has nothing left to add.
        expect(
          spoken.any((String s) => s.contains(w.app)),
          isTrue,
          reason: 'the row does not name the app it came from (INB-1, INB-23)',
        );
        expect(
          spoken.any((String s) => s.contains(w.title)),
          isTrue,
          reason: 'the row does not name the conversation (INB-1, INB-23)',
        );

        // And the decoration adds nothing of its own: one row, one thing read
        // out, not a name followed by its own initials and its own badge.
        // Asserted on the exclusion itself rather than on the absence of a
        // Semantics node, because Image builds one internally whatever we do —
        // what decides it is that the whole circle is excluded from the tree.
        expect(
          find.descendant(
            of: find.byType(SourceAppAvatar),
            matching: find.byType(ExcludeSemantics),
          ),
          findsWidgets,
          reason:
              'the leading circle is decoration and is excluded from the '
              'semantic tree (INB-23)',
        );
        expect(
          l10n.semanticsConversationRow(w.title, w.app, w.newest, '12:00'),
          contains(w.app),
          reason: "the row's own label is where the app is named (INB-23)",
        );
      } finally {
        // Not an `addTearDown`: the binding checks that no semantics handle
        // outlives the test, and it checks before tear-downs run.
        handle.dispose();
      }
    });

    testWidgets('INB-5 messages that arrive while the phone is on the home '
        'screen are not marked read behind the open thread', (
      WidgetTester tester,
    ) async {
      // The sequence this guards, end to end: open Ana's thread, press Home —
      // the route is still alive and Dart is still running — Ana sends three
      // messages, the drain fires the capture signal, and the thread's read
      // advances `read_through_at` past all three. Nothing is drawn and nothing
      // says so afterwards: the badge is simply never there again.
      //
      // So the assertion is at the only place a person could ever see it: the
      // list, on the next launch. `ThreadProvider` gates the read marker on the
      // lifecycle for exactly this, and before this test nothing in the repo
      // mentioned a lifecycle state at all.
      final CaptureSignal signal = CaptureSignal();
      addTearDown(signal.dispose);
      final Conversation ana = aConversation(title: 'Ana Rodriguez');
      await seed(tester, (Repository repo) async {
        await repo.insertConversation(ana);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ana.id, text: 'are we still on for six'),
        );
      });

      await tester.pumpWidget(
        _listAndThread(repository: repo, services: _services(), signal: signal),
      );
      await _until(tester, find.text('Ana Rodriguez'));
      await tester.tap(find.text('Ana Rodriguez'));
      // Waited on the route rather than on the line, because the row's preview
      // draws the same words: a finder that matched the list would let the
      // thread mount later, after the pause, and the thread would then open
      // believing the app was in front of somebody.
      await _openedThread(tester, find.byType(ThreadScreen));
      // The thread is open, and its one message is read because it is drawn.
      expect(find.text('are we still on for six'), findsOneWidget);

      // Home, in the three steps the framework actually delivers.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      await seed(tester, (Repository repo) async {
        for (int i = 1; i <= 3; i++) {
          await repo.insertMessageIfNew(
            aMessage(
              conversationId: ana.id,
              text: 'behind the home screen $i',
              notificationKey: 'behind-$i',
              sentAt: t0.add(Duration(minutes: i)),
            ),
          );
        }
      });
      // The drain, which fires on every pass whether anyone is looking or not.
      signal.captured();
      await _settle(tester);

      // The reader never came back to the thread: the app was killed while it
      // was away, and the next launch opens on the list (INB-19). The state
      // goes back to `inactive` first and never to `resumed` — the app is in
      // the switcher, not in front of anybody — because a binding that is
      // `paused` produces no frames at all and would leave the launch below
      // unbuilt. The gate does not distinguish the two: everything that is not
      // `resumed` is nobody looking.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpWidget(
        ReplyboxApp(
          // Keyed, so this is a second launch and not the same tree updated:
          // the thread's route, and the provider behind it, go with the run
          // that was killed.
          key: const ValueKey<String>('relaunch'),
          repository: repo,
          services: _services(),
        ),
      );
      await _until(tester, find.text('Ana Rodriguez'));
      await _settle(tester);

      expect(
        find.text('3'),
        findsOneWidget,
        reason:
            'INB-5: three messages nobody was ever shown came back read, so '
            'the badge for them is gone for good',
      );
    });

    testWidgets('INB-15 a list whose last conversation is inside a pending '
        'Undo never says nothing was ever stored', (WidgetTester tester) async {
      // *Nothing yet* is a statement about the whole database — nothing has
      // ever been captured — and it comes with the one action INB-15 gives it,
      // drawn directly under the snackbar holding the Undo the hand is already
      // reaching for (INB-6). A conversation five seconds from coming back is
      // not an app that has never seen a message.
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'the engine works'),
        );
      });

      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('Ada Lovelace'));

      await _drag(tester, find.text('Ada Lovelace'), -200);
      await tester.tap(find.text('Delete'));
      await _until(tester, find.text('Conversation deleted'));

      // The only conversation is gone from the list and the list is empty.
      expect(find.text('Ada Lovelace'), findsNothing);
      expect(
        find.text('Nothing yet'),
        findsNothing,
        reason:
            'INB-15: the list claimed nothing was ever stored while its one '
            'conversation was inside an Undo window',
      );
      expect(
        find.text('See included apps'),
        findsNothing,
        reason:
            "INB-15's one action was drawn over the Undo the reader is "
            'reaching for (INB-6)',
      );
      expect(find.byType(InboxEmptyStates), findsNothing);

      // And what stands there instead is a sentence, not five seconds of
      // blank: INB-15 gives the list no state it draws nothing in.
      expect(
        find.text(_l10n(tester).inboxEmptyPendingUndo),
        findsOneWidget,
        reason: 'INB-15: the list is blank while the Undo window is open',
      );

      // Undo, and it is back — the window was never the end of the story.
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.text('Undo'));
      await _until(tester, find.text('Ada Lovelace'));
      await _closeSnackBar(tester);
    });

    testWidgets('INB-15 the Undo window closing without Undo is what brings '
        '*Nothing yet* back', (WidgetTester tester) async {
      // The other half of the rule, and what stops the first assertion being
      // met by a screen that simply never draws the empty state again.
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'the engine works'),
        );
      });

      final CaptureSignal signal = CaptureSignal();
      addTearDown(signal.dispose);
      final InboxProvider inbox = InboxProvider(
        repo,
        _services(),
        captureSignal: signal,
      );
      addTearDown(inbox.dispose);
      await tester.runAsync(inbox.load);
      await tester.pumpWidget(
        _listAndThread(
          repository: repo,
          services: _services(),
          signal: signal,
          inbox: inbox,
        ),
      );
      await _until(tester, find.text('Ada Lovelace'));

      await _drag(tester, find.text('Ada Lovelace'), -200);
      await tester.tap(find.text('Delete'));
      await _until(tester, find.text('Conversation deleted'));

      // INB-6's five seconds run out without Undo (DEL-2), which is this call:
      // the screen makes it the moment its snackbar closes for any reason but
      // the action. Made here rather than by waiting, because that snackbar is
      // shown from a continuation that resumes outside the fake clock — the
      // delete before it is real database work — so nothing a widget test can
      // pump or wait for ever reaches its timer.
      await tester.runAsync(inbox.forgetPendingUndo);
      await _settle(tester);
      await _until(tester, find.text('Nothing yet'));

      expect(
        find.text('See included apps'),
        findsOneWidget,
        reason: 'INB-15: *Nothing yet* has exactly one action and this is it',
      );
    });
  });

  /// What the hand drill of 23 September 2026 found on emulator-5554, each one
  /// written as the thing a person would have seen.
  group('the 23 September 2026 device drill', () {
    /// One conversation, the screen, and the provider the test holds, so a
    /// delete can be followed all the way to what the list says afterwards.
    Future<InboxProvider> oneConversation(WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'the engine works'),
        );
      });
      final CaptureSignal signal = CaptureSignal();
      addTearDown(signal.dispose);
      final InboxProvider inbox = InboxProvider(
        repo,
        _services(),
        captureSignal: signal,
      );
      addTearDown(inbox.dispose);
      await tester.runAsync(inbox.load);
      await tester.pumpWidget(
        _listAndThread(
          repository: repo,
          services: _services(),
          signal: signal,
          inbox: inbox,
        ),
      );
      await _until(tester, find.text('Ada Lovelace'));
      return inbox;
    }

    testWidgets('DEL-2 the Undo window closes on its own, and the list stops '
        'saying a delete is pending', (WidgetTester tester) async {
      // D3. The drill found the snackbar still up at t+8s and Undo still
      // working at t+9s, and an earlier reading had it past 25s. It is not the
      // screen-reader rule the drill suspected: a `SnackBar` carrying an action
      // sets `persist`, and a persisting snackbar never times out — for every
      // user, on every device. Nothing then completed the `closed` future, so
      // `forgetPendingUndo` never ran and INB-15's pending-undo state stayed on
      // the screen for the rest of the run.
      await oneConversation(tester);

      await _drag(tester, find.text('Ada Lovelace'), -200);
      await tester.tap(find.text('Delete'));
      await _until(tester, find.text('Conversation deleted'));
      // The window is only armed once the snackbar has finished arriving, so
      // the clock is not moved until it has.
      await tester.pumpAndSettle();

      // Nothing but the clock. No `forgetPendingUndo` by hand, because that is
      // the call this rule says the window itself is supposed to make.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await _settle(tester);

      expect(
        find.text('Conversation deleted'),
        findsNothing,
        reason: 'DEL-2: the Undo window is about five seconds, not forever',
      );
      await _until(tester, find.text('Nothing yet'));
      expect(
        find.text(_l10n(tester).inboxEmptyPendingUndo),
        findsNothing,
        reason: 'INB-15: the pending-undo state goes when the window does',
      );
    });

    testWidgets('DEL-2 the window a screen reader gets is longer and still '
        'closes', (WidgetTester tester) async {
      // The other half of D3's decision. Material's own answer for a reader is
      // that the snackbar never goes away, which pins INB-15's fourth empty
      // state to the screen of the person least able to work around it. So the
      // window is three times as long — long enough to be told the line and the
      // action before reaching for it — and it is still a window.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      await oneConversation(tester);
      await _drag(tester, find.text('Ada Lovelace'), -200);
      await tester.tap(find.text('Delete'));
      await _until(tester, find.text('Conversation deleted'));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(
        find.text('Conversation deleted'),
        findsOneWidget,
        reason: 'DEL-2: five seconds is not the offer when it has to be spoken',
      );

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      await _settle(tester);
      expect(
        find.text('Conversation deleted'),
        findsNothing,
        reason: 'DEL-2: longer is still a window, and a window closes',
      );
      await _until(tester, find.text('Nothing yet'));
    });

    testWidgets('INB-1 a title with no letters in it draws the app icon alone '
        'rather than punctuation', (WidgetTester tester) async {
      // D7a: `(555) 123-0003` was drawn as `(1` — the first character of each
      // of the first two words, neither of which is an initial.
      await seed(tester, (Repository repo) async {
        final Conversation number = aConversation(title: '(555) 123-0003');
        await repo.insertConversation(number);
        await repo.insertMessageIfNew(
          aMessage(conversationId: number.id, text: 'on my way'),
        );
      });
      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('(555) 123-0003'));

      expect(
        find.text('(1'),
        findsNothing,
        reason: 'INB-1: `(` and `1` are not initials',
      );
      expect(
        find.descendant(
          of: find.byType(SourceAppAvatar),
          matching: find.byType(Text),
        ),
        findsNothing,
        reason: 'INB-2: with nothing to draw the circle is the app icon alone',
      );
      expect(
        find.text(_l10n(tester).conversationUnnamed),
        findsNothing,
        reason: 'INB-2: the conversation has a name; its name has no initials',
      );
    });

    testWidgets('INB-1 a title that does have letters still gets its two '
        'initials', (WidgetTester tester) async {
      // The other side of D7a, so the fix cannot be met by a circle that has
      // simply stopped drawing initials at all.
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: '(Ada) 2 Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'the engine works'),
        );
      });
      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('(Ada) 2 Lovelace'));

      expect(
        find.descendant(
          of: find.byType(SourceAppAvatar),
          matching: find.text('AL'),
        ),
        findsOneWidget,
        reason:
            'INB-1: the first letter of each of the first two words that '
            'has one',
      );
    });

    testWidgets('INB-23 the app-bar control opens the list from its own '
        'centre', (WidgetTester tester) async {
      // D6's guard. The drill found three taps at the middle of this control
      // doing nothing on the phone; it does not reproduce — not here at the
      // drill's own device metrics and tap points, and not on emulator-5554 on
      // a build of this branch — so there is nothing to repair, and this is
      // what would catch it if the target ever came apart from the paint.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.byIcon(Icons.tune));

      final Rect target = tester.getRect(find.byIcon(Icons.tune));
      expect(
        min(target.width, target.height),
        greaterThanOrEqualTo(48),
        reason: 'INB-23: 48dp on the shorter side',
      );
      await tester.tapAt(target.center);
      await _settle(tester);
      expect(
        find.byType(IncludedAppsScreen),
        findsOneWidget,
        reason: 'the middle of a control is the part a thumb aims at',
      );
    });

    testWidgets('INB-14 the chip row starts at the leading edge in both '
        'directions, and still scrolls', (WidgetTester tester) async {
      // D4: measured dead centre in 1080 with equal gaps either side. A
      // centred row has nothing for INB-23 to mirror.
      const double gutter = 16;
      final List<InboxChip> few = _chips(2);

      for (final TextDirection direction in TextDirection.values) {
        await tester.pumpWidget(_chipRow(few, direction));
        await tester.pumpAndSettle();
        final double width =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        // The chip's own box, not the word inside it: a chip carries its own
        // padding and the gutter is measured to the chip.
        final Rect all = tester.getRect(find.byType(FilterChip).first);

        if (direction == TextDirection.ltr) {
          expect(
            all.left,
            closeTo(gutter, 1),
            reason: 'INB-14: `All` is pinned at the leading edge, not centred',
          );
        } else {
          expect(
            width - all.right,
            closeTo(gutter, 1),
            reason: 'INB-23: leading is the right-hand edge here',
          );
        }
      }

      // And the row is still a scrolling row once the chips outgrow it
      // (INB-14), which is the thing full width could have cost.
      await tester.pumpWidget(_chipRow(_chips(30), TextDirection.ltr));
      await tester.pumpAndSettle();
      final ScrollableState scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(
        scrollable.position.maxScrollExtent,
        greaterThan(0),
        reason: 'INB-14: a horizontally scrolling chip row',
      );
    });
  });
}

// --- scaffolding ---------------------------------------------------------

/// The no-op bag with one service swapped, since [DeviceServices] has no
/// `copyWith` and a test that built a real one would be reaching for a phone.
/// The ordinary case since the manifest's launcher filter landed: the source
/// app is on the phone and the package manager says so (INB-16, decision 13).
///
/// A test that only needs to reach the thread's bottom bar uses this, because a
/// thread whose package resolved nothing has no control to tap — which is a rule
/// of its own (INB-16's `unknown`) and is asserted where it belongs, in
/// `thread_screen_test.dart`, rather than being the accidental state of every
/// other test on this screen.
const Map<String, SourceAppIdentity> _whatsappHere =
    <String, SourceAppIdentity>{
      'com.whatsapp': SourceAppIdentity(
        package: 'com.whatsapp',
        presence: PackagePresence.installed,
        label: 'WhatsApp',
      ),
    };

/// [identities] is what the package manager would answer (INB-16). Seeded
/// wherever a test has to reach INB-13's *control*, because an unresolved
/// package has none: the bar draws INB-16's sentence instead, and a test using
/// the button as its "the thread is open" marker would be waiting for a widget
/// the rule says is not there.
DeviceServices _services({
  AppLauncher? launcher,
  Map<String, SourceAppIdentity> identities =
      const <String, SourceAppIdentity>{},
}) => DeviceServices(
  // Access granted, and stated rather than defaulted. Every rule this file is
  // about — the rows, the chips, INB-15's empty states — describes a phone
  // that can see notifications, and with access off PERM-8's banner is the
  // screen's whole account of the state: it draws above the rows and replaces
  // *Nothing yet* outright. Leaving the default false would make half of this
  // file assert INB-15's sentences on a screen the rules say is showing a
  // different one. Section 9's own screen is `permissions_screens_test.dart`.
  //
  // `connected` stays null, which is what a device with no listener to ask has
  // honestly learned: PERM-10 draws nothing on it, so the list is the whole
  // screen here (PERM-13).
  notifications: const NoopNotificationSource(access: true),
  captureFilter: NoopCaptureFilter(),
  packages: NoopPackageInfoService(identities: identities),
  reply: const NoopReplyService(),
  launcher: launcher ?? const NoopAppLauncher(),
  reminders: const NoopReminderScheduler(),
  entitlements: const NoopEntitlements(),
  appLock: const NoopAppLock(),
  systemSettings: const NoopSystemSettings(),
);

/// [count] chips for INB-14's row.
///
/// Short labels on purpose: the row is only centred while its chips fit inside
/// the screen, and a long label pushes the content past the edge, where a
/// viewport clamped to the width starts at the leading edge whatever is wrong
/// with it. Two chips of two characters is the case the drill measured.
List<InboxChip> _chips(int count) => <InboxChip>[
  for (int i = 0; i < count; i++)
    InboxChip(
      package: 'com.example.app$i',
      app: SourceApp.seen(
        package: 'com.example.app$i',
        label: 'A$i',
        enabled: true,
        at: DateTime.utc(2026, 9, 23),
      ),
      conversationCount: 1,
      newestMessageAt: DateTime.utc(2026, 9, 23),
      selected: false,
    ),
];

/// INB-14's row on its own, in one direction.
///
/// The widget rather than the screen, because what is being measured is where
/// the row puts its first chip in the width it is given, and the screen's own
/// `Column` is one of the two things that decides that. The direction is
/// imposed through `MaterialApp.builder`: `MaterialApp` installs its own
/// `Directionality` from the resolved locale and would overwrite one wrapped
/// around it.
Widget _chipRow(List<InboxChip> chips, TextDirection direction) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (BuildContext context, Widget? child) =>
      Directionality(textDirection: direction, child: child!),
  home: Scaffold(
    body: Column(
      children: <Widget>[
        AppFilterChips(
          chips: chips,
          filterIsEmpty: true,
          onToggle: (String _) {},
          onClear: () {},
        ),
      ],
    ),
  ),
);

/// The list, the thread it pushes, and a capture signal the test holds.
///
/// [ReplyboxApp] builds its own [CaptureSignal] and keeps it private — the
/// drain loop is the only thing that fires it — so a test about a message
/// arriving while the phone is on the home screen has to own the signal itself.
/// Everything else here is what the two screens read out of the tree.
Widget _listAndThread({
  required Repository repository,
  required DeviceServices services,
  required CaptureSignal signal,
  InboxProvider? inbox,
}) {
  return MultiProvider(
    providers: <SingleChildWidget>[
      Provider<Repository>.value(value: repository),
      Provider<DeviceServices>.value(value: services),
      ChangeNotifierProvider<CaptureSignal>.value(value: signal),
      if (inbox != null)
        ChangeNotifierProvider<InboxProvider>.value(value: inbox)
      else
        ChangeNotifierProvider<InboxProvider>(
          create: (_) =>
              InboxProvider(repository, services, captureSignal: signal)
                ..load(),
        ),
      ChangeNotifierProvider<AppsProvider>(
        create: (_) => AppsProvider(repository, services),
      ),
      // Section 9's state, in the tree because the screen reads it and the real
      // app provides it (`lib/main.dart`). Never refreshed here: an unrefreshed
      // provider answers `CaptureStatusLine.none`, so PERM-13 draws nothing and
      // every assertion in this file stays a statement about INB-1 to INB-24
      // rather than about a banner. PERM-8's own placement is asserted in
      // `permissions_screens_test.dart`, where a refresh is the point.
      ChangeNotifierProvider<PermissionsProvider>(
        create: (_) => PermissionsProvider(repository, services),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: InboxScreen(
        onOpenConversation: (BuildContext context, Conversation conversation) =>
            unawaited(
              Navigator.of(context).push(ThreadScreen.route(conversation)),
            ),
        onOpenIncludedApps: (BuildContext _) {},
      ),
    ),
  );
}

/// Every button on screen, whatever kind it is.
///
/// `find.byType` matches the exact runtime type, and INB-15's action is a
/// `FilledButton.tonal`, so counting buttons has to go through the base class
/// the rule actually means: exactly one action, never two.
final Finder _buttons = find.byWidgetPredicate(
  (Widget w) => w is ButtonStyleButton,
);

/// INB-13's launch, recorded rather than performed.
///
/// [canOpenChat] is false on the same terms as `NoopAppLauncher`: a cold start
/// holds no content intent, so the screen draws INB-13's `Open in app` path and
/// the tap that follows lands in [opened].
class _Launches implements AppLauncher {
  final List<String> opened = <String>[];
  final List<String> openedChats = <String>[];

  @override
  Future<bool> open(String package) async {
    opened.add(package);
    return true;
  }

  @override
  Future<bool> canOpenChat(String notificationKey) async => false;

  @override
  Future<bool> openChat(String notificationKey) async {
    openedChats.add(notificationKey);
    return true;
  }
}

/// Steps outside the fake clock so the database's real work can land, then
/// draws whatever arrived, until [finder] matches.
///
/// `pumpAndSettle` cannot do this: the read is real asynchronous work and a
/// widget test's clock never advances on its own, so settling would wait on a
/// frame that is waiting on a clock that is not running.
Future<void> _until(
  WidgetTester tester,
  Finder finder, {
  int turns = 60,
}) async {
  for (int i = 0; i < turns; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, findsWidgets, reason: 'never appeared after $turns turns');
}

/// Waits for a pushed route to arrive **and** for its transition to finish.
///
/// Until it does, the list is still in the tree under the thread, and a row's
/// one-line preview carries the same words as the message it previews — so a
/// finder run mid-transition sees each of them twice.
Future<void> _openedThread(WidgetTester tester, Finder onThread) async {
  await _until(tester, onThread);
  await _settle(tester);
}

/// Lets pending work land without waiting for anything in particular.
Future<void> _settle(WidgetTester tester, {int turns = 30}) async {
  for (int i = 0; i < turns; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Runs out INB-6's five-second Undo window, so no timer outlives the test.
Future<void> _closeSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await _settle(tester);
}

/// The given texts that are on screen, in the order a reader meets them.
List<String> _topToBottom(WidgetTester tester, List<String> texts) {
  final List<String> present = <String>[
    for (final String t in texts)
      if (find.text(t).evaluate().isNotEmpty) t,
  ];
  present.sort(
    (String a, String b) => tester
        .getTopLeft(find.text(a))
        .dy
        .compareTo(tester.getTopLeft(find.text(b)).dy),
  );
  return present;
}

/// Everything the process printed while [body] ran.
Future<void> _capturingPrint(List<String> into, Future<void> Function() body) =>
    Zone.current
        .fork(
          specification: ZoneSpecification(
            print: (Zone self, ZoneDelegate parent, Zone zone, String line) =>
                into.add(line),
          ),
        )
        .run(body);

/// The strings a test seeds, long enough to stand in for a language that says
/// more than English does (INB-23, LANG-6).
///
/// The app ships one language, so a screen can only be pushed to overflow by
/// the data it draws: a title, an app label, a sender and a preview are what
/// actually differ in length between one language and the next. None of these
/// is a word an English screen would ever hold, which is the point — a box
/// sized to fit `Delete` and not a longer word is the defect this coverage
/// exists to catch.
class _Long {
  const _Long({
    required this.app,
    required this.otherApp,
    required this.title,
    required this.otherTitle,
    required this.sender,
    required this.body,
  });

  final String app;
  final String otherApp;
  final String title;
  final String otherTitle;
  final String sender;
  final String body;

  /// The newest of [_seedBusyList]'s messages, which is what the row previews.
  String get newest => '$body 100';

  static const _Long german = _Long(
    app: 'WhatsApp Messenger Kurznachrichtendienst',
    otherApp: 'Telegram Sofortnachrichten',
    title: 'Anna-Katharina Schmidt-Hohenzollern und die Nachbarn',
    otherTitle: 'Grossherzogliche Handelsgesellschaft Bremen',
    sender: 'Wolfgang Amadeus Mozart-Beethoven',
    body:
        'Eine ausserordentlich lange Vorschauzeile, die unmoeglich in eine '
        'einzige Zeile eines Gespraechs passen kann',
  );

  static const _Long arabic = _Long(
    app: 'واتساب للمراسلة الفورية',
    otherApp: 'تيليجرام للرسائل',
    title: 'رفاق الغداء الطويل جدا وجيرانهم',
    otherTitle: 'الشركة التجارية الكبرى',
    sender: 'أدا لوفليس بايرون',
    body: 'رسالة طويلة بما يكفي لتضطر الصف إلى قص نهايتها بثلاث نقاط',
  );
}

/// Two apps, two conversations, and a count past 99 (INB-5).
///
/// One conversation is busy enough to overflow INB-5's badge; the other gives
/// the chip row a second app and gives the semantics a row whose count is
/// exactly one.
Future<void> _seedBusyList(Repository repo, _Long w) async {
  await repo.upsertSeenApp(
    package: 'com.whatsapp',
    label: w.app,
    enabledIfNew: true,
    at: t0,
  );
  await repo.upsertSeenApp(
    package: 'org.telegram.messenger',
    label: w.otherApp,
    enabledIfNew: true,
    at: t0,
  );

  final Conversation busy = aConversation(
    title: w.title,
    isGroup: true,
    lastMessageAt: t0,
  );
  await repo.insertConversation(busy);
  // 101 of them, so INB-5's count is past 99 and the badge draws its overflow
  // form. Each carries its own time, so which message the row previews is a
  // fact rather than a tie (INB-4).
  for (int i = 0; i <= 100; i++) {
    await repo.insertMessageIfNew(
      aMessage(
        conversationId: busy.id,
        sender: w.sender,
        text: '${w.body} $i',
        notificationKey: 'busy-$i',
        sentAt: t0.subtract(Duration(minutes: 100 - i)),
      ),
    );
  }

  final Conversation quiet = aConversation(
    package: 'org.telegram.messenger',
    key: 'shortcut-2',
    title: w.otherTitle,
    lastMessageAt: t0.subtract(const Duration(hours: 2)),
  );
  await repo.insertConversation(quiet);
  await repo.insertMessageIfNew(
    aMessage(
      conversationId: quiet.id,
      sender: w.sender,
      text: w.body,
      notificationKey: 'quiet-1',
      sentAt: t0.subtract(const Duration(hours: 2)),
    ),
  );
}

/// The message files the screen on the tester is actually resolving.
AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

/// INB-23: the screens fail on overflow.
///
/// Two things have to hold and neither implies the other. A `RenderFlex` that
/// overflowed reports a rendering error, which the framework holds until it is
/// taken; a line that was merely pushed past the edge of the screen reports
/// nothing at all, so each one named is measured against the screen it is on.
void _fitsThePhone(WidgetTester tester, List<String> texts) {
  expect(
    tester.takeException(),
    isNull,
    reason: 'INB-23: an overflow, which reports as a rendering error',
  );
  final double width =
      tester.view.physicalSize.width / tester.view.devicePixelRatio;
  for (final String text in texts) {
    final Finder drawn = find.text(text);
    expect(
      drawn,
      findsWidgets,
      reason: 'INB-23: "$text" is not on the screen at all',
    );
    final Rect rect = tester.getRect(drawn.first);
    expect(
      rect.left,
      greaterThanOrEqualTo(-0.5),
      reason: 'INB-23: "$text" starts off the leading edge of the screen',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(width + 0.5),
      reason: 'INB-23: "$text" runs off the trailing edge of the screen',
    );
  }
}

/// INB-23's floor, measured on what is on screen rather than assumed from the
/// constant the app happens to lay out with.
void _atLeast48(WidgetTester tester, Finder finder, String what) {
  final Size size = tester.getSize(finder);
  expect(
    min(size.width, size.height),
    greaterThanOrEqualTo(48),
    reason: 'INB-23: $what is $size, under 48dp on its shorter side',
  );
}

/// INB-6's reveal swipe, run out to the end of its animation.
Future<void> _drag(WidgetTester tester, Finder row, double dx) async {
  await tester.drag(row, Offset(dx, 0));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Everything one node gives a screen reader to say.
///
/// A `Chip`'s message-files line arrives as a tooltip rather than as its label
/// — the label is the app's own name — and a reader announces both, so INB-23's
/// "says what it is" is met by either.
String _spoken(SemanticsNode node) {
  final SemanticsData data = node.getSemanticsData();
  return '${data.label} ${data.tooltip}';
}

/// Everything on screen gives a screen reader to say, node by node.
List<String> _allSpoken(WidgetTester tester) {
  final List<String> out = <String>[];
  void walk(SemanticsNode node) {
    out.add(_spoken(node));
    node.visitChildren((SemanticsNode child) {
      walk(child);
      return true;
    });
  }

  walk(tester.getSemantics(find.byType(MaterialApp)));
  return out;
}

/// A screen with a direction and a text scale forced on it (INB-23, LANG-5,
/// LANG-6).
///
/// The app ships one language and it reads left to right, so the direction is
/// imposed through `MaterialApp.builder` rather than by choosing a locale:
/// `MaterialApp` installs its own `Directionality` from the resolved locale and
/// would overwrite one wrapped around it.
Widget _screenHost({
  required Repository repository,
  required DeviceServices services,
  required Widget home,
  required bool rtl,
  double textScale = 1,
}) {
  return MultiProvider(
    providers: <SingleChildWidget>[
      Provider<Repository>.value(value: repository),
      Provider<DeviceServices>.value(value: services),
      ChangeNotifierProvider<InboxProvider>(
        create: (_) => InboxProvider(repository, services)..load(),
      ),
      ChangeNotifierProvider<AppsProvider>(
        create: (_) => AppsProvider(repository, services),
      ),
      // Unrefreshed, for the reason `_listAndThread` gives: PERM-13 resolves
      // `none` until someone asks the system, so nothing in this file measures
      // a row's width against a banner it was not written about.
      ChangeNotifierProvider<PermissionsProvider>(
        create: (_) => PermissionsProvider(repository, services),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (BuildContext context, Widget? child) {
        final Widget scaled = MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        );
        return rtl
            ? Directionality(textDirection: TextDirection.rtl, child: scaled)
            : scaled;
      },
      home: home,
    ),
  );
}
