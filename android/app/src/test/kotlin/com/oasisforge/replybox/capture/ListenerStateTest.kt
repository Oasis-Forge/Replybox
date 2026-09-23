package com.oasisforge.replybox.capture

import java.io.File
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * PERM-10's honesty, which is entirely about the third value.
 *
 * The rule reads on each resume whether *this app's own* listener is connected, and
 * the platform offers no way to ask -- only two callbacks into the service. So the
 * answer is a record of what this process has observed, and a process that has
 * observed nothing has to be able to say so: PERM-10 draws its line on a **false**,
 * and its ten-second wait exists precisely so that a listener which is merely slow
 * to bind is never accused. A null that decayed into a false anywhere between the
 * callback and the screen would be that accusation, on a first resume, on every
 * install.
 *
 * Three of the checks below are executed and the rest read source, and the split is
 * not a preference. [ListenerState] is plain Kotlin and runs here as the shipped
 * code. The channel branch that carries its value cannot: `CaptureChannel`'s
 * constructor takes a `Context`, which cannot be built on this classpath (the stub
 * android.jar answers null to every framework call -- `AppLaunchTest` and
 * `NotificationProjectionTest` document the same limit), and neither can the
 * `ComponentName` a rebind names. What a source read can still hold is the part a
 * compiler cannot: that the null crosses the channel *as a null*, that the rebind
 * has one outcome shape, and that no clock has appeared in Kotlin to disagree with
 * the one in the state layer. Each of those is paired with a mutation check, because
 * a source-reading test whose pattern has quietly stopped matching passes on every
 * build including the one that ships the defect (CaptureLogTest).
 */
class ListenerStateTest {

    /**
     * The object is a process singleton and the whole suite shares one JVM, so a
     * test that did not clear it would be asserting against whatever the test
     * before it left behind -- and the claim worth the most here is about the state
     * *before* anything has been observed.
     */
    @BeforeTest
    fun clear() = ListenerState.forget()

    /** And again afterwards, so no other test class inherits this one's leftovers. */
    @AfterTest
    fun clearAgain() = ListenerState.forget()

    @Test
    fun `a process that has observed neither callback answers null, never false`() {
        assertNull(
            ListenerState.connected,
            "PERM-10: a flag that is false because this process has not been bound yet is not the same as " +
                "one that is false because the listener died. The app and the listener share a process, so " +
                "the Activity's first resume can legitimately run before either callback has fired -- and " +
                "false there is the line `capture is not running right now` shown about a listener that is " +
                "binding perfectly well.",
        )
    }

    @Test
    fun `a connection is true and a disconnection is false`() {
        ListenerState.onConnected()
        assertEquals(true, ListenerState.connected)

        ListenerState.onDisconnected()
        assertEquals(
            false,
            ListenerState.connected,
            "false is the one value PERM-10 may draw its line on, and it means this process was told the " +
                "listener went away",
        )
    }

    @Test
    fun `a reconnection replaces a disconnection, so the line can be gone the moment it binds`() {
        ListenerState.onDisconnected()
        ListenerState.onConnected()

        assertEquals(
            true,
            ListenerState.connected,
            "PERM-10: the line is removed the moment the listener connects. A disconnection that stuck would " +
                "leave it on screen over a listener that had already rebound and re-read the shade (CAP-13).",
        )
    }

    @Test
    fun `a disconnection never becomes null again on its own`() {
        // The distinction the rule rests on, in the one direction a later refactor
        // could plausibly break: "learned nothing" is the state a process starts
        // in, and nothing may put it back there -- a false decaying to a null would
        // silently stop PERM-10 from ever showing its line.
        ListenerState.onDisconnected()
        ListenerState.onDisconnected()

        assertEquals(false, ListenerState.connected)
    }

    @Test
    fun `both lifecycle callbacks record the state before anything is queued`() {
        val source = listenerText()
        val complaints = orderComplaints(source)

        assertEquals(
            emptyList(),
            complaints,
            "PERM-10's read has to happen in the callback body, ahead of the `submit {` that hands the event " +
                "to the single-threaded worker. Behind the worker a reboot's backlog of captures sits in " +
                "front of the write, and a resume asking microseconds later would be told `not connected` " +
                "about a listener that had already said otherwise. The ordering the worker protects is " +
                "between events; this is a volatile field write and is not one.",
        )
    }

