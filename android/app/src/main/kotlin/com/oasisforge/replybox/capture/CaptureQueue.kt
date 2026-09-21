package com.oasisforge.replybox.capture

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * The hand-over queue between the listener and Dart (CAP-13, CAP-15).
 *
 * One projected event per line, `"<rowId>\t<json>"`. A line, not a JSON array: an
 * array has to be read, parsed and rewritten whole on every notification, and a
 * burst is exactly the moment that would drop events (CAP-4's fixture delivered
 * five messages in one).
 *
 * The file lives in `context.filesDir`, which is private to the app and is the
 * `domain="file"` that res/xml/data_extraction_rules.xml excludes from cloud backup
 * and device-to-device transfer (CAP-24). The spike wrote to getExternalFilesDir,
 * which is world-readable; a queue holding message text must never go there.
 */
class CaptureQueue private constructor(private val file: File) {

    /**
     * Appends and rewrites are serialised against each other. The listener's
     * callbacks and the MethodChannel's drain/ack run on the same process but not
     * necessarily the same thread, and a rewrite racing an append loses events.
     */
    private val lock = Any()

    /**
     * Adds one projected event. Returns the row id, or null if it could not be
     * written -- in which case the failure is counted in CaptureFaults, so a
     * screen can say an event was lost rather than the app quietly holding less
     * than it claims (CAP-12, RUN-1).
     *
     * [now] is stamped into the row as its own age. CAP-15's sweep drops a row
     * undrained after 30 days, and the only honest clock for that is when *we*
     * queued it: `postTime` is when the source app posted, so a CAP-22 removal of
     * a notification that sat in the shade for a month arrives carrying a
     * month-old `postTime` and would be swept on sight -- losing the one event
     * that marks the conversation read.
     */
    fun append(row: JSONObject, now: Long = System.currentTimeMillis()): String? {
        val rowId = UUID.randomUUID().toString()
        row.put(KEY_QUEUED_AT, now)
        // org.json escapes newlines inside strings, so a projected event is always
        // one physical line -- which is what makes the line-per-row format safe for
        // message text the app did not write.
        val line = rowId + SEPARATOR + row.toString() + "\n"
        // CAP-15 bounds how long this file holds a row; nothing bounded how big one
        // row could be. A notification is free to carry a megabyte of EXTRA_TEXT --
        // the binder payload is about 1 MB and the app that posts it chooses how to
        // spend that -- and a source app that re-posts such a notification once a
        // minute writes a megabyte a minute into capture-queue.jsonl, which then
        // sits on the phone until the 30-day sweep. That is unbounded growth of a
        // file holding other people's message text, which is the one thing
        // docs/privacy-policy.md promises about it (CAP-15, CAP-24).
        //
        // An oversized row is refused rather than truncated: truncating would store
        // a message the app then presents as complete, and product principle 3 says
        // it does not do that. Refusing is counted in CaptureFaults like any other
        // failed append, so a screen can say the app is holding less than it claims
        // rather than the event vanishing in silence (CAP-12, RUN-1).
        if (line.length > MAX_ROW_CHARS) {
            synchronized(lock) { CaptureFaults.queueWriteFailed(now) }
            // The size, never the row: the row is somebody's message (INB-24).
            CaptureLog.failure("a capture row was refused: ${line.length} characters is past the cap")
            return null
        }
        return synchronized(lock) {
            try {
                file.appendText(line)
                rowId
            } catch (e: Exception) {
                // CAP-24 and product principle 1: a failed write is reported without
                // its payload. Never log the row -- it holds someone's message --
                // and never the throwable either, because an exception raised while
                // handling that text can carry it (INB-24, see CaptureLog).
                CaptureFaults.queueWriteFailed(now)
                CaptureLog.failure("could not append a capture row", e)
                null
            }
        }
    }

    /**
     * Every undrained row, oldest first, as `"<rowId>\t<json>"`.
     *
     * A queue that could not be read answers empty, which is the only answer it
     * can give -- but it is an answer about this call and not about the file, and
     * [ack] and [prune] are careful to keep those two apart.
     */
    fun drain(): List<String> = synchronized(lock) { read() ?: emptyList() }

    /**
     * Deletes exactly these rows.
     *
     * Dart acks after its ingest loop, not inside it: CaptureSync writes each
     * drained row in its own transaction, collects the ids of the ones that were
     * dealt with, and makes one `ackQueue` call at the end of the pass
     * (android_capture_service.dart, `_syncOnce`). So a crash between the drain and
     * the write leaves every row of that pass in place and it is simply drained
     * again -- CAP-5's dedup makes the repeat harmless, and that is what the split
     * buys (CAP-15).
     *
     * **A failed read is not an empty queue.** [read] used to swallow any exception
     * and answer `emptyList()`, so one transient IOException on `readLines()` during
     * an ack made `kept` empty, [write] took the empty list as "nothing left" and
     * deleted the file -- destroying every queued event, including rows this pass
     * had never seen and Dart had never been handed. The queue is the only copy of a
     * message captured while the app was not running (CAP-13), so that is a message
     * lost with nothing on screen. A read that failed therefore changes nothing at
     * all: the rows stay, the next pass drains them again.
     */
    fun ack(rowIds: Collection<String>) {
        if (rowIds.isEmpty()) return
        val drop = rowIds.toHashSet()
        synchronized(lock) {
            val all = read() ?: return
            write(all.filterNot { drop.contains(rowIdOf(it)) })
        }
    }

