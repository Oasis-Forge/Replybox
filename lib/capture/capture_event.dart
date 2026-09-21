/// One hand-over row from the native listener, parsed into a typed event.
///
/// Every field here crossed a platform channel after being assembled from
/// another app's notification, so nothing about its shape is guaranteed:
/// `org.json` drops null keys, so any field can be absent, and a field can
/// arrive with a type the contract does not name. Every reader tolerates both
/// (a throw here would lose the rest of a drain), and a field that cannot be
/// read as its declared type is read as absent rather than coerced — a title
/// invented out of a number would be the app guessing at content it did not
/// receive.
///
/// The field names are the spike dump's names on purpose, so
/// `docs/research/spike-dumps/*.jsonl` are fixtures with no translation layer
/// between them and the engine.
///
/// What is *not* here is the point of CAP-15: no icons, no extras bundle, no
/// channel, no `Action` objects, no `bigText`, no flags. This class is the
/// whole of what capture is allowed to see.
library;

import 'dart:convert';

/// The `template` CAP-2 gates a message on.
const String messagingStyleTemplate =
    r'android.app.Notification$MessagingStyle';

/// Which of the listener's four events this row is.
enum CaptureEventType {
  posted,
  removed,

  /// The listener bound; CAP-12 opens a capture session on it.
  listenerConnected,

  /// The listener went away; CAP-12 closes the session.
  listenerDisconnected,

  /// Anything else. The spike's own dumps carry `dismiss_all` and
  /// `reply_attempt` lines that its tooling wrote and the contract does not
  /// define, so an unrecognised event is a normal thing to meet, not a bug.
  unknown;

  static CaptureEventType fromName(Object? value) => switch (value) {
    'posted' => CaptureEventType.posted,
    'removed' => CaptureEventType.removed,
    'listener_connected' => CaptureEventType.listenerConnected,
    'listener_disconnected' => CaptureEventType.listenerDisconnected,
    _ => CaptureEventType.unknown,
  };
}

/// Why a notification left the shade (CAP-22).
///
/// Only the reasons CAP-22 names have members. Everything else — including a
/// reason Android adds in a later release — is [other] and changes nothing,
/// which is the rule's own default, so this enum never has to be kept in step
/// with the platform's list.
enum RemovalReason {
  /// The user opened it. The strongest read signal there is (CAP-22, INB-5).
  click,

  /// The posting app cancelled it, which it does when the user read the
  /// conversation in the app itself (CAP-22).
  appCancel,

  /// The shade was cleared. Named rather than folded into [other] so a test
  /// can assert that clearing the shade is not reading (CAP-22).
  cancelAll,
  listenerCancel,
  listenerCancelAll,

  /// Any other reason, or none supplied.
  other;

  static RemovalReason fromName(Object? value) => switch (value) {
    'CLICK' => RemovalReason.click,
    'APP_CANCEL' => RemovalReason.appCancel,
    'CANCEL_ALL' => RemovalReason.cancelAll,
    'LISTENER_CANCEL' => RemovalReason.listenerCancel,
    'LISTENER_CANCEL_ALL' => RemovalReason.listenerCancelAll,
    _ => RemovalReason.other,
  };

  /// Whether this reason means the user read the conversation (CAP-22). The
  /// shade being cleared is not the user reading anything, so only these two
  /// move the marker.
  bool get marksRead =>
      this == RemovalReason.click || this == RemovalReason.appCancel;
}

/// One entry in a notification's message history.
///
/// Its position in [CaptureEvent.messages] is its history index, and half of
/// its identity (CAP-5, CAP-8) — so an entry that cannot be read is kept as an
/// empty one rather than dropped, because dropping it would shift every later
/// entry's index and change the identity of messages that did parse.
class CapturedMessage {
  const CapturedMessage({
    this.sender,
    this.text,
    this.time,
    this.type,
    bool? hasSender,
  }) : hasSender = hasSender ?? (sender != null);

