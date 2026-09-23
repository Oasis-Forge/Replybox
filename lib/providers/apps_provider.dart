import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/shipped_apps.dart';
import '../db/repository.dart';
import '../models/normalise.dart';
import '../models/source_app.dart';
import '../services/services.dart';
// For [sourceAppLabel], INB-1's one label chain. A widget file, but the chain
// itself is a plain function with no `BuildContext` in it, and `source_app.dart`
// is explicit that every surface naming a source app calls this one and nothing
// else does the work — including INB-21's sort, which is a surface too: it puts
// the rows in the order the user reads them.
import '../widgets/source_app.dart';
import 'inbox_provider.dart';

/// INB-21's four groups. Every row falls in exactly one, and the list is drawn
/// in this order.
enum AppGroup {
  /// On, with at least one conversation the list can show. Ordered by the most
  /// recent captured message, then by label.
  onWithMessages,

  /// On, with nothing captured. Ordered by label. At first launch every
  /// shipped-list row sits here.
  onWithNothing,

  /// Off, and seen posting. Ordered by most recently seen, then by label.
  offAndSeen,

  /// The rest, by label: a row that is off and that the listener has never seen
  /// post anything.
  rest,
}

/// One row of the included-apps list (INB-20, INB-21).
@immutable
class IncludedApp {
  const IncludedApp({
    required this.package,
    required this.row,
    required this.enabled,
    required this.isShipped,
    required this.lastSeenAt,
    required this.conversationCount,
    required this.newestMessageAt,
    required this.group,
    required this.sortLabel,
  });

  final String package;

  /// The stored row, or null for a shipped package the listener has not seen
  /// post yet — which has no row at all, because CAP-1 captures from it from
  /// its first notification without anyone having to write anything down.
  final SourceApp? row;

  /// INB-1's fallbacks, as data: the label the listener stored, or null, in
  /// which case the screen shows a generic source icon and the package name.
  String? get label => row?.label;

  /// Whether messages from this app are captured (CAP-1). For a package with no
  /// row this is CAP-1's default, which is on for the shipped list and off for
  /// everything else.
  final bool enabled;

  /// Whether this is one of the six in `lib/data/shipped_apps.dart` (INB-20).
  final bool isShipped;

  /// When the listener last saw this package post, or null where it never has.
  /// Null is what separates INB-21's third group from its fourth.
  final DateTime? lastSeenAt;

  /// How many conversations the list can show from this app (INB-21).
  final int conversationCount;

  /// The most recent captured message, which is what orders the first group.
  final DateTime? newestMessageAt;

  final AppGroup group;

  /// The name this row is actually drawn with, which is what INB-21 sorts on.
  ///
  /// INB-1's chain, resolved at read time: the package manager's label for a
  /// package inside INB-16's `<queries>` declaration, then [label], then the
  /// package name. It has to be this and not [label], because [label] is only
  /// the middle branch — the device drill of 23 September 2026 found the second
  /// group in exactly package order with `Messages` sitting second, drawn under
  /// the name the package manager gave it and sorted under
  /// `com.google.android.apps.messaging`, which on a phone with all six
  /// installed reads as no sort at all.
  final String sortLabel;

  /// INB-21: a row shows either the number of conversations stored from it or
  /// that nothing has arrived yet.
  bool get hasCaptured => conversationCount > 0;
}

/// The included-apps list in Settings (INB-20 to INB-22).
///
/// This screen belongs to the Inbox area rather than to Permissions, because
/// the Inbox item ships first and cannot ship a Settings screen that does not
/// exist yet (INB-20).
///
/// Every mutation follows the house order: **write first, then change state,
/// and roll back on failure.** For the switch that matters more than usual —
/// the row on disk is the only authority on what is captured, and the listener
/// is a mirror of it.
class AppsProvider extends ChangeNotifier with DeferredNotifier {
  AppsProvider(
    this._repository,
    this._services, {
    CaptureSignal? captureSignal,
  }) {
    _captureSignal = captureSignal;
    _captureSignal?.addListener(_onCaptured);
  }

  final Repository _repository;
  final DeviceServices _services;
  CaptureSignal? _captureSignal;

  List<IncludedApp> _apps = const <IncludedApp>[];
  bool _loading = false;
  StateFailure? _error;

  /// [FailureKind.captureFilter], held apart from [_error] so a read that
  /// succeeded cannot clear it. See [captureFilterFailure].
  StateFailure? _captureFilterFailure;

  /// Whether [load] has ever run. Until it has, no screen has asked for this
  /// list and there is nothing on screen for a capture signal to keep fresh.
  bool _everLoaded = false;

  /// The rows, in INB-21's exact order.
  List<IncludedApp> get apps => _apps;

