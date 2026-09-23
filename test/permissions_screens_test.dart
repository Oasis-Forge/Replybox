/// Section 9's screens, as a person actually meets them (PERM-1 … PERM-8,
/// PERM-13, PERM-14, PERM-16, INB-23, INB-24).
///
/// Every assertion here is about what someone would read, how many taps it took
/// them, and what the app refused to say. That matters more in this area than
/// anywhere else in the app: the disclosure is the one screen whose whole job is
/// to be *true*, and a test that only proved a widget existed would pass on a
/// disclosure that rendered five empty strings, on a banner that stated a time
/// the app does not hold, and on battery guidance that quietly named a
/// manufacturer and told the user what it does to this app — the three failures
/// section 9 exists to prevent.
///
/// Two of the assertions below are made against the **source** rather than
/// against a screen, and both are deliberate:
///
///  * PERM-1's "the disclosure is the only route inside the app to the system
///    notification-access page" is a property of every file in `lib/`, not of
///    one screen. A widget test can show that this screen reaches the page; it
///    cannot notice a *second* caller somewhere else, which is the only way that
///    rule actually breaks. Same shape as `test/package_visibility_test.dart`.
///  * INB-24's "in any build" is the same argument: a line behind `kDebugMode`,
///    inside an `assert`, or on a path no test happens to reach is still a line
///    in the file.
///
/// The screens here are driven with the no-op services by default (the rule in
/// `lib/services/noop_services.dart`'s header), and `test/helpers.dart` is not
/// edited.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:replybox/data/shipped_apps.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/l10n/app_localizations.dart';
import 'package:replybox/main.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/providers/apps_provider.dart';
import 'package:replybox/providers/inbox_provider.dart' show CaptureSignal;
import 'package:replybox/providers/permissions_provider.dart';
import 'package:replybox/screens/battery_guidance_screen.dart';
import 'package:replybox/screens/disclosure_screen.dart';
import 'package:replybox/screens/included_apps_screen.dart';
import 'package:replybox/screens/privacy_policy_screen.dart';
import 'package:replybox/services/noop_services.dart';
import 'package:replybox/services/services.dart';
import 'package:replybox/theme.dart';
import 'package:replybox/widgets/capture_status_line.dart';
import 'package:replybox/widgets/date_separator.dart';
import 'package:replybox/widgets/message_time.dart';

import 'helpers.dart';

