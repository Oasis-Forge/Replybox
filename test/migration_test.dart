import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/migrations.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';

/// The thread the upgrade tests fill before they upgrade.
final Conversation conversation = aConversation();

/// Version 1, frozen: the schema of a device that installed before step 2, as
/// literal SQL and not as a call to `migrationSteps[0]`.
///
/// It is written out rather than reused on purpose. A test that builds its
/// "old" database by running the current step 1 is comparing the code with
/// itself: edit that merged step — the one thing `migrations.dart` says must
/// never happen — and both sides of the comparison move together and the test
/// still passes, while real devices split into two schemas sharing one version
/// number. Frozen, the comparison has something to be wrong about.
///
/// So this list does not get "kept in sync" with step 1. If it stops matching,
/// either a merged step was edited, or a change that belongs in a new step was
/// made in an old one.
const List<String> version1Schema = <String>[
  '''
    CREATE TABLE apps (
      id           TEXT    PRIMARY KEY,
      created_at   INTEGER NOT NULL,
      updated_at   INTEGER NOT NULL,
      deleted_at   INTEGER,
      package      TEXT    NOT NULL,
      label        TEXT    NOT NULL,
      enabled      INTEGER NOT NULL DEFAULT 0,
      last_seen_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE UNIQUE INDEX idx_apps_package
      ON apps (package) WHERE deleted_at IS NULL
  ''',
  '''
    CREATE TABLE conversations (
      id           TEXT    PRIMARY KEY,
      created_at   INTEGER NOT NULL,
      updated_at   INTEGER NOT NULL,
      deleted_at   INTEGER,
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
  ''',
  '''
    CREATE UNIQUE INDEX idx_conversations_identity
      ON conversations (package, conversation_key) WHERE deleted_at IS NULL
  ''',
  '''
    CREATE INDEX idx_conversations_recent
      ON conversations (last_message_at DESC) WHERE deleted_at IS NULL
  ''',
  '''
    CREATE TABLE messages (
      id           TEXT    PRIMARY KEY,
      created_at   INTEGER NOT NULL,
      updated_at   INTEGER NOT NULL,
      deleted_at   INTEGER,
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
  ''',
  '''
    CREATE UNIQUE INDEX idx_messages_dedup
      ON messages (conversation_id, sent_at, sender, text_hash)
  ''',
  '''
    CREATE UNIQUE INDEX idx_messages_notification
      ON messages (notification_key, history_index)
  ''',
  '''
    CREATE TABLE capture_sessions (
      id           TEXT    PRIMARY KEY,
      created_at   INTEGER NOT NULL,
      updated_at   INTEGER NOT NULL,
      deleted_at   INTEGER,
      started_at INTEGER NOT NULL,
      ended_at   INTEGER
    )
  ''',
  '''
    CREATE TABLE app_capture_sessions (
      id           TEXT    PRIMARY KEY,
      created_at   INTEGER NOT NULL,
      updated_at   INTEGER NOT NULL,
      deleted_at   INTEGER,
      package    TEXT    NOT NULL,
      started_at INTEGER NOT NULL,
      ended_at   INTEGER
    )
  ''',
  '''
    CREATE INDEX idx_app_capture_sessions_package
      ON app_capture_sessions (package, started_at)
  ''',
  '''
    CREATE TABLE settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''',
];

/// Opens [path] as a version-1 database holding [version1Schema] and nothing
/// else — a device that installed before step 2 shipped.
Future<Database> openVersion1(String path) => databaseFactoryFfi.openDatabase(
  path,
  options: OpenDatabaseOptions(
    version: 1,
    onCreate: (Database d, int v) => d.transaction((Transaction txn) async {
      for (final String statement in version1Schema) {
        await txn.execute(statement);
      }
    }),
  ),
);

