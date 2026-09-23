/// One open thread on screen (INB-3, INB-7 to INB-13, INB-16, INB-23).
///
/// The thread is where the app is most tempted to look like an ordinary chat
/// screen and so most able to lie: a message the phone hid, a notification that
/// was never a conversation, a gap nobody was told about. Every assertion below
/// is on the sentence the reader actually gets, and on where it sits relative to
/// the messages around it.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/l10n/app_localizations.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:replybox/providers/inbox_provider.dart';
import 'package:replybox/screens/thread_screen.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:replybox/services/services.dart';

import 'helpers.dart';

void main() {
  setUpAll(initTestDatabases);

  late Repository repo;
  late DBHelper db;

  /// Real database work cannot be awaited from a widget test's own zone: the
  /// fake clock never advances, so the future never completes.
  Future<void> seed(
    WidgetTester tester,
    Future<void> Function(Repository repo) write,
  ) async {
    await tester.runAsync(() => write(repo));
  }

  setUp(() {
    db = testDb();
    repo = Repository(db);
  });

  tearDown(() async => db.close());

  /// A conversation and a thread of plain text messages, one per line given.
  Future<Conversation> aThread(
    WidgetTester tester, {
    String title = 'Ada Lovelace',
    String package = 'com.whatsapp',
    KeySource keySource = KeySource.shortcutId,
    bool isGroup = false,
    List<({String sender, String text, DateTime at})> messages = const [],
  }) async {
    final Conversation c = aConversation(
      title: title,
      package: package,
      keySource: keySource,
      key: keySource == KeySource.package ? package : 'shortcut-1',
      isGroup: isGroup,
      lastMessageAt: messages.isEmpty ? t0 : messages.last.at,
    );
    await seed(tester, (Repository repo) async {
      await repo.insertConversation(c);
      for (int i = 0; i < messages.length; i++) {
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sender: messages[i].sender,
            text: messages[i].text,
            sentAt: messages[i].at,
            notificationKey: 'notif-$i',
          ),
        );
      }
    });
    return c;
  }

  group('what a thread says about itself', () {
    testWidgets('INB-10 the standing notice is the first row, above the '
        'oldest message, and names the date history begins', (
      WidgetTester tester,
    ) async {
      // A fixed install date, written before the screen opens, so the sentence
      // on screen is a fact about seeded data rather than about the clock the
      // test happens to run on.
      final DateTime installed = t0.subtract(const Duration(days: 30));
      final Conversation c = await aThread(
        tester,
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Ada', text: 'the oldest line', at: t0),
          (
            sender: 'Ada',
            text: 'the newest line',
            at: t0.add(const Duration(minutes: 5)),
          ),
        ],
      );
      await seed(tester, (Repository repo) => repo.installedAt(installed));

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('the oldest line'));

      const String base =
          'Replybox holds only what arrived as a notification. A message '
          'edited, unsent or deleted in the app it came from still reads here '
          'as it first arrived.';
      expect(find.text(base), findsOneWidget);
      // No capture session was ever opened, so the date is stated as access
      // having been off until then (INB-10, CAP-12).
      expect(
        find.text(
          'Notification access was off until Aug 22, 2026, so nothing from '
          'before then is here.',
        ),
        findsOneWidget,
      );

      // Above the oldest message, which is the top of the thread (INB-7).
      expect(
        tester.getTopLeft(find.text(base)).dy,
        lessThan(tester.getTopLeft(find.text('the oldest line')).dy),
      );
      expect(
        tester.getTopLeft(find.text('the oldest line')).dy,
        lessThan(tester.getTopLeft(find.text('the newest line')).dy),
      );
    });

    testWidgets('INB-8 a date separator sits before the first message of each '
        'day, and a group names its senders', (WidgetTester tester) async {
      final Conversation c = await aThread(
        tester,
        title: 'Lunch crew',
        isGroup: true,
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Ada Lovelace', text: 'monday line', at: t0),
          (
            sender: 'Grace Hopper',
            text: 'tuesday line',
            at: t0.add(const Duration(days: 1)),
          ),
        ],
      );

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('tuesday line'));

      // Two calendar days, two separators, each above its own first message.
      expect(find.text('Sep 21, 2026'), findsOneWidget);
      expect(find.text('Sep 22, 2026'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Sep 22, 2026')).dy,
        greaterThan(tester.getTopLeft(find.text('monday line')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Sep 22, 2026')).dy,
        lessThan(tester.getTopLeft(find.text('tuesday line')).dy),
      );

      // INB-8: an inbound message names its sender in a group conversation.
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('Grace Hopper'), findsOneWidget);

      // INB-8's sender circle, beside the bubble, takes its initials by the
      // same rule INB-1's leading circle does (`models/initials.dart`).
      expect(find.text('AL'), findsOneWidget);
      expect(find.text('GH'), findsOneWidget);
    });

    testWidgets('INB-8 a sender with no letters in their name gets no '
        'initials, one screen deeper than INB-1 does', (
      WidgetTester tester,
    ) async {
      // The 23 September 2026 drill reported `(1` in the *list's* circle for
      // `(555) 123-0003`, and the correction landed on `InboxRow` alone — the
      // thread kept a private copy of the rule and went on drawing `(1` beside
      // the bubble. The two circles are now one function (INB-1, INB-8), and
      // this is the assertion that says the deeper one moved with it.
      final Conversation c = await aThread(
        tester,
        title: 'Lunch crew',
        isGroup: true,
        messages: <({String sender, String text, DateTime at})>[
          (sender: '(555) 123-0003', text: 'on my way', at: t0),
          (
            sender: 'Ada Lovelace',
            text: 'see you there',
            at: t0.add(const Duration(minutes: 1)),
          ),
        ],
      );

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('see you there'));

      // The nonsense the drill found: two characters of punctuation and
      // arithmetic standing where a name should be.
      expect(
        find.text('(1'),
        findsNothing,
        reason:
            'INB-8: the first character of a word is only an initial when '
            'it is a letter',
      );
      // Nothing else is invented in its place either — not the first digit,
      // not the app's name, not the title's initials.
      for (final String guess in <String>['51', '5', '(', 'LC', 'L']) {
        expect(find.text(guess), findsNothing, reason: 'INB-8: "$guess"');
      }
      // The name itself is still on screen beside the empty circle: the
      // conversation has a sender, and the sender simply has no initials.
      expect(find.text('(555) 123-0003'), findsOneWidget);
      // And the circle still works for a sender who does have letters, so the
      // rule was narrowed rather than switched off.
      expect(find.text('AL'), findsOneWidget);
    });

    testWidgets('INB-8 a one-to-one conversation never names the sender', (
      WidgetTester tester,
    ) async {
      final Conversation c = await aThread(
        tester,
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Ada Lovelace', text: 'just us two', at: t0),
        ],
      );

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('just us two'));

      // The title bar carries the name; the message does not repeat it.
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Ada Lovelace')).dy,
        lessThan(tester.getTopLeft(find.text('just us two')).dy - 40),
      );
    });

    testWidgets('INB-22 a thread from an app that is switched off says no '
        'more will arrive', (WidgetTester tester) async {
      final Conversation c = await aThread(
        tester,
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Ada', text: 'the last one that arrived', at: t0),
        ],
      );
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        await repo.setAppEnabled('com.whatsapp', enabled: false, at: t0);
      });

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('the last one that arrived'));

      expect(
        find.text(
          'WhatsApp is switched off, so no further messages will arrive here '
          'until you switch it back on.',
        ),
        findsOneWidget,
      );
    });
  });

  group('what the thread will not pretend to hold', () {
    testWidgets('INB-3 a hidden message draws the message-files line as its '
        'body, and the bar says the app will not answer it', (
      WidgetTester tester,
    ) async {
      final Conversation c = aConversation(title: 'Ada Lovelace');
      await seed(tester, (Repository repo) async {
        await repo.insertConversation(c);
        await repo.insertMessageIfNew(
          aMessage(conversationId: c.id, sender: '', kind: MessageKind.hidden),
        );
      });

      await tester.pumpWidget(
        _host(
          repo,
          c,
          // Seeded, because this test is about the bar holding a *control* and
          // an unresolved package has none to hold (INB-16's `unknown` says a
          // sentence instead). WhatsApp is on the phone in this test, which is
          // the ordinary case the rule is written for.
          services: _services(
            identities: const <String, SourceAppIdentity>{
              'com.whatsapp': SourceAppIdentity(
                package: 'com.whatsapp',
                presence: PackagePresence.installed,
                label: 'WhatsApp',
              ),
            },
          ),
        ),
      );
      await _until(
        tester,
        find.text(
          'Your phone hid this message. Open it in the app it came from.',
        ),
      );

      // INB-3: while the newest message is hidden the bar holds INB-13's
      // control whatever the action map says, and states that this is a
      // capability declined rather than a platform limit.
      expect(
        find.text('Replybox will not answer a message it cannot show.'),
        findsOneWidget,
      );
      expect(find.text('Open WhatsApp'), findsOneWidget);
    });

    testWidgets('INB-12 a raw conversation reads as a notification, not as a '
        'chat', (WidgetTester tester) async {
      final Conversation c = aConversation(
        package: 'com.example.parcels',
        key: 'com.example.parcels',
        keySource: KeySource.package,
        title: '',
      );
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.example.parcels',
          label: 'Parcels',
          enabledIfNew: true,
          at: t0,
        );
        await repo.insertConversation(c);
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sender: 'Out for delivery',
            text: 'Arriving by 18:00',
            kind: MessageKind.raw,
          ),
        );
      });

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('Arriving by 18:00'));

      expect(
        find.text(
          'Replybox saw a notification from this app, but not a conversation. '
          "Each line below is the notification's own title and text, as the "
          'phone delivered them. Nothing was added and nothing was inferred.',
        ),
        findsOneWidget,
      );
      // The notification's own title and text, kept apart, and the thread
      // titled with the app rather than with a sender.
      expect(find.text('Out for delivery'), findsOneWidget);
      expect(find.text('Parcels'), findsOneWidget);
    });

    testWidgets('INB-11 an attachment is a placeholder and never stored '
        'words', (WidgetTester tester) async {
      final Conversation c = aConversation(title: 'Ada Lovelace');
      await seed(tester, (Repository repo) async {
        await repo.insertConversation(c);
        await repo.insertMessageIfNew(
          aMessage(conversationId: c.id, kind: MessageKind.image),
        );
      });

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('Photo'));
      // CAP-15 keeps no size, duration, filename or thumbnail, so there is
      // nothing beside the line to draw.
      expect(find.text('hello'), findsNothing);
    });

    testWidgets('INB-9 an outbound message sits on the other side and a '
        'pending one carries no time', (WidgetTester tester) async {
      final Conversation c = aConversation(title: 'Ada Lovelace');
      await seed(tester, (Repository repo) async {
        await repo.insertConversation(c);
        await repo.insertMessageIfNew(
          aMessage(conversationId: c.id, sender: 'Ada', text: 'their line'),
        );
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sender: '',
            text: 'my line, not sent yet',
            direction: Direction.outbound,
            sendState: SendState.pending,
            notificationKey: 'notif-2',
            sentAt: t0.add(const Duration(minutes: 1)),
          ),
        );
      });

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('my line, not sent yet'));

      // LANG-5 mirrors the sides; in English the outbound one is further from
      // the leading edge than the inbound one.
      expect(
        tester.getTopLeft(find.text('my line, not sent yet')).dx,
        greaterThan(tester.getTopLeft(find.text('their line')).dx),
      );
      // INB-9: a clock glyph stands in place of the time, so nothing on screen
      // claims the message arrived anywhere.
      expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
    });

    testWidgets('INB-7 a thread longer than the window says so at its top, '
        'and what is above the window is not drawn as its beginning', (
      WidgetTester tester,
    ) async {
      // The read is bounded to `Repository.threadWindow`, so a longer thread
      // shows its newest window and nothing older. INB-10 forbids the top of a
      // thread implying that more can be loaded, and this is the case where a
      // silent bound is the lie: the notice names the date history begins,
      // months before the oldest message drawn, with nothing between them
      // saying why — which reads as five hundred messages lost.
      const int window = Repository.threadWindow;
      final Conversation c = aConversation(title: 'Ada Lovelace');
      await seed(tester, (Repository repo) async {
        await repo.insertConversation(c);
        // One past the window, so exactly one message is above it and the
        // oldest thing on screen is the second.
        await repo.insertMessagesIfNew(<Message>[
          for (int i = 1; i <= window + 1; i++)
            aMessage(
              conversationId: c.id,
              text: 'line $i',
              notificationKey: 'notif-$i',
              sentAt: t0.add(Duration(minutes: i)),
            ),
        ]);
      });

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('line ${window + 1}'));
      await _settle(tester);

      // The top of the thread, which is five hundred messages above where it
      // opened: a drag cannot get there, and what this is about is what the
      // first row says.
      final ScrollableState scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scrollable.position.jumpTo(0);
      await tester.pump();
      await _settle(tester);

      final AppLocalizations l10n = _l10n(tester);
      expect(
        find.text(l10n.threadWindowed(window)),
        findsOneWidget,
        reason:
            'INB-7, INB-10: the thread is bounded to its newest $window '
            'messages and the top of it says nothing about that',
      );
      // The line above the window is not on screen, and nothing else is
      // standing in for it either.
      expect(
        find.text('line 1'),
        findsNothing,
        reason: 'the message above the window is drawn as if it were inside it',
      );
      expect(find.text('line 2'), findsOneWidget);
      // And the sentence sits above the oldest message that is drawn, where a
      // reader would otherwise try to pull for more (INB-10).
      expect(
        tester.getTopLeft(find.text(l10n.threadWindowed(window))).dy,
        lessThan(tester.getTopLeft(find.text('line 2')).dy),
      );
    });

    testWidgets('INB-7 a thread that fits inside the window says nothing '
        'about one', (WidgetTester tester) async {
      // The other half: the line is about a thread that really is cut off, and
      // a standing sentence on every short thread would be the app stating a
      // limit it is not under (product principle 3).
      final Conversation c = await aThread(
        tester,
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Ada', text: 'the only line', at: t0),
        ],
      );

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('the only line'));

      final AppLocalizations l10n = _l10n(tester);
      expect(
        find.text(l10n.threadWindowed(Repository.threadWindow)),
        findsNothing,
      );
    });
  });

  group('INB-13 and INB-16 the control at the bottom', () {
    testWidgets('a package nothing resolved is offered no launch, and the '
        'sentence names no uninstall', (WidgetTester tester) async {
      // INB-16's third state, and it is still reachable after the manifest's
      // launcher filter landed (decision 13): a package with no launcher
      // activity, one the store has no record of having posted, or a lookup
      // that simply failed. All three arrive here as `unknown`, which is what
      // the fake answers for anything it was not seeded with.
      final Conversation c = await aThread(
        tester,
        package: 'com.example.unknown',
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Ada', text: 'hello', at: t0),
        ],
      );

      await tester.pumpWidget(_host(repo, c));
      await _until(tester, find.text('hello'));

      // INB-16: the app says less rather than guessing. `Open in app` used to
      // stand here, and it was a control whose launch could not land —
      // `getLaunchIntentForPackage` answers null for a package this build
      // cannot resolve, so every tap produced the same snackbar, forever.
      expect(
        find.text('Replybox cannot open com.example.unknown.'),
        findsOneWidget,
      );
      expect(
        find.byType(FilledButton),
        findsNothing,
        reason: 'INB-16: no launch is offered that could only ever fail',
      );
      // The two sentences the app has not earned. `unknown` is the app unable
      // to see, and an uninstall is a thing it has seen; INB-16 forbids saying
      // the second on the strength of the first.
      expect(find.text('This app is no longer installed.'), findsNothing);
      // The messages are the user's either way (DEL-1).
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('an installed package is named in the control', (
      WidgetTester tester,
    ) async {
      final Conversation c = await aThread(
        tester,
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Ada', text: 'hello', at: t0),
        ],
      );

      await tester.pumpWidget(
        _host(
          repo,
          c,
          services: _services(
            identities: const <String, SourceAppIdentity>{
              'com.whatsapp': SourceAppIdentity(
                package: 'com.whatsapp',
                presence: PackagePresence.installed,
                label: 'WhatsApp',
              ),
            },
          ),
        ),
      );
      await _until(tester, find.text('hello'));
      expect(find.text('Open WhatsApp'), findsOneWidget);
    });

    testWidgets('INB-16 an uninstalled package replaces the control with the '
        'line that says so', (WidgetTester tester) async {
      final Conversation c = await aThread(
        tester,
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Ada', text: 'hello', at: t0),
        ],
      );

      await tester.pumpWidget(
        _host(
          repo,
          c,
          services: _services(
            identities: const <String, SourceAppIdentity>{
              'com.whatsapp': SourceAppIdentity(
                package: 'com.whatsapp',
                presence: PackagePresence.gone,
              ),
            },
          ),
        ),
      );
      await _until(tester, find.text('hello'));
      expect(find.text('This app is no longer installed.'), findsOneWidget);

      // In place of the control, never beside it: a launch that cannot land is
      // not offered.
      expect(find.text('Open in app'), findsNothing);
      expect(find.text('Open WhatsApp'), findsNothing);
      // The messages stay: only the user deletes them (INB-16, DEL-1).
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('a launch that lands changes nothing on screen, and one that '
        'fails says only that', (WidgetTester tester) async {
      final Conversation c = await aThread(
        tester,
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Ada', text: 'hello', at: t0),
        ],
      );

      await tester.pumpWidget(
        _host(
          repo,
          c,
          services: _services(
            launcher: const NoopAppLauncher(succeeds: false),
            identities: _whatsappHere,
          ),
        ),
      );
      await _until(tester, find.text('hello'));
      expect(find.text('Open WhatsApp'), findsOneWidget);

      await tester.tap(find.text('Open WhatsApp'));
      await _until(tester, find.text('Could not open that app.'));
      // INB-13: one snackbar, and nothing else on screen changes. It names no
      // app and reports no uninstall — the package manager said the app is
      // there a frame ago, and a launch that did not land is not evidence
      // against that (INB-16).
      expect(find.text('This app is no longer installed.'), findsNothing);
      expect(find.text('hello'), findsOneWidget);
      expect(
        find.text('Open WhatsApp'),
        findsOneWidget,
        reason: 'INB-13: a failed launch leaves the control where it was',
      );

      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
    });
  });

  // Decision 13, 22 September 2026: the manifest's `<queries>` gained a
  // launcher intent filter, so every app with an icon the user could tap is
  // visible to this build — not only the six the manifest names. INB-13's
  // control and INB-16's installed-or-gone therefore work for the apps INB-20's
  // *second* source is made of: the ones that joined the inbox by posting a
  // notification. That half had no coverage, because before the change it could
  // not work at all.
  group('INB-13 and INB-16 for an app outside the shipped six', () {
    /// A package that is in nobody's shipped list and has an `apps` row,
    /// which is what makes it askable at all (INB-20).
    const String shopping = 'com.example.shopping';

    Future<Conversation> aShoppingThread(WidgetTester tester) async {
      final Conversation c = await aThread(
        tester,
        title: 'Deliveries',
        package: shopping,
        messages: <({String sender, String text, DateTime at})>[
          (sender: 'Courier', text: 'left at your door', at: t0),
        ],
      );
      await seed(
        tester,
        (Repository repo) => repo.upsertSeenApp(
          package: shopping,
          label: 'Shopping',
          enabledIfNew: true,
          at: t0,
        ),
      );
      return c;
    }

    testWidgets('it opens, and the control names the app', (
      WidgetTester tester,
    ) async {
      final Conversation c = await aShoppingThread(tester);
      final _RecordsLaunches launcher = _RecordsLaunches();

      await tester.pumpWidget(
        _host(
          repo,
          c,
          services: _services(
            launcher: launcher,
            identities: const <String, SourceAppIdentity>{
              shopping: SourceAppIdentity(
                package: shopping,
                presence: PackagePresence.installed,
                label: 'Shopping',
              ),
            },
          ),
        ),
      );
      await _until(tester, find.text('left at your door'));

      // INB-13: the label says which launch will run, and names the app the
      // package manager actually resolved. This is the sentence the developer
      // paid the privacy policy's package-list claim for.
      expect(find.text('Open Shopping'), findsOneWidget);
      expect(find.text('Open chat'), findsNothing);

      await tester.tap(find.text('Open Shopping'));
      await _settle(tester);

      // The launcher intent, for this package and nothing else. INB-13: the
      // app adds no extra, no message and no conversation identifier.
      expect(launcher.opened, <String>[shopping]);
      expect(launcher.openedChats, isEmpty);
      // A launch that landed changes nothing on screen.
      expect(find.text('Could not open that app.'), findsNothing);
      expect(find.text('left at your door'), findsOneWidget);
    });

    testWidgets('INB-16 an uninstalled one gets the line, not a control', (
      WidgetTester tester,
    ) async {
      // Before decision 13 this state was unreachable outside the six: a
      // NameNotFound from an undeclared package could equally have been package
      // visibility, so the app had to say `unknown`. The launcher filter is
      // what lets `gone` mean an uninstall here too.
      final Conversation c = await aShoppingThread(tester);

      await tester.pumpWidget(
        _host(
          repo,
          c,
          services: _services(
            identities: const <String, SourceAppIdentity>{
              shopping: SourceAppIdentity(
                package: shopping,
                presence: PackagePresence.gone,
              ),
            },
          ),
        ),
      );
      await _until(tester, find.text('left at your door'));

      expect(find.text('This app is no longer installed.'), findsOneWidget);
      expect(
        find.byType(FilledButton),
        findsNothing,
        reason: 'INB-16: the line stands in place of the control',
      );
      expect(find.text('Open Shopping'), findsNothing);
      // INB-16: a conversation is never emptied because its source app was
      // uninstalled. The messages are the user's (DEL-1, CAP-16).
      expect(find.text('left at your door'), findsOneWidget);
      expect(find.text('Deliveries'), findsWidgets);
    });

    testWidgets('a held notification opens the chat, which needs no '
        'visibility at all', (WidgetTester tester) async {
      // INB-13's first path, and the one that is not a fallback: a
      // `PendingIntent` runs as the app that created it, so `Open chat` is the
      // only control that works for a package this build cannot resolve.
      final Conversation c = await aShoppingThread(tester);
      final _RecordsLaunches launcher = _RecordsLaunches(holdsChat: true);

      // Deliberately not seeded: `unknown`, and `Open chat` all the same.
      await tester.pumpWidget(
        _host(repo, c, services: _services(launcher: launcher)),
      );
      await _until(tester, find.text('Open chat'));

      // The label names no app, because this path claims nothing about the app
      // around the conversation (INB-13).
      expect(find.text('Open Shopping'), findsNothing);
      expect(find.text('Replybox cannot open Shopping.'), findsNothing);

      await tester.tap(find.text('Open chat'));
      await _settle(tester);

      expect(launcher.openedChats, <String>['notif-0']);
      expect(
        launcher.opened,
        isEmpty,
        reason:
            'INB-13: a content intent that did not send is never retried as a '
            'launcher intent — landing the user on a home screen is the same '
            'lie in the other direction',
      );
    });
  });

  // The 23 September 2026 drill: `installed` is not `launchable`. The phone
  // half of the fix is held by `SourceAppInfoTest` and the channel half by
  // `test/package_info_test.dart`; this group is the half the user reads —
  // which of INB-13's five bottom-bar states the new fact actually produces.
  group('INB-13 an installed app with no screen to open', () {
    /// The drill's own case: the package manager resolved the app, its name and
    /// its icon, and no launcher intent for it.
    const Map<String, SourceAppIdentity> whatsappUnopenable =
        <String, SourceAppIdentity>{
          'com.whatsapp': SourceAppIdentity(
            package: 'com.whatsapp',
            presence: PackagePresence.installed,
            label: 'WhatsApp',
            launchability: Launchability.noLauncher,
          ),
        };

    Future<Conversation> aLine(WidgetTester tester) => aThread(
      tester,
      messages: <({String sender, String text, DateTime at})>[
        (sender: 'Ada', text: 'hello', at: t0),
      ],
    );

    testWidgets('draws the line that says so, in place of the control', (
      WidgetTester tester,
    ) async {
      final Conversation c = await aLine(tester);
      final _RecordsLaunches launcher = _RecordsLaunches();

      await tester.pumpWidget(
        _host(
          repo,
          c,
          services: _services(
            launcher: launcher,
            identities: whatsappUnopenable,
          ),
        ),
      );
      await _until(tester, find.text('hello'));

      expect(find.text('WhatsApp has no screen to open.'), findsOneWidget);
      expect(
        find.byType(FilledButton),
        findsNothing,
        reason:
            'INB-13: `Open WhatsApp` here is a control that can only ever '
            'end in the snackbar — the drill found it on com.android.shell',
      );
      expect(find.text('Open WhatsApp'), findsNothing);
      expect(find.text('Open chat'), findsNothing);

      // Its own sentence, and neither of the other two: nothing has been
      // uninstalled, and this is not the app unable to see. It looked, and
      // there is nothing to start (INB-16).
      expect(find.text('This app is no longer installed.'), findsNothing);
      expect(find.text('Replybox cannot open WhatsApp.'), findsNothing);

      // The thread is otherwise untouched: the messages are the user's
      // whatever the app around them can do (DEL-1, INB-16).
      expect(find.text('hello'), findsOneWidget);
      expect(launcher.opened, isEmpty);
      expect(launcher.openedChats, isEmpty);
    });

    testWidgets('a launchability nobody measured still offers the launch', (
      WidgetTester tester,
    ) async {
      // Deliberate, and the direction the whole tri-state exists for: a host
      // that does not send the key — an older build of the native side, an
      // answer that could not be read — must leave the app behaving exactly as
      // it did before the key existed. Folding "did not say" into "has no
      // screen" would put a sentence on screen accusing a launchable app of
      // being unopenable, which is the opposite of the bug being fixed.
      final Conversation c = await aLine(tester);
      final _RecordsLaunches launcher = _RecordsLaunches();

      await tester.pumpWidget(
        _host(
          repo,
          c,
          // `_whatsappHere` carries no launchability at all, which is
          // `Launchability.unknown`.
          services: _services(launcher: launcher, identities: _whatsappHere),
        ),
      );
      await _until(tester, find.text('hello'));

      expect(find.text('Open WhatsApp'), findsOneWidget);
      expect(find.text('WhatsApp has no screen to open.'), findsNothing);

      await tester.tap(find.text('Open WhatsApp'));
      await _settle(tester);

      // And the tap runs the launcher intent, as it always did. A launch that
      // then fails is INB-13's snackbar, which is the cost this state accepts.
      expect(launcher.opened, <String>['com.whatsapp']);
    });

    testWidgets('a held notification outranks it, because it is the one app '
        'nothing else can reach', (WidgetTester tester) async {
      // The order is the whole value of the content intent. An app with no
      // launcher activity is precisely the app no launch can reach, so while
      // its notification is held there is still a working second tap (INB-18),
      // and only once that is gone does the bar fall to the line.
      final Conversation c = await aLine(tester);
      final _RecordsLaunches launcher = _RecordsLaunches(holdsChat: true);

      await tester.pumpWidget(
        _host(
          repo,
          c,
          services: _services(
            launcher: launcher,
            identities: whatsappUnopenable,
          ),
        ),
      );
      await _until(tester, find.text('Open chat'));

      expect(find.text('WhatsApp has no screen to open.'), findsNothing);
      expect(find.text('Open WhatsApp'), findsNothing);

      await tester.tap(find.text('Open chat'));
      await _settle(tester);

      // The content intent, and never the launcher intent this app has none of.
      expect(launcher.openedChats, <String>['notif-0']);
      expect(launcher.opened, isEmpty);
    });

    testWidgets('INB-16 an uninstall still outranks it, because the line is '
        'about the app being gone', (WidgetTester tester) async {
      // `gone` comes first even over a held notification, so it certainly comes
      // first over this: a `PendingIntent` into an uninstalled app has no
      // target left. The two lines are different sentences and only one of them
      // is true here.
      final Conversation c = await aLine(tester);

      await tester.pumpWidget(
        _host(
          repo,
          c,
          services: _services(
            launcher: _RecordsLaunches(holdsChat: true),
            identities: const <String, SourceAppIdentity>{
              'com.whatsapp': SourceAppIdentity(
                package: 'com.whatsapp',
                presence: PackagePresence.gone,
                launchability: Launchability.noLauncher,
              ),
            },
          ),
        ),
      );
      await _until(tester, find.text('hello'));

      expect(find.text('This app is no longer installed.'), findsOneWidget);
      expect(find.text('WhatsApp has no screen to open.'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  // INB-13 says the label says which path it is, and INB-23 says that has to
  // hold for a screen reader. The launcher path's semantic label is measured
  // under INB-23 below; the chat path's was asserted nowhere, and the two are
  // one careless edit from being the same sentence.
  group('INB-13 the two open paths do not sound alike', () {
    /// The bar's control, with semantics switched on around one thread.
    ///
    /// Two tests and not one screen pumped twice: `ThreadScreen` asks whether
    /// the notification is held once per notification key, so a second
    /// `pumpWidget` into the same element tree keeps the answer the first one
    /// got and the path never changes.
    Future<void> withSemantics(
      WidgetTester tester,
      Future<void> Function(AppLocalizations l10n, Finder control) body, {
      required bool holdsChat,
      required String visible,
    }) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        final Conversation c = await aThread(
          tester,
          messages: <({String sender, String text, DateTime at})>[
            (sender: 'Ada', text: 'hello', at: t0),
          ],
        );
        await tester.pumpWidget(
          _host(
            repo,
            c,
            services: _services(
              launcher: _RecordsLaunches(holdsChat: holdsChat),
              identities: _whatsappHere,
            ),
          ),
        );
        await _until(tester, find.text(visible));
        await body(_l10n(tester), find.byType(FilledButton).first);
      } finally {
        // Not an `addTearDown`: the binding checks that no semantics handle
        // outlives the test, and it checks before tear-downs run.
        handle.dispose();
      }
    }

    testWidgets('the content-intent path says it opens the conversation where '
        'it arrived', (WidgetTester tester) async {
      // Its visible label names no app, so the semantic label is the only
      // place a screen-reader user hears that this tap goes to the
      // conversation rather than to the app's home screen — and it is the one
      // of the two that nothing asserted.
      await withSemantics(tester, holdsChat: true, visible: 'Open chat', (
        AppLocalizations l10n,
        Finder control,
      ) async {
        expect(tester.getSemantics(control).label, l10n.semanticsOpenChat);
        expect(
          l10n.semanticsOpenChat,
          isNot(l10n.semanticsOpenInApp('WhatsApp')),
          reason:
              'INB-13: two different launches to two different places must '
              'not read out as the same sentence',
        );
      });
    });

    testWidgets('the launcher path names the app it will open', (
      WidgetTester tester,
    ) async {
      await withSemantics(tester, holdsChat: false, visible: 'Open WhatsApp', (
        AppLocalizations l10n,
        Finder control,
      ) async {
        expect(
          tester.getSemantics(control).label,
          l10n.semanticsOpenInApp('WhatsApp'),
        );
        expect(
          tester.getSemantics(control).label,
          isNot(l10n.semanticsOpenChat),
        );
      });
    });
  });

  group('INB-23 the thread at 1.3x text, mirrored, and reachable', () {
    /// A phone-size screen, in logical pixels.
    ///
    /// INB-23 names a phone, and a phone is where the rule can fail: the
    /// 800x600 a widget test defaults to is wider than any of them, so a
    /// bubble that overflows on a phone lays out comfortably on it.
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    /// A group thread carrying one of everything a thread can draw, in strings
    /// long enough to stand in for a language that says more than English does
    /// (INB-23, LANG-6).
    Future<Conversation> aFullThread(WidgetTester tester) async {
      final Conversation c = aConversation(
        title: _Long.title,
        isGroup: true,
        lastMessageAt: t0.add(const Duration(days: 1)),
      );
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: _Long.app,
          enabledIfNew: true,
          at: t0,
        );
        await repo.insertConversation(c);
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sender: _Long.sender,
            text: _Long.inbound,
            notificationKey: 'n1',
            sentAt: t0,
          ),
        );
        // INB-11: an attachment is a line from the message files, and it is
        // the longest thing the bubble ever holds.
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sender: _Long.sender,
            kind: MessageKind.voice,
            notificationKey: 'n2',
            sentAt: t0.add(const Duration(minutes: 1)),
          ),
        );
        // INB-3: the hidden line, which is longer still.
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sender: '',
            kind: MessageKind.hidden,
            notificationKey: 'n3',
            sentAt: t0.add(const Duration(minutes: 2)),
          ),
        );
        // INB-8: a second calendar day, so a date separator is drawn too.
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sender: '',
            text: _Long.outbound,
            direction: Direction.outbound,
            notificationKey: 'n4',
            historyIndex: 1,
            sentAt: t0.add(const Duration(days: 1)),
          ),
        );
      });
      return c;
    }

    /// A two-message thread, so both sides are drawn at once.
    ///
    /// INB-7 opens a thread scrolled to its newest message, so a thread long
    /// enough to scroll never has its oldest message in the tree to measure.
    Future<Conversation> aTwoSidedThread(WidgetTester tester) async {
      final Conversation c = aConversation(
        title: _Long.title,
        isGroup: true,
        lastMessageAt: t0.add(const Duration(minutes: 1)),
      );
      await seed(tester, (Repository repo) async {
        await repo.insertConversation(c);
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sender: _Long.sender,
            text: _Long.short,
            notificationKey: 'n1',
            sentAt: t0,
          ),
        );
        await repo.insertMessageIfNew(
          aMessage(
            conversationId: c.id,
            sender: '',
            text: _Long.outbound,
            direction: Direction.outbound,
            notificationKey: 'n2',
            historyIndex: 1,
            sentAt: t0.add(const Duration(minutes: 1)),
          ),
        );
      });
      return c;
    }

    testWidgets('a filled thread draws every message inside a phone screen at '
        '1.3x, in words a longer language would need', (
      WidgetTester tester,
    ) async {
      phone(tester);
      final Conversation c = await aFullThread(tester);

      await tester.pumpWidget(_host(repo, c, textScale: 1.3));
      await _until(tester, find.text(_Long.outbound));

      final AppLocalizations l10n = _l10n(tester);
      // The newest end of the thread, which is where INB-7 opens it: the
      // outbound reply, INB-3's hidden line and INB-11's placeholder.
      expect(find.text(l10n.messageHidden), findsOneWidget);
      _fitsThePhone(tester, <String>[
        _Long.title,
        _Long.outbound,
        l10n.messageHidden,
      ]);

      // Then the oldest end, which a reader reaches by scrolling: INB-10's
      // standing notice, the long inbound bubble and the sender above it.
      await _scrollToOldest(tester, find.text(l10n.threadHistoryNotice));
      _fitsThePhone(tester, <String>[
        l10n.threadHistoryNotice,
        _Long.inbound,
        _Long.sender,
      ]);
    });

    testWidgets('INB-9 an outbound message sits away from the inbound ones, '
        'and the two sides swap in a right-to-left language', (
      WidgetTester tester,
    ) async {
      phone(tester);
      final Conversation c = await aTwoSidedThread(tester);
      final double width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;

      await tester.pumpWidget(_host(repo, c, textScale: 1.3));
      await _until(tester, find.text(_Long.outbound));
      final Rect inLtr = _bubble(tester, _Long.short);
      final Rect outLtr = _bubble(tester, _Long.outbound);
      // Left to right: inbound hangs from the left gutter and outbound from
      // the right one (INB-9).
      expect(inLtr.left, lessThan(outLtr.left));
      expect(outLtr.right, greaterThan(inLtr.right));

      await tester.pumpWidget(_host(repo, c, textScale: 1.3, rtl: true));
      await _until(tester, find.text(_Long.outbound));
      final Rect inRtl = _bubble(tester, _Long.short);
      final Rect outRtl = _bubble(tester, _Long.outbound);

      // INB-23: the same two sides, mirrored. Asserting the pair swapped,
      // rather than one side on its own, is what makes this a mirror test —
      // a layout that hard-coded the right-hand side would pass half of it.
      expect(
        outRtl.left,
        lessThan(inRtl.left),
        reason: 'INB-23: the outbound side did not mirror',
      );
      expect(
        inRtl.right,
        greaterThan(outRtl.right),
        reason: 'INB-23: the inbound side did not mirror',
      );
      // And measured from whichever edge the language starts at, the two keep
      // the same relationship in both: inbound leads, outbound trails.
      expect(inLtr.left, lessThan(outLtr.left));
      expect(width - inRtl.right, lessThan(width - outRtl.right));
      expect(tester.takeException(), isNull);
    });

    testWidgets("INB-13's control is at least 48dp on its shorter side and "
        'says what it is, in words from the message files', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        phone(tester);
        final Conversation c = await aFullThread(tester);

        // The package manager's own label, which is INB-1's first fallback and
        // the longest thing this button ever holds: `Open <app>` carries a name
        // the app did not choose, and at 1.3x a long one wraps to two lines.
        // That is the case the rule's minimum height exists for, so it is the
        // one measured.
        await tester.pumpWidget(
          _host(
            repo,
            c,
            textScale: 1.3,
            services: _services(
              identities: const <String, SourceAppIdentity>{
                'com.whatsapp': SourceAppIdentity(
                  package: 'com.whatsapp',
                  presence: PackagePresence.installed,
                  label: _Long.app,
                ),
              },
            ),
          ),
        );
        await _until(tester, find.text(_Long.outbound));
        final AppLocalizations l10n = _l10n(tester);

        // INB-13 sizes this bar because the reply field will occupy it, so the
        // floor is measured on what was drawn rather than read off the
        // constant the app laid it out with (INB-23).
        final Finder control = find.byType(FilledButton).first;
        final Size size = tester.getSize(control);
        expect(
          min(size.width, size.height),
          greaterThanOrEqualTo(48),
          reason: "INB-23: INB-13's control is $size",
        );
        // INB-13: the label names the app the package manager resolved, and
        // INB-23 gives the button one semantic label of its own — not the
        // visible words a second time.
        expect(find.text(l10n.openApp(_Long.app)), findsOneWidget);
        expect(
          tester.getSemantics(control).label,
          l10n.semanticsOpenInApp(_Long.app),
        );
        // INB-23: the control is one of the lines that has to survive a long
        // name on a phone at 1.3x rather than run off the edge.
        _fitsThePhone(tester, <String>[l10n.openApp(_Long.app)]);
      } finally {
        // Not an `addTearDown`: the binding checks that no semantics handle
        // outlives the test, and it checks before tear-downs run.
        handle.dispose();
      }
    });
  });
}

