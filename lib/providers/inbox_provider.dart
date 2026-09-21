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
    _error = null;
    await load();
  }
}
