/// The included-apps list in Settings — the only Settings this version has
/// (INB-20 to INB-22).
///
/// It belongs to the Inbox area rather than to Permissions, because the Inbox
/// item ships first and cannot ship a Settings screen that does not exist yet
/// (section 8's preamble). INB-15's *Nothing yet* empty state routes here as
/// its one action, so an inbox with nothing in it still reaches it.
///
/// Presentational: everything on screen is read from [AppsProvider], every
/// string comes from the message files, and the only writes are the two
/// mutations INB-22 names.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/normalise.dart';
import '../providers/apps_provider.dart';
// For [StateFailure] and [FailureKind], which every provider in this area
// reports through and which this screen turns into one line per row (INB-22).
import '../providers/inbox_provider.dart';
import '../services/services.dart';
import '../widgets/failure_notice.dart';
import '../widgets/source_app.dart';
import '../widgets/source_app_row.dart';

class IncludedAppsScreen extends StatefulWidget {
  const IncludedAppsScreen({super.key});

  /// The route the inbox pushes for INB-15's *Nothing yet* action and for
  /// wherever the list puts Settings.
  static const String routeName = '/included-apps';

  @override
  State<IncludedAppsScreen> createState() => _IncludedAppsScreenState();
}

class _IncludedAppsScreenState extends State<IncludedAppsScreen>
    with WidgetsBindingObserver {
  /// What the package manager said about each package on screen, keyed by
  /// package. Resolved once per read and held here rather than fetched per
  /// build, so scrolling asks nothing (INB-20).
  final Map<String, SourceAppIdentity> _identities =
      <String, SourceAppIdentity>{};

  final TextEditingController _search = TextEditingController();

  /// Guards the one-shot first read, which the screen owns because the
  /// provider may have been built for the inbox and never opened.
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final AppsProvider apps = context.read<AppsProvider>();
    // A spinner only where there is nothing to show yet: a provider the inbox
    // already filled re-reads quietly instead of blanking a list the user is
    // looking at (INB-25's discipline).
    unawaited(apps.apps.isEmpty ? apps.load() : apps.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  /// INB-16: nothing tells the app that a source app was uninstalled while
  /// Replybox was in the background — watching for it would mean a broadcast
  /// receiver this app does not have — so the answers are dropped on resume
  /// and asked again. That is what makes a `No longer installed` row appear.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    sourceAppPackages(context)?.forgetAll();
    setState(_identities.clear);
    final AppsProvider apps = context.read<AppsProvider>();
    unawaited(apps.refresh());
  }

  /// Asks about exactly the packages already on the list, and nothing else.
  ///
  /// INB-20: the app never enumerates installed packages. This iterates the
  /// rows the provider built out of its two sources, and the service answers a
  /// package outside INB-16's `<queries>` declaration without touching the
  /// phone at all.
  Future<void> _resolve(List<String> pending) async {
    final PackageInfoService? packages = sourceAppPackages(context);
    if (packages == null) return;
    _resolving = true;
    final List<SourceAppIdentity> resolved = await Future.wait(
      pending.map(packages.lookup),
    );
    if (!mounted) {
      _resolving = false;
      return;
    }
    setState(() {
      _resolving = false;
      for (final SourceAppIdentity identity in resolved) {
        _identities[identity.package] = identity;
      }
    });
  }

  /// True while a batch of lookups is in flight, so a rebuild in the middle of
  /// one does not start a second.
  bool _resolving = false;

  /// INB-22's "about five seconds of Undo" (INB-6, DEL-2), and three times that
  /// for someone who has to be told the line and the action before either
  /// exists for them (INB-23). The twin of `inbox_screen.dart`'s, which argues
  /// the choice; both windows close, and only the length differs.
  Duration get _undoDuration => MediaQuery.accessibleNavigationOf(context)
      ? const Duration(seconds: 15)
      : const Duration(seconds: 5);

  /// What the package manager has already answered for [package], preferring
  /// the cache so a row draws its icon in its first frame rather than flashing
  /// the fallback through a rebuild.
  SourceAppIdentity? _identityOf(String package) =>
      _identities[package] ?? sourceAppPackages(context)?.lookupCached(package);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AppsProvider provider = context.watch<AppsProvider>();
    final List<IncludedApp> apps = provider.apps;

    // Which rows still have no answer. Computed here, asked outside the build:
    // resolving during build would set state while the tree is being laid out.
    final List<String> pending = <String>[
      for (final IncludedApp app in apps)
        if (!_identities.containsKey(app.package)) app.package,
    ];
    if (pending.isNotEmpty && !_resolving) {
      scheduleMicrotask(() {
        if (mounted) unawaited(_resolve(pending));
      });
    }

    final List<IncludedApp> shown = _matching(apps);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.includedAppsTitle)),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Nothing to show yet and a read in flight. Once there are rows the
            // list stays put and re-reads underneath it.
            if (provider.isLoading && apps.isEmpty)
              const LinearProgressIndicator(minHeight: 2),

            // INB-22: what the switch does is stated rather than confirmed. It
            // is said once for the screen instead of on every row, because one
            // sentence repeated down a list is the same sentence and, at 1.3x
            // text on a phone, is what overflows the rows (INB-23).
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                l10n.includedAppsSwitchExplainer,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),

            // INB-21: a search field appears once the list passes ten rows.
            if (provider.showsSearchField)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _search,
                  onChanged: (String _) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search),
                    hintText: l10n.includedAppsSearchHint,
                  ),
                ),
              ),

            // The read failed and left nothing behind: without this the screen
            // is the explainer, the standing note and no rows at all, which
            // reads as a phone that has never seen a messaging app (INB-21,
            // product principle 3). A failure with rows already on screen
            // leaves them — they are the last true thing the app read.
            //
            // `failedToLoad` and not `error != null && apps.isEmpty`: the
            // shipped six are always rows (INB-20), so `apps.isEmpty` is never
            // true once a read has landed, and this condition used to be the
            // only reader of the error on the screen — which left the write
            // failure and INB-22's capture-filter failure with nowhere to be
            // drawn at all. Both belong on the row they happened to, below.
            if (provider.failedToLoad)
              Expanded(
                child: FailureNotice(
                  // The line, never the exception (INB-24).
                  message: l10n.includedAppsLoadFailed,
                  onRetry: () => unawaited(provider.load()),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  // One past the rows: the last item is INB-21's permanent line.
                  itemCount: shown.length + 1,
                  itemBuilder: (BuildContext context, int index) {
                    if (index == shown.length) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                        child: Text(
                          // INB-21: why an app the user expected is missing —
                          // permanent, so an absent app reads as a stated limit
                          // rather than as a bug (product principle 3).
                          l10n.includedAppsMissingNote,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      );
                    }
                    final IncludedApp app = shown[index];
                    return SourceAppRow(
                      // Keyed by package so a row that moves between INB-21's
                      // groups after a switch carries its state with it instead
                      // of the row that took its place.
                      key: ValueKey<String>(app.package),
                      app: app,
                      identity: _identityOf(app.package),
                      onEnabledChanged: (bool enabled) =>
                          unawaited(_setEnabled(app, enabled: enabled)),
                      // INB-22: removing the stored messages is a separate,
                      // explicit action, and there is nothing to offer on a row
                      // with nothing stored.
                      onRemoveMessages: app.hasCaptured
                          ? () => unawaited(_removeCaptured(app))
                          : null,
                      failure: _failureFor(provider, app),
                      // The action for the capture-filter line: mirror the set
                      // down again. Nothing is re-written — the database
                      // already holds the truth — so the switch stays where it
                      // is and only the half that failed is tried again.
                      onRetryCaptureFilter: () =>
                          unawaited(provider.retryCaptureFilter()),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Which row a failure belongs to, and what that row says about it (INB-22).
  ///
  /// Only a failure the state layer attributed to a package is drawn, and only
  /// on that package's own row: a mutation that failed for WhatsApp says
  /// nothing on the Telegram row. A read failure is not a row's business — it
  /// is the whole list's, and [AppsProvider.failedToLoad] is where it is drawn.
  ///
  /// The write first and the capture-filter failure under it, which is the
  /// order [AppsProvider.error] itself composes them in: a write that has just
  /// been refused is the fresher fact, and the capture-filter one is held in a
  /// field of its own precisely because it outlives the reads around it.
  ///
  /// The exception never reaches the row. It is not even passed: `Repository`
  /// composes its failures out of the `Message` it was writing, so handing the
  /// widget anything but a kind would be one edit away from a sender's name on
  /// screen (INB-24).
  SourceAppRowFailure? _failureFor(AppsProvider provider, IncludedApp app) {
    final StateFailure? error = provider.error;
    if (error != null &&
        error.kind == FailureKind.write &&
        error.package == app.package) {
      return SourceAppRowFailure.write;
    }
    // Read from its own getter rather than from `error`, which returns whatever
    // is fresher: a read that failed elsewhere must not take this line off the
    // row while CAP-1's filter is still working from the old set.
    final StateFailure? filter = provider.captureFilterFailure;
    if (filter != null && filter.package == app.package) {
      return SourceAppRowFailure.captureFilter;
    }
    return null;
  }

  /// INB-21's search, over exactly what the row draws: the resolved label with
  /// INB-1's fallbacks, and the package name.
  ///
  /// Folded through [normalise] rather than lower-cased, so the match ignores
  /// case and accents the way LANG-4 says search does everywhere else.
  List<IncludedApp> _matching(List<IncludedApp> apps) {
    final String query = normalise(_search.text.trim());
    if (query.isEmpty) return apps;
    return <IncludedApp>[
      for (final IncludedApp app in apps)
        if (normalise(
              // The one chain, so the search matches exactly the name the row
              // draws (INB-1).
              sourceAppLabel(
                package: app.package,
                identity: _identityOf(app.package),
                app: app.row,
              ),
            ).contains(query) ||
            normalise(app.package).contains(query))
          app,
    ];
  }

  /// INB-22: the switch moving is the whole confirmation. No dialog, and
  /// nothing on screen changes but the switch and the row's place in INB-21's
  /// order.
  ///
  /// Awaited rather than fired and forgotten, because the switch is not the
  /// whole confirmation when it fails to mean anything: the write can be
  /// refused, and CAP-1's filter can miss a write that landed. Both outcomes
  /// come back on [AppsProvider.error] with the package on them, and the row
  /// that moved draws whichever one it is.
  Future<void> _setEnabled(IncludedApp app, {required bool enabled}) async {
    await context.read<AppsProvider>().setEnabled(
      app.package,
      enabled: enabled,
      now: DateTime.now().toUtc(),
    );
  }

  /// INB-22's separate action: soft-deletes that app's conversations and their
  /// messages in one step, with about five seconds of Undo (INB-6, CAP-16).
  Future<void> _removeCaptured(IncludedApp app) async {
    final AppsProvider provider = context.read<AppsProvider>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);

    final ({DateTime deletedAt, int conversations})? removed = await provider
        .removeCaptured(app.package, DateTime.now().toUtc());
    if (!mounted) return;
    // Null is the write having failed, so nothing moved and there is nothing to
    // offer an Undo for — but the user pressed a control and something has to
    // answer them. The line is from the message files and names no app,
    // because the exception behind it carries a message's text (INB-24).
    if (removed == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.changeFailed),
            duration: _undoDuration,
            persist: false,
          ),
        );
      return;
    }

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          l10n.includedAppsRemoveMessagesDone(removed.conversations),
        ),
        duration: _undoDuration,
        // A `SnackBar` with an action persists by default and never times out,
        // so INB-22's five seconds of Undo were the rest of the run: the row
        // went on offering to put back a delete the user had moved on from.
        persist: false,
        action: SnackBarAction(
          label: l10n.undo,
          // CAP-23: a later notification revives a conversation the user
          // deleted rather than forking a second one, so this puts back exactly
          // what that step took and nothing else.
          onPressed: () => unawaited(
            provider.undoRemoveCaptured(app.package, removed.deletedAt),
          ),
        ),
      ),
    );
  }
}
