package com.oasisforge.replybox.capture

import android.app.Notification
import android.app.Person
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/**
 * The only place a [StatusBarNotification] is turned into something the app keeps.
 *
 * CAP-15: the fields below are the whole of it. Everything the spike also dumped --
 * icons, the extras bundle, the channel, Action objects, bigText, subText, flags --
 * is read here and deliberately not written, so nothing the inbox cannot show can
 * survive as far as the queue, let alone the database.
 *
 * The field names are the spike dump's names on purpose: docs/research/spike-dumps
 * is what the Dart normaliser's tests parse, so a rename here silently invalidates
 * every fixture.
 *
 * There is exactly one field the dumps do not have: `senderAbsent` on a history
 * entry (see [projectHistory]). It is new because the dumps were written by a
 * different projection and carry no way to express what it says -- which is also
 * why those fixtures cannot be the only test of this file, and why
 * NotificationProjectionTest now executes the history projection instead of reading
 * it. Dart treats the key's absence as "this fixture predates the flag", never as
 * false, so the dumps keep replaying unchanged.
 */
object NotificationProjection {

    /**
     * CAP-2 is decided on this exact string. Taken from the class rather than typed
     * out because a typo would fail open: every notification would look like "not
     * MessagingStyle" and fall through to CAP-21's category test.
     *
     * Visible so a JVM test can assert the value, which is the half a typo-proof
     * expression does not cover: the Dart normaliser matches the same literal, and
     * if the framework ever moved the class the two sides would disagree silently.
     */
    internal val MESSAGING_STYLE: String = Notification.MessagingStyle::class.java.name

    /**
     * CAP-4's history, capped where the platform caps its own.
     *
     * `Notification.MessagingStyle` retains `MAXIMUM_RETAINED_MESSAGES` = 25 entries
     * and drops the oldest past that, so 25 is every entry any app using the builder
     * can actually show. But `EXTRA_MESSAGES` and `EXTRA_TEMPLATE` can also be
     * written straight into the extras with `Notification.Builder.addExtras`, which
     * goes nowhere near that cap, and a roughly 1 MB binder payload holds several
     * thousand small bundles.
     *
     * Uncapped, that reached SQLite. `Repository.insertMessagesIfNew` builds an
     * `id NOT IN (...)` list with one bound parameter per entry, and
     * `SQLITE_MAX_VARIABLE_NUMBER` is **999 below Android 11** and 32766 from
     * Android 11 -- so a device on API 24-29, which this build supports (minSdk 24),
     * fails at roughly 995 entries, about 33x sooner than the API 37 emulator every
     * measurement was taken on. The exception is swallowed, the row is never acked,
     * and every drain for the next 30 days runs it again.
     *
     * The **newest** 25 are kept, which is what MessagingStyle itself keeps. Taking
     * the oldest 25 instead would throw away the message that has just arrived --
     * the one the notification is on screen about -- which is the failure CAP-5's
     * correction of 21 September 2026 exists to stop. The cost is that an over-cap
     * notification's entries shift position between reads; CAP-5 matches on content
     * and not on position for exactly that reason, and a history that slides is the
     * case its correction is written against.
     *
     * The literal is written out rather than read from
     * `Notification.MessagingStyle.MAXIMUM_RETAINED_MESSAGES`: this file is compiled
     * against android.jar, and a stub constant that answered 0 would cap the history
     * at nothing at all.
     */
    internal const val MAX_HISTORY = 25

    /**
     * One entry of `EXTRA_MESSAGES`, reduced to the plain values its Bundle carried,
     * so that [projectHistory] -- the part of the projection that decides what Dart
     * reads -- is a pure function a JVM test can execute (NotificationProjectionTest).
     *
     * The `...KeyPresent` flags are the whole point of the shape. `getCharSequence`
     * answers null both for a key that is absent and for a key whose value is null,
     * and those two are different facts here: CAP-8 recognises a hidden message by
     * `sender` being **empty**, while MessagingStyle marks the phone owner's own line
     * by writing no sender key **at all**. A reader that cannot tell them apart files
     * the user's own messages as incoming ones from nobody.
     */
    data class HistoryEntry(
        /** The legacy `"sender"` value: `""` on a redacted entry, null if absent or null. */
        val sender: String? = null,
        /** Whether the bundle carried the `"sender"` key at all, whatever its value. */
        val senderKeyPresent: Boolean = false,
        /** The name on the modern `"sender_person"` Person (API 28), or null. */
        val personName: String? = null,
        /** Whether the bundle carried the `"sender_person"` key at all. */
        val personKeyPresent: Boolean = false,
        val text: String? = null,
        val time: Long? = null,
        val type: String? = null,
    )