  /// Reads the sender, and — separately — whether there was one at all.
  ///
  /// `MessagingStyle.Message.toBundle()` writes the sender under two keys: the
  /// modern `sender_person`, a `Person`, and the legacy `sender`, the name on
  /// that `Person`. It writes **neither** when the `Person` is null, which is
  /// how it marks the phone owner's own line. The projection collapses the two
  /// into one `sender` — the legacy name, else the `Person`'s — and states the
  /// absence separately, as a real Boolean under `senderAbsent`
  /// (`NotificationProjection.projectHistory`), because a `sender` that is
  /// merely missing from the JSON cannot be told from one Android emptied.
  ///
  /// That flag is authoritative where it is there. Where it is not, the row was
  /// written by a projection that predates it — every dump in
  /// `docs/research/spike-dumps` is — and the honest reading is the older one:
  /// a `sender` key that arrived at all is a sender the notification carried.
  /// None of those dumps holds a line the posting user wrote (INB-9), so none
  /// of them needs the flag to be read correctly.
  ///
  /// `sender_person` is read too, as a name or as an object carrying one, so
  /// that a row projecting the `Person` itself is a *sender* rather than being
  /// mistaken for the user's own line. Nothing emits it today.
  factory CapturedMessage.fromJson(Object? value) {
    if (value is! Map) return const CapturedMessage();
    final Map<String, Object?> map = value.cast<String, Object?>();
    final String? legacy = _string(map['sender']);
    final Object? person = map['sender_person'];
    final Object? absent = map['senderAbsent'];
    return CapturedMessage(
      sender: legacy ?? _personName(person),
      hasSender: absent is bool ? !absent : (legacy != null || person != null),
      text: _string(map['text']),
      time: _time(map['time']),
      type: _string(map['type']),
    );
  }

  /// As the notification named them. Empty on a hidden message, and the app
  /// does not guess (CAP-8). Null when the entry carried no sender at all —
  /// which is not the same thing, and [hasSender] is what keeps them apart.
  final String? sender;

  /// Whether the entry carried a sender key at all, under either name.
  ///
  /// This is the one field that tells the two content-free cases apart, and
  /// nothing else on the contract can:
  ///
  ///  * **Android hid the message.** Redaction *empties* the values it is given
  ///    — the spike's own dump carries `"sender": ""`, `"title": ""` and
  ///    `"selfDisplayName": ""`, present and emptied, beside the marker text
  ///    (`messages-redaction.jsonl`, 21 September 2026). A sender is there; it
  ///    has no name.
  ///  * **The phone owner wrote it.** `MessagingStyle` marks the user's own
  ///    line by constructing the message with a null `Person`, so
  ///    `Message.toBundle()` writes neither `sender` nor `sender_person`. The
  ///    projection states that as `senderAbsent: true`.
  ///
  /// CAP-8 and INB-9 are the two rules that read it.
  final bool hasSender;

  final String? text;

  /// The time the posting app gave *this message*. Never trusted for a hidden
  /// message: one was observed moving 19 seconds between two reads of an
  /// unchanged notification (CAP-8).
  final DateTime? time;

  /// The data mime type, when the entry carried an attachment (CAP-9). Null
  /// for ordinary text.
  final String? type;

  /// A sender that is there and has no name: a name Android emptied (CAP-8).
  bool get senderEmptied => hasSender && (sender == null || sender!.isEmpty);

  /// No sender at all, which on a `MessagingStyle` history is how the phone
  /// owner's own line arrives (INB-9).
  bool get senderAbsent => !hasSender;

  /// Whether the entry carries nothing at all. Such an entry still holds its
  /// index, but there is nothing to file (CAP-15).
  bool get isBlank =>
      (sender == null || sender!.isEmpty) &&
      (text == null || text!.isEmpty) &&
      (type == null || type!.isEmpty);

  @override
  String toString() => 'CapturedMessage($sender, ${type ?? 'text'}, $time)';
}

/// One event, exactly as the contract defines it.
class CaptureEvent {
  const CaptureEvent({
    required this.type,
    this.sdkInt,
    this.release,
    this.key,
    this.package,
    this.tag,
    this.postTime,
    this.isOngoing = false,
    this.isGroupSummary = false,
    this.isClearable = false,
    this.groupKey,
    this.category,
    this.template,
    this.shortcutId,
    this.conversationTitle,
    this.isGroupConversation = false,
    this.title,
    this.text,
    this.selfDisplayName,
    this.messages = const <CapturedMessage>[],
    this.hasRemoteInput = false,
    this.removalReason = RemovalReason.other,
  });

  factory CaptureEvent.fromJson(Map<String, Object?> json) => CaptureEvent(
    type: CaptureEventType.fromName(json['event']),
    sdkInt: _int(json['sdkInt']),
    release: _string(json['release']),
    key: _string(json['key']),
    package: _string(json['package']),
    tag: _string(json['tag']),
    postTime: _time(json['postTime']),
    isOngoing: _bool(json['isOngoing']),
    isGroupSummary: _bool(json['isGroupSummary']),
    isClearable: _bool(json['isClearable']),
    groupKey: _string(json['groupKey']),
    category: _string(json['category']),
    template: _string(json['template']),
    shortcutId: _string(json['shortcutId']),
    conversationTitle: _string(json['conversationTitle']),
    isGroupConversation: _bool(json['isGroupConversation']),
    title: _string(json['title']),
    text: _string(json['text']),
    selfDisplayName: _string(json['selfDisplayName']),
    messages: _messages(json['messages']),
    hasRemoteInput: _bool(json['hasRemoteInput']),
    removalReason: RemovalReason.fromName(json['removalReasonName']),
  );

