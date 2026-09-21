package com.oasisforge.replybox.capture

import android.service.notification.NotificationListenerService
import com.oasisforge.replybox.capture.NotificationProjection.HistoryEntry
import org.json.JSONObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * CAP-4, CAP-8, CAP-15: what the projection carries, and what the values mean.
 *
 * ## What changed here, and why it had to
 *
 * Every test in this file used to be a regular expression over
 * NotificationProjection.kt. That is a test of the source text, not of the code: it
 * can catch a field that is emitted *at all*, and nothing about whether the value is
 * right. Nothing anywhere executed the shipped projection -- the Dart fixture tests
 * replay `docs/research/spike-dumps/`, which a **different** projection wrote (those
 * dumps still carry `id`, `flags`, `channelId`, `when` and `actions`, none of which
 * this one emits) -- so for three rounds of review the two sides agreed on paper and
 * nowhere else. That is how the missing sender key (CAP-8, INB-9) survived.
 *
 * The part of the projection that decides what Dart reads about a message is now
 * [NotificationProjection.projectHistory], a pure function over
 * [NotificationProjection.HistoryEntry], and the tests below **call it**.
 *
 * ## What still cannot be executed here, and what it would cost
 *
 * `project(event, sbn, reason)` reads a [android.service.notification.StatusBarNotification],
 * a [android.app.Notification] and a [android.os.Bundle]. On this classpath those are
 * android.jar stubs, and `isReturnDefaultValues` makes a Bundle answer null to every
 * getter, so calling it here would produce an empty object and assert nothing. Still
 * uncovered, and each is a value the Dart side branches on:
 *
 *  * the top-level `title`, `text` and `selfDisplayName` being `""` rather than
 *    absent, which is three-quarters of CAP-8's hidden-message test;
 *  * `isGroupConversation` being emitted only when the key is genuinely present and
 *    genuinely a Boolean (INB-1);
 *  * the Bundle-to-[HistoryEntry] step itself -- specifically that `sender_person` is
 *    read through `containsKey` and not through a null getter.
 *
 * Making those runnable needs Robolectric: real `Bundle`, `Notification` and
 * `Person` implementations, `@Config(sdk = ...)` to pin the API level a fixture was
 * taken at (CAP-25), and a first run that downloads an android-all jar per SDK level
 * -- roughly 60 MB of cached artifacts, a few seconds per test class, and a second
 * test framework for CI to keep working. It was **not** added on this branch's own
 * authority; the report on this branch names it as the open decision.
 *
 * Until then the contract half below stays, and is written for what it is: it cannot
 * catch a field emitted wrong, only one emitted at all. It is here because a
 * `put("extras", ...)` added to `project` would otherwise reach a release with
 * nothing objecting.
 */
class NotificationProjectionTest {

    /**
     * CAP-15's field list, exactly. Adding a line to `project` means adding it here
     * and to `docs/PRODUCT_RULES.md`, in that order -- the rule is what the privacy
     * policy quotes, and it names icons, extras, channel and Action objects as the
     * things that are dropped at this boundary and never written.
     */
    private val contract = setOf(
        "event",
        "sdkInt",
        "release",
        "key",
        "package",
        "tag",
        "postTime",
        "isOngoing",
        "isGroupSummary",
        "isClearable",
        "groupKey",
        "category",
        "template",
        "shortcutId",
        "conversationTitle",
        "isGroupConversation",
        "title",
        "text",
        "selfDisplayName",
        "messages",
        "hasRemoteInput",
        "removalReasonName",
    )

    @Test
    fun `project writes CAP-15's fields and nothing else`() {
        val body = sourceBetween("fun project(", "private fun messages(")

        assertEquals(contract, keysWrittenIn(body))
    }

    // ---- CAP-4's history: the real function, on real data -------------------

    @Test
    fun `a history entry carries five fields and no more`() {
        // CAP-4's history is the one nested object in the projection, and CAP-15
        // applies inside it: an icon, a Person bundle or a data URI put here would
        // reach the queue exactly as a top-level field would. Read off the function's
        // own output now, not off its source.
        val entry = single(HistoryEntry(sender = "Ada", senderKeyPresent = true, text = "hi", time = 7L, type = "image/png"))

        assertEquals(setOf("sender", "senderAbsent", "text", "time", "type"), entry.keys().asSequence().toSet())
        assertEquals("Ada", entry.getString("sender"))
        assertEquals("hi", entry.getString("text"))
        assertEquals(7L, entry.getLong("time"))
        assertEquals("image/png", entry.getString("type"))
    }

    @Test
    fun `an ordinary inbound line is not marked as the user's own`() {
        val entry = single(HistoryEntry(sender = "Ada", senderKeyPresent = true, text = "hi", time = 7L))

        assertFalse(entry.getBoolean("senderAbsent"))
    }

