/// The rule engine: one captured notification in, stored rows out.
///
/// Pure Dart over a [Repository] — no Flutter binding, no platform channel, no
/// `MethodChannel` import — so the spike's own dumps in
/// `docs/research/spike-dumps/` can be replayed through it exactly as the
/// listener would deliver them. Everything platform-shaped lives on the other
/// side of [CaptureEvent].
///
/// Every decision returns an [IngestOutcome] naming the rule that made it. A
/// drop is a result, not a silent return: the Permissions screen has to be
/// able to say what happened to a notification the user watched arrive, and a
/// test that cannot tell "dropped because the app is off" from "dropped
/// because it was an ongoing status" is not testing CAP-1 (product principle
/// 3).
///
/// The caller's drain order matters and is not this class's to enforce: the
/// seen-apps rows are written **before** the enabled set is handed back down,
/// or a stale set would undo a shipped-app default the listener has just
/// applied (CAP-1, INB-20).
library;

import '../data/shipped_apps.dart';
import '../db/repository.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/record.dart';
import '../models/source_app.dart';
import 'capture_event.dart';

/// What the engine did with one event.
enum IngestAction {
  /// At least one message was written.
  stored,

  /// The event was understood and every message in it was already stored
  /// (CAP-5) — what a re-post or a reconnection re-read produces.
  duplicate,

  /// A rule refused it. [IngestOutcome.rule] says which.
  dropped,

  /// A conversation's read marker moved (CAP-22).
  markedRead,

  /// The listener bound or went away (CAP-12).
  sessionOpened,
  sessionClosed,

  /// Understood, and correctly changed nothing: an event shape the contract
  /// does not define, or a removal whose reason means nothing (CAP-22).
  ignored,
}

/// What happened to one event, and which rule decided it.
class IngestOutcome {
  const IngestOutcome({
    required this.action,
    required this.rule,
    this.conversationId,
    this.messagesStored = 0,
    this.revived = false,
  });

  final IngestAction action;

  /// The rule ID that decided this, as it appears in `docs/PRODUCT_RULES.md`.
  final String rule;

  /// The thread the event landed in, where it reached one.
  final String? conversationId;

  /// How many rows were actually written — not how many the notification
  /// carried, which for a re-post is the same number with nothing new in it.
  final int messagesStored;

  /// Whether this event brought a conversation the user had deleted back
  /// (CAP-23). The messages deleted with it stayed deleted.
  final bool revived;

  @override
  bool operator ==(Object other) =>
      other is IngestOutcome &&
      other.action == action &&
      other.rule == rule &&
      other.conversationId == conversationId &&
      other.messagesStored == messagesStored &&
      other.revived == revived;

  @override
  int get hashCode =>
      Object.hash(action, rule, conversationId, messagesStored, revived);

  @override
  String toString() =>
      'IngestOutcome(${action.name}, $rule, stored: $messagesStored'
      '${revived ? ', revived' : ''})';
}

/// Turns captured notifications into stored conversations and messages.
class CaptureIngest {
  CaptureIngest(this._repository, {DateTime Function()? clock})
    : _clock = clock ?? _systemClock;

  final Repository _repository;

  /// The capture clock. Injected because REC-1's `created_at` and CAP-5's
  /// `sent_at` are different instants and the only way to assert that in a
  /// test is to control one of them.
  final DateTime Function() _clock;

  static DateTime _systemClock() => DateTime.now().toUtc();

  /// Applies events in order, and in order on purpose: dedup (CAP-5), revival
  /// (CAP-23) and the read marker (CAP-22) all depend on what the events
  /// before them wrote.
  Future<List<IngestOutcome>> applyAll(Iterable<CaptureEvent> events) async {
    final List<IngestOutcome> outcomes = <IngestOutcome>[];
    for (final CaptureEvent event in events) {
      outcomes.add(await apply(event));
    }
    return outcomes;
  }