    /**
     * CAP-15: a row still undrained after 30 days is dropped on the next service
     * start. Without this the queue is unbounded on a phone where the app is never
     * opened again, and it would hold message text indefinitely -- which is a
     * privacy-policy claim, not a housekeeping preference.
     */
    fun prune(now: Long) {
        synchronized(lock) {
            if (!file.exists()) return
            // Same rule as [ack]: a read that failed says nothing about what the
            // file holds, so nothing is dropped on it.
            val all = read() ?: return
            val kept = all.filter { line -> queuedAtOf(line)?.let { now - it <= MAX_AGE_MS } ?: false }
            if (kept.size != all.size) write(kept)
        }
    }

    /**
     * Every non-blank line, or **null** when the file could not be read.
     *
     * Null rather than `emptyList()`, because the two have opposite consequences:
     * an empty queue means "delete the file", and an unreadable one means "touch
     * nothing". Folding them together is what let one IOException delete the whole
     * undrained queue -- see [ack].
     */
    private fun read(): List<String>? = try {
        if (file.exists()) file.readLines().filter { it.isNotBlank() } else emptyList()
    } catch (e: Exception) {
        // The class only: the lines being read are other people's messages, and a
        // throwable raised while reading them can carry them (INB-24, CaptureLog).
        CaptureLog.failure("could not read the capture queue", e)
        null
    }

    /**
     * Replaces the file with exactly [lines], or deletes it when there are none.
     *
     * Only ever called with a list derived from a **successful** [read]. The delete
     * is the destructive step, so it is stated here as well as guarded at both call
     * sites: an empty list has to mean "every row was accounted for", never "the
     * rows could not be counted".
     */
    private fun write(lines: List<String>) {
        try {
            if (lines.isEmpty()) {
                file.delete()
                return
            }
            // Written beside the queue and renamed over it: rename(2) replaces
            // atomically, so a crash mid-rewrite leaves the old queue rather than a
            // truncated one. Losing captured messages to a power cut is not a
            // trade-off worth the simpler call.
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(lines.joinToString("\n", postfix = "\n"))
            if (!tmp.renameTo(file)) {
                file.writeText(lines.joinToString("\n", postfix = "\n"))
                tmp.delete()
            }
        } catch (e: Exception) {
            // The class only, for the same reason (INB-24, CaptureLog).
            CaptureLog.failure("could not rewrite the capture queue", e)
        }
    }

    private fun rowIdOf(line: String): String = line.substringBefore(SEPARATOR)

    /**
     * How old [prune] considers a row: the moment [append] queued it, never the
     * notification's `postTime`. A message can sit unread in the shade for longer
     * than CAP-15's window and still be captured today; what the rule caps is how
     * long *this queue* holds a row, which is a privacy-policy claim about our own
     * file.
     *
     * `postTime` is the fallback for a row written before this stamp existed, so
     * an upgrade does not sweep away an undrained queue. A row with neither is
     * dropped: every row this class writes carries one, so a row without either is
     * corrupt, and a corrupt row that can never be aged would defeat the 30-day
     * cap forever.
     */
    private fun queuedAtOf(line: String): Long? = try {
        val json = line.substringAfter(SEPARATOR, missingDelimiterValue = "")
        if (json.isEmpty()) {
            null
        } else {
            val row = JSONObject(json)
            row.optLong(KEY_QUEUED_AT).takeIf { it > 0L } ?: row.optLong("postTime").takeIf { it > 0L }
        }
    } catch (e: Exception) {
        null
    }

    companion object {
        private const val SEPARATOR = "\t"

        /**
         * The row's own age (CAP-15). A projection field name would be a field the
         * spike's dumps carry; this one is the queue's, so it is named for what it
         * is and Dart ignores it like any other key it does not read.
         */
        private const val KEY_QUEUED_AT = "queuedAt"
        const val FILE_NAME = "capture-queue.jsonl"
        private const val MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000

        /**
         * The widest single row the queue accepts, row id and JSON together, in
         * characters (see [append]).
         *
         * 256 KiB, chosen against the shape of a real event rather than against the
         * binder limit: a MessagingStyle notification capped at 25 history entries
         * (NotificationProjection.MAX_HISTORY) is a few kilobytes, so this is two
         * orders of magnitude of headroom over anything a messaging app posts and
         * still small enough that a pathological notification cannot fill the phone.
         * It is a cap on our file, not a judgement about the notification.
         */
        internal const val MAX_ROW_CHARS = 256 * 1024

        @Volatile
        private var instance: CaptureQueue? = null

        /**
         * One queue per process, shared by the listener and the MethodChannel. Only
         * the File is kept: holding the Context would outlive whichever of the two
         * created it.
         */
        fun of(context: Context): CaptureQueue =
            instance ?: synchronized(this) {
                instance ?: CaptureQueue(File(context.applicationContext.filesDir, FILE_NAME)).also { instance = it }
            }
    }
}