    @Test
    fun `the user's own line is marked, unambiguously, and keeps its text`() {
        // MessagingStyle marks the phone owner's own message with a null Person, and
        // Message.toBundle then writes neither "sender" nor "sender_person". Before
        // this flag existed that arrived on the Dart side as an absent sender, which
        // is indistinguishable from CAP-8's redaction -- so the user's own messages
        // were filed as inbound from nobody, or had their text destroyed as hidden
        // (INB-9).
        val entry = single(HistoryEntry(text = "on my way", time = 9L))

        assertTrue(entry.getBoolean("senderAbsent"), "a null Person must be stated, not implied by absence")
        assertFalse(entry.has("sender"), "there was no sender to report, so none is written")
        assertEquals("on my way", entry.getString("text"), "the user's own text is a message, not a redaction")
    }

    @Test
    fun `a redacted line keeps its empty sender and is never mistaken for the user's own`() {
        // CAP-8 recognises a hidden message by sender, title and selfDisplayName all
        // being empty at once. Empty is a value here and must survive the round trip:
        // the phone emptied a name it does have, which is the opposite fact from the
        // phone owner having written the line.
        val entry = single(HistoryEntry(sender = "", senderKeyPresent = true, text = "1 new message", time = 9L))

        assertEquals("", entry.getString("sender"))
        assertFalse(entry.getBoolean("senderAbsent"), "an emptied sender is redaction, not authorship")
    }

    @Test
    fun `a Person with no name is not the user's own line either`() {
        // The key is there and its value is null -- a Person carrying no name. That
        // is Android declining to say who, which is CAP-8's territory, not INB-9's.
        val entry = single(HistoryEntry(senderKeyPresent = true, personKeyPresent = true, text = "hi", time = 9L))

        assertFalse(entry.has("sender"), "no name was given, and the app does not invent one")
        assertFalse(entry.getBoolean("senderAbsent"), "a sender key that is present was not absent")
    }

    @Test
    fun `the modern sender_person supplies the name when the legacy key is missing`() {
        // An app writing EXTRA_MESSAGES by hand may write only the Person. Reading
        // only the legacy "sender" key lost that name entirely.
        val entry = single(HistoryEntry(personName = "Grace", personKeyPresent = true, text = "hi", time = 9L))

        assertEquals("Grace", entry.getString("sender"))
        assertFalse(entry.getBoolean("senderAbsent"))
    }

    @Test
    fun `the legacy key wins where both are there`() {
        // What the spike's dumps recorded, and what CAP-8's empty-string test is
        // written against.
        val entry = single(
            HistoryEntry(sender = "Ada", senderKeyPresent = true, personName = "Ada Lovelace", personKeyPresent = true),
        )

        assertEquals("Ada", entry.getString("sender"))
    }

    @Test
    fun `an absent time is absent, never nineteen seventy`() {
        // Bundle.getLong answers 0 for a key that is not there and for a value that
        // is not a long. 0 reads as a real instant on the Dart side, sinks the thread
        // to the bottom of the inbox for good (INB-4) and never runs the documented
        // fallback to postTime (CAP-8, INB-3).
        val entry = single(HistoryEntry(sender = "Ada", senderKeyPresent = true, text = "hi"))

        assertFalse(entry.has("time"))
        // And the rule itself, run: a value of the wrong type is absent, not coerced.
        assertEquals(7L, NotificationProjection.longValueOrNull(7L))
        assertNull(NotificationProjection.longValueOrNull("7"))
        assertNull(NotificationProjection.longValueOrNull(7))
        assertNull(NotificationProjection.longValueOrNull(null))
        assertEquals(true, NotificationProjection.booleanValueOrNull(true))
        assertNull(NotificationProjection.booleanValueOrNull("true"))
        assertNull(NotificationProjection.booleanValueOrNull(null))
    }

    @Test
    fun `the history is capped at the platform's own twenty-five, newest kept`() {
        // MessagingStyle retains 25 and drops the oldest past that, but EXTRA_MESSAGES
        // can be written straight into the extras with Notification.Builder.addExtras,
        // which goes nowhere near that cap; a ~1 MB binder payload holds several
        // thousand small bundles. Uncapped, Repository.insertMessagesIfNew builds one
        // bound parameter per entry and SQLITE_MAX_VARIABLE_NUMBER is 999 below
        // Android 11 -- so an API 24-29 device fails at about 995 entries, roughly 33x
        // sooner than the API 37 emulator this was measured on, and the row is then
        // re-ingested on every drain for thirty days.
        val entries = (0 until 3000).map { HistoryEntry(sender = "Ada", senderKeyPresent = true, text = "m$it") }

        val history = NotificationProjection.projectHistory(entries)

        assertEquals(25, history.length())
        // The newest, not the oldest: the entry the notification is actually on
        // screen about is the last one, and dropping it is the failure CAP-5's
        // correction of 21 September 2026 exists to stop.
        assertEquals("m2975", history.getJSONObject(0).getString("text"))
        assertEquals("m2999", history.getJSONObject(24).getString("text"))
    }