  Future<IngestOutcome> apply(CaptureEvent event) async {
    switch (event.type) {
      // CAP-12: the app's account of what it could see is these two rows and
      // nothing else, so they are written before any filtering — a session
      // belongs to the listener, not to a package.
      case CaptureEventType.listenerConnected:
        // A bind while a session is already open changes nothing, and says so.
        // A device bound the listener thirty times in one sitting — revoke and
        // grant, `am start -S`, force-stop, reboot — and every one of them
        // inserted a row, so the table held thirty sessions and thirty null end
        // times (drill, 21 September 2026). Reporting the no-op as
        // `sessionOpened` would also spend INB-25's second reloading a screen
        // for a row that was not written.
        final bool opened = await _repository.openCaptureSession(
          event.postTime ?? _clock(),
        );
        return IngestOutcome(
          action: opened ? IngestAction.sessionOpened : IngestAction.ignored,
          rule: 'CAP-12',
        );
      case CaptureEventType.listenerDisconnected:
        // Closed with the event's own time where it has one. Nothing here
        // substitutes the moment we noticed for the moment it happened; a loss
        // found on a resume is PERM-9's job and carries its own estimate flag.
        await _repository.closeCaptureSession(event.postTime ?? _clock());
        return const IngestOutcome(
          action: IngestAction.sessionClosed,
          rule: 'CAP-12',
        );
      case CaptureEventType.unknown:
        // The queue holds only the four events the contract defines (CAP-15).
        // Anything else is a line we do not understand, and guessing at one is
        // how an app files a delivery notice as a message.
        return const IngestOutcome(
          action: IngestAction.ignored,
          rule: 'CAP-15',
        );
      case CaptureEventType.posted:
      case CaptureEventType.removed:
        break;
    }

    final String? package = event.package;
    if (package == null || package.isEmpty) {
      return const IngestOutcome(action: IngestAction.dropped, rule: 'CAP-1');
    }

    // CAP-1, a second time. The listener already dropped this natively, but
    // the queue can hold rows enqueued before the user moved a switch, and a
    // message captured from an app the user switched off is exactly the
    // failure that costs the app its permission (product principle 4).
    final SourceApp? app = await _repository.appByPackage(package);
    // No row at all means the listener has never recorded this package, which
    // only happens ahead of the seen-apps write. CAP-1's default is the
    // shipped list, so that is the answer — and inventing an `apps` row here
    // would invent a label the app has not been given (INB-20).
    final bool enabled = app?.enabled ?? isShippedMessagingApp(package);
    if (!enabled) {
      return const IngestOutcome(action: IngestAction.dropped, rule: 'CAP-1');
    }

    if (event.type == CaptureEventType.removed) {
      return _applyRemoval(event);
    }
    return _applyPosted(event, package, app);
  }

  // --- posted -----------------------------------------------------------

  Future<IngestOutcome> _applyPosted(
    CaptureEvent event,
    String package,
    SourceApp? app,
  ) async {
    // CAP-6: every group summary the spike captured carried an empty history,
    // so its children hold the content and this one holds nothing.
    if (event.isGroupSummary) {
      return const IngestOutcome(action: IngestAction.dropped, rule: 'CAP-6');
    }
    // CAP-7: a status is not something anyone is waiting on a reply to.
    if (event.isOngoing) {
      return const IngestOutcome(action: IngestAction.dropped, rule: 'CAP-7');
    }

    final String? key = event.key;
    if (key == null || key.isEmpty) {
      // Without a key a message has no identity (CAP-5), and every keyless
      // message would share the one `('', 0)` slot in the notification index —
      // so the first would swallow all the rest. Losing one unidentifiable
      // event is the smaller harm.
      return const IngestOutcome(action: IngestAction.dropped, rule: 'CAP-5');
    }

    // CAP-2's gate, both halves of it: the template says this is a
    // conversation, and the history is what a message is read from. Anything
    // else is never guessed into a sender and a text.
    if (event.isMessagingStyle && event.messages.isNotEmpty) {
      return _applyHistory(event, package, key);
    }
    // CAP-21: an included app's notification with no history is still kept
    // when its category says it is a message.
    if (_rawCategories.contains(event.category)) {
      return _applyRaw(event, package, key, app);
    }
    return const IngestOutcome(action: IngestAction.dropped, rule: 'CAP-2');
  }

