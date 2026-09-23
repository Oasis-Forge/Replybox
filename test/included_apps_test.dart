/// The included-apps list in Settings (INB-20 to INB-23).
///
/// This screen is where the app's one real choice lives, so the assertions are
/// about what the person reads before making it: which app each row is, what it
/// has, what the switch will do, and why an app they expected is not here at
/// all.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/l10n/app_localizations.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/providers/apps_provider.dart';
import 'package:replybox/screens/included_apps_screen.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:replybox/services/services.dart';
import 'package:replybox/widgets/source_app_row.dart';

import 'helpers.dart';

void main() {
  setUpAll(initTestDatabases);

  late Repository repo;
  late DBHelper db;

  /// Real database work cannot be awaited from a widget test's own zone: the
  /// fake clock never advances, so the future would never complete.
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

  /// The screen with its rows already read.
  ///
  /// The provider is filled before the first frame on purpose: a screen that
  /// opens on an empty one starts its read from `didChangeDependencies` and
  /// the provider notifies inside the build, which the framework reports as an
  /// error. That is its own defect and has its own test at the bottom of this
  /// file; every other test here would otherwise fail on it instead of on its
  /// own subject.
  Future<AppsProvider> open(
    WidgetTester tester, {
    DeviceServices? services,
    double textScale = 1,
    bool rtl = false,
  }) async {
    final DeviceServices bag = services ?? _services();
    final AppsProvider apps = AppsProvider(repo, bag);
    await tester.runAsync(apps.load);
    await tester.pumpWidget(
      _host(
        repository: repo,
        services: bag,
        apps: apps,
        textScale: textScale,
        rtl: rtl,
      ),
    );
    await _settle(tester);
    return apps;
  }

  group('INB-21 the rows and their order', () {
    testWidgets('one row in each of the four groups comes back in one exact '
        'order', (WidgetTester tester) async {
      // Tall enough that every row is built: a `ListView` does not lay out what
      // is past the fold, and a finder cannot read a row that was never drawn.
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await seed(tester, (Repository repo) async {
        // Group 1: on, with a conversation captured.
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        await repo.insertConversation(aConversation(title: 'Ada Lovelace'));
        // Group 3: off, and seen posting.
        await repo.upsertSeenApp(
          package: 'org.telegram.messenger',
          label: 'Telegram',
          enabledIfNew: true,
          at: t0,
        );
        await repo.setAppEnabled(
          'org.telegram.messenger',
          enabled: false,
          at: t0,
        );
        // Group 4: off, never seen posting — a row that exists only because a
        // switch moved.
        await repo.setAppEnabled(
          'org.thoughtcrime.securesms',
          enabled: false,
          at: t0,
          labelIfNew: 'Signal',
        );
      });

      await open(tester);

      // Group 2 is every shipped app the listener has not seen yet, which has
      // no stored label and so draws INB-1's last fallback, the package name.
      expect(
        _topToBottom(tester, <String>[
          'WhatsApp',
          'com.facebook.orca',
          'com.google.android.apps.messaging',
          'com.instagram.android',
          'Telegram',
          'Signal',
        ]),
        <String>[
          'WhatsApp',
          'com.facebook.orca',
          'com.google.android.apps.messaging',
          'com.instagram.android',
          'Telegram',
          'Signal',
        ],
      );
    });

    testWidgets('INB-21 a group sorts by the name the row draws, not by the '
        'label the listener happened to store', (WidgetTester tester) async {
      // The hand drill of 23 September 2026 opened this screen at first launch
      // and read: com.facebook.orca, Messages, com.instagram.android,
      // com.whatsapp, org.telegram.messenger, org.thoughtcrime.securesms —
      // exactly package order, with the one row that has a resolved name
      // sitting where its package name would put it. On a phone with all six
      // installed, every row has a name and the whole group reads as unsorted.
      // First launch: nothing seeded, so no shipped row has a stored label and
      // every name on the screen is the package manager's. That is the case
      // INB-21 was getting wrong — the sort was reading the middle branch of
      // INB-1's chain, which is empty here, while the rows were drawing the
      // first.
      await open(
        tester,
        services: _services(
          identities: const <String, SourceAppIdentity>{
            'com.google.android.apps.messaging': SourceAppIdentity(
              package: 'com.google.android.apps.messaging',
              presence: PackagePresence.installed,
              label: 'Messages',
            ),
          },
        ),
      );

      expect(
        _topToBottom(tester, <String>[
          'com.facebook.orca',
          'com.instagram.android',
          'com.whatsapp',
          'Messages',
          'org.telegram.messenger',
          'org.thoughtcrime.securesms',
        ]),
        <String>[
          'com.facebook.orca',
          'com.instagram.android',
          'com.whatsapp',
          'Messages',
          'org.telegram.messenger',
          'org.thoughtcrime.securesms',
        ],
        reason:
            'INB-21: alphabetical by the label, and `Messages` is the '
            'label — `com.google.android.apps.messaging` is the fallback the '
            'row is not drawing',
      );
    });

    testWidgets('INB-21 two rows on the same timestamp fall back to the name '
        'the row draws', (WidgetTester tester) async {
      // The first group, so the rule's other three groups are not taken on
      // trust: the recency key ties and the label is what breaks it.
      await seed(tester, (Repository repo) async {
        for (final String package in <String>[
          'com.whatsapp',
          'org.telegram.messenger',
        ]) {
          await repo.upsertSeenApp(
            package: package,
            label: package,
            enabledIfNew: true,
            at: t0,
          );
          final Conversation c = aConversation(
            key: package,
            package: package,
            title: 'Someone',
          );
          await repo.insertConversation(c);
          await repo.insertMessageIfNew(
            aMessage(
              conversationId: c.id,
              text: 'hello',
              sentAt: t0,
              notificationKey: 'notif-$package',
            ),
          );
        }
      });

      await open(
        tester,
        services: _services(
          identities: const <String, SourceAppIdentity>{
            // Resolved names that sort the opposite way round from their
            // packages, so package order and label order cannot both be right.
            'com.whatsapp': SourceAppIdentity(
              package: 'com.whatsapp',
              presence: PackagePresence.installed,
              label: 'Zebra chat',
            ),
            'org.telegram.messenger': SourceAppIdentity(
              package: 'org.telegram.messenger',
              presence: PackagePresence.installed,
              label: 'Aardvark chat',
            ),
          },
        ),
      );

      expect(
        _topToBottom(tester, <String>['Aardvark chat', 'Zebra chat']),
        <String>['Aardvark chat', 'Zebra chat'],
        reason:
            'INB-21: within a group the label breaks the tie, and the '
            'label is INB-1s resolved chain',
      );
    });

    testWidgets('a row says how many conversations it has, or that nothing '
        'has arrived', (WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        await repo.insertConversation(aConversation(key: 'a', title: 'Ada'));
        await repo.insertConversation(aConversation(key: 'b', title: 'Grace'));
      });

      await open(tester);

      expect(find.text('2 conversations'), findsOneWidget);
      // INB-21: at first launch every shipped row sits in the second group and
      // says so rather than showing a zero.
      expect(find.text('Nothing has arrived yet'), findsWidgets);
    });

    testWidgets('the permanent line says why an app the user expected is '
        'missing', (WidgetTester tester) async {
      await open(tester);

      await tester.dragUntilVisible(
        find.text(
          'An app is missing until it posts a notification. Replybox never '
          'lists the apps on your phone, so it learns about one the first time '
          'it posts.',
        ),
        find.byType(Scrollable).last,
        const Offset(0, -80),
      );
      expect(
        find.text(
          'An app is missing until it posts a notification. Replybox never '
          'lists the apps on your phone, so it learns about one the first time '
          'it posts.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the search field appears once the list passes ten rows, and '
        'narrows it', (WidgetTester tester) async {
      await open(tester);
      // Six shipped rows and nothing else: no field yet.
      expect(find.text('Search apps'), findsNothing);

      await seed(tester, (Repository repo) async {
        for (int i = 0; i < 6; i++) {
          await repo.upsertSeenApp(
            package: 'com.example.app$i',
            label: 'Example $i',
            enabledIfNew: false,
            at: t0,
          );
        }
      });
      final AppsProvider apps = await open(tester);
      expect(apps.apps.length, greaterThan(10));

      expect(find.text('Search apps'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'example 3');
      await _settle(tester);
      expect(find.text('Example 3'), findsOneWidget);
      expect(find.text('Example 4'), findsNothing);
    });
  });

  group('INB-22 the switch and what it does', () {
    testWidgets('the screen states what the switch does rather than '
        'confirming it afterwards', (WidgetTester tester) async {
      await open(tester);

      expect(
        find.text(
          'Off means the next notification this app posts is not stored. What '
          'is already here stays.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('turning a row off stops capture at once and leaves what is '
        'already here', (WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        await repo.insertConversation(aConversation(title: 'Ada Lovelace'));
      });

      final DeviceServices services = _services();
      await open(tester, services: services);
      expect(find.text('1 conversation'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find
              .ancestor(of: find.text('WhatsApp'), matching: find.byType(Row))
              .first,
          matching: find.byType(Switch),
        ),
      );
      await _settle(tester);

      // INB-22, CAP-1: the listener is told from the moment the switch moves,
      // and not on some later resume.
      final NoopCaptureFilter filter =
          services.captureFilter as NoopCaptureFilter;
      expect(filter.lastPushed, isNot(contains('com.whatsapp')));
      expect(filter.lastPushedKnown, contains('com.whatsapp'));
      // The switch moving is the whole confirmation: no dialog stands after it.
      expect(find.byType(AlertDialog), findsNothing);
      // And what was captured stays on the screen it was captured for.
      expect(find.text('1 conversation'), findsOneWidget);
    });

    testWidgets('removing the stored messages is its own action, and it has '
        'an Undo', (WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
        await repo.insertConversation(aConversation(title: 'Ada Lovelace'));
      });

      await open(tester);
      expect(find.text('1 conversation'), findsOneWidget);

      await tester.tap(find.text('Remove stored messages'));
      await _until(tester, find.text('1 conversation removed'));
      expect(find.text('Nothing has arrived yet'), findsWidgets);

      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.text('Undo'));
      await _until(tester, find.text('1 conversation'));

      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
    });

    testWidgets('a row with nothing stored offers nothing to remove', (
      WidgetTester tester,
    ) async {
      await open(tester);
      expect(find.text('Remove stored messages'), findsNothing);
    });
  });

  group('INB-16 and INB-23', () {
    testWidgets('a row for an app that is no longer installed says so and '
        'keeps a working switch', (WidgetTester tester) async {
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        );
      });

      final DeviceServices services = _services(
        identities: const <String, SourceAppIdentity>{
          'com.whatsapp': SourceAppIdentity(
            package: 'com.whatsapp',
            presence: PackagePresence.gone,
          ),
        },
      );
      await open(tester, services: services);

      expect(find.text('No longer installed'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find
              .ancestor(of: find.text('WhatsApp'), matching: find.byType(Row))
              .first,
          matching: find.byType(Switch),
        ),
      );
      await _settle(tester);
      expect(
        (services.captureFilter as NoopCaptureFilter).lastPushed,
        isNot(contains('com.whatsapp')),
      );
    });
  });

  group('INB-23 the included-apps list at 1.3x text, mirrored, and reachable', () {
    /// A phone-size screen, in logical pixels.
    ///
    /// INB-23 names a phone, and a phone is where the rule can fail: the
    /// 800x600 a widget test defaults to is wider than any of them, so a row
    /// that overflows on a phone lays out comfortably on it.
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    /// Two apps whose labels are longer than any English one, one of them with
    /// something stored so its row carries a count and a remove control
    /// (INB-21, INB-22).
    Future<void> seedLongLabels(WidgetTester tester) =>
        seed(tester, (Repository repo) async {
          await repo.upsertSeenApp(
            package: 'com.whatsapp',
            label: _longLabel,
            enabledIfNew: true,
            at: t0,
          );
          await repo.upsertSeenApp(
            package: 'org.telegram.messenger',
            label: _otherLongLabel,
            enabledIfNew: true,
            at: t0,
          );
          await repo.insertConversation(aConversation(title: 'أدا لوفليس'));
        });

    testWidgets('a filled list draws every row inside a phone screen at 1.3x, '
        'in words a longer language would need', (WidgetTester tester) async {
      // A phone's width, which is what INB-23's overflow is a question about,
      // and more height than a phone has, which is not: a `ListView` does not
      // lay out what is past the fold, so a row nobody scrolled to is a row
      // this test could not have measured.
      tester.view.physicalSize = const Size(1080, 4800);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await seedLongLabels(tester);

      await open(tester, textScale: 1.3);
      final AppLocalizations l10n = _l10n(tester);

      // The rows are populated, not the first-launch shape: a label, INB-21's
      // count, and INB-22's own action on the row that has something to remove.
      expect(find.text(_longLabel), findsOneWidget);
      expect(find.text(_otherLongLabel), findsOneWidget);
      _fitsThePhone(tester, <String>[
        l10n.includedAppsTitle,
        _longLabel,
        _otherLongLabel,
        l10n.includedAppsConversations(1),
        l10n.includedAppsRemoveMessages,
        l10n.includedAppsNothingYet,
      ]);
    });

    testWidgets('INB-21 the icon and label lead and the switch trails, and '
        'the two swap in a right-to-left language', (
      WidgetTester tester,
    ) async {
      phone(tester);
      await seedLongLabels(tester);

      await open(tester, textScale: 1.3);
      final double ltrSwitch = tester.getTopLeft(find.byType(Switch).first).dx;
      final double ltrLabel = tester.getTopLeft(find.text(_longLabel)).dx;
      // Left to right: the label leads on the left and the switch trails on
      // the right.
      expect(ltrLabel, lessThan(ltrSwitch));

      await open(tester, textScale: 1.3, rtl: true);
      final double rtlSwitch = tester.getTopLeft(find.byType(Switch).first).dx;
      final double rtlLabel = tester.getTopLeft(find.text(_longLabel)).dx;
      // INB-23: the same row, mirrored. Asserting the pair swapped, rather
      // than one side on its own, is what makes this a mirror test.
      expect(
        rtlSwitch,
        lessThan(rtlLabel),
        reason: 'INB-23: the row did not mirror',
      );
      _fitsThePhone(tester, <String>[_longLabel]);
    });

    testWidgets('every switch and every remove control is at least 48dp on '
        'its shorter side and says what it is, in words from the message '
        'files', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        phone(tester);
        await seedLongLabels(tester);

        await open(tester, textScale: 1.3);
        final AppLocalizations l10n = _l10n(tester);

        // Every switch the list drew, not just the first: a row further down
        // is where a floor gets lost (INB-23).
        final int switches = find.byType(Switch).evaluate().length;
        expect(switches, greaterThanOrEqualTo(2));
        for (int i = 0; i < switches; i++) {
          final Size size = tester.getSize(find.byType(Switch).at(i));
          expect(
            min(size.width, size.height),
            greaterThanOrEqualTo(48),
            reason: 'INB-23: switch $i is $size',
          );
        }

        // INB-22's removal is a separate control on the same row, so it has
        // its own target and its own line (INB-23).
        final Finder remove = find
            .ancestor(
              of: find.text(l10n.includedAppsRemoveMessages),
              matching: find.byType(TextButton),
            )
            .first;
        final Size removeSize = tester.getSize(remove);
        expect(
          min(removeSize.width, removeSize.height),
          greaterThanOrEqualTo(48),
          reason: 'INB-23: the remove control is $removeSize',
        );

        // Each says which app it is about, because a reader stepping down the
        // list hears the same two words on every row otherwise.
        expect(
          tester.getSemantics(find.byType(Switch).first).label,
          contains(l10n.semanticsAppSwitch(_longLabel)),
        );
        expect(
          tester.getSemantics(remove).label,
          contains(l10n.semanticsRemoveMessages(_longLabel)),
        );
      } finally {
        // Not an `addTearDown`: the binding checks that no semantics handle
        // outlives the test, and it checks before tear-downs run.
        handle.dispose();
      }
    });
  });

  group('gaps found while testing', () {
    testWidgets('INB-20 opening the included-apps list does not report an '
        'error', (WidgetTester tester) async {
      // The screen starts its first read from `didChangeDependencies`, and
      // `AppsProvider.load` raises its loading flag and notifies
      // synchronously — so every cold open of this screen marks a provider
      // dirty in the middle of the build the provider is being read in, and
      // the framework reports it. It is the path the real app always takes:
      // `main.dart` builds this provider empty and nothing fills it until the
      // screen is opened.
      final DeviceServices services = _services();
      await tester.pumpWidget(
        _host(
          repository: repo,
          services: services,
          apps: AppsProvider(repo, services),
        ),
      );
      await _settle(tester);

      expect(find.text('Included apps'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'INB-20: opening the chooser reports a build-time setState',
      );
    });
  });

  group('INB-22 what the row says when the switch did not take', () {
    testWidgets('a switch the listener never heard about leaves a sentence on '
        'its own row', (WidgetTester tester) async {
      // The worst of the three failures and the one nothing on screen betrays:
      // the switch is on, the row on disk is on, and CAP-1's filter is still
      // working from the old set — so every notification this package posts is
      // dropped before the queue, messages gone rather than late, until the
      // next launch re-mirrors. INB-22 is why it has to be said.
      await seed(tester, (Repository repo) async {
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: false,
          at: t0,
        );
      });

      final DeviceServices services = _services(
        captureFilter: _UnreachableCaptureFilter(),
      );
      await open(tester, services: services);

      await tester.tap(_switchOn('WhatsApp'));
      await _settle(tester);

      final AppLocalizations l10n = _l10n(tester);
      // On the row that moved, not in a snackbar that is gone by the time it
      // matters and not at the top of a list of twelve.
      expect(
        find.descendant(
          of: _rowFor('WhatsApp'),
          matching: find.text(l10n.includedAppsSwitchOnNotLive),
        ),
        findsOneWidget,
        reason:
            'INB-22: the switch went on, the listener never heard it, and the '
            'row says nothing',
      );
      // Switched on is the direction that loses messages, and the two
      // directions do not cost the same, so they do not read the same either.
      expect(
        find.text(l10n.includedAppsSwitchOffNotLive),
        findsNothing,
        reason: 'the line for the other direction is on the wrong row',
      );
      _noExceptionOnScreen(tester);
    });

    testWidgets('a write that did not land says so on the row, and never in '
        "the exception's own words", (WidgetTester tester) async {
      // INB-24: `Repository` composes its failures out of the `Message` it was
      // writing, so an exception that reached the screen would put a sender
      // and a message's text on it — and a switch row is drawn on a locked
      // screen and read aloud.
      final _FailingRepository failing = _FailingRepository(db);
      await tester.runAsync(
        () => failing.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: t0,
        ),
      );

      final DeviceServices services = _services();
      final AppsProvider apps = AppsProvider(failing, services);
      await tester.runAsync(apps.load);
      await tester.pumpWidget(
        _host(repository: failing, services: services, apps: apps),
      );
      await _settle(tester);

      failing.failWrites = true;
      await tester.tap(_switchOn('WhatsApp'));
      await _settle(tester);

      final AppLocalizations l10n = _l10n(tester);
      expect(
        find.descendant(
          of: _rowFor('WhatsApp'),
          matching: find.text(l10n.changeFailed),
        ),
        findsOneWidget,
        reason: 'INB-22: the write failed and the row said nothing',
      );
      // Nothing moved, so the switch is where it started and the row can
      // simply be used again.
      expect(
        tester.widget<Switch>(_switchOn('WhatsApp')).value,
        isTrue,
        reason: 'the switch moved on screen for a write that never landed',
      );
      _noExceptionOnScreen(tester);
    });
  });
}

