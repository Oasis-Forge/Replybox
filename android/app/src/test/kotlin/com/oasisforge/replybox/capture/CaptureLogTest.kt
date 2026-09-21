package com.oasisforge.replybox.capture

import org.json.JSONException
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * INB-24: nothing in the capture package writes a message's text, a sender's name,
 * a conversation title or the device's package list to logcat, in any build.
 *
 * ## Why this file exists, and why the obvious test cannot be written here
 *
 * The leak this guards was `Log.e(TAG, "could not read the capture store", e)`,
 * where `e` was the JSONException from `JSONObject(file.readText())`. On a device,
 * `org.json.JSONTokener.syntaxError` composes its message as `message + this`, and
 * `JSONTokener.toString()` is `" at character " + pos + " of " + in` -- `in` being
 * the whole input. `capture-store.json` names every app that has ever posted a
 * notification on the phone, so that one line put the device's package list into
 * logcat.
 *
 * **A test that parsed bad JSON and inspected the exception could not catch it**,
 * and still cannot: build.gradle.kts puts the *reference* `org.json:json` ahead of
 * the stub android.jar on the unit-test classpath -- it has to, or CaptureQueue's
 * and CaptureStore's file formats would be asserted against a stub that answers
 * null -- and the reference `JSONTokener.toString()` returns only the class name and
 * position. It does not echo the input. So on this classpath the leak is invisible
 * by construction, and a test written that way would pass on the exact build that
 * ships the defect.
 *
 * What is asserted instead does not depend on which org.json is loaded:
 *
 *  1. [`the formatted line names the exception class and nothing else`] executes the
 *     real formatter against an exception whose own message carries the input, which
 *     is what Android's JSONException does. This is the shipped rule, run.
 *  2. [`the capture package holds exactly one android_util_Log call`] holds the rule
 *     structurally, because (1) can only prove that CaptureLog is safe -- not that
 *     every catch block goes through it. A throwable passed to `Log` anywhere else
 *     in the package is a leak again, whatever CaptureLog does.
 *
 * The second is the weaker kind of test and is written as one. What actually covers
 * the behaviour on a device is that there is one `Log` call in the package and it is
 * fed a String built by a function this file executes.
 */
class CaptureLogTest {

    @Test
    fun `the formatted line names the exception class and nothing else`() {
        // Shaped like Android's: the parser's message carries the text it was
        // parsing. These are the two things INB-24 names -- the package list from
        // capture-store.json, and message text from capture-queue.jsonl.
        val leaked =
            """{"everSeen":["com.whatsapp","org.thoughtcrime.securesms"]} at character 3 of {"text":"see you at six"}"""
        val error = JSONException(leaked)

        val line = CaptureLog.describe("could not read the capture store", error)

        assertEquals("could not read the capture store (org.json.JSONException)", line)
        assertFalse(line.contains("com.whatsapp"), "a package name reached the log line: $line")
        assertFalse(line.contains("org.thoughtcrime.securesms"), "a package name reached the log line: $line")
        assertFalse(line.contains("see you at six"), "message text reached the log line: $line")
        assertFalse(line.contains(leaked), "the exception's own message reached the log line: $line")
    }

    @Test
    fun `a failure with no throwable is the message alone`() {
        // CaptureQueue refuses an oversized row this way: a real failure with no
        // exception behind it, reported by size and never by content.
        assertEquals(
            "a capture row was refused",
            CaptureLog.describe("a capture row was refused", null),
        )
    }

    @Test
    fun `the capture package holds exactly one android_util_Log call`() {
        val offenders = mutableListOf<String>()
        var callsInCaptureLog = 0

        for (source in captureSources()) {
            val calls = LOG_CALL.findAll(source.readText()).map { it.value }.toList()
            if (source.name == "CaptureLog.kt") {
                callsInCaptureLog = calls.size
                // The one permitted call, and its second argument is a String this
                // test has already run: never a throwable, so there is no third.
                for (call in calls) {
                    if (call != "Log.e(TAG, describe(") {
                        offenders.add("${source.name}: $call")
                    }
                }
            } else {
                calls.forEach { offenders.add("${source.name}: $it") }
            }
        }

        assertEquals(
            emptyList(),
            offenders,
            "android.util.Log is reached outside CaptureLog.failure. A throwable handed to Log " +
                "carries whatever it was raised over -- a parser's exception carries the parsed " +
                "text -- so every catch block in this package reports through CaptureLog (INB-24).",
        )
        assertEquals(1, callsInCaptureLog, "CaptureLog should hold exactly one Log call")
    }

    private companion object {
        /**
         * A `Log.x(` call and the start of its argument list.
         *
         * The lookbehind is what keeps `CaptureLog.failure(...)` -- the call every
         * catch block is supposed to make -- from reading as a call to `Log` itself.
         */
        val LOG_CALL = Regex("""(?<![A-Za-z])Log\.[a-z]+\([^,)]*,\s*[a-zA-Z]+\(?""")

        fun captureSources(): List<File> {
            val relative = "src/main/kotlin/com/oasisforge/replybox/capture"
            var dir: File? = File("").absoluteFile
            while (dir != null) {
                for (candidate in listOf(File(dir, relative), File(dir, "android/app/$relative"))) {
                    if (candidate.isDirectory) {
                        val sources = candidate.listFiles { f: File -> f.name.endsWith(".kt") }.orEmpty().sorted()
                        assertTrue(sources.isNotEmpty(), "no Kotlin sources under $candidate")
                        return sources
                    }
                }
                dir = dir.parentFile
            }
            fail("could not find $relative above ${File("").absoluteFile}")
        }
    }
}
