package com.oasisforge.replybox.capture

import java.io.File

/**
 * A fresh [CaptureQueue] / [CaptureStore] on a file this test owns.
 *
 * Both classes are process singletons reached through `of(context)`, and the
 * constructor that takes nothing but a File is private. A unit test needs a new
 * instance per test for two reasons: there is no Context here, and the state these
 * tests are about -- `loadAttempted`, `readable`, `everSeenComplete` -- is
 * per-instance and loads once. Sharing one singleton would let the first test that
 * corrupts a store decide the answers of every test after it.
 *
 * Reflection rather than an edit to those classes: CaptureStore.kt is being changed
 * elsewhere on this branch, and a test that reaches in is the smaller thing to undo.
 * Widening each `private constructor(file: File)` to `internal constructor` is all
 * this needs -- AGP compiles the unit tests as a friend of the main source set, so
 * `internal` is visible here -- and both helpers below then become plain calls.
 */
internal fun queueOn(file: File): CaptureQueue =
    CaptureQueue::class.java
        .getDeclaredConstructor(File::class.java)
        .apply { isAccessible = true }
        .newInstance(file)

internal fun storeOn(file: File): CaptureStore =
    CaptureStore::class.java
        .getDeclaredConstructor(File::class.java)
        .apply { isAccessible = true }
        .newInstance(file)

/**
 * `android/app`, found by walking up from wherever the test runner started.
 *
 * Gradle runs unit tests with the project directory as the working directory, but
 * an IDE and a `--tests` run from the repo root do not, so the walk is what makes a
 * source-reading test give the same answer everywhere. A test that silently found no
 * sources would pass while asserting nothing, so the callers fail rather than skip.
 */
internal fun androidAppDir(): File {
    var dir: File? = File("").absoluteFile
    while (dir != null) {
        for (candidate in listOf(dir, File(dir, "android/app"))) {
            if (File(candidate, "src/main/kotlin/com/oasisforge/replybox/capture").isDirectory) return candidate
        }
        dir = dir.parentFile
    }
    throw AssertionError("could not find android/app above ${File("").absoluteFile}")
}

/** A directory no other test shares, so a leftover file cannot cross a test boundary. */
internal fun newTempDir(prefix: String): File =
    File(System.getProperty("java.io.tmpdir"), "$prefix-${System.nanoTime()}").apply { mkdirs() }

/**
 * A fixed instant, so an assertion about the 30-day window never depends on when the
 * suite ran. 21 September 2026, the date the capture rules were written.
 */
internal const val T: Long = 1_789_000_000_000L

internal const val DAY_MS: Long = 24L * 60 * 60 * 1000
