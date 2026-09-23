package com.oasisforge.replybox.capture

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * INB-13's launch, run rather than described.
 *
 * The defect this file exists over shipped as a *silent success*: the control
 * called a no-op launcher that returned true, so on a real phone nothing opened
 * and the snackbar that would have said so never appeared either. Every
 * assertion below is therefore about the honesty of the answer as much as about
 * the launch -- a path that does nothing must answer false, and a path that was
 * not offered must not run.
 *
 * `PendingIntent` and `PackageManager` cannot be built on this classpath (the
 * stub android.jar answers null to every framework call), so [AppLaunch] takes
 * its targets through [LaunchTargets] and this file hands it fakes that record
 * what they were asked for. What that buys is the part a compiler cannot hold:
 * which of the two paths ran, and which one did not.
 */
class AppLaunchTest {

    /**
     * Records every question asked of it, so a test can assert on the asks that
     * did **not** happen -- which is the whole of "the two paths are not
     * interchangeable".
     */
    private class RecordingTargets(
        private val chat: Boolean = false,
        private val launcher: Boolean = false,
        private val throwsOnResolve: Boolean = false,
        private val throwsOnStart: Boolean = false,
        private val posted: Set<String> = emptySet(),
    ) : LaunchTargets {

        val asked = mutableListOf<String>()
        val started = mutableListOf<String>()

        /**
         * This install's `everSeen` record ([CaptureStore.hasEverSeen] on a
         * device). Not recorded in [asked]: it is the app's own note of what has
         * messaged the user, not a question put to the phone, which is the whole
         * distinction the gate rests on.
         */
        override fun hasPosted(packageName: String): Boolean = packageName in posted

        override fun heldChat(notificationKey: String): Launch? {
            asked.add("chat:$notificationKey")
            if (throwsOnResolve) throw IllegalStateException("the map could not be read")
            return if (chat) start("chat:$notificationKey") else null
        }

        override fun appLauncher(packageName: String): Launch? {
            asked.add("app:$packageName")
            if (throwsOnResolve) throw SecurityException("the package manager refused")
            return if (launcher) start("app:$packageName") else null
        }

        private fun start(what: String) = Launch {
            if (throwsOnStart) throw IllegalStateException("the intent was cancelled")
            started.add(what)
        }
    }

    private val key = "0|com.whatsapp|1|null|10123"
    private val pkg = "com.whatsapp"

    @Test
    fun `open chat fires the held content intent and never asks for a launcher intent`() {
        val targets = RecordingTargets(chat = true, launcher = true)

        assertTrue(AppLaunch.openChat(key, targets))

        assertEquals(listOf("chat:$key"), targets.started)
        assertEquals(
            listOf("chat:$key"),
            targets.asked,
            "INB-13's `Open chat` fires the notification's own content intent and nothing else. Reaching " +
                "for a launcher intent here would land the user somewhere other than the chat the label " +
                "promised.",
        )
    }

    @Test
    fun `open app starts the launcher intent and never asks for a held notification`() {
        val targets = RecordingTargets(chat = true, launcher = true)

        assertTrue(AppLaunch.openApp(pkg, targets))

        assertEquals(listOf("app:$pkg"), targets.started)
        assertEquals(
            listOf("app:$pkg"),
            targets.asked,
            "INB-13's `Open <app>` claims nothing about where it lands, and firing a held content intent " +
                "instead would make that label a lie in the other direction.",
        )
    }

    @Test
    fun `a chat with nothing held is false, and does not become a launcher intent`() {
        val targets = RecordingTargets(chat = false, launcher = true)

        assertFalse(
            AppLaunch.openChat(key, targets),
            "Nothing held means the state the `Open chat` label was drawn from has gone. INB-13 spends " +
                "that as a failed launch -- one snackbar -- not as a different launch.",
        )
        assertEquals(emptyList(), targets.started)
        assertEquals(listOf("chat:$key"), targets.asked)
    }

    @Test
    fun `a package that resolves to nothing is false`() {
        // INB-16's two remaining indistinguishable cases: the app is gone, or it
        // is installed with no launcher activity and so has nothing to start.
        // Both are this, and the snackbar names no app.
        val targets = RecordingTargets(launcher = false)

        assertFalse(AppLaunch.openApp(pkg, targets))
        assertEquals(emptyList(), targets.started)
    }

    @Test
    fun `an app that has never posted is not launched, and the phone is never asked about it`() {
        // The other half of the 22 September 2026 decision. `<queries>` now
        // carries a MAIN + LAUNCHER filter, so `getLaunchIntentForPackage` would
        // resolve for any launchable app -- which would make this method a
        // yes/no oracle a caller could walk a list of package names through.
        // SourceAppInfo.mayAsk is the one rule both routes to the package
        // manager go through, and this is it on this route.
        val targets = RecordingTargets(launcher = true)

        assertFalse(
            AppLaunch.openApp("com.example.never.posted", targets),
            "Replybox only ever asks about a package that has already sent the user a notification, or one " +
                "of the six the manifest names (SourceAppInfo.mayAsk).",
        )
        assertEquals(emptyList(), targets.asked, "the refusal has to happen before the package manager is touched")
        assertEquals(emptyList(), targets.started)
    }

