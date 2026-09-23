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

/// Characters a reader cannot see but [String.trim] leaves behind, because the
/// Unicode standard does not class them as whitespace: the soft hyphen, the
/// Arabic letter mark, the zero-width space and joiners, the bidirectional
/// embedding and isolate controls, the invisible maths operators and the byte
/// order mark.
const Set<int> _invisibleRunes = <int>{
  0x00AD, // soft hyphen
  0x061C, // Arabic letter mark
  0x180E, // Mongolian vowel separator
  0x200B, 0x200C, 0x200D, 0x200E, 0x200F, // zero width, joiners, LRM/RLM
  0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // bidi embedding and override
  0x2060, 0x2061, 0x2062, 0x2063, 0x2064, // word joiner, invisible operators
  0x2066, 0x2067, 0x2068, 0x2069, // bidi isolates
  0xFEFF, // byte order mark
};

/// Whether [value] holds nothing a reader could see.
///
/// Not the same question as `isEmpty`, and INB-2 turns on the difference. A
/// notification can arrive carrying a title of one space, or of one zero-width
/// space, and such a title stores as a perfectly non-empty string that draws as
/// nothing at all: the row would show a blank name, take no initials from it,
/// and — because the title was "not empty" — say nothing about the notification
/// having arrived without one. That blank is the exact gap INB-2 exists to
/// close, so "no name" here means no visible character rather than no character.
bool isBlank(String value) {
  for (final int rune in value.runes) {
    if (_invisibleRunes.contains(rune)) continue;
    if (String.fromCharCode(rune).trim().isEmpty) continue;
    return false;
  }
  return true;
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
  ///
  /// [isBlank] and not `isEmpty`: a title of one space draws as nothing, and a
  /// row that drew it would be nameless while claiming to have a name.
  bool get isUnnamed => isBlank(title);

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