void main() {
  setUpAll(initTestDatabases);

  late Repository repo;
  late DBHelper db;

  /// The database is real and does real asynchronous work, so every seeding
  /// step has to happen outside the fake clock a widget test installs. Awaiting
  /// a database call straight from a `testWidgets` body hangs until the
  /// ten-minute timeout — the trap `inbox_screen_test.dart` is arranged around
  /// and this file inherits.
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

  /// A provider over this test's database, disposed with the test.
  ///
  /// [delay] is injected on every one of these, even where PERM-10's branch is
  /// not what the test is about: the default is a real ten-second
  /// `Future.delayed`, and a screen test that accidentally reached that branch
  /// would hang rather than fail. `clock` is left alone — the screens below date
  /// nothing from it, and the few that read a stored instant read one this test
  /// wrote.
  PermissionsProvider providerFor(DeviceServices services) {
    final PermissionsProvider permissions = PermissionsProvider(
      repo,
      services,
      delay: (Duration _) async {},
    );
    addTearDown(permissions.dispose);
    return permissions;
  }

  /// The disclosure, already on screen, with its first read done.
  ///
  /// Returns the provider so a test can drive PERM-5's re-read — the thing a
  /// return from the system page actually is — without reaching into the tree.
  /// [checkErrors] is false only in the two tests that make that assertion
  /// themselves, so a failure there names the rule rather than this helper; see
  /// [_noFrameworkErrorYet].
  Future<PermissionsProvider> openDisclosure(
    WidgetTester tester, {
    DeviceServices? services,
    double textScale = 1,
    bool rtl = false,
    bool checkErrors = true,
  }) async {
    final DeviceServices bag = services ?? _services();
    final PermissionsProvider permissions = providerFor(bag);
    await tester.runAsync(permissions.refresh);
    await tester.pumpWidget(
      _host(
        repository: repo,
        services: bag,
        permissions: permissions,
        home: const DisclosureScreen(),
        textScale: textScale,
        rtl: rtl,
      ),
    );
    if (checkErrors) _noFrameworkErrorYet(tester);
    await _settle(tester);
    return permissions;
  }

  /// The battery guidance, already on screen.
  Future<PermissionsProvider> openGuidance(
    WidgetTester tester, {
    DeviceServices? services,
    double textScale = 1,
    bool rtl = false,
    bool checkErrors = true,
  }) async {
    final DeviceServices bag = services ?? _services(access: true);
    final PermissionsProvider permissions = providerFor(bag);
    // PERM-14's two device facts are read by `refresh`, and only on a refresh
    // that finds access granted — which is the state the guidance is shown in.
    await tester.runAsync(permissions.refresh);
    await tester.pumpWidget(
      _host(
        repository: repo,
        services: bag,
        permissions: permissions,
        home: const BatteryGuidanceScreen(),
        textScale: textScale,
        rtl: rtl,
      ),
    );
    if (checkErrors) _noFrameworkErrorYet(tester);
    await _settle(tester);
    return permissions;
  }

  /// The privacy policy, already on screen.
  ///
  /// [onOpenHosted] is null by default because that is what `main.dart` passes:
  /// there is no seam in the app that opens a URL, and PERM-7 and PERM-14 both
  /// forbid a button that silently does nothing — so the absence of the control
  /// is the shipped state and a test that wants the other branch says so.
  Future<void> openPolicy(
    WidgetTester tester, {
    Future<void> Function(String url)? onOpenHosted,
    double textScale = 1,
    bool rtl = false,
  }) async {
    final DeviceServices bag = _services();
    await tester.pumpWidget(
      _host(
        repository: repo,
        services: bag,
        permissions: providerFor(bag),
        home: PrivacyPolicyScreen(onOpenHosted: onOpenHosted),
        textScale: textScale,
        rtl: rtl,
      ),
    );
    await _settle(tester);
  }

  group('PERM-1 the disclosure is the only route to the system page', () {
    test('nothing in lib/ asks for the system page except the disclosure', () {
      // PERM-1 is a property of every file in `lib/` and not of one screen: a
      // widget test can prove this screen reaches the page, but the way the rule
      // breaks in practice is a *second* caller — a banner that "helpfully"
      // skips the explanation, a Settings row wired straight to the intent, a
      // later area that wants the grant without the disclosure in front of it.
      // Each of those is one line that compiles, passes every other test, and
      // reads as perfectly ordinary code. So the call sites are counted, exactly
      // as `package_visibility_test.dart` counts asks about a package.
      //
      // Receiver-qualified on purpose. `Future<void> openAccessSettings();` in
      // `services.dart`, the `@override` in `noop_services.dart` and the
      // `_invoke<void>('openAccessSettings')` in `android_capture_service.dart`
      // are the seam itself being declared and implemented, not a caller.
      final RegExp asks = RegExp(r'\.openAccessSettings\s*\(');
      final Set<String> callers = <String>{
        for (final MapEntry<String, String> file in _dartSources('lib').entries)
          if (asks.hasMatch(file.value)) file.key,
      };

      expect(
        callers,
        <String>{
          // The state layer's own implementation: one `await` on the service,
          // wrapped in PERM-7's catch. This is the seam, and it is where the
          // throw becomes `canOpenAccessSettings == false` instead of an error
          // on a screen.
          'lib/providers/permissions_provider.dart',
          // The screen PERM-1 names, and the only one.
          'lib/screens/disclosure_screen.dart',
        },
        reason:
            'PERM-1: "the disclosure screen is the only route inside the app to '
            'the system notification-access page". Every other in-app entry '
            'point — the first launch, PERM-8\'s banner, the row at the foot of '
            'the included-apps list — has to push DisclosureScreen.routeName '
            'and let the user read what they are agreeing to first (decision '
            '6). Found: $callers',
      );
    });

    test('the two entry points that could skip it push the disclosure by '
        'name', () {
      // The other half of the same promise, and the half a call-site count
      // cannot see: a banner action or a Settings row that reached the system
      // page by some *other* route — a raw intent, a channel call of its own —
      // would add no `openAccessSettings` call anywhere. What both files do
      // instead is push the route constant, so that is what is asserted.
      for (final String path in <String>[
        'lib/screens/inbox_screen.dart',
        'lib/screens/included_apps_screen.dart',
      ]) {
        final String source = _dartSources('lib')[path]!;
        expect(
          source,
          contains('DisclosureScreen.routeName'),
          reason:
              'PERM-1: $path is an entry point that would lead to the system '
              'page, so it opens the disclosure first. Pushing the constant is '
              'what keeps that checkable — a string literal here would be one '
              'rename away from routing nowhere.',
        );
        expect(
          source,
          isNot(contains('MethodChannel')),
          reason:
              'PERM-1: a screen holding a channel of its own is a route to the '
              'system page this rule cannot see (INB-24 bans it outright).',
        );
      }
    });

    testWidgets('the disclosure carries one primary control and one decline, '
        'and both are on screen without scrolling', (
      WidgetTester tester,
    ) async {
      _phone(tester);
      await openDisclosure(tester);
      final AppLocalizations l10n = _l10n(tester);

      // PERM-1 fixes the count: one primary, one decline, and nothing else that
      // advances. Counted over every kind of button so a third control added as
      // a `TextButton` — the shape a "Learn more" link arrives in — fails here.
      expect(_buttons, findsNWidgets(2));
      expect(find.text(l10n.permissionsDisclosureTurnOn), findsOneWidget);
      expect(find.text(l10n.permissionsDisclosureDecline), findsOneWidget);

      // "Both reachable without scrolling" is a measurement, not a layout
      // opinion: the screen may scroll and the two actions may not (PERM-2), so
      // each one's box has to be inside the phone before anybody drags
      // anything.
      _onScreen(tester, find.text(l10n.permissionsDisclosureTurnOn), 'PERM-1');
      _onScreen(tester, find.text(l10n.permissionsDisclosureDecline), 'PERM-1');
    });

    testWidgets('nothing else on the disclosure advances', (
      WidgetTester tester,
    ) async {
      _phone(tester);
      await openDisclosure(tester);
      final AppLocalizations l10n = _l10n(tester);

      // PERM-1 lists what must not be here by name: no timer, no auto-advance,
      // no pre-ticked box, no "by continuing you agree". The first two are a
      // question about time, so time is what this spends — thirty seconds of
      // it, which is three times PERM-10's wait and long enough for any
      // plausible splash timer.
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(
        find.text(l10n.permissionsDisclosureTitle),
        findsOneWidget,
        reason: 'PERM-1: the disclosure advanced on its own',
      );
      expect(_buttons, findsNWidgets(2));

      // A box that is ticked before the user touches it is consent the app
      // gave itself. There is none on this screen in any state, so the
      // assertion is that the controls do not exist at all rather than that
      // they are unticked.
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(Switch), findsNothing);
      // By predicate rather than `find.byType`, which matches an exact runtime
      // type: a `Radio<String>` is not a `Radio<Object?>`, and a pre-selected
      // one is exactly the shape a "choose an option to continue" gate arrives
      // in.
      expect(find.byWidgetPredicate((Widget w) => w is Radio), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('PERM-2 what the disclosure says', () {
    testWidgets('all five lines are on the screen, each as its own line and in '
        "the rule's order", (WidgetTester tester) async {
      _phone(tester);
      await openDisclosure(tester);
      final AppLocalizations l10n = _l10n(tester);

      // PERM-2 says five things "each as its own line", which is a claim about
      // the tree and not only about the words: a screen that joined them into
      // one paragraph would contain every sentence and would have stopped being
      // five lines. `find.text` matches a `Text` whose whole data is the string,
      // so one match each is exactly that.
      final List<String> five = <String>[
        l10n.permissionsDisclosureReads,
        l10n.permissionsDisclosureUses,
        l10n.permissionsDisclosureStaysHere,
        // The fourth line is a heading with seven clauses under it; the heading
        // is the line, and the clauses are asserted in the next test.
        l10n.permissionsDisclosureLimitsTitle,
        l10n.permissionsDisclosureWithdraw,
      ];
      for (final String line in five) {
        expect(
          find.text(line),
          findsOneWidget,
          reason: 'PERM-2: a line is missing or is not a line of its own',
        );
      }

      // And in the order the rule fixes: what is read, what is done with it,
      // that it stays here, what it still cannot see, that it can be withdrawn.
      // Order matters here for the reason it matters in a contract — the
      // withdrawal sentence is the reassurance, and a screen that opened with it
      // would be answering a question the reader has not thought of yet.
      expect(_topToBottom(tester, five), five);
    });

    testWidgets('every absence CAP-12 lists is on the fourth line, in CAP-12\'s '
        'order', (WidgetTester tester) async {
      _phone(tester);
      await openDisclosure(tester);
      final AppLocalizations l10n = _l10n(tester);

      // CAP-12's four absences in CAP-12's order, then the three this area
      // meets first (CAP-8, CAP-14/INB-13, PERM-17). Written out here rather
      // than read from a list in `lib/` on purpose: this test is what fails when
      // CAP-12 grows an absence the disclosure does not carry, and a test that
      // iterated the screen's own list would pass on a screen that had quietly
      // dropped one.
      final List<String> clauses = <String>[
        l10n.permissionsDisclosureLimitBeforeInstall,
        l10n.permissionsDisclosureLimitAccessOff,
        l10n.permissionsDisclosureLimitAppOff,
        l10n.permissionsDisclosureLimitEdits,
        l10n.permissionsDisclosureLimitHidden,
        l10n.permissionsDisclosureLimitOpenInApp,
        l10n.permissionsDisclosureLimitWorkProfile,
      ];
      for (final String clause in clauses) {
        expect(
          find.text(clause),
          findsOneWidget,
          reason: 'PERM-2: an absence CAP-12 names is not on the disclosure',
        );
      }
      expect(_topToBottom(tester, clauses), clauses);

      // Under the heading, not scattered through the screen: the fourth line is
      // one line, and a clause drawn above its own heading is a sentence the
      // reader meets with no idea what it is a list of.
      final double heading = tester
          .getTopLeft(find.text(l10n.permissionsDisclosureLimitsTitle))
          .dy;
      for (final String clause in clauses) {
        expect(
          tester.getTopLeft(find.text(clause)).dy,
          greaterThan(heading),
          reason: 'PERM-2: a clause sits above the line it belongs to',
        );
      }
    });
  });

  group('PERM-3 the apps captured without being chosen', () {
    testWidgets('every shipped-list app is displayed in full', (
      WidgetTester tester,
    ) async {
      _phone(tester);
      await openDisclosure(tester);
      final AppLocalizations l10n = _l10n(tester);

      // Driven from the constant, which is the whole point of the rule: PERM-3
      // says the list is rendered "from the same constant the listener filters
      // against and the chooser reads ... and never from a second copy", and a
      // test that spelt out six package names would be that second copy. Adding
      // an app to `shippedMessagingApps` has to break this test rather than
      // silently enlarge the set of apps captured without anyone being told.
      expect(
        shippedMessagingApps,
        isNotEmpty,
        reason:
            'PERM-3 scanned nothing: the shipped constant is empty, so this '
            'test would pass on a disclosure that named no apps at all.',
      );
      for (final String package in shippedMessagingApps) {
        // The no-op package service answers `unknown` for everything, so
        // `sourceAppLabel`'s chain ends where it is designed to end: at the
        // package name. That is the name on screen here, and it is the one
        // string that is certain to be the *right* one for this package.
        expect(
          find.text(package),
          findsOneWidget,
          reason:
              'PERM-3: $package can start enabled and the disclosure does not '
              'display it. "A test fails if any package can start enabled whose '
              'label the disclosure does not display."',
        );
      }

      // The sentence beside the list, which is the half that says what the list
      // *means* — captured as soon as they post, without the user naming them.
      expect(find.text(l10n.permissionsDisclosureAppsTitle), findsOneWidget);
      expect(
        find.text(l10n.permissionsDisclosureAppsExplainer),
        findsOneWidget,
      );

      // No truncation, no "and others", no collapsed row. Checked two ways,
      // because they fail differently: a `maxLines` clips a name and reports
      // nothing at all, while a summarising string is a sentence somebody wrote.
      //
      // Scoped to the scrolling text, which is where PERM-2's claims and
      // PERM-3's list both live. The `AppBar`'s own title is deliberately out
      // of scope: Material ellipsizes a toolbar title by design, and this one
      // is long enough to reach that on a phone — which is a fact about the app
      // bar and not about whether the app named the apps it captures.
      final Finder scrollingText = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Text),
      );
      for (final RenderParagraph line
          in tester.renderObjectList<RenderParagraph>(scrollingText)) {
        expect(
          line.didExceedMaxLines,
          isFalse,
          reason: 'PERM-3: something on the disclosure is truncated',
        );
      }
      final RegExp summarised = RegExp(
        r'and others|and \d+ more|…|\.\.\.',
        caseSensitive: false,
      );
      for (final String drawn in _allText(tester)) {
        expect(
          summarised.hasMatch(drawn),
          isFalse,
          reason:
              'PERM-3: the app list was summarised rather than shown: '
              '"$drawn"',
        );
      }
    });

    testWidgets('a shipped-list app that is not installed is shown and marked', (
      WidgetTester tester,
    ) async {
      _phone(tester);
      const String absent = 'org.thoughtcrime.securesms';
      await openDisclosure(
        tester,
        services: _services(
          identities: const <String, SourceAppIdentity>{
            absent: SourceAppIdentity(
              package: absent,
              presence: PackagePresence.gone,
            ),
            'com.whatsapp': SourceAppIdentity(
              package: 'com.whatsapp',
              presence: PackagePresence.installed,
              label: 'WhatsApp',
            ),
          },
        ),
      );
      final AppLocalizations l10n = _l10n(tester);

      // Shown like the rest — the point of naming it is that the user can
      // switch it off before it ever posts — and marked, because INB-16's
      // `<queries>` is what lets the app tell.
      expect(find.text(absent), findsOneWidget);
      expect(
        find.text(l10n.permissionsDisclosureAppNotInstalled),
        findsOneWidget,
        reason: 'PERM-3: a package the phone does not have is not marked',
      );

      // Exactly one marker, and beside the right name. INB-16's three values are
      // three different facts: `unknown` is nothing learned, and a screen that
      // marked those would tell a user that apps they are holding in their hand
      // are missing.
      expect(
        tester
            .getTopLeft(find.text(l10n.permissionsDisclosureAppNotInstalled))
            .dy,
        greaterThan(tester.getTopLeft(find.text(absent)).dy - 1),
      );
      expect(
        find.text('WhatsApp'),
        findsOneWidget,
        reason: "PERM-3: an installed app's own label is what is shown",
      );
    });
  });

  group('PERM-4 declining leaves a whole app', () {
    testWidgets('declining is one tap, and the inbox, the chooser and the rest '
        'still work afterwards', (WidgetTester tester) async {
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
      // PERM-4: "the disclosure opens without a tap exactly once per install,
      // on the first launch". Waited for rather than tapped towards — the count
      // below starts at zero and the first tap is the decline.
      await _until(tester, find.text('Continue without it'));
      _noFrameworkErrorYet(tester);

      int taps = 0;
      taps++;
      await tester.tap(find.text('Continue without it'));
      await _until(tester, find.text('Ada Lovelace'));
      // Settled as well as found: the list is underneath the disclosure the
      // whole time, so a finder that matched a row mid-pop would see the
      // disclosure still in the tree and read as a permission wall that is
      // merely halfway through an animation.
      await _settle(tester);
      expect(taps, 1, reason: 'PERM-4: declining is one tap');

      // No permission wall: the screen behind the disclosure is the app, with
      // its rows on it, and the disclosure is gone rather than replaced by a
      // "grant access to continue" page.
      expect(find.text('Before you turn on notification access'), findsNothing);
      expect(find.text('the engine works'), findsOneWidget);

      // "Nothing is greyed out". Counted over every button on the screen rather
      // than over the ones this test happened to think of: a disabled control is
      // a `ButtonStyleButton` with a null `onPressed`, whichever one it is.
      _nothingDisabled(tester, 'PERM-4');

      // And the chooser — the screen that holds the app's one real choice — is
      // still reachable and still works. INB-20's route is the app-bar control,
      // found by the label a screen reader would use.
      final AppLocalizations l10n = _l10n(tester);
      await tester.tap(find.bySemanticsLabel(l10n.semanticsIncludedApps));
      await _until(tester, find.byType(IncludedAppsScreen));
      await _until(tester, find.byType(Switch));
      for (final Switch control in tester.widgetList<Switch>(
        find.byType(Switch),
      )) {
        expect(
          control.onChanged,
          isNotNull,
          reason: 'PERM-4: a switch in the chooser is dead after a decline',
        );
      }
      _nothingDisabled(tester, 'PERM-4');

      // The included-apps screen starts its first read from
      // `didChangeDependencies` and its provider notifies synchronously, so the
      // framework reports a build-time `setState` every time it is opened. That
      // is its own defect and its own failing test, in `included_apps_test.dart`;
      // it is drained here so this test fails only on its own subject.
      while (tester.takeException() != null) {}
    });

    testWidgets('a second launch after a decline does not offer the disclosure '
        'again, and the banner still does', (WidgetTester tester) async {
      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      await _until(tester, find.text('Continue without it'));
      _noFrameworkErrorYet(tester);
      await tester.tap(find.text('Continue without it'));
      await _settle(tester);

      // A second launch over the same database. Keyed so this is a relaunch and
      // not the same tree updated — the state that pushed the first disclosure
      // goes with the run that was killed.
      await tester.pumpWidget(
        ReplyboxApp(
          key: const ValueKey<String>('relaunch'),
          repository: repo,
          services: _services(),
        ),
      );
      await _until(tester, find.textContaining('Capture has never been on.'));
      await _settle(tester);

      expect(
        find.text('Before you turn on notification access'),
        findsNothing,
        reason:
            'PERM-4: the disclosure opens without a tap exactly once per '
            'install',
      );

      // "That is not a stored suppression of the offer (PERM-1): the banner is
      // always present and always opens it." One tap, from the screen the user
      // lands on, and the disclosure is back.
      await tester.tap(find.text('How to turn it on'));
      await _until(tester, find.text('Before you turn on notification access'));
      _noFrameworkErrorYet(tester);
      expect(find.text('Continue without it'), findsOneWidget);
    });
  });

  group('PERM-5 a grant made in the system\'s own settings app', () {
    testWidgets('the disclosure is shown as information: the same lines, the '
        'same app list, and Continue where the decline was', (
      WidgetTester tester,
    ) async {
      _phone(tester);
      // PERM-5's path: the listener can bind while the Flutter app is dead, so
      // a launch can find access already granted with the disclosure never
      // displayed. The screen is then shown once over the first screen as
      // information — because onboarding is marked done only once it has
      // actually been on screen, and until then the app would be capturing from
      // apps the user did not name without having said so first (decision 6).
      final _Access access = _Access(granted: true);
      await openDisclosure(tester, services: _services(notifications: access));
      final AppLocalizations l10n = _l10n(tester);

      // "The same lines (PERM-2) and the same app list (PERM-3)" — the grant
      // does not buy the user a shorter version of what they agreed to.
      expect(find.text(l10n.permissionsDisclosureReads), findsOneWidget);
      expect(find.text(l10n.permissionsDisclosureStaysHere), findsOneWidget);
      expect(find.text(l10n.permissionsDisclosureLimitsTitle), findsOneWidget);
      for (final String package in shippedMessagingApps) {
        expect(find.text(package), findsOneWidget);
      }

      // "With a route back to the system page beside `Continue`" — and no
      // decline, because there is nothing here left to decline.
      expect(find.text(l10n.permissionsDisclosureContinue), findsOneWidget);
      expect(
        find.text(l10n.permissionsDisclosureDecline),
        findsNothing,
        reason:
            'PERM-5: the screen offered to decline a grant the user has '
            'already made in the system\'s own settings app',
      );
      expect(_buttons, findsNWidgets(2));

      // PERM-6's extra line is not this: access is on, so there is nothing
      // still off to report.
      expect(find.text(l10n.permissionsDisclosureStillOff), findsNothing);

      // The route back is a real route, and it is still the only one in the app
      // (PERM-1).
      await tester.tap(find.text(l10n.permissionsDisclosureTurnOn));
      await _settle(tester);
      expect(access.opened, 1);
    });

    testWidgets('the disclosure records its own showing without marking the '
        'screen under it dirty', (WidgetTester tester) async {
      // Found while writing the tests above, and red until the state layer
      // changed one word — **fixed on 23 September 2026 and green since.**
      // PERM-5 says the fact recorded is that the screen was *displayed*, so
      // the write is made from `initState`, and
      // `PermissionsProvider.markDisclosureShown` used to announce it with
      // `notify()`, synchronously, while the framework was still building this
      // screen. The provider is above `MaterialApp` in `main.dart` exactly as
      // it is here, so what Flutter saw was an ancestor being marked dirty from
      // inside a descendant's build, which it refuses: *setState() or
      // markNeedsBuild() called during build*.
      //
      // What a person saw was a red frame on the first launch of a fresh
      // install — the one launch every user of this app has, and the launch the
      // whole of section 9 is written for.
      //
      // The fix was in `lib/providers/permissions_provider.dart` and not here:
      // `markDisclosureShown` and `markBatteryGuidanceShown` announce with
      // `notifyLater()`, which is the discipline `_announce` in that same file
      // already documents — "a screen's first read of this provider runs inside
      // the build that is reading it". Making this test drain the error instead
      // would have recorded the defect as the design. It is kept as the guard,
      // because the same stack now has a second writer on it: this provider
      // reads on a capture signal (PERM-8, PERM-10), and a signal is delivered
      // synchronously on whatever stack fired it.
      _phone(tester);
      await openDisclosure(tester, checkErrors: false);

      expect(
        tester.takeException(),
        isNull,
        reason:
            'PERM-5: recording that the disclosure was displayed threw a '
            'framework error. markDisclosureShown notifies synchronously from '
            "the screen's initState; it has to announce with notifyLater().",
      );
    });

    testWidgets('the battery guidance records its own showing the same way', (
      WidgetTester tester,
    ) async {
      // The same defect through PERM-14's door, kept separate because the two
      // screens were fixed by two separate lines and a single test would have
      // gone green on half a fix.
      _tallPhone(tester);
      await openGuidance(tester, checkErrors: false);

      expect(
        tester.takeException(),
        isNull,
        reason:
            'PERM-14: recording that the guidance was shown threw a framework '
            'error. markBatteryGuidanceShown notifies synchronously from the '
            "screen's initState; it has to announce with notifyLater().",
      );
    });
  });

  group('PERM-6 the route from a fresh install', () {
    testWidgets('open the app, the disclosure, its primary button — one tap on '
        'a control and no screen in between', (WidgetTester tester) async {
      final _Access access = _Access();
      await tester.pumpWidget(
        ReplyboxApp(
          repository: repo,
          services: _services(notifications: access),
        ),
      );

      // Nothing is tapped to reach the disclosure: PERM-6's path is "open the
      // app ... the disclosure", and RUN-3's setup page does not exist yet, so
      // the screen after the launch is this one.
      await _until(tester, find.text('Before you turn on notification access'));
      _noFrameworkErrorYet(tester);
      int taps = 0;

      // "One tap on a control from the disclosure onward, and no screen in
      // between": the primary button is on the screen the app opened, and what
      // it reaches is the system page itself rather than another page of the
      // app's own.
      taps++;
      await tester.tap(find.text('Turn on notification access'));
      await _settle(tester);

      expect(
        taps,
        1,
        reason: 'PERM-6: more than one tap reached the system page',
      );
      expect(
        access.opened,
        1,
        reason:
            'PERM-6: the primary control did not reach the system page. It is '
            'the one control in the app that does (PERM-1).',
      );
      // And no screen was interposed: the disclosure is still what is on
      // screen, because the system page is the system's and this app cannot
      // draw over it.
      expect(
        find.text('Before you turn on notification access'),
        findsOneWidget,
      );
    });

    testWidgets('a return with access still missing shows the same disclosure '
        'with one extra line and the same single button', (
      WidgetTester tester,
    ) async {
      _phone(tester);
      final _Access access = _Access();
      final PermissionsProvider permissions = await openDisclosure(
        tester,
        services: _services(notifications: access),
      );
      final AppLocalizations l10n = _l10n(tester);

      // That the line is *absent* before the return is a separate rule and has
      // its own test below, because it does not hold today.

      await tester.tap(find.text(l10n.permissionsDisclosureTurnOn));
      await _settle(tester);
      // The return. PERM-5 is explicit that there is no "we came back" moment to
      // observe — the process can be killed while the system page is open — so
      // what a return *is* is another read of the system, which is what the
      // resume does and what this calls.
      await tester.runAsync(permissions.refresh);
      await _settle(tester);

      expect(
        find.text(l10n.permissionsDisclosureStillOff),
        findsOneWidget,
        reason: 'PERM-6: the return said nothing about access still being off',
      );
      // "The same disclosure ... and the same single button" — one extra line
      // and nothing else changed. Not a second screen, not an error dialog, and
      // not a second primary control offering to try again.
      expect(find.text(l10n.permissionsDisclosureTitle), findsOneWidget);
      expect(find.text(l10n.permissionsDisclosureReads), findsOneWidget);
      expect(_buttons, findsNWidgets(2));
      expect(find.text(l10n.permissionsDisclosureTurnOn), findsOneWidget);
      expect(find.text(l10n.permissionsDisclosureDecline), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the first showing of the disclosure does not already say '
        'access is still off', (WidgetTester tester) async {
      // Found while writing the test above, and failing until the state layer
      // changes. PERM-6 puts the extra line on a *return* — "a return with
      // access still missing shows the same disclosure with one extra line" —
      // and `disclosure_screen.dart` says the same in its own words: it is "an
      // answer to something the user just did", which is why it sits in the
      // fixed block beside the controls rather than at the top of the page.
      //
      // `PermissionsProvider.accessStillOff` is
      // `_disclosureShownThisRun && !_hasAccess`, and `_disclosureShownThisRun`
      // is set by `markDisclosureShown`, which the screen calls from its own
      // `initState`. So the condition is already true in the screen's first
      // build, and a first-time reader meets *Notification access is still off,
      // so nothing has been captured* before they have been asked for anything
      // — the app opening with a report of a failure the user has not had the
      // chance to cause. That is the register this whole area is written
      // against.
      //
      // The fix is in `lib/providers/permissions_provider.dart`: the line needs
      // a run-scoped fact about the user having been *sent to the system page*
      // — `openAccessSettings` having been called in this run — and not about
      // the screen having been drawn. PERM-5 is untouched by that: it forbids a
      // stored flag that unlocks a screen, and this one is neither stored nor
      // unlocks anything.
      _phone(tester);
      await openDisclosure(tester);
      final AppLocalizations l10n = _l10n(tester);

      expect(
        find.text(l10n.permissionsDisclosureStillOff),
        findsNothing,
        reason:
            'PERM-6: the disclosure said access was still off on the very '
            'first screen a new user sees, before they had been offered it.',
      );
    });
  });

  group('PERM-7 a settings page that will not open', () {
    testWidgets('the button is replaced by the written path, never left as a '
        'button that does nothing', (WidgetTester tester) async {
      _phone(tester);
      // PERM-7's third branch: a build can ship without that screen, and
      // `CaptureChannel.openAccessSettings` raises `no_settings_page` when
      // neither intent starts. `AndroidNotificationSource` deliberately does not
      // swallow it, so this is the shape the state layer actually receives.
      await openDisclosure(
        tester,
        services: _services(notifications: _Access(throwsOnOpen: true)),
      );
      final AppLocalizations l10n = _l10n(tester);

      // There is no honest probe — package-visibility filtering makes
      // `resolveActivity` unreliable on API 30 and up — so the only way to learn
      // that the page will not open is to have tried. The control is a control
      // until then.
      expect(find.text(l10n.permissionsDisclosureTurnOn), findsOneWidget);

      await tester.tap(find.text(l10n.permissionsDisclosureTurnOn));
      await _settle(tester);

      expect(
        find.text(l10n.permissionsDisclosureNoSettingsPage),
        findsOneWidget,
        reason: 'PERM-7: the app did not say where to find the page by hand',
      );
      expect(
        find.text(l10n.permissionsDisclosureTurnOn),
        findsNothing,
        reason:
            'PERM-7: the button that cannot work is still on screen. A greyed '
            'or a live control here both read as something that would work if '
            'the user pressed it correctly, and this one never will on this '
            'phone.',
      );
      // The decline is untouched: the page not opening is not a reason to trap
      // somebody on this screen (PERM-4).
      expect(find.text(l10n.permissionsDisclosureDecline), findsOneWidget);
      _nothingDisabled(tester, 'PERM-7');
      // And no error surfaced: the answer to a page that will not open is the
      // path to it, on screen, where the button was.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('PERM-8 the access banner and where it goes', () {
    /// The app, launched over this test's database with access off.
    Future<void> launch(WidgetTester tester) async {
      await tester.pumpWidget(
        ReplyboxApp(repository: repo, services: _services()),
      );
      // The disclosure is pushed on a fresh install, and PERM-8's banner is on
      // the screen underneath it. Declined first so the assertions below are
      // about the screen the user is actually looking at.
      await _until(tester, find.text('Continue without it'));
      _noFrameworkErrorYet(tester);
      await tester.tap(find.text('Continue without it'));
      await _settle(tester);
    }

    testWidgets('a window closed on a reported disconnection says "since", and '
        'draws above the rows when conversations are stored', (
      WidgetTester tester,
    ) async {
      await seed(tester, (Repository repo) async {
        final Conversation ada = aConversation(title: 'Ada Lovelace');
        await repo.insertConversation(ada);
        await repo.insertMessageIfNew(
          aMessage(conversationId: ada.id, text: 'the engine works'),
        );
        // PERM-9's exact close: the listener reported its own disconnection
        // inside that callback, with that callback's time.
        await repo.openCaptureSession(t0);
        await repo.closeCaptureSession(t0.add(const Duration(hours: 1)));
      });
      await launch(tester);
      await _until(tester, find.text('Ada Lovelace'));

      // Asserted on the invariant half of the sentence rather than on the whole
      // of it: the instant is formatted by `formatRowTime`, whose shape depends
      // on how long ago it was, and a test that rebuilt the formatted string
      // would be asserting the clock rather than the rule.
      final Finder banner = find.textContaining(
        'Capture is off. Nothing has been stored since ',
      );
      expect(banner, findsOneWidget);
      expect(
        find.textContaining('since at least'),
        findsNothing,
        reason:
            'PERM-9: this window was closed on a reported disconnection, so the '
            'end is exact and the banner may say "since" rather than hedging.',
      );

      // PERM-8's first placement: above the rows, and the rows are still there.
      // "Stored messages stay readable, searchable and deletable throughout."
      expect(
        tester.getTopLeft(banner).dy,
        lessThan(tester.getTopLeft(find.text('Ada Lovelace')).dy),
        reason: 'PERM-8: the banner did not draw above the rows',
      );
      expect(find.text('the engine works'), findsOneWidget);
    });

    testWidgets('a window closed on a later discovery says "since at least"', (
      WidgetTester tester,
    ) async {
      await seed(tester, (Repository repo) async {
        await repo.openCaptureSession(t0);
        // PERM-9's other close: the loss was found on a resume, the exact end is
        // unknown, and the row is closed at the last thing the app can prove and
        // flagged as an estimate.
        await repo.closeOpenCaptureSessionsAtLastEvidence(
          t0.add(const Duration(days: 1)),
        );
      });
      await launch(tester);
      await _until(
        tester,
        find.textContaining(
          'Capture is off. Nothing has been stored since at '
          'least ',
        ),
      );

      // The whole of the difference between this branch and the one above is
      // the hedge, and the hedge is the rule: "the app never prints the time it
      // noticed something as the time that thing happened".
      expect(
        find.textContaining('stored since at least'),
        findsOneWidget,
        reason: 'PERM-9: an estimated end was stated as an exact one',
      );
    });

    testWidgets('no window ever closed says capture has never been on, and the '
        'banner replaces Nothing yet', (WidgetTester tester) async {
      // Nothing seeded: a fresh install where access has never been granted,
      // which is the state a first-time user who declined is actually in.
      await launch(tester);
      await _until(tester, find.textContaining('Capture has never been on.'));

      expect(
        find.textContaining(
          'Replybox has stored nothing since it was installed on ',
        ),
        findsOneWidget,
        reason:
            'PERM-8: the third branch names `installed_at` rather than a '
            'time the app does not hold (CAP-12).',
      );

      // PERM-8's second placement, and the one that is easy to get wrong:
      // "replaces INB-15's *Nothing yet* outright". Two sentences about an empty
      // inbox is one too many — and the wrong one would be on top, because
      // *Nothing yet* names the included apps and offers the chooser while
      // access is off and none of them can post.
      expect(
        find.text('Nothing yet'),
        findsNothing,
        reason: 'PERM-8: the banner did not replace *Nothing yet*',
      );
      expect(find.text('See included apps'), findsNothing);
    });

    testWidgets('the banner is not dismissible and its one action opens the '
        'disclosure', (WidgetTester tester) async {
      await launch(tester);
      await _until(tester, find.textContaining('Capture has never been on.'));
      final AppLocalizations l10n = _l10n(tester);

      // "It is not dismissible, because the state it reports does not go away on
      // being tapped." PERM-11's line is the only one of the three that carries
      // a dismissal, so the assertion is that this control is absent entirely
      // rather than that it does nothing.
      expect(find.text(l10n.captureQuietDismiss), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);

      // "Its one action opens the disclosure (PERM-1), never the system page
      // directly."
      expect(find.text(l10n.captureOffAction), findsOneWidget);
      await tester.tap(find.text(l10n.captureOffAction));
      await _until(tester, find.text(l10n.permissionsDisclosureTitle));
      _noFrameworkErrorYet(tester);
      expect(find.text(l10n.permissionsDisclosureReads), findsOneWidget);
    });
  });

  group('PERM-13 one status line at a time', () {
    testWidgets('one value in, one sentence out, for every value the provider '
        'can resolve', (WidgetTester tester) async {
      // PERM-13's rule is "at most one status line shows above the first
      // screen's rows at a time", and the widget is where that becomes
      // unbreakable: it takes the one value `PermissionsProvider` resolved and
      // switches on it once. So the test drives every value through it and
      // counts sentences — a widget that stacked a fact, a probable and an
      // observation would produce two here on some value, whatever the screen
      // above it did.
      final DateTime now = DateTime.utc(2026, 9, 23, 12);
      final DateTime since = now.subtract(const Duration(days: 2));

      for (final CaptureStatusLine line in CaptureStatusLine.values) {
        await tester.pumpWidget(
          _noticeHost(line: line, since: since, now: now),
        );
        await tester.pump();

        final BuildContext context = tester.element(find.byType(Scaffold));
        final AppLocalizations l10n = AppLocalizations.of(context);
        // The five sentences the widget can draw, built with the app's own
        // formatters. This test is about *how many* lines are on screen, not
        // about the shape of the time, which is `message_time.dart`'s own
        // subject — so reusing the formatter here is what keeps the count exact
        // without asserting a format twice.
        final String time = formatRowTime(since, now, l10n.localeName);
        final List<String> everySentence = <String>[
          l10n.captureOffSince(time),
          l10n.captureOffSinceAtLeast(time),
          l10n.captureNeverOn(threadNoticeDate(context, since)),
          l10n.captureNotRunning,
          l10n.captureQuietSince(time),
        ];
        final List<String> onScreen = <String>[
          for (final String sentence in everySentence)
            if (find.text(sentence).evaluate().isNotEmpty) sentence,
        ];

        expect(
          onScreen,
          hasLength(line == CaptureStatusLine.none ? 0 : 1),
          reason:
              'PERM-13: $line drew ${onScreen.length} lines. The rule is at '
              'most one, and `none` is the branch that draws nothing at all — '
              'which is also what "the app has learned nothing" looks like '
              '(PERM-10).',
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('the dismissal is on PERM-11\'s line and on neither of the '
        'others', (WidgetTester tester) async {
      final DateTime now = DateTime.utc(2026, 9, 23, 12);
      final DateTime since = now.subtract(const Duration(days: 2));

      await tester.pumpWidget(
        _noticeHost(line: CaptureStatusLine.quiet, since: since, now: now),
      );
      await tester.pump();
      final AppLocalizations l10n = _l10n(tester);
      // PERM-11 carries two controls: its guidance link and the dismissal, in
      // that order, because the dismissal is the way out and not the offer.
      expect(find.text(l10n.captureGuidanceAction), findsOneWidget);
      expect(find.text(l10n.captureQuietDismiss), findsOneWidget);

      await tester.pumpWidget(
        _noticeHost(line: CaptureStatusLine.notRunning, since: null, now: now),
      );
      await tester.pump();
      // PERM-10's line has PERM-14 as its action and nothing else: the state it
      // reports does not go away on being tapped either.
      expect(find.text(l10n.captureGuidanceAction), findsOneWidget);
      expect(find.text(l10n.captureQuietDismiss), findsNothing);
      expect(find.text(l10n.captureOffAction), findsNothing);
    });

    testWidgets('a branch that names a time with no time to name says nothing '
        'at all', (WidgetTester tester) async {
      // PERM-9 and product principle 3: the app never prints a time it does not
      // hold. A banner reading *installed on 1 January 1970* would break that in
      // the one direction CAP-12 may not be wrong in, so the answer is silence
      // and INB-15's own state is left to speak.
      await tester.pumpWidget(
        _noticeHost(
          line: CaptureStatusLine.accessNeverOn,
          since: null,
          now: DateTime.utc(2026, 9, 23, 12),
        ),
      );
      await tester.pump();

      expect(find.textContaining('Capture has never been on'), findsNothing);
      expect(find.textContaining('1970'), findsNothing);
      expect(_buttons, findsNothing);
      expect(find.byType(TextButton), findsNothing);
    });
  });

  group('PERM-11 the day\'s one showing is spent by the line that was read', () {
    // The defect these pin. `quiet_notice_shown_at` used to be written where
    // the twenty-four hours were *decided* — at the bottom of the state layer's
    // read — and `main.dart` runs that read before the first frame and then
    // pushes the disclosure and PERM-14's guidance over the inbox. The budget
    // went on a sentence nobody had read, and the app then said nothing for a
    // day about a phone it had noticed going quiet.
    //
    // PERM-14 already had the honest shape: its flag is written by the screen
    // that drew it, from that screen's own `initState`, so what is recorded is
    // *it was displayed*. These assert the same shape through PERM-11's door,
    // and the counter is the only way to make it: the widget reports its own
    // showing, so how many showings there were is a number nothing else holds.

    testWidgets('the line reports one showing per time it goes on screen, and '
        'reports nothing for the other two lines', (WidgetTester tester) async {
      final DateTime now = DateTime.utc(2026, 9, 23, 12);
      final DateTime since = now.subtract(const Duration(days: 2));
      int shown = 0;

      Future<void> draw(CaptureStatusLine line, {DateTime? at}) async {
        await tester.pumpWidget(
          _noticeHost(
            line: line,
            since: at,
            now: now,
            onQuietShown: () => shown += 1,
          ),
        );
        await tester.pump();
      }

      await draw(CaptureStatusLine.quiet, at: since);
      expect(shown, 1, reason: 'PERM-11: the line drew and reported nothing');

      // The frame's instant moves, the list under it reloads, the widget is
      // rebuilt. One showing is still one showing — a budget spent per rebuild
      // would be spent by a phone that simply had a busy minute.
      await draw(CaptureStatusLine.quiet, at: since);
      expect(shown, 1, reason: 'a rebuild is not a second showing');

      // PERM-8's banner and PERM-10's line report nothing at all: neither has a
      // budget, because the state each reports is still true on the next read
      // and each draws again every time it is.
      await draw(CaptureStatusLine.accessOffSince, at: since);
      await draw(CaptureStatusLine.notRunning);
      await draw(CaptureStatusLine.none);
      expect(shown, 1, reason: 'only PERM-11\'s line has a showing to report');

      // Quiet again, after something else held the line. The same element
      // serves both — `initState` never runs a second time — so this is the
      // case a report written only in `initState` would silently drop, and two
      // showings a day apart are two showings.
      await draw(CaptureStatusLine.quiet, at: since);
      expect(shown, 2, reason: 'PERM-11: a second showing went unreported');
    });

    testWidgets('a quiet line with no instant to name draws nothing and spends '
        'nothing', (WidgetTester tester) async {
      // The same refusal the whole widget is built on, reached through the
      // budget: PERM-9 and product principle 3 say the app never prints a time
      // it does not hold, so this branch draws no sentence — and a showing
      // nobody could read must not cost the day's one showing either.
      int shown = 0;
      await tester.pumpWidget(
        _noticeHost(
          line: CaptureStatusLine.quiet,
          since: null,
          now: DateTime.utc(2026, 9, 23, 12),
          onQuietShown: () => shown += 1,
        ),
      );
      await tester.pump();

      expect(find.byType(TextButton), findsNothing);
      expect(
        shown,
        0,
        reason:
            'PERM-11: the day\'s one showing was spent on a line that drew no '
            'sentence at all',
      );
    });

    testWidgets('on the real screen the stamp is written by the line, and the '
        'app stays quiet for a day afterwards', (WidgetTester tester) async {
      // Everything PERM-11 asks for except the silence, which the seeded event
      // supplies: an install date, one enabled app seen posting after it, and
      // the last event twenty-five hours ago. The two onboarding stamps are
      // seeded as well so nothing is pushed over the inbox — this test is about
      // the line being read, and the launch where it is *not* is the state
      // layer's own test.
      final DateTime now = DateTime.now().toUtc();
      await seed(tester, (Repository repo) async {
        await repo.installedAt(now.subtract(const Duration(hours: 30)));
        await repo.markDisclosureShown(now.subtract(const Duration(hours: 30)));
        await repo.markBatteryGuidanceShown(
          now.subtract(const Duration(hours: 30)),
        );
        await repo.upsertSeenApp(
          package: 'com.whatsapp',
          label: 'WhatsApp',
          enabledIfNew: true,
          at: now.subtract(const Duration(hours: 29)),
        );
        await repo.noteCaptureEventAt(now.subtract(const Duration(hours: 25)));
      });

      await tester.pumpWidget(
        ReplyboxApp(
          repository: repo,
          services: _services(
            // PERM-11 is only meaningful with access granted and the listener
            // reporting itself connected: with either false the silence has a
            // known cause and PERM-13 has already answered with another line.
            notifications: const NoopNotificationSource(
              access: true,
              connected: true,
            ),
          ),
        ),
      );
      await _until(tester, find.textContaining('Nothing has arrived since '));

      expect(
        find.text('Why this happens'),
        findsOneWidget,
        reason: 'PERM-11: its action is PERM-14, and it is on the line',
      );
      expect(find.text('Dismiss'), findsOneWidget);

      // The stamp, written by the line rather than by the read that resolved
      // it. Nothing on this screen reads it back, so the database is where it
      // is visible at all.
      DateTime? stamped;
      await tester.runAsync(
        () async => stamped = await repo.quietNoticeShownAt(),
      );
      expect(
        stamped,
        isNotNull,
        reason:
            'PERM-11: the line went on screen and nothing recorded the '
            'showing, so the app would offer it again on the next resume',
      );
    });
  });

  group('PERM-8 and PERM-10 a binding heard without a resume', () {
    testWidgets('a capture signal delivered from inside a build is not a '
        'notification into that build', (WidgetTester tester) async {
      // The hazard this pins. `CaptureSignal.captured()` is delivered
      // synchronously to its listeners, and the drain loop that fires it can be
      // reached from inside a build — so a provider that read the platform and
      // announced on that stack would be marking an ancestor of `MaterialApp`
      // dirty while the framework was building one of its descendants, which
      // Flutter refuses outright: *setState() or markNeedsBuild() called during
      // build*. It is the same defect PERM-5's and PERM-14's own marks had, and
      // the same discipline answers it — every announcement on this path is
      // behind an `await`, and the first of all goes through `notifyLater`.
      //
      // The screen underneath is the disclosure on purpose: it records its own
      // showing from `initState`, so this is the worst frame in the app — a
      // screen writing to the provider while a signal reads from it.
      final _Access access = _Access(granted: true);
      final DeviceServices bag = _services(notifications: access);
      final CaptureSignal signal = CaptureSignal();
      addTearDown(signal.dispose);
      final PermissionsProvider permissions = PermissionsProvider(
        repo,
        bag,
        captureSignal: signal,
        delay: (Duration _) async {},
      );
      addTearDown(permissions.dispose);

      await tester.pumpWidget(
        _host(
          repository: repo,
          services: bag,
          permissions: permissions,
          home: _FiresCaptureSignal(
            signal: signal,
            child: const DisclosureScreen(),
          ),
        ),
      );
      await _settle(tester);

      expect(
        tester.takeException(),
        isNull,
        reason:
            'a listener binding heard mid-build threw a framework error. The '
            'read it starts has to be behind an await and its first '
            'announcement behind notifyLater (DeferredNotifier).',
      );
      // And it actually happened, which is the half a "nothing threw" assertion
      // would pass on by itself: nothing refreshed this provider by hand, so
      // the only thing that can have read the platform is the signal.
      expect(
        permissions.hasAccess,
        isTrue,
        reason:
            'PERM-8: the signal reached no read at all, so a binding while the '
            'app is open would leave the banner up until the next resume',
      );
    });
  });

  group('PERM-14 the battery guidance', () {
    testWidgets('it names the settings pages, says nobody has measured them, '
        'and claims nothing about the manufacturer it prints', (
      WidgetTester tester,
    ) async {
      _tallPhone(tester);
      const String make = 'Xiaomi';
      await openGuidance(
        tester,
        services: _services(
          access: true,
          systemSettings: const NoopSystemSettings(reportedManufacturer: make),
        ),
      );
      final AppLocalizations l10n = _l10n(tester);

      // The two things it is allowed to state about the phone, and the sentence
      // that stops the first one reading as a promise.
      expect(find.text(l10n.batteryGuidanceAndroid), findsOneWidget);
      expect(
        find.text(l10n.batteryGuidanceUnmeasured),
        findsOneWidget,
        reason:
            'PERM-14: the 24-hour OEM survival check did not run (spike, 21 '
            'September 2026, check 3), so the page has to say so. Without this '
            'sentence the screen is a fix the app promises.',
      );
      // And it sits above the controls, which is deliberate: a reader who takes
      // the first two sentences as a promise and then presses a button has been
      // told the opposite of what section 9 says this screen is for.
      expect(
        tester.getTopLeft(find.text(l10n.batteryGuidanceUnmeasured)).dy,
        lessThan(
          tester.getTopLeft(find.text(l10n.batteryGuidanceBatteryPage)).dy,
        ),
      );

      // The two Android pages, named. Both are unguarded intents (PERM-15).
      expect(find.text(l10n.batteryGuidanceBatteryPage), findsOneWidget);
      expect(find.text(l10n.batteryGuidanceAppInfoPage), findsOneWidget);

      // The generic branch, which every phone takes today because an entry with
      // no verified date does not ship (decision 11). It names no manufacturer
      // and states nothing about one.
      expect(find.text(l10n.batteryGuidanceNoVerifiedSteps), findsOneWidget);

      // The make is printed once, inside the one sentence the rule allows, and
      // the value carries Unicode isolate marks so a Latin name inside a
      // mirrored sentence stays left to right (LANG-5). Counted over every
      // string on screen rather than looked for in one: what PERM-14 forbids is
      // the app saying *what a named manufacturer does to it*, and that would
      // arrive as a second sentence with the name in it.
      final List<String> naming = <String>[
        for (final String drawn in _allText(tester))
          if (drawn.contains(make)) drawn,
      ];
      expect(
        naming,
        hasLength(1),
        reason:
            'PERM-14: "it never states what any named manufacturer does to this '
            'app". The make belongs in one sentence — the one that reports what '
            'the device said — and nowhere else. Found: $naming',
      );
      expect(
        naming.single,
        equals(l10n.batteryGuidanceManufacturer('$_lri$make$_pdi')),
        reason:
            'PERM-14, LANG-5: the manufacturer is printed as the device '
            'reported it, isolated so it does not reorder the sentence around '
            'it.',
      );
    });

    testWidgets('a phone that reported no manufacturer is told so, and still '
        'gets the generic branch', (WidgetTester tester) async {
      _tallPhone(tester);
      // `NoopSystemSettings` reports nothing by default, which is the honest
      // answer for a device with no settings app to ask.
      await openGuidance(tester);
      final AppLocalizations l10n = _l10n(tester);

      expect(
        find.text(l10n.batteryGuidanceManufacturerUnknown),
        findsOneWidget,
        reason:
            'PERM-14: a made-up "Unknown" would be the app telling the user '
            'something about their hardware that the hardware did not say.',
      );
      // The fallback is clean rather than empty: the screen still offers the two
      // pages and still says nobody has measured them.
      expect(find.text(l10n.batteryGuidanceNoVerifiedSteps), findsOneWidget);
      expect(find.text(l10n.batteryGuidanceBatteryPage), findsOneWidget);
      expect(find.text(l10n.batteryGuidanceAppInfoPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a manufacturer nothing in the table matches takes the same '
        'generic branch and is named anyway', (WidgetTester tester) async {
      _tallPhone(tester);
      // An unlisted make. The table ships empty, so *every* phone is this phone
      // today — and the rule's reason for printing the name at all is that an
      // unlisted phone should be visibly unlisted rather than silently generic.
      const String make = 'Fairphone';
      await openGuidance(
        tester,
        services: _services(
          access: true,
          systemSettings: const NoopSystemSettings(reportedManufacturer: make),
        ),
      );
      final AppLocalizations l10n = _l10n(tester);

      expect(
        find.text(l10n.batteryGuidanceManufacturer('$_lri$make$_pdi')),
        findsOneWidget,
      );
      expect(find.text(l10n.batteryGuidanceNoVerifiedSteps), findsOneWidget);
      // No numbered steps: an entry with no verified date does not ship, so
      // there is nothing here that could be read as tested advice.
      expect(find.text('1.'), findsNothing);
    });

    testWidgets('a page that will not open is replaced by its written path', (
      WidgetTester tester,
    ) async {
      _tallPhone(tester);
      // `opens` is false by default for the reason `NoopAppLauncher.succeeds`
      // is: a fake that claims a page opened is a fake of a phone where it
      // worked, and this screen returns early on a true.
      await openGuidance(tester);
      final AppLocalizations l10n = _l10n(tester);

      await tester.tap(find.text(l10n.batteryGuidanceBatteryPage));
      await _settle(tester);

      expect(
        find.text(l10n.batteryGuidanceBatteryPagePath),
        findsOneWidget,
        reason: 'PERM-14, PERM-7: the written path did not replace the control',
      );
      expect(
        find.text(l10n.batteryGuidanceBatteryPage),
        findsNothing,
        reason: 'PERM-14: a button that does nothing was left on screen',
      );
      expect(find.text(l10n.batteryGuidanceCannotOpen), findsOneWidget);

      // The other page is untouched. They are two pages and either can be absent
      // on its own; replacing both because one failed would take away a route
      // that works.
      expect(
        find.text(l10n.batteryGuidanceAppInfoPage),
        findsOneWidget,
        reason: 'PERM-14: one page refusing took the other page away',
      );

      await tester.tap(find.text(l10n.batteryGuidanceAppInfoPage));
      await _settle(tester);
      expect(find.text(l10n.batteryGuidanceAppInfoPagePath), findsOneWidget);
      // Said once, beside whichever path replaced a control, and not once per
      // failure: two copies of one sentence under two paths is what pushes the
      // paths themselves off a phone screen at 1.3x.
      expect(find.text(l10n.batteryGuidanceCannotOpen), findsOneWidget);
    });

    testWidgets('it is reachable from the included-apps list, which is the only '
        'Settings this version has', (WidgetTester tester) async {
      _tallPhone(tester);
      final DeviceServices services = _services(access: true);
      final PermissionsProvider permissions = providerFor(services);
      final AppsProvider apps = AppsProvider(repo, services);
      addTearDown(apps.dispose);
      // Filled before the first frame: a screen that opens on an empty provider
      // starts its read from `didChangeDependencies` and notifies inside the
      // build, which is `included_apps_test.dart`'s own subject and not this
      // one.
      await tester.runAsync(apps.load);
      await tester.runAsync(permissions.refresh);

      await tester.pumpWidget(
        _host(
          repository: repo,
          services: services,
          permissions: permissions,
          apps: apps,
          home: const IncludedAppsScreen(),
        ),
      );
      await _settle(tester);
      final AppLocalizations l10n = _l10n(tester);

      // PERM-14: "it stays reachable from Settings", and section 9's note says
      // the chooser is what Settings is today. All three rows are here, below
      // INB-21's permanent missing-app note.
      //
      // Found without scrolling because the screen is tall enough to have built
      // them: a `ListView` does not lay out what is past the fold, and the point
      // of `_tallPhone` is that this assertion reads a footer the list actually
      // drew rather than one a drag coaxed into existence.
      expect(find.text(l10n.permissionsDisclosureTitle), findsOneWidget);
      expect(find.text(l10n.batteryGuidanceTitle), findsOneWidget);
      expect(find.text(l10n.privacyPolicyTitle), findsOneWidget);

      await tester.tap(find.text(l10n.batteryGuidanceTitle));
      await _settle(tester);
      expect(find.text(l10n.batteryGuidanceAndroid), findsOneWidget);
      expect(find.text(l10n.batteryGuidanceUnmeasured), findsOneWidget);

      while (tester.takeException() != null) {}
    });
  });

  group('PERM-16 the privacy policy', () {
    testWidgets('it renders in the app without a network call', (
      WidgetTester tester,
    ) async {
      _tallPhone(tester);
      // "The policy text ships inside the app and is shown in the app,
      // translated with every other string (LANG-2), so reading it makes no
      // network request." That is not decoration: the release build declares no
      // INTERNET permission (PERM-15, product principle 1), so a policy fetched
      // from the hosted copy would be a blank screen on every phone. Counting
      // clients created is the closest a test can stand to the phone's own
      // answer, which is that the socket would not open.
      final HttpOverrides? original = HttpOverrides.current;
      final _CountingHttpOverrides overrides = _CountingHttpOverrides();
      HttpOverrides.global = overrides;
      try {
        await openPolicy(tester);
      } finally {
        // Restored inside the body rather than in a tear-down: the binding
        // installs its own override and checks for leaks before tear-downs run.
        HttpOverrides.global = original;
      }

      expect(
        overrides.clients,
        0,
        reason: 'PERM-16: reading the policy opened an HTTP client',
      );

      final AppLocalizations l10n = _l10n(tester);
      // Every claim, on screen, from the message files.
      for (final String claim in <String>[
        l10n.privacyPolicyStoredTitle,
        l10n.privacyPolicyStoredWhere,
        l10n.privacyPolicyPackagesTitle,
        l10n.privacyPolicyPackages,
        l10n.privacyPolicyLeavesTitle,
        l10n.privacyPolicyLeaves,
        l10n.privacyPolicyDeleting,
      ]) {
        expect(find.text(claim), findsOneWidget);
      }
      // The hosted copy's address, shown beside the page as text (PERM-16) —
      // which is also the only route to it while nothing in the app can open a
      // browser.
      expect(
        find.textContaining(PrivacyPolicyScreen.hostedAddress),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    test('nothing in the policy screen could fetch anything, in any build', () {
      // The runtime half above can only speak for the build it ran in. A fetch
      // behind `kDebugMode`, inside an `assert`, or on a path no test reaches is
      // still a line in the file — and a policy that loaded its own text over
      // the network would be a page that renders on the developer's phone and
      // nowhere else.
      final String source = _dartSources(
        'lib',
      )['lib/screens/privacy_policy_screen.dart']!;
      for (final MapEntry<String, RegExp> fetch in <String, RegExp>{
        'an HTTP client': RegExp(r'HttpClient|package:http|\bget\(\s*Uri'),
        'a web view': RegExp('WebView|InAppWebView'),
        'a URL launcher': RegExp('launchUrl|url_launcher'),
        'a network image': RegExp('NetworkImage|Image\\.network'),
      }.entries) {
        expect(
          fetch.value.hasMatch(source),
          isFalse,
          reason:
              'PERM-16: the policy ships inside the app and reading it makes no '
              'network request. Found ${fetch.key}.',
        );
      }
    });

    testWidgets('the control that opens the browser says it leaves the phone, '
        'and there is no control at all where nothing can', (
      WidgetTester tester,
    ) async {
      _tallPhone(tester);
      // `main.dart` passes nothing today: there is no seam in the app that opens
      // a URL. PERM-7 and PERM-14 both forbid a button that silently does
      // nothing, so the absence is the correct state and is asserted as one.
      await openPolicy(tester);
      final AppLocalizations l10n = _l10n(tester);
      expect(
        _buttons,
        findsNothing,
        reason:
            'PERM-16: a browser control was drawn on a build with no way to '
            'open one, which is the dead button PERM-7 and PERM-14 both forbid.',
      );

      // And with a way to open one, the control appears and its label is the
      // warning — in the same words, on the thing the user presses, rather than
      // in a dialog afterwards, by which time they have already left.
      final List<String> opened = <String>[];
      await openPolicy(
        tester,
        onOpenHosted: (String url) async => opened.add(url),
      );

      final Finder control = find.widgetWithText(
        OutlinedButton,
        l10n.privacyPolicyOpenHosted,
      );
      expect(
        control,
        findsOneWidget,
        reason:
            'PERM-16: "any control that opens it is labelled as opening a '
            'browser and leaving the phone". The label has to be on the control '
            'itself.',
      );
      // The English wording, checked once. A test that only compared the label
      // against its own message ID would pass on a control relabelled `Open`,
      // which is precisely the edit this rule exists to stop.
      expect(l10n.localeName, 'en');
      expect(l10n.privacyPolicyOpenHosted.toLowerCase(), contains('browser'));
      expect(
        l10n.privacyPolicyOpenHosted.toLowerCase(),
        contains('leaves your phone'),
        reason:
            'PERM-16: the one control in the app that leaves the phone must say '
            'so (product principle 1).',
      );

      await tester.tap(control);
      await _settle(tester);
      expect(
        opened,
        <String>[PrivacyPolicyScreen.hostedAddress],
        reason:
            'PERM-16: the control opened something other than the hosted '
            'copy of this same page',
      );
    });

    testWidgets("the disclosure's three claims and the policy's are the same "
        'sentences', (WidgetTester tester) async {
      _tallPhone(tester);
      // PERM-16: the three claims "exist once, as PERM-2's and PERM-3's own
      // message IDs, and the policy quotes them". A second wording of the same
      // claim is a second thing to keep true, and the first time one of them
      // changed the app would be telling a user one story on the permission
      // screen and another on the policy.
      await openDisclosure(tester);
      final AppLocalizations l10n = _l10n(tester);
      final List<String> shared = <String>[
        l10n.permissionsDisclosureReads,
        l10n.permissionsDisclosureAppsExplainer,
        l10n.permissionsDisclosureStaysHere,
      ];
      for (final String claim in shared) {
        expect(find.text(claim), findsOneWidget);
      }

      await openPolicy(tester);
      for (final String claim in shared) {
        expect(
          find.text(claim),
          findsOneWidget,
          reason:
              'PERM-16: the policy restated a disclosure claim in its own words '
              'instead of quoting it, so the two can now drift.',
        );
      }

      // The source half, which is what makes "the same message IDs" checkable
      // rather than "the same English today": two getters that happened to hold
      // identical strings would satisfy the assertions above and would diverge
      // on the first translation.
      final String policy = _dartSources(
        'lib',
      )['lib/screens/privacy_policy_screen.dart']!;
      for (final String id in <String>[
        'permissionsDisclosureReads',
        'permissionsDisclosureAppsExplainer',
        'permissionsDisclosureStaysHere',
      ]) {
        expect(
          policy,
          contains(id),
          reason: 'PERM-16: the policy holds its own copy of $id',
        );
      }
    });
  });

  group('INB-23 at 1.3x text and mirrored', () {
    testWidgets('the disclosure fits a phone at 1.3x with both actions still on '
        'screen', (WidgetTester tester) async {
      _phone(tester);
      await openDisclosure(tester, textScale: 1.3);
      final AppLocalizations l10n = _l10n(tester);

      // INB-23 and LANG-6: the screens fail on overflow. A `RenderFlex` that
      // overflowed reports a rendering error, which the framework holds until it
      // is taken — so the first assertion is that nothing is waiting.
      expect(
        tester.takeException(),
        isNull,
        reason: 'INB-23: the disclosure overflowed at 1.3x text',
      );

      // Every claim is still in the tree. The screen may scroll, so this is not
      // a measurement of where they are — it is that 1.3x did not cost the
      // reader a sentence.
      for (final String line in <String>[
        l10n.permissionsDisclosureReads,
        l10n.permissionsDisclosureUses,
        l10n.permissionsDisclosureStaysHere,
        l10n.permissionsDisclosureLimitsTitle,
        l10n.permissionsDisclosureWithdraw,
        l10n.permissionsDisclosureLimitWorkProfile,
      ]) {
        expect(find.text(line), findsOneWidget);
      }

      // PERM-2: "the screen may scroll, the two actions may not". This is the
      // text scale that decides it — the seven clauses and the six app names
      // grow, and a layout that put the controls inside the scroll view would
      // push them off a phone here.
      _onScreen(tester, find.text(l10n.permissionsDisclosureTurnOn), 'INB-23');
      _onScreen(tester, find.text(l10n.permissionsDisclosureDecline), 'INB-23');
      _atLeast48(
        tester,
        find.widgetWithText(FilledButton, l10n.permissionsDisclosureTurnOn),
        "the disclosure's primary control",
      );
      _atLeast48(
        tester,
        find.widgetWithText(OutlinedButton, l10n.permissionsDisclosureDecline),
        "the disclosure's decline",
      );
    });

    testWidgets('the disclosure mirrors at 1.3x, and the package names inside '
        'it stay left to right', (WidgetTester tester) async {
      _phone(tester);
      await openDisclosure(tester, textScale: 1.3, rtl: true);
      final AppLocalizations l10n = _l10n(tester);

      expect(
        tester.takeException(),
        isNull,
        reason: 'INB-23: the disclosure overflowed mirrored at 1.3x',
      );
      expect(find.text(l10n.permissionsDisclosureReads), findsOneWidget);
      _onScreen(tester, find.text(l10n.permissionsDisclosureTurnOn), 'INB-23');
      _onScreen(tester, find.text(l10n.permissionsDisclosureDecline), 'INB-23');

      // LANG-5: "times, numbers and package names stay left to right inside
      // them". Here the package name *is* the label — nothing resolved a nicer
      // one — so the row asks for it explicitly, and a mirrored `com.whatsapp`
      // would read back to front.
      final Text name = tester.widget<Text>(
        find.text(shippedMessagingApps.first),
      );
      expect(
        name.textDirection,
        TextDirection.ltr,
        reason: 'INB-23, LANG-5: a package name mirrored with the layout',
      );
    });

    testWidgets('the guidance and the policy fit a phone at 1.3x, mirrored', (
      WidgetTester tester,
    ) async {
      _tallPhone(tester);
      await openGuidance(
        tester,
        services: _services(
          access: true,
          systemSettings: const NoopSystemSettings(
            reportedManufacturer: 'Xiaomi',
          ),
        ),
        textScale: 1.3,
        rtl: true,
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'INB-23: the battery guidance overflowed mirrored at 1.3x',
      );
      final AppLocalizations l10n = _l10n(tester);
      expect(find.text(l10n.batteryGuidanceUnmeasured), findsOneWidget);

      await openPolicy(tester, textScale: 1.3, rtl: true);
      expect(
        tester.takeException(),
        isNull,
        reason: 'INB-23: the privacy policy overflowed mirrored at 1.3x',
      );
      expect(find.text(l10n.privacyPolicyLeaves), findsOneWidget);
    });

    testWidgets("PERM-13's line fits a phone at 1.3x with both of PERM-11's "
        'controls on it', (WidgetTester tester) async {
      _phone(tester);
      // The one branch that carries two controls, which is the one a `Row` would
      // overflow: at 1.3x, in the language with the longest word for *Dismiss*,
      // they do not fit one phone-width line.
      await tester.pumpWidget(
        _noticeHost(
          line: CaptureStatusLine.quiet,
          since: DateTime.utc(2026, 9, 21, 12),
          now: DateTime.utc(2026, 9, 23, 12),
          textScale: 1.3,
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: "INB-23: PERM-11's line overflowed at 1.3x text",
      );
      final AppLocalizations l10n = _l10n(tester);
      _onScreen(tester, find.text(l10n.captureGuidanceAction), 'INB-23');
      _onScreen(tester, find.text(l10n.captureQuietDismiss), 'INB-23');
      _atLeast48(
        tester,
        find.widgetWithText(TextButton, l10n.captureQuietDismiss),
        "PERM-11's dismissal",
      );
    });
  });

  group('INB-24 nothing in this area leaves the screen', () {
    test('no file in the permissions area holds a sink that could carry a '
        'sender, a title, a message or a package off the screen', () {
      // `inbox_screen_test.dart` scans `lib/screens` and `lib/widgets` whole, so
      // the three new screens and the status line are already covered there.
      // What is not is the state layer of this area: its scan names
      // `inbox_provider`, `thread_provider` and `apps_provider` one by one, and
      // `permissions_provider.dart` is new. It is listed here rather than added
      // there because this is the file that owns section 9.
      const List<String> area = <String>[
        'lib/providers/permissions_provider.dart',
        'lib/data/battery_guidance.dart',
      ];
      final Map<String, String> sources = _dartSources('lib');
      for (final String path in area) {
        expect(
          sources.containsKey(path),
          isTrue,
          reason:
              '$path is gone or renamed, so this scan silently stopped reading '
              'the state layer of section 9 (INB-24).',
        );
      }

      // Every way a string leaves this process: the console, a crash report,
      // another app, and the file system. None has a use in a provider or in a
      // data constant, whatever build it is compiled into.
      final Map<String, RegExp> sinks = <String, RegExp>{
        'print': RegExp(r'(^|[^a-zA-Z])print\s*\('),
        'debugPrint': RegExp('debugPrint'),
        'dart:developer': RegExp(r'dart:developer|developer\.log'),
        'stdout or stderr': RegExp(r'\bstd(out|err)\b'),
        'a crash report': RegExp('recordError|reportError|Crashlytics'),
        'a share sheet': RegExp(r'\bShare\b|SharePlus'),
        'the clipboard': RegExp(r'Clipboard\.'),
        'the file system': RegExp(r'\bFile\(|\bDirectory\('),
        'a platform channel': RegExp('MethodChannel|EventChannel'),
        'dart:io': RegExp('dart:io'),
      };

      final List<String> found = <String>[];
      for (final String path in area) {
        sinks.forEach((String name, RegExp pattern) {
          if (pattern.hasMatch(sources[path]!)) found.add('$path: $name');
        });
      }
      expect(
        found,
        isEmpty,
        reason:
            'INB-24: a sink in section 9\'s code path. The state layer reaches '
            'the platform through DeviceServices and nowhere else, which is '
            'also what keeps PERM-15 true — a channel here is a capability '
            'nothing declared.\n${found.join('\n')}',
      );
    });

    testWidgets('nothing the disclosure draws is written anywhere but the '
        'screen', (WidgetTester tester) async {
      // The runtime half. The disclosure is the one screen in this area that
      // renders package names — PERM-3's six — so those are what is watched for,
      // with a seeded label nothing else in the app could produce standing in
      // for what the package manager would return on a phone.
      const String label = 'Zzy-Label-7c40';
      const String package = 'com.whatsapp';

      final List<String> emitted = <String>[];
      final DebugPrintCallback originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) emitted.add(message);
      };
      try {
        await _capturingPrint(emitted, () async {
          await openDisclosure(
            tester,
            services: _services(
              identities: const <String, SourceAppIdentity>{
                package: SourceAppIdentity(
                  package: package,
                  presence: PackagePresence.installed,
                  label: label,
                ),
              },
            ),
          );
        });
      } finally {
        // Restored inside the body, not in a tear-down: the binding checks that
        // no foundation debug variable outlives the test, and it checks before
        // tear-downs run.
        debugPrint = originalDebugPrint;
      }

      // It is on the screen, so the capture above was watching a screen that
      // actually drew it.
      expect(find.text(label), findsOneWidget);
      for (final String secret in <String>[label, ...shippedMessagingApps]) {
        expect(
          emitted.where((String line) => line.contains(secret)),
          isEmpty,
          reason: 'INB-24: $secret reached a log line',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });
}

/// Nothing has been reported to the framework at this point in the test.
///
/// **What this was, and the correction of 23 September 2026.** It was written
/// as `_drainFirstBuildNotify`, and it *drained*: it took a
/// *setState() or markNeedsBuild() called during build* error and threw
/// everything else away. The defect it was written around was real —
/// `PermissionsProvider.markDisclosureShown` and `markBatteryGuidanceShown`
/// announced with `notify()`, synchronously, from the two screens' own
/// `initState`, and the provider sits above `MaterialApp` in `main.dart` as it
/// does in this file's host, so a screen mounted under it marked an ancestor
/// dirty mid-build. It fired on a real phone, on the first launch of a fresh
/// install.
///
/// **It has been fixed**, in the one place it belonged: both methods announce
/// with `notifyLater()` now, and the two tests in the PERM-5 group that own the
/// defect (`drain: false`) pass on their own subject. This function was checked
/// against every call site below with its drain removed and found to swallow
/// nothing at all — so it was left in place and turned the right way round.
///
/// That matters rather than being tidiness: a helper that quietly eats
/// *markNeedsBuild during build* is precisely the thing that would hide the
/// next one. There is a next one to hide — `PermissionsProvider` now reads on a
/// capture signal (PERM-8, PERM-10), and a signal is delivered synchronously on
/// whatever stack fired it, which in the app can be a build.
void _noFrameworkErrorYet(WidgetTester tester) {
  final Object? error = tester.takeException();
  expect(
    error,
    isNull,
    reason:
        'the framework reported $error at a point in this test where section 9 '
        'produces nothing. A notification dispatched into a build is the one '
        'this has caught before (see this function).',
  );
}

/// Unicode's directional isolate pair, built by code point on purpose.
///
/// The same reason `battery_guidance_screen.dart` builds it that way: both
/// characters are invisible and zero-width, and a literal one pasted into a
/// source file is a character nobody reviewing it can see. The screen wraps
/// `Build.MANUFACTURER` in these before it goes into the sentence (LANG-5), so
/// a test that expected the bare name would be asserting a screen that had
/// dropped the isolation — and a make inside a right-to-left sentence would
/// then reorder the punctuation around it.
final String _lri = String.fromCharCode(0x2066);
final String _pdi = String.fromCharCode(0x2069);

/// Every `.dart` file under [dir], comments stripped, keyed by a forward-slashed
/// relative path.
///
/// Stripping comments is load-bearing, exactly as it is in
/// `package_visibility_test.dart` and `manifest_test.dart`: the files in this
/// area explain themselves at length and write out the very names these scans
/// forbid in order to say they are absent. A test reading raw text would fail on
/// the paragraph explaining why the thing it bans is not there — and would then
/// be "fixed" by deleting the explanation.
Map<String, String> _dartSources(String dir) {
  final Directory root = Directory(dir);
  expect(
    root.existsSync(),
    isTrue,
    reason:
        '$dir is gone, so this test scanned nothing. A promise checked by a '
        'test that reads no files is not checked (PERM-1, INB-24).',
  );
  final Map<String, String> found = <String, String>{};
  for (final FileSystemEntity entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    found[entity.path.replaceAll(r'\', '/')] = entity
        .readAsStringSync()
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .replaceAll(RegExp(r'//[^\n]*'), '');
  }
  expect(found, isNotEmpty, reason: 'no .dart files under $dir');
  return found;
}

/// The no-op bag with whichever services a test needs swapped in.
///
/// [DeviceServices] has no `copyWith`, and a test that built a real one would be
/// reaching for a phone (docs/STACK_NOTES.md: a real service reachable as a
/// default parameter hung the suite for ten minutes).
DeviceServices _services({
  NotificationSource? notifications,
  bool access = false,
  SystemSettings systemSettings = const NoopSystemSettings(),
  Map<String, SourceAppIdentity> identities =
      const <String, SourceAppIdentity>{},
}) => DeviceServices(
  // `connected` is deliberately left at its default of null throughout this
  // file. Null is "this process has observed neither lifecycle callback", which
  // is the honest answer for a build with no listener — and PERM-10's line may
  // only be drawn on a false. A test here that wanted that branch would also be
  // buying its ten-second wait, and PERM-10 is `permissions_provider_test.dart`'s
  // subject rather than a screen's.
  notifications: notifications ?? NoopNotificationSource(access: access),
  captureFilter: NoopCaptureFilter(),
  packages: NoopPackageInfoService(identities: identities),
  reply: const NoopReplyService(),
  launcher: const NoopAppLauncher(),
  reminders: const NoopReminderScheduler(),
  entitlements: const NoopEntitlements(),
  appLock: const NoopAppLock(),
  systemSettings: systemSettings,
);

/// One of section 9's screens with everything it reads above it, and the other
/// two reachable by name.
///
/// The routes are registered rather than omitted because two of the assertions
/// here are about a screen *reaching* another one — PERM-8's banner action and
/// PERM-14's row at the foot of the chooser — and a route that is not on the map
/// fails with a framework error rather than with the rule it broke.
///
/// The direction is imposed through `MaterialApp.builder` and not by choosing a
/// locale: the app ships one language and it reads left to right, and
/// `MaterialApp` installs its own `Directionality` from the resolved locale,
/// which would overwrite one wrapped around it.
Widget _host({
  required Repository repository,
  required DeviceServices services,
  required PermissionsProvider permissions,
  required Widget home,
  AppsProvider? apps,
  double textScale = 1,
  bool rtl = false,
}) {
  return MultiProvider(
    providers: <SingleChildWidget>[
      Provider<Repository>.value(value: repository),
      Provider<DeviceServices>.value(value: services),
      ChangeNotifierProvider<PermissionsProvider>.value(value: permissions),
      if (apps != null) ChangeNotifierProvider<AppsProvider>.value(value: apps),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // The app's own theme, not the framework default. INB-23's 48dp floor is
      // met here by `materialTapTargetSize: padded`, which `replyboxTheme` sets
      // explicitly — so a test measuring a control under a default theme would
      // be measuring a screen this app never draws.
      theme: replyboxTheme(),
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
      routes: <String, WidgetBuilder>{
        DisclosureScreen.routeName: (BuildContext _) =>
            const DisclosureScreen(),
        BatteryGuidanceScreen.routeName: (BuildContext _) =>
            const BatteryGuidanceScreen(),
        PrivacyPolicyScreen.routeName: (BuildContext _) =>
            const PrivacyPolicyScreen(),
        IncludedAppsScreen.routeName: (BuildContext _) =>
            const IncludedAppsScreen(),
      },
      home: home,
    ),
  );
}

/// PERM-13's line on its own, with one value in.
///
/// The widget rather than the screen, because what PERM-13 fixes is that one
/// resolved value produces one line: the screen's job is only *where* it goes,
/// and that half is asserted on the real screen in the PERM-8 group. Nothing
/// here needs a provider — the widget reads none, which is what makes it
/// impossible for a second ranking of the three facts to grow inside it.
///
/// [onQuietShown] defaults to doing nothing, because most of the tests below
/// are about what is on the screen rather than about PERM-11's budget. The one
/// group that is about the budget passes a counter, and counts: the widget
/// reports its own showing, so "how many times did this draw PERM-11's line"
/// is a number only this callback can answer.
Widget _noticeHost({
  required CaptureStatusLine line,
  required DateTime? since,
  required DateTime now,
  VoidCallback? onQuietShown,
  double textScale = 1,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: replyboxTheme(),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: CaptureStatusNotice(
      line: line,
      since: since,
      now: now,
      onOpenDisclosure: () {},
      onOpenGuidance: () {},
      onDismissQuiet: () {},
      onQuietShown: onQuietShown ?? () {},
    ),
  ),
);

/// A phone-size screen, in logical pixels.
///
/// INB-23 names a phone, and a phone is where these screens can actually fail:
/// the 800x600 a widget test defaults to is wider than any of them, so a
/// disclosure whose two actions are pushed off the bottom at 1.3x lays out
/// comfortably on it.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A phone's width with room below it, so a `ListView` builds all of itself.
///
/// A `ListView` does not lay out what is past the fold, and a finder cannot read
/// a widget that was never built — so the three Settings rows at the foot of the
/// chooser, the second of the battery guidance's two page controls, and
/// everything on the privacy policy below *What leaves this phone* need either a
/// scroll or a taller screen. This is the same shape `included_apps_test.dart`
/// uses for the same reason.
///
/// The **width** is still a phone's, which is the half that decides INB-23: the
/// guidance and the policy are `ListView`s, so nothing in them can overflow
/// vertically, and what a long sentence at 1.3x text actually overflows is the
/// side of the screen. The disclosure is the screen where the height is
/// load-bearing — PERM-1's two actions sit outside its scroll view and have to
/// be on screen without scrolling — and that one is measured on [_phone].
void _tallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 7200);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Every button on screen, whatever kind it is.
///
/// `find.byType` matches the exact runtime type, and the disclosure's primary is
/// a `FilledButton` while its decline is an `OutlinedButton` — so counting
/// controls has to go through the base class PERM-1 actually means.
final Finder _buttons = find.byWidgetPredicate(
  (Widget w) => w is ButtonStyleButton,
);

/// PERM-4: "nothing is greyed out".
///
/// A disabled control is a `ButtonStyleButton` with a null `onPressed`,
/// whichever one it is, so this counts them rather than naming the ones a test
/// happened to think of.
void _nothingDisabled(WidgetTester tester, String rule) {
  for (final ButtonStyleButton button in tester.widgetList<ButtonStyleButton>(
    _buttons,
  )) {
    expect(
      button.onPressed ?? button.onLongPress,
      isNotNull,
      reason: '$rule: a control on screen is disabled',
    );
  }
}

/// That [finder]'s box is inside the screen it is drawn on.
///
/// Two things fail differently here and neither implies the other: a `RenderFlex`
/// that overflowed reports a rendering error the framework holds until it is
/// taken, while a control merely pushed past the bottom of the screen reports
/// nothing at all. This is the second — a control off the bottom of a phone is
/// one PERM-1 says is not reachable without scrolling.
void _onScreen(WidgetTester tester, Finder finder, String rule) {
  expect(finder, findsOneWidget, reason: '$rule: not on the screen at all');
  final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  final Rect rect = tester.getRect(finder);
  expect(
    rect.left,
    greaterThanOrEqualTo(-0.5),
    reason: '$rule: it starts off the leading edge of the screen',
  );
  expect(
    rect.right,
    lessThanOrEqualTo(screen.width + 0.5),
    reason: '$rule: it runs off the trailing edge of the screen',
  );
  expect(
    rect.bottom,
    lessThanOrEqualTo(screen.height + 0.5),
    reason: '$rule: it is below the bottom of the screen',
  );
  expect(
    rect.top,
    greaterThanOrEqualTo(-0.5),
    reason: '$rule: it is above the top of the screen',
  );
}

/// INB-23's floor, measured on what is on screen rather than assumed from the
/// constant the app happens to lay out with.
void _atLeast48(WidgetTester tester, Finder finder, String what) {
  final Size size = tester.getSize(finder);
  final double shorter = size.width < size.height ? size.width : size.height;
  expect(
    shorter,
    greaterThanOrEqualTo(48),
    reason: 'INB-23: $what is $size, under 48dp on its shorter side',
  );
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

/// Every string drawn as a `Text` on the current screen.
List<String> _allText(WidgetTester tester) => <String>[
  for (final Text text in tester.widgetList<Text>(find.byType(Text)))
    if (text.data != null) text.data!,
];

/// The message files the screen on the tester is actually resolving.
AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

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

/// Steps outside the fake clock so the database's real work can land, then draws
/// whatever arrived, until [finder] matches.
///
/// `pumpAndSettle` cannot do this: the read is real asynchronous work and a
/// widget test's clock never advances on its own, so settling would wait on a
/// frame that is waiting on a clock that is not running.
Future<void> _until(
  WidgetTester tester,
  Finder finder, {
  int turns = 80,
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

/// Lets pending work land without waiting for anything in particular.
Future<void> _settle(WidgetTester tester, {int turns = 30}) async {
  for (int i = 0; i < turns; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// A notification source that records the one thing PERM-1 counts, and can be
/// the phone on which PERM-7's page does not exist.
///
/// Its own fake rather than a flag on `NoopNotificationSource`: a counter there
/// would make that class stateful and every test in the suite would share it —
/// the reason `noop_services.dart` gives for `requestListenerRebind` counting
/// nothing.
class _Access implements NotificationSource {
  _Access({this.granted = false, this.throwsOnOpen = false});

  /// What the *system* says, which is the only thing PERM-5 lets the app read.
  final bool granted;

  /// PERM-7's third branch: a build can ship without the notification-access
  /// screen, and `CaptureChannel.openAccessSettings` raises `no_settings_page`
  /// when neither of its two intents starts. `AndroidNotificationSource`
  /// deliberately does not swallow it, so this is the shape the state layer
  /// receives on such a phone.
  final bool throwsOnOpen;

  /// How many times the app asked for the system page. PERM-1 is a claim about
  /// this number's sources and PERM-6 is a claim about the taps in front of it.
  int opened = 0;

  @override
  Future<bool> hasAccess() async => granted;

  @override
  Future<void> openAccessSettings() async {
    opened += 1;
    if (throwsOnOpen) {
      throw PlatformException(
        code: 'no_settings_page',
        message: 'neither intent resolved',
      );
    }
  }

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  /// Null, like the no-op: nothing has been observed. PERM-10's line may only be
  /// drawn on a false, and a fake here that answered false would let a screen
  /// test draw the one sentence PERM-10 forbids without evidence.
  @override
  Future<bool?> listenerConnected() async => null;

  @override
  Future<bool> requestListenerRebind() async => false;
}

/// Fires the capture signal once, from inside its own `build`.
///
/// The one shape that can catch a notification dispatched into a build: a
/// `CaptureSignal` listener is a `VoidCallback` called synchronously by
/// `notifyListeners`, so whatever stack fires the signal is the stack the
/// provider's handler runs on — and in the app that stack can be a build, since
/// the drain loop is reached from one. Fired once rather than on every build,
/// because a provider that announces makes this widget's ancestors rebuild and
/// a test that fired again on each of those would be measuring its own loop.
class _FiresCaptureSignal extends StatefulWidget {
  const _FiresCaptureSignal({required this.signal, required this.child});

  final CaptureSignal signal;
  final Widget child;

  @override
  State<_FiresCaptureSignal> createState() => _FiresCaptureSignalState();
}

class _FiresCaptureSignalState extends State<_FiresCaptureSignal> {
  bool _fired = false;

  @override
  Widget build(BuildContext context) {
    if (!_fired) {
      _fired = true;
      widget.signal.captured();
    }
    return widget.child;
  }
}

/// Counts every `HttpClient` this process creates while it is installed.
///
/// PERM-16's "reading it makes no network request" is a claim about something
/// that does *not* happen, so the only way to assert it is to make the thing
/// that would happen observable. A client created and then never used still
/// fails this: the rule is that the policy ships inside the app, and a build
/// that reached for the network at all would be a blank page on a release build
/// with no INTERNET permission (PERM-15).
class _CountingHttpOverrides extends HttpOverrides {
  int clients = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients += 1;
    return super.createHttpClient(context);
  }
}