    /** CAP-21: the categories that are kept as one `raw` line when CAP-2 says no. */
    private val KEPT_CATEGORIES = setOf(
        Notification.CATEGORY_MESSAGE,
        Notification.CATEGORY_SOCIAL,
        Notification.CATEGORY_EMAIL,
    )

    /**
     * Whether this notification is one the app stores at all. Package filtering is
     * not here: CAP-1's drop happens before this is called, so a disabled app's
     * title and text are never read into memory in the first place.
     */
    fun isCapturable(sbn: StatusBarNotification): Boolean {
        val n = sbn.notification
        // CAP-6: a summary's children carry the content, and every summary the spike
        // captured had an empty message history, so nothing is lost by dropping it.
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        // CAP-7: an ongoing notification is a status. Nobody is waiting on a reply to
        // "Messages is doing work in the background".
        if (sbn.isOngoing) return false
        // CAP-2: MessagingStyle is the only shape that becomes a real message.
        if (n.extras.getString(Notification.EXTRA_TEMPLATE) == MESSAGING_STYLE) return true
        // CAP-21: otherwise it is kept only as a raw line, and only for these three
        // categories. Anything else from an included app is ignored.
        return n.category in KEPT_CATEGORIES
    }

    /**
     * CAP-14: the action that can answer this notification is the one carrying a
     * free-form RemoteInput. Never matched by label -- CAP-8 says a redacted
     * notification arrives with every action title emptied to "", so a label match
     * would lose reply on exactly the notifications that still have it.
     *
     * `semanticAction` would be the other half of CAP-8's test, but it is API 28 and
     * buys nothing here: the free-form RemoteInput *is* the capability, and the
     * spike's redacted fixture proved one still delivers after dismissal (check 5).
     */
    fun replyAction(n: Notification): Notification.Action? =
        n.actions.orEmpty().firstOrNull { action ->
            action.remoteInputs.orEmpty().any { it.allowFreeFormInput }
        }

    /**
     * CAP-21's "carries a RemoteInput", answered by exactly the predicate
     * [replyAction] uses.
     *
     * Two definitions would be two different answers on the same notification: a
     * choice-only RemoteInput -- a set of canned replies with `allowFreeFormInput`
     * false -- would report a reply field the app could never put words into, and
     * the thread would offer a bar that [ReplyActions] has nothing to fire. The
     * projected field and the held action are the same capability, so they are the
     * same test.
     */
    fun hasReplyAction(n: Notification): Boolean = replyAction(n) != null

    /**
     * A bind or unbind event. It carries `postTime` like any other row so that
     * CAP-15's 30-day sweep can age it, and so PERM-8 can open and close its
     * `capture_sessions` row on a time the listener reported rather than the time
     * Dart happened to drain the queue.
     */
    fun lifecycle(event: String, now: Long): JSONObject = JSONObject().apply {
        put("event", event)
        put("sdkInt", Build.VERSION.SDK_INT)
        put("release", Build.VERSION.RELEASE)
        put("postTime", now)
    }