  bool get isLoading => _loading;

  /// The last failure, for the screen to show (see `InboxProvider.error` for
  /// the order the states are read in).
  ///
  /// [FailureKind.captureFilter] is the one this screen cannot leave unsaid:
  /// the switch moved, the row on disk moved, and CAP-1's filter never heard
  /// it, so the listener goes on dropping that package's notifications before
  /// the queue — messages lost rather than delayed, until the next launch or
  /// resume re-mirrors. Nothing the user can see is wrong, which is exactly
  /// why INB-22 needs it said.
  ///
  /// A read or write failure first, because it is the fresher fact and the one
  /// the user's last action produced; [captureFilterFailure] underneath it,
  /// because that one does not go away when a read succeeds.
  StateFailure? get error => _error ?? _captureFilterFailure;

  /// CAP-1's filter never heard a write that landed (INB-22), and it stays said
  /// until something actually mirrors the set down again.
  ///
  /// Its own field, and not [_error], because [load] and [refresh] clear that
  /// one on every read that succeeds — and this provider reads on every capture
  /// signal, which fires within the second of *any* app posting anything. Left
  /// there, the one failure that means messages are being lost right now was
  /// wiped by an unrelated message arriving: turn WhatsApp on while the
  /// listener is unbound, have Telegram post once, and the row goes back to
  /// looking perfectly fine while every WhatsApp notification is dropped before
  /// the queue.
  ///
  /// Cleared by a push that succeeds and by nothing else; [retryCaptureFilter]
  /// is the action for it, and the next cold start or resume re-mirrors from
  /// the database, which is the authority.
  StateFailure? get captureFilterFailure => _captureFilterFailure;

  /// Whether the list is empty because the read failed rather than because
  /// there is nothing to show. There is no such thing as an empty
  /// included-apps list — the shipped six are always rows (INB-20) — so a
  /// zero-row list with no sentence on it is always this.
  bool get failedToLoad => _error?.kind == FailureKind.read && _apps.isEmpty;

  /// INB-21: a search field appears once the list passes ten rows.
  bool get showsSearchField => _apps.length > 10;

  @override
  void dispose() {
    _captureSignal?.removeListener(_onCaptured);
    _captureSignal = null;
    super.dispose();
  }

  /// The screen's first read, started from `didChangeDependencies` — which runs
  /// inside the build this provider is being read in. The loading flag is
  /// therefore announced a microtask later, after that build has finished, and
  /// nothing is announced at all once the tree has come down under a read that
  /// was still in flight (see [DeferredNotifier]).
  Future<void> load() async {
    _loading = true;
    await notifyLater();
    if (isDisposed) return;
    try {
      _apps = await _read();
      _error = null;
    } catch (e) {
      _error = StateFailure(FailureKind.read, e);
    } finally {
      _loading = false;
      _everLoaded = true;
      notify();
    }
  }

  /// The same read without the spinner. A first sighting while this screen is
  /// open adds a row to it (INB-20, INB-25).
  Future<void> refresh() async {
    try {
      _apps = await _read();
      _error = null;
    } catch (e) {
      _error = StateFailure(FailureKind.read, e);
    }
    notify();
  }

  void _onCaptured() {
    // This provider outlives its screen — it is built once for the whole run
    // (`main.dart`) and the included-apps list is a route somebody opens now and
    // then. A capture signal fires for a message from any app, so without the
    // first gate the app ran `allApps()` and the whole-table conversation
    // aggregate on every captured message from launch onwards, for a screen
    // nobody had opened yet.
    if (!_everLoaded) return;
    // Coalesced for the same reason [InboxProvider] coalesces: the signal is per
    // message and the spike's own fixture put five on one timestamp (INB-4).
    // One read in flight, one queued behind it, and the queued one sees
    // everything that landed in between.
    if (_reading) {
      _readAgain = true;
      return;
    }
    unawaited(_refreshCoalesced());
  }

  bool _reading = false;
  bool _readAgain = false;

  Future<void> _refreshCoalesced() async {
    _reading = true;
    try {
      do {
        _readAgain = false;
        await refresh();
      } while (_readAgain && !isDisposed);
    } finally {
      _reading = false;
    }
  }