    @Test
    fun `the order check rejects a state write moved behind the worker`() {
        val survivors = orderMutants(listenerText())
            .filter { (_, mutant) -> orderComplaints(mutant).isEmpty() }
            .map { it.first }

        assertEquals(
            emptyList(),
            survivors,
            "a state write moved onto the worker was accepted by the check above, so it proves nothing",
        )
    }

    @Test
    fun `only the listener service writes the state, and nothing that ships clears it`() {
        val writers = shippedSourcesNaming("ListenerState.onConnected(", "ListenerState.onDisconnected(")

        assertEquals(
            listOf("ReplyboxListenerService.kt"),
            writers,
            "the two lifecycle callbacks are the only evidence PERM-10 has. Anything else writing this flag " +
                "would be the app deciding what it observed -- and a `true` written by something that is not " +
                "a binding is `capture is running` put on screen with nothing behind it.",
        )

        assertEquals(
            listOf("ListenerState.kt"),
            shippedSourcesNaming("forget("),
            "ListenerState.forget() is a door for this test file and nothing else. A shipped caller would be " +
                "manufacturing `learned nothing` out of a state the app had in fact learned, which is the " +
                "one value PERM-10 reads as `do not accuse the listener`.",
        )
    }

    @Test
    fun `the channel hands the tri-state over without collapsing it`() {
        val source = withoutComments(channelText())

        assertTrue(
            source.contains(BRANCH),
            "PERM-10's read crosses the channel as `$BRANCH`. A `?: false` makes a first resume accuse a " +
                "listener that is binding; an `== true` makes a null read as connected, which is the app " +
                "claiming capture is running on no evidence at all (product principle 3). Both are wrong, so " +
                "the third value stays a third value and the state layer decides.",
        )
        assertEquals(
            1,
            Regex(Regex.escape(READ)).findAll(source).count(),
            "the flag is read once, in that one branch. A second read in this file is somewhere the value " +
                "could be turned into a boolean before it leaves the platform.",
        )
    }

    @Test
    fun `the collapse check rejects every way the null could be spent as a boolean`() {
        val source = withoutComments(channelText())
        val survivors = collapseMutants(source)
            .filter { (_, mutant) -> mutant.contains(BRANCH) }
            .map { it.first }

        assertEquals(
            emptyList(),
            survivors,
            "a collapsed tri-state was accepted by the check above, so it proves nothing about the version " +
                "that ships (PERM-10)",
        )
    }

    @Test
    fun `the rebind asks for this app's own listener and nothing else`() {
        val source = withoutComments(channelText())

        assertTrue(
            source.contains(REBIND),
            "PERM-10's rebind is `$REBIND`. The component is the same one `hasAccess` compares against and " +
                "the same one PERM-7's detail intent carries; asking for a rebind of anything else is not " +
                "this app's business and the platform refuses it anyway.",
        )
        assertTrue(
            source.contains("private fun listenerComponent() = ComponentName(context, ReplyboxListenerService::class.java)"),
            "`listenerComponent()` is what makes the line above about this app's own service. If it now " +
                "resolves something else, PERM-5's access read and PERM-10's rebind are both pointed " +
                "somewhere new.",
        )
    }

