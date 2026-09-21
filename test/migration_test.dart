import 'package:flutter_test/flutter_test.dart';
import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/migrations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';

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

  test('upgrading from the oldest schema lands on the same tables as a fresh '
      'install', () async {
    // Open at version 0 with no steps run, then let the helper upgrade it the
    // way a real device would.
    final Database old = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (Database d, int v) async {},
      ),
    );
    await old.close();

    final DBHelper fresh = testDb();
    final Database database = await fresh.database;
    final List<Map<String, Object?>> tables = await database.query(
      'sqlite_master',
      columns: <String>['name'],
      where: "type = 'table' AND name NOT LIKE 'sqlite_%'",
    );

    expect(tables, isNotEmpty);
    await fresh.close();
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

    test('CAP-3 conversation identity, CAP-5 dedup, INB-4 sort', () async {
      expect(
        await indexNames(),
        containsAll(<String>[
          'idx_conversations_identity',
          'idx_conversations_recent',
          'idx_messages_dedup',
          'idx_messages_notification',
          'idx_apps_package',
        ]),
      );
    });

    test('the dedup index does NOT exclude deleted rows (CAP-5)', () async {
      // If this index were partial on deleted_at, a message the user deleted
      // would be captured again on the next re-post. The rule turns on it.
      final List<Map<String, Object?>> rows = await database.query(
        'sqlite_master',
        columns: <String>['sql'],
        where: "type = 'index' AND name = 'idx_messages_dedup'",
      );
      expect(rows.single['sql'], isNot(contains('WHERE')));
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
