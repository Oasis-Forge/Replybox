/// The app itself, boot to first screen.
///
/// What is left here is only what no screen test can cover, because it is
/// about the thing above all three of them: `ReplyboxApp` builds a real tree
/// over a real database with no-op device services, resolves its localisations,
/// and lands on the conversation list without anything escaping. Everything
/// each screen then draws is asserted in `inbox_screen_test.dart`,
/// `thread_screen_test.dart` and `included_apps_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/main.dart';
import 'package:replybox/services/noop_services.dart';

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

    await tester.pumpWidget(
      ReplyboxApp(repository: Repository(db), services: noopServices()),
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
  });
}