// --- scaffolding ---------------------------------------------------------

/// The words a `Repository` exception carries, which INB-24 forbids any screen
/// from drawing: the sender and the text of the message it was writing.
const String _forbiddenSender = 'Ada Lovelace';
const String _forbiddenText = 'are we still on for six';

/// INB-24: no `Text` anywhere in the tree quotes the exception.
///
/// Walked over every `Text` rather than asserted with `find.text`, because the
/// defect this guards is a sentence that *contains* the exception — a line from
/// the message files with `$e` interpolated into it — which an equality finder
/// passes straight over.
void _noExceptionOnScreen(WidgetTester tester) {
  for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
    final String? drawn = text.data ?? text.textSpan?.toPlainText();
    if (drawn == null) continue;
    for (final String forbidden in <String>[
      _forbiddenSender,
      _forbiddenText,
      'StateError',
      'Exception',
    ]) {
      expect(
        drawn.contains(forbidden),
        isFalse,
        reason: 'INB-24: "$drawn" carries the exception onto the screen',
      );
    }
  }
}

/// The whole row drawn for the app labelled [label].
Finder _rowFor(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(SourceAppRow));

/// That row's switch.
Finder _switchOn(String label) =>
    find.descendant(of: _rowFor(label), matching: find.byType(Switch));

