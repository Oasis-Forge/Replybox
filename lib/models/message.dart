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

/// Whether a message came in, went out, or could not be decided (INB-9).
enum Direction {
  inbound,
  outbound,

  /// The notification's history did not say who wrote this line, so the app
  /// does not guess one (INB-9, corrected 21 September 2026).
  ///
  /// A third value rather than "inbound, probably" because the two failures a
  /// guess produces are both real and both visible: the user's own message
  /// drawn as though someone had sent it *and* counted in the unread badge, or
  /// somebody else's drawn as the user's and never counted. INB-9's answer is
  /// a message with no side and no sender, counted in no badge, and that state
  /// has to be storable for the screen to be able to draw it.
  unknown;

  /// Anything the column cannot be read as is [unknown], not [inbound]: a
  /// direction the app cannot read is exactly what this value means, and
  /// defaulting to `inbound` would put a row in someone's unread badge on the
  /// strength of a failed parse (INB-5).
  static Direction fromDb(Object? value) => Direction.values.firstWhere(
    (Direction d) => d.name == value,
    orElse: () => Direction.unknown,
  );
}

/// Where a message's `sent_at` came from — and so whether that time is allowed
/// to be part of its identity (CAP-5, corrected 21 September 2026).
enum TimeSource {
  /// The posting app gave this message its own time, in its history entry. It
  /// does not move, so CAP-5 matches on it.
  entry,

  /// There was no such time, so `sent_at` is the notification's `postTime`:
  /// a hidden message (CAP-8), a raw one (CAP-21), an attachment whose entry
  /// carried no time, and any entry whose time could not be read (CAP-9).
  ///
  /// Android sets `StatusBarNotification.postTime` on every enqueue, including
  /// an in-place update of a notification already in the shade, so this value
  /// moves under a message that has not changed. **A time that moves cannot be
  /// part of identity**, and CAP-5 leaves it out of the match for these rows.
  post;

