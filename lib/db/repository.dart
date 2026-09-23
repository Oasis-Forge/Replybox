import 'package:sqflite/sqflite.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../models/record.dart';
import '../models/source_app.dart';
import 'db_helper.dart';

/// A message reached `idx_messages_post_identity` that the CAP-5 matching
/// should have recognised as one already stored.
///
/// This is a bug in the matching, never a user's doing, and it is thrown rather
/// than reported because of what the alternative cost: swallowing the rejection
/// turned a message the user had just been sent into a silent "already stored",
/// which is the exact failure CAP-5's correction of 21 September 2026 exists to
/// stop. Losing a message quietly is the one outcome that must never happen
/// again, so the app fails where someone can see it instead.
///
/// Only a message with no time of its own can raise it — a hidden one (CAP-8),
/// a raw one (CAP-21), an attachment or a line whose entry carried no readable
/// time — because that is the only identity the schema can still express as a
/// tuple. A message that carried its own time is identified by an alignment
/// against its notification's stored history, which no index can hold; see
/// [Repository.insertMessagesIfNew].
class MessageIdentityCollision implements Exception {
  const MessageIdentityCollision(this.message, this.cause);

  /// The message that could not be written.
  final Message message;

  /// What SQLite said.
  final DatabaseException cause;

  @override
  String toString() =>
      'MessageIdentityCollision: CAP-5 matching missed a stored row, so '
      '$message (conversation ${message.conversationId}, '
      'notification ${message.notificationKey}, '
      'history index ${message.historyIndex}) collided on '
      'idx_messages_post_identity and was not stored. $cause';
}

/// One stored message, read back as the alignment needs it: what a window
/// carries unchanged, and the time it is corroborated by (CAP-5).
typedef _StoredEntry = ({
  String id,
  String sender,
  String textHash,
  String direction,
  int sentAt,
});

/// What one source app has in the inbox: the conversations the list can show
/// from it, and the arrival time of its newest message (INB-14, INB-21).
typedef PackageActivity = ({int conversations, DateTime newestMessageAt});

/// Which table a [CaptureGap] was read off.
enum CaptureGapScope {
  /// `capture_sessions`: the listener was unbound, or notification access was
  /// off, so nothing at all was captured (CAP-12).
  device,

  /// `app_capture_sessions`: access was on and this one app's row was off, so
  /// its notifications were dropped before the queue (CAP-1, INB-22).
  app,
}

/// A stretch of time the app knows it was not capturing (CAP-12, INB-10).
///
/// Derived from the session rows, never stored: a gap is the absence between
/// two sessions, and storing an absence means writing a row every time nothing
/// happens.
class CaptureGap {
  const CaptureGap({required this.from, required this.to, required this.scope});

  /// When capture stopped — the `ended_at` of the session before the gap.
  final DateTime from;

  /// When it resumed, or [Repository.captureGaps]'s `now` where it has not.
  final DateTime to;

  final CaptureGapScope scope;

  Duration get duration => to.difference(from);

  /// Whether this gap falls inside a thread's range, which is what decides
  /// whether INB-10's notice mentions it at all. Half-open at both ends: a gap
  /// that ends exactly when the thread's oldest message arrived took nothing
  /// from it.
  bool overlaps(DateTime start, DateTime end) =>
      from.isBefore(end) && to.isAfter(start);

  @override
  String toString() => 'CaptureGap(${scope.name}, $from → $to)';
}

/// Every read and write of stored data goes through here.
///
/// Providers call this; nothing else touches SQL. Soft deletion is applied
/// here rather than left to callers, because DEL-1's "deleted records count
/// nowhere" is only true if every read remembers — and one that forgets is
/// invisible until a user sees a deleted message come back.
class Repository {
  Repository(this._db);

  final DBHelper _db;

  Future<Database> get _database => _db.database;

  // --- apps -------------------------------------------------------------