/// A filter that cannot be told — INB-22's failure path, with an exception
/// shaped like the ones `Repository` composes (INB-24).
class _UnreachableCaptureFilter implements CaptureFilter {
  @override
  Future<void> setEnabledPackages(
    List<String> packages,
    List<String> known,
  ) async => throw StateError(
    'the listener could not be told while writing '
    '$_forbiddenSender: $_forbiddenText',
  );
}

/// A repository whose writes fail, carrying the message it was writing the way
/// the real one does (INB-24).
class _FailingRepository extends Repository {
  _FailingRepository(super.db);

  bool failWrites = false;

  @override
  Future<void> setAppEnabled(
    String package, {
    required bool enabled,
    required DateTime at,
    String? labelIfNew,
  }) {
    if (failWrites) {
      throw StateError(
        'the apps row refused the write while storing '
        '$_forbiddenSender: $_forbiddenText',
      );
    }
    return super.setAppEnabled(
      package,
      enabled: enabled,
      at: at,
      labelIfNew: labelIfNew,
    );
  }
}

/// App labels longer than any English one (INB-23, LANG-6).
///
/// The app ships one language, so the only way to push a row past the edge of
/// a phone is the data it draws, and an app's label is the longest thing on a
/// row. A box sized to fit `WhatsApp` and not a longer name is the defect this
/// coverage exists to catch.
const String _longLabel = 'واتساب للمراسلة الفورية والمكالمات المرئية';
const String _otherLongLabel = 'تيليجرام للرسائل السريعة والقنوات';