    @Test
    fun `an app that has posted is launched, though it ships in nothing`() {
        // What the decision bought: INB-13's control now works for INB-20's
        // second source -- every app that joined the inbox by posting a
        // notification -- instead of failing every time, forever.
        val joined = "com.example.some.other.app"
        val targets = RecordingTargets(launcher = true, posted = setOf(joined))

        assertTrue(AppLaunch.openApp(joined, targets))
        assertEquals(listOf("app:$joined"), targets.started)
    }

    @Test
    fun `open chat is not gated on having posted, because it names no package`() {
        // A held content intent is keyed by a notification this process is
        // holding, so it can only ever name a conversation that arrived here --
        // there is nothing to learn about the phone and nothing to refuse. It is
        // also the only path that reaches an app with no launcher activity.
        val targets = RecordingTargets(chat = true)

        assertTrue(AppLaunch.openChat(key, targets))
        assertEquals(listOf("chat:$key"), targets.started)
    }

    @Test
    fun `a launch that throws while starting is false, not a crash`() {
        val targets = RecordingTargets(chat = true, launcher = true, throwsOnStart = true)

        assertFalse(AppLaunch.openChat(key, targets), "a cancelled PendingIntent is a launch that did not happen")
        assertFalse(AppLaunch.openApp(pkg, targets), "an ActivityNotFoundException is a launch that did not happen")
    }

    @Test
    fun `a launch that throws while resolving is false, not a crash`() {
        // Resolving and starting are one outcome in INB-13: "a launch that throws
        // *or resolves to nothing* changes nothing on screen".
        val targets = RecordingTargets(chat = true, launcher = true, throwsOnResolve = true)

        assertFalse(AppLaunch.openChat(key, targets))
        assertFalse(AppLaunch.openApp(pkg, targets))
        assertEquals(emptyList(), targets.started)
    }

    /**
     * Product principle 1, as INB-13 spells it: *neither intent carries an extra,
     * a message, a sender or a conversation identifier the app added.*
     *
     * A source-reading check, because there is no way to execute it: the extra
     * that would break this rule would be added to an `Intent` that cannot be
     * built on this classpath, and asserting on a fake's recorded string would
     * only assert on the fake. What can be held is that the file has no way to
     * add one -- it never constructs an `Intent`, never writes to one, and never
     * builds a component into another app's internals.
     *
     * `addFlags(FLAG_ACTIVITY_NEW_TASK)` is the one write, and it is allowed: it
     * says which task the activity starts in, carries nothing, and is required
     * because the channel starts from the application context.
     */
    @Test
    fun `neither launch path can add anything to an intent`() {
        val source = launchText()
        val offenders = FORBIDDEN_IN_LAUNCH.filter { source.contains(it) }

        assertEquals(
            emptyList(),
            offenders,
            "INB-13: neither intent carries an extra, a message, a sender or a conversation identifier the " +
                "app added, and the app never builds an intent into another app's internals or guesses a " +
                "deep link (product principle 1). A content intent is sent as the source app built it and " +
                "a launcher intent as the package manager handed it over.",
        )
    }

    /**
     * INB-13's 23 September 2026 correction, held at the one line that carries it.
     *
     * The drill measured `PendingIntent.send()` succeeding while the system
     * blocked the activity behind it -- `balAllowedByPiCreator: BSP.NONE`, a
     * background activity launch refused because the *creator* never opted in.
     * Since Android 14 a sender targeting API 34 or above has to offer its own
     * start privileges explicitly, and this app has them: it is on screen with the
     * user's finger on the control.
     *
     * A source-reading check, like the two below it, because none of this can be
     * executed here -- `ActivityOptions` is one more thing the stub android.jar
     * answers null to. What it holds is that the send still asks for the launch on
     * the app's own behalf, and that the offer is made through options and never
     * through the intent: the fill-in argument, the only place a sender may merge
     * values into someone else's intent, stays null.
     */
    @Test
    fun `the content intent is sent with the app's own start privileges and no fill-in`() {
        val source = launchText()

        assertTrue(
            source.contains(SEND),
            "INB-13's `Open chat` sends the held content intent as `$SEND`. A send that stopped lending " +
                "this app's foreground start privileges is the defect the 23 September 2026 drill found: " +
                "the send succeeds, the activity is blocked, and the tap does nothing and says nothing.",
        )
        assertTrue(
            source.contains("setPendingIntentBackgroundActivityStartMode(") &&
                source.contains("ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED"),
            "the options the send carries are what offers those privileges; without them the platform " +
                "judges the launch on the creator's, which is what it refused",
        )
        assertTrue(
            source.contains("Build.VERSION_CODES.UPSIDE_DOWN_CAKE"),
            "the option is API 34. Below it a foreground sender's privileges were lent implicitly, so the " +
                "answer there is no options bundle rather than a call that does not exist.",
        )
    }

