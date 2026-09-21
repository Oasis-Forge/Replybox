import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'normalise.dart';
import 'record.dart';

/// What a message actually holds (CAP-8, CAP-9, CAP-21).
///
/// A boolean `redacted` could not carry hidden, an attachment placeholder and
/// a raw fallback at once, so the kind is a column. It is what enforces CAP-8's
/// "the marker text is never stored as if it were the message": a hidden
/// message has [MessageKind.hidden] and a null text, and there is no code path
/// that can put the system's string in the text column.
enum MessageKind {
  /// Ordinary text the notification supplied.
  text,

  /// Android hid the content from listeners. Text is null (CAP-8).
  hidden,

  image,
  voice,
  video,
  file,

  /// A notification with no message history, kept as one line because its
  /// category said it was a message (CAP-21).
  raw,

  /// Something arrived that the app cannot describe (CAP-9).
  other;

  static MessageKind fromDb(Object? value) => MessageKind.values.firstWhere(
    (MessageKind k) => k.name == value,
    orElse: () => MessageKind.other,
  );

  /// Whether this kind may carry text at all. Used by the database's own check
  /// constraint, so the rule is enforced by the column and not only here.
  bool get carriesText => this == MessageKind.text || this == MessageKind.raw;
}

/// Whether a message came in or went out.
enum Direction {
  inbound,
  outbound;

  static Direction fromDb(Object? value) => Direction.values.firstWhere(
    (Direction d) => d.name == value,
    orElse: () => Direction.inbound,
  );
}

/// Where an outbound message has got to (INB-9).
///
/// Here in Phase 1 rather than with the Reply area, because the Inbox screen
/// draws the unconfirmed bubble before Reply exists, and adding the column
/// later would mean a migration on live data for something already rendered.
enum SendState {
  pending,
  sent,
  failed;

  static SendState fromDb(Object? value) => SendState.values.firstWhere(
    (SendState s) => s.name == value,
    orElse: () => SendState.sent,
  );
}

/// One message in a conversation.
class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.sender,
    required this.sentAt,
    required this.kind,
    required this.direction,
    required this.sendState,
    required this.notificationKey,
    required this.historyIndex,
    required this.createdAt,
    required this.updatedAt,
    this.text,
    this.deletedAt,
  });

  factory Message.fromMap(Map<String, Object?> map) => Message(
    id: map['id']! as String,
    conversationId: map['conversation_id']! as String,
    sender: map['sender']! as String,
    sentAt: timeFromDb(map['sent_at']),
    kind: MessageKind.fromDb(map['content_kind']),
    direction: Direction.fromDb(map['direction']),
    sendState: SendState.fromDb(map['send_state']),
    notificationKey: map['notification_key']! as String,
    historyIndex: map['history_index']! as int,
    createdAt: timeFromDb(map['created_at']),
    updatedAt: timeFromDb(map['updated_at']),
    text: map['text'] as String?,
    deletedAt: timeFromDbOrNull(map['deleted_at']),
  );

  final String id;
  final String conversationId;

  /// Who sent it, as the notification named them. Empty on a hidden message:
  /// redaction empties the sender too, and the app does not guess (CAP-8).
  final String sender;

  /// The time the posting app gave the message — never the time we captured
  /// it, which is [createdAt] (CAP-5). For a hidden or raw message this is the
  /// notification's post time, because neither carries a history to read a
  /// time from (INB-4).
  final DateTime sentAt;

  final MessageKind kind;
  final Direction direction;
  final SendState sendState;

  /// The key of the notification this message arrived in. With
  /// [historyIndex] it is the message's identity within that notification,
  /// which is what makes dedup work when five messages share one timestamp
  /// (CAP-5).
  final String notificationKey;

  /// Position in that notification's message history, 0-based.
  final int historyIndex;

  /// Null for every kind that does not carry text — a hidden message most of
  /// all (CAP-8).
  final String? text;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// The hash CAP-5 matches on across notification keys. Hashing rather than
  /// comparing the text keeps the dedup index narrow and avoids a second copy
  /// of every message sitting in an index (CAP-15). Empty for a message with
  /// no text, so two hidden messages never collide on it.
  static String hashText(String? text) {
    if (text == null || text.isEmpty) return '';
    return sha256.convert(utf8.encode(text)).toString();
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'conversation_id': conversationId,
    'sender': sender,
    'sender_normalised': normalise(sender),
    'text': text,
    'text_normalised': text == null ? null : normalise(text!),
    'text_hash': hashText(text),
    'content_kind': kind.name,
    'direction': direction.name,
    'send_state': sendState.name,
    'notification_key': notificationKey,
    'history_index': historyIndex,
    'sent_at': timeToDb(sentAt),
    'created_at': timeToDb(createdAt),
    'updated_at': timeToDb(updatedAt),
    'deleted_at': deletedAt == null ? null : timeToDb(deletedAt!),
  };

  Message copyWith({
    SendState? sendState,
    DateTime? updatedAt,
    Object? text = unset,
    Object? deletedAt = unset,
  }) => Message(
    id: id,
    conversationId: conversationId,
    sender: sender,
    sentAt: sentAt,
    kind: kind,
    direction: direction,
    sendState: sendState ?? this.sendState,
    notificationKey: notificationKey,
    historyIndex: historyIndex,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    text: identical(text, unset) ? this.text : text as String?,
    deletedAt: identical(deletedAt, unset)
        ? this.deletedAt
        : deletedAt as DateTime?,
  );

  @override
  String toString() => 'Message(${kind.name}, $sender, $sentAt)';
}