  /// The MessagingStyle path: every entry in the history becomes its own
  /// message (CAP-4).
  Future<IngestOutcome> _applyHistory(
    CaptureEvent event,
    String package,
    String key,
  ) async {
    final DateTime postTime = event.postTime ?? _clock();
    final List<_Entry> entries = <_Entry>[];

    for (int index = 0; index < event.messages.length; index++) {
      final CapturedMessage entry = event.messages[index];
      // An entry carrying nothing is nothing to file. The index comes from the
      // position in the list and not from this loop's output, so skipping one
      // never shifts another message's identity (CAP-5).
      if (entry.isBlank) continue;

      final bool hidden = _isHidden(event, entry);
      final MessageKind kind = hidden
          ? MessageKind.hidden
          : (_attachmentKind(entry.type) ?? MessageKind.text);
      // Where this message's time is about to come from, which is what decides
      // whether CAP-5 may match on it. A hidden message never uses its own
      // time; everything else uses it when the entry carried a readable one.
      final bool fromPostTime = hidden || entry.time == null;

      entries.add((
        index: index,
        kind: kind,
        // CAP-8: redaction empties the sender, and the app does not guess at
        // who wrote a message it was not shown.
        sender: hidden ? '' : (entry.sender ?? ''),
        // Null for every kind that cannot carry text, which is what keeps the
        // system's marker string out of the column (CAP-8, CAP-9).
        text: kind.carriesText ? entry.text : null,
        // CAP-8: a hidden message takes the notification's post time, because
        // its own time was observed moving 19 seconds between two reads of one
        // unchanged notification. An ordinary message keeps the time its app
        // gave it, and falls back to the post time only when it has none —
        // there is no other honest instant, and INB-4 has to sort it.
        sentAt: fromPostTime ? postTime : entry.time!,
        timeSource: fromPostTime ? TimeSource.post : TimeSource.entry,
        // A hidden message is inbound, and that is INB-5's own choice rather
        // than this engine's: the rule counts a hidden message in the unread
        // badge by its `postTime`, which it can only do if the message has a
        // side. Redaction hides who wrote the line as thoroughly as it hides
        // what it said, so this is the one place the app files a direction it
        // was not told - and the rule it is filed for is the one that asked.
        direction: hidden ? Direction.inbound : _direction(event, entry),
      ));
    }

    if (entries.isEmpty) {
      return const IngestOutcome(action: IngestAction.dropped, rule: 'CAP-2');
    }

    // INB-4: the thread's place in the list is its newest message's arrival
    // time, and a burst delivers five of them under one timestamp, so this is
    // a max and not "the last one".
    DateTime newest = entries.first.sentAt;
    for (final _Entry entry in entries) {
      if (entry.sentAt.isAfter(newest)) newest = entry.sentAt;
    }

    final _ResolvedKey resolved = _resolveKey(event, key);
    final DateTime now = _clock();

    final ({Conversation conversation, bool revived})
    upserted = await _repository.upsertConversation(
      package: package,
      conversationKey: resolved.key,
      keySource: resolved.source,
      // conversationTitle, else the notification's title, else empty —
      // and empty is a real value, not a failure: redaction leaves a good
      // key with no name at all, which is the branch INB-2 draws.
      title: _nonEmpty(event.conversationTitle) ?? _nonEmpty(event.title) ?? '',
      isGroup: event.isGroupConversation,
      lastMessageAt: newest,
      at: now,
      // The candidates are stored beside the resolved key so an app that
      // changes its keying is migrated rather than split silently (CAP-3).
      // Emptied and absent are one value here, because CAP-3 says a `""` is a
      // field redaction emptied and so no candidate at all.
      //
      // [_present] and not [_nonEmpty], the same predicate [_resolveKey] reads
      // its candidates with — these columns are the record of what that
      // resolver saw, and a column that disagreed with the key beside it would
      // be a stored row lying about its own identity, which is the one thing a
      // keying migration reads first (CAP-3).
      shortcutId: _present(event.shortcutId),
      conversationTitle: _present(event.conversationTitle),
      tag: _present(event.tag),
    );

    // The whole history goes down in one call, and it has to. CAP-5 identifies
    // a message inside one notification key by aligning the incoming history
    // against the stored one as a sequence, and a sequence cannot be assembled
    // one entry at a time: a repository handed a single "?" cannot tell a second
    // "?" from a re-post of the first, and cannot see that the entry before it
    // is the line a sliding window moved. Every entry of this event, in the
    // order the notification carried them, is the input the rule needs.
    final List<({bool wrote, String id})> results = await _repository
        .insertMessagesIfNew(<Message>[
          for (final _Entry entry in entries)
            Message(
              id: newId(),
              conversationId: upserted.conversation.id,
              sender: entry.sender,
              sentAt: entry.sentAt,
              kind: entry.kind,
              direction: entry.direction,
              sendState: SendState.sent,
              notificationKey: key,
              historyIndex: entry.index,
              timeSource: entry.timeSource,
              text: entry.text,
              // The capture time. CAP-5 matches on `sent_at`, which the
              // posting app gave us; this is ours, and the two are never the
              // same field.
              createdAt: now,
              updatedAt: now,
            ),
        ]);
    int stored = 0;
    for (final ({bool wrote, String id}) result in results) {
      if (result.wrote) stored++;
    }

    return IngestOutcome(
      action: stored > 0 ? IngestAction.stored : IngestAction.duplicate,
      rule: 'CAP-4',
      conversationId: upserted.conversation.id,
      messagesStored: stored,
      revived: upserted.revived,
    );
  }