/// The strings a thread test seeds, long enough to stand in for a language
/// that says more than English does (INB-23, LANG-6).
///
/// The app ships one language, so the only way to push a bubble past the edge
/// of a phone is the data it holds: a title, a sender and a message are what
/// actually differ in length between one language and the next.
abstract final class _Long {
  static const String app = 'واتساب للمراسلة الفورية';
  static const String title = 'رفاق الغداء الطويل جدا وجيرانهم في الحي';
  static const String sender = 'أدا لوفليس بايرون كاونتيس أوف لافلايس';
  static const String inbound =
      'رسالة واردة طويلة بما يكفي لتلتف على أكثر من سطر داخل فقاعتها ثم تعود '
      'إلى أول السطر التالي';
  static const String short = 'حسنا، أراك عند السادسة';
  static const String outbound =
      'ردي الصادر الطويل الذي كتبته من داخل التطبيق نفسه';
}

/// Scrolls back towards the oldest message until [finder] is in the tree.
///
/// INB-7 opens a thread at its newest message, so nothing above the fold has
/// been built and a finder cannot read what was never drawn.
Future<void> _scrollToOldest(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
  }
  expect(finder, findsOneWidget, reason: 'never scrolled into the tree');
}

/// The message files the screen on the tester is actually resolving.
AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