    /**
     * One event, one JSON object. A null value removes the key rather than writing
     * `null`, which is org.json's own behaviour and is why every reader on the Dart
     * side has to tolerate an absent field.
     */
    // EXTRA_SELF_DISPLAY_NAME is deprecated in favour of the Person object, and is
    // read anyway: CAP-8 recognises a hidden message by sender, title and
    // selfDisplayName all being empty at once, and the spike's fixtures carry this
    // extra under this name. Following the deprecation would change the field the
    // dumps in docs/research/spike-dumps were recorded with.
    @Suppress("DEPRECATION")
    fun project(event: String, sbn: StatusBarNotification, removalReasonName: String? = null): JSONObject {
        val n = sbn.notification
        val extras = n.extras
        return JSONObject().apply {
            put("event", event)
            // CAP-25: a fixture is only comparable against another one taken at the
            // same API level, because redaction widened in 15 and again in 16.
            put("sdkInt", Build.VERSION.SDK_INT)
            put("release", Build.VERSION.RELEASE)
            put("key", sbn.key)
            put("package", sbn.packageName)
            put("tag", sbn.tag)
            put("postTime", sbn.postTime)
            put("isOngoing", sbn.isOngoing)
            put("isGroupSummary", n.flags and Notification.FLAG_GROUP_SUMMARY != 0)
            put("isClearable", sbn.isClearable)
            // CAP-3: recorded, never used as a conversation key. One groupKey covered
            // three separate threads in the spike's dumps and one changed between a
            // notification's post and its removal, so it is evidence, not identity.
            put("groupKey", sbn.groupKey)
            put("category", n.category)
            put("template", extras.getString(Notification.EXTRA_TEMPLATE))
            // getShortcutId() is API 26; below that CAP-3 falls through to its next
            // candidate rather than inventing one.
            put("shortcutId", if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) n.shortcutId else null)
            put("conversationTitle", extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString())
            // EXTRA_IS_GROUP_CONVERSATION is an API 28 constant, inlined at compile
            // time; below 28 the key is simply absent. Absent is not false here: the
            // two-argument getBoolean cannot tell an absent key from a wrong-typed
            // one, and writing `false` for either would be the projection stating
            // something the phone never said (product principle 3). The key is
            // emitted only when it is genuinely present and genuinely a Boolean, and
            // Dart's own reader is what turns absence into INB-1's one-to-one
            // layout.
            put("isGroupConversation", extras.booleanOrNull(Notification.EXTRA_IS_GROUP_CONVERSATION))
            put("title", extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
            put("text", extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
            put("selfDisplayName", extras.getCharSequence(Notification.EXTRA_SELF_DISPLAY_NAME)?.toString())
            // CAP-4: in a burst the visible `text` collapses to the newest line while
            // the history keeps them all, so this array is the only place the other
            // four messages exist.
            put("messages", messages(extras))
            // CAP-21: whether a raw line can be answered at all -- the same
            // predicate the held reply action is chosen by, never a second one.
            put("hasRemoteInput", hasReplyAction(n))
            // CAP-22: present only when the event carried one. Never inferred from a
            // notification merely being gone.
            put("removalReasonName", removalReasonName)
        }
    }

    /**
     * CAP-4's history: the Bundle-reading half, which no JVM test can run. Every
     * decision about what the values *mean* is in [projectHistory], which is pure
     * and is executed by NotificationProjectionTest; all this does is read keys and
     * record whether each was there.
     *
     * Every field is emitted only when the bundle genuinely carries it, with one
     * rule throughout: absent is absent, and empty is a value. The one exception is
     * `senderAbsent`, which is always written because its whole job is to state an
     * absence rather than imply one.
     *
     * `time` is why the rule is written down. `Bundle.getLong` answers 0 for a key
     * that is not there and for a value that is not a long, so the old projection
     * filed a message with no time at 1 Jan 1970 -- which reads as a real instant
     * on the Dart side, sinks the thread to the bottom of the inbox for good
     * (INB-4) and never runs the documented fallback to `postTime` (CAP-8, INB-3).
     * An empty `sender` is the opposite case and must survive: CAP-8 recognises a
     * hidden message by sender, title and self-display name all being empty at
     * once, so `""` is read as the answer it is and only a missing key is dropped.
     */
    private fun messages(extras: Bundle): JSONArray {
        val items = parcelableArray(extras, Notification.EXTRA_MESSAGES)
        // Capped before the bundles are read, not after: reading several thousand
        // Bundles is the unbounded work, and the entries past the cap cannot reach
        // the queue anyway. [projectHistory] applies the same cap again, and that is
        // the copy a test can execute -- they cite one constant on purpose.
        val kept = if (items.size > MAX_HISTORY) items.copyOfRange(items.size - MAX_HISTORY, items.size) else items
        val entries = ArrayList<HistoryEntry>(kept.size)
        for (item in kept) {
            val b = item as? Bundle ?: continue
            entries.add(
                HistoryEntry(
                    sender = b.getCharSequence(KEY_SENDER)?.toString(),
                    senderKeyPresent = b.containsKey(KEY_SENDER),
                    personName = b.personName(KEY_SENDER_PERSON),
                    personKeyPresent = b.containsKey(KEY_SENDER_PERSON),
                    text = b.getCharSequence(KEY_TEXT)?.toString(),
                    time = b.longOrNull(KEY_TIME),
                    type = b.getString(KEY_TYPE),
                ),
            )
        }
        return projectHistory(entries)
    }

    /**
     * CAP-4's history as Dart receives it. Pure: this is the real logic the shipped
     * projection runs, called by a JVM test with plain data rather than read off the
     * source with a regular expression.
     *
     * Four things are decided here.
     *
     * **The cap.** The newest [MAX_HISTORY] entries and no more; see that constant.
     *
     * **Which sender key.** `MessagingStyle.Message.toBundle` writes the legacy
     * `"sender"` CharSequence *and* the modern `"sender_person"` Person, so the
     * legacy key is enough on every app that uses the builder -- but an app writing
     * extras by hand may write only the Person, and reading only the legacy key
     * loses the name. The legacy value wins where both are there, because it is what
     * the spike's dumps recorded and what CAP-8's empty-string test is written
     * against.
     *
     * **Absent versus empty.** `""` is a value and survives: CAP-8 recognises a
     * hidden message by `sender`, `title` and `selfDisplayName` all being empty at
     * once, and an emptied sender is the phone redacting a name it does have. A key
     * that is not there is dropped instead, because org.json removes a null and
     * Dart's readers are written to tolerate an absent field.
     *
     * **`senderAbsent`, which is new.** `Message.toBundle` writes *neither* sender
     * key when the message's Person is null, and MessagingStyle uses a null Person
     * to mean exactly one thing: the phone's owner wrote this line. Emitting only
     * `sender` could not express that -- an absent `sender` looked identical to a
     * redaction, so the user's own messages arrived as incoming ones from nobody, or
     * had their text destroyed as a hidden message (CAP-8, INB-9). This flag is
     * emitted on every entry, always as a real Boolean, so the Dart side can tell
     * three states apart: `senderAbsent` true is "the user wrote this"; false with a
     * `sender` of `""` is "Android hid this"; false with a name is an ordinary
     * inbound line. An entry with the key missing altogether is a fixture written by
     * an older projection and means neither -- which is the honest answer for the
     * dumps in docs/research/spike-dumps, none of which carry it.
     */
    fun projectHistory(entries: List<HistoryEntry>): JSONArray {
        val out = JSONArray()
        for (entry in entries.takeLast(MAX_HISTORY)) {
            out.put(
                JSONObject()
                    .put(KEY_SENDER, entry.sender ?: entry.personName)
                    .put(KEY_SENDER_ABSENT, !entry.senderKeyPresent && !entry.personKeyPresent)
                    .put(KEY_TEXT, entry.text)
                    .put(KEY_TIME, entry.time)
                    .put(KEY_TYPE, entry.type),
            )
        }
        return out
    }

    /**
     * The name on a `Person` the bundle holds under [key], or null.
     *
     * `android.app.Person` is API 28, and so is the `sender_person` key that carries
     * it, so below 28 there is nothing to read and the legacy `sender` key is the
     * whole answer. A bundle whose Parcelable cannot be unmarshalled -- a class this
     * process does not have, a malformed payload -- answers null rather than taking
     * the listener down over one notification.
     */
    @Suppress("DEPRECATION")
    private fun Bundle.personName(key: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        return try {
            (getParcelable(key) as? Person)?.name?.toString()
        } catch (e: Exception) {
            CaptureLog.failure("could not read a message sender", e)
            null
        }
    }

    /**
     * A long the bundle really holds, or null. Read through `get` rather than
     * `getLong`, because both of `getLong`'s overloads fold "not there" and "not a
     * long" into the default and there is no default that cannot also be a real
     * message time.
     *
     * A wrong-typed value is absent rather than coerced: a time the app did not
     * write is a time the app invented, and Dart's fallback to the notification's
     * `postTime` is the honest answer (product principle 3).
     */
    @Suppress("DEPRECATION")
    private fun Bundle.longOrNull(key: String): Long? = longValueOrNull(get(key))

    /** The same rule for a flag: present and really a Boolean, or absent. */
    @Suppress("DEPRECATION")
    private fun Bundle.booleanOrNull(key: String): Boolean? = booleanValueOrNull(get(key))

    /**
     * The two rules above with the Bundle taken away, so a JVM test runs the real
     * ones. A wrong-typed value is absent, never coerced: `0` for a time the app did
     * not write files a message at 1 Jan 1970, and `false` for a flag the phone never
     * set is the projection stating something it was not told (product principle 3).
     */
    internal fun longValueOrNull(value: Any?): Long? = value as? Long

    internal fun booleanValueOrNull(value: Any?): Boolean? = value as? Boolean

    /**
     * The `MessagingStyle.Message` bundle keys, written out because they are the
     * framework's own and are not public constants, and because the projected field
     * names have to stay the spike dumps' names (see the note on this object).
     *
     * `sender_person` is the modern one: `Message.toBundle` writes the Person there
     * and the legacy name under `sender`, and writes **neither** when the Person is
     * null, which is how it marks the phone owner's own line.
     */
    private const val KEY_SENDER = "sender"
    private const val KEY_SENDER_PERSON = "sender_person"
    private const val KEY_TEXT = "text"
    private const val KEY_TIME = "time"
    private const val KEY_TYPE = "type"

    /** Projected, not read: [projectHistory] explains what it means. */
    internal const val KEY_SENDER_ABSENT = "senderAbsent"

    /**
     * getParcelableArray(String, Class) is API 33; the untyped overload is what
     * exists at minSdk 24 and is deprecated above it. Both are kept rather than
     * suppressing the warning, because the typed one is the only version that does
     * not hand back a heap-poisoned array on a malformed bundle.
     */
    @Suppress("DEPRECATION")
    private fun parcelableArray(extras: Bundle, key: String): Array<out Parcelable> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            extras.getParcelableArray(key, Parcelable::class.java).orEmpty()
        } else {
            extras.getParcelableArray(key).orEmpty()
        }