  /// CAP-21: no history, but a category that says this was a message. One
  /// `raw` row in a conversation keyed by the package alone.
  Future<IngestOutcome> _applyRaw(
    CaptureEvent event,
    String package,
    String key,
    SourceApp? app,
  ) async {
    final String? title = _nonEmpty(event.title);
    final String? text = _nonEmpty(event.text);
    // Nothing to show. INB-12 renders a raw message as the notification's own
    // title and text, and a blank note under a standing explanation reads as a
    // bug rather than as a limit (product principle 3).
    if (title == null && text == null) {
      return const IngestOutcome(action: IngestAction.dropped, rule: 'CAP-21');
    }

    // CAP-8 reaches this path too, and it has to: Android redacts a
    // notification whatever its template, so a redacted one that is not
    // MessagingStyle lands here with the system's marker string sitting in
    // `text`. Written as a raw message that string becomes searchable (CAP-19)
    // and is drawn to the user as though a person had sent it — and
    // `docs/privacy-policy.md` promises the placeholder is not stored (CAP-27).
    // So the same structural test runs here, and the row is stored hidden with
    // no text at all.
    final bool hidden = _isRawHidden(event);

    final DateTime postTime = event.postTime ?? _clock();
    final DateTime now = _clock();

    final ({Conversation conversation, bool revived}) upserted =
        await _repository.upsertConversation(
          package: package,
          // The package alone, which is what keeps a raw conversation from
          // ever merging with one keyed by CAP-3 (CAP-21, INB-12).
          conversationKey: package,
          // CAP-3 stores the field the key came from, so it says `package`:
          // the key in the column beside it *is* the package, and claiming
          // `notificationKey` here would be a stored row saying something
          // untrue about itself — the one thing the keying migration CAP-3
          // exists for would read first.
          keySource: KeySource.package,
          // Labelled with the app (CAP-21, INB-12). Empty only when the
          // listener has not recorded a label yet, which INB-1's fallback
          // covers by showing the package name.
          title: app?.label ?? '',
          isGroup: false,
          lastMessageAt: postTime,
          at: now,
        );

    // The notification's title and text are kept in separate columns because
    // INB-12 joins them from the message files at render time, and a join
    // baked in at capture would be one language's join stored forever
    // (LANG-2). `sender` is the only other column CAP-15 keeps, and INB-12
    // draws a raw message as a full-width note, never as a bubble attributed
    // to whoever is in it.
    final ({bool wrote, String id}) result = await _repository
        .insertMessageIfNew(
          Message(
            id: newId(),
            conversationId: upserted.conversation.id,
            // Redaction empties the title as well, and the app does not guess
            // at who wrote a message it was not shown (CAP-8).
            sender: hidden ? '' : (title ?? ''),
            // No history means no time of its own, so the notification's post
            // time is the arrival time (INB-4) — which is also the only time
            // CAP-8 lets a hidden message use.
            sentAt: postTime,
            // And so a time CAP-5 must not match on: Android moves `postTime`
            // on every enqueue, including the in-place update an app makes when
            // it re-posts "2 new notifications". Matched on it, one row became
            // one more row on every re-post, forever.
            timeSource: TimeSource.post,
            kind: hidden ? MessageKind.hidden : MessageKind.raw,
            direction: Direction.inbound,
            sendState: SendState.sent,
            notificationKey: key,
            historyIndex: 0,
            // Null for a hidden message, which is what keeps the marker out of
            // `text` and out of `text_normalised` (CAP-8).
            text: hidden ? null : text,
            createdAt: now,
            updatedAt: now,
          ),
        );

    return IngestOutcome(
      action: result.wrote ? IngestAction.stored : IngestAction.duplicate,
      rule: 'CAP-21',
      conversationId: upserted.conversation.id,
      messagesStored: result.wrote ? 1 : 0,
      revived: upserted.revived,
    );
  }