/// The whole bubble a message is drawn in, rather than the line inside it.
///
/// The side a message sits on is a fact about the bubble: the text inside one
/// is laid out from the language's own leading edge and moves with it even
/// when the bubble has not moved at all.
Rect _bubble(WidgetTester tester, String text) => tester.getRect(
  find
      .ancestor(of: find.text(text), matching: find.byType(MergeSemantics))
      .first,
);

/// INB-23: the thread fails on overflow.
///
/// Two things have to hold and neither implies the other. A `RenderFlex` that
/// overflowed reports a rendering error, which the framework holds until it is
/// taken; a line merely pushed past the edge of the screen reports nothing at
/// all, so each one named is measured against the screen it is on.
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

// --- scaffolding ---------------------------------------------------------

/// The ordinary case since the manifest's launcher filter landed: the source
/// app is on the phone and the package manager says so (INB-16, decision 13).
const Map<String, SourceAppIdentity> _whatsappHere =
    <String, SourceAppIdentity>{
      'com.whatsapp': SourceAppIdentity(
        package: 'com.whatsapp',
        presence: PackagePresence.installed,
        label: 'WhatsApp',
      ),
    };

/// INB-13's two launches, recorded rather than performed.
///
/// Which one ran is the assertion, not merely that something did: the rule
/// picks the path before the tap and the label tells the user which, so a fake
/// that only counted launches would pass on a screen that drew `Open chat` and
/// then started a launcher intent.
class _RecordsLaunches implements AppLauncher {
  _RecordsLaunches({this.holdsChat = false});

