package com.oasisforge.replybox.capture

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * PERM-12, held structurally: **nothing from the app's own package reaches the
 * native queue, in any build, by any route.**
 *
 * ## Why this is a source-reading test and not a behavioural one
 *
 * The behaviour is two lines inside a `NotificationListenerService`, reached only
 * from framework callbacks with a real `StatusBarNotification`. Neither can be built
 * on this classpath -- the stub `android.jar` answers null to everything and
 * `NotificationProjectionTest` documents the same limit for `project` -- so there is
 * no honest way to execute `capture()` here. What CAN be asserted, and is worth
 * more than an executed copy of the rule, is that the guard is **unconditional**:
 * no flag, no build type, no debug escape.
 *
 * That matters because the debug source set now contains one. `SpikeCaptureBridge`
 * exists so CAP-21's storage path can be driven on a device, and the tempting way to
 * write it was a debug-only exception inside `ReplyboxListenerService`. This file is
 * the reason that was not done and the reason it stays not done: it fails the moment
 * the guard grows a condition, the moment anything in `src/main` learns the spike
 * package exists, and the moment the bridge's substituted package could be mistaken
 * for the app itself.
 *
 * A release build cannot take the escape because there is no escape to take. The
 * proof is in three parts, and all three are below:
 *
 *  1. the guard is the first statement of both entry points and has no condition
 *     attached to it;
 *  2. nothing in the shipped capture package mentions a build type, `BuildConfig`,
 *     the debuggable flag or the spike, so there is no second route to weaken and
 *     nothing in a release build that could call one;
 *  3. every file that names the bridge lives under `src/debug`, which AGP does not
 *     compile into a release variant at all.
 *
 * (3) is the structural one: the escape is in a source set the release build never
 * sees. (1) and (2) are what stop a later change from moving it.
 */
class OwnPackageGuardTest {

    @Test
    fun `the own-package drop is the first statement of both entry points`() {
        assertEquals(emptyList(), firstStatementComplaints(listenerSource().readText()))
    }

    @Test
    fun `the drop carries no condition`() {
        assertEquals(emptyList(), unconditionalComplaints(listenerSource().readText()))
    }

    /**
     * The two checks above, run against a source that has been weakened on purpose.
     *
     * Without this they are only as good as their regexes, and a source-reading test
     * whose pattern has quietly stopped matching passes on every build including the
     * one that ships the defect -- the exact failure mode `CaptureLogTest` documents
     * for the leak it could not catch by parsing. Nothing on disk is touched: each
     * mutant is the real file's text with one edit applied in memory, and the test
     * fails if any of them is accepted.
     *
     * The list is every shape a debug escape has been proposed in, plus the two ways
     * the drop could be moved instead of conditioned.
     */
    @Test
    fun `the checks reject every weakening of the drop`() {
        val source = listenerSource().readText()
        val survivors = mutableListOf<String>()
        for ((name, mutant) in mutants(source)) {
            val complaints = firstStatementComplaints(mutant) + unconditionalComplaints(mutant)
            if (complaints.isEmpty()) survivors.add(name)
        }
        assertEquals(
            emptyList(),
            survivors,
            "A weakened own-package drop was accepted by the checks above, so those checks prove nothing " +
                "about the version that ships (PERM-12).",
        )
    }

    @Test
    fun `the shipped capture package knows nothing about build types or the spike`() {
        val offenders = mutableListOf<String>()
        for (source in shippedSources()) {
            val text = source.readText()
            for (token in FORBIDDEN_IN_SHIPPED) {
                if (text.contains(token)) offenders.add("${source.name}: $token")
            }
        }
        assertEquals(
            emptyList(),
            offenders,
            "Shipped capture code branches on nothing build-type-shaped and names nothing in the debug " +
                "source set. A release build therefore has no escape to take and no bridge to call: the " +
                "debug-only path reaches capture through CaptureStore's and CaptureQueue's public API, " +
                "and src/main must stay unaware it exists (PERM-12).",
        )
    }