  // --- removed ----------------------------------------------------------

  /// CAP-22: a removal is a signal about the source app, never a change to our
  /// data. Nothing is deleted here and nothing is hidden (CAP-11).
  Future<IngestOutcome> _applyRemoval(CaptureEvent event) async {
    // Only CLICK and APP_CANCEL. The shade being cleared is not the user
    // reading anything, and an unrecognised reason is treated as one of those
    // rather than guessed at.
    if (!event.removalReason.marksRead) {
      return const IngestOutcome(action: IngestAction.ignored, rule: 'CAP-22');
    }

    final String? key = event.key;
    if (key == null || key.isEmpty) {
      return const IngestOutcome(action: IngestAction.ignored, rule: 'CAP-22');
    }

    // "That notification's newest message" has to be read from what was
    // stored: every removal in the spike's dumps arrived with its message
    // history already emptied, and the removal's own `groupKey` was seen to
    // differ from the one its post carried (CAP-3), so the stored rows are the
    // only reliable link back to a conversation.
    final ({String conversationId, DateTime sentAt})? newest = await _repository
        .newestMessageForNotification(key);
    if (newest == null) {
      return const IngestOutcome(action: IngestAction.ignored, rule: 'CAP-22');
    }

    final bool moved = await _repository.markReadThrough(
      conversationId: newest.conversationId,
      through: newest.sentAt,
      at: _clock(),
    );
    // Not moving is a real and correct outcome: a late APP_CANCEL on an older
    // notification never un-reads newer messages (CAP-22, INB-5).
    return IngestOutcome(
      action: moved ? IngestAction.markedRead : IngestAction.ignored,
      rule: 'CAP-22',
      conversationId: newest.conversationId,
    );
  }

  // --- rules over one notification --------------------------------------

