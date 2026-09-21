package com.oasisforge.replybox.capture

/**
 * What capture could not do, in a form Dart can ask for.
 *
 * CAP-12 and RUN-1: an absence the app cannot explain reads as a bug, so a
 * notification the listener could not hand over has to be reachable rather than
 * only logged. Nothing here is a screen -- it is the fact a screen can state
 * (`captureFaults` on the MethodChannel).
 *
 * Counts and times only. Never a package, never a title, never a text: a fault
 * record that carried the row it lost would put message content somewhere the
 * database's rules do not reach (product principle 1, INB-24). The counters live
 * in memory with the process that hit the fault, which is the same lifetime as
 * the failure itself being current.
 */
object CaptureFaults {

    private var queueWriteFailures = 0
    private var lastQueueWriteFailureAt = 0L
    private var storeWriteFailures = 0
    private var lastStoreWriteFailureAt = 0L
    private var storeUnreadable = false

    /**
     * An event that could not be appended to the hand-over queue (CAP-15). The
     * live nudge still goes out, so this is not always a lost event -- it is an
     * event that survives only if a Dart isolate was running to hear it.
     */
    @Synchronized
    fun queueWriteFailed(now: Long) {
        queueWriteFailures++
        lastQueueWriteFailureAt = now
    }

    /** The included-apps store could not be written; the process's own copy is ahead of the disk. */
    @Synchronized
    fun storeWriteFailed(now: Long) {
        storeWriteFailures++
        lastStoreWriteFailureAt = now
    }

    /**
     * Whether the included-apps store could not be read. While this is true the
     * listener captures nothing at all (CAP-1 fails closed, product principle 4),
     * which is exactly the state a screen has to be able to say out loud.
     */
    @Synchronized
    fun setStoreUnreadable(unreadable: Boolean) {
        storeUnreadable = unreadable
    }

    /** Everything above, as the MethodChannel's answer. */
    @Synchronized
    fun snapshot(): Map<String, Any> = mapOf(
        "queueWriteFailures" to queueWriteFailures,
        "lastQueueWriteFailureAt" to lastQueueWriteFailureAt,
        "storeWriteFailures" to storeWriteFailures,
        "lastStoreWriteFailureAt" to lastStoreWriteFailureAt,
        "storeUnreadable" to storeUnreadable,
    )
}
