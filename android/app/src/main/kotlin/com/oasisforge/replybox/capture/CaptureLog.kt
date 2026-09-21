package com.oasisforge.replybox.capture

import android.util.Log

/**
 * The only place in the capture package that is allowed to touch
 * [android.util.Log].
 *
 * INB-24: no code path here may write a message's text, a sender's name, a
 * conversation title or the device's package list to logcat, in any build. A
 * plain `Log.e(TAG, "...", e)` breaks that rule silently, because **a throwable
 * from a parser carries the text it was parsing**. Android's own
 * `org.json.JSONTokener.syntaxError` builds its message as `message + this`, and
 * `JSONTokener.toString()` is `" at character " + pos + " of " + in` -- `in`
 * being the entire input string. So a JSONException thrown while reading
 * `capture-store.json` used to put every package name and app label that had ever
 * posted a notification on this phone into logcat, and one thrown while reading
 * `capture-queue.jsonl` would put other people's messages there.
 *
 * The rule is therefore structural rather than case-by-case: the throwable never
 * reaches Log at all. Only its class name does, which is what is actually
 * diagnostic -- "this was a JSONException" and not "this was the contents".
 *
 * A stack trace is lost with it, and that is the trade. Every catch site in this
 * package already knows exactly which call it wrapped, so the class name plus the
 * message written here names the failure precisely enough to act on, and there is
 * no diagnostic worth a privacy-policy claim (product principle 1, CAP-27).
 */
internal object CaptureLog {

    private const val TAG = "ReplyboxCapture"

    /**
     * Reports a failure without its payload. See [describe].
     *
     * One `Log` call in the whole package, on purpose: CaptureLogTest asserts
     * that this file holds the only one, which is what stops a
     * `Log.e(TAG, "...", e)` reappearing somewhere the classpath cannot catch it.
     */
    fun failure(what: String, error: Throwable? = null) {
        Log.e(TAG, describe(what, error))
    }

    /**
     * What [failure] writes, as a pure function so a JVM test runs the real rule
     * rather than a regular expression over it (CaptureLogTest).
     *
     * The class name and nothing else: never `error.message`, never
     * `error.toString()`, never the throwable itself.
     */
    fun describe(what: String, error: Throwable?): String =
        if (error == null) what else "$what (${error.javaClass.name})"
}