  /// Reads one line of a `.jsonl` dump or one element of `drainQueue()`.
  ///
  /// Returns null when the line is not a JSON object, so a corrupt queue row
  /// costs one event rather than the whole drain.
  static CaptureEvent? decode(String json) {
    try {
      final Object? value = jsonDecode(json);
      if (value is! Map) return null;
      return CaptureEvent.fromJson(value.cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  final CaptureEventType type;

  /// The API level and release the event was captured on. Recorded, never
  /// branched on here: a rule that states what Android hides names its level
  /// itself (CAP-25).
  final int? sdkInt;
  final String? release;

  /// The notification key. With a message's history index it is that message's
  /// identity (CAP-5), and it is the conversation key of last resort (CAP-3).
  final String? key;

  final String? package;
  final String? tag;

  /// When the phone posted the notification. The arrival time of a hidden
  /// message (CAP-8) and of a raw one (CAP-21), neither of which has a message
  /// history to read a time from (INB-4).
  final DateTime? postTime;

  final bool isOngoing;
  final bool isGroupSummary;
  final bool isClearable;

  /// Recorded and never used as a conversation key: one `groupKey` covered
  /// three separate threads in the spike's dumps, and one changed between a
  /// notification's post and its removal (CAP-3).
  final String? groupKey;

  final String? category;
  final String? template;

  final String? shortcutId;
  final String? conversationTitle;
  final bool isGroupConversation;

  final String? title;
  final String? text;

  /// What the posting app calls the user. Empty on a redacted notification,
  /// which is one third of CAP-8's structural test.
  final String? selfDisplayName;

  /// The history, in order: element *i* is history index *i* (CAP-5).
  final List<CapturedMessage> messages;

  /// Whether the notification itself carries a `RemoteInput`. Nothing stores
  /// it: a `PendingIntent` cannot be serialised, so whether a conversation can
  /// be replied to is a property of this run and not of a row (CAP-14, CAP-15).
  final bool hasRemoteInput;

  /// Meaningful only on a removal (CAP-22).
  final RemovalReason removalReason;

  /// CAP-2's gate. A notification of any other template is never guessed into
  /// a sender and a text.
  bool get isMessagingStyle => template == messagingStyleTemplate;

  @override
  String toString() =>
      'CaptureEvent(${type.name}, $package, ${messages.length} messages)';
}

/// A string, or absent. A value of another type is read as absent rather than
/// stringified: `"1024"` as a sender would be the app inventing content.
String? _string(Object? value) => value is String ? value : null;

/// The name inside a projected `Person`, or null when it carries none.
///
/// Null here never means "no sender": a `Person` whose name the projection
/// could not read is still a sender the notification carried, which is what
/// `CapturedMessage.hasSender` records separately.
String? _personName(Object? value) {
  if (value is String) return value;
  if (value is Map) return _string(value.cast<String, Object?>()['name']);
  return null;
}

/// Absent reads as false, which is what every boolean in the contract means
/// when `org.json` has dropped it. A number reads as SQLite reads one, so a
/// channel that flattens a bool to 0/1 does not silently turn a group summary
/// into a message.
bool _bool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return false;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// The furthest from the epoch a `DateTime` will go: 100,000,000 days, in
/// milliseconds. Beyond it `DateTime.fromMillisecondsSinceEpoch` throws.
const int _maxMillisecondsSinceEpoch = 8640000000000000;

/// Milliseconds since the epoch, kept in UTC like every other stored instant
/// (REC-1). Absent stays absent: the caller decides what an event with no time
/// is worth, because that is a rule, not a parse.
///
/// A number too large to be an instant is absent too. The count is a field of
/// another app's notification, so any included app can put `9e18` in it, and an
/// unguarded conversion would throw out of `fromJson` — past the `decode` that
/// catches only `FormatException`, and so past the drain. The queue row that
/// carried it is deleted in the transaction that writes its message (CAP-15),
/// which never happens, so the same row throws on every later drain until the
/// 30-day drop: one hostile notification would cost the user 30 days of that
/// row. Absent is a value every caller already handles by falling back to the
/// notification's post time or to ours (CAP-8, CAP-21, INB-4).
DateTime? _time(Object? value) {
  final int? ms = _int(value);
  // Compared at both ends rather than by `abs()`, which is its own argument
  // for the most negative int there is.
  if (ms == null ||
      ms < -_maxMillisecondsSinceEpoch ||
      ms > _maxMillisecondsSinceEpoch) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

List<CapturedMessage> _messages(Object? value) {
  if (value is! List) return const <CapturedMessage>[];
  return value.map(CapturedMessage.fromJson).toList(growable: false);
}
