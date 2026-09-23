import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'db/db_helper.dart';
import 'db/repository.dart';
import 'l10n/app_localizations.dart';
import 'models/conversation.dart';
import 'providers/apps_provider.dart';
import 'providers/inbox_provider.dart';
import 'providers/permissions_provider.dart';
import 'screens/battery_guidance_screen.dart';
import 'screens/disclosure_screen.dart';
import 'screens/included_apps_screen.dart';
import 'screens/inbox_screen.dart';
import 'screens/privacy_policy_screen.dart';
import 'screens/thread_screen.dart';
import 'services/android_app_launcher.dart';
import 'services/android_capture_service.dart';
import 'services/android_package_service.dart';
import 'services/noop_services.dart';
import 'services/services.dart';
import 'theme.dart';

/// The only place the real device services are ever built
/// (docs/STACK_NOTES.md). Everything below this line takes them as an
/// argument, which is what lets tests hand over fakes and an in-memory
/// database.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final DBHelper db = DBHelper();
  final Repository repository = Repository(db);

  // Off Android there is no listener to talk to, so the app runs on the no-op
  // set rather than on a channel with nobody on the other end — the shape that
  // hung the suite for ten minutes (docs/STACK_NOTES.md).
  final bool onAndroid = Platform.isAndroid;
  const AndroidNotificationSource source = AndroidNotificationSource();

  // One instance, shared by the drain loop that fills it and the tree that
  // reads it. Built here on every platform rather than only on Android, so the
  // screen that states the fault (PERM-8's banner) is never a conditional
  // widget: off Android it simply never gets one to state.
  final CaptureHealth health = CaptureHealth();

  runApp(
    ReplyboxApp(
      repository: repository,
      health: health,
      services: onAndroid
          ? DeviceServices(
              notifications: source,
              // The same object as `notifications`, through a second, narrower
              // interface: the chooser pushes CAP-1's filter down the moment a
              // switch moves (INB-22), and this is still the only place a real
              // service is constructed — `InboxProvider` is handed one, and can
              // reach for nothing.
              captureFilter: source,
              // INB-1's icon and label and INB-16's installed-or-gone. Its own
              // class rather than a third face on `source`: it talks to the
              // package manager, not to the listener, and it holds a cache the
              // listener has no business in.
              packages: AndroidPackageInfoService(),
              reply: AndroidReplyService(),
              // INB-13's control. This was `NoopAppLauncher()`, whose `succeeds`
              // defaulted to true, so on a phone the control started nothing and
              // reported that it had: the screen returns early on success, so
              // the "could not be opened" snackbar never drew either. Until area
              // REP ships, that control is the second tap of INB-18's reply
              // path, which made the app's only action a lie.
              launcher: const AndroidAppLauncher(),
              // Still no-op, each waiting on its own item: Triage, Plus and
              // App lock.
              reminders: const NoopReminderScheduler(),
              entitlements: const NoopEntitlements(),
              appLock: const NoopAppLock(),
              // PERM-14's two settings pages and the one fact it prints about
              // the phone. Its own class rather than a third face on `source`:
              // none of it is about notifications, and every one of its three
              // answers is something the app can only *offer*. It adds no
              // permission to the release build (PERM-15) — `Build.MANUFACTURER`
              // is a public field, and both intents are unguarded.
              systemSettings: const AndroidSystemSettings(),
            )
          : noopServices(),
      captureSync: onAndroid ? CaptureSync(source, repository, health) : null,
    ),
  );
}

class ReplyboxApp extends StatefulWidget {
  const ReplyboxApp({
    required this.repository,
    required this.services,
    this.captureSync,
    this.health,
    super.key,
  });

  final Repository repository;
  final DeviceServices services;

  /// Null in every test and on every platform but Android: there is no queue
  /// to drain where there is no listener (CAP-13).
  final CaptureSync? captureSync;

  /// What capture could not do, for PERM-8's banner to state (CAP-12).
  ///
  /// Optional, and one is built when it is absent, so a test that only wants a
  /// screen does not have to carry one — but there is always exactly one in the
  /// tree, so no widget that reads it has to handle its absence.
  final CaptureHealth? health;

  @override
  State<ReplyboxApp> createState() => _ReplyboxAppState();
}