    /**
     * CAP-22 reads these names, so they are the spike's names exactly: the dumps in
     * docs/research/spike-dumps are the fixtures, and `APP_CANCEL` there has to mean
     * `APP_CANCEL` here. An unrecognised reason keeps its number rather than being
     * folded into one of the known ones -- CAP-22 treats unrecognised as "changes
     * nothing", which is only safe if it stays distinguishable.
     */
    fun reasonName(reason: Int): String = when (reason) {
        NotificationListenerService.REASON_CLICK -> "CLICK"
        NotificationListenerService.REASON_CANCEL -> "CANCEL"
        NotificationListenerService.REASON_CANCEL_ALL -> "CANCEL_ALL"
        NotificationListenerService.REASON_LISTENER_CANCEL -> "LISTENER_CANCEL"
        NotificationListenerService.REASON_LISTENER_CANCEL_ALL -> "LISTENER_CANCEL_ALL"
        NotificationListenerService.REASON_APP_CANCEL -> "APP_CANCEL"
        NotificationListenerService.REASON_APP_CANCEL_ALL -> "APP_CANCEL_ALL"
        NotificationListenerService.REASON_TIMEOUT -> "TIMEOUT"
        NotificationListenerService.REASON_SNOOZED -> "SNOOZED"
        NotificationListenerService.REASON_ERROR -> "ERROR"
        NotificationListenerService.REASON_PACKAGE_CHANGED -> "PACKAGE_CHANGED"
        NotificationListenerService.REASON_USER_STOPPED -> "USER_STOPPED"
        NotificationListenerService.REASON_PACKAGE_BANNED -> "PACKAGE_BANNED"
        NotificationListenerService.REASON_CHANNEL_BANNED -> "CHANNEL_BANNED"
        NotificationListenerService.REASON_CHANNEL_REMOVED -> "CHANNEL_REMOVED"
        NotificationListenerService.REASON_CLEAR_DATA -> "CLEAR_DATA"
        NotificationListenerService.REASON_ASSISTANT_CANCEL -> "ASSISTANT_CANCEL"
        else -> "UNKNOWN_$reason"
    }
}