    @Test
    fun `the bridge is a debug source set class and no shipped code names it`() {
        val app = androidAppDir()
        assertTrue(
            File(app, "src/debug/kotlin/com/oasisforge/replybox/spike/$BRIDGE.kt").isFile,
            "$BRIDGE is gone from src/debug, or it moved. If it moved into a shipped source set, the " +
                "escape moved with it; if it was deleted, delete this test rather than leaving a proof " +
                "of nothing.",
        )
        // src/main only. The unit-test source sets are not in any APK, and this file
        // is itself one of them -- but every shipped variant, release included,
        // compiles src/main, so a reference there is a reference a release build can
        // follow.
        val shipped = File(app, "src/main").walkTopDown()
            .filter { it.isFile }
            .filter { it.readText().contains(BRIDGE) }
            .map { it.relativeTo(app).path.replace('\\', '/') }
            .toList()
        assertEquals(
            emptyList(),
            shipped,
            "Shipped code names $BRIDGE. It lives in src/debug, which AGP does not compile into a " +
                "release variant at all -- that absence is what makes the escape impossible to take " +
                "rather than merely guarded, and it only holds while nothing in src/main reaches for it.",
        )
    }

    @Test
    fun `the bridge's substituted package cannot be mistaken for this app`() {
        val applicationId = Regex("""applicationId\s*=\s*"([^"]+)"""")
            .find(File(androidAppDir(), "build.gradle.kts").readText())
            ?.groupValues?.get(1)
        assertEquals("com.oasisforge.replybox", applicationId, "the application id moved; PERM-12's drop is about this string")

        val substitute = assertNotNull(
            Regex("""SUBSTITUTE_PACKAGE\s*=\s*"([^"]+)"""")
                .find(File(androidAppDir(), "src/debug/kotlin/com/oasisforge/replybox/spike/SpikeCaptureBridge.kt").readText())
                ?.groupValues?.get(1),
            "the bridge no longer names a substituted package",
        )

        assertFalse(
            substitute == applicationId || substitute.startsWith("$applicationId."),
            "PERM-12 promises Replybox never appears as a source app. A substituted package equal to the " +
                "application id, or sitting under it, appears in the included-apps list and in a database " +
                "dump as exactly that. Got: $substitute",
        )
        assertFalse(
            ShippedApps.PACKAGES.contains(substitute),
            "A substituted package inside the shipped list would be switched on by CAP-1 without the user, " +
                "and the drill would skip the step it exists to prove. Got: $substitute",
        )
    }

    private companion object {
        const val GUARD = "if (sbn.packageName == packageName) return"
        const val BRIDGE = "SpikeCaptureBridge"

        /**
         * Empty when [source] opens both entry points with the drop. Returns the
         * complaints rather than asserting, so the mutation test can ask the same
         * question of a source that is supposed to fail.
         */
        fun firstStatementComplaints(source: String): List<String> {
            val out = mutableListOf<String>()
            for (signature in ENTRY_POINTS) {
                val start = source.indexOf(signature)
                if (start < 0) {
                    out.add("$signature is gone from ReplyboxListenerService; PERM-12's drop moved with it")
                    continue
                }
                val firstStatement = source.substring(start + signature.length)
                    .lineSequence().drop(1)
                    .map { it.trim() }
                    .firstOrNull { it.isNotEmpty() && !it.startsWith("//") && !it.startsWith("*") }
                if (firstStatement != GUARD) {
                    out.add(
                        "PERM-12: the app's own notifications are dropped before anything else happens in " +
                            "$signature. Anything running ahead of this line -- a store write, a projection, " +
                            "a log -- has already read or recorded a notification the app posted itself. " +
                            "Found: $firstStatement",
                    )
                }
            }
            return out
        }

        /** Empty when the drop is a bare equality with a bare `return`, twice. */
        fun unconditionalComplaints(source: String): List<String> {
            val out = mutableListOf<String>()
            val comparisons = Regex("""sbn\.packageName\s*[!=]=\s*packageName""").findAll(source).map { it.value }.toList()
            if (comparisons != listOf("sbn.packageName == packageName", "sbn.packageName == packageName")) {
                out.add(
                    "PERM-12's drop is an equality against the app's own package and nothing else. A " +
                        "negation, or a second comparison, means the drop now depends on something. " +
                        "Found: $comparisons",
                )
            }
            val guards = Regex("""if \(sbn\.packageName == packageName\)[^\n]*""").findAll(source).map { it.value }.toList()
            if (guards != listOf(GUARD, GUARD)) {
                out.add(
                    "The guard's line is `$GUARD` in both entry points. An `&&`, an `||` or a body other " +
                        "than `return` is a debug escape however it is spelled. Found: $guards",
                )
            }
            return out
        }

        /**
         * name to weakened source. Each applies one edit to the real text, which is
         * normalised to `\n` first: the repo is checked out with CRLF on Windows,
         * and a mutant whose pattern silently failed to match would be the original
         * file and would "survive" for no reason at all.
         */
        fun mutants(raw: String): List<Pair<String, String>> = with(raw.replace("\r\n", "\n")) {
            mutantsOf(this)
        }

        private fun mutantsOf(source: String): List<Pair<String, String>> = listOf(
            "a build-type condition on the drop" to
                source.replace(GUARD, "if (BuildConfig.DEBUG && sbn.packageName == packageName) return"),
            "a flag the drill could set" to
                source.replace(GUARD, "if (sbn.packageName == packageName && !allowOwnPackage) return"),
            "an or, which opens it for anything" to
                source.replace(GUARD, "if (sbn.packageName == packageName || allowOwnPackage) return"),
            "the drop negated" to
                source.replace(GUARD, "if (sbn.packageName != packageName) return"),
            "the drop made a log instead of a return" to
                source.replace(GUARD, "if (sbn.packageName == packageName) CaptureLog.failure(\"own package\", null)"),
            "the drop moved below the store write" to
                source.replace(
                    "$GUARD\n        val enabled = store.recordSeen",
                    "val enabled = store.recordSeen",
                ).replace(
                    "        if (!enabled) return",
                    "        $GUARD\n        if (!enabled) return",
                ),
            "the drop deleted outright" to source.replace(GUARD, ""),
        )

        /** The two functions that read a notification. Both drop the app's own first. */
        val ENTRY_POINTS = listOf(
            "private fun capture(sbn: StatusBarNotification, seenAt: Long) {",
            "private fun removed(sbn: StatusBarNotification, reasonName: String?) {",
        )

        /**
         * Tokens that would give a release build something to branch on. `BuildConfig`
         * is the usual one; `DEBUG` catches `BuildConfig.DEBUG` however it is imported,
         * and the two `debuggable` spellings catch the ApplicationInfo route that needs
         * no BuildConfig at all.
         *
         * The spike tokens are the class names and the package, not the word
         * "spike": shipped comments cite the spike's dumps as evidence all over this
         * package, and citing a measurement is not depending on debug code.
         */
        val FORBIDDEN_IN_SHIPPED = listOf(
            "BuildConfig",
            "DEBUG",
            "isDebuggable",
            "FLAG_DEBUGGABLE",
            "com.oasisforge.replybox.spike",
            "SpikeCaptureBridge",
            "SpikeRawPoster",
            "SpikeListenerService",
        )

        fun listenerSource(): File =
            File(androidAppDir(), "src/main/kotlin/com/oasisforge/replybox/capture/ReplyboxListenerService.kt")

        fun shippedSources(): List<File> =
            File(androidAppDir(), "src/main/kotlin/com/oasisforge/replybox/capture")
                .listFiles { f: File -> f.name.endsWith(".kt") }.orEmpty().sorted()
    }
}
