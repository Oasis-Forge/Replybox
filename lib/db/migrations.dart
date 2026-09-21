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
const List<MigrationStep> migrationSteps = <MigrationStep>[_step1CaptureTables];

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
