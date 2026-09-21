import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'db/db_helper.dart';
import 'db/repository.dart';
import 'l10n/app_localizations.dart';
import 'providers/inbox_provider.dart';
import 'services/android_capture_service.dart';
import 'services/noop_services.dart';
import 'services/services.dart';

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
              reply: AndroidReplyService(),
              // Still no-op, and each waits on its own item: the launcher on
              // INB-13's control, the rest on Triage, Plus and App lock.
              launcher: const NoopAppLauncher(),
              reminders: const NoopReminderScheduler(),
              entitlements: const NoopEntitlements(),
              appLock: const NoopAppLock(),
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

class _ReplyboxAppState extends State<ReplyboxApp> {
  /// Built once here rather than in `build`, because the drain loop holds a
  /// reference to it: a provider rebuilt under the loop would leave the loop
  /// refreshing a state object no screen is reading.
  late final InboxProvider _inbox = InboxProvider(
    widget.repository,
    widget.services,
  );

  /// The one the drain loop was given, or one of our own when there is no loop.
  late final CaptureHealth _health = widget.health ?? CaptureHealth();

  @override
  void initState() {
    super.initState();
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
    unawaited(widget.repository.installedAt(DateTime.now().toUtc()));
    unawaited(_inbox.load());
    // The listener kept queueing while the app was closed, so the first drain
    // happens before anyone has had a chance to pull anything to refresh
    // (CAP-13, INB-25).
    widget.captureSync?.start(onChanged: _inbox.load);
  }

  @override
  void dispose() {
    widget.captureSync?.stop();
    _inbox.dispose();
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
        // PERM-8's banner reads this. It is separate from `InboxProvider`
        // because it is not inbox state: it is what the listener could not do,
        // and it keeps moving while the inbox has nothing new to show.
        ChangeNotifierProvider<CaptureHealth>.value(value: _health),
      ],
      child: MaterialApp(
        onGenerateTitle: (BuildContext context) =>
            AppLocalizations.of(context).appTitle,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
        ),
        home: const _Placeholder(),
      ),
    );
  }
}

/// What the app shows until the Inbox item ships its screens.
///
/// It deliberately uses the real empty-state message rather than a lorem
/// placeholder, so the string, the generation and the locale wiring are all
/// exercised by the widget test that covers this.
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.inboxEmptyNothingYet,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      ),
    );
  }
}