    /**
     * CAP-10 and INB-17: Replybox never hides another app's notification.
     *
     * INB-13 allows one consequence that looks like the opposite -- firing a
     * content intent may make the *source app* cancel its own notification, and
     * CAP-22 reads that removal like any other and marks the conversation read.
     * That is the user having opened the chat. The line this test holds is that
     * the cancel is always theirs: nothing in the shipped capture package can
     * cancel, snooze or suppress a notification itself.
     */
    @Test
    fun `nothing in the capture package cancels a notification`() {
        val offenders = mutableListOf<String>()
        for (source in shippedSources()) {
            val text = source.readText()
            for (token in FORBIDDEN_CANCELS) {
                if (text.contains(token)) offenders.add("${source.name}: $token")
            }
        }

        assertEquals(
            emptyList(),
            offenders,
            "CAP-10: the app never hides or dismisses another app's notification. INB-13's launch is the " +
                "one thing this area sends back to another app, and it sends an intent -- a cancel here " +
                "would make the read that follows `Open chat` the app's doing instead of the user's " +
                "(CAP-22, INB-5).",
        )
    }

    @Test
    fun `the checks reject a launch file that adds an extra or cancels`() {
        // Without this the two source-reading tests are only as good as their
        // token lists, and a list that has quietly stopped matching passes on
        // every build including the one that ships the defect (CaptureLogTest).
        val source = launchText()
        val survivors = mutableListOf<String>()
        for ((name, mutant) in mutants(source)) {
            if (FORBIDDEN_IN_LAUNCH.none { mutant.contains(it) } && FORBIDDEN_CANCELS.none { mutant.contains(it) }) {
                survivors.add(name)
            }
        }

        assertEquals(emptyList(), survivors, "a weakened launch was accepted by the checks above, so they prove nothing")
    }

    @Test
    fun `the launch file is a shipped source the cancel check reads`() {
        assertTrue(
            shippedSources().any { it.name == "AppLaunch.kt" },
            "AppLaunch.kt moved out of src/main/kotlin/com/oasisforge/replybox/capture, so the cancel check " +
                "above no longer covers the one file that talks to another app.",
        )
    }

    private companion object {

        /**
         * Every way an intent could be given something the app made up. `Intent(`
         * catches a freshly built one, which is the route a guessed deep link
         * would take; the setters catch a resolved one being edited.
         */
        val FORBIDDEN_IN_LAUNCH = listOf(
            "putExtra",
            "putExtras",
            "Intent(",
            "setData",
            "setAction",
            "setComponent",
            "setClassName",
            "setPackage",
            "setType",
            "setSelector",
            "fillIn",
        )

        /** Every API that would suppress a notification the app did not post. */
        val FORBIDDEN_CANCELS = listOf(
            "cancelNotification",
            "cancelAllNotifications",
            "snoozeNotification",
            "NotificationManager",
            "setNotificationsShown",
            "setInterruptionFilter",
        )

        /** The send, as `SystemLaunchTargets.heldChat` spells it. */
        const val SEND = "held.send(context, 0, null, null, null, null, senderOptions())"

        fun mutants(source: String): List<Pair<String, String>> = listOf(
            "the conversation key added as an extra" to
                source.replace(
                    SEND,
                    "held.send(context, 0, Intent().putExtra(\"key\", notificationKey), null, null, null, null)",
                ),
            "the conversation key merged in as a fill-in" to
                source.replace(
                    SEND,
                    "held.send(context, 0, fillIn(notificationKey), null, null, null, senderOptions())",
                ),
            "a deep link guessed into the source app" to
                source.replace(
                    "context.packageManager.getLaunchIntentForPackage(packageName) ?: return null",
                    "Intent(Intent.ACTION_VIEW).setPackage(packageName)",
                ),
            "the notification cancelled after the launch" to
                source.replace(
                    SEND,
                    "$SEND; NotificationManager::class.java",
                ),
        )

        fun launchText(): String = File(
            androidAppDir(),
            "src/main/kotlin/com/oasisforge/replybox/capture/AppLaunch.kt",
        ).readText().replace("\r\n", "\n")

        fun shippedSources(): List<File> =
            File(androidAppDir(), "src/main/kotlin/com/oasisforge/replybox/capture")
                .listFiles { f: File -> f.name.endsWith(".kt") }.orEmpty().sorted()
    }
}
