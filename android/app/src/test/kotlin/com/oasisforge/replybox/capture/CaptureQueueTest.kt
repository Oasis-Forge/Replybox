package com.oasisforge.replybox.capture

import org.json.JSONObject
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * CAP-15's hand-over queue: what it keeps, what it drops, and what survives a rewrite.
 *
 * The 30-day drop is not housekeeping. `docs/privacy-policy.md` states it, so it is a
 * claim made to the person installing the app about a file holding other people's
 * message text, and nothing else on this branch proves it happens.
 */
class CaptureQueueTest {

    private lateinit var dir: File
    private lateinit var file: File

    @BeforeTest
    fun setUp() {
        dir = newTempDir("replybox-queue")
        file = File(dir, CaptureQueue.FILE_NAME)
    }

    @AfterTest
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun row(text: String): JSONObject =
        JSONObject()
            .put("event", "notification_posted")
            .put("package", "com.whatsapp")
            .put("text", text)

    /** Every drained row, parsed back through the format the file actually holds. */
    private fun drainedTexts(queue: CaptureQueue): List<String> =
        queue.drain().map { line -> JSONObject(line.substringAfter("\t")).getString("text") }

    @Test
    fun `prune drops a row past thirty days and keeps the younger ones, in order`() {
        val queue = queueOn(file)
        queue.append(row("thirty-one days old"), T - 31 * DAY_MS)
        queue.append(row("twenty-nine days old"), T - 29 * DAY_MS)
        queue.append(row("queued just now"), T)

        queue.prune(T)

        assertEquals(listOf("twenty-nine days old", "queued just now"), drainedTexts(queue))
        // Still the row that was appended, not a re-serialised approximation of it:
        // the rewrite must not touch the JSON it is carrying.
        val youngest = JSONObject(queue.drain().last().substringAfter("\t"))
        assertEquals("notification_posted", youngest.getString("event"))
        assertEquals("com.whatsapp", youngest.getString("package"))
        assertEquals(T, youngest.getLong("queuedAt"))
    }

    @Test
    fun `prune drops a row carrying neither queuedAt nor postTime`() {
        val queue = queueOn(file)
        // append() always stamps queuedAt, so a row without one is a truncated write
        // or a row from a build that never stamped it. Written by hand for that
        // reason. A row that can never be aged would hold message text past CAP-15's
        // window for as long as the install lasts, which is the one outcome the
        // privacy policy rules out.
        val ageless = JSONObject().put("event", "notification_posted").put("text", "no age at all")
        file.appendText("ageless-row\t$ageless\n")
        queue.append(row("stamped"), T)

        queue.prune(T)

        assertEquals(listOf("stamped"), drainedTexts(queue))
    }

    @Test
    fun `drain does not clear, and ack deletes exactly the rows it is given`() {
        val queue = queueOn(file)
        val first = assertNotNull(queue.append(row("first"), T))
        val second = assertNotNull(queue.append(row("second"), T))
        val third = assertNotNull(queue.append(row("third"), T))

        // Draining twice hands the same rows over twice on purpose: a crash between
        // the drain and Dart's write must leave the rows, and CAP-5's dedup makes the
        // repeat harmless.
        assertEquals(listOf("first", "second", "third"), drainedTexts(queue))
        assertEquals(listOf("first", "second", "third"), drainedTexts(queue))

        queue.ack(listOf(second))
        assertEquals(listOf("first", "third"), drainedTexts(queue))

        queue.ack(listOf(first, third))
        assertEquals(emptyList(), queue.drain())
        assertTrue(queue.append(row("after the queue emptied"), T) != null)
        assertEquals(listOf("after the queue emptied"), drainedTexts(queue))
    }

    @Test
    fun `a message text holding a newline and a tab survives the rewrite intact`() {
        val queue = queueOn(file)
        // The file is one row per line and tab-separated, and the text in it was
        // written by whoever sent the message, not by us (CAP-15). An unescaped
        // newline would split one event into two unparseable lines; an unescaped tab
        // would move the row-id boundary and make the row un-ageable.
        val text = "first line\nsecond line\tafter a tab\r\nand a carriage return"
        val kept = assertNotNull(queue.append(row(text), T))
        val dropped = assertNotNull(queue.append(row("a second row"), T))

        // An ack is the rewrite: read every line, drop one, write the rest back.
        queue.ack(listOf(dropped))

        val lines = queue.drain()
        assertEquals(1, lines.size, "the escaped text must still be one physical line")
        assertEquals(kept, lines.single().substringBefore("\t"))
        assertEquals(text, JSONObject(lines.single().substringAfter("\t")).getString("text"))

        // And the row is still ageable after all that, which is what the tab would
        // have broken: queuedAtOf() reads the JSON after the first tab.
        queue.prune(T + 31 * DAY_MS)
        assertEquals(emptyList(), queue.drain())
    }