  /// CAP-3, in order. `groupKey` is not a candidate and never will be: one
  /// covered three separate threads in the spike's dumps.
  ///
  /// Reads its candidates with [_present] and never with [_nonEmpty] — see
  /// [_present] for why the difference is a stored conversation's identity.
  _ResolvedKey _resolveKey(CaptureEvent event, String notificationKey) {
    // Which of shortcutId and conversationTitle wins is provisional (CAP-25):
    // no notification the spike captured carried both.
    final String? shortcutId = _present(event.shortcutId);
    if (shortcutId != null) {
      return (key: shortcutId, source: KeySource.shortcutId);
    }
    final String? conversationTitle = _present(event.conversationTitle);
    if (conversationTitle != null) {
      return (key: conversationTitle, source: KeySource.conversationTitle);
    }
    final String? tag = _present(event.tag);
    if (tag != null) {
      return (key: tag, source: KeySource.tag);
    }
    // Keyed by its own notification key, and so never merged into another
    // thread — which is the point, not a fallback that happens to work.
    return (key: notificationKey, source: KeySource.notificationKey);
  }

  /// CAP-8, read from the structure and never from the marker text, which is a
  /// system string that changes with the phone's language.
  ///
  /// The test the rule states is that the message's sender, the notification's
  /// title and its `selfDisplayName` are all empty while the text is not. What
  /// it left open, and what destroyed messages, is what "empty" means for the
  /// sender. Read as "empty or absent", this predicate fired on a line the
  /// *user* wrote: `MessagingStyle` marks the phone owner's own message by
  /// constructing it with a null `Person`, so its sender key is absent, and
  /// INB-2 says a real notification can carry an empty title — the spike's own
  /// redacted dump does. The line was then stored hidden, its text dropped for
  /// good, and shown to the user as something their phone had hidden from them.
  ///
  /// The discriminator is the same one CAP-21's path already uses for the
  /// title, on the same evidence: **redaction empties a value, it does not drop
  /// the key.** The spike's redacted notification carries `"sender": ""` beside
  /// the marker (`messages-redaction.jsonl`, 21 September 2026) — present, and
  /// with no name in it. The user's own line carries no sender key at all.
  /// `org.json` drops a null key entirely, so the two arrive as different
  /// values and [CapturedMessage.hasSender] keeps them apart.
  ///
  /// The residual runs the safe way, which is the only way it is allowed to
  /// run: a redacted notification whose sender key arrived *absent* rather than
  /// emptied would be kept as an ordinary message, marker text and all. That
  /// costs one system string in a row the user can read and delete. Reading it
  /// the other way costs a message the app was handed and can never get back,
  /// and destroying one of those is the worse error every time (CAP-5's
  /// correction, 21 September 2026).
  ///
  /// **Correction, 22 September 2026.** The name fields are read with
  /// [_emptiedOrAbsent] and not with [_nonEmpty], because those answer two
  /// different questions and only one of them is CAP-8's. INB-2 asks "is there
  /// a name to draw?", so it folds a title of one space to nothing — correctly:
  /// a space draws as a blank row. This asks "did Android empty this field?",
  /// and a title of one space is a title that was *present*. Both are true of
  /// the same notification and they are not in conflict. Sharing [_nonEmpty]
  /// between them made a MessagingStyle notification with a title of `" "`, an
  /// emptied sender and real words classify as hidden: the words were stored as
  /// null and the user was told their phone had hidden a message it had not
  /// hidden. That is the destructive direction this predicate is not allowed to
  /// err in.
  bool _isHidden(CaptureEvent event, CapturedMessage entry) =>
      entry.senderEmptied &&
      _emptiedOrAbsent(event.title) &&
      _emptiedOrAbsent(event.selfDisplayName) &&
      // The text stays on INB-2's reading, and it is the one place here that
      // should be: "while its text is not empty" is asking whether there is
      // anything worth keeping, and a text of one space is not. Being stricter
      // here only ever classifies fewer messages as hidden, which is the safe
      // direction (CAP-8).
      _nonEmpty(entry.text) != null;