    @Test
    fun `the rebind has one outcome shape, so nothing has to be collapsed on the Dart side`() {
        val source = withoutComments(channelText())

        assertTrue(
            source.contains("\"requestListenerRebind\" -> result.success(requestListenerRebind())"),
            "PERM-10 spends `the request was made` and `it could not even be made` the same way -- wait ten " +
                "seconds and ask again -- so the answer is a boolean",
        )
        assertTrue(
            source.contains("catch (e: RuntimeException)"),
            "the call rethrows a dead system server from the binder as an unchecked exception, and a refusal " +
                "for a component the caller does not own is a SecurityException; both are RuntimeException, " +
                "and either escaping would take PERM-10's read out with it",
        )
        assertEquals(
            listOf("bad_arguments", "no_settings_page"),
            Regex("""result\.error\(\s*"([a-z_]+)"""").findAll(source).map { it.groupValues[1] }.toList().sorted(),
            "this channel answers exactly two errors, and neither is PERM-10's. A third would be a second " +
                "failure shape for the Dart side to collapse back into false (PERM-7 is the one place an " +
                "error is the answer, because there the screen has a different thing to say).",
        )
    }

    @Test
    fun `no rebind clock lives in Kotlin`() {
        val source = withoutComments(channelText())
        val clocks = CLOCKS.filter { source.contains(it) }

        assertEquals(
            emptyList(),
            clocks,
            "PERM-10's at-most-one-request-per-resume and 60-second floor belong to the state layer: one " +
                "refresh is one resume, and only PermissionsProvider knows where a resume began. A clock " +
                "here would count method calls instead and would quietly disagree with the line the user is " +
                "being shown.",
        )
        assertTrue(
            channelText().contains("PermissionsProvider"),
            "and where the floor does live is written down in this file, so the next person to look for it " +
                "in Kotlin finds the answer rather than adding one",
        )
    }

    @Test
    fun `the disconnection the listener reports carries the callback's own time`() {
        // PERM-9's native half, which is already done and is asserted so it stays
        // done. The two observations PERM-8 has to tell apart -- the listener
        // reporting itself gone, and the app discovering it later -- are
        // distinguishable downstream because only the first one produces this event
        // at all, and it carries `now` from the callback body rather than the moment
        // a drain ran. The app never prints the time it noticed something as the time
        // that thing happened (product principle 3).
        val source = listenerText()
        val body = bodyOf(source, DISCONNECTED)

        assertTrue(
            body.contains("val now = System.currentTimeMillis()") &&
                body.contains("""NotificationProjection.lifecycle("listener_disconnected", now)"""),
            "the `listener_disconnected` event is stamped with the time the callback fired. Taking the time " +
                "inside the worker instead would date the loss to whenever the queue got round to it, and " +
                "PERM-9's exact close would silently become an estimate wearing an exact label (PERM-8).",
        )
    }

    @Test
    fun `the three files these checks read are where they think they are`() {
        // Every source read above is worthless if a file moved, and an empty read
        // would pass silently while asserting nothing (CaptureTestSubjects says the
        // same about its own walk up the tree).
        assertFalse(listenerText().isEmpty(), "ReplyboxListenerService.kt read as empty")
        assertFalse(channelText().isEmpty(), "CaptureChannel.kt read as empty")
        assertTrue(
            shippedSources().any { it.name == "ListenerState.kt" },
            "ListenerState.kt is no longer a shipped capture source, so the writer and forget() scans above " +
                "cover nothing",
        )
    }

    private companion object {

        /** PERM-10's read, as the channel spells it. */
        const val BRANCH = """"listenerConnected" -> result.success(ListenerState.connected)"""
        const val READ = "ListenerState.connected"
        const val REBIND = "NotificationListenerService.requestRebind(listenerComponent())"

        const val CONNECTED = "override fun onListenerConnected() {"
        const val DISCONNECTED = "override fun onListenerDisconnected() {"

        /**
         * Every shape a rate limit would arrive in. The two durations are PERM-10's
         * own numbers, written both ways Kotlin allows; a clock is what a floor
         * needs before it can be written at all, and this file holds none today.
         */
        val CLOCKS = listOf(
            "System.currentTimeMillis()",
            "SystemClock",
            "elapsedRealtime",
            "60_000",
            "60000",
            "10_000",
            "10000",
        )

        /**
         * Empty when both callbacks record the state ahead of their `submit {`.
         *
         * Returns complaints rather than asserting, so the mutation check can ask
         * the same question of a source that is supposed to fail.
         */
        fun orderComplaints(source: String): List<String> {
            val out = mutableListOf<String>()
            for ((signature, call) in listOf(
                CONNECTED to "ListenerState.onConnected()",
                DISCONNECTED to "ListenerState.onDisconnected()",
            )) {
                val body = bodyOf(source, signature)
                if (body.isEmpty()) {
                    out.add("$signature is gone from ReplyboxListenerService; PERM-10's read went with it")
                    continue
                }
                val write = body.indexOf(call)
                val submit = body.indexOf("submit {")
                when {
                    write < 0 -> out.add("$signature does not record PERM-10's state at all. Found: $body")
                    submit in 0 until write ->
                        out.add("$signature records PERM-10's state behind `submit {`, on the worker. Found: $body")
                }
            }
            return out
        }

        fun orderMutants(raw: String): List<Pair<String, String>> {
            val source = raw.replace("\r\n", "\n")
            return listOf(
                "the connection recorded on the worker" to
                    source.replace(
                        "        ListenerState.onConnected()\n",
                        "",
                    ).replace(
                        "            enqueue(NotificationProjection.lifecycle(\"listener_connected\", now))",
                        "            ListenerState.onConnected()\n" +
                            "            enqueue(NotificationProjection.lifecycle(\"listener_connected\", now))",
                    ),
                "the disconnection recorded on the worker" to
                    source.replace(
                        "        ListenerState.onDisconnected()\n",
                        "",
                    ).replace(
                        "            enqueue(NotificationProjection.lifecycle(\"listener_disconnected\", now))",
                        "            ListenerState.onDisconnected()\n" +
                            "            enqueue(NotificationProjection.lifecycle(\"listener_disconnected\", now))",
                    ),
                "the connection not recorded at all" to
                    source.replace("        ListenerState.onConnected()\n", ""),
                "the disconnection not recorded at all" to
                    source.replace("        ListenerState.onDisconnected()\n", ""),
            )
        }

        /** Every way the third value could be spent as a boolean at the border. */
        fun collapseMutants(source: String): List<Pair<String, String>> = listOf(
            "a null read as disconnected" to
                source.replace(BRANCH, """"listenerConnected" -> result.success(ListenerState.connected ?: false)"""),
            "a null read as connected" to
                source.replace(BRANCH, """"listenerConnected" -> result.success(ListenerState.connected != false)"""),
            "the flag compared instead of passed" to
                source.replace(BRANCH, """"listenerConnected" -> result.success(ListenerState.connected == true)"""),
            "the read removed outright" to source.replace(BRANCH, ""),
        )

        /**
         * The text of one function, from its signature to the first line that
         * closes it at the same indentation. Enough to ask what happened in which
         * order inside it, and nothing beyond it.
         */
        fun bodyOf(source: String, signature: String): String {
            val start = source.indexOf(signature)
            if (start < 0) return ""
            val rest = source.substring(start + signature.length)
            val end = rest.indexOf("\n    }")
            return if (end < 0) rest else rest.substring(0, end)
        }

        /** Shipped capture sources whose text names any of [tokens], by file name. */
        fun shippedSourcesNaming(vararg tokens: String): List<String> =
            shippedSources()
                .filter { file -> tokens.any { file.readText().contains(it) } }
                .map { it.name }
                .sorted()

        /** Kotlin comments removed, so prose about a rule never answers for it. */
        fun withoutComments(source: String): String =
            Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL).replace(source, "")
                .replace(Regex("//[^\n]*"), "")

        fun listenerText(): String = sourceText("ReplyboxListenerService.kt")

        fun channelText(): String = sourceText("CaptureChannel.kt")

        /**
         * Line endings normalised, which every check above depends on: the repo is
         * checked out with CRLF on Windows, and a pattern that looks at a line's
         * tail takes the `\r` with it -- a test that only passes where nobody is
         * looking at it is worse than no test (OwnPackageGuardTest).
         */
        fun sourceText(name: String): String =
            File(captureDir(), name).readText().replace("\r\n", "\n")

        fun captureDir(): File = File(androidAppDir(), "src/main/kotlin/com/oasisforge/replybox/capture")

        fun shippedSources(): List<File> =
            captureDir().listFiles { f: File -> f.name.endsWith(".kt") }.orEmpty().sorted()
    }
}
