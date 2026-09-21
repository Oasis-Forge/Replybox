import 'package:sqflite/sqflite.dart';

import '../models/record.dart';

/// One ordered step in the schema's history.
///
/// A step that has been merged is never edited — not its SQL, not its
/// position. A device that already ran step 3 will never run it again, so
/// changing it silently gives two users different databases with the same
/// version number. Fix a mistake by appending a step that corrects it.
typedef MigrationStep = Future<void> Function(Transaction txn);

/// Every step, in order. The database's version is the length of this list, so
/// appending a step is the only thing needed to ship a schema change.
const List<MigrationStep> migrationSteps = <MigrationStep>[
  _step1CaptureTables,
  _step2MessageIdentityIsContent,
];

/// The schema version a fresh install lands on.
int get schemaVersion => migrationSteps.length;

/// Step 1: the tables capture writes and the inbox reads.
///
/// Everything here is required by a rule that already exists; nothing is
/// speculative. Columns for areas that have not been specced yet (done,
/// snoozed, muted) are deliberately absent — there are no users, so a later
/// migration costs nothing, and guessing a column for an unwritten rule costs
/// a wrong one.
Future<void> _step1CaptureTables(Transaction txn) async {
  // Apps the listener has seen. A row with enabled = 0 is one it saw and
  // dropped, which is what makes the chooser's "other apps" list exist
  // (INB-20, CAP-1).
  await txn.execute('''
    CREATE TABLE apps (
      $recordColumns,
      package      TEXT    NOT NULL,
      label        TEXT    NOT NULL,
      enabled      INTEGER NOT NULL DEFAULT 0,
      last_seen_at INTEGER NOT NULL
    )
  ''');
  await txn.execute('''
    CREATE UNIQUE INDEX idx_apps_package
      ON apps (package) WHERE deleted_at IS NULL
  ''');

  // Conversations. The key candidates sit beside the resolved key so an app
  // that changes its keying can be migrated rather than splitting every
  // thread (CAP-3); one column would not be enough, because the field that
  // changes is the one that can no longer be matched on.
  await txn.execute('''
    CREATE TABLE conversations (
      $recordColumns,
      package            TEXT    NOT NULL,
      conversation_key   TEXT    NOT NULL,
      key_source         TEXT    NOT NULL,
      shortcut_id        TEXT,
      conversation_title TEXT,
      tag                TEXT,
      title              TEXT    NOT NULL DEFAULT '',
      title_normalised   TEXT    NOT NULL DEFAULT '',
      is_group           INTEGER NOT NULL DEFAULT 0,
      last_message_at    INTEGER NOT NULL,
      read_through_at    INTEGER
    )
  ''');
  // The identity CAP-3 defines. Partial, because a deleted conversation must
  // not block a new one for the same thread being created when it revives
  // (CAP-23).
  await txn.execute('''
    CREATE UNIQUE INDEX idx_conversations_identity
      ON conversations (package, conversation_key) WHERE deleted_at IS NULL
  ''');
  // The inbox's own sort (INB-4).
  await txn.execute('''
    CREATE INDEX idx_conversations_recent
      ON conversations (last_message_at DESC) WHERE deleted_at IS NULL
  ''');

  // Messages. `text` is nullable and the check constraint is what enforces
  // CAP-8's "the marker is never stored as if it were the message": a hidden
  // message cannot carry text at all, whatever a future code path tries.
  await txn.execute('''
    CREATE TABLE messages (
      $recordColumns,
      conversation_id  TEXT    NOT NULL REFERENCES conversations (id),
      sender           TEXT    NOT NULL DEFAULT '',
      sender_normalised TEXT   NOT NULL DEFAULT '',
      text             TEXT,
      text_normalised  TEXT,
      text_hash        TEXT    NOT NULL DEFAULT '',
      content_kind     TEXT    NOT NULL,
      direction        TEXT    NOT NULL,
      send_state       TEXT    NOT NULL DEFAULT 'sent',
      notification_key TEXT    NOT NULL DEFAULT '',
      history_index    INTEGER NOT NULL DEFAULT 0,
      sent_at          INTEGER NOT NULL,
      CHECK (content_kind IN ('text','hidden','image','voice','video','file','raw','other')),
      CHECK (direction IN ('inbound','outbound')),
      CHECK (send_state IN ('pending','sent','failed')),
      CHECK (text IS NULL OR content_kind IN ('text','raw'))
    )
  ''');
  // CAP-5's cross-key dedup. Deliberately NOT partial on deleted_at: a message
  // the user deleted must not be captured again by a re-post or a reconnection
  // re-read. The column order also serves the thread view's oldest-first read
  // and retention's range scan, so three readers share one index.
  await txn.execute('''
    CREATE UNIQUE INDEX idx_messages_dedup
      ON messages (conversation_id, sent_at, sender, text_hash)
  ''');
  // CAP-5's within-notification identity, which is what makes a burst of five
  // messages sharing one timestamp five rows rather than one.
  await txn.execute('''
    CREATE UNIQUE INDEX idx_messages_notification
      ON messages (notification_key, history_index)
  ''');

  // When the listener was bound, so "nothing from while access was off" is a
  // fact the app holds rather than a sentence on a screen (CAP-12).
  await txn.execute('''
    CREATE TABLE capture_sessions (
      $recordColumns,
      started_at INTEGER NOT NULL,
      ended_at   INTEGER
    )
  ''');

  // The per-app twin: one row per enable and per disable, because a single
  // enabled_at column cannot carry more than one gap (INB-10, INB-22).
  await txn.execute('''
    CREATE TABLE app_capture_sessions (
      $recordColumns,
      package    TEXT    NOT NULL,
      started_at INTEGER NOT NULL,
      ended_at   INTEGER
    )
  ''');
  await txn.execute('''
    CREATE INDEX idx_app_capture_sessions_package
      ON app_capture_sessions (package, started_at)
  ''');

  // Single-row key/value settings. `installed_at` lives here: without it the
  // app cannot say when its history starts (CAP-12).
  await txn.execute('''
    CREATE TABLE settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
}

/// Step 2: a message's identity is its content, never its position (CAP-5, as
/// corrected on 21 September 2026).
///
/// Step 1 gave `messages` two unique indexes, and between them they threw away
/// messages the user had been sent:
///
///  * `(notification_key, history_index)` made the first message ever written
///    under a key the only one. Google Messages — the one real app the spike
///    measured — posts one notification per message and reuses one key for the
///    whole thread, each post carrying a history of one entry at index 0, so
///    every message after a contact's first collided with it and was discarded.
///    A history window that slides loses its newest entry the same way.
///  * `(conversation_id, sent_at, sender, text_hash)` applied CAP-5's
///    *cross-key* rule inside one key, so two identical texts sent in one burst
///    — "?" then "?" — became one row.
///
/// The replacement keeps one unique index, and only for the rows whose identity
/// is genuinely a tuple: a message with no time of its own (CAP-8, CAP-21),
/// keyed on its notification and its position. For a message that carried its
/// own time there is no unique index at all, because CAP-5 identifies one by
/// aligning the incoming message history against the stored one as a sequence,
/// and a sequence is not a tuple — see `idx_messages_content` below.
/// `history_index` stays stored and stays real information about where the
/// message sat in its notification; it is simply not what makes a message that
/// message.
///
/// A device upgrading keeps every row it has. Nothing here rewrites data: the
/// old indexes only ever *rejected* writes, so no stored row can violate the
/// new ones — a row that is in the table already satisfied a stricter rule.
///
/// The same step carries CAP-9's half of the correction — an attachment is
/// keyed on its type code and no longer on its position — which does change
/// what `text_hash` holds for an image, a voice note, a video, a file and an
/// `other`. That needs no backfill, and the reason is worth stating rather
/// than assuming: capture is the only writer of `messages` and it ships on
/// this branch, alongside this step, so no device that ran step 1 can hold a
/// single message row, let alone an attachment. An identity change that landed
/// after rows existed would need its rewrite here, and step 2 is the wrong
/// place to learn that by rote.
/// **Two things were added to this step rather than appended as a step 3, on
/// 21 September 2026, and the choice is deliberate.** `messages` needs a
/// widened `direction` check (INB-9's third value) and a new `time_source`
/// column (CAP-5's), and SQLite can change neither a CHECK nor a column list in
/// place: both mean rebuilding the table. Step 2 is not merged, it already owns
/// the CAP-5 correction these two changes finish, and it already argues, for
/// its own reasons above, that no device can hold a message row, because
/// capture ships on this branch alongside it. So there is nothing for a step 3
/// to migrate that step 2 is not already migrating, and one rebuilt table on
/// one schema version says what happened more honestly than two versions of a
/// branch that has never been released. Step 1 stays untouched: it is merged,
/// and it is what a device that installed before this branch is sitting on.
Future<void> _step2MessageIdentityIsContent(Transaction txn) async {
  await txn.execute('DROP INDEX IF EXISTS idx_messages_dedup');
  await txn.execute('DROP INDEX IF EXISTS idx_messages_notification');

  // The rebuild. Step 1's table cannot be edited, so the table is replaced:
  //
  //  * `direction` gains `unknown`. INB-9 says a message whose direction cannot
  //    be decided is drawn with no side and no sender rather than guessed into
  //    one, and is counted in no unread badge - and the old two-value check
  //    made that state unstorable, so capture guessed `inbound` and put the
  //    user's own messages into their own unread count (INB-5).
  //  * `time_source` records whether `sent_at` came from the message's own
  //    history entry or from the notification's `postTime`. Android sets
  //    `postTime` on every enqueue, including an in-place update, so it moves
  //    under a message that never changed; CAP-5 leaves it out of the match for
  //    the rows that carry it, and this column is how a row says which it is.
  await txn.execute('''
    CREATE TABLE messages_v2 (
      $recordColumns,
      conversation_id   TEXT    NOT NULL REFERENCES conversations (id),
      sender            TEXT    NOT NULL DEFAULT '',
      sender_normalised TEXT    NOT NULL DEFAULT '',
      text              TEXT,
      text_normalised   TEXT,
      text_hash         TEXT    NOT NULL DEFAULT '',
      content_kind      TEXT    NOT NULL,
      direction         TEXT    NOT NULL,
      send_state        TEXT    NOT NULL DEFAULT 'sent',
      notification_key  TEXT    NOT NULL DEFAULT '',
      history_index     INTEGER NOT NULL DEFAULT 0,
      sent_at           INTEGER NOT NULL,
      time_source       TEXT    NOT NULL DEFAULT 'entry',
      CHECK (content_kind IN ('text','hidden','image','voice','video','file','raw','other')),
      CHECK (direction IN ('inbound','outbound','unknown')),
      CHECK (send_state IN ('pending','sent','failed')),
      CHECK (time_source IN ('entry','post')),
      CHECK (text IS NULL OR content_kind IN ('text','raw'))
    )
  ''');
  // Every row carried over, and `time_source` left at its default for all of
  // them. That is not a guess about old data: the only rows a device can hold
  // here were written before capture shipped, and capture is the only writer
  // that ever produces a `post` row.
  await txn.execute('''
    INSERT INTO messages_v2 (
      id, created_at, updated_at, deleted_at,
      conversation_id, sender, sender_normalised, text, text_normalised,
      text_hash, content_kind, direction, send_state, notification_key,
      history_index, sent_at
    )
    SELECT
      id, created_at, updated_at, deleted_at,
      conversation_id, sender, sender_normalised, text, text_normalised,
      text_hash, content_kind, direction, send_state, notification_key,
      history_index, sent_at
    FROM messages
  ''');
  await txn.execute('DROP TABLE messages');
  await txn.execute('ALTER TABLE messages_v2 RENAME TO messages');

  // CAP-5's cross-notification content match, and the thread read.
  //
  // **Not unique, and that is the correction of 21 September 2026 (fourth).**
  // A message that carried its own time is no longer identified by a tuple of
  // its own fields: it is identified by where it sits in its notification's
  // message history, aligned against the history already stored under that key
  // (CAP-5). Two rows of one conversation may now legitimately agree on
  // `sent_at`, `sender`, `text_hash` **and** `history_index` — a window that
  // slides an entry down while a new entry with the same words takes the
  // position it left is exactly that, and the device produced it. A unique
  // index over those five columns rejects the second write, and an index that
  // rejects a write the rule allows does not protect a message, it deletes one.
  //
  // So nothing in the schema can express the identity of an `entry` row any
  // more, and pretending otherwise is what cost messages twice. What is left
  // here is an ordinary index: it serves the cross-key content match
  // (conversation, `sent_at`, sender, `text_hash` — the shape that covers one
  // message arriving under two different notification keys) and, on its
  // two-column prefix, the thread view's oldest-first read.
  //
  // Still does not exclude deleted rows, for the reason step 1 gave and which
  // has not changed: a message the user deleted must never be captured again
  // by a re-post or a reconnection re-read (CAP-5, DEL-1).
  await txn.execute('''
    CREATE INDEX idx_messages_content
      ON messages (conversation_id, sent_at, sender, text_hash, history_index)
  ''');
  // The alignment's own read: the tail of what is already stored under one
  // notification key, in the order the app told us about it (CAP-5). Partial on
  // `time_source`, because only a message that carried its own time is aligned;
  // a message whose `sent_at` is the notification's moving `postTime` is matched
  // by key and position instead, on the index below.
  //
  // `created_at` leads the sort keys because it is the order the posts arrived
  // in, which is the order the history grew in; `sent_at` and `history_index`
  // break the tie inside one post, where a burst puts every entry on one
  // instant and only the position separates them.
  await txn.execute('''
    CREATE INDEX idx_messages_alignment
      ON messages (
        conversation_id, notification_key, created_at, sent_at, history_index
      )
      WHERE time_source = 'entry'
  ''');
  // The other shape: a message whose `sent_at` is the notification's `postTime`
  // and so a time that moves. Matched on the notification key and the position
  // CAP-8 names, plus whatever content the message does carry - which is what
  // stops an unchanged re-post of a raw notification (CAP-21) being filed again
  // every time the app calls notify().
  //
  // `sent_at` is still in the index, last and as a backstop only. CAP-8 lets
  // two hidden messages sit at one position under one key when the phone posted
  // them at two different moments, because nothing else can tell them apart,
  // and an index that rejected the second would throw away a message on the
  // strength of a rule the lookup does not apply.
  //
  // This is the **only** unique index left on `messages`, and it stays unique
  // because a `post` row's identity genuinely is a tuple: CAP-8 says so, and
  // the lookup that guards it keys on the same columns. The `entry` half of
  // CAP-5 gave its unique index up above, for the reason argued there.
  await txn.execute('''
    CREATE UNIQUE INDEX idx_messages_post_identity
      ON messages (
        conversation_id, notification_key, history_index, sender, text_hash,
        sent_at
      )
      WHERE time_source = 'post'
  ''');

  // Not unique any more, and that is the point: one key now carries as many
  // messages as the app posts under it. It stays an index because a removal
  // has to find the newest message stored for a notification to know what to
  // mark read, and that lookup is by key alone (CAP-22).
  await txn.execute('''
    CREATE INDEX idx_messages_notification
      ON messages (notification_key, sent_at DESC, history_index DESC)
  ''');
}