  /// CAP-8 on CAP-21's path, where there is no message history to read.
  ///
  /// Structural for the same reason: the marker is a system string that changes
  /// with the phone's language, so matching it would be a rule that works in
  /// English. The evidence here is the title Android *emptied* — `""` present,
  /// not absent, which is what a redacted notification carried in the spike's
  /// fixture (`messages-redaction.jsonl`) and what the projection preserves,
  /// since `org.json` drops a null key entirely. An absent title is not
  /// evidence of anything: plenty of honest notifications never set one, and
  /// treating those as hidden would throw away exactly the content CAP-21
  /// exists to keep.
  ///
  /// `selfDisplayName` is tested the way CAP-8 tests it, as "carries no name":
  /// only a MessagingStyle notification sets it at all, so on this path it is
  /// usually absent and it is the title that decides.
  ///
  /// The residual, stated rather than papered over: a redacted notification
  /// whose title arrives absent instead of emptied is indistinguishable from an
  /// ordinary untitled one, and is kept as a raw message (CAP-25 — this is
  /// measured on one app at one API level).
  ///
  /// **Correction, 22 September 2026.** Both halves of CAP-8 now read "emptied"
  /// the same way, through [_emptied] and [_emptiedOrAbsent]: a field Android
  /// emptied holds nothing at all, and a field holding a space is a field the
  /// app filled in. The literal `event.title == ''` written here was already
  /// that reading; [_isHidden] had drifted off it, so one notification shape
  /// could be hidden on this path and not on that one. The two paths still
  /// differ in what *absence* buys, and deliberately: here the title is the
  /// only evidence there is, so an absent one proves nothing, while on the
  /// history path the emptied sender is the discriminator and the title only
  /// corroborates it.
  bool _isRawHidden(CaptureEvent event) =>
      _emptied(event.title) &&
      _emptiedOrAbsent(event.selfDisplayName) &&
      _nonEmpty(event.text) != null;

  /// CAP-9: an attachment is stored as its type code, never as the rendered
  /// words. Null means the entry is ordinary text.
  MessageKind? _attachmentKind(String? type) {
    final String? mime = _nonEmpty(type)?.toLowerCase();
    if (mime == null) return null;
    if (mime.startsWith('image/')) return MessageKind.image;
    if (mime.startsWith('audio/')) return MessageKind.voice;
    if (mime.startsWith('video/')) return MessageKind.video;
    // Anything else says only that something arrived the app cannot show,
    // which is exactly what INB-11 renders for `other`. No attachment was
    // captured in the spike, so mapping, say, `application/*` to `file` would
    // be a guess dressed as a type code (CAP-9, provisional under CAP-25).
    return MessageKind.other;
  }

  /// INB-9: direction is read from the history and never assumed, and where it
  /// cannot be decided it is [Direction.unknown] rather than a guess.
  ///
  /// `MessagingStyle` has two ways of saying the phone owner wrote a line, and
  /// the old reading of this rule could only see one of them. It compared the
  /// entry's sender against `selfDisplayName` — which catches an app that names
  /// the user on their own messages, and catches nothing at all on the
  /// platform's documented convention, which is to construct the user's message
  /// with a **null** `Person`. `Message.toBundle()` then writes neither sender
  /// key, so the sender arrives absent, an absent sender equals nothing, and
  /// the branch was unreachable for exactly the messages it existed to catch.
  /// Every message the user had sent was stored inbound, with an empty sender,
  /// and counted in their own unread badge (INB-5).
  ///
  /// So, in order:
  ///
  ///  * **No sender key at all, and the notification names the user.** The
  ///    platform's convention, from an app that is following it — it built a
  ///    `MessagingStyle` with a user to name. Outbound.
  ///  * **No sender key, and no `selfDisplayName` either.** The same shape from
  ///    an app that told us nothing about the user, so the convention cannot be
  ///    read into it. Unknown.
  ///  * **A sender with a name.** Outbound when it is the name the notification
  ///    gives the user, inbound otherwise.
  ///  * **A sender with no name** — redaction emptied it. There is nothing to
  ///    compare and nothing to conclude. Unknown.
  ///
  /// Unknown loses to safety in both directions: the message is drawn with no
  /// side and no sender, and it is counted in no unread badge (INB-9, INB-5).
  /// How each target app marks its own lines is still unmeasured — no dump
  /// holds one — so this stays provisional under CAP-25.
  Direction _direction(CaptureEvent event, CapturedMessage entry) {
    final String? self = _nonEmpty(event.selfDisplayName);
    if (entry.senderAbsent) {
      return self != null ? Direction.outbound : Direction.unknown;
    }
    final String? sender = _nonEmpty(entry.sender);
    if (sender == null) return Direction.unknown;
    return self != null && sender == self
        ? Direction.outbound
        : Direction.inbound;
  }
}