  static TimeSource fromDb(Object? value) => TimeSource.values.firstWhere(
    (TimeSource s) => s.name == value,
    // A row written before the column existed came from capture, which had no
    // other source then either; `entry` is the column's own default.
    orElse: () => TimeSource.entry,
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
    this.timeSource = TimeSource.entry,
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
    timeSource: TimeSource.fromDb(map['time_source']),
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

  /// Where [sentAt] came from, and so whether CAP-5 may match on it.
  final TimeSource timeSource;

  final MessageKind kind;
  final Direction direction;
  final SendState sendState;

  /// The key of the notification this message arrived in. Kept because a
  /// removal names a key and nothing else, and that is how CAP-22 finds what to
  /// mark read.
  ///
  /// It is *not* the message's identity. With [historyIndex] it was, until a
  /// sliding history window and an app that reuses one key per thread showed
  /// that a message's position moves while the message does not (CAP-5,
  /// corrected 21 September 2026).
  final String notificationKey;

  /// Position in that notification's message history, 0-based.
  ///
  /// Real information about where the message sat when it arrived, and worth
  /// storing for that alone — it is what orders a burst that shares one
  /// timestamp. It is not identity (CAP-5).
  final int historyIndex;

  /// Null for every kind that does not carry text — a hidden message most of
  /// all (CAP-8).
  final String? text;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// The hash CAP-5 matches on. Hashing rather than comparing the text keeps
  /// the dedup index narrow and avoids a second copy of every message sitting
  /// in an index (CAP-15). Empty for a message with no text — which is why
  /// [dedupHash], not this, is what reaches the column.
  static String hashText(String? text) {
    if (text == null || text.isEmpty) return '';
    return sha256.convert(utf8.encode(text)).toString();
  }

  /// The identity a message with nothing of its own to match on carries into
  /// the dedup index: the notification's key and the message's position in its
  /// history, hashed the same width as a text hash so one column holds both.
  ///
  /// The leading marker keeps this apart from the hash of any real message
  /// text, so the two kinds of identity can never be confused for one another.
  ///
  /// This is identity by *position*, and a position moves when a history
  /// window slides — which is the whole reason CAP-5 stopped using it. Exactly
  /// one message is still allowed it, and CAP-8 says which: a hidden one, with
  /// no sender, no text and a time that was observed moving 19 seconds between
  /// two reads of one unchanged notification. Nothing else may borrow it; see
  /// [dedupHash].
  static String hashIdentity(String notificationKey, int historyIndex) => sha256
      .convert(
        utf8.encode(
          '\u0000notification\u0000$notificationKey\u0000$historyIndex',
        ),
      )
      .toString();

  /// The identity an attachment carries into the dedup index (CAP-9): its
  /// content kind, which is the whole of what the app was told about it.
  ///
  /// An attachment is not a hidden message and must not borrow CAP-8's
  /// position identity. It arrives with a sender, with a time its app gave it,
  /// and with a type — so it has content to be identified by, and CAP-5 says
  /// content is what identity is. Keyed on position, a photo a sliding history
  /// window moves from index 1 to index 0 is stored a second time, and the
  /// inbox shows a photo the user was sent once as two.
  ///
  /// The kind is deliberately all of it. CAP-15 keeps the type code and never
  /// the MIME string it was read from, so there is nothing finer to key on;
  /// what that costs is written into CAP-5's residuals rather than papered
  /// over. Two photos in one burst are still two rows: inside one notification
  /// the position is the tie-break, and the caller claims each row it matched.
  ///
  /// Same NUL marker as [hashIdentity], and for the same reason: no
  /// notification text can carry one, so neither identity can ever be mistaken
  /// for the hash of something a person actually wrote.
  static String hashAttachmentIdentity(MessageKind kind) => sha256
      .convert(utf8.encode('\u0000attachment\u0000${kind.name}'))
      .toString();

  /// What goes in `text_hash`: the content half of CAP-5's identity, and the
  /// reason the dedup lookup can tell two textless messages apart.
  ///
  /// The lookup matches on (conversation_id, sent_at, sender, text_hash). Two
  /// hidden messages in one conversation carry sender `''` and text null, so
  /// hashing the text gives both the same empty string; share a `postTime` —
  /// which is the only time a hidden message may use (CAP-8) — and the second
  /// one matches the first and is never stored, losing a message the user was
  /// never shown and can never recover. CAP-8 says a hidden message's identity
  /// is the notification key plus its history index and never sender, text or
  /// time, so that is what the column carries when there is no text to hash.
  /// That is CAP-8's own rule and it is deliberately untouched by CAP-5's
  /// correction: a message with no content cannot be identified by content.
  ///
  /// The same collapse reaches every other kind that cannot carry text — an
  /// image, a voice note, a video, a file, an `other` (CAP-9) — and the spike's
  /// burst proved the premise, delivering five messages under one identical
  /// timestamp: five photos from one sender in one burst would otherwise
  /// become one row. Matching on emptiness is how two different messages
  /// become one, so a message with nothing to match on is matched on its
  /// identity instead.
  ///
  /// But an attachment does have something to match on, and taking CAP-8's
  /// position identity for it was the second half of the same mistake CAP-5's
  /// correction names: position is not identity, so a history window that
  /// slides an image from index 1 to index 0 stored the photo twice and drew
  /// the user two of a photo they were sent once. An attachment is keyed on
  /// its type instead ([hashAttachmentIdentity]) — the only content CAP-15
  /// keeps of it — which a slide carries with it. `other` is keyed the same
  /// way and for the same reason: it is CAP-9's attachment whose type the app
  /// could not name, not a message with no content.
  ///
  /// A message that does carry text is matched on conversation, sender, text
  /// and `sent_at` wherever it turns up, which is what makes a reconnection
  /// re-read (CAP-13) under a new key store nothing twice.
  String get dedupHash {
    if (text != null && text!.isNotEmpty) return hashText(text);
    return switch (kind) {
      // CAP-8, untouched: the one message with no sender, no text and no time
      // it can trust is identified by where it sat.
      MessageKind.hidden => hashIdentity(notificationKey, historyIndex),
      // CAP-9: identified by what it is.
      MessageKind.image ||
      MessageKind.voice ||
      MessageKind.video ||
      MessageKind.file ||
      MessageKind.other => hashAttachmentIdentity(kind),
      // A kind that may carry text and turned up with none. Capture never
      // files one — a blank history entry is skipped and CAP-21 drops a
      // notification with neither title nor text — so this is the branch for a
      // row no rule describes, and position is what cannot silently merge it
      // with another.
      MessageKind.text ||
      MessageKind.raw => hashIdentity(notificationKey, historyIndex),
    };
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'conversation_id': conversationId,
    'sender': sender,
    'sender_normalised': normalise(sender),
    'text': text,
    'text_normalised': text == null ? null : normalise(text!),
    'text_hash': dedupHash,
    'content_kind': kind.name,
    'direction': direction.name,
    'send_state': sendState.name,
    'notification_key': notificationKey,
    'history_index': historyIndex,
    'sent_at': timeToDb(sentAt),
    'time_source': timeSource.name,
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
    timeSource: timeSource,
    text: identical(text, unset) ? this.text : text as String?,
    deletedAt: identical(deletedAt, unset)
        ? this.deletedAt
        : deletedAt as DateTime?,
  );

  @override
  String toString() => 'Message(${kind.name}, $sender, $sentAt)';
}
