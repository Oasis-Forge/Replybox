# Spike dumps

Raw notification captures, one JSON object per line, kept as evidence rather than
as prose: `test/capture_fixture_test.dart` replays these files through the real
ingest engine, so a rule that stops matching what a phone actually wrote fails a
test instead of quietly drifting.

**Two different projections wrote the files in this folder, and they are not
interchangeable.** Read the table before adding an assertion to either kind.

| Dump | Written by | Date | sdkInt / release |
|---|---|---|---|
| `shell-burst.jsonl` | the throwaway debug spike (`android/app/src/debug/.../spike/SpikeListenerService.kt`) | 21 Sep 2026 | 37 / 17 |
| `messages-redaction.jsonl` | the throwaway debug spike | 21 Sep 2026 | 37 / 17 |
| `messages-reply-after-dismissal.jsonl` | the throwaway debug spike | 21 Sep 2026 | 37 / 17 |
| `2026-09-21-shipped-projection.jsonl` | **the shipped projection** (`capture/NotificationProjection.kt`), via `CaptureQueue` | 21 Sep 2026 | 37 / 17 |
| `2026-09-21-shipped-projection-evening.jsonl` | **the shipped projection**, via `CaptureQueue` | 21 Sep 2026 (evening) | 37 / 17 |
| `2026-09-21-raw-shapes.jsonl` | the throwaway debug spike, driven by `SpikeRawPoster` | 21 Sep 2026 (evening) | 37 / 17 |
| `2026-09-21-alignment-night.jsonl` | **the shipped projection**, via `CaptureQueue` | 21 Sep 2026 (night) | 37 / 17 |

Device for all seven: `emulator-5554`, `sdk_gphone16k_x86_64`, Android 17, API 37.
No physical phone. Every phone number in them is a `555-…` emulator number and
every message body was typed for the test; nothing here is anyone's real data.

## The three spike dumps

The spike's projection dumped far more than the app keeps — `id`, `flags`,
`channelId`, `when`, `bigText`, the whole `actions` array — and it wrote to
world-readable external storage. It is scaffolding for deciding the capture
rules (see `docs/research/spike.md`), and it no longer runs in any build the
listener is enabled in.

Because it is a *different* projection, these dumps carry fields the shipped one
does not emit, and they are missing `senderAbsent`, which the shipped one always
emits and which is how the phone owner's own line is told apart from a redacted
one. Dart reads an absent `senderAbsent` as "this fixture predates the flag",
never as `false`, so they keep replaying unchanged — but they cannot, on their
own, prove that the shipped projection emits what the Dart engine reads.

## `2026-09-21-shipped-projection.jsonl`

Written by the code that ships, pulled straight off
`files/capture-queue.jsonl` during the device drill of 21 September 2026. It
closes the gap above: these are the exact bytes the shipped listener handed to
Dart.

29 lines, in the order they were queued: 8 `listener_connected`, 15 `posted`,
6 `removed`. The re-drive of the evening of 21 September 2026 pulled more of the
same projection off the same device; those went into
`2026-09-21-shipped-projection-evening.jsonl` rather than being appended here,
because `test/capture_fixture_test.dart` asserts on this file's exact contents
and seven of its assertions key on these 29 lines. What they cover:

- Google Messages `MessagingStyle` over real SMS, with 1, 3, 4 and 5 entries in
  one notification's history — the burst-collapse case, against a real app.
- **A history entry the phone's owner wrote.** Replying inline from the shade
  made Google Messages append the reply with a null `Person`, and the shipped
  projection emitted `{"senderAbsent":true,"text":…}` with no `sender` key at
  all. This is the only recorded evidence that Android really does write neither
  sender key for the owner's own line, which is the assumption CAP-8's and
  INB-5's correction of 21 September 2026 rests on.
- **A redacted one-time-code SMS**, captured with OTP redaction on by default at
  API 37: `title` `""`, `selfDisplayName` `""`, the entry's `sender` `""`,
  `senderAbsent` **false**, and the marker string in `text`. Beside it, an
  ordinary SMS seconds later, intact. The pair is what makes the empty-sender
  case and the absent-sender case distinguishable in one file.
- Shell-posted `MessagingStyle` (`conversationTitle`, no `category`, no
  `RemoteInput`) — the shell is not a messaging app, so these lines only exist
  because the drill switched `com.android.shell` on by hand.