  /// INB-20: the list is built from two sources only — the shipped messaging
  /// apps, and packages the listener has actually seen post a notification.
  ///
  /// The app never enumerates installed packages, so a package that is in
  /// neither is not here, and INB-21's permanent bottom line is what says so on
  /// screen rather than this silently omitting it.
  Future<List<IncludedApp>> _read() async {
    final List<SourceApp> rows = await _repository.allApps();
    final Map<String, PackageActivity> activity = await _repository
        .conversationActivityByPackage();
    final Map<String, SourceApp> byPackage = <String, SourceApp>{
      for (final SourceApp row in rows) row.package: row,
    };
    final List<String> packages = <String>[
      ...<String>{...shippedMessagingApps, ...byPackage.keys},
    ];

    // INB-21 sorts by the label, and the label is INB-1's whole chain — so the
    // package manager is asked here, before the sort, rather than only by the
    // screen after it. Exactly these packages and nothing else (INB-20: the app
    // never enumerates installed packages), and `lookup` never throws: INB-16
    // turns every failure into `unknown`, which the chain reads as "nothing
    // resolved" and falls through.
    final List<SourceAppIdentity> identities = await Future.wait(
      packages.map(_services.packages.lookup),
    );
    final Map<String, SourceAppIdentity> byPackageIdentity =
        <String, SourceAppIdentity>{
          for (final SourceAppIdentity identity in identities)
            identity.package: identity,
        };

    final List<IncludedApp> entries = <IncludedApp>[
      for (final String package in packages)
        _entry(
          package,
          byPackage[package],
          activity[package],
          byPackageIdentity[package],
        ),
    ];
    entries.sort(_byGroupThenOrder);
    return List<IncludedApp>.unmodifiable(entries);
  }

  IncludedApp _entry(
    String package,
    SourceApp? row,
    PackageActivity? activity,
    SourceAppIdentity? identity,
  ) {
    // A shipped package with no row is on: CAP-1 says it is captured from the
    // first notification the listener sees, and INB-21 says that row sits in
    // the second group at first launch. Anything else with no row would be off,
    // but there is nothing else — a non-shipped package only appears here once
    // the listener has written its row.
    final bool enabled = row?.enabled ?? isShippedMessagingApp(package);
    final bool everPosted = row != null && !Repository.hasNeverPosted(row);
    final int conversations = activity?.conversations ?? 0;
    return IncludedApp(
      package: package,
      row: row,
      enabled: enabled,
      isShipped: isShippedMessagingApp(package),
      lastSeenAt: everPosted ? row.lastSeenAt : null,
      conversationCount: conversations,
      newestMessageAt: activity?.newestMessageAt,
      // The one chain, from the one place that holds it (`source_app.dart`).
      // A second copy of INB-1's branches here would be a second place for it
      // to fall one branch behind what the row draws — which is the defect
      // being fixed, in the other direction.
      sortLabel: sourceAppLabel(package: package, identity: identity, app: row),
      group: enabled
          // "At least one message captured", read as at least one conversation
          // the list can show: `last_message_at` is a message's arrival time, so
          // a package with a conversation had a message, and a package whose
          // conversations the user has all deleted has nothing on screen for
          // this group to be about.
          ? (conversations > 0
                ? AppGroup.onWithMessages
                : AppGroup.onWithNothing)
          : (everPosted ? AppGroup.offAndSeen : AppGroup.rest),
    );
  }

  /// INB-21's one exact order: the four groups, then each group's own keys,
  /// then the label, then the package.
  ///
  /// "Alphabetical" is the current language's collation (LANG-4). Dart's core
  /// `compareTo` is code-unit order, which puts `Zebra` before `ähnlich` and
  /// every accented label after every unaccented one — so the comparison runs
  /// over [normalise], the same folding capture already writes beside every
  /// title and sender, and ties fall through to the package ascending so the
  /// order is total and two reads can never disagree (INB-4's discipline).
  static int _byGroupThenOrder(IncludedApp a, IncludedApp b) {
    final int byGroup = a.group.index.compareTo(b.group.index);
    if (byGroup != 0) return byGroup;
    switch (a.group) {
      case AppGroup.onWithMessages:
        final int byRecency = _descending(a.newestMessageAt, b.newestMessageAt);
        if (byRecency != 0) return byRecency;
      case AppGroup.offAndSeen:
        final int bySeen = _descending(a.lastSeenAt, b.lastSeenAt);
        if (bySeen != 0) return bySeen;
      case AppGroup.onWithNothing:
      case AppGroup.rest:
        break;
    }
    // [IncludedApp.sortLabel] and not [IncludedApp.label]: the rule sorts by
    // the name the row draws, which is INB-1's resolved chain and not the
    // middle branch of it.
    final int byLabel = normalise(
      a.sortLabel,
    ).compareTo(normalise(b.sortLabel));
    return byLabel != 0 ? byLabel : a.package.compareTo(b.package);
  }

  /// Newest first, with a missing value sorting last rather than as epoch.
  static int _descending(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return b.compareTo(a);
  }