/// The message files the screen on the tester is actually resolving.
AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

/// INB-23: the list fails on overflow.
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

DeviceServices _services({
  Map<String, SourceAppIdentity> identities =
      const <String, SourceAppIdentity>{},
  CaptureFilter? captureFilter,
}) => DeviceServices(
  notifications: const NoopNotificationSource(),
  captureFilter: captureFilter ?? NoopCaptureFilter(),
  packages: NoopPackageInfoService(identities: identities),
  reply: const NoopReplyService(),
  launcher: const NoopAppLauncher(),
  reminders: const NoopReminderScheduler(),
  entitlements: const NoopEntitlements(),
  appLock: const NoopAppLock(),
);

/// The screen with what it reads above it.
///
/// The direction is imposed through `MaterialApp.builder` because the app
/// ships one language and it reads left to right: `MaterialApp` installs its
/// own `Directionality` from the resolved locale and would overwrite one
/// wrapped around it.
Widget _host({
  required Repository repository,
  required DeviceServices services,
  required AppsProvider apps,
  double textScale = 1,
  bool rtl = false,
}) {
  return MultiProvider(
    providers: <SingleChildWidget>[
      Provider<Repository>.value(value: repository),
      Provider<DeviceServices>.value(value: services),
      ChangeNotifierProvider<AppsProvider>.value(value: apps),
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
      home: const IncludedAppsScreen(),
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