  /// Every app the listener has ever seen, enabled or not (INB-20).
  Future<List<SourceApp>> allApps() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'apps',
      where: 'deleted_at IS NULL',
      orderBy: 'label COLLATE NOCASE ASC',
    );
    return rows.map(SourceApp.fromMap).toList();
  }

  Future<SourceApp?> appByPackage(String package) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'apps',
      where: 'package = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[package],
      limit: 1,
    );
    return rows.isEmpty ? null : SourceApp.fromMap(rows.first);
  }

  /// Records that a package posted something, whether or not it is captured
  /// (INB-20). Keeps `enabled` as it stands: only the user changes that.
  Future<SourceApp> upsertSeenApp({
    required String package,
    required String label,
    required bool enabledIfNew,
    required DateTime at,
  }) async {
    final Database db = await _database;
    final SourceApp? existing = await appByPackage(package);
    if (existing == null) {
      final SourceApp created = SourceApp.seen(
        package: package,
        label: label,
        enabled: enabledIfNew,
        at: at,
      );
      await db.insert('apps', created.toMap());
      return created;
    }
    final SourceApp updated = existing.copyWith(
      label: label,
      lastSeenAt: at,
      updatedAt: at,
    );
    await db.update(
      'apps',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[updated.id],
    );
    return updated;
  }

  /// The `last_seen_at` of a row that exists because the user touched its
  /// switch and not because the listener saw the app post (INB-20, INB-21).
  ///
  /// `apps.last_seen_at` is `NOT NULL`, and INB-21 needs "seen posting" and
  /// "never seen posting" kept apart — they are its third group and its
  /// fourth. Epoch is the sentinel for the second, because there is no instant
  /// before it and nothing else in the schema can mean absent. A real sighting
  /// overwrites it ([upsertSeenApp] always writes the instant it was handed),
  /// so a row only carries this until the app posts once.
  ///
  /// Stating it here rather than in the chooser keeps the two readers — the
  /// write below and INB-21's grouping — on one definition.
  static final DateTime neverSeenPosting = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );

  /// Whether this row exists only because a switch moved, never because the
  /// listener saw the package post something (INB-21).
  static bool hasNeverPosted(SourceApp app) =>
      !app.lastSeenAt.isAfter(neverSeenPosting);

  /// Turning an app on or off (INB-22). Leaves everything already captured in
  /// the inbox (CAP-1).
  ///
  /// [labelIfNew] opens a row for a package that has none. A shipped app is
  /// captured from the first notification the listener sees (CAP-1) and so has
  /// no `apps` row until it posts — INB-21 puts exactly those rows in its
  /// second group at first launch — and without this the one switch on that row
  /// would move on screen and change nothing on disk. The row it opens carries
  /// [neverSeenPosting], because the listener has not seen this package and a
  /// row that claimed otherwise would sort itself into INB-21's third group on
  /// a sighting that never happened.
  ///
  /// Null [labelIfNew] keeps the old behaviour — no row, no write — for the
  /// callers that are reacting to stored state rather than to a user's tap.
  Future<void> setAppEnabled(
    String package, {
    required bool enabled,
    required DateTime at,
    String? labelIfNew,
  }) async {
    final Database db = await _database;
    final SourceApp? app = await appByPackage(package);
    if (app == null && labelIfNew == null) return;
    if (app == null) {
      await db.insert(
        'apps',
        SourceApp(
          id: newId(),
          package: package,
          label: labelIfNew!,
          enabled: enabled,
          lastSeenAt: neverSeenPosting,
          // The record's own clock is when the row was written; only
          // `last_seen_at` is a claim about the listener (REC-1).
          createdAt: at,
          updatedAt: at,
        ).toMap(),
      );
    } else {
      await db.update(
        'apps',
        app.copyWith(enabled: enabled, updatedAt: at).toMap(),
        where: 'id = ?',
        whereArgs: <Object?>[app.id],
      );
    }
    // One row per enable and per disable: a single timestamp cannot carry more
    // than one gap (INB-10, INB-22).
    if (enabled) {
      await db.insert('app_capture_sessions', <String, Object?>{
        'id': newId(),
        'package': package,
        'started_at': timeToDb(at),
        'ended_at': null,
        'created_at': timeToDb(at),
        'updated_at': timeToDb(at),
        'deleted_at': null,
      });
    } else {
      await db.update(
        'app_capture_sessions',
        <String, Object?>{'ended_at': timeToDb(at), 'updated_at': timeToDb(at)},
        where: 'package = ? AND ended_at IS NULL',
        whereArgs: <Object?>[package],
      );
    }
  }

  // --- conversations ----------------------------------------------------

  /// The inbox list, newest first (INB-4). Ties break by `created_at` then
  /// `id`, so two reads of the same data are always in the same order — the
  /// spike's burst put five messages on one timestamp, so ties are real.
  ///
  /// ## No `LIMIT`, deliberately
  ///
  /// This is the one unbounded read left, and it stays unbounded. A window here
  /// would drop the oldest conversations off the end of the list with nothing
  /// on screen saying so — no rule fixes a list window, INB-15 has no empty
  /// state for it, INB-10's "scrolling loads nothing" is about a thread, and
  /// search (area SRCH) does not exist yet to reach what fell off. Hiding a
  /// user's conversations under a screen that looks complete is the failure
  /// this whole area is written against (product principle 3), and it is not
  /// worth trading for a scan.
  ///
  /// What the scan actually costs, so the choice is a measurement and not a
  /// shrug. `idx_conversations_recent` is `(last_message_at DESC) WHERE
  /// deleted_at IS NULL`, so this is an index walk in the order it returns and
  /// never a sort; the work is one row read and one [Conversation] built per
  /// conversation. The ceiling is the number of **conversations** — one row per
  /// thread per app, not per message — so a heavy user after years sits in the
  /// low thousands, and the list read costs on that order: thousands of small
  /// objects, plus one [newestMessages] query per four hundred of them.
  /// [unreadCounts] and [conversationActivityByPackage] scale with the same
  /// number, not with the message table.
  ///
  /// The frequency was the real cost and it is fixed where it belongs, in the
  /// state layer: a capture signal fires per message, so `InboxProvider` and
  /// `AppsProvider` coalesce their signal-driven reads into one in flight and
  /// one queued, and `AppsProvider` does not read at all until its screen has
  /// been opened. If this ever does need bounding, it needs a rule and a
  /// sentence on screen first.
  Future<List<Conversation>> conversations({List<String>? packages}) async {
    final Database db = await _database;
    final bool filtered = packages != null && packages.isNotEmpty;
    final List<Map<String, Object?>> rows = await db.query(
      'conversations',
      where: filtered
          ? 'deleted_at IS NULL AND package IN (${List<String>.filled(packages.length, '?').join(',')})'
          : 'deleted_at IS NULL',
      whereArgs: filtered ? packages : null,
      orderBy: 'last_message_at DESC, created_at DESC, id ASC',
    );
    return rows.map(Conversation.fromMap).toList();
  }

  /// One thread by id, for the screen that opens it.
  ///
  /// Deleted rows are excluded (DEL-1): a conversation inside its Undo window
  /// is gone from every read, and the thread screen has to find it gone too —
  /// otherwise a row the list stopped drawing is still openable from a route
  /// the user left behind.
  Future<Conversation?> conversationById(String id) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'conversations',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : Conversation.fromMap(rows.first);
  }

  /// Finds a thread by its identity (CAP-3), including one the user deleted,
  /// because a new notification revives it rather than opening a second row
  /// (CAP-23).
  Future<Conversation?> conversationByKey(
    String package,
    String conversationKey, {
    bool includeDeleted = false,
  }) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'conversations',
      where: includeDeleted
          ? 'package = ? AND conversation_key = ?'
          : 'package = ? AND conversation_key = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[package, conversationKey],
      limit: 1,
    );
    return rows.isEmpty ? null : Conversation.fromMap(rows.first);
  }

  Future<void> insertConversation(Conversation conversation) async {
    final Database db = await _database;
    await db.insert('conversations', conversation.toMap());
  }

  Future<void> updateConversation(Conversation conversation) async {
    final Database db = await _database;
    await db.update(
      'conversations',
      conversation.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[conversation.id],
    );
  }

  /// Deleting a conversation soft-deletes it and every message in it in one
  /// step, so one Undo restores all of them (CAP-16, DEL-1, DEL-2).
  Future<void> deleteConversation(String id, DateTime at) async {
    final Database db = await _database;
    await db.transaction((Transaction txn) async {
      final int stamp = timeToDb(at);
      await txn.update(
        'conversations',
        <String, Object?>{'deleted_at': stamp, 'updated_at': stamp},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      await txn.update(
        'messages',
        <String, Object?>{'deleted_at': stamp, 'updated_at': stamp},
        where: 'conversation_id = ? AND deleted_at IS NULL',
        whereArgs: <Object?>[id],
      );
    });
  }

  /// Undo for [deleteConversation]. Restores only the messages that were
  /// deleted by that same step: a message the user had deleted earlier stays
  /// deleted (CAP-23).
  Future<void> undeleteConversation(String id, DateTime deletedAt) async {
    final Database db = await _database;
    await db.transaction((Transaction txn) async {
      final int stamp = timeToDb(deletedAt);
      await txn.update(
        'conversations',
        <String, Object?>{'deleted_at': null},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      await txn.update(
        'messages',
        <String, Object?>{'deleted_at': null},
        where: 'conversation_id = ? AND deleted_at = ?',
        whereArgs: <Object?>[id, stamp],
      );
    });
  }

  /// INB-22's separate, explicit action on an included-apps row: soft-deletes
  /// every conversation captured from one package and every message in them,
  /// in one step, so one Undo restores all of it (CAP-16, DEL-1, DEL-2).
  ///
  /// One `deleted_at` stamp across the whole step, for the same reason
  /// [deleteConversation] uses one: the stamp is what
  /// [undeleteConversationsForPackage] matches on, and a step that wrote two
  /// instants would restore half of itself.
  ///
  /// Turning the switch off is *not* this (INB-22): that leaves everything
  /// already captured in the inbox. Returns how many conversations went, which
  /// is what the row has to be able to say afterwards.
  Future<int> deleteConversationsForPackage(String package, DateTime at) async {
    final Database db = await _database;
    return db.transaction((Transaction txn) async {
      final int stamp = timeToDb(at);
      final List<Map<String, Object?>> targets = await txn.query(
        'conversations',
        columns: <String>['id'],
        where: 'package = ? AND deleted_at IS NULL',
        whereArgs: <Object?>[package],
      );
      if (targets.isEmpty) return 0;
      final List<String> ids = <String>[
        for (final Map<String, Object?> row in targets) row['id']! as String,
      ];
      final String placeholders = List<String>.filled(
        ids.length,
        '?',
      ).join(',');
      await txn.update(
        'conversations',
        <String, Object?>{'deleted_at': stamp, 'updated_at': stamp},
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
      await txn.update(
        'messages',
        <String, Object?>{'deleted_at': stamp, 'updated_at': stamp},
        where: 'conversation_id IN ($placeholders) AND deleted_at IS NULL',
        whereArgs: ids,
      );
      return ids.length;
    });
  }

  /// Undo for [deleteConversationsForPackage]. Restores exactly what that step
  /// took and nothing else: a conversation or a message the user had deleted
  /// earlier stays deleted (CAP-23, DEL-1).
  Future<void> undeleteConversationsForPackage(
    String package,
    DateTime deletedAt,
  ) async {
    final Database db = await _database;
    await db.transaction((Transaction txn) async {
      final int stamp = timeToDb(deletedAt);
      final List<Map<String, Object?>> targets = await txn.query(
        'conversations',
        columns: <String>['id'],
        where: 'package = ? AND deleted_at = ?',
        whereArgs: <Object?>[package, stamp],
      );
      if (targets.isEmpty) return;
      final List<String> ids = <String>[
        for (final Map<String, Object?> row in targets) row['id']! as String,
      ];
      final String placeholders = List<String>.filled(
        ids.length,
        '?',
      ).join(',');
      await txn.update(
        'conversations',
        <String, Object?>{'deleted_at': null},
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
      await txn.update(
        'messages',
        <String, Object?>{'deleted_at': null},
        where: 'conversation_id IN ($placeholders) AND deleted_at = ?',
        whereArgs: <Object?>[...ids, stamp],
      );
    });
  }

  // --- messages ---------------------------------------------------------

  /// How many messages a thread reads at once (INB-7).
  ///
  /// The read runs on every open **and** on every capture signal, which fires
  /// for a message from any app, so an unbounded one turns a long thread into
  /// a whole table materialised as objects several times a minute. Five hundred
  /// is well past what anyone scrolls in one sitting and small enough that the
  /// repeat costs nothing.
  ///
  /// A thread longer than this shows its newest five hundred messages and
  /// nothing older. INB-10 already forbids the screen from suggesting more can
  /// be loaded — scrolling to the top loads nothing and shows no spinner — and
  /// the notice above the thread still names the real date its history begins,
  /// because that date comes from [firstCaptureSessionStart] and
  /// [oldestMessageAt] rather than from whatever this read returned.
  static const int threadWindow = 500;

  /// A thread, oldest first (INB-7). The tie-break order matches the dedup
  /// index so the read is covered by it.
  ///
  /// [limit] keeps the newest [limit] messages and drops what is older, still
  /// oldest-first: the newest end is the end the thread opens on, and INB-7's
  /// order read backwards is the same order, so the window is a suffix of the
  /// thread rather than an independently chosen set.
  Future<List<Message>> messages(String conversationId, {int? limit}) async {
    final Database db = await _database;
    if (limit == null) {
      final List<Map<String, Object?>> rows = await db.query(
        'messages',
        where: 'conversation_id = ? AND deleted_at IS NULL',
        whereArgs: <Object?>[conversationId],
        orderBy: 'sent_at ASC, created_at ASC, history_index ASC, id ASC',
      );
      return rows.map(Message.fromMap).toList();
    }
    final List<Map<String, Object?>> rows = await db.query(
      'messages',
      where: 'conversation_id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[conversationId],
      orderBy: 'sent_at DESC, created_at DESC, history_index DESC, id DESC',
      limit: limit,
    );
    return rows.reversed.map(Message.fromMap).toList();
  }

  /// The arrival time of the oldest message a thread still holds, or null where
  /// it holds none (DEL-1).
  ///
  /// One row off `idx_messages_content`, so INB-10's notice can name the real
  /// beginning of a thread that [messages] only read the newest window of.
  Future<DateTime?> oldestMessageAt(String conversationId) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'messages',
      columns: <String>['sent_at'],
      where: 'conversation_id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[conversationId],
      orderBy: 'sent_at ASC, created_at ASC, history_index ASC, id ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : timeFromDb(rows.first['sent_at']);
  }

  /// The newest message a thread holds: INB-7's order, read from the other end.
  ///
  /// The four keys are INB-7's exactly, reversed — arrival time, then the
  /// arrival order of the notification that carried it, then its position in
  /// that notification's history, then `id`. Reusing that one order is what
  /// makes this row *the last row of the thread* rather than an independently
  /// chosen "newest": a burst puts five messages on one instant, and two reads
  /// that disagreed on which of them is last would draw a preview that does not
  /// match the bottom of the thread the user then opens.
  ///
  /// Soft-deleted rows are excluded, so deleting the newest message moves the
  /// preview back to the one before it rather than leaving a deleted line on
  /// screen (DEL-1).
  Future<Message?> newestMessage(String conversationId) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'messages',
      where: 'conversation_id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[conversationId],
      orderBy: 'sent_at DESC, created_at DESC, history_index DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Message.fromMap(rows.first);
  }

  /// [newestMessage] for a whole list, keyed by conversation id (INB-1).
  ///
  /// One query for the common case instead of one per row. It joins on
  /// `conversations.last_message_at`, which INB-4 defines as the arrival time
  /// of the newest message, so the join lands on the handful of rows tied at
  /// that instant and the tie is then broken in Dart by INB-7's remaining keys.
  ///
  /// `last_message_at` only ever moves forward (see [upsertConversation]), so
  /// it can sit *past* every message the thread still holds — the newest one
  /// was deleted, or an outbound message that has not confirmed yet bumped it
  /// (INB-9). Those conversations fall through to a single [newestMessage] each
  /// rather than being reported as empty, because a row with no preview at all
  /// is what a user reads as lost data.
  ///
  /// No window function and no row-value syntax: `minSdk` is 24, and the SQLite
  /// that ships with Android 7 has neither.
  ///
  /// **Bounded on both sides.** The join asks only about the conversations it
  /// was handed — without that predicate it was a scan of the whole `messages`
  /// table joined to the whole `conversations` table on every read, including
  /// every read behind a chip filter that had narrowed the list to one app. The
  /// ids go in [_sqlVariableChunk] at a time, because a parameter list is not a
  /// place to find out what the device's `SQLITE_MAX_VARIABLE_NUMBER` is.
  ///
  /// The fallback is capped at [newestMessageFallbackLimit] queries for the
  /// same reason. It fires only for a conversation whose `last_message_at` sits
  /// past every message it still holds, which is rare; a database where it is
  /// not would otherwise turn one list read into one query per row. Past the
  /// cap a row simply has no preview, which INB-1 already draws — the row keeps
  /// its title, its time and its unread count.
  Future<Map<String, Message>> newestMessages(
    List<Conversation> conversations,
  ) async {
    if (conversations.isEmpty) return const <String, Message>{};
    final Database db = await _database;
    final List<String> wanted = <String>[
      for (final Conversation c in conversations) c.id,
    ];
    final Map<String, Message> newest = <String, Message>{};
    for (final List<String> chunk in _chunked(wanted)) {
      final String placeholders = List<String>.filled(
        chunk.length,
        '?',
      ).join(',');
      final List<Map<String, Object?>> rows = await db.rawQuery('''
      SELECT m.* FROM messages m
      JOIN conversations c
        ON c.id = m.conversation_id AND m.sent_at = c.last_message_at
      WHERE c.deleted_at IS NULL AND m.deleted_at IS NULL
        AND m.conversation_id IN ($placeholders)
      ORDER BY m.conversation_id ASC, m.created_at ASC, m.history_index ASC,
               m.id ASC
    ''', chunk);
      for (final Map<String, Object?> row in rows) {
        // Ascending order, so the last row written for a conversation is the
        // one INB-7 puts at the bottom of the thread.
        newest[row['conversation_id']! as String] = Message.fromMap(row);
      }
    }
    int fallbacks = 0;
    for (final Conversation c in conversations) {
      if (newest.containsKey(c.id)) continue;
      if (++fallbacks > newestMessageFallbackLimit) break;
      final Message? fallback = await newestMessage(c.id);
      if (fallback != null) newest[c.id] = fallback;
    }
    return newest;
  }

  /// How many ids go into one `IN (...)` list.
  ///
  /// SQLite's `SQLITE_MAX_VARIABLE_NUMBER` defaults to 999 on the builds that
  /// ship with the older Android versions `minSdk` 24 reaches, and a read that
  /// exceeded it would throw rather than return fewer rows.
  static const int _sqlVariableChunk = 400;

  /// The most conversations one list read will fall back to a single-row query
  /// for. See [newestMessages].
  static const int newestMessageFallbackLimit = 200;

  static Iterable<List<String>> _chunked(List<String> values) sync* {
    for (int i = 0; i < values.length; i += _sqlVariableChunk) {
      yield values.sublist(
        i,
        i + _sqlVariableChunk > values.length
            ? values.length
            : i + _sqlVariableChunk,
      );
    }
  }

  /// How far back the alignment reads, in rows, for one notification key.
  ///
  /// `Notification.MessagingStyle` retains 25 entries and drops the oldest past
  /// that (`NotificationProjection.MAX_HISTORY`), so an incoming history is
  /// never longer than 25 and the overlap the alignment is looking for — a
  /// suffix of what is stored that is also a prefix of what arrived — can never
  /// be longer than 25 either. Twenty-five would therefore be enough for a queue
  /// drained in order.
  ///
  /// It is fifty because the queue is not always drained in order: the listener
  /// appends while the app is dead and the app applies what it finds, so an
  /// older post of a key can reach this method after a newer one and leave a
  /// whole history's worth of rows sitting past the overlap. One extra history
  /// is the amount of room that costs, and it is a constant-size read either
  /// way. Larger buys nothing — the overlap cannot start further back than one
  /// history — and would only spend the query on rows no alignment can use.
  static const int alignmentTailLimit = 50;

  /// Stores one notification's messages, writing only the ones CAP-5 says are
  /// not already stored.
  ///
  /// Takes the whole history at once because **a notification's message history
  /// is an ordered list, and identity is a question about the list**. When a
  /// notification posts again under a key we have seen, what arrives is the
  /// history we saw before with entries possibly dropped from the front and
  /// entries possibly appended to the back — a window over the same
  /// conversation. So the incoming history is aligned against what is already
  /// stored under that key, the way a diff aligns two files: entries that align
  /// are the same messages whatever their index or their timestamp now says,
  /// and entries left over at the end are new.
  ///
  /// That is the fourth correction of CAP-5, and it exists because the three
  /// before it all asked the wrong question. Each matched an entry against a
  /// *tuple of fields* — content and time, or key and position — and a device
  /// moved whichever field the current fix trusted:
  ///
  ///  * the window slid **and** the entry's clock moved in one post, so the
  ///    content shape missed (the time moved) and the position shape missed
  ///    (the index moved), and the owner's reply was stored twice;
  ///  * the moved entry was still the **newest** line of its history, which is
  ///    exactly where the position shape was forbidden to look — and on a real
  ///    phone, with no SMS loopback echo pushing the owner's line down, that is
  ///    the ordinary case rather than the rare one.
  ///
  /// Neither position nor time is matched on here. What is matched on is the
  /// sender, the content hash and the order, which is what a window carries
  /// unchanged; see [_alignAgainstStoredHistory] for the sender, the bound and
  /// the one piece of corroboration the alignment does ask of the clock.
  ///
  /// The passes, in order, and the boundary between them is where the next
  /// defect will live so it is stated rather than implied:
  ///
  ///  1. **Messages with no time of their own** — a hidden one (CAP-8), a raw
  ///     one (CAP-21), an attachment or a text line whose entry carried no
  ///     readable time. These are not aligned. Their identity is their
  ///     notification key and their position, because they have no content to
  ///     align on at all, and that is CAP-8's own rule with its own device
  ///     evidence behind it. See [_claimStoredRow].
  ///  2. **Alignment**, over the entries that carried their own time, against
  ///     the stored tail for this conversation and this notification key. This
  ///     is the whole of the within-a-key rule.
  ///  3. **The cross-key content match** CAP-5 has always had, over whatever
  ///     the alignment left: conversation, `sent_at`, sender and content hash,
  ///     at any position and under any key. Alignment covers a notification
  ///     posting again under its own key; this covers an app that posts one
  ///     notification per message under distinct keys — Google Messages does
  ///     this for incoming messages — and a reconnection re-read that hands the
  ///     same message back under a new key (CAP-13). It also catches an *old*
  ///     post of this same key redelivered after a newer one, which the
  ///     alignment cannot see because the overlap it is looking for is not at
  ///     the end of the stored list any more.
  ///
  /// No pass excludes soft-deleted rows, deliberately: a message the user
  /// deleted must not be captured again by a re-post or a reconnection re-read,
  /// and must never reappear in the inbox (DEL-1, CAP-5).
  ///
  /// Two identical texts from one sender at one instant inside one history are
  /// two different messages, and only the caller applying that one event knows
  /// it — which is why a row is claimed once and no second entry may take it.
  ///
  /// Returns one result per message, in order: whether a row was written, and
  /// the id of the row that message is now represented by. That id always names
  /// a row that exists.
  Future<List<({bool wrote, String id})>> insertMessagesIfNew(
    List<Message> messages,
  ) async {
    final Set<String> claimed = <String>{};
    final List<({bool wrote, String id})?> results =
        List<({bool wrote, String id})?>.filled(messages.length, null);

    // Which entry is the newest line in this history. Only a message with no
    // content of its own needs it, and only to keep from losing one; see
    // [_claimStoredRow].
    int newestIndex = -1;
    for (final Message message in messages) {
      if (message.historyIndex > newestIndex) {
        newestIndex = message.historyIndex;
      }
    }

    // Pass 1: the messages that carry nothing to align on, matched by key and
    // position as CAP-8 says. Disjoint from everything below — the lookup is
    // constrained to `time_source = 'post'` rows and the alignment to `entry`
    // ones — so neither can claim a row the other needs.
    for (int i = 0; i < messages.length; i++) {
      if (messages[i].timeSource != TimeSource.post) continue;
      final String? id = await _claimStoredRow(
        messages[i],
        claimed,
        atHistoryIndex: messages[i].historyIndex,
        newestInHistory: messages[i].historyIndex == newestIndex,
      );
      if (id != null) {
        claimed.add(id);
        results[i] = (wrote: false, id: id);
      }
    }

    // Pass 2: the alignment.
    await _alignAgainstStoredHistory(messages, results, claimed);

    // Pass 3: CAP-5's cross-key content match, over what the alignment left. In
    // entry order, so the oldest entry takes the oldest row and a window never
    // crosses two over.
    for (int i = 0; i < messages.length; i++) {
      if (results[i] != null) continue;
      if (messages[i].timeSource == TimeSource.post) continue;
      final String? id = await _claimStoredRow(messages[i], claimed);
      if (id != null) {
        claimed.add(id);
        results[i] = (wrote: false, id: id);
      }
    }
    // Whatever is left is new.
    for (int i = 0; i < messages.length; i++) {
      if (results[i] != null) continue;
      await _insertMessage(messages[i]);
      claimed.add(messages[i].id);
      results[i] = (wrote: true, id: messages[i].id);
    }
    return results.cast<({bool wrote, String id})>();
  }

  /// CAP-5's alignment: the incoming history against the stored one, as two
  /// sequences.
  ///
  /// The model is a window. Between two posts of one notification key, entries
  /// can fall off the front and entries can be appended to the back, and
  /// nothing else happens to the ones in between — their index shifts and, on
  /// the app this product is measured against, their own `time` can shift too,
  /// but they are the same messages in the same order. So the alignment looks
  /// for the longest **suffix of what is stored that is also a prefix of what
  /// arrived**, and calls everything past it new.
  ///
  /// What a pair is compared on is what a window carries unchanged:
  ///
  ///  * **The sender**, and `direction` is how the absent one is read.
  ///    `MessagingStyle` marks the phone owner's own line by writing no sender
  ///    key at all, while redaction *empties* the key — two different things
  ///    that both reach the `sender` column as `''` (CAP-8, INB-9). `direction`
  ///    is the column that already tells them apart: the owner's line is
  ///    `outbound`, an emptied one is `unknown`. Comparing it is what stops the
  ///    owner's "ok" aligning with a redacted line that happens to sit beside
  ///    it.
  ///  * **The content hash**, which is the text where there is text and the
  ///    attachment's type code where there is not (CAP-9).
  ///
  /// Not the index. Not the time.
  ///
  /// **One thing is asked of the time, and it is corroboration, not identity:
  /// an alignment is accepted only if at least one of its pairs still agrees on
  /// `sent_at` exactly.** Without that, an alignment cannot be told from a
  /// fresh window carrying the same words. A contact who sends "ok" and then
  /// "ok" again to a thread whose history holds one entry hands us two
  /// genuinely different messages, and an unanchored alignment would fold them
  /// into one and lose the second — the failure CAP-5's first correction
  /// exists to stop. A re-post, by contrast, re-presents lines we have already
  /// seen, and an app moves the clock on the line it has just refined, not on
  /// the ones above it: on the device every post that moved a clock still
  /// carried five other entries whose times had not moved (drill, 21 September
  /// 2026). Where there is no such anchor the alignment declines, the entry
  /// falls to the content match and then to a second row, and CAP-5 takes the
  /// duplicate — a line the user can delete — over the loss of a message they
  /// were sent.
  ///
  /// Soft-deleted rows are part of the stored history here, exactly as they are
  /// for every other pass: a message the user deleted must not come back on the
  /// next re-post (DEL-1).
  Future<void> _alignAgainstStoredHistory(
    List<Message> messages,
    List<({bool wrote, String id})?> results,
    Set<String> claimed,
  ) async {
    // Every entry of one event shares one conversation and one notification
    // key, so the first unresolved one names both.
    final List<int> incoming = <int>[
      for (int i = 0; i < messages.length; i++)
        if (results[i] == null && messages[i].timeSource == TimeSource.entry) i,
    ];
    if (incoming.isEmpty) return;

    final List<_StoredEntry> stored = await _storedHistoryTail(
      conversationId: messages[incoming.first].conversationId,
      notificationKey: messages[incoming.first].notificationKey,
    );
    if (stored.isEmpty) return;

    int overlap = 0;
    for (
      int k = incoming.length < stored.length ? incoming.length : stored.length;
      k >= 1;
      k--
    ) {
      bool aligns = true;
      bool anchored = false;
      for (int j = 0; j < k; j++) {
        final _StoredEntry row = stored[stored.length - k + j];
        final Message entry = messages[incoming[j]];
        if (claimed.contains(row.id) ||
            row.sender != entry.sender ||
            row.textHash != entry.dedupHash ||
            row.direction != entry.direction.name) {
          aligns = false;
          break;
        }
        if (row.sentAt == timeToDb(entry.sentAt)) anchored = true;
      }
      if (aligns && anchored) {
        overlap = k;
        break;
      }
    }

    for (int j = 0; j < overlap; j++) {
      final String id = stored[stored.length - overlap + j].id;
      claimed.add(id);
      results[incoming[j]] = (wrote: false, id: id);
    }
  }

  /// The end of the message history already stored under one notification key,
  /// oldest first — what the incoming history is aligned against.
  ///
  /// Ordered by `created_at` first, which is the order the posts arrived in and
  /// so the order the history grew in, then by `sent_at` and `history_index`,
  /// which is what separates the entries of one post: a burst puts five of them
  /// on one instant and only the position tells them apart. Bounded by
  /// [alignmentTailLimit], argued there.
  Future<List<_StoredEntry>> _storedHistoryTail({
    required String conversationId,
    required String notificationKey,
  }) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'messages',
      columns: <String>['id', 'sender', 'text_hash', 'direction', 'sent_at'],
      where:
          'conversation_id = ? AND notification_key = ? '
          "AND time_source = 'entry'",
      whereArgs: <Object?>[conversationId, notificationKey],
      // Newest first so the LIMIT takes the *tail*, then reversed below.
      orderBy: 'created_at DESC, sent_at DESC, history_index DESC, id DESC',
      limit: alignmentTailLimit,
    );
    return <_StoredEntry>[
      for (final Map<String, Object?> row in rows.reversed)
        (
          id: row['id']! as String,
          sender: row['sender']! as String,
          textHash: row['text_hash']! as String,
          direction: row['direction']! as String,
          sentAt: row['sent_at']! as int,
        ),
    ];
  }

  /// One message, for the callers that only ever have one — CAP-21's raw row,
  /// and a reconnection re-read.
  ///
  /// **Not aligned, and that is not an omission.** CAP-5's alignment is a
  /// statement about a message *history*, and a caller with one message has no
  /// history to make it about: a lone raw notification carries none at all
  /// (CAP-21), so its identity is the key and the position CAP-8 names. What is
  /// left here is that match, and then — for a message that did carry its own
  /// time — the cross-key content match. Anything that arrives as a history goes
  /// through [insertMessagesIfNew], history and all, because the alignment
  /// cannot be assembled one entry at a time.
  ///
  /// [alreadyMatched] holds rows the current event has already claimed.
  Future<({bool wrote, String id})> insertMessageIfNew(
    Message message, {
    Set<String> alreadyMatched = const <String>{},
  }) async {
    final String? atIndex = await _claimStoredRow(
      message,
      alreadyMatched,
      atHistoryIndex: message.historyIndex,
      // A history of one is its own newest line.
      newestInHistory: true,
    );
    if (atIndex != null) return (wrote: false, id: atIndex);
    if (message.timeSource == TimeSource.entry) {
      final String? anywhere = await _claimStoredRow(message, alreadyMatched);
      if (anywhere != null) return (wrote: false, id: anywhere);
    }
    await _insertMessage(message);
    return (wrote: true, id: message.id);
  }

  /// The id of a stored row that is this message and has not been claimed yet,
  /// or null. With [atHistoryIndex] the row must also sit at that position.
  ///
  /// There are two identity shapes here, and `time_source` picks between them
  /// (CAP-5, corrected 21 September 2026).
  ///
  /// **A message that carried its own time** is matched on content wherever it
  /// turns up: conversation, `sent_at`, sender and the content hash, at any
  /// position and under any notification key. This is CAP-5's **cross-key**
  /// half and nothing more — one message arriving under two different
  /// notifications, which is what an app posting one notification per message
  /// does and what a reconnection re-read produces (CAP-13). It is not what
  /// recognises a notification posted again under its own key: the entry's own
  /// clock was observed moving between two posts of one notification, so this
  /// match misses there by construction, and [_alignAgainstStoredHistory] is
  /// what covers it.
  ///
  /// **A message whose `sent_at` is the notification's `postTime`** — a hidden
  /// one (CAP-8), a raw one (CAP-21), an attachment or a text line whose entry
  /// carried no readable time — is matched with `sent_at` left out entirely,
  /// because Android sets `postTime` on every enqueue including an in-place
  /// update of a notification already in the shade. A time that moves cannot be
  /// part of identity: with it in the match, the stored row was never found and
  /// every re-post filed the same message again, forever. What is matched
  /// instead is what CAP-8 already names — the notification key and the
  /// position in the history — plus whatever content the message does carry, so
  /// that an app re-posting "2 new notifications" is one message and an app
  /// posting "3 new notifications" over it is two.
  ///
  /// [newestInHistory] is the one exception, and it exists to keep from losing
  /// a message rather than to be tidy. A hidden message carries no sender, no
  /// text and no time it can trust, so two of them at one position under one
  /// key are indistinguishable — and Google Messages, the one real app the
  /// spike measured, posts each new message under one reused key with a history
  /// of one entry at index 0. Matched on key and position alone, the second
  /// message a contact sends a redacted thread would be read as a re-post of
  /// the first and discarded, which is precisely the failure CAP-5's correction
  /// exists to stop. So at the newest position of a history, a content-free
  /// message claims a stored row only when the phone posted it at the same
  /// moment — which is what a reconnection re-read delivers (CAP-13: same
  /// notification, same `postTime`) and what a re-post does not. The residual
  /// is stated in CAP-8 rather than papered over: a redacted notification
  /// re-posted with nothing new in it leaves a second "message hidden" row, and
  /// that is the right way round, because the alternative loses real messages.
  Future<String?> _claimStoredRow(
    Message message,
    Set<String> claimed, {
    int? atHistoryIndex,
    bool newestInHistory = false,
  }) async {
    final Database db = await _database;
    // Every shape is constrained to rows written under the same `time_source`,
    // so a message with a time of its own can never claim a hidden or raw row
    // whose `sent_at` means something else entirely — and the alignment, which
    // reads `entry` rows only, can never be undercut by a match that reached
    // across (CAP-8, CAP-21).
    final List<String> where = <String>[
      'conversation_id = ?',
      'time_source = ?',
    ];
    final List<Object?> args = <Object?>[
      message.conversationId,
      message.timeSource.name,
    ];

    if (message.timeSource == TimeSource.post) {
      where.addAll(<String>[
        'notification_key = ?',
        'history_index = ?',
        'sender = ?',
        'text_hash = ?',
      ]);
      args.addAll(<Object?>[
        message.notificationKey,
        message.historyIndex,
        message.sender,
        message.dedupHash,
      ]);
      if (newestInHistory && message.kind == MessageKind.hidden) {
        where.add('sent_at = ?');
        args.add(timeToDb(message.sentAt));
      }
    } else {
      where.addAll(<String>['sent_at = ?', 'sender = ?', 'text_hash = ?']);
      args.addAll(<Object?>[
        timeToDb(message.sentAt),
        message.sender,
        message.dedupHash,
      ]);
      if (atHistoryIndex != null) {
        where.add('history_index = ?');
        args.add(atHistoryIndex);
      }
    }
    if (claimed.isNotEmpty) {
      where.add(
        'id NOT IN (${List<String>.filled(claimed.length, '?').join(',')})',
      );
      args.addAll(claimed);
    }

    final List<Map<String, Object?>> existing = await db.query(
      'messages',
      columns: <String>['id'],
      where: where.join(' AND '),
      whereArgs: args,
      // Oldest position first, then oldest arrival, so a sliding window matches
      // entries to rows in the order both were written and never crosses two of
      // them over.
      orderBy: 'history_index ASC, sent_at ASC, id ASC',
      limit: 1,
    );
    return existing.isEmpty ? null : existing.first['id']! as String;
  }

  /// Writes the row, and throws if the identity index rejects it.
  ///
  /// Loud on purpose. `ConflictAlgorithm.ignore` used to swallow that
  /// rejection, so a collision came back as `wrote: false` and the caller
  /// reported it as "already stored" — the exact shape of the defect CAP-5's
  /// correction exists to stop, a message the user was sent disappearing with
  /// nothing on screen and nothing in a log to say so. If the matching above
  /// ever misses a row again, the app has to fail where it can be found rather
  /// than quietly lose the message.
  ///
  /// **There is one index left that can reject anything, and it covers only the
  /// messages with no time of their own** (`idx_messages_post_identity`: a
  /// hidden message, a raw one, an attachment or a line whose entry carried no
  /// readable time). A message that carried its own time has no unique index at
  /// all any more, because CAP-5's alignment deliberately allows two rows of one
  /// conversation to agree on `sent_at`, sender, content and even
  /// `history_index` — a window that slides an entry down while a new entry with
  /// the same words takes the position it left is exactly that. An index that
  /// rejected the second write would not be a safety net; it would be the loss.
  /// So for those rows this method never throws, and what stands behind them is
  /// the alignment and the fixtures that pin it.
  ///
  /// **Loud only as far as its callers let it be**, and one of them does not.
  /// `lib/services/android_capture_service.dart` wraps the drain in a bare
  /// `on Object` with no log and no recorded fault, so a collision thrown here
  /// is swallowed there and the paragraph above stops being true at the
  /// boundary of this file. Nothing inside the repository can fix that: an
  /// exception is only as loud as the code that catches it. What this side can
  /// do it does — the row is not written, the caller is not told "already
  /// stored", and [MessageIdentityCollision.toString] names the conversation,
  /// the notification key and the position, so a fault that is recorded is
  /// enough to find the bug from. The service has to let this type through, or
  /// record it as a capture fault; until it does, the failure is quiet again.
  Future<void> _insertMessage(Message message) async {
    final Database db = await _database;
    try {
      await db.insert('messages', message.toMap());
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw MessageIdentityCollision(message, error);
      }
      rethrow;
    }
  }

  /// Unread inbound messages: those newer than the read marker (INB-5,
  /// CAP-22).
  ///
  /// Inbound and nothing else, which is the whole of INB-9's "counted in no
  /// unread badge": a message the notification's history did not say who wrote
  /// is [Direction.unknown] and is not counted here. Neither is an outbound
  /// one. A badge is the app claiming somebody is waiting on the user, and it
  /// never makes that claim on a direction it had to guess.
  Future<int> unreadCount(Conversation conversation) async {
    final Database db = await _database;
    final int? count = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM messages '
        'WHERE conversation_id = ? AND deleted_at IS NULL '
        'AND direction = ? AND sent_at > ?',
        <Object?>[
          conversation.id,
          Direction.inbound.name,
          conversation.readThroughAt == null
              ? 0
              : timeToDb(conversation.readThroughAt!),
        ],
      ),
    );
    return count ?? 0;
  }

  /// [unreadCount] for every conversation the list can show, keyed by
  /// conversation id (INB-5).
  ///
  /// One query rather than one per row, and the same three conditions as
  /// [unreadCount]: inbound only (INB-9 counts an undecided direction in no
  /// badge), soft-deleted messages excluded (DEL-1), and newer than
  /// `read_through_at` — which is the *arrival* time, so a hidden message is
  /// counted by the notification's `postTime` exactly as INB-4 sorts on it
  /// (CAP-8).
  ///
  /// A conversation with nothing unread is absent from the map rather than
  /// present with a zero; callers read it with a `?? 0`, and the 99+ cap is a
  /// display decision that belongs to the state layer, not to this read.
  ///
  /// `COALESCE(..., -1)` and not `0`: an instant of 0 is epoch, which is a
  /// value a read marker could legitimately hold, and comparing against 0 would
  /// then silently mean "nothing is unread".
  Future<Map<String, int>> unreadCounts({List<String>? packages}) async {
    final Database db = await _database;
    final bool filtered = packages != null && packages.isNotEmpty;
    final String clause = filtered
        ? 'AND c.package IN (${List<String>.filled(packages.length, '?').join(',')})'
        : '';
    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT m.conversation_id AS conversation_id, COUNT(*) AS unread
      FROM messages m
      JOIN conversations c ON c.id = m.conversation_id
      WHERE c.deleted_at IS NULL AND m.deleted_at IS NULL
        AND m.direction = ?
        AND m.sent_at > COALESCE(c.read_through_at, -1)
        $clause
      GROUP BY m.conversation_id
    ''',
      <Object?>[Direction.inbound.name, if (filtered) ...packages],
    );
    return <String, int>{
      for (final Map<String, Object?> row in rows)
        row['conversation_id']! as String: row['unread']! as int,
    };
  }

  /// What each source app has in the inbox right now: how many conversations
  /// the list can show from it, and the arrival time of its newest message.
  ///
  /// Two screens read this and neither can be built without it. INB-14's chip
  /// row is one chip per package with **at least one conversation the list can
  /// show**, ordered by that app's newest message; INB-21's included-apps list
  /// carries a conversation count on every row and orders its first group by
  /// the most recent captured message. Both are the same aggregate, so it is
  /// read once.
  ///
  /// Deleted conversations are excluded, which is what makes INB-6's Undo
  /// window behave: while a conversation sits inside it, it is out of the
  /// count and out of its app's newest-message time, exactly as it is out of
  /// the list. Whether a chip nevertheless stays on screen is INB-14's
  /// question, and it is answered in the state layer, where the selection
  /// lives.
  ///
  /// A package with nothing showable is absent from the map, not present with
  /// a zero: "has a conversation the list can show" is the chip row's whole
  /// membership test.
  Future<Map<String, PackageActivity>> conversationActivityByPackage() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.rawQuery('''
      SELECT package,
             COUNT(*) AS conversations,
             MAX(last_message_at) AS newest
      FROM conversations
      WHERE deleted_at IS NULL
      GROUP BY package
    ''');
    return <String, PackageActivity>{
      for (final Map<String, Object?> row in rows)
        row['package']! as String: (
          conversations: row['conversations']! as int,
          newestMessageAt: timeFromDb(row['newest']),
        ),
    };
  }

  // --- settings and sessions -------------------------------------------

  Future<String?> setting(String key) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    final Database db = await _database;
    await db.insert('settings', <String, Object?>{
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// When this install started being able to see anything (CAP-12). Written
  /// once and never moved: it is what makes "no history from before install" a
  /// fact the app holds rather than a sentence on a screen.
  Future<DateTime> installedAt(DateTime nowIfUnset) async {
    final String? stored = await setting('installed_at');
    if (stored != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        int.parse(stored),
        isUtc: true,
      );
    }
    await setSetting('installed_at', timeToDb(nowIfUnset).toString());
    return nowIfUnset;
  }

  /// [installedAt] without the write.
  ///
  /// INB-10's notice is a read on a screen, and a read that writes the date it
  /// is about would move the app's own history to whenever a thread was first
  /// opened. `main.dart` writes the key once per launch before any screen
  /// exists; everything after that asks this.
  Future<DateTime?> installedAtOrNull() async {
    final String? stored = await setting('installed_at');
    if (stored == null) return null;
    final int? parsed = int.tryParse(stored);
    return parsed == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(parsed, isUtc: true);
  }

  /// The start of the earliest session in either table (CAP-12, INB-10).
  ///
  /// With no [package] this is the first time the listener ever bound. With
  /// one it is the start of the earliest `app_capture_sessions` row for that
  /// package — the first time its switch was turned on. Null in either case
  /// means there has never been such a session, which is not the same as one
  /// that started at epoch and is why this is nullable rather than defaulted.
  ///
  /// A shipped app captured by default (CAP-1) has no `app_capture_sessions`
  /// row at all, because only the switch moving writes one, so null here means
  /// "no app-level start to take into account" and INB-10 then falls back to
  /// the other two dates.
  Future<DateTime?> firstCaptureSessionStart({String? package}) async {
    final Database db = await _database;
    final int? earliest = Sqflite.firstIntValue(
      await db.rawQuery(
        package == null
            ? 'SELECT MIN(started_at) FROM capture_sessions '
                  'WHERE deleted_at IS NULL'
            : 'SELECT MIN(started_at) FROM app_capture_sessions '
                  'WHERE package = ? AND deleted_at IS NULL',
        <Object?>[?package],
      ),
    );
    return earliest == null ? null : timeFromDb(earliest);
  }

  /// The shortest absence the app will report (INB-10).
  ///
  /// A rebind at boot closes one session and opens another a few seconds
  /// later, and CAP-12 is explicit that a window interrupted while access
  /// stayed on is one window rather than two. Reporting those seconds as an
  /// absence would put a gap notice on a thread nobody lost anything from,
  /// which trains the user to ignore the one notice that matters.
  static const Duration minimumReportedGap = Duration(seconds: 60);

  /// Every stretch the app knows it was not capturing, newest first (CAP-12,
  /// INB-10).
  ///
  /// Reads both tables where [package] is given — a gap in either one is an
  /// absence in that thread, because access being off and the app's own row
  /// being off take the same messages away — and only `capture_sessions`
  /// otherwise.
  ///
  /// A gap is the gap *between* sessions, plus the one still running where the
  /// newest session has closed: that one ends at [now], which also bounds every
  /// other end, so a session row stamped in the future cannot produce a gap
  /// that has not happened. Sessions are walked with a running high-water mark
  /// rather than pairwise, so an overlapping pair — which CAP-12's one-window
  /// guard should make impossible and a drained-out-of-order queue can still
  /// produce — never invents a gap inside a stretch another row covers. A
  /// session still open covers everything from its start onwards and ends the
  /// walk.
  ///
  /// Nothing shorter than [minimumReportedGap] is returned, argued there.
  Future<List<CaptureGap>> captureGaps({
    String? package,
    required DateTime now,
  }) async {
    final List<CaptureGap> gaps = <CaptureGap>[
      ...await _gapsIn(
        table: 'capture_sessions',
        package: null,
        scope: CaptureGapScope.device,
        now: now,
      ),
      if (package != null)
        ...await _gapsIn(
          table: 'app_capture_sessions',
          package: package,
          scope: CaptureGapScope.app,
          now: now,
        ),
    ];
    gaps.sort((CaptureGap a, CaptureGap b) {
      final int byStart = b.from.compareTo(a.from);
      return byStart != 0 ? byStart : b.to.compareTo(a.to);
    });
    return gaps;
  }

  Future<List<CaptureGap>> _gapsIn({
    required String table,
    required String? package,
    required CaptureGapScope scope,
    required DateTime now,
  }) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      table,
      columns: <String>['started_at', 'ended_at'],
      where: package == null
          ? 'deleted_at IS NULL'
          : 'package = ? AND deleted_at IS NULL',
      whereArgs: package == null ? null : <Object?>[package],
      orderBy: 'started_at ASC',
    );
    if (rows.isEmpty) return const <CaptureGap>[];

    final List<CaptureGap> gaps = <CaptureGap>[];
    DateTime? coveredUntil;
    bool stillOpen = false;
    for (final Map<String, Object?> row in rows) {
      final DateTime startedAt = timeFromDb(row['started_at']);
      final DateTime? endedAt = timeFromDbOrNull(row['ended_at']);
      if (coveredUntil != null && startedAt.isAfter(coveredUntil)) {
        gaps.add(CaptureGap(from: coveredUntil, to: startedAt, scope: scope));
      }
      if (endedAt == null) {
        stillOpen = true;
        break;
      }
      if (coveredUntil == null || endedAt.isAfter(coveredUntil)) {
        coveredUntil = endedAt;
      }
    }
    if (!stillOpen && coveredUntil != null && now.isAfter(coveredUntil)) {
      gaps.add(CaptureGap(from: coveredUntil, to: now, scope: scope));
    }
    return <CaptureGap>[
      for (final CaptureGap gap in gaps)
        if (gap.duration > minimumReportedGap) gap,
    ];
  }

  /// Opens a capture session (CAP-12): the listener bound.
  ///
  /// **Never a second one while one is open**, and that guard is the whole of
  /// this method. A device drill bound the listener thirty times in one sitting
  /// — a revoke and a grant, `am start -S`, a force-stop, a reboot — and every
  /// bind inserted a row, so `capture_sessions` held thirty rows with thirty
  /// null `ended_at` values and CAP-12 could not answer the one question it
  /// exists for (drill, 21 September 2026). Two rows open at once is not a
  /// longer record of capture being on; it is the same window counted twice.
  ///
  /// The existing row is kept rather than replaced, because it starts earlier
  /// and the app has nothing with which to date the gap between the two binds.
  /// What that leaves over is stated where it can be acted on: the one gap the
  /// app *can* date — access taken away — is closed by
  /// [closeOpenCaptureSessionsAtLastEvidence], and CAP-12 carries the residual.
  ///
  /// Returns whether a row was opened.
  Future<bool> openCaptureSession(DateTime at) async {
    final Database db = await _database;
    final List<Map<String, Object?>> open = await db.query(
      'capture_sessions',
      columns: <String>['id'],
      where: 'ended_at IS NULL',
      limit: 1,
    );
    if (open.isNotEmpty) return false;
    await db.insert('capture_sessions', <String, Object?>{
      'id': newId(),
      'started_at': timeToDb(at),
      'ended_at': null,
      'created_at': timeToDb(at),
      'updated_at': timeToDb(at),
      'deleted_at': null,
    });
    return true;
  }

  /// Closes any open capture session: the listener went away, and said so.
  Future<void> closeCaptureSession(DateTime at) async {
    final Database db = await _database;
    await db.update('capture_sessions', <String, Object?>{
      'ended_at': timeToDb(at),
      'updated_at': timeToDb(at),
    }, where: 'ended_at IS NULL');
  }

  /// Closes an open session the app has only just found out it cannot stand
  /// behind: notification access is off, and nothing ever told us when it went
  /// away (CAP-12, PERM-8).
  ///
  /// `onListenerDisconnected` does not fire for a revoke at API 37 — verified
  /// with Dart dead, so the queue could not have swallowed it; the process is
  /// simply torn down (drill, 21 September 2026). So [closeCaptureSession]'s
  /// caller never runs, the row stays open for ever, and CAP-12 would tell the
  /// user capture was continuously on across a window in which it was off.
  /// That is the one direction the rule may not be wrong in.
  ///
  /// **Which instant closes it is a choice, and this is the choice: the newest
  /// `sent_at` of any message captured inside the session, and the session's
  /// own `started_at` when it captured nothing.** Every instant the app then
  /// claims capture was on has a stored message standing behind it — a
  /// notification the listener really did hand over at that time — and it
  /// claims nothing past the last such proof. The alternatives were both worse
  /// in a way worth writing down rather than discovering: `now` is the bug
  /// itself, since the whole revoked window sits between the last event and
  /// this launch; `started_at` never over-claims either but throws away
  /// coverage the app can prove, and a session that captured a week of messages
  /// would be recorded as zero seconds long. CAP-12's own wording is what this
  /// produces — capture has been off *since at least* a stated time.
  ///
  /// Deleted messages count as evidence: the user deleting a message says
  /// nothing about whether the listener was alive when it arrived (DEL-1).
  ///
  /// [now] only bounds the search, so a message whose app stamped it in the
  /// future cannot push the close past this launch. Returns the instant used,
  /// or null when no session was open.
  Future<DateTime?> closeOpenCaptureSessionsAtLastEvidence(DateTime now) async {
    final Database db = await _database;
    final List<Map<String, Object?>> open = await db.query(
      'capture_sessions',
      columns: <String>['id', 'started_at'],
      where: 'ended_at IS NULL',
      orderBy: 'started_at ASC',
    );
    if (open.isEmpty) return null;

    DateTime? closedAt;
    for (final Map<String, Object?> row in open) {
      final DateTime startedAt = timeFromDb(row['started_at']);
      final int? evidence = Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT MAX(sent_at) FROM messages WHERE sent_at >= ? AND sent_at <= ?',
          <Object?>[timeToDb(startedAt), timeToDb(now)],
        ),
      );
      final DateTime endedAt = evidence == null
          ? startedAt
          : timeFromDb(evidence);
      await db.update(
        'capture_sessions',
        <String, Object?>{
          'ended_at': timeToDb(endedAt),
          // The capture clock, which is ours and is not the instant being
          // claimed (REC-1). The two are different on purpose here: the row
          // says capture stopped at `ended_at` and that we noticed at `now`.
          'updated_at': timeToDb(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[row['id']],
      );
      closedAt = endedAt;
    }
    return closedAt;
  }

  // --- capture ----------------------------------------------------------

  /// The packages CAP-1 lets through, for handing down to the listener so it
  /// drops every other one before a row reaches the native queue.
  ///
  /// Read straight from the rows the user's switches wrote, never from a list
  /// held in memory: the switch moving is the whole of the change (INB-22).
  Future<List<String>> enabledPackages() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'apps',
      columns: <String>['package'],
      where: 'enabled = 1 AND deleted_at IS NULL',
      orderBy: 'package ASC',
    );
    return rows
        .map((Map<String, Object?> row) => row['package']! as String)
        .toList();
  }

  /// Finds the thread this notification belongs to, or opens one (CAP-3).
  ///
  /// The lookup includes deleted rows, so a notification for a conversation
  /// the user deleted revives that row instead of opening a second one for the
  /// same package and key (CAP-23). Only the conversation is revived: the
  /// messages deleted with it stay deleted, so nothing the user deleted
  /// returns.
  ///
  /// Returns the row and whether this call revived it.
  Future<({Conversation conversation, bool revived})> upsertConversation({
    required String package,
    required String conversationKey,
    required KeySource keySource,
    required String title,
    required bool isGroup,
    required DateTime lastMessageAt,
    required DateTime at,
    String? shortcutId,
    String? conversationTitle,
    String? tag,
  }) async {
    // A live row wins over a deleted one carrying the same identity. Only the
    // partial index keeps two live rows apart, so reviving a deleted twin
    // while a live row exists would put two rows on one identity and the write
    // would be rejected (CAP-3, CAP-23).
    final Conversation? existing =
        await conversationByKey(package, conversationKey) ??
        await conversationByKey(package, conversationKey, includeDeleted: true);
    if (existing == null) {
      final Conversation created = Conversation(
        id: newId(),
        package: package,
        conversationKey: conversationKey,
        keySource: keySource,
        title: title,
        isGroup: isGroup,
        lastMessageAt: lastMessageAt,
        // The capture time, never a time the notification supplied: the
        // difference between the two is what CAP-5 matches on (REC-1).
        createdAt: at,
        updatedAt: at,
        shortcutId: shortcutId,
        conversationTitle: conversationTitle,
        tag: tag,
      );
      await insertConversation(created);
      return (conversation: created, revived: false);
    }

    final Conversation updated = existing.copyWith(
      // An empty title never overwrites a name we already hold: redaction
      // empties the title field while leaving a perfectly good key, so one
      // hidden notification would otherwise blank a named thread (CAP-8,
      // INB-2).
      title: title.isEmpty ? null : title,
      // Sticky, for the same reason: a redacted notification reports
      // isGroupConversation false whatever the thread is, and flipping the
      // flag would drop the sender prefix from every preview (INB-1, CAP-8).
      isGroup: existing.isGroup || isGroup,
      // Forward only. A queue drained out of order, or a re-read of an old
      // notification (CAP-13), must not pull a thread back down the list
      // (INB-4).
      lastMessageAt: existing.lastMessageAt.isAfter(lastMessageAt)
          ? existing.lastMessageAt
          : lastMessageAt,
      // Each candidate keeps the last non-empty value seen, because the field
      // that changes when an app changes its keying is the one that can no
      // longer be matched on (CAP-3).
      shortcutId: shortcutId ?? existing.shortcutId,
      conversationTitle: conversationTitle ?? existing.conversationTitle,
      tag: tag ?? existing.tag,
      updatedAt: at,
      deletedAt: null,
    );
    await updateConversation(updated);
    return (conversation: updated, revived: existing.isDeleted);
  }

  /// Marks a conversation read up to [through] (CAP-22).
  ///
  /// The guard in the WHERE clause is the rule: `read_through_at` only ever
  /// moves forward, so a late `APP_CANCEL` on an older notification changes
  /// nothing rather than un-reading newer messages (INB-5). [at] is the
  /// capture time and [through] is a message's own arrival time; they are
  /// different instants and the row keeps both apart (REC-1).
  ///
  /// Returns whether the marker actually moved.
  Future<bool> markReadThrough({
    required String conversationId,
    required DateTime through,
    required DateTime at,
  }) async {
    final Database db = await _database;
    final int rows = await db.update(
      'conversations',
      <String, Object?>{
        'read_through_at': timeToDb(through),
        'updated_at': timeToDb(at),
      },
      where:
          'id = ? AND deleted_at IS NULL '
          'AND (read_through_at IS NULL OR read_through_at < ?)',
      whereArgs: <Object?>[conversationId, timeToDb(through)],
    );
    return rows > 0;
  }

  /// The newest message stored from one notification, and the thread it is in.
  ///
  /// This is how a removal finds what to mark read (CAP-22): the removal event
  /// itself arrives with an empty message history, so the answer can only come
  /// from what was stored when the notification was posted. Deleted rows are
  /// excluded, so a thread the user emptied has nothing to mark (DEL-1).
  Future<({String conversationId, DateTime sentAt})?>
  newestMessageForNotification(String notificationKey) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'messages',
      columns: <String>['conversation_id', 'sent_at'],
      where: 'notification_key = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[notificationKey],
      orderBy: 'sent_at DESC, history_index DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (
      conversationId: rows.first['conversation_id']! as String,
      sentAt: timeFromDb(rows.first['sent_at']),
    );
  }
}
