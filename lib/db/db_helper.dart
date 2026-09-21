import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'migrations.dart';

/// Owns the database and the ordered migration steps that build it.
///
/// Injected into the state layer rather than reached for as a global, so tests
/// get an in-memory database and never touch a file (docs/STACK_NOTES.md).
class DBHelper {
  DBHelper({this.factoryOverride, this.pathOverride});

  /// Set by tests to `databaseFactoryFfi`. Null in the app, which uses the
  /// platform factory.
  final DatabaseFactory? factoryOverride;

  /// Set by tests to `inMemoryDatabasePath`.
  final String? pathOverride;

  Database? _db;

  /// The open database, opening it on first use.
  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final DatabaseFactory factory = factoryOverride ?? databaseFactory;
    final String path =
        pathOverride ?? p.join(await factory.getDatabasesPath(), 'replybox.db');
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: _configure,
        onCreate: _create,
        onUpgrade: _upgrade,
      ),
    );
  }

  Future<void> _configure(Database db) async {
    // messages.conversation_id is a real reference and the app relies on it;
    // sqflite leaves enforcement off unless asked.
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// A fresh install runs every step in order, so there is exactly one code
  /// path that builds a schema and it is the same one an upgrade uses.
  Future<void> _create(Database db, int version) =>
      _runSteps(db, from: 0, to: version);

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) =>
      _runSteps(db, from: oldVersion, to: newVersion);

  Future<void> _runSteps(Database db, {required int from, required int to}) =>
      db.transaction((Transaction txn) async {
        for (int i = from; i < to; i++) {
          await migrationSteps[i](txn);
        }
      });

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