class _ReplyboxAppState extends State<ReplyboxApp> with WidgetsBindingObserver {
  /// INB-25's other half, built here because this is where the drain loop is
  /// started and where every provider that can be on screen is made.
  ///
  /// The loop's `onChanged` used to go straight to `_inbox.load`, which redrew
  /// one screen with a spinner. A single callback can only reach one object,
  /// and a message arriving while a *thread* is open has the same one-second
  /// deadline as one arriving while the list is open. So the loop nudges this,
  /// and every provider listens to it.
  final CaptureSignal _captureSignal = CaptureSignal();

  /// Built once here rather than in `build`, because the drain loop holds a
  /// reference to it: a provider rebuilt under the loop would leave the loop
  /// refreshing a state object no screen is reading.
  late final InboxProvider _inbox = InboxProvider(
    widget.repository,
    widget.services,
    captureSignal: _captureSignal,
  );

  /// INB-20's list, built here for the same reason as the inbox's: it listens
  /// to the capture signal, and a provider rebuilt under that listener would
  /// leave the signal nudging an object no screen is reading. Its first read is
  /// the screen's, not ours — this costs nothing until someone opens it.
  late final AppsProvider _apps = AppsProvider(
    widget.repository,
    widget.services,
    captureSignal: _captureSignal,
  );

  /// Section 9's whole state, built here for the same reason the two above are:
  /// it is read on every cold start and every resume, and the resume is this
  /// object's `didChangeAppLifecycleState`. A provider rebuilt under that
  /// observer would leave the observer refreshing a state object no screen is
  /// reading.
  ///
  /// It takes the capture signal for the third reason the two above take it,
  /// and it is the reason the drain loop nudges a signal rather than one
  /// object: PERM-8's banner is gone on the first resume "**or listener
  /// binding** after access returns, whichever comes first", and PERM-10's line
  /// goes "**the moment** the listener connects". A binding enqueues a
  /// `listener_connected` event, `CaptureSync` drains it, and the signal is how
  /// that reaches a provider without a resume.
  ///
  /// It still owns no timer and no lifecycle observer of its own (see its class
  /// comment), so what it needs from here is the call on resume, that signal,
  /// and a `dispose` before the signal's.
  late final PermissionsProvider _permissions = PermissionsProvider(
    widget.repository,
    widget.services,
    captureSignal: _captureSignal,
  );

  /// The one the drain loop was given, or one of our own when there is no loop.
  late final CaptureHealth _health = widget.health ?? CaptureHealth();