- `removed` events carrying `removalReasonName` `CANCEL_ALL`, from clearing the
  shade. Not `LISTENER_CANCEL_ALL`: that reason belongs to the listener
  cancelling notifications itself, which is what the spike's check 5 did.
- **A history entry whose own `time` moved.** Lines 9 and 12 are two posts of
  one notification, 501 ms apart, and the owner's reply sits at
  `history_index` 3 in both — with `time` `1790015627272` in the first and
  `1790015627773` in the second. Same conversation, same key, same text, two
  different entry times. The entry clock is not a fixed property of a message.
  The app had assumed it was, and stored the owner's reply twice; that was
  fixed on 21 September 2026 (`docs/ROADMAP.md`, the Capture item). These two
  lines are the only evidence of the behaviour, so a test for it belongs here.

## `2026-09-21-shipped-projection-evening.jsonl`

Pulled with `adb exec-out run-as … cat files/capture-queue.jsonl` in two intact
reads during the re-drive of the evening of 21 September 2026, with the Flutter
side force-stopped so nothing could drain the queue mid-capture. Deduped the
same way as the lines above: copies identical apart from `queuedAt` were
dropped. 5 `listener_connected`, 8 `posted`, no `removed`.

They exist because the first 29 lines were not enough to catch what they hold.
**A history entry's own `time` moves more than once, and the history window
slides under it.** Two shapes, both in these lines, both of which the
21 September correction does not cover:

- `(555) 987-6543`, `incoming_message:2`: the owner's entry `third reply line`
  sits at `history_index` 1 in a two-entry history — the newest line — in both
  the post at `1790018505695` and the post at `1790018597015`, with `time`
  `1790018504757` and then `1790018505307`. Same key, same position, same
  words, 550 ms apart. The repository's position-shape pass is restricted to an
  entry that is *not* the newest of its history, so nothing matches it and the
  reply is stored twice.
- `(555) 123-4567`, `incoming_message:1`: between the post at `1790018596957`
  and the post at `1790018598503` the window dropped its oldest entry, so
  `fourth reply line` moved from `history_index` 6 to 5 **and** its `time`
  moved from `1790018596220` to `1790018596639`. Position-shape keys on
  `history_index`, so a slide plus a move matches on neither shape. The same
  post slid `my own reply line` from 1 to 0 and `second reply line` from 3 to 2,
  and both of those were stored a second time as well.

So a re-post changes the time and not the position only for as long as the
window holds still. On this device it did not, and four owner replies out of
four ended up as eight rows. See the drill report of 21 September 2026 (evening).

## `2026-09-21-alignment-night.jsonl`

Six intact reads of `files/capture-queue.jsonl` taken during the drill of the
night of 21 September 2026, with the Flutter side force-stopped between reads so
nothing could drain the queue mid-capture, concatenated and deduped by the
queue's own row id, then ordered by `queuedAt`. 34 lines: 5 `listener_connected`,
29 `posted`, no `removed`.

It exists to hold the two shapes the evening file only *found*, now with the
sequence-alignment dedup in place, and one shape neither earlier file has:

- **The window slid and the clock moved in the same post**, five times over, all
  on `incoming_message:1`. The clearest pair: `fourth reply line` at
  `history_index` 6 with `time` `1790019818096` in the post at `1790019818785`,
  then at `history_index` 5 with `time` `1790019818583` in the post at
  `1790019820354`. Every one of the five is the owner's own line
  (`senderAbsent` true), because it is the line Google Messages refines from a
  sending clock to a sent clock.
- **The entry stayed the newest line while its clock moved.** `incoming_message:2`,
  `fifth reply line` at `history_index` 1 of a two-entry history — the newest
  entry — in both the post at `1790019880178` (`time` `1790019878991`) and the
  post at `1790019946077` (`time` `1790019879651`). The second post is 66 s
  later and carries no new content: sending a message in the *other* thread
  makes Google Messages re-post every conversation notification, and the
  refined clock only reaches the queue on that re-post.
- **Two genuinely identical messages in one history.** `Echo test one` was typed
  into the shade twice on purpose, at `1790020151786` and `1790020172798`, and
  the emulator's SMS loopback echoed both back, so the history carries the same
  words four times under two senders. Replaying the file leaves four rows. This
  is the direction the alignment must not get wrong: folding them would lose a
  message the user was sent, which is worse than a duplicate.
