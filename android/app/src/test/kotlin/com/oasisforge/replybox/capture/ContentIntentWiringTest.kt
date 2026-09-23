package com.oasisforge.replybox.capture

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * INB-13's first path, held to being wired rather than merely implemented.
 *
 * ## Why this file exists
 *
 * `ReplyActions.rememberContentIntent` shipped with no caller. Everything around
 * it worked -- the map, the channel method, `AppLaunch.openChat`, the launcher --
 * and the one line that puts an intent into the map was missing, so
 * `contentIntentFor` answered null for every notification ever posted and every
 * thread fell to INB-13's other path, the package's launcher intent.
 *
 * That fallback is not a fallback for most apps. `getLaunchIntentForPackage` is
 * filtered by package visibility, so it answers null for every package outside the
 * manifest's `<queries>` -- and INB-20 is explicit that the app declares no
 * `QUERY_ALL_PACKAGES` and never enumerates installed packages. The packages
 * outside the declaration are exactly INB-20's second source: every app that
 * joined the inbox by posting a notification. For those, the content intent is the
 * only thing that can open anything at all, and until area REP ships, that control
 * is the second tap of INB-18's reply path.
 *
 * So the wiring is load-bearing, it is one line, and a compiler cannot miss it
 * twice. This file reads the listener's source, the way AppLaunchTest reads
 * AppLaunch.kt's, and fails if the writer or the reader the screen asks through
 * goes away again.
 */
class ContentIntentWiringTest {

    /** The write, as `capture` spells it. */
    private val writer = "sbn.notification.contentIntent?.let { ReplyActions.rememberContentIntent(sbn.key, it) }"

    /**
     * The same write, anchored to the start of its own line.
     *
     * A plain `contains` would be satisfied by the line commented out, which is
     * exactly how a wiring like this gets lost -- and the mutant check below holds
     * this regex to catching that.
     */
    private val writerLine = Regex("""^[ \t]*${Regex.escape(writer)}$""", RegexOption.MULTILINE)

    /** The channel method the thread screen asks before it draws `Open chat`. */
    private val reader = "\"canOpenChat\" -> result.success("

    @Test
    fun `the listener remembers each captured notification's content intent`() {
        val source = listenerText()

        assertTrue(
            writerLine.containsMatchIn(source),
            "INB-13's `Open chat` fires the notification's own content intent, and nothing but " +
                "ReplyboxListenerService.capture can put one in the map. Without this line every thread " +
                "falls to the launcher intent, which package visibility answers null for on every package " +
                "outside the manifest's <queries> (INB-16, INB-20) -- so the only control on the screen " +
                "could never open anything for an app that reached the inbox by posting.",
        )
    }

    @Test
    fun `the content intent is remembered only after the filter has run`() {
        val source = listenerText()
        val write = source.indexOf(writer)
        val filter = source.indexOf("if (!NotificationProjection.isCapturable(sbn)) return")
        val enabled = source.indexOf("if (!enabled) return")

        assertTrue(write > filter && write > enabled, "the content intent is held at index $write")
    }

    @Test
    fun `nothing reads or rewrites the notification's own intent`() {
        val source = listenerText()
        val offenders = listOf(
            "contentIntent.send",
            "contentIntent!!",
            "putExtra",
            "setComponent",
            "ComponentName",
            "import android.content.Intent",
        ).filter { source.contains(it) }

        assertEquals(
            emptyList(),
            offenders,
            "Product principle 1, as INB-13 spells it: the intent is held as the source app built it and " +
                "sent that way. The listener hands the handle over and reads nothing out of it.",
        )
    }

    @Test
    fun `the screen can ask whether Open chat is available without firing it`() {
        val channel = channelText()

        assertTrue(
            channel.contains(reader),
            "INB-13 decides the path before the tap, because the label says which one will run. A screen " +
                "that had to fire openChat to discover there was nothing held would show `Open chat` and " +
                "then a snackbar, which is the failing control this path exists to remove.",
        )
        assertTrue(
            channel.contains("fun hasContentIntent(notificationKey: String): Boolean"),
            "the ask is answered from the same entry openChat fires, or the two can disagree",
        )
    }

    @Test
    fun `an unheld notification answers false rather than throwing`() {
        // A cold start holds nothing, and that is an ordinary state: the screen
        // says INB-16's line instead of offering a launch it cannot make.
        assertFalse(ReplyActions.hasContentIntent("0|com.discord|7|null|10123"))
        assertFalse(ReplyActions.canReplyTo("0|com.discord|7|null|10123"))
    }

    @Test
    fun `the wiring check rejects a listener that lost the line`() {
        // Without this the check above is only as good as its string, and a string
        // that has quietly stopped matching passes on the build that ships the
        // defect (CaptureLogTest, AppLaunchTest).
        val source = listenerText()
        val survivors = listOf(
            "the write deleted outright" to source.replace(writer, ""),
            "the write commented out" to source.replace(writer, "// $writer"),
            "the write moved onto the reply action's handle" to
                source.replace(writer, "ReplyActions.remember(sbn.key, it)"),
        ).filter { (_, mutant) -> writerLine.containsMatchIn(mutant) }.map { it.first }

        assertEquals(emptyList(), survivors, "a listener with no content-intent writer was accepted")
    }

    private fun listenerText() = captureSource("ReplyboxListenerService.kt")

    private fun channelText() = captureSource("CaptureChannel.kt")

    /**
     * One shipped source, with its line endings normalised.
     *
     * The normalisation is not decoration: the repo is checked out with CRLF on
     * Windows, and a check whose pattern silently failed to match would pass while
     * asserting nothing -- green where nobody is looking at it and green on the
     * runner too (OwnPackageGuardTest records that failure).
     */
    private fun captureSource(name: String) =
        File(androidAppDir(), "src/main/kotlin/com/oasisforge/replybox/capture/$name")
            .readText()
            .replace("\r\n", "\n")
}