/// CAP-21's three categories, and only these three.
const Set<String> _rawCategories = <String>{'msg', 'social', 'email'};

/// INB-2's question: **is there a name to draw?**
///
/// A value with nothing visible in it is an absence: a title of one space or
/// one zero-width space is not a name, and storing it as one puts a blank row
/// on screen — the gap INB-2 exists to close. So this folds anything [isBlank]
/// calls blank, and it is the predicate every field read for display or for
/// comparison goes through: the title, a raw notification's title and text, an
/// attachment's MIME type, the names INB-9 compares to decide a direction.
///
/// It is **not** CAP-3's question. See [_present].
String? _nonEmpty(String? value) =>
    (value == null || isBlank(value)) ? null : value;

/// CAP-3's question: **did the notification supply this candidate at all?**
///
/// `""` or absent, literally, which is what CAP-3 says: redaction empties a
/// title field, so an emptied one is no candidate and the app cannot tell an
/// emptied field from one that was never set (INB-2). A value that merely
/// *draws* as nothing — one space, one zero-width space — is a value the app
/// chose to send and a perfectly serviceable identifier, because a key's job is
/// identity and not display. Nothing renders it; it is matched against.
///
/// **Correction, 22 September 2026.** This was [_nonEmpty] until INB-2 widened
/// that one to [isBlank], and the widening silently took CAP-3's resolver with
/// it. A conversation already stored under a key of one space — resolved from a
/// blank `shortcutId`, `conversationTitle` or `tag` — would, on its next
/// notification, resolve to the notification key instead and open a **second
/// thread** beside the first, with the user's history sitting in the one they
/// can no longer reach. CAP-3 is explicit that a keying change is migrated
/// rather than split silently, and the candidate columns exist for exactly that
/// migration; nothing would have caught this one, because the change was in the
/// resolver rather than in an app.
///
/// Splitting the predicate is the fix and not a migration, deliberately: it
/// restores the resolver to the behaviour CAP-3 has always described, so no
/// stored `conversation_key` ever resolved differently and there is nothing to
/// migrate. A migration would have had to rewrite keys that were never wrong.
String? _present(String? value) =>
    (value == null || value.isEmpty) ? null : value;

/// CAP-8's question, which is not [_nonEmpty]'s.
///
/// [_nonEmpty] asks whether there is a name to draw, so it folds anything that
/// draws as nothing — a space, a zero-width space — to absence. This asks
/// whether **Android emptied the field**, which is a question about what
/// arrived and not about what it looks like: redaction replaces a value with
/// `""`, and `org.json` drops a null key entirely, so an emptied field is
/// present and holds no character at all.
///
/// A space is therefore not emptied. It is a value some app chose to send, and
/// the only honest thing to conclude from it is that the notification was not
/// redacted. Folding the two questions into one predicate is what destroyed
/// message text (CAP-8's correction, 22 September 2026), so they stay apart:
/// the same notification can carry a title with no name to draw (INB-2) and a
/// title that was plainly present (CAP-8), and both readings are right.
bool _emptied(String? value) => value == '';

/// [_emptied], or the key never arrived. Used where an emptied field only
/// corroborates evidence that is carried by another field, and so where
/// absence is allowed to count as "carries no name" (CAP-8).
bool _emptiedOrAbsent(String? value) => value == null || _emptied(value);

typedef _ResolvedKey = ({String key, KeySource source});

/// One message the engine has decided to store, with the history index it will
/// keep (CAP-5).
typedef _Entry = ({
  int index,
  MessageKind kind,
  String sender,
  String? text,
  DateTime sentAt,
  TimeSource timeSource,
  Direction direction,
});
