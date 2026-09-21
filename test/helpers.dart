/// Shared test scaffolding.
///
/// Database tests run a real SQLite in memory, so a migration step is
/// exercised by the engine that will actually run it. A mock would pass on SQL
/// SQLite rejects, which is the whole risk a migration test exists to cover.
library;

import 'package:replybox/db/db_helper.dart';
import 'package:replybox/db/repository.dart';
import 'package:replybox/models/conversation.dart';
import 'package:replybox/models/message.dart';
import 'package:replybox/models/record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Call once per test file, before any database is opened.
void initTestDatabases() {
  sqfliteFfiInit();
}

/// A fresh, empty database, built by running every migration step in order.
DBHelper testDb() => DBHelper(
  factoryOverride: databaseFactoryFfi,
  pathOverride: inMemoryDatabasePath,
);

/// A repository over a fresh database.
Future<({Repository repository, DBHelper db})> testRepository() async {
  final DBHelper db = testDb();
  return (repository: Repository(db), db: db);
}

/// A fixed instant, so nothing in a test depends on the clock.
final DateTime t0 = DateTime.utc(2026, 9, 21, 12);

/// A conversation with sensible defaults; override only what the test is about.
Conversation aConversation({
  String package = 'com.whatsapp',
  String key = 'shortcut-1',
  KeySource keySource = KeySource.shortcutId,
  String title = 'Ada Lovelace',
  bool isGroup = false,
  DateTime? lastMessageAt,
  DateTime? readThroughAt,
  String? id,
}) {
  final DateTime at = lastMessageAt ?? t0;
  return Conversation(
    id: id ?? newId(),
    package: package,
    conversationKey: key,
    keySource: keySource,
    title: title,
    isGroup: isGroup,
    lastMessageAt: at,
    readThroughAt: readThroughAt,
    createdAt: at,
    updatedAt: at,
    shortcutId: keySource == KeySource.shortcutId ? key : null,
  );
}

/// A message with sensible defaults.
///
/// [sentAt] defaults to [t0] for every message, on purpose: the spike's burst
/// delivered five messages under one identical timestamp, so a test that wants
/// distinct times has to ask for them.
Message aMessage({
  required String conversationId,
  String sender = 'Ada',
  String? text = 'hello',
  MessageKind kind = MessageKind.text,
  Direction direction = Direction.inbound,
  SendState sendState = SendState.sent,
  String notificationKey = 'notif-1',
  int historyIndex = 0,
  DateTime? sentAt,
  String? id,
}) {
  final DateTime at = sentAt ?? t0;
  return Message(
    id: id ?? newId(),
    conversationId: conversationId,
    sender: sender,
    sentAt: at,
    kind: kind,
    direction: direction,
    sendState: sendState,
    notificationKey: notificationKey,
    historyIndex: historyIndex,
    text: kind.carriesText ? text : null,
    createdAt: at,
    updatedAt: at,
  );
}