  final bool holdsChat;

  final List<String> opened = <String>[];
  final List<String> openedChats = <String>[];

  @override
  Future<bool> open(String package) async {
    opened.add(package);
    return true;
  }

  @override
  Future<bool> canOpenChat(String notificationKey) async => holdsChat;

  @override
  Future<bool> openChat(String notificationKey) async {
    openedChats.add(notificationKey);
    return true;
  }
}

DeviceServices _services({
  AppLauncher? launcher,
  Map<String, SourceAppIdentity> identities =
      const <String, SourceAppIdentity>{},
}) => DeviceServices(
  notifications: const NoopNotificationSource(),
  captureFilter: NoopCaptureFilter(),
  packages: NoopPackageInfoService(identities: identities),
  reply: const NoopReplyService(),
  launcher: launcher ?? const NoopAppLauncher(),
  reminders: const NoopReminderScheduler(),
  entitlements: const NoopEntitlements(),
  appLock: const NoopAppLock(),
);

/// The thread screen with everything it reaches for above it.
///
/// It builds its own [ThreadProvider] out of the tree, so what a host has to
/// supply is a `Repository` and a `DeviceServices`. The direction is imposed
/// through `MaterialApp.builder` because the app ships one language and it
/// reads left to right — `MaterialApp` installs its own `Directionality` from
/// the resolved locale and would overwrite one wrapped around it.
Widget _host(
  Repository repository,
  Conversation conversation, {
  DeviceServices? services,
  double textScale = 1,
  bool rtl = false,
}) {
  final DeviceServices bag = services ?? _services();
  return MultiProvider(
    providers: <SingleChildWidget>[
      Provider<Repository>.value(value: repository),
      Provider<DeviceServices>.value(value: bag),
      ChangeNotifierProvider<CaptureSignal>(create: (_) => CaptureSignal()),
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
      home: ThreadScreen(conversation: conversation),
    ),
  );
}

/// Steps outside the fake clock so the database's real work can land, then
/// draws whatever arrived, until [finder] matches.
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

Future<void> _settle(WidgetTester tester, {int turns = 30}) async {
  for (int i = 0; i < turns; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}