  /// PERM-4's and PERM-14's pushes need a navigator, and this state sits
  /// *above* the `MaterialApp` that creates one — so its own `context` has none.
  ///
  /// A key rather than moving the push down into [InboxScreen]: PERM-4 says the
  /// disclosure is offered without a tap exactly once per install, and PERM-14
  /// says the guidance is shown once after the first screen is drawn. Both are
  /// launch-and-resume facts about the app, not about the conversation list,
  /// and putting them in the first screen would mean the next screen to become
  /// the first screen (RUN-3's setup page) silently loses them.
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  /// True from the moment an onboarding push is scheduled until the last of
  /// them has been popped.
  ///
  /// A resume lands while the disclosure is already open more often than it
  /// sounds — the user goes to the system page from it and comes back — and
  /// without this the app would push a second disclosure on top of the first.
  bool _onboardingInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // CAP-12's first clause — "no history from before it was installed" — is a
    // date the app has to hold, and nothing on the capture path was writing it:
    // a device drill that ran thirty listener sessions and captured eighteen
    // messages finished with the `settings` table as empty as it started
    // (21 September 2026). So it is written here, at the one place that runs
    // once per launch on every platform and does not wait on a permission the
    // user may never grant — `Repository.installedAt` writes only when the key
    // is unset, so the value is the first launch and no later one moves it.
    //
    // Not in `CaptureSync.start`: that is built on Android alone and only when
    // there is a listener, and an install whose history began before access was
    // granted still has a beginning.
    final Future<void> installStamped = widget.repository.installedAt(
      DateTime.now().toUtc(),
    );
    unawaited(installStamped);
    unawaited(_inbox.load());
    // The listener kept queueing while the app was closed, so the first drain
    // happens before anyone has had a chance to pull anything to refresh
    // (CAP-13, INB-25).
    widget.captureSync?.start(onChanged: _captureSignal.captured);
    // PERM-5's first read, and PERM-4's one-per-install offer behind it. Held
    // behind the write above rather than started beside it: PERM-8's third
    // branch — "capture has never been on, and nothing has been stored since
    // it was installed on <date>" — reads `installed_at`, and on the very first
    // launch the two would otherwise be a write and a read of the same key
    // racing each other. Losing that race prints CAP-12's timeless sentence to
    // a user whose install date the app was in the middle of writing down.
    unawaited(_firstPermissionsRead(installStamped));
  }

  /// PERM-5 on a cold start, then PERM-4's and PERM-14's offers (PERM-6's route
  /// from a fresh install).
  ///
  /// Access is read from the system here, and the disclosure is *pushed over*
  /// the first screen rather than shown in place of it: `home:` below is
  /// [InboxScreen] on every launch including the very first, because PERM-4 is
  /// explicit that no screen is replaced by a permission wall and that
  /// declining leaves an app that works.
  Future<void> _firstPermissionsRead(Future<void> installStamped) async {
    try {
      await installStamped;
    } catch (_) {
      // A failed stamp is a missing `installed_at`, which PERM-8's third branch
      // already handles by drawing the sentence without a date rather than
      // inventing one. It must not also cost the user the access read: that is
      // the one thing on this path that decides whether the app can see
      // anything at all.
    }
    if (!mounted) return;
    await _permissions.refresh();
    if (!mounted) return;
    _offerOnboarding();
  }

  /// Schedules PERM-4's and PERM-14's pushes for after the current frame.
  ///
  /// Post-frame, which is PERM-14's "after the first screen has been drawn and
  /// never in place of it" and the same discipline PERM-4 asks of the
  /// disclosure: the user sees the app they installed, and then sees what it
  /// wants to tell them, in that order. A push from inside the build that is
  /// drawing the first screen would also be a navigation during a build, which
  /// Flutter refuses outright.
  void _offerOnboarding() {
    if (_onboardingInFlight) return;
    if (!_permissions.shouldShowDisclosure &&
        !_permissions.shouldShowBatteryGuidance) {
      return;
    }
    _onboardingInFlight = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      unawaited(_pushOnboarding());
    });
  }

  /// The disclosure, then the guidance, in that order where both are pending.
  ///
  /// The order is PERM-14's: the guidance is about keeping a listener alive,
  /// and showing it before the screen that explains what the listener reads
  /// would be answering a question the user has not been asked yet.
  ///
  /// Each screen records its own showing from its own `initState` — PERM-5's
  /// `disclosure_shown_at` and PERM-14's `battery_guidance_shown_at` both mean
  /// *it was displayed* — so the two `should` flags are already false by the
  /// time the push returns and nothing here writes anything.
  Future<void> _pushOnboarding() async {
    try {
      if (_permissions.shouldShowDisclosure) {
        // Re-read through the key on each push: the navigator this state is
        // pointing at can be rebuilt between the two, and a captured
        // `NavigatorState` would be the disposed one.
        final NavigatorState? navigator = _navigator.currentState;
        if (navigator == null) return;
        await navigator.pushNamed(DisclosureScreen.routeName);
        if (!mounted) return;
      }
      if (_permissions.shouldShowBatteryGuidance) {
        final NavigatorState? navigator = _navigator.currentState;
        if (navigator == null) return;
        await navigator.pushNamed(BatteryGuidanceScreen.routeName);
      }
    } finally {
      // In the `finally` so an early return — or a throw out of a route — cannot
      // leave the flag raised and make every later resume believe a push is
      // still on screen.
      _onboardingInFlight = false;
    }
  }

  /// What a resume changes that nothing else can tell the app about.
  ///
  /// Two things, and neither is the queue: `CaptureSync` drains on resume by
  /// itself and nudges [_captureSignal] when it wrote something (INB-25).
  ///
  ///  * An app can be installed or uninstalled while Replybox is in the
  ///    background and nothing tells it. Dropping what the package manager said
  ///    is what makes INB-16's `sourceAppGone` line appear after the user
  ///    uninstalls a source app, and what makes a re-installed app's icon come
  ///    back.
  ///  * A resume that captured nothing still crossed a midnight, and INB-1's
  ///    times are relative to today. Reading again is cheap and keeps a row
  ///    from claiming this morning's clock time for yesterday's message.
  ///
  /// Since section 9, a third: whether the app can see notifications at all.
  /// PERM-5 says that is read from the system on every cold start and every
  /// resume and from nothing the app stored — the process can be killed while
  /// the system page is open and the listener can bind while the Flutter app is
  /// dead, so there is no return to observe and no flag that could stand in for
  /// one. It is also the resume PERM-10 counts: one call to
  /// [PermissionsProvider.refresh] is one resume, which is what makes "at most
  /// one rebind request per resume" enforceable in the state layer.
  ///
  /// **The order of the three below is load-bearing and is why the third is
  /// last.** `forgetAll` must run inside this synchronous observer pass:
  /// `source_app.dart` schedules its own re-resolve as a microtask precisely so
  /// that it runs after the last observer, and it is depending on the cache
  /// having been dropped by then. `_refreshAfterDrain` then has to be started
  /// before anything that can occupy the event loop, because INB-25's deadline
  /// is measured from this resume. The permissions read is started after both,
  /// touches neither the package cache nor the queue, and can take ten seconds
  /// on PERM-10's branch — which is exactly why it is not in front of them.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    widget.services.packages.forgetAll();
    unawaited(_refreshAfterDrain());
    unawaited(_resumePermissionsRead());
  }

  /// PERM-5's read on a resume, and PERM-14's offer behind it.
  ///
  /// The guidance is shown "on the first launch **or resume** that reads access
  /// as granted while the guidance has not yet been shown", which is this: a
  /// user who granted access on the system page and came back has had no launch
  /// since, and a flag written when the grant was read rather than when the
  /// guidance was drawn is the thing PERM-14's last clause forbids.
  Future<void> _resumePermissionsRead() async {
    await _permissions.refresh();
    if (!mounted) return;
    _offerOnboarding();
  }

  /// INB-25's second half: a message captured while the app was not
  /// foregrounded "is on screen in the first frame of the list drawn after the
  /// next resume, **because the queue is drained before the list reads it**".
  ///
  /// That "because" is an ordering, and it was a race. `CaptureSync` observes
  /// the same resume and drains by itself, so the list's own resume read used
  /// to start beside the drain rather than after it: it read the database as it
  /// stood before the queue was applied, and the message reached the screen a
  /// frame or more later, when the drain's own signal arrived. Awaiting the
  /// pass here is what makes the read follow it.
  ///
  /// A pass already running is joined rather than started again — `sync` keeps
  /// a request made mid-pass and loops — so this observer firing before
  /// `CaptureSync`'s own still ends with one drain, fully applied, before the
  /// read. Nothing inside a pass escapes as an error, and off Android there is
  /// no sync at all and this is just the refresh.
  Future<void> _refreshAfterDrain() async {
    await widget.captureSync?.sync();
    await _inbox.refresh();
  }

  /// INB-18's first tap. The push is awaited because INB-5 makes the thread a
  /// write: opening it advances `read_through_at` to the newest message the
  /// conversation holds, so the count the list is still drawing is stale the
  /// moment the reader backs out. Nothing else refreshes the list on a return —
  /// the capture signal fires only when capture wrote something, and reading a
  /// thread is not capture — so the badge stayed on the row until the next
  /// message arrived from anywhere.
  Future<void> _openConversation(
    BuildContext context,
    Conversation conversation,
  ) async {
    await Navigator.of(context).push(ThreadScreen.route(conversation));
    await _inbox.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.captureSync?.stop();
    _inbox.dispose();
    _apps.dispose();
    // Ours, built above and provided by `.value`, so ownership never left this
    // state — the same bargain `_inbox` and `_apps` are on. It listens to the
    // capture signal like those two, so it belongs with them and above the line
    // that disposes it; what it can *also* be holding is PERM-10's ten-second
    // wait, and `DeferredNotifier` is what makes that wait finish harmlessly
    // into a disposed notifier.
    _permissions.dispose();
    // After the three that listen to it, so none is left holding a listener
    // on a disposed notifier.
    _captureSignal.dispose();
    // Only the one we made. Disposing a notifier we were handed would leave
    // whoever handed it over holding something that throws on its next report.
    if (widget.health == null) _health.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: <SingleChildWidget>[
        ChangeNotifierProvider<InboxProvider>.value(value: _inbox),
        // The row's icon and its installed-or-gone (INB-1, INB-16) come from a
        // device service, and a widget cannot be handed one down six
        // constructors. Not a `ChangeNotifierProvider`: these are not state and
        // nothing rebuilds when one of them answers — the widget that asked
        // does.
        Provider<DeviceServices>.value(value: widget.services),
        // For the screens this one routes to: a thread has the same
        // one-second deadline as the list (INB-25), and its provider is built
        // where it is opened rather than here, so it needs to be able to reach
        // the same signal.
        // A `ChangeNotifierProvider`, because a plain `Provider` refuses a
        // `Listenable` — and because `.value` is what keeps ownership here:
        // this one is disposed in [dispose], after the two providers that
        // listen to it. Nothing watches it, so nothing rebuilds from it; the
        // screens that take it `read` it once and subscribe themselves.
        ChangeNotifierProvider<CaptureSignal>.value(value: _captureSignal),
        // The thread builds its own provider when it opens, because a thread's
        // lifetime is the time one is open, so it needs the database the same
        // way it needs the services.
        Provider<Repository>.value(value: widget.repository),
        ChangeNotifierProvider<AppsProvider>.value(value: _apps),
        // PERM-8's banner reads this. It is separate from `InboxProvider`
        // because it is not inbox state: it is what the listener could not do,
        // and it keeps moving while the inbox has nothing new to show.
        ChangeNotifierProvider<CaptureHealth>.value(value: _health),
        // Section 9's three screens read this, and so does PERM-13's single
        // status line on the first screen. `.value` like the four above,
        // because it was built in this state and is disposed there: a
        // `ChangeNotifierProvider` that constructed it would dispose it on
        // every rebuild of this widget, and PERM-10's ten-second wait would
        // finish into a notifier nothing is listening to.
        ChangeNotifierProvider<PermissionsProvider>.value(value: _permissions),
      ],
      child: MaterialApp(
        // PERM-4's and PERM-14's pushes happen from the state above this
        // widget, which has no navigator of its own. See [_navigator].
        navigatorKey: _navigator,
        onGenerateTitle: (BuildContext context) =>
            AppLocalizations.of(context).appTitle,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: replyboxTheme(),
        darkTheme: replyboxTheme(brightness: Brightness.dark),
        routes: <String, WidgetBuilder>{
          IncludedAppsScreen.routeName: (BuildContext context) =>
              const IncludedAppsScreen(),
          // PERM-1: the disclosure is a route and a first-run push, and never a
          // gate. Every in-app path to the system's notification-access page
          // arrives here first — the push above, PERM-8's banner action, and
          // the row at the foot of the included-apps list — and the screen
          // itself is the only caller of `openAccessSettings` in `lib/`.
          DisclosureScreen.routeName: (BuildContext context) =>
              const DisclosureScreen(),
          // PERM-14. Pushed once after the first screen, and reachable from the
          // included-apps list and from PERM-10's and PERM-11's lines after
          // that.
          BatteryGuidanceScreen.routeName: (BuildContext context) =>
              const BatteryGuidanceScreen(),
          // PERM-16. No `onOpenHosted`: nothing in the app can open a browser
          // yet, and the screen shows the hosted address as text rather than a
          // control that would do nothing. Its doc comment carries the whole of
          // what is missing.
          PrivacyPolicyScreen.routeName: (BuildContext context) =>
              const PrivacyPolicyScreen(),
        },
        home: InboxScreen(
          // INB-18's second tap is on the screen this push opens, so the push
          // itself is not one: the row is tap one, and the control in the
          // thread's bottom bar is tap two.
          onOpenConversation:
              (BuildContext context, Conversation conversation) =>
                  unawaited(_openConversation(context, conversation)),
          // INB-15's *Nothing yet* action, and INB-20's list.
          onOpenIncludedApps: (BuildContext context) => unawaited(
            Navigator.of(context).pushNamed(IncludedAppsScreen.routeName),
          ),
        ),
      ),
    );
  }
}