  /// INB-22's switch. The switch moving is the whole confirmation.
  ///
  /// Turning a row off means the next notification that package posts after the
  /// switch moves is not stored (CAP-1), and it changes nothing on screen but
  /// the switch: its conversations stay in the list, stay openable, stay
  /// searchable and keep their chip (INB-14).
  ///
  /// Two writes, in this order — the row, then CAP-1's filter — for the reason
  /// [InboxProvider.setAppEnabled] argues at length: a switch that moved on
  /// screen and not on the phone loses messages in the ON direction and writes
  /// forbidden text into the hand-over queue in the OFF one, and only the screen
  /// that moved it can tell the listener in time.
  ///
  /// `labelIfNew` is the package itself, and on purpose. A shipped app has no
  /// `apps` row until it posts (CAP-1), so turning its switch off has to open
  /// one, and the state layer has no package manager to ask for a name. INB-1's
  /// last fallback already draws a package name where no label resolves, and the
  /// first real sighting overwrites it with the app's own.
  Future<void> setEnabled(
    String package, {
    required bool enabled,
    required DateTime now,
  }) async {
    final List<IncludedApp> before = _apps;
    try {
      await _repository.setAppEnabled(
        package,
        enabled: enabled,
        at: now,
        labelIfNew: package,
      );
    } catch (e) {
      // Nothing moved: the row is as it was and the listener was never told
      // anything, so the switch can simply be used again.
      _error = StateFailure(FailureKind.write, e, package: package);
      _apps = before;
      notify();
      return;
    }

    Object? pushFailure;
    try {
      await _pushEnabledPackages();
    } catch (e) {
      pushFailure = e;
    }

    _error = null;
    // Its own field rather than `_error`, because it is the one state where the
    // screen, the database and the phone do not agree — and because `_error` is
    // cleared by the next read that succeeds, which a capture signal produces
    // within the second. Turn WhatsApp on while the listener is unbound and
    // this is what stands between the user and every notification dropped
    // before the queue until the next successful mirror (INB-22).
    //
    // Surfaced, never swallowed: the database keeps the write because it is the
    // authority, and the next launch or resume re-mirrors from it.
    _captureFilterFailure = pushFailure == null
        ? null
        : StateFailure(
            FailureKind.captureFilter,
            pushFailure,
            package: package,
          );
    await load();
  }

  /// The action for [captureFilterFailure]: mirror the set down again.
  ///
  /// Nothing is re-written — the database already holds the truth — so this
  /// retries the half that failed and nothing else. A success clears the state;
  /// a failure replaces it with the new one, still naming the package whose
  /// switch was moved, so the row it is drawn on does not move either.
  Future<void> retryCaptureFilter() async {
    final StateFailure? held = _captureFilterFailure;
    if (held == null) return;
    try {
      await _pushEnabledPackages();
      _captureFilterFailure = null;
    } catch (e) {
      _captureFilterFailure = StateFailure(
        FailureKind.captureFilter,
        e,
        package: held.package,
      );
    }
    notify();
  }

  /// INB-22's separate, explicit action on the same row: soft-deletes that
  /// app's conversations and their messages in one step, with about five
  /// seconds of Undo (INB-6, CAP-16).
  ///
  /// Returns the instant and the count, which is what the row says afterwards
  /// and what [undoRemoveCaptured] needs to restore exactly this step (CAP-23).
  /// Null means the write failed and nothing moved.
  Future<({DateTime deletedAt, int conversations})?> removeCaptured(
    String package,
    DateTime now,
  ) async {
    final int removed;
    try {
      removed = await _repository.deleteConversationsForPackage(package, now);
    } catch (e) {
      _error = StateFailure(FailureKind.write, e, package: package);
      notify();
      return null;
    }
    _error = null;
    await refresh();
    return (deletedAt: now, conversations: removed);
  }

  /// Undo for [removeCaptured]. A later notification revives a conversation the
  /// user deleted rather than forking a second one, so this puts back exactly
  /// what that step took (CAP-23).
  Future<void> undoRemoveCaptured(String package, DateTime deletedAt) async {
    try {
      await _repository.undeleteConversationsForPackage(package, deletedAt);
    } catch (e) {
      _error = StateFailure(FailureKind.write, e, package: package);
      notify();
      return;
    }
    _error = null;
    await refresh();
  }

  /// Mirrors the enabled set down to CAP-1's filter, read fresh from the
  /// database so this is a mirror and never a merge. The twin of
  /// [InboxProvider]'s, which argues why both halves are sent.
  Future<void> _pushEnabledPackages() async {
    final List<SourceApp> rows = await _repository.allApps();
    await _services.captureFilter.setEnabledPackages(
      <String>[
        for (final SourceApp app in rows)
          if (app.enabled) app.package,
      ],
      <String>[for (final SourceApp app in rows) app.package],
    );
  }
}