/// Every table and index the app defines, by name, with its SQL flattened so
/// the comparison is about the schema and not about how it was laid out.
///
/// Indexes are in it as well as tables: step 2 changes nothing but indexes, so
/// a comparison that read only table names would pass whatever step 2 did.
Future<Map<String, String>> schemaOf(Database database) async {
  final List<Map<String, Object?>> rows = await database.query(
    'sqlite_master',
    columns: <String>['name', 'sql'],
    where:
        "type IN ('table', 'index') AND name NOT LIKE 'sqlite_%' "
        "AND name NOT LIKE 'android_%'",
  );
  return <String, String>{
    for (final Map<String, Object?> row in rows)
      row['name']! as String: ((row['sql'] as String?) ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAllMapped(RegExp(r'\s+([,)])'), (Match m) => m[1]!)
          .replaceAll(RegExp(r'\(\s+'), '(')
          .trim(),
  };
}

/// The migration scaffold, tested against a real SQLite engine.
///
/// The test that matters most here is the upgrade from the oldest schema: a
/// fresh install and an upgraded install must end up with the same database,
/// and nothing else checks that.
void main() {
  setUpAll(initTestDatabases);

  test('a fresh install has every table the rules require', () async {
    final DBHelper db = testDb();
    final Database database = await db.database;

    final List<Map<String, Object?>> tables = await database.query(
      'sqlite_master',
      columns: <String>['name'],
      where:
          "type = 'table' AND name NOT LIKE 'android_%' AND name NOT LIKE 'sqlite_%'",
    );
    final Set<String> names = tables
        .map((Map<String, Object?> r) => r['name']! as String)
        .toSet();

    expect(
      names,
      containsAll(<String>[
        'apps',
        'conversations',
        'messages',
        'capture_sessions',
        'app_capture_sessions',
        'settings',
      ]),
    );
    await db.close();
  });

  test(
    'the version is the number of steps, so appending one ships it',
    () async {
      final DBHelper db = testDb();
      final Database database = await db.database;

      expect(await database.getVersion(), migrationSteps.length);
      await db.close();
    },
  );

  group('upgrading a device that already holds messages (step 2)', () {
    late Directory dir;
    late String path;

    setUp(() async {
      // A file, not `:memory:`: an upgrade is two opens of one database, and an
      // in-memory one is gone the moment the first open closes.
      dir = await Directory.systemTemp.createTemp('replybox-migration');
      path = '${dir.path}/replybox.db';
    });

    tearDown(() => dir.delete(recursive: true));

    /// Opens the version-1 schema — the one a device that installed before this
    /// fix is sitting on — and fills it.
    Future<void> makeVersion1({required List<Message> messages}) async {
      final Database old = await openVersion1(path);
      await old.insert('conversations', conversation.toMap());
      for (final Message m in messages) {
        // Written column by column against the frozen schema, minus the
        // columns step 2 adds: a version-1 row is what a version-1 device could
        // actually hold, and `Message.toMap()` is today's model. Dropping the
        // key here rather than teaching the model about versions is what keeps
        // [version1Schema] frozen and the comparison honest.
        final Map<String, Object?> row = m.toMap()..remove('time_source');
        await old.insert('messages', row);
      }
      await old.close();
    }

    test('every message it already holds is still there afterwards', () async {
      await makeVersion1(
        messages: <Message>[
          aMessage(
            conversationId: conversation.id,
            text: 'from before the fix',
          ),
          aMessage(
            conversationId: conversation.id,
            text: 'and the one after it',
            historyIndex: 1,
            sentAt: t0.add(const Duration(minutes: 1)),
          ),
        ],
      );

      final DBHelper upgraded = DBHelper(
        factoryOverride: databaseFactoryFfi,
        pathOverride: path,
      );
      final Repository repo = Repository(upgraded);

      expect(await (await upgraded.database).getVersion(), 2);
      expect(
        (await repo.messages(conversation.id)).map((Message m) => m.text),
        <String>['from before the fix', 'and the one after it'],
      );
      await upgraded.close();
    });

    test('the next message under the key it already used is stored, not '
        'swallowed (CAP-5)', () async {
      // The upgrade's whole point, on real data: the stored row holds
      // ('thread-key', 0), and Google Messages posts the next message in that
      // thread under the same key at the same index.
      await makeVersion1(
        messages: <Message>[
          aMessage(
            conversationId: conversation.id,
            text: 'the first message this contact ever sent',
            notificationKey: 'thread-key',
          ),
        ],
      );

      final DBHelper upgraded = DBHelper(
        factoryOverride: databaseFactoryFfi,
        pathOverride: path,
      );
      final Repository repo = Repository(upgraded);
      await repo.insertMessageIfNew(
        aMessage(
          conversationId: conversation.id,
          text: 'and the second',
          notificationKey: 'thread-key',
          sentAt: t0.add(const Duration(minutes: 1)),
        ),
      );

      expect(
        (await repo.messages(conversation.id)).map((Message m) => m.text),
        <String>['the first message this contact ever sent', 'and the second'],
      );
      await upgraded.close();
    });

    test('a message it already holds is not stored a second time', () async {
      await makeVersion1(
        messages: <Message>[
          aMessage(conversationId: conversation.id, text: 'already here'),
        ],
      );

      final DBHelper upgraded = DBHelper(
        factoryOverride: databaseFactoryFfi,
        pathOverride: path,
      );
      final Repository repo = Repository(upgraded);
      // A re-read after the upgrade delivers it again under a new key
      // (CAP-13), and identity is content, so it is the same message.
      final bool wrote = (await repo.insertMessageIfNew(
        aMessage(
          conversationId: conversation.id,
          text: 'already here',
          notificationKey: 'a-new-key',
          historyIndex: 3,
        ),
      )).wrote;

      expect(wrote, isFalse);
      expect(await repo.messages(conversation.id), hasLength(1));
      await upgraded.close();
    });
  });

  test('upgrading from the oldest schema lands on the same tables as a fresh '
      'install', () async {
    // The one migration property nothing else checks, and the reason to check
    // it: two devices on the same version must hold the *same* database,
    // whichever way they got there. So both databases are built here and both
    // are read — an upgraded one and a fresh one — and the test is the
    // comparison between them.
    //
    // Version 1 is the oldest schema a device can be sitting on: step 1 is the
    // only merged step, so it is the only one that ever shipped. Upgrading
    // from version 0 would prove nothing, because a fresh install *is* an
    // upgrade from 0 — `DBHelper` runs one list of steps for both. And the
    // version-1 side is [version1Schema], frozen, not `migrationSteps[0]`:
    // built from the current step 1 this compares the code with itself and
    // cannot fail.
    final Directory dir = await Directory.systemTemp.createTemp(
      'replybox-upgrade',
    );
    addTearDown(() => dir.delete(recursive: true));
    final String path = '${dir.path}/replybox.db';

    final Database old = await openVersion1(path);
    await old.close();

    // Reopening through DBHelper is what a real device does on the update.
    final DBHelper upgraded = DBHelper(
      factoryOverride: databaseFactoryFfi,
      pathOverride: path,
    );
    final DBHelper fresh = testDb();
    // Closed in teardown, and registered after the directory so that they run
    // before it: Windows will not delete a file a database still has open, and
    // a failing assertion below must not turn into a teardown error on top.
    addTearDown(upgraded.close);
    addTearDown(fresh.close);
    final Database upgradedDb = await upgraded.database;
    final Database freshDb = await fresh.database;

    expect(await upgradedDb.getVersion(), schemaVersion);
    expect(await freshDb.getVersion(), schemaVersion);
    expect(await schemaOf(upgradedDb), await schemaOf(freshDb));
  });

  group('the indexes the rules depend on exist', () {
    late DBHelper db;
    late Database database;

    setUp(() async {
      db = testDb();
      database = await db.database;
    });

    tearDown(() => db.close());

    Future<Set<String>> indexNames() async {
      final List<Map<String, Object?>> rows = await database.query(
        'sqlite_master',
        columns: <String>['name'],
        where: "type = 'index' AND name LIKE 'idx_%'",
      );
      return rows.map((Map<String, Object?> r) => r['name']! as String).toSet();
    }

    test('CAP-3 conversation identity, CAP-5 identity, INB-4 sort', () async {
      expect(
        await indexNames(),
        containsAll(<String>[
          'idx_conversations_identity',
          'idx_conversations_recent',
          // CAP-5's cross-key content match and the thread read.
          'idx_messages_content',
          // The stored history the alignment reads back (CAP-5).
          'idx_messages_alignment',
          // The one identity the schema can still hold: a message with no time
          // of its own (CAP-8, CAP-21).
          'idx_messages_post_identity',
          'idx_messages_notification',
          'idx_apps_package',
        ]),
      );
      // Step 2 replaced both of step 1's message indexes; the old dedup index
      // is what collapsed two identical texts in one burst into one row.
      expect(await indexNames(), isNot(contains('idx_messages_dedup')));
    });

    test('no index excludes deleted rows (CAP-5)', () async {
      // If any of them were partial on deleted_at, a message the user deleted
      // would be captured again on the next re-post. The rule turns on it.
      //
      // Two of them ARE partial, on `time_source`: a message that carried its
      // own time is aligned against its notification's stored history, and one
      // whose `sent_at` is the notification's moving `postTime` is matched by
      // key and position, and the two key on different columns. That is what
      // this reads for: a WHERE clause about `deleted_at` specifically, not the
      // absence of a WHERE clause.
      for (final String name in <String>[
        'idx_messages_content',
        'idx_messages_alignment',
        'idx_messages_post_identity',
      ]) {
        final List<Map<String, Object?>> rows = await database.query(
          'sqlite_master',
          columns: <String>['sql'],
          where: "type = 'index' AND name = ?",
          whereArgs: <Object?>[name],
        );
        expect(rows.single['sql'], isNot(contains('deleted_at')), reason: name);
      }
    });

    test('only a message with no time of its own has a unique identity '
        '(CAP-5)', () async {
      // The fourth correction, read off the schema. A message that carried its
      // own time is identified by an alignment against the history stored under
      // its notification key, and an alignment is not a tuple: a window that
      // slides one entry down while a new entry with the same words takes the
      // position it left produces two rows agreeing on conversation, `sent_at`,
      // sender, content hash and `history_index`. A unique index over those
      // columns rejects the second write, and an index that rejects a write the
      // rule allows is not a safety net — it is the lost message.
      final List<Map<String, Object?>> rows = await database.query(
        'sqlite_master',
        columns: <String>['name', 'sql'],
        where: "type = 'index' AND name LIKE 'idx_messages_%'",
      );
      final Set<String> unique = <String>{
        for (final Map<String, Object?> row in rows)
          if ((row['sql']! as String).contains('UNIQUE'))
            row['name']! as String,
      };
      expect(unique, <String>{'idx_messages_post_identity'});
      expect(
        rows.firstWhere(
          (Map<String, Object?> r) => r['name'] == 'idx_messages_content',
        )['sql'],
        isNot(contains('UNIQUE')),
      );
    });

    test('a notification key is no longer unique (CAP-5)', () async {
      // Unique on (notification_key, history_index) is what made the first
      // message an app ever posted under a key the only one it could ever
      // store — Google Messages reuses one key for a whole thread.
      final List<Map<String, Object?>> rows = await database.query(
        'sqlite_master',
        columns: <String>['sql'],
        where: "type = 'index' AND name = 'idx_messages_notification'",
      );
      expect(rows.single['sql'], isNot(contains('UNIQUE')));
    });

    test('the conversation identity index IS partial, so a deleted thread can '
        'revive (CAP-23)', () async {
      final List<Map<String, Object?>> rows = await database.query(
        'sqlite_master',
        columns: <String>['sql'],
        where: "type = 'index' AND name = 'idx_conversations_identity'",
      );
      expect(rows.single['sql'], contains('deleted_at IS NULL'));
    });
  });
}
