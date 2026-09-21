import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/main.dart';
import 'package:replybox/services/noop_services.dart';

import 'helpers.dart';

/// The app boots, with an in-memory database and no-op services.
///
/// These assert what is on screen, not that a widget exists: the point is that
/// the localisation wiring resolves a real message, because a missing one
/// fails at runtime rather than at compile time (LANG-2).
void main() {
  setUpAll(initTestDatabases);

  testWidgets('the app starts and says what it has, in words from the message '
      'files', (WidgetTester tester) async {
    final ({Repository repository, dynamic db}) t = await testRepository();

    await tester.pumpWidget(
      ReplyboxApp(repository: t.repository, services: noopServices()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Replybox'), findsOneWidget);
    expect(
      find.text(
        "Nothing yet. Messages from the apps you've included will appear here.",
      ),
      findsOneWidget,
    );

    await t.db.close();
  });

  testWidgets('it renders at 1.3x text without overflowing a phone screen', (
    WidgetTester tester,
  ) async {
    // LANG-6 asks for this on every screen in every language. There is one
    // screen and one language today; the harness is here so the next screen
    // inherits it rather than inventing it.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ({Repository repository, dynamic db}) t = await testRepository();

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: ReplyboxApp(repository: t.repository, services: noopServices()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    await t.db.close();
  });
}
