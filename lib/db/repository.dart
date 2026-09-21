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
