import 'package:sqflite/sqflite.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../models/record.dart';
import '../models/source_app.dart';
import 'db_helper.dart';

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

  /// Turning an app on or off (INB-22). Leaves everything already captured in
  /// the inbox (CAP-1).
  Future<void> setAppEnabled(
    String package, {
    required bool enabled,
    required DateTime at,
  }) async {
    final Database db = await _database;
    final SourceApp? app = await appByPackage(package);
    if (app == null) return;
    await db.update(
      'apps',
      app.copyWith(enabled: enabled, updatedAt: at).toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[app.id],
    );
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

  // --- messages ---------------------------------------------------------

  /// A thread, oldest first (INB-7). The tie-break order matches the dedup
  /// index so the read is covered by it.
  Future<List<Message>> messages(String conversationId) async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'messages',
      where: 'conversation_id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[conversationId],
      orderBy: 'sent_at ASC, created_at ASC, history_index ASC, id ASC',
    );
    return rows.map(Message.fromMap).toList();
  }

  /// Stores a message unless it is already stored (CAP-5).
  ///
  /// The dedup lookup deliberately does **not** exclude soft-deleted rows: a
  /// message the user deleted must not be captured again by a re-post or a
  /// reconnection re-read, and must never reappear in the inbox.
  ///
  /// Returns true when a row was written.
  Future<bool> insertMessageIfNew(Message message) async {
    final Database db = await _database;
    final int inserted = await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return inserted != 0;
  }

  /// Unread inbound messages: those newer than the read marker (INB-5,
  /// CAP-22).
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

  /// Opens a capture session (CAP-12): the listener bound.
  Future<void> openCaptureSession(DateTime at) async {
    final Database db = await _database;
    await db.insert('capture_sessions', <String, Object?>{
      'id': newId(),
      'started_at': timeToDb(at),
      'ended_at': null,
      'created_at': timeToDb(at),
      'updated_at': timeToDb(at),
      'deleted_at': null,
    });
  }

  /// Closes any open capture session: the listener went away.
  Future<void> closeCaptureSession(DateTime at) async {
    final Database db = await _database;
    await db.update('capture_sessions', <String, Object?>{
      'ended_at': timeToDb(at),
      'updated_at': timeToDb(at),
    }, where: 'ended_at IS NULL');
  }
}
