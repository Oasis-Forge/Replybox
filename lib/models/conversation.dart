import 'normalise.dart';
import 'record.dart';

/// Which notification field produced a conversation's key (CAP-3).
///
/// Stored alongside the key because the field that changes when an app updates
/// its keying is exactly the field that can no longer be matched on, so a
/// migration needs to know which one was used.
enum KeySource {
  shortcutId,
  conversationTitle,
  tag,

  /// No candidate was present. The conversation is keyed by its own
  /// notification key and is never merged into another (CAP-3).
  notificationKey,

  /// CAP-21's fallback: a notification with no message history, kept because
  /// its category said it was a message, is keyed by the source app's package
  /// alone.
  ///
  /// A member of its own rather than borrowed from [notificationKey], because
  /// CAP-3 stores the field the key *came from* and this key came from neither
  /// a candidate nor the notification's key. A row claiming `notificationKey`
  /// while holding a package would send the keying migration CAP-3 exists for
  /// looking at the wrong column, and would tell the reader the thread can
  /// never merge when in fact every raw notification from the app lands in it.
  package;

  static KeySource fromDb(Object? value) => KeySource.values.firstWhere(
    (KeySource k) => k.name == value,
    orElse: () => KeySource.notificationKey,
  );
}

/// A thread in the inbox: one conversation inside one source app (CAP-3).
class Conversation {
  const Conversation({
    required this.id,
    required this.package,
    required this.conversationKey,
    required this.keySource,
    required this.title,
    required this.isGroup,
    required this.lastMessageAt,
    required this.createdAt,
    required this.updatedAt,
    this.shortcutId,
    this.conversationTitle,
    this.tag,
    this.readThroughAt,
    this.deletedAt,
  });

  factory Conversation.fromMap(Map<String, Object?> map) => Conversation(
    id: map['id']! as String,
    package: map['package']! as String,
    conversationKey: map['conversation_key']! as String,
    keySource: KeySource.fromDb(map['key_source']),
    title: map['title']! as String,
    isGroup: boolFromDb(map['is_group']),
    lastMessageAt: timeFromDb(map['last_message_at']),
    createdAt: timeFromDb(map['created_at']),
    updatedAt: timeFromDb(map['updated_at']),
    shortcutId: map['shortcut_id'] as String?,
    conversationTitle: map['conversation_title'] as String?,
    tag: map['tag'] as String?,
    readThroughAt: timeFromDbOrNull(map['read_through_at']),
    deletedAt: timeFromDbOrNull(map['deleted_at']),
  );

  final String id;

  /// The source app's package. Half of the natural key.
  final String package;

  /// The resolved key: the first non-empty of shortcutId, conversationTitle,
  /// tag, else the notification's own key (CAP-3). Unique with [package] among
  /// rows that are not deleted.
  final String conversationKey;

  /// Which field [conversationKey] came from.
  final KeySource keySource;

  /// The other candidates as the notification supplied them, kept so an app
  /// that changes its keying can be migrated rather than silently splitting
  /// every thread (CAP-3). One column would not be enough.
  final String? shortcutId;
  final String? conversationTitle;
  final String? tag;

  /// What the inbox shows as the thread's name. Empty is a real and expected
  /// value: redaction empties the title while leaving a perfectly good key, so
  /// INB-2 branches on this being empty and never on [keySource].
  final String title;

  final bool isGroup;

  /// The arrival time of the newest message: its `sent_at` for an ordinary
  /// message, the notification's post time for a hidden or raw one (INB-4).
  /// Denormalised so the list sorts without touching the messages table.
  final DateTime lastMessageAt;

  /// Everything at or before this instant is read (CAP-22, INB-5). Only ever
  /// moves forward. Null means nothing has been read.
  final DateTime? readThroughAt;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// Whether the thread arrived without a name (INB-2).
  bool get isUnnamed => title.isEmpty;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'package': package,
    'conversation_key': conversationKey,
    'key_source': keySource.name,
    'shortcut_id': shortcutId,
    'conversation_title': conversationTitle,
    'tag': tag,
    'title': title,
    // Written at capture, not when the search screen ships: adding it later
    // would mean a migration that rewrites every row a user already has
    // (CAP-19).
    'title_normalised': normalise(title),
    'is_group': boolToDb(isGroup),
    'last_message_at': timeToDb(lastMessageAt),
    'read_through_at': readThroughAt == null ? null : timeToDb(readThroughAt!),
    'created_at': timeToDb(createdAt),
    'updated_at': timeToDb(updatedAt),
    'deleted_at': deletedAt == null ? null : timeToDb(deletedAt!),
  };

  Conversation copyWith({
    String? title,
    bool? isGroup,
    DateTime? lastMessageAt,
    DateTime? updatedAt,
    Object? shortcutId = unset,
    Object? conversationTitle = unset,
    Object? tag = unset,
    Object? readThroughAt = unset,
    Object? deletedAt = unset,
  }) => Conversation(
    id: id,
    package: package,
    conversationKey: conversationKey,
    keySource: keySource,
    title: title ?? this.title,
    isGroup: isGroup ?? this.isGroup,
    lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    shortcutId: identical(shortcutId, unset)
        ? this.shortcutId
        : shortcutId as String?,
    conversationTitle: identical(conversationTitle, unset)
        ? this.conversationTitle
        : conversationTitle as String?,
    tag: identical(tag, unset) ? this.tag : tag as String?,
    readThroughAt: identical(readThroughAt, unset)
        ? this.readThroughAt
        : readThroughAt as DateTime?,
    deletedAt: identical(deletedAt, unset)
        ? this.deletedAt
        : deletedAt as DateTime?,
  );

  @override
  String toString() => 'Conversation($package/$conversationKey, "$title")';
}
