/// The app itself, boot to first screen.
///
/// What is left here is only what no screen test can cover, because it is
/// about the thing above all three of them: `ReplyboxApp` builds a real tree
/// over a real database with no-op device services, resolves its localisations,
/// and lands on the conversation list without anything escaping. Everything
/// each screen then draws is asserted in `inbox_screen_test.dart`,
/// `thread_screen_test.dart` and `included_apps_test.dart`, and section 9's
/// launch — PERM-4's one-per-install disclosure, PERM-8's banner, PERM-14's
/// guidance — in `permissions_screens_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/main.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:replybox/services/services.dart';

import 'helpers.dart';

void main() {
  setUpAll(initTestDatabases);

  testWidgets('the app boots on the conversation list, in words from the '
      'message files', (WidgetTester tester) async {
    final DBHelper db = testDb();
    // Registered before anything can fail, so a failed expectation still
    // closes the database — an in-memory one left open outlives the test and
    // the next one opens behind it.
    addTearDown(() async => db.close());

    final Repository repository = Repository(db);
    // A phone that has been through onboarding, and not a fresh install.
    //
    // Both halves matter and both are section 9's doing. With access off,
    // PERM-8 says the banner *replaces* INB-15's *Nothing yet* outright, so an
    // empty database would draw the banner and this test would be asserting a
    // sentence the rules say is not there. With the disclosure never shown,
    // PERM-4 pushes it over the list on the first launch. Both are real and
    // both are pinned where they belong; what is left here is the one thing
    // only this file can see — the whole tree standing up over a real database
    // and landing on the list.
    //
    // The two facts are written through the repository, which is the only
    // place they are ever written from: PERM-5 forbids a stored flag that
    // unlocks anything, and these unlock nothing. They record that two screens
    // were once displayed.
    //
    // Inside `runAsync` because inside `testWidgets` the clock is faked, and a
    // real SQLite call awaited outside it never completes.
    await tester.runAsync(() async {
      await repository.markDisclosureShown(DateTime.utc(2026, 9, 1));
      await repository.markBatteryGuidanceShown(DateTime.utc(2026, 9, 1));
    });

    await tester.pumpWidget(
      ReplyboxApp(repository: repository, services: _servicesWithAccess()),
    );

    // INB-19: the list is the whole first screen in v1, and its title is drawn
    // before any read returns. A missing message file fails at runtime rather
    // than at compile time (LANG-2), so this is the check that the wiring
    // resolved a real line.
    expect(find.text('Inbox'), findsOneWidget);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).theme,
      isNotNull,
    );

    // The cold-start read lands, and INB-15's *Nothing yet* is what an empty
    // database draws. Each turn steps outside the fake clock so the real work
    // can complete, then pumps to draw whatever arrived — `pumpAndSettle`
    // would wait on a frame that is waiting on a clock that is not running.
    for (int i = 0; i < 60; i++) {
      if (find.text('Nothing yet').evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Nothing yet'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // PERM-13, at the level only this file reaches: with access granted and
    // the listener silent about itself, the app has learned nothing about the
    // listener and says nothing about it. `NoopNotificationSource.connected`
    // is null by default for exactly this reason, so a line here would be the
    // app accusing a listener it never asked.
    expect(find.textContaining('Capture'), findsNothing);

    // The app comes down before the database under it closes: since section 9
    // a launch runs PERM-5's read, and a query left in flight over a closed
    // handle parks sqflite's queue for every test after this one.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  });
}

/// The no-op bag with notification access granted (PERM-5).
///
/// `noopServices()` answers false, which is the honest default for a device
/// with no listener to ask — and PERM-8 then draws its banner over everything
/// this file is about. Granting it here states the premise instead of leaving
/// it to a default that is about to change the screen.
DeviceServices _servicesWithAccess() {
  final DeviceServices base = noopServices();
  return DeviceServices(
    notifications: const NoopNotificationSource(access: true),
    captureFilter: base.captureFilter,
    packages: base.packages,
    reply: base.reply,
    launcher: base.launcher,
    reminders: base.reminders,
    entitlements: base.entitlements,
    appLock: base.appLock,
    systemSettings: base.systemSettings,
  );
}