- **A reconnect re-queues every active notification.** After each force-stop the
  listener re-reads `getActiveNotifications()`, so a post already drained and
  acked arrives again with its original `postTime` (CAP-13). Lines with an
  earlier `postTime` than the `listener_connected` above them are that, not a
  queue that failed to ack.

## `2026-09-21-raw-shapes.jsonl`

The first device evidence CAP-21, CAP-6, CAP-7 and CAP-8's title distinction have
ever had. Written by **the throwaway debug spike's** projection, not the shipped
one, because the shipped listener drops `sbn.packageName == packageName` before
anything else and `SpikeRawPoster` posts under Replybox's own package: nothing in
this file could ever have reached the shipped store. Read the header of
`SpikeRawPoster.kt` before asserting on it.

Every shape appears twice — a `post_request` row saying what was *built*, then a
`posted` row saying what *arrived* — so a field the platform rewrote is visible
without a second source. What arrived, at API 37:

- `raw-msg`, `raw-social`, `raw-email`: `category` survives as `msg`, `social`
  and `email`, `template` is absent and `messages` is empty. CAP-21's gate does
  open on a real notification.
- `raw-nocategory`: the `category` **key is absent entirely**, not `null`. The
  gate stays shut (CAP-2).
- `raw-reply`: `hasRemoteInput` `true`, and the reply round-trips —
  `reply_attempt` with `"result":"sent"` and `resultKeys":"spike_raw_reply"`,
  then `poster_reply_received` carrying the exact text.
- `title-empty` versus `title-absent`: `"title":""` arrives as an empty string
  and survives; `title-absent` arrives with **no `title` key at all**. The
  distinction `NotificationProjection` documents as a residual is real and
  observable.
- `ongoing`: `isOngoing` is `true` even with no foreground service behind it
  (CAP-7).
- `summary` / `summary-child`: the summary's `isGroupSummary` is `true` with an
  empty `messages` array, the child arrives beside it carrying the content
  (CAP-6).
- `repost`: one id (9006), two `posted` rows, second text.
- **Not posted by anything in the drill:** three `isGroupSummary` rows under the
  group key `0|com.oasisforge.replybox|g:Aggregate_SilentSection`, id 1. The
  system built its own aggregate summary for the silent channel. One of them
  carries `isOngoing` `true`, inherited from the ongoing child. CAP-6 drops all
  three, which is the right outcome, but nothing in the rules had anticipated a
  summary the app never posted.

It holds no redaction-marker shape: `SpikeRawPoster` builds none, and
`cmd notification redact_otp_from_untrusted_listeners` no longer runs from the
shell at this API level.

Two things to know before asserting on it:

- Every line carries `queuedAt`. That field is added by `CaptureQueue.append`,
  not by `NotificationProjection`, so it is part of the queue format and not
  part of the projection's contract.
- Lines identical apart from `queuedAt` were dropped. A notification re-read by
  `onListenerConnected` produced the same projection several times; one copy of
  each is kept.

### What a follow-up should do with it

1. **Add a fixture test that replays it**, alongside the spike dumps rather than
   instead of them, asserting on what a user would see: the owner's reply is an
   outbound message with its words intact, the redacted SMS is a hidden message
   with `text` and `text_normalised` null and the marker nowhere, and the
   five-entry Messages notification yields five messages in one thread.
2. **Make it the file the Kotlin↔Dart contract is checked against.** The spike
   dumps cannot fail when the shipped projection renames or drops a field; this
   one can.
3. **Do not delete the spike dumps.** They are the record the rules in
   `docs/PRODUCT_RULES.md` were written from, and `docs/research/spike.md`
   cites them.
4. It does **not** contain a CAP-21 raw line (a `category` `msg` notification
   that is not `MessagingStyle`), and it never can. `cmd notification post` has
   no flag for a notification category, and the one thing on the device that
   does post that shape — `SpikeRawPoster` — posts under Replybox's own package,
   which the shipped listener drops before CAP-1's filter runs. Driven on
   21 September 2026 (evening): eleven raw shapes posted, the shipped store's
   row counts identical before and after. `2026-09-21-raw-shapes.jsonl` holds
   what the *platform delivered* for each shape; CAP-21 end to end, from a
   third-party package into the shipped store, remains undriven (CAP-25).