    @Test
    fun `a history at the cap is untouched`() {
        val entries = (0 until 25).map { HistoryEntry(sender = "Ada", senderKeyPresent = true, text = "m$it") }

        val history = NotificationProjection.projectHistory(entries)

        assertEquals(25, history.length())
        assertEquals("m0", history.getJSONObject(0).getString("text"))
    }

    @Test
    fun `an empty history is an empty array, not an absent one`() {
        // CAP-21 reads "carries no MessagingStyle history" off this, and CAP-6 asserts
        // every group summary the spike captured had one.
        assertEquals(0, NotificationProjection.projectHistory(emptyList()).length())
    }

    // ---- The rest --------------------------------------------------------------

    @Test
    fun `CAP-2 is decided on the framework's own template string`() {
        // The Dart normaliser matches this literal. Deriving it from the class stops a
        // typo, but not a disagreement: if the two sides ever named different strings,
        // every notification would look like "not MessagingStyle" and fall through to
        // CAP-21's category test, and the app would store raw lines instead of
        // conversations with nothing failing.
        assertEquals("android.app.Notification\$MessagingStyle", NotificationProjection.MESSAGING_STYLE)
    }

    @Test
    fun `a lifecycle row carries the queue's own fields and no notification content`() {
        // The one projected row that can be built here: it reads the clock and
        // Build.VERSION and nothing else (PERM-8, CAP-15).
        val row = NotificationProjection.lifecycle("listener_connected", T)

        assertEquals("listener_connected", row.getString("event"))
        assertEquals(T, row.getLong("postTime"))
        val written = row.keys().asSequence().toSet()
        assertEquals(
            emptySet<String>(),
            written - setOf("event", "sdkInt", "release", "postTime"),
            "a lifecycle row wrote a field the contract does not name",
        )
    }

    @Test
    fun `reasonName gives CAP-22 the names it decides on, and keeps an unknown one apart`() {
        // CAP-22 acts on CLICK and APP_CANCEL and must not act on the rest, so what
        // matters is that these six answers are six different strings. The names are
        // the spike dump's names: docs/research/spike-dumps is the fixture set, and
        // APP_CANCEL there has to mean APP_CANCEL here.
        val marksRead = listOf(
            NotificationListenerService.REASON_CLICK to "CLICK",
            NotificationListenerService.REASON_APP_CANCEL to "APP_CANCEL",
        )
        val changesNothing = listOf(
            NotificationListenerService.REASON_LISTENER_CANCEL to "LISTENER_CANCEL",
            NotificationListenerService.REASON_LISTENER_CANCEL_ALL to "LISTENER_CANCEL_ALL",
            NotificationListenerService.REASON_CANCEL_ALL to "CANCEL_ALL",
            NotificationListenerService.REASON_TIMEOUT to "TIMEOUT",
        )
        for ((reason, name) in marksRead + changesNothing) {
            assertEquals(name, NotificationProjection.reasonName(reason))
        }

        // An unrecognised reason keeps its number rather than folding into a known
        // one: CAP-22 treats unrecognised as "changes nothing", which is only safe
        // while it stays distinguishable from CLICK.
        assertEquals("UNKNOWN_9999", NotificationProjection.reasonName(9999))

        val all = (marksRead + changesNothing).map { NotificationProjection.reasonName(it.first) } + "UNKNOWN_9999"
        assertEquals(all.size, all.toSet().size, "two reasons answered the same name: $all")
    }

    /** The one projected entry of a one-entry history. */
    private fun single(entry: HistoryEntry): JSONObject {
        val history = NotificationProjection.projectHistory(listOf(entry))
        assertEquals(1, history.length())
        return history.getJSONObject(0)
    }

    /** Every `put("name"` in a stretch of the projection's source. */
    private fun keysWrittenIn(source: String): Set<String> =
        Regex("""put\("([^"]+)"""").findAll(source).map { it.groupValues[1] }.toSet()

    private fun sourceBetween(open: String, close: String): String {
        val source = projectionSource()
        val body = source.substringAfter(open, "").substringBefore(close, "")
        if (body.isEmpty()) {
            fail("NotificationProjection.kt no longer has '$open' ... '$close'; move these bounds with it")
        }
        return body
    }

    private fun projectionSource(): String {
        val relative = "src/main/kotlin/com/oasisforge/replybox/capture/NotificationProjection.kt"
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            for (candidate in listOf(File(dir, relative), File(dir, "android/app/$relative"))) {
                if (candidate.isFile) return candidate.readText()
            }
            dir = dir.parentFile
        }
        fail("could not find $relative above ${File("").absoluteFile}")
    }
}