    @Test
    fun `prune on a queue that was never written does nothing and creates nothing`() {
        val queue = queueOn(file)

        queue.prune(T)

        assertTrue(!file.exists(), "prune must not bring the queue file into existence")
        assertEquals(emptyList(), queue.drain())
    }

    @Test
    fun `an ack that cannot read the queue deletes nothing`() {
        // The defect this pins: read() swallowed every exception and answered
        // emptyList(), so one transient IOException on readLines() during an ack made
        // the kept list empty, write() read that as "nothing left" and deleted the
        // file -- destroying every queued event, including rows that pass had never
        // been handed and Dart had never seen. The queue is the only copy of a message
        // captured while the app was not running (CAP-13), so those messages are gone
        // with nothing on screen to say so.
        //
        // A directory at the queue's path is how the failure is reached portably: it
        // exists, so read() gets past the exists() check, and readLines() throws on
        // every platform. What is asserted is the destructive step itself -- the
        // unconditional delete -- because that is what turned a failed read into lost
        // messages. An empty directory is deletable, so the old code removed this path
        // and the new code must not.
        val queue = queueOn(file)
        assertTrue(file.mkdirs(), "the test needs a directory where the queue file goes")

        queue.ack(listOf("some-row-id"))

        assertTrue(file.exists(), "an unreadable queue must not be deleted by an ack")
    }

    @Test
    fun `a prune that cannot read the queue drops nothing`() {
        // Same rule: a read that failed says nothing about the file's age, so nothing
        // is swept on it. CAP-15's window is a claim about how long a row may live,
        // not a licence to delete rows nobody could count.
        val queue = queueOn(file)
        assertTrue(file.mkdirs(), "the test needs a directory where the queue file goes")

        queue.prune(T + 31 * DAY_MS)

        assertTrue(file.exists(), "an unreadable queue must not be deleted by a prune")
        assertEquals(emptyList(), queue.drain(), "an unreadable queue hands nothing over")
    }

    @Test
    fun `an ack that reads the queue and accounts for every row still deletes it`() {
        // The other half of the rule. Empty-because-read must keep working, or the
        // file would grow for ever and CAP-15's own claim about it would be the thing
        // that broke.
        val queue = queueOn(file)
        val only = assertNotNull(queue.append(row("the only row"), T))

        queue.ack(listOf(only))

        assertTrue(!file.exists(), "a queue with every row acked is deleted, not left empty")
    }

    @Test
    fun `a row past the size cap is refused rather than written`() {
        // CAP-15 bounds how long the queue holds a row; nothing bounded how big one
        // could be. A notification is free to carry close to a megabyte of EXTRA_TEXT,
        // and a source app that re-posts one grows capture-queue.jsonl by that much
        // every time, until the 30-day sweep. That is unbounded growth of a file
        // holding other people's message text, which is what docs/privacy-policy.md
        // makes a promise about.
        val queue = queueOn(file)
        val small = assertNotNull(queue.append(row("an ordinary message"), T))
        val huge = "x".repeat(300 * 1024)

        assertNull(queue.append(row(huge), T), "an oversized row is refused, and says so")

        // Refused, not half-written: the queue still holds exactly what it held.
        assertEquals(listOf("an ordinary message"), drainedTexts(queue))
        assertEquals(small, queue.drain().single().substringBefore("\t"))
    }

    @Test
    fun `a large but sane row is still written`() {
        // The cap has to be past anything a messaging app really posts, or it becomes
        // its own silent data loss. 25 history entries (the projection's cap) of long
        // messages are a few kilobytes.
        val queue = queueOn(file)
        val long = "y".repeat(32 * 1024)

        assertNotNull(queue.append(row(long), T), "a long message is a message, not an attack")
        assertEquals(listOf(long), drainedTexts(queue))
    }
}
