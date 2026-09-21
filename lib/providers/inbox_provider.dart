import 'package:flutter/foundation.dart';

import '../db/repository.dart';
import '../models/conversation.dart';
import '../models/source_app.dart';
import '../services/services.dart';

/// The inbox's state.
///
/// Every mutation here follows the same order: **write first, then change
/// state, and roll back on failure.** The opposite order — update the list,
/// then persist — is what produces a UI that shows something the database
/// does not have, which survives until the next restart and then looks to the
/// user like data loss.
class InboxProvider extends ChangeNotifier {
  /// Both dependencies are injected, never reached for: that is what lets a
  /// test hand over an in-memory database and the no-op services. Positional
  /// because Dart has no private named parameters, and these fields have no
  /// business being public.
  InboxProvider(this._repository, this._services);

  final Repository _repository;
  final DeviceServices _services;

  List<Conversation> _conversations = const <Conversation>[];
  List<SourceApp> _apps = const <SourceApp>[];
  Set<String> _filter = const <String>{};
  bool _loading = false;
  Object? _error;

  List<Conversation> get conversations => _conversations;
  List<SourceApp> get apps => _apps;

  /// Packages the list is filtered to. Empty means no filter (INB-14).
  Set<String> get filter => _filter;

  bool get isLoading => _loading;

  /// The last failure, for the screen to show. Cleared by the next successful
  /// mutation, never silently.
  Object? get error => _error;

  /// Whether replying in place is possible for this conversation right now
  /// (CAP-14). Always false after a cold start, which is why the inbox needs
  /// "open in app" before the Reply area exists (INB-13).
  bool canReplyTo(Conversation conversation) =>
      _services.reply.canReplyTo(conversation);

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    try {
      _apps = await _repository.allApps();
      _conversations = await _repository.conversations(
        packages: _filter.isEmpty ? null : _filter.toList(),
      );
      _error = null;
    } catch (e) {
      _error = e;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> setFilter(Set<String> packages) async {
    _filter = packages;
    await load();
  }

  /// Deletes a conversation and everything in it (CAP-16, DEL-1, DEL-2).
  ///
  /// Returns the instant it was deleted, which [undoDelete] needs to restore
  /// exactly the messages this step took and no others (CAP-23).
  Future<DateTime?> deleteConversation(
    Conversation conversation,
    DateTime now,
  ) async {
    final List<Conversation> before = _conversations;
    try {
      await _repository.deleteConversation(conversation.id, now);
    } catch (e) {
      _error = e;
      notifyListeners();
      return null;
    }
    // Only now does the list change, and only because the write succeeded.
    _conversations = before
        .where((Conversation c) => c.id != conversation.id)
        .toList(growable: false);
    _error = null;
    notifyListeners();
    return now;
  }

  Future<void> undoDelete(Conversation conversation, DateTime deletedAt) async {
    try {
      await _repository.undeleteConversation(conversation.id, deletedAt);
    } catch (e) {
      _error = e;
      notifyListeners();
      return;
    }
    await load();
  }

  /// Turns a source app on or off (INB-22). What it already captured stays in
  /// the inbox (CAP-1).
  ///
  /// Two steps, in this order: the row, then CAP-1's filter. The row first
  /// because the database is the only authority on what is on; the filter
  /// immediately after because INB-22 says the switch takes effect from the
  /// moment it moves, and the listener is what makes that true. Waiting for the
  /// next resume to mirror the set — which is all that used to happen — loses
  /// messages in one direction and captures forbidden ones in the other:
  ///
  ///  * **On.** The user switches an app on and locks the phone. The listener
  ///    still has it off, so CAP-1 drops what it posts *before the queue*, and
  ///    dropped there means gone, not late. INB-22 promises capture "from that
  ///    moment forward".
  ///  * **Off.** The user switches an app off and stays in the inbox. The
  ///    listener still has it on, so the next notification's sender, title and
  ///    full text are written into the hand-over queue. Ingest refuses to store
  ///    it, but CAP-1 puts the drop before anything reaches the queue, and text
  ///    sitting in a file is the thing the rule is about.
  ///
  /// The push carries both halves for the OFF direction to be true at all. An
  /// app that posted while Dart was not running is sitting un-acked in the
  /// listener's pending list at the moment the switch moves, and on the enabled
  /// list alone the listener put every such package straight back — so the app
  /// the user had just turned off kept projecting into the queue until a later
  /// sync pass. Sending the packages this database holds a row for as well is
  /// what closes that: this one has a row, it was left out, it is off.
  Future<void> setAppEnabled(
    String package, {
    required bool enabled,
    required DateTime now,
  }) async {
    final List<SourceApp> before = _apps;
    try {
      await _repository.setAppEnabled(package, enabled: enabled, at: now);
    } catch (e) {
      _error = e;
      _apps = before;
      notifyListeners();
      return;
    }

    // Before `load()`, not after: `load()` also reads every conversation, and
    // CAP-1's drop happens on whatever the listener is holding in the meantime.
    // Its own read of the apps table is the mirror of what was just written —
    // the provider's cached list is a frame behind until `load()` returns.
    Object? pushFailure;
    try {
      await _pushEnabledPackages();
    } catch (e) {
      pushFailure = e;
    }

    _error = null;
    await load();
    if (pushFailure != null) {
      // Surfaced, never swallowed. The row moved and the listener did not, so
      // the switch on screen is telling the user something the phone is not
      // doing — silent loss in the ON direction. The database keeps the write:
      // it is the authority, and the next launch or resume re-mirrors from it.
      _error = pushFailure;
      notifyListeners();
    }
  }

  /// Mirrors the enabled set down to CAP-1's filter, read fresh from the
  /// database so this is a mirror and never a merge.
  ///
  /// Both lists come off that one read: the enabled packages, and every package
  /// the table holds a row for. The second is what makes the OFF direction
  /// immediate rather than eventual (CAP-1, INB-22) — see [setAppEnabled] — and
  /// reading it twice could hand the listener an enabled package it was told
  /// nothing is known about.
  Future<void> _pushEnabledPackages() async {
    final List<SourceApp> apps = await _repository.allApps();
    await _services.captureFilter.setEnabledPackages(
      <String>[
        for (final SourceApp app in apps)
          if (app.enabled) app.package,
      ],
      <String>[for (final SourceApp app in apps) app.package],
    );
  }
}
